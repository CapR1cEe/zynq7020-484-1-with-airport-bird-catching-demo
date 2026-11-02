#!/usr/bin/env python3
"""Summarize a Vivado min/max timing report without upgrading it to signoff."""
import argparse
import json
import math
from pathlib import Path
import re

REQUIRED_CHECKS = ('no_clock', 'constant_clock', 'unconstrained_internal_endpoints',
                   'no_input_delay', 'no_output_delay', 'multiple_clock', 'loops',
                   'partial_input_delay', 'partial_output_delay')


def assess(text, context='unknown'):
    if context not in ('unknown', 'ooc', 'integrated'):
        raise ValueError('context must be unknown, ooc or integrated')
    result = {'status': 'incomplete', 'context': context, 'signoff': False,
              'metrics': {}, 'check_timing': {}, 'failures': [], 'incomplete_reasons': [],
              'remaining_review': ['Clock/CDC relationships, DRC, methodology, exceptions and constraint intent',
                                   'Physical IO/clock context, path details and application/board behavior']}
    header = re.search(r'^\s*WNS\(ns\).*WPWS\(ns\).*$', text, re.M)
    row = None
    expected_header = ('WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints '
                       'WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints '
                       'WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints')
    if header and ' '.join(header.group().split()) == expected_header:
        for line in text[header.end():].splitlines()[:5]:
            fields = line.split()
            if fields and re.fullmatch(r'-?\d+(?:\.\d+)?|N/A', fields[0]):
                row = fields
                break
    if row is None or len(row) != 12:
        result['incomplete_reasons'].append('No supported 12-column min/max summary row')
    else:
        for name, index in [('wns_ns',0),('tns_ns',1),('whs_ns',4),('ths_ns',5),('wpws_ns',8),('tpws_ns',9)]:
            try:
                value = float(row[index])
                if not math.isfinite(value):
                    raise ValueError('nonfinite')
                result['metrics'][name] = value
                if value < 0:
                    result['failures'].append(f'{name} is negative: {value}')
            except ValueError:
                result['metrics'][name] = None
                result['incomplete_reasons'].append(f'{name} not measured')
        for name, index in [('setup_failing_endpoints',2),('hold_failing_endpoints',6),('pulse_failing_endpoints',10)]:
            try:
                value = int(row[index])
                if value < 0:
                    raise ValueError('negative endpoint count')
                result['metrics'][name] = value
                if value:
                    result['failures'].append(f'{name}: {value}')
            except ValueError:
                result['incomplete_reasons'].append(f'{name} unavailable')
    state = re.search(r'^\|\s*Design State\s*:\s*(.*?)\s*$', text, re.M)
    result['design_state'] = state.group(1) if state else None
    if not state or not re.fullmatch(r'(Fully )?Routed', state.group(1), re.I):
        result['incomplete_reasons'].append('Routed design state not established')
    for name in REQUIRED_CHECKS:
        counts = re.findall(r'checking\s+'+name+r'\s+\((\d+)\)',text)
        if not counts:
            result['incomplete_reasons'].append(f'check_timing {name} absent')
            result['check_timing'][name] = None
        else:
            value = max(map(int,counts))
            result['check_timing'][name] = value
            if value:
                result['failures'].append(f'check_timing {name}: {value}')
    if context != 'integrated':
        result['incomplete_reasons'].append('Integrated clock/IO context not established')
    if result['failures']:
        result['status'] = 'timing_fail'
    elif not result['incomplete_reasons']:
        result['status'] = 'summary_pass_review_remaining'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--context', choices=['unknown','ooc','integrated'], default='unknown',
                        help='Caller-supplied scope, not inferred proof of integration')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = assess(args.report.read_text(encoding='utf-8',errors='replace'),args.context)
    rendered = json.dumps(result,indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(rendered,encoding='utf-8')
    print(rendered,end='')
    return {'summary_pass_review_remaining':0,'timing_fail':1,'incomplete':2}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
