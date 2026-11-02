#!/usr/bin/env python3
"""Calculate necessary II bounds; this is not a scheduler or FPGA mapper."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import sys


def positive_int(value, name):
    if type(value) is not int or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value


def nonnegative_int(value, name):
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")
    return value


def ratio(value, name):
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a positive finite number")
    try:
        result = Fraction(str(value))
    except (ValueError, ZeroDivisionError):
        raise ValueError(f"{name} must be a positive finite number") from None
    if result <= 0:
        raise ValueError(f"{name} must be positive")
    return result


def ceiling(value):
    return -(-value.numerator // value.denominator)


def plan(contract):
    frequency = ratio(contract['target_frequency_mhz'], 'target_frequency_mhz')
    required = positive_int(contract['required_ii_cycles'], 'required_ii_cycles')
    candidates = contract['candidates']
    if not isinstance(candidates, list) or not candidates:
        raise ValueError('candidates must be a nonempty list')
    caps = contract.get('resource_caps', {})
    for resource, cap in caps.items():
        nonnegative_int(cap, f'resource_caps.{resource}')
    output = []
    for candidate in candidates:
        name = candidate['name']
        if not isinstance(name, str) or not name:
            raise ValueError('candidate name must be nonempty text')
        bounds = []
        resources = {}
        for group in candidate.get('operators', []):
            operations = positive_int(group['operations_per_token'], 'operations_per_token')
            instances = positive_int(group['instances'], 'instances')
            initiation = positive_int(group['operator_ii_cycles'], 'operator_ii_cycles')
            bounds.append({'kind': 'operator', 'name': group['name'],
                           'ii_cycles': ceiling(Fraction(operations * initiation, instances))})
            for resource, count in group.get('estimated_resources_per_instance', {}).items():
                nonnegative_int(count, f'{group["name"]}.{resource}')
                resources[resource] = resources.get(resource, 0) + instances * count
        for recurrence in candidate.get('recurrences', []):
            latency = positive_int(recurrence['feedback_latency_cycles'], 'feedback_latency_cycles')
            distance = positive_int(recurrence['dependence_distance'], 'dependence_distance')
            bounds.append({'kind': 'recurrence', 'name': recurrence['name'],
                           'ii_cycles': ceiling(Fraction(latency, distance))})
        for transfer in candidate.get('transfers', []):
            amount = ratio(transfer['bytes_per_token'], 'bytes_per_token')
            if 'effective_bytes_per_cycle' in transfer and 'effective_bytes_per_second' in transfer:
                raise ValueError('provide one effective capacity unit per transfer, not both')
            if 'effective_bytes_per_cycle' in transfer:
                capacity = ratio(transfer['effective_bytes_per_cycle'], 'effective_bytes_per_cycle')
            else:
                capacity = ratio(transfer['effective_bytes_per_second'], 'effective_bytes_per_second')
                capacity /= frequency * 1_000_000
            bounds.append({'kind': 'transfer', 'name': transfer['name'],
                           'ii_cycles': ceiling(amount / capacity)})
        for resource, count in candidate.get('estimated_fixed_resources', {}).items():
            nonnegative_int(count, f'estimated_fixed_resources.{resource}')
            resources[resource] = resources.get(resource, 0) + count
        lower = max([1] + [x['ii_cycles'] for x in bounds])
        exceeded = {r: {'estimated': resources[r], 'cap': cap}
                    for r, cap in caps.items() if r in resources and resources[r] > cap}
        output.append({
            'name': name,
            'necessary_ii_lower_bound_cycles': lower,
            'required_ii_not_ruled_out_by_bounds': lower <= required,
            'binding_bounds': [b for b in bounds if b['ii_cycles'] == lower],
            'all_bounds': bounds,
            'partial_estimated_resources': resources,
            'estimated_cap_violations': exceeded,
            'unestimated_capped_resources': sorted(set(caps) - set(resources)),
            'throughput_upper_bound_tokens_per_second': float(frequency * 1_000_000 / lower),
            'implementation_feasibility': 'unproven',
        })
    return {
        'schema_version': 1,
        'target_frequency_mhz': float(frequency),
        'target_period_ns': float(1000 / frequency),
        'required_ii_cycles': required,
        'required_rate_tokens_per_second': float(frequency * 1_000_000 / required),
        'candidates': output,
        'limitations': [
            'Necessary average bounds only; no schedule, banking-conflict, placement or timing proof.',
            'Combine all operations sharing an operator pool before calculating its bound.',
            'Transfer capacities must already account for port sharing, burst efficiency and contention.',
            'Resource figures are caller-supplied partial estimates, not synthesis measurements.',
            'Clock target and upper-bound throughput are not achieved implementation performance.',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('contract', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = plan(json.loads(args.contract.read_text(encoding='utf-8-sig')))
        data = json.dumps(result, indent=2, allow_nan=False) + '\n'
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(data, encoding='utf-8')
        print(data, end='')
    except (ValueError, TypeError, KeyError, OSError) as error:
        parser.exit(2, f'resource_plan: {error}\n')


if __name__ == '__main__':
    main()
