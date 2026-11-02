"""Check signed results, reset flushing and exact metadata latency in UNISIM."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BIN = Path('C:/AMDDesigntools/2025.2/Vivado/bin')
out = ROOT / 'runs' / ('split_dot_pairs_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
out.mkdir()
sources = [ROOT / 'hardware/g227/rtl' / name for name in
           ('tinyyolo_pipe_add.v', 'tinyyolo_dsp_mul.v', 'tinyyolo_dot16_pair.v', 'tinyyolo_dot24_pair.v')]
benches = [ROOT / 'tests' / (name + '.sv') for name in ('tb_dot_pair', 'tb_dot24_pair')]
inventory = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + benches}
env = dict(os.environ, XILINX_LOCAL_USER_DATA='no', TEMP=str(out), TMP=str(out))

def run(tool, args, tag):
    with (out / (tag + '.console.log')).open('wb') as fp:
        result = subprocess.run([str(BIN / (tool + '.bat')), *map(str, args)], cwd=out, env=env,
                                stdout=fp, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(str(out / (tag + '.console.log')))

run('xvlog', ['-sv', *sources, *benches, BIN.parent / 'data/verilog/src/glbl.v'], 'compile')
results = []
for bench, marker, latency in [('tb_dot_pair', 'PACKED_DOT_PAIR_PASS', 13), ('tb_dot24_pair', 'DOT24_PAIR_PASS', 15)]:
    run('xelab', ['-L', 'unisims_ver', '-L', 'secureip', bench, 'glbl', '-s', bench], bench + '_elab')
    run('xsim', [bench, '-runall', '-log', bench + '.log'], bench + '_sim')
    log = (out / (bench + '.log')).read_text()
    passed = re.findall('^' + marker + r' .+$', log, re.M)
    if len(passed) != 1 or re.search(r'^(?:FATAL:|Fatal:|ERROR:)', log, re.M):
        raise RuntimeError(log[-4000:])
    print(passed[0] + f' latency_clocks={latency}', flush=True)
    results.append(dict(bench=bench, marker=passed[0], latency_clocks=latency))
for name, digest in inventory.items():
    if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
        raise RuntimeError('Source changed: ' + name)
(out / 'result.json').write_text(json.dumps(dict(status='PASS_SPLIT_DOT_PAIRS', backend='AMD_UNISIM',
    clock_mhz=240, source_sha256=inventory, suites=results), indent=2) + '\n')
print('SPLIT_DOT_PAIRS_PASS ' + str(out), flush=True)
