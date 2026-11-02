"""Audit current physical-camera FPS separately from tracking output FPS.

Run after current-build offline acceptance and physical board validation.
This reads receipts only; it never programs, resets or writes to the board.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value, name, positive=False):
    require(type(value) in (float, int) and math.isfinite(value) and
            (value > 0 if positive else value >= 0), 'Invalid '+name)
    return value


def frame_metrics(frame, hardware):
    require(frame['status']=='PASS_LINUX_PL_FRAME' and frame['pl_calls']==24 and
            frame['pl_hz']==hardware['pl_MHz']*1000000 and
            abs(frame['fclk_hz']-hardware['fclk_MHz']*1000000)<=10000,
            'Frame clock or convolution count mismatch')
    layers=frame['layers']
    require(len(layers)==24 and [x['layer'] for x in layers]==list(range(24)) and
            all(x['hp_idle']==1 and number(x['cycles'],'PL cycles',True)>0 for x in layers),
            'Missing layer, stalled HP port or invalid cycle counter')


def sequence(directory, build, size, positions, tracking=False):
    summary=read(directory/'summary.json')
    require(summary['status']=='PASS_CAMERA_SEQUENCE' and
            summary['board_measurement'] is True and not summary.get('test_doubles') and
            summary['build_id']==build and summary['input_size']==size and
            summary['positions']==positions, 'Camera source, scope or build mismatch')
    rows=[json.loads(line) for line in (directory/'frames.jsonl').read_text().splitlines() if line]
    frames=[x for x in rows if 'frame' in x]
    count=summary['capture_frames']
    require(type(count) is int and count>=(450 if tracking else 120) and
            [x['frame'] for x in frames]==list(range(1,count+1)), 'Incomplete camera sequence')
    detections=[]; camera_sequences=set(); tracked=0; total_ms=0
    for row in rows:
        if 'frame' not in row:
            require(tracking and set(row)=={'final_background_detection'}, 'Unexpected camera record')
            detections.append(row['final_background_detection'])
            continue
        camera=row['camera']
        require(type(camera['sequence']) is int and camera['sequence'] not in camera_sequences and
                0<camera['width']<=4096 and 0<camera['height']<=4096 and
                number(camera['host_dequeue_us'],'camera dequeue timestamp',True)>0,
                'Missing physical capture metadata or repeated frame')
        camera_sequences.add(camera['sequence'])
        total_ms+=number(row['elapsed_ms']['total'],'camera total')
        require(row['elapsed_ms']['total']>=number(row['elapsed_ms']['capture'],'capture time'),
                'Camera total excludes capture')
        tracked+=int(row['target'] is not None)
        detection=row['detection']
        if detection is not None:
            require(detection['frame_id']<=row['frame'] and
                    (tracking or detection['frame_id']==row['frame']), 'Detection frame mismatch')
            detections.append(detection)
        elif not tracking:
            raise ValueError('Synchronous camera frame has no detection')
    ids=[x['frame_id'] for x in detections]
    require(ids==sorted(set(ids)) and all(type(x) is int and 1<=x<=count for x in ids),
            'Duplicated, reordered or invalid detection')
    completed=summary['completed_detections']
    require(type(completed) is int and completed==len(detections) and 0<completed<=count and
            (tracking or completed==count), 'Detection completion count mismatch')
    runtime=(directory/'sequence.runtime.log').read_text(errors='replace')
    ready=re.findall(r'^READY_TINYYOLO_INPUT (\{[^\n]+\})$',runtime,re.M)
    require(len(ready)==1, 'Missing unique runtime identity')
    identity=json.loads(ready[0])
    require(identity['build_id']==int(build,16) and identity['input_size']==size and
            identity['positions']==positions and identity['mode']=='dma-int8' and
            identity['input_bytes']==3*size*size and identity['output_bytes']==5*positions*4,
            'Camera runtime build or DMA mapping mismatch')
    acks=re.findall(r'^PASS_LINUX_PL_FRAME frame=(\d+) elapsed_ms=(\d+) '
                    r'PL_convolutions=24 HP_idle=1$',runtime,re.M)
    require([int(x[0]) for x in acks]==list(range(1,completed+1)) and
            [int(x[1]) for x in acks]==summary['network_ms']==[x['network_ms'] for x in detections],
            'Missing or inconsistent runtime acknowledgements')
    require(not re.search(r'(?im)^(?:Linux inference failed|FATAL|ERROR|FAIL)\b',runtime),
            'Runtime failure in camera sequence')
    for detection in detections:
        elapsed=number(detection['elapsed_ms']['total'],'detection total')
        duration=number(detection['completed_at'],'completion time')-number(
            detection['submitted_at'],'submission time')
        require(abs(duration*1000-elapsed)<=0.001 and
                elapsed>=number(detection['elapsed_ms']['runtime_process'],'runtime process time'),
                'Detection timing omits work or timestamp differs')
    duration=number(summary['duration_seconds'],'sequence duration',True)
    require(duration*1000+0.001>=total_ms, 'FPS duration excludes frame work')
    fps=completed/duration; tracking_fps=tracked/duration
    require(summary['successful_tracking_updates']==tracked and
            math.isclose(summary['detection_fps'],fps,rel_tol=1e-9) and
            math.isclose(summary['tracking_output_fps'],tracking_fps,rel_tol=1e-9) and
            math.isclose(summary['capture_loop_fps'],count/duration,rel_tol=1e-9),
            'FPS counters differ from raw frame records')
    require(summary['detection_5fps_pass']==(fps>=5) and
            summary['detection_15fps_pass']==(fps>=15) and
            summary['tracking_15fps_pass']==(tracking and tracking_fps>=15), 'FPS flag mismatch')
    return dict(capture_frames=count,completed_detections=completed,duration_seconds=duration,
        detection_fps=fps,tracking_output_fps=tracking_fps,startup_ms=number(summary['startup_ms'],'startup'),
        full_camera_mean_ms=duration*1000/completed,overlay_saved=summary['overlay_saved'],
        source_sha256={n:sha(directory/n) for n in ('summary.json','frames.jsonl','sequence.runtime.log')})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline',type=Path,required=True,help='Current offline acceptance result.json')
    parser.add_argument('--expected',type=Path,required=True,help='Current board kit expected.json')
    parser.add_argument('--validation',type=Path,required=True,help='Physical board golden result.json')
    parser.add_argument('--detection',type=Path,required=True,help='120+ synchronous live frames directory')
    parser.add_argument('--tracking',type=Path,required=True,help='450+ live tracking frames directory')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    offline=read(args.offline);expected=read(args.expected);board=read(args.validation)
    require(offline['status']=='OFFLINE_TIMING_FUNCTIONAL_PASS_BOARD_PENDING' and
            offline['timing_closed'] and offline['functional_regression_passed'], 'Offline acceptance missing')
    root=Path(__file__).resolve().parents[1]
    kit_receipt=offline['evidence']['board_kit']
    kit_directory=(root/kit_receipt['path']).resolve()
    require(kit_directory.is_relative_to(root) and
            sha(kit_directory/'result.json')==kit_receipt['sha256'], 'Board kit receipt changed')
    kit=read(kit_directory/'result.json')
    require(sha(args.expected)==kit['files']['expected.json'] and
            expected['host_reference_manifest_sha256']==offline['host_reference_manifest_sha256'],
            'Board goldens are not the offline-qualified kit')
    hardware=offline['hardware'];build=offline['build_id'];size=offline['input_size']
    require(hardware==expected['hardware']==board['hardware'] and hardware['build_id']==build,
            'Board golden and current implementation differ')
    require(board['status']=='PASS_LINUX_24_LAYER_AND_PRODUCTION' and
            board['step_hash_comparisons']==150 and board['convolution_hash_comparisons']==72,
            'Current board golden validation incomplete')
    require(set(expected['frames'])==set(board['trace_frames'])=={'bird','random','bird_repeat'} and
            board['input_check']==kit['input_check'], 'Board input validation differs')
    smoke=board['smoke']
    require(smoke['status']=='PASS_LINUX_DRIVER_SMOKE' and smoke['abi']==2 and
            smoke['build_id']==build and smoke['pl_hz']==hardware['pl_MHz']*1000000 and
            abs(smoke['fclk_hz']-hardware['fclk_MHz']*1000000)<=10000 and
            smoke['exclusive_open']=='PASS_EBUSY' and smoke['invalid_descriptor']=='PASS_EINVAL' and
            smoke['faulted']==0, 'Driver smoke or clock validation failed')
    for name,golden in expected['frames'].items():
        result=board['trace_frames'][name]
        require(result['status']=='PASS_50_STEPS_24_CONVOLUTIONS' and
                result['final_sha256']==golden['final_sha256'] and
                len(result['steps'])==len(golden['steps'])==50, 'Golden graph differs')
        frame_metrics(result['metrics'],hardware)
        for actual,item in zip(result['steps'],golden['steps']):
            require(actual['status']=='PASS_SHA256_EQUAL' and
                    all(actual[key]==value for key,value in item.items()), 'Graph step differs')
    require(len(board['production'])==8, 'Missing production repetitions')
    for frame in board['production']:
        require(frame['trace_enabled'] is False, 'Production trace overhead enabled')
        frame_metrics(frame,hardware)
    positions=(size//16)**2+(size//32)**2
    require(offline.get('positions',positions)==positions and
            all(frame['steps'][-1]['bytes']==positions*5*4 for frame in expected['frames'].values()),
            'Detector position count differs from graph outputs')
    detection=sequence(args.detection,build,size,positions)
    tracking=sequence(args.tracking,build,size,positions,tracking=True)
    fps=detection['detection_fps']
    status=('PASS_BOARD_15FPS' if fps>=15 else 'PASS_BOARD_5FPS' if fps>=5 else
            'BOARD_VERIFIED_FPS_BELOW_TARGET')
    record=dict(status=status,build_id=build,hardware=hardware,board_tested=True,camera_tested=True,
        detection=detection,tracking=tracking,minimum_detection_5fps_pass=fps>=5,
        stretch_detection_15fps_pass=fps>=15,tracking_15fps_pass=tracking['tracking_output_fps']>=15,
        accuracy_mAP=None,thermal_qualification=False,physical_pan_tilt_tested=False,
        scope='Current 24-layer golden and live camera throughput; accuracy and thermal acceptance separate',
        input_sha256={key:sha(getattr(args,key)) for key in ('offline','expected','validation')},
        generator_sha256=sha(Path(__file__)))
    args.output.mkdir(parents=True,exist_ok=False)
    (args.output/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,ensure_ascii=False,indent=2))
    return 0 if fps>=5 else 2


if __name__=='__main__':
    raise SystemExit(main())
