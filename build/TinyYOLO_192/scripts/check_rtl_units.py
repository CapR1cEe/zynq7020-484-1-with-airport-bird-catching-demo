"""Validate changed FP datapaths, profiling MMIO and HP0 failure handling."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
BIN=Path('C:/AMDDesigntools/2025.2/Vivado/bin')


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    drive=next(letter+':' for letter in 'UVWXYZ' if not Path(letter+':/').exists())
    subprocess.run(['subst.exe',drive,str(ROOT)],check=True)
    try:
        short=Path(drive+'/')
        out=short/'verification/rtl_units'
        out.mkdir(parents=True,exist_ok=False)
        frozen=out/'rtl';frozen.mkdir()
        inventory={}
        for source in (ROOT/'hardware/g227/rtl').glob('*.v'):
            inventory[source.name]=sha(source)
            shutil.copy2(source,frozen/source.name)
        shutil.copytree(ROOT/'tests/fp_vectors',out/'fp_vectors')
        suites={'tb_shift56_jam':['SHIFT56_JAM_PASS'],
                'tb_fp_exact':['FP_EXACT_PASS'],
                'tb_counter64':['PROFILE_SAMPLE_PASS','COUNTER64_PASS','COUNTER32_PASS'],
                'tb_hp0_protocol':['HP0_PROTOCOL_PASS']}
        for top in suites:shutil.copy2(ROOT/('tests/'+top+'.sv'),out/(top+'.sv'))
        env=dict(os.environ,XILINX_LOCAL_USER_DATA='no',TEMP=str(out),TMP=str(out))
        def invoke(tool,args,tag):
            with (out/(tag+'.console.log')).open('wb') as stream:
                result=subprocess.run([str(BIN/(tool+'.bat')),*map(str,args)],cwd=out,
                                      env=env,stdout=stream,stderr=subprocess.STDOUT)
            if result.returncode:raise RuntimeError(str(out/(tag+'.console.log')))
        invoke('xvlog',['-sv',*sorted(frozen.glob('*.v')),
               *(out/(s+'.sv') for s in suites),BIN.parent/'data/verilog/src/glbl.v'],'compile')
        results=[]
        for top,prefixes in suites.items():
            invoke('xelab',['-L','unisims_ver','-L','secureip',top,'glbl','-s',top],top+'_elaborate')
            invoke('xsim',[top,'-runall','-log',top+'.log'],top+'_simulate')
            log=(out/(top+'.log')).read_text()
            if re.search(r'^(?:FATAL:|Fatal:|ERROR:)',log,re.M):
                raise AssertionError(log[-3000:])
            markers=[]
            for prefix in prefixes:
                matches=re.findall(r'^'+prefix+r' .+$',log,re.M)
                if len(matches)!=1:raise AssertionError('Missing pass marker: '+prefix)
                markers.extend(matches)
            print('\n'.join(markers),flush=True)
            results.append(dict(top=top,status='PASS',markers=markers,
                bench_sha256=sha(ROOT/('tests/'+top+'.sv')),log_sha256=sha(out/(top+'.log'))))
        if inventory!={p.name:sha(p) for p in (ROOT/'hardware/g227/rtl').glob('*.v')}:
            raise RuntimeError('RTL changed during simulation')
        (out/'result.json').write_text(json.dumps(dict(status='PASS_RTL_UNITS',board_tested=False,
            backend='AMD_UNISIM',source_sha256=inventory,suites=results),indent=2)+'\n')
    finally:subprocess.run(['subst.exe',drive,'/D'],check=True)


if __name__=='__main__':main()
