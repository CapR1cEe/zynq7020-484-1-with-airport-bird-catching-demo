"""Verify fault-edge preservation and dimension guards against UNISIM RTL."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root=Path(__file__).resolve().parents[1]
tools=Path('C:/AMDDesigntools/2025.2/Vivado/bin')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
drive=next(x+':' for x in 'WXYZTU' if not Path(x+':/').exists())
subprocess.run(['subst.exe',drive,str(root)],check=True)
try:
    out=Path(drive+'/verification/control_guards')
    out.mkdir(parents=True,exist_ok=False)
    rtl=out/'rtl';rtl.mkdir()
    frozen={}
    for p in (root/'hardware/g227/rtl').glob('*.v'):
        frozen[p.name]=sha(p);shutil.copy2(p,rtl/p.name)
    suites={'tb_control_fault_guards':('CONTROL_FAULT_GUARDS_PASS',root/'tests/tb_control_fault_guards.sv'),
            'tb_head_config':('HEAD_CONFIG_PASS',root/'tests/tb_head_config.sv'),
            'tb_size_pipeline':('SIZE_PIPELINE_PASS',root/'tests/tb_size_pipeline.sv')}
    for top,(_,p) in suites.items():shutil.copy2(p,out/(top+'.sv'))
    env=dict(os.environ,XILINX_LOCAL_USER_DATA='no',TEMP=str(out),TMP=str(out))
    def run(tool,args,name):
        with (out/(name+'.console.log')).open('wb') as f:
            subprocess.run([str(tools/(tool+'.bat')),*map(str,args)],cwd=out,env=env,
                           stdout=f,stderr=subprocess.STDOUT,check=True)
    run('xvlog',['-sv',*sorted(rtl.glob('*.v')),*(out/(s+'.sv') for s in suites),
                 tools.parent/'data/verilog/src/glbl.v'],'compile')
    records=[]
    for top,(marker,_) in suites.items():
        run('xelab',['-L','unisims_ver','-L','secureip',top,'glbl','-s',top],top+'_elaborate')
        run('xsim',[top,'-runall','-log',top+'.log'],top+'_simulate')
        log=(out/(top+'.log')).read_text()
        matches=re.findall('^'+marker+r' .+$',log,re.M)
        assert len(matches)==1 and not re.search(r'^(FATAL:|Fatal:|ERROR:)',log,re.M),log[-3000:]
        print(matches[0],flush=True)
        records.append(dict(top=top,marker=matches[0],bench_sha256=sha(out/(top+'.sv')),
                            log_sha256=sha(out/(top+'.log'))))
    assert frozen=={p.name:sha(p) for p in (root/'hardware/g227/rtl').glob('*.v')}
    (out/'result.json').write_text(json.dumps(dict(status='PASS_CONTROL_GUARDS',backend='AMD_UNISIM',
        clock_mhz=240,source_sha256=frozen,suites=records),indent=2)+'\n')
finally:subprocess.run(['subst.exe',drive,'/D'],check=True)
