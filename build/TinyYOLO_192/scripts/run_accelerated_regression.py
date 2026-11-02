"""Qualify an exact DSP simulation model, then run extended integration tests.

Generated simulation sources replace only DSP primitive instances. Hardware
sources remain untouched. Results are RTL simulation, never board evidence.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path('C:/AMDDesigntools/2025.2/Vivado/bin')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rtl-root', type=Path, required=True)
    ap.add_argument('--tests-root', type=Path, default=ROOT/'tests')
    ap.add_argument('--run', required=True)
    ap.add_argument('--suites', nargs='+', choices=['head','features','parallel','closedloop'],
                    default=['head','features','parallel'])
    ap.add_argument('--drive', default='V:')
    ap.add_argument('--resume', action='store_true', help='Validate frozen inputs and reuse only completed suites')
    ap.add_argument('--resume-inventory', type=Path)
    args = ap.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,60}', args.run):
        ap.error('Invalid run name')
    if not re.fullmatch(r'[A-Z]:', args.drive):
        ap.error('Drive must be one uppercase drive letter')
    if not Path(args.drive+'/').exists():
        subprocess.run(['subst.exe', args.drive, str(ROOT)], check=True)
    if not os.path.samefile(args.drive+'/', ROOT):
        raise ValueError('Short drive is assigned to another directory')
    short = Path(args.drive+'/')
    out = short/'runs'/args.run
    out.mkdir(parents=True, exist_ok=args.resume)
    rtl = args.rtl_root.resolve()
    tests = args.tests_root.resolve()
    originals = {p.name: sha(p) for p in sorted(rtl.glob('*.v'))}
    test_hashes = {p.relative_to(tests).as_posix(): sha(p) for p in tests.rglob('*') if p.is_file()}
    if args.resume:
        if args.resume_inventory is None:
            raise ValueError('Resume requires the immutable validation source inventory')
        frozen_inventory = json.loads(args.resume_inventory.read_text(encoding='utf-8-sig'))
        for name, digest in originals.items():
            if frozen_inventory['hardware/g227/rtl/'+name] != digest:
                raise ValueError('Frozen RTL mismatch: '+name)
        for name, digest in test_hashes.items():
            if frozen_inventory['tests/'+name] != digest:
                raise ValueError('Frozen test mismatch: '+name)
    generated = out/'simulation_rtl'
    generated.mkdir(exist_ok=args.resume)
    replacements = {}
    for path in sorted(rtl.glob('*.v')):
        text = path.read_text()
        count = text.count('DSP48E1 #(')
        if count:
            replacements[path.name] = count
            text = text.replace('DSP48E1 #(', 'ty_dsp48e1_fast #(')
        destination = generated/path.name
        if args.resume and destination.read_text() != text:
            raise ValueError('Previously generated RTL changed: '+path.name)
        if not args.resume:
            destination.write_text(text)
    if replacements != {'tinyyolo_dsp_accum32.v':1, 'tinyyolo_dsp_mul.v':1}:
        raise ValueError('Unexpected primitive configurations')
    model = generated/'dsp48e1_fast.sv'
    if args.resume and sha(model) != sha(ROOT/'tests/dsp48e1_fast.sv'):
        raise ValueError('Previously qualified DSP model changed')
    if not args.resume:
        shutil.copy2(ROOT/'tests/dsp48e1_fast.sv', model)
    qualification = out/'qualification'
    qualification.mkdir(exist_ok=args.resume)
    qualified = []
    for name in replacements:
        text = (generated/name).read_text().replace('module tinyyolo_', 'module fast_tinyyolo_', 1)
        path = qualification/('fast_'+name)
        if args.resume and path.read_text() != text:
            raise ValueError('Previously qualified primitive wrapper changed')
        if not args.resume:
            path.write_text(text)
        qualified.extend([rtl/name, path])

    def invoke(directory, name, arguments):
        env = os.environ.copy()
        env['XILINX_LOCAL_USER_DATA'] = 'no'
        for key in ('TEMP','TMP'):
            env[key] = str(directory)
        with (directory/(name+'.console.log')).open('wb') as log:
            result = subprocess.run([str(BIN/(name+'.bat')), *map(str, arguments)],
                                    cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(str(directory/(name+'.console.log')))

    glbl = BIN.parent/'data/verilog/src/glbl.v'
    invoke(qualification, 'xvlog', ['-sv', *qualified, model, ROOT/'tests/tb_dsp_fast.sv', glbl])
    invoke(qualification, 'xelab', ['-L','unisims_ver','-L','secureip','tb_dsp_fast','glbl','-s','qualification'])
    invoke(qualification, 'xsim', ['qualification','-runall','-log','qualification.log'])
    log = (qualification/'qualification.log').read_text()
    markers = re.findall(r'^FAST_DSP_LOCKSTEP_PASS .+$', log, re.M)
    if len(markers) != 1 or re.search(r'^(FATAL:|Fatal:|ERROR:)', log, re.M):
        raise ValueError('DSP model qualification failed: '+str(qualification))
    print(markers[0], flush=True)
    results = []
    for suite in args.suites:
        directory = out/suite
        directory.mkdir(exist_ok=args.resume)
        for vectors in ('closedloop_vectors','head_vectors'):
            if (tests/vectors).exists():
                if args.resume and (directory/vectors).exists():
                    for vector in (tests/vectors).rglob('*'):
                        if vector.is_file() and sha(vector) != sha(directory/vectors/vector.relative_to(tests/vectors)):
                            raise ValueError('Previous vectors changed')
                else:
                    shutil.copytree(tests/vectors, directory/vectors)
        shutil.copy2(tests/'closedloop_cases.svh', directory/'closedloop_cases.svh')
        top = 'tb_head_top' if suite == 'head' else 'tb_'+suite
        bench = (tests/(top+'.sv')).read_text()
        # Behavioral period checks logic only; routed STA proves 240 MHz.
        if 'always #2.083333333 clk' not in bench:
            raise ValueError('Expected the explicit 240 MHz simulation clock')
        assertion = '''
    always @(posedge clk) if(rst_n) begin
        if($isunknown(dut.u_control.state) || !$onehot(dut.u_control.state))
            $fatal(1,"FSM_ONEHOT_INVARIANT_FAILED");
    end
'''
        control = (rtl/'tinyyolo_allconv_control.v').read_text()
        if 'reg [63:0] state' in control and 'FSM_ONEHOT_INVARIANT_FAILED' not in bench:
            bench = bench.replace('endmodule', assertion+'endmodule')
        bench_path = directory/(top+'.sv')
        if args.resume and bench_path.exists() and bench_path.read_text() != bench:
            raise ValueError('Previously generated bench changed: '+suite)
        bench_path.write_text(bench)
        if args.resume and (directory/'result.json').exists():
            previous = json.loads((directory/'result.json').read_text())
            lines = (directory/(suite+'.log')).read_text().splitlines()
            if (previous['status'] != 'PASS' or len(previous['pass_marker']) != 1 or
                lines.count(previous['pass_marker'][0]) != 1 or
                any(line.startswith(('FATAL:', 'Fatal:', 'ERROR:', 'FAIL', 'ASSERTION_FAILED')) for line in lines) or
                previous['generated_bench_sha256'] != sha(bench_path)):
                raise ValueError('Completed suite cannot be reused: '+suite)
            results.append(previous)
            print('REUSE_VALIDATED_SUITE '+suite, flush=True)
            continue
        if args.resume:
            for name in (suite+'.log', 'xsim.console.log'):
                previous_log = directory/name
                if previous_log.exists():
                    archived = directory/(name+'.interrupted')
                    if archived.exists():
                        raise ValueError('Interrupted log already preserved')
                    previous_log.rename(archived)
        print('START_ACCELERATED '+suite, flush=True)
        start = time.monotonic()
        invoke(directory, 'xvlog', ['-sv', *sorted(generated.glob('*.v')), model, bench_path, glbl])
        invoke(directory, 'xelab', ['-L','unisims_ver','-L','secureip',top,'glbl','-s',suite])
        invoke(directory, 'xsim', [suite,'-runall','-log',suite+'.log'])
        lines = (directory/(suite+'.log')).read_text().splitlines()
        prefix = {'head':'HEAD_TOP_PASS ', 'features':'FEATURES_PASS ',
                  'parallel':'PARALLEL_PASS ', 'closedloop':'CLOSEDLOOP_PASS '}[suite]
        passed = [line for line in lines if line.startswith(prefix)]
        errors = [line for line in lines if line.startswith(('FATAL:','Fatal:','ERROR:','FAIL','ASSERTION_FAILED'))]
        if len(passed)!=1 or errors:
            raise ValueError('Accelerated suite failed: '+suite)
        record = dict(suite=suite,status='PASS',backend='qualified_cycle_exact_DSP_model',
                      elapsed_seconds=round(time.monotonic()-start,3),pass_marker=passed,
                      behavioral_clock_MHz=240,onehot_assertion='reg [63:0] state' in control,
                      generated_bench_sha256=sha(bench_path))
        results.append(record)
        (directory/'result.json').write_text(json.dumps(record,indent=2)+'\n')
        print(json.dumps(record), flush=True)
    if originals != {p.name:sha(p) for p in sorted(rtl.glob('*.v'))}:
        raise ValueError('Hardware sources changed during simulation')
    if test_hashes != {p.relative_to(tests).as_posix():sha(p) for p in tests.rglob('*') if p.is_file()}:
        raise ValueError('Test sources changed during simulation')
    receipt = dict(status='PASS_QUALIFIED_DSP_INTEGRATION', finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   board_tested=False,post_route_simulation=False,source_root=str(rtl),
                   source_sha256=originals,test_sha256=test_hashes,qualification_marker=markers,
                   model_sha256=sha(model),generated_sources={p.name:sha(p) for p in generated.iterdir()},
                   suites=results)
    (out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(receipt['status'],flush=True)


if __name__=='__main__':
    main()
