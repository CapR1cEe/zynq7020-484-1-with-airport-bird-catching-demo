"""Independently audit the downloaded 192x192 board receipts; no board access."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import statistics
import sys

sys.dont_write_bytecode = True


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def log_text(path):
    data = path.read_bytes()
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    return data.decode(encoding, errors='replace')


def hashes(path):
    return {line.split(None, 1)[1].lstrip('*'): line.split(None, 1)[0].lower()
            for line in path.read_text().splitlines() if line}


def stats(values):
    return dict(mean=statistics.mean(values), median=statistics.median(values),
                minimum=min(values), maximum=max(values), samples=len(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--write-result', action='store_true', help='Save a new result.json after a successful audit')
    args = parser.parse_args()
    root = args.evidence.resolve()
    g = root/'raw_golden'
    c = root/'raw_camera'
    prov = root/'provenance'
    prep = read(root/'04_preparation.json')
    expected = read(root/'expected_192.json')
    board = read(g/'result.json')
    hardware = expected['hardware']
    require(sha(root/'initial_evidence.tgz') == '48dd621093cf99e144dcb750864c01a20da33a62dc7571820fba42ae389fba77',
            'Golden archive hash mismatch')
    require(sha(root/'camera_evidence.tgz') == '4f758287903a32fa632bb99ed443a82e4042b4814f7ce9d35b2410ba380f9749',
            'Camera archive hash mismatch')
    require(sha(root/'expected_192.json') == sha(g/'expected.json') == prep['expected_sha256'],
            'Uploaded goldens differ from local qualified goldens')
    require(sha(prov/'artifact_manifest.json') == prep['candidate_manifest_sha256'] and
            read(prov/'artifact_manifest.json')['file_count'] == prep['candidate_manifest_files'] == 71,
            'Candidate provenance mismatch')
    require(read(prov/'implementation.json') == prep['offline_implementation'] and
            sha(prov/'reference_manifest.json') == expected['host_reference_manifest_sha256'],
            'Implementation or CPU reference provenance mismatch')
    require(hardware == prep['hardware'] == board['hardware'] and
            expected['input_contract']['shape'] == [3, 192, 192], 'Hardware or model mismatch')
    require(board['status'] == 'PASS_LINUX_24_LAYER_AND_PRODUCTION' and
            board['step_hash_comparisons'] == 150 and board['convolution_hash_comparisons'] == 72 and
            board['input_check'] == prep['input_check'], 'Board validation incomplete')
    spec = importlib.util.spec_from_file_location('sealed_qualifier', prov/'qualify_fast_board.py')
    qualifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qualifier)
    smoke = board['smoke']
    require(smoke == read(g/'smoke.json') and smoke['status'] == 'PASS_LINUX_DRIVER_SMOKE' and
            smoke['abi'] == 2 and smoke['build_id'] == hardware['build_id'] and
            smoke['pl_hz'] == 240000000 and abs(smoke['fclk_hz']-100000000) <= 10000 and
            smoke['faulted'] == 0 and smoke['exclusive_open'] == 'PASS_EBUSY' and
            smoke['invalid_descriptor'] == 'PASS_EINVAL', 'Driver smoke mismatch')
    step_count = conv_count = 0
    require(set(board['trace_frames']) == set(expected['frames']) == {'bird', 'random', 'bird_repeat'},
            'Missing golden case')
    for name, golden in expected['frames'].items():
        actual = board['trace_frames'][name]
        require(actual['status'] == 'PASS_50_STEPS_24_CONVOLUTIONS' and
                len(actual['steps']) == len(golden['steps']) == 50 and
                actual['final_sha256'] == golden['final_sha256'], 'Incomplete graph: '+name)
        qualifier.frame_metrics(actual['metrics'], hardware)
        require(actual['metrics'] == read(g/(name+'.0001.metrics.json')), 'Trace metrics mismatch')
        require([x['layer'] for x in golden['steps'] if x['kind'] in (4, 5)] == list(range(24)),
                'Convolution step sequence differs')
        for received, wanted in zip(actual['steps'], golden['steps']):
            require(received['status'] == 'PASS_SHA256_EQUAL' and
                    all(received[k] == v for k, v in wanted.items()), 'Graph step hash mismatch')
            step_count += 1
            conv_count += int(wanted['kind'] in (4, 5))
        final = g/(name+'.0001.final.bin')
        require(final.stat().st_size == 3600 and sha(final) == golden['final_sha256'],
                'Golden final tensor mismatch')
    require(step_count == 150 and conv_count == 72, 'Comparison count mismatch')
    require(len(board['production']) == 8, 'Missing production repetitions')
    for index, frame in enumerate(board['production'], 1):
        qualifier.frame_metrics(frame, hardware)
        require(frame == read(g/('production.%04d.metrics.json' % index)) and
                frame['frame'] == index and frame['trace_enabled'] is False and
                frame['cpu_lookup_cache'] == 'cached_ram' and frame['cpu_lookup_cache_bytes'] == 9616,
                'Production metrics or cache scope mismatch')
        final = g/('production.%04d.final.bin' % index)
        require(final.stat().st_size == 3600 and sha(final) == expected['frames']['bird']['final_sha256'],
                'Production output differs from golden')
    warm = [x['elapsed_ms'] for x in board['production'][1:]]
    require(board['warm_frame_ms'] == dict(samples=len(warm), min=min(warm), max=max(warm),
                                         mean=statistics.mean(warm)), 'Warm timing receipt mismatch')
    detection = qualifier.sequence(c/'camera120', hardware['build_id'], 192, 180, tracking=False)
    rows = [json.loads(x) for x in (c/'camera120/frames.jsonl').read_text().splitlines() if x]
    require(all(x['target'] is None and x['control'] == {'enabled': False} and
                x['detection']['input_dtype'] == 'int8' and
                x['detection']['preprocessing']['network_size'] == [192, 192] for x in rows),
            'Camera mode or control scope mismatch')
    dimensions = sorted({(x['camera']['width'], x['camera']['height']) for x in rows})
    post = read(c/'post_device.json')
    require(post == read(g/'programmed_device.json') and post['faulted'] == 0 and
            read(c/'post_processes.json')['active_inference_processes'] == [],
            'Device fault, identity change or leftover process')
    runtime_sha = hashes(c/'post_runtime_sha256.txt')
    require(all(runtime_sha[k] == v for k, v in hashes(g/'runtime_sha256.txt').items()),
            'Runtime changed during validation')
    require(runtime_sha['parameters.bin'] == expected['inputs']['parameters.bin']['sha256'] ==
            prep['source_files']['parameters.bin'], 'Model parameter SHA mismatch')
    for name in ('camera_stream', 'camera_capture', 'libtinyyolo_tracker.so'):
        require(runtime_sha[name] == prep['reused_native_files'][name]['sha256'], 'Native module mismatch')
    require(list(hashes(c/'post_driver_sha256.txt').values()) == [prep['reused_kernel_module']['sha256']],
            'Kernel module changed')
    require(all(prep['source_files'][k] == v for k, v in hashes(c/'post_sources_sha256.txt').items()),
            'Camera runtime sources changed')
    jtag = (root/'08_program_candidate.log').read_text(errors='replace')
    require('TY_JTAG_PROGRAM_COMPLETE' in jtag and hardware['bit_sha256'] in jtag and
            re.search(r'REGISTER.CONFIG_STATUS.BIT14_DONE_PIN\s+string\s+true\s+1\b', jtag) and
            re.search(r'REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR\s+string\s+true\s+0\b', jtag),
            'JTAG configuration receipt incomplete')
    serial = log_text(root/'18_serial_restore.log')
    final_console = log_text(root/'19_final_console_check.log')
    require('SERIAL_SPEED_PASS baud=115200' in serial and 'TY_FINAL_CONSOLE_PASS' in final_console and
            all(name+': OK' in final_console for name in ('/opt/tinyyolo/parameters.bin',
                  '/opt/tinyyolo/tinyyolo_linux', '/opt/tinyyolo/tinyyolo_dma.ko')),
            'Console restore or original deployment verification missing')
    layers = board['production'][1]['layers']
    total_cycles = sum(x['cycles'] for x in layers)
    ranked = [dict(layer=x['layer'], cycles=x['cycles'], milliseconds=x['cycles']/240000,
                   percent_of_pl_cycles=100*x['cycles']/total_cycles)
              for x in sorted(layers, key=lambda x: x['cycles'], reverse=True)]
    detection.update(actual_capture_dimensions=[list(x) for x in dimensions],
                     requested_capture_dimensions=[320, 240],
                     actual_fourcc=sorted({x['camera']['fourcc'].to_bytes(4, 'little').decode('ascii') for x in rows}),
                     total_boxes=sum(len(x['detection']['detections']) for x in rows),
                     per_frame_outputs_saved=False, per_frame_layer_metrics_saved=False,
                     network_ms=stats([x['detection']['network_ms'] for x in rows]),
                     frame_total_ms=stats([x['elapsed_ms']['total'] for x in rows]),
                     capture_ms=stats([x['elapsed_ms']['capture'] for x in rows]),
                     preprocess_ms=stats([x['detection']['elapsed_ms']['preprocess'] for x in rows]),
                     runtime_process_ms=stats([x['detection']['elapsed_ms']['runtime_process'] for x in rows]),
                     decode_nms_ms=stats([x['detection']['elapsed_ms']['decode_nms'] for x in rows]))
    fps = detection['detection_fps']
    status = 'PASS_BOARD_15FPS' if fps >= 15 else 'PASS_BOARD_5FPS' if fps >= 5 else 'BOARD_VERIFIED_FPS_BELOW_TARGET'
    record = dict(status=status,
        audit_time=datetime.now(timezone(timedelta(hours=8))).isoformat(),
        board_tested=True, functional_validation_passed=True, camera_tested=True,
        camera_short_sequence_passed=True, minimum_detection_5fps_pass=fps >= 5,
        stretch_detection_15fps_pass=fps >= 15, input_size=192, positions=180, mac_lanes=24,
        hardware=hardware, runtime_sha256=runtime_sha, post_device=post,
        golden=dict(step_hash_comparisons=step_count, convolution_hash_comparisons=conv_count,
                    trace_cases=3, production_repetitions=8, production_outputs_equal=True,
                    production_elapsed_ms=[x['elapsed_ms'] for x in board['production']],
                    warm_frame_ms=stats(warm), cpu_lookup_cache='cached_ram', cpu_lookup_cache_bytes=9616),
        detection=detection,
        bottleneck=dict(source='golden production frame 2, 24 per-layer PL counters',
                        pl_cycles=total_cycles, pl_milliseconds=total_cycles/240000,
                        layers_by_cycles=ranked),
        deployment=dict(mode='temporary JTAG and tmpfs',
                        board_directory='/dev/shm/ty192_validation_20261025_run01',
                        persistent_deployment_changed=False, startup_files_changed=False,
                        serial_port='COM5', final_baud=115200, active_inference_processes=[]),
        accuracy_map=None, thermal_qualified=False, power_measured=False,
        tracking_tested=False, physical_pan_tilt_tested=False,
        clock_note='Board RTC is 2016; host audit date and monotonic duration are used.',
        provenance=dict(candidate_manifest_files=71, candidate_manifest_sha256=prep['candidate_manifest_sha256'],
                        offline_implementation=prep['offline_implementation'],
                        source_sha256={name: sha(root/name) for name in
                            ('04_preparation.json', 'expected_192.json', 'initial_evidence.tgz', 'camera_evidence.tgz',
                             'raw_golden/result.json', 'raw_camera/post_device.json',
                             'provenance/reference_manifest.json', 'provenance/qualify_fast_board.py')},
                        audit_generator_sha256=sha(Path(__file__))))
    if args.write_result:
        (root/'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(status=record['status'], step_hash_comparisons=step_count,
                         convolution_hash_comparisons=conv_count,
                         camera=detection, driver_faulted=post['faulted']), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
