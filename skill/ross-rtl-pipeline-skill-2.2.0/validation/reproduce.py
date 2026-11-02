#!/usr/bin/env python3
"""Re-run package unit tests and selected HDL checks in a separate directory."""
import argparse
from pathlib import Path
import subprocess
import sys

PACKAGE = Path(__file__).resolve().parents[1]
SKILL = PACKAGE/'skills/vivado-rtl-pipeline-design'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,required=True)
    parser.add_argument('--backend',choices=['xsim','verilator','iverilog'],default='xsim')
    parser.add_argument('--mode',choices=['simulate','lint'],default='simulate')
    parser.add_argument('--vivado-bin',type=Path)
    parser.add_argument('--verilator')
    parser.add_argument('--full-matrix',action='store_true',help='Also check six tree and seven rounding boundaries')
    args = parser.parse_args()
    output = args.build_dir.resolve()
    if output == PACKAGE or PACKAGE in output.parents:
        parser.error('Keep build output outside the distribution so file integrity remains checkable')
    output.mkdir(parents=True,exist_ok=True)
    for script in ['test_resource_plan.py','test_assess_timing.py']:
        subprocess.run([sys.executable,'-B',str(SKILL/'scripts'/script)],check=True)
    common = [sys.executable,'-B',str(SKILL/'scripts/run_examples.py'),
              '--mode',args.mode,'--backend',args.backend]
    if args.vivado_bin:
        common += ['--vivado-bin',str(args.vivado_bin)]
    if args.verilator:
        common += ['--verilator',args.verilator]
    subprocess.run(common+['--build-dir',str(output/'default')],check=True)
    if args.full_matrix:
        for count,width in [(1,2),(2,15),(3,4),(8,12),(17,8),(32,15)]:
            subprocess.run(common+['--example','tree','--tree-inputs',str(count),'--tree-width',str(width),
                                  '--build-dir',str(output/f'tree_n{count}_w{width}')],check=True)
        for in_width,out_width,fraction in [(2,2,0),(3,2,1),(8,4,0),(8,8,0),(9,3,8),(10,4,3),(12,6,5)]:
            subprocess.run(common+['--example','round','--round-in-width',str(in_width),
                                  '--round-out-width',str(out_width),'--round-fraction-bits',str(fraction),
                                  '--build-dir',str(output/f'round_i{in_width}_o{out_width}_f{fraction}')],check=True)



if __name__ == '__main__':
    main()
