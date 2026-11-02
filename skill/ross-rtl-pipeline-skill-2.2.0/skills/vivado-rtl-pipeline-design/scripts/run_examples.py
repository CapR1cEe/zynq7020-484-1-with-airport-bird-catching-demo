#!/usr/bin/env python3
"""Lint or simulate the original examples using an installed HDL toolchain."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = {
    'mac': ('four_lane_mac_stream', 'tb_four_lane_mac_stream'),
    'elastic': ('elastic_buffer', 'tb_elastic_buffer'),
    'tree': ('signed_sum_tree_stream', 'tb_signed_sum_tree_stream'),
    'fork': ('stream_fork2', 'tb_stream_fork2'),
    'round': ('round_sat_stream', 'tb_round_sat_stream'),
}


def executable(name, override=None):
    found = override or shutil.which(name)
    if not found and os.name == 'nt' and name == 'verilator':
        found = shutil.which('verilator_bin')
    # The MSYS2 wrapper is a Perl script; CreateProcess needs the native binary.
    if found and os.name == 'nt' and name == 'verilator':
        native = Path(found).with_name('verilator_bin.exe')
        if native.is_file():
            found = str(native)
    if not found or not Path(found).is_file():
        raise RuntimeError(f'{name} not found; install/configure the selected backend')
    return found


def invoke(command, log, cwd, timeout):
    rendered = [x.as_posix() if isinstance(x, Path) else str(x) for x in command]
    launch = rendered
    if os.name == 'nt' and Path(rendered[0]).suffix.lower() in ('.bat', '.cmd'):
        # CALL in Vivado's batch wrappers treats an unquoted '=' as a separator.
        # Quote every argument; reject shell-expansion characters rather than
        # interpolate untrusted strings into cmd.exe syntax.
        if any(any(c in arg for c in ('"', '%', '\n', '\r')) for arg in rendered):
            raise RuntimeError('batch-tool arguments cannot contain quotes, percent or newlines')
        quoted = ' '.join('"' + arg + '"' for arg in rendered)
        launch = subprocess.list2cmdline([os.environ.get('COMSPEC', 'cmd.exe')])
        launch += ' /d /v:off /s /c "' + quoted + '"'
    try:
        result = subprocess.run(launch, cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors='replace',
                                timeout=timeout, check=False)
        output, code = result.stdout, result.returncode
    except subprocess.TimeoutExpired as error:
        output = str(error.stdout or '') + f'\nTIMEOUT after {timeout} seconds\n'
        code = 124
    log.write_text(json.dumps(rendered) + '\n' + output, encoding='utf-8')
    print(f'{log.name}: exit={code}', flush=True)
    if code:
        print(output[-8000:], flush=True)
        raise RuntimeError(f'command failed; see {log}')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['lint', 'simulate'], default='simulate')
    parser.add_argument('--backend', choices=['verilator', 'iverilog', 'xsim'], default='verilator')
    parser.add_argument('--example', choices=['all', *EXAMPLES], default='all')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--verilator', help='Explicit Verilator executable path')
    parser.add_argument('--vivado-bin', type=Path, help='Vivado bin directory for the xsim backend')
    parser.add_argument('--timeout', type=int, default=300, help='Seconds per tool command')
    parser.add_argument('--mac-width', type=int, default=8, help='Simulation bench width, 2..15')
    parser.add_argument('--tree-inputs', type=int, default=5, help='Tree lanes for this bench, 1..32')
    parser.add_argument('--tree-width', type=int, default=8, help='Tree operand width, 2..15')
    parser.add_argument('--round-in-width', type=int, default=8, help='Rounding bench input width, 2..12')
    parser.add_argument('--round-out-width', type=int, default=4, help='Rounding output width, 2..input width')
    parser.add_argument('--round-fraction-bits', type=int, default=3, help='Rounding fractional bits, 0..input width-1')
    args = parser.parse_args()
    if args.timeout < 1 or not 2 <= args.mac_width <= 15:
        parser.error('timeout must be positive and --mac-width must be in 2..15')
    if not 1 <= args.tree_inputs <= 32 or not 2 <= args.tree_width <= 15:
        parser.error('--tree-inputs must be in 1..32 and --tree-width in 2..15')
    if (not 2 <= args.round_in_width <= 12 or
            not 2 <= args.round_out_width <= args.round_in_width or
            not 0 <= args.round_fraction_bits < args.round_in_width):
        parser.error('rounding bench needs input width 2..12, output width 2..input width, and fractional bits 0..input width-1')
    build_root = args.build_dir.resolve()
    if build_root == ROOT or ROOT in build_root.parents:
        parser.error('--build-dir must be outside the installed skill directory')
    build_root.mkdir(parents=True, exist_ok=True)
    selected = EXAMPLES if args.example == 'all' else {args.example: EXAMPLES[args.example]}
    receipt = {'mode': args.mode, 'backend': args.backend, 'results': [],
               'implementation_frequency': 'not_measured_by_this_runner'}
    try:
        if args.backend == 'xsim':
            def x_tool(name):
                suffix = '.bat' if os.name == 'nt' else ''
                return executable(name, str(args.vivado_bin/(name+suffix)) if args.vivado_bin else None)
            backend = x_tool('xvlog')
        else:
            backend = executable(args.backend, args.verilator if args.backend == 'verilator' else None)
        version = subprocess.run([backend, '-V' if args.backend == 'iverilog' else '--version'],
                                 capture_output=True, text=True, errors='replace', timeout=20)
        receipt['tool_version'] = (version.stdout + version.stderr).splitlines()[0]
        for name, (module, top) in selected.items():
            parameters = ({'DATA_WIDTH': args.mac_width} if name == 'mac' else
                          {'INPUTS': args.tree_inputs, 'DATA_WIDTH': args.tree_width} if name == 'tree' else
                          {'IN_WIDTH': args.round_in_width, 'OUT_WIDTH': args.round_out_width,
                           'FRACTION_BITS': args.round_fraction_bits} if name == 'round' else {})
            suffix = ''.join(f'_{key.lower()}{value}' for key, value in parameters.items())
            build = build_root / (name + suffix)
            build.mkdir(exist_ok=True)
            rtl, tb = ROOT/'assets/rtl'/f'{module}.sv', ROOT/'assets/tb'/f'{top}.sv'
            if args.mode == 'lint':
                if args.backend == 'verilator':
                    command = [backend, '--lint-only', '-Wall', '--top-module', module, rtl]
                    command += [f'-G{key}={value}' for key, value in parameters.items()]
                elif args.backend == 'iverilog':
                    command = [backend, '-g2012', '-Wall', '-s', module, '-tnull', rtl]
                    command += [f'-P{module}.{key}={value}' for key, value in parameters.items()]
                else:
                    command = [backend, '--sv', rtl]
                invoke(command, build/'lint.log', build, args.timeout)
            else:
                if args.backend == 'verilator':
                    obj = build/'obj_dir'
                    command = [backend, '--binary', '--timing', '--assert', '-j', '2',
                               '--top-module', top, '--Mdir', obj, rtl, tb]
                    command += [f'-G{key}={value}' for key, value in parameters.items()]
                    invoke(command, build/'build.log', build, args.timeout)
                    binary = obj / (f'V{top}' + ('.exe' if os.name == 'nt' else ''))
                    run_command = [binary]
                elif args.backend == 'iverilog':
                    binary = build/'simulation.vvp'
                    command = [backend, '-g2012', '-s', top, '-o', binary, rtl, tb]
                    command += [f'-P{top}.{key}={value}' for key, value in parameters.items()]
                    invoke(command, build/'build.log', build, args.timeout)
                    run_command = [executable('vvp'), binary]
                else:
                    invoke([backend, '--sv', rtl, tb], build/'compile.log', build, args.timeout)
                    command = [x_tool('xelab'), top, '--snapshot', 'ross_example', '--debug', 'typical']
                    for key, value in parameters.items():
                        command += ['--generic_top', f'{key}={value}']
                    invoke(command, build/'build.log', build, args.timeout)
                    run_command = [x_tool('xsim'), 'ross_example', '--runall']
                output = invoke(run_command, build/'simulation.log', build, args.timeout)
                if 'PASS ' not in output:
                    raise RuntimeError(f'{name}: simulation ended without the bench PASS receipt')
                print('\n'.join(line for line in output.splitlines() if line.startswith('PASS ')), flush=True)
            receipt['results'].append({'example': name, 'status': 'passed',
                                       'parameters': parameters,
                                       'mac_width': args.mac_width if name == 'mac' else None})
        receipt['status'] = 'passed'
    except (RuntimeError, OSError, subprocess.SubprocessError, IndexError) as error:
        receipt.update(status='failed', error=str(error))
        print(str(error), file=sys.stderr)
    destination = build_root/'run_receipt.json'
    destination.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(destination)
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
