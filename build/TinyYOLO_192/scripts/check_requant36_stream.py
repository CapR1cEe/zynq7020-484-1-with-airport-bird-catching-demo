"""Check a four-DSP, II=1 requantizer against arbitrary-precision products."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BIN = Path('C:/AMDDesigntools/2025.2/Vivado/bin')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    drive = next(letter + ':' for letter in 'TUVWXYZ' if not Path(letter + ':/').exists())
    subprocess.run(['subst', drive, str(ROOT)], check=True)
    try:
        short = Path(drive + '/')
        out = short / 'runs/requant36_stream'
        out.mkdir(parents=True, exist_ok=True)
        (out / 'result.json').unlink(missing_ok=True)
        sources = [ROOT / 'hardware/g227/rtl' / n for n in
                   ('tinyyolo_dsp_mul.v', 'tinyyolo_requant36_stream.v')]
        inventory = {p.name: sha(p) for p in sources}
        frozen = []
        for src in sources:
            dst = out / src.name
            shutil.copyfile(src, dst)
            frozen.append(dst)
        config = (ROOT / 'software/source/network_config.h').read_text()
        rows = config.split('static const Conv convs[24]={')[1].split('};')[0]
        params = (ROOT / 'model/parameters.bin').read_bytes()
        coefficients = []
        for row in rows.splitlines():
            if not row.startswith('{'):
                continue
            values = list(map(int, re.findall(r'(?<![\w.])([0-9]+)U', row)[:12]))
            co, offset = values[1], values[9]
            if offset:
                coefficients.extend(x[0] for x in struct.iter_unpack('<Q', params[offset:offset + 8 * co]))
        assert coefficients and max(coefficients).bit_length() <= 36
        accs = [0,1,-1,2,-2,127,-128,255,-256,65535,-65536,2**31-1,-2**31]
        coeffs = [0,1,2,3,2**16-1,2**18-1,2**18,2**32-1,2**35,2**36-1]
        cases = [(a,m,s,z) for a in accs for m in coeffs
                 for s in (1,2,16,17,18,31,32,35,36,47,61,62) for z in (-128,-1,0,127)]
        rng = random.Random(0x47325501)
        cases += [(rng.randrange(-2**31,2**31),rng.randrange(2**36),
                   rng.randrange(1,63),rng.randrange(-128,128)) for _ in range(20000)]
        cases += [(rng.randrange(-2**31,2**31),m,rng.randrange(1,63),rng.randrange(-128,128))
                  for m in coefficients]
        vectors = []
        for a,m,s,z in cases:
            product = abs(a) * m
            q, rem = divmod(product, 1 << s)
            q += rem > (1 << (s-1)) or (rem == (1 << (s-1)) and q & 1)
            result = max(-128,min(127,(-q if a < 0 else q) + z))
            vectors.append(f'{a&0xffffffff:08x} {m:09x} {s} {z&255:02x} {result&255:02x} {product:017x}')
        (out / 'vectors.txt').write_text('\n'.join(vectors) + '\n')
        bench = out / 'tb_requant36_stream.sv'
        original_bench = ROOT / 'tests/tb_requant36_stream.sv'
        bench.write_text(original_bench.read_text().replace('VECTOR_MIN', str(len(cases))))
        env = os.environ.copy()
        env.update(XILINX_LOCAL_USER_DATA='no',TEMP=str(out),TMP=str(out))
        glbl = BIN.parent / 'data/verilog/src/glbl.v'
        for tool, arguments in [
            ('xvlog',['-sv',*frozen,bench,glbl]),
            ('xelab',['-L','unisims_ver','-L','secureip','tb_requant36_stream','glbl','-s','requant36']),
            ('xsim',['requant36','-runall','-log','simulation.log'])]:
            print('RUN ' + tool, flush=True)
            with (out / (tool+'.console.log')).open('wb') as log:
                result = subprocess.run([str(BIN/(tool+'.bat')),*map(str,arguments)],
                    cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(str(out/(tool+'.console.log')))
        log = out / 'simulation.log'
        text = log.read_text()
        markers = re.findall(r'^REQUANT36_STREAM_PASS .+$',text,re.M)
        assert len(markers)==1 and not re.search(r'^(?:FATAL:|Fatal:|ERROR:)',text,re.M),text[-3000:]
        assert all(sha(src)==inventory[src.name] and sha(out/src.name)==inventory[src.name] for src in sources)
        record = dict(status='PASS_REQUANT36_STREAM',board_tested=False,
            backend='AMD_UNISIM',source_sha256=inventory,bench_sha256=sha(original_bench),
            generator_sha256=sha(Path(__file__)),vectors_sha256=sha(out/'vectors.txt'),
            log_sha256=sha(log),vectors=len(cases),model_coefficients=len(coefficients),
            maximum_model_coefficient_bits=max(coefficients).bit_length(),
            latency_clocks=14,initiation_interval=1,DSPs_per_engine=4,
            marker=markers[0],finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
        (out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
        print(record['marker'],flush=True)
    finally:
        subprocess.run(['subst',drive,'/D'],check=True)


if __name__ == '__main__':
    main()
