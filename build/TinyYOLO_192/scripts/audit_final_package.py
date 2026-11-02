"""Audit the released project; board validation is a separate, explicit gate."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import struct

import audit_delivery as common

ROOT = Path(__file__).resolve().parents[1]
read = common.read
digest = common.digest
require = common.require
check_hashes = common.check_hashes


def save(name, value):
    (ROOT/name).write_text(json.dumps(value, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')


def configuration(path):
    data = path.read_bytes()
    offset = 2 + struct.unpack('>H', data[:2])[0]
    require(data[offset:offset+2] == b'\0\1', 'Invalid bitstream header')
    offset += 2
    for tag in b'abcde':
        require(data[offset] == tag, 'Invalid bitstream tag')
        offset += 1
        width = 4 if tag == ord('e') else 2
        size = int.from_bytes(data[offset:offset+width], 'big')
        offset += width
        payload = data[offset:offset+size]
        offset += size
    require(offset == len(data), 'Bitstream length differs')
    return payload


def regression_receipts():
    checks = []
    common.audit_synchronous_reset_distribution()
    correction = read('reports/lut64_format_correction.json')
    require(correction['status'] == 'PASS_LUT64_FORMAT_CORRECTION' and
            correction['full_truth_tables_exhaustively_checked'] and
            correction['applied_init_readback_checked_by_implementation_hook'] and
            correction['implementation_hook_sha256'] == digest(ROOT/'scripts/distribute_synchronous_reset.tcl') and
            correction['transformation_table_sha256'] == digest(ROOT/'reports/synchronous_reset_distribution.tsv'),
            'LUT64 correction does not match the implemented reset transformation')
    common.audit_control_guards()
    units = read('verification/rtl_units/result.json')
    check_hashes(units['source_sha256'], 'hardware/g227/rtl/')
    require(units['status'] == 'PASS_RTL_UNITS', 'RTL units did not pass')
    for item in units['suites']:
        top = item['top']
        require(item['status'] == 'PASS', 'RTL suite failed: '+top)
        require(digest(ROOT/'tests'/(top+'.sv')) == item['bench_sha256'] ==
                digest(ROOT/'verification/rtl_units'/(top+'.sv')), 'RTL bench identity differs')
        require(digest(ROOT/'verification/rtl_units'/(top+'.log')) == item['log_sha256'],
                'RTL log identity differs')
        log = common.read_log('verification/rtl_units/'+top+'.log').splitlines()
        require(all(log.count(marker) == 1 for marker in item['markers']), 'Missing RTL pass marker')
    current = read('verification/current_regressions.json')
    for label, item in current['receipts'].items():
        require(digest(ROOT/item['path']) == item['sha256'], 'Regression receipt identity differs')
        receipt = read(item['path'])
        prefix = 'hardware/g227/rtl/' if label == 'integration' else ''
        check_hashes(receipt['source_sha256'], prefix)
        if label == 'integration':
            require(receipt['status'] == 'PASS_QUALIFIED_DSP_INTEGRATION' and
                    receipt['post_route_simulation'] is False and receipt['board_tested'] is False,
                    'Integration result scope differs')
            check_hashes(receipt['test_sha256'], 'tests/')
            require(set(receipt['source_sha256']) == {p.name for p in (ROOT/'hardware/g227/rtl').glob('*.v')},
                    'Integration RTL inventory differs')
            require({s['suite'] for s in receipt['suites']} == {'head','features','parallel','closedloop'},
                    'Integration suite missing')
            folder = Path(item['path']).parent
            for suite in receipt['suites']:
                require(suite['status'] == 'PASS', 'Integration suite failed')
                log = common.read_log(str(folder/suite['suite']/(suite['suite']+'.log'))).splitlines()
                require(all(log.count(marker) == 1 for marker in suite['pass_marker']),
                        'Integration completion marker missing')
        else:
            require(receipt['status'] == 'PASS_SPLIT_DOT_PAIRS', 'DSP pair regression failed')
        checks.append(dict(receipt=item['path'], status=receipt['status'], source_identity='PASS'))
    for name, prefix, expected in (
        ('runs/requant36_stream/result.json','hardware/g227/rtl/','PASS_REQUANT36_STREAM'),
        ('verification/tracking_final_run04/result.json','','PASS_OFFLINE_TRACKING_CAMERA_PIPELINE'),
        ('verification/arm_tracking03/result.json','','PASS_OFFLINE_TRACKING_CAMERA_PIPELINE')):
        receipt = read(name)
        require(receipt['status'] == expected, 'Regression failed: '+name)
        check_hashes(receipt['source_sha256'], prefix)
        checks.append(dict(receipt=name, status=expected, source_identity='PASS'))
    save('reports/regression_identity_preflight.json', dict(
        status='PASS_CURRENT_SOURCE_REGRESSION_IDENTITIES', checks=checks,
        simulations_repeated=False, board_tested=False))
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-board-validation', action='store_true')
    args = parser.parse_args()
    frozen = read('reports/build_source_sha256.json')
    provenance = read('reports/finalization_provenance.json')
    require(digest(ROOT/'reports/build_source_sha256.json') == provenance['build_inventory_sha256'],
            'Original build inventory changed')
    differences = {name: dict(before_sha256=value, after_sha256=digest(ROOT/name))
                   for name, value in frozen.items() if digest(ROOT/name) != value}
    require(differences == provenance['changed_frozen_files'] == {},
            'Unrecorded change to frozen synthesis/implementation sources')
    require({p.relative_to(ROOT).as_posix() for p in (ROOT/'hardware').rglob('*') if p.is_file()} ==
            {name for name in frozen if name.startswith('hardware/')}, 'Hardware inventory changed')
    check_hashes(read('reports/delivery_source_sha256.json'))
    native = read('reports/native_implementation_process.json')
    require(provenance['status'] == 'PASS_CLOCKFIX_FINALIZATION' and
            provenance['native_implementation_receipt_sha256'] ==
            digest(ROOT/'reports/native_implementation_process.json') and
            provenance['placement_routing_repeated'] and provenance['synthesis_reused'] is False and
            provenance['implementation_netlist_corrected'] and
            provenance['rtl_changed_during_finalization'] is True and
            provenance['timing_constraints_changed'] is False and provenance['run_properties_forced'] is False,
            'Finalization provenance does not describe the corrected implementation')
    checkpoint = ROOT/'vivado/TinyYOLO_192.runs/impl_1/Tiny_Yolo_wrapper_postroute_physopt.dcp'
    require(native['status'] == 'PASS_NATIVE_IMPLEMENTATION_PROCESS' and native['vivado_exit_code'] == 0 and
            native['full_implementation_repeated'] and native['synthesis_reused'] is False and
            native['frozen_sources_verified_before_and_after'] and native['run_properties_forced'] is False and
            native['checkpoint_sha256'] == digest(checkpoint) == provenance['routed_checkpoint_sha256'],
            'Native implementation process/checkpoint identity is incomplete')
    run_dir = checkpoint.parent
    require(native['generated_script_sha256'] == digest(run_dir/'Tiny_Yolo_wrapper.tcl') and
            native['bit_sha256'] == digest(run_dir/'Tiny_Yolo_wrapper.bit') and
            (run_dir/'.vivado.end.rst').is_file() and
            (run_dir/'.write_bitstream.end.rst').is_file() and
            not (run_dir/'.vivado.error.rst').exists(),
            'Native implementation outputs or process markers differ')
    synthesis = read('reports/native_synthesis_process.json')
    synthesis_dir = ROOT/'vivado/TinyYOLO_192.runs/synth_1'
    require(synthesis['status'] == 'PASS_NATIVE_SYNTHESIS_PROCESS' and
            synthesis['vivado_exit_code'] == 0 and synthesis['full_synthesis_repeated'] and
            synthesis['frozen_sources_verified_before_and_after'] and
            synthesis['run_properties_forced'] is False and synthesis['source_sha256'] == frozen and
            synthesis['checkpoint_sha256'] == native['synthesis_checkpoint_sha256'] ==
                digest(synthesis_dir/'Tiny_Yolo_wrapper.dcp') and
            synthesis['generated_script_sha256'] == digest(synthesis_dir/'Tiny_Yolo_wrapper.tcl') and
            provenance['native_synthesis_receipt_sha256'] == digest(ROOT/'reports/native_synthesis_process.json') and
            (synthesis_dir/'.vivado.end.rst').is_file() and
            (synthesis_dir/'__synthesis_is_complete__').is_file() and
            not (synthesis_dir/'.vivado.error.rst').exists(),
            'Fresh synthesis checkpoint, source identity or native process completion differs')
    common.audit_reset_constraints()
    budget = read('reports/implementation_budget.json')
    require(budget['status'] == 'PASS_ORIGINAL_SETUP_BUDGET_RESTORED' and
            budget['scope'] == 'uncertainty_restoration_with_original_clock_topology' and
            budget['clock_mhz'] == 240 and budget['original_user_uncertainty_ns'] ==
            budget['restored_user_uncertainty_ns'] == 0 and budget['clock_topology_preserved'],
            'Original timing constraints were not restored')
    replication = read('reports/critical_data_replication.json')
    require(replication['status'] == 'PASS_TIMING_DRIVEN_DATA_OPTIMIZATION' and
            replication['phase'] == 'post_place_pre_route' and replication['forced_candidate_data_nets'] == 0 and
            replication['added_pipeline_cycles'] == 0 and
            replication['clock_topology_preserved'] and replication['path_exceptions_changed'] is False,
            'Timing-driven data optimization was not performed before routing')
    repair = read('reports/timing_repair_provenance.json')
    require(repair['status'] == 'PASS_CLOCKFIX_IMPLEMENTATION' and
            repair['native_implementation_receipt_sha256'] ==
            digest(ROOT/'reports/native_implementation_process.json') and
            repair['clock_topology_receipt_sha256'] == digest(ROOT/'reports/clock_topology.json') and
            repair['clock_mhz'] == 240 and repair['rtl_changed'] is True and
            repair['timing_constraints_changed'] is False and
            set(repair['changed_rtl_sources']) == {'hardware/g227/rtl/tinyyolo_dot24_pair.v',
                'hardware/g227/rtl/tinyyolo_hp0_burst_cache.v'} and
            repair['added_pipeline_cycles'] == 0 and repair['cascaded_bufg'] is False and
            all(item['after_sha256'] == digest(ROOT/name)
                for name, item in repair['changed_build_sources'].items()),
            'Timing repair provenance differs')
    for name in ('project_open.json','project_portability.json'):
        opened = read('reports/'+name)
        require(opened['all_active_sources_local'] and opened['synthesis'] == 'synth_design Complete!' and
                opened['implementation'] == 'write_bitstream Complete!' and
                opened['pre_opt_hook_in_utils'] and opened['post_place_hook_in_utils'] and
                opened['cleanup_dependency_local'] and opened['clock_topology_checked'] and
                opened['cascaded_bufg'] is False, 'Project open/relocation check failed')
    regressions = regression_receipts()
    model = read('linux/model_config.json')
    require(model['input_size'] == 192 and model['mac_lanes'] == 24 and model['positions'] == 180 and
            model['parameters_sha256'] == digest(ROOT/'model/parameters.bin'), 'Model identity differs')
    require(read('linux/pan_tilt.json')['enabled'] is False, 'Default physical PWM is enabled')
    require('-Wno-' not in (ROOT/'linux/Makefile').read_text(), 'Compiler warnings are disabled')
    artifacts = read('reports/artifact_sha256.json')
    for name, item in artifacts.items():
        require((ROOT/name).stat().st_size == item['bytes'] and digest(ROOT/name) == item['sha256'],
                'Artifact identity differs: '+name)
    common.audit_firmware_payload()
    require(configuration(ROOT/'firmware/final_192.bit') ==
            configuration(ROOT/'vivado/TinyYOLO_192.runs/impl_1/Tiny_Yolo_wrapper.bit'),
            'Native implementation and exported firmware configuration differ')
    implementation = read('reports/implementation.json')
    closure = read('reports/timing_closure.json')
    require(implementation['status'] == 'BUILT' and implementation['clock_mhz'] == 240 and
            closure['status'] == 'PASS_TIMING_CLOSURE' and closure['timing_constraints_met'] and
            closure['negative_slack_allowed'] is False and
            closure['minimum_setup_margin_target_ns'] == 0.0 and
            closure['setup_ns'] == implementation['setup_ns'] >= 0 and
            closure['hold_ns'] == implementation['hold_ns'] >= 0 and closure['minimum_bus_skew_ns'] >= 0,
            'Final timing signoff failed')
    topology = read('reports/clock_topology.json')
    require(topology['status'] == 'PASS_ORIGINAL_CLOCK_TOPOLOGY' and topology['clock_mhz'] == 240 and
            topology['clock_period_unchanged'] and topology['user_uncertainty_ns'] == 0 and
            topology['bufg_count'] == 3 and topology['cascaded_bufg'] is False and
            topology['pl_bufg_direct_mmcm_clkout0'] and topology['path_exceptions_changed'] is False and
            topology['warning_suppression'] is False,
            'Original clock network was not preserved')
    clock_rows = (ROOT/'reports/clock_topology_buffers.tsv').read_text().splitlines()
    require(len(clock_rows) == 4 and all('\tBUFG\t' in row for row in clock_rows[1:]) and
            any(row.startswith('Tiny_Yolo_i/pl_clk/inst/clkout1_buf\tBUFG\t') and
                '/CLKOUT0\t' in row for row in clock_rows) and
            not any('clkout1_buf_replica' in row for row in clock_rows),
            'Clock primitive connectivity evidence missing')
    timing = common.read_log('reports/timing.rpt')
    require('all user specified timing constraints are met.' in timing.lower(), 'Timing summary failed')
    summary = re.search(r'^\s*WNS\(ns\).*?\n[^\n]+\n([^\n]+)', timing, re.M)
    require(summary is not None, 'Missing global timing summary')
    values = summary[1].split()
    require(len(values) == 12 and all(float(values[i]) >= 0 for i in (0,4,8)) and
            all(float(values[i]) == 0 for i in (1,2,5,6,9,10)), 'Global timing violation remains')
    clock = re.search(r'^\s*clk_out1_Tiny_Yolo_pl_clk_0\s+\{[^}]+\}\s+([\d.]+)\s+([\d.]+)\s*$',timing,re.M)
    require(clock is not None and abs(float(clock[1])-1000/240) < .001 and abs(float(clock[2])-240) < .001,
            'Implemented accelerator clock is not 240 MHz')
    checks = re.findall(r'^\d+\.\s+checking\s+(\w+)\s+\((\d+)\)\s*$',
                        common.read_log('reports/check_timing.rpt'), re.M)
    require(len(checks) >= 12 and all(int(count) == 0 for _,count in checks), 'Invalid/unconstrained timing')
    report_audit = common.audit_implementation_reports()
    require(report_audit['bus_skew_met'], 'Bus skew constraint failed')
    errors = [item for item in report_audit['report_diagnostics']
              if item['severity'].lower() in ('error', 'critical', 'critical warning')]
    diagnostics = [item for item in report_audit['report_diagnostics'] if item not in errors]
    logs = ['vivado/TinyYOLO_192.runs/synth_1/runme.log',
            'vivado/TinyYOLO_192.runs/impl_1/runme.log',
            'reports/final_export.log','reports/synthesis_diagnostics_final.log',
            'reports/project_open_check.log','reports/project_portability_check.log']
    intermediate_timing_critical = []
    for name in logs:
        lines = common.read_log(name).splitlines()
        restore_lines = [index for index, line in enumerate(lines,1)
                         if line.startswith('ORIGINAL_SETUP_BUDGET_RESTORED ')]
        final_pass = any(line.startswith('FINAL_TIMING_CLOSURE_PASS ') for line in lines)
        for number, line in enumerate(lines,1):
            match = re.match(r'^(WARNING|CRITICAL WARNING|ERROR): \[([^]]+)\] (.*)',line)
            if match:
                item = dict(file=name,line=number,severity=match[1],id=match[2],message=match[3],
                            timing=match[2] in common.TIMING_WARNING_IDS)
                # Native intermediate reports run before the +0.250 ns
                # optimization budget is restored. Keep their original
                # severity and text; they cannot stand in for final signoff.
                intermediate = (name == 'vivado/TinyYOLO_192.runs/impl_1/runme.log' and
                    match[1] == 'CRITICAL WARNING' and match[2] == 'Timing 38-282' and
                    len(restore_lines) == 1 and number < restore_lines[0] and final_pass)
                if intermediate:
                    item['phase'] = 'stricter_intermediate_implementation_budget'
                    intermediate_timing_critical.append(item)
                    diagnostics.append(item)
                else:
                    (errors if match[1] in ('ERROR','CRITICAL WARNING') else diagnostics).append(item)
    policy = (ROOT/'scripts/message_policy.tcl').read_text()
    rules = [line for line in policy.splitlines() if line.startswith('set_msg_config ')]
    require(all('-id ' in line and '-string ' in line and '-suppress' not in line for line in rules),
            'Broad message suppression found')
    non_timing = [item for item in diagnostics if not item['timing']]
    # Clock connectivity warnings have no exemption. Exact benign vendor
    # INFO classifications remain disclosed; new diagnostics must be fixed.
    require('PLBUFGOPT-1' not in policy, 'Clock DRC message policy must stay at its default severity')
    unresolved_non_timing = non_timing
    save('reports/warning_audit.json',dict(errors=errors,non_timing_warnings=non_timing,
         timing_warnings=[item for item in diagnostics if item['timing']],current_logs=logs,
         unresolved_non_timing_warnings=unresolved_non_timing,
         intermediate_timing_critical_warnings=intermediate_timing_critical,
         exact_info_classification_rules=len(rules),warning_suppression=False))
    require(not errors and not unresolved_non_timing,
            'Unresolved errors or non-timing warnings; see warning_audit.json')
    scope = read('verification/validation_scope.json')
    require(scope['final_firmware_board_tested'] is False and scope['camera_tested_on_final_firmware'] is False,
            'Unexpected final board acceptance claim')
    result = dict(status='PASS_PACKAGE_PENDING_BOARD_VALIDATION',
        checked_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        part='xc7z020clg484-1',input_size=192,mac_lanes=24,clock_mhz=240,
        setup_ns=float(values[0]),hold_ns=float(values[4]),pulse_width_ns=float(values[8]),
        minimum_bus_skew_ns=closure['minimum_bus_skew_ns'],timing_met=True,
        minimum_setup_margin_target_ns=0.0,errors=0,critical_warnings=0,
        non_timing_warnings=len(non_timing),retained_non_timing_warning_rules=[],
        unresolved_non_timing_warnings=0,
        timing_warning_instances=sum(item['timing'] for item in diagnostics),
        exact_info_classification_rules=len(rules),
        intermediate_timing_critical_warning_instances=len(intermediate_timing_critical),
        build_source_identity='PASS',regression_source_identity='PASS',regressions=regressions,
        board_tested=False,camera_tested=False,physical_target_tracking_accepted=False,
        physical_servo_tested=False,artifacts=artifacts)
    save('reports/delivery_audit.json',result)
    print(json.dumps(result,indent=2))
    if args.require_board_validation:
        raise RuntimeError('Final firmware board validation is pending; package audit passed only.')


if __name__ == '__main__':
    main()
