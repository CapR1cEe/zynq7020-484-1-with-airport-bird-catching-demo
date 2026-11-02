"""USB UVC/image -> RGB NCHW INT8/float32 -> 24 PL convolutions -> NMS/overlay.

Run with Python 3 and Pillow on Xillinux. Capture format is negotiated by
camera_capture; its binary PPM/JPEG output is streamed directly into Pillow.
Preprocessing records the exact letterbox transform and writes the tensor to DMA.
"""
import argparse
import array
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack

from PIL import Image, ImageDraw
try:
    from tinyyolo_session import RuntimeSession, INPUT_SIZE, POSITIONS
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from tinyyolo_session import RuntimeSession, INPUT_SIZE, POSITIONS
from camera_session import CameraSession
from target_control import Tracker, PanTilt


def capture_image(capture, device):
    """Decode a live capture from a pipe; no intermediate image file is written."""
    process = subprocess.Popen([str(capture), str(device), '-'], stdout=subprocess.PIPE)
    try:
        if process.stdout is None:
            raise RuntimeError('Camera capture did not provide an image stream')
        with Image.open(process.stdout) as source_image:
            image = source_image.convert('RGB')
        # Consume any bytes Pillow left buffered at the end of the encoded frame.
        while process.stdout.read(65536):
            pass
        status = process.wait()
        if status != 0:
            raise RuntimeError('Camera capture failed with exit status %d' % status)
        return image
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait()
        raise
    finally:
        if process.stdout is not None:
            process.stdout.close()


def preprocess(image, output=None, dtype='float32'):
    if dtype not in ('float32', 'int8'):
        raise ValueError('Unsupported model input dtype')
    image = image.convert('RGB')
    w, h = image.size
    ratio = min(float(INPUT_SIZE)/w, float(INPUT_SIZE)/h)
    nw, nh = max(1, int(round(w*ratio))), max(1, int(round(h*ratio)))
    left, top = (INPUT_SIZE-nw)//2, (INPUT_SIZE-nh)//2
    canvas = Image.new('RGB', (INPUT_SIZE, INPUT_SIZE), (114, 114, 114))
    canvas.paste(image.resize((nw, nh), Image.BILINEAR), (left, top))
    # Pillow performs the 256-entry normalization lookup in C. Splitting the
    # image already gives the model's planar RGB order, without a Python
    # loop over all 519,168 pixels on Cortex-A9.
    # For this model, round_even(float32(pixel/255)/INPUT_SCALE)-128
    # equals pixel-128 for all 256 byte values. INT8 mode writes the first
    # convolution's input tensor directly, without an intermediate FP tensor.
    lookup = [i ^ 128 for i in range(256)] if dtype == 'int8' else [i/255.0 for i in range(256)]
    point_mode = 'L' if dtype == 'int8' else 'F'
    planar = None
    if output is None:
        planes = [channel.point(lookup, point_mode).tobytes() for channel in canvas.split()]
        if dtype == 'float32' and sys.byteorder != 'little':
            swapped = []
            for plane in planes:
                values = array.array('f'); values.frombytes(plane); values.byteswap()
                swapped.append(values.tobytes())
            planes = swapped
        planar = b''.join(planes)
    else:
        expected = 3*INPUT_SIZE*INPUT_SIZE*(1 if dtype == 'int8' else 4)
        if len(output) != expected:
            raise ValueError('Mapped DMA view has the wrong size')
        plane_bytes = INPUT_SIZE*INPUT_SIZE*(1 if dtype == 'int8' else 4)
        for index, channel in enumerate(canvas.split()):
            plane = channel.point(lookup, point_mode).tobytes()
            if dtype == 'float32' and sys.byteorder != 'little':
                values = array.array('f'); values.frombytes(plane); values.byteswap()
                plane = values.tobytes()
            output[index*plane_bytes:(index+1)*plane_bytes] = plane
    return planar, {'source_width': w, 'source_height': h,
            'resized_width': nw, 'resized_height': nh, 'left': left, 'top': top,
            'scale_x': float(nw)/w, 'scale_y': float(nh)/h,
            'resize': 'Pillow bilinear', 'padding': 114, 'channels': 'RGB NCHW',
            'normalization': 'int8(pixel - 128)' if dtype == 'int8' else 'float32(pixel / 255)',
            'dtype': dtype, 'network_size': [INPUT_SIZE, INPUT_SIZE]}


def nms(candidates, threshold, limit=100):
    candidates = sorted(candidates, key=lambda x: x['score'], reverse=True)
    selected = []
    for box in candidates:
        x1, y1, x2, y2 = box['xyxy']
        area = max(0, x2-x1)*max(0, y2-y1)
        keep = True
        for old in selected:
            a, b, c, d = old['xyxy']
            intersection = max(0, min(x2, c)-max(x1, a))*max(0, min(y2, d)-max(y1, b))
            union = area+max(0, c-a)*max(0, d-b)-intersection
            if union > 0 and intersection/union > threshold:
                keep = False
                break
        if keep:
            selected.append(box)
            if len(selected) == limit:
                break
    return selected


def decode(data, transform, confidence, overlap):
    if len(data) != POSITIONS*5*4:
        raise ValueError('Expected 5 x %d float32 outputs' % POSITIONS)
    values = array.array('f')
    values.frombytes(data)
    if sys.byteorder != 'little':
        values.byteswap()
    candidates = []
    for i in range(POSITIONS):
        x, y, w, h, score = [values[c*POSITIONS+i] for c in range(5)]
        if not all(math.isfinite(v) for v in (x, y, w, h, score)):
            raise ValueError('Non-finite detection output')
        if score < confidence or w <= 0 or h <= 0:
            continue
        left, top = transform['left'], transform['top']
        sx, sy = transform['scale_x'], transform['scale_y']
        sw, sh = transform['source_width'], transform['source_height']
        xyxy = [max(0, min(sw, (x-w/2-left)/sx)), max(0, min(sh, (y-h/2-top)/sy)),
                max(0, min(sw, (x+w/2-left)/sx)), max(0, min(sh, (y+h/2-top)/sy))]
        if xyxy[2] > xyxy[0] and xyxy[3] > xyxy[1]:
            candidates.append({'index': i, 'class_id': 0, 'score': score, 'xyxy': xyxy})
    return nms(candidates, overlap)


def selftest():
    data, t = preprocess(Image.new('RGB', (4, 2), (255, 0, 0)))
    assert len(data) == 3*INPUT_SIZE*INPUT_SIZE*4 and t['left'] == 0 and t['top'] == INPUT_SIZE//4
    values = array.array('f'); values.frombytes(data)
    if sys.byteorder != 'little': values.byteswap()
    middle = (INPUT_SIZE//2)*INPUT_SIZE+INPUT_SIZE//2
    assert values[middle] == 1.0 and values[INPUT_SIZE*INPUT_SIZE+middle] == 0.0
    assert abs(values[0]-114.0/255) < 1e-7
    boxes = [{'index': 0, 'score': .9, 'xyxy': [0, 0, 10, 10]},
             {'index': 1, 'score': .8, 'xyxy': [1, 1, 9, 9]},
             {'index': 2, 'score': .7, 'xyxy': [20, 20, 30, 30]}]
    assert [x['index'] for x in nms(boxes, .5)] == [0, 2]
    print('CAMERA_OFFLINE_SELFTEST_PASS RGB_NCHW_float32=1 letterbox=1 NMS=1')


def infer_image(session, image, args, prefix, frame_id):
    """Single worker owns the DMA view until inference acknowledges completion."""
    start = time.monotonic()
    dtype = 'int8' if args.input_mode == 'dma-int8' else 'float32'
    digest = None
    if args.input_mode != 'pipe':
        target = session.input_view()
        try:
            _, transform = preprocess(image, target, dtype=dtype)
            if args.save_input:
                digest = hashlib.sha256(target).hexdigest()
                with Path(str(prefix)+'.'+dtype+'.bin').open('xb') as stream:
                    stream.write(target)
        finally:
            target.release()
        data = None
    else:
        data, transform = preprocess(image)
        if args.save_input:
            digest = hashlib.sha256(data).hexdigest()
            Path(str(prefix)+'.float32.bin').write_bytes(data)
    prepared = time.monotonic()
    raw = session.infer(data)
    inferred = time.monotonic()
    boxes = decode(raw, transform, args.confidence, args.iou)
    done = time.monotonic()
    return dict(frame_id=frame_id, detections=boxes, preprocessing=transform,
                input_sha256=digest, input_dtype=dtype, submitted_at=start,
                completed_at=done, network_ms=session.last_network_ms,
                elapsed_ms=dict(preprocess=(prepared-start)*1000,
                    runtime_process=(inferred-prepared)*1000,
                    decode_nms=(done-inferred)*1000, total=(done-start)*1000))


def apply_detection(tracker, result, history, now, max_age=1.5):
    """Replay a bounded history; failed refreshes preserve the current tracker."""
    age=now-result['submitted_at']
    replay=result['tracking_replay']=dict(age_seconds=age,replayed_frames=0)
    if not math.isfinite(age) or age<0 or age>max_age:
        replay['status']='rejected_age'
        return None
    frames = list(history)
    anchor = next((i for i,(number,_) in enumerate(frames)
                   if number==result['frame_id']), None)
    if anchor is None:
        replay['status']='rejected_missing_anchor'
        return None
    if any(b[0]!=a[0]+1 for a,b in zip(frames[anchor:],frames[anchor+1:])):
        replay['status']='rejected_history_gap'
        return None
    if not result['detections']:
        replay['status']='no_detection'
        return None
    previous=copy.deepcopy(tracker.state)
    target=None
    try:
        target = tracker.seed(frames[anchor][1],result['detections'])
        for _, image in frames[anchor+1:]:
            if target is None: break
            target = tracker.update(image)
            replay['replayed_frames']+=1
    except BaseException:
        tracker.state=previous
        raise
    if target is None:
        tracker.state=previous
    replay['status']='applied' if target is not None else 'rejected_tracking'
    return target


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    source = ap.add_mutually_exclusive_group()
    source.add_argument('--video')
    source.add_argument('--image',type=Path)
    ap.add_argument('--output',type=Path)
    ap.add_argument('--runtime',type=Path,default=Path(__file__).parent/'tinyyolo_linux')
    ap.add_argument('--capture',type=Path,default=Path(__file__).parent/'camera_stream')
    ap.add_argument('--parameters',type=Path,default=Path(__file__).parent.parent/'model/parameters.bin')
    ap.add_argument('--frames',type=int,default=1)
    ap.add_argument('--input-mode',choices=('dma-int8','dma','pipe'),default='dma-int8')
    ap.add_argument('--save-input',action='store_true')
    ap.add_argument('--save-overlay',action='store_true',help='Include overlay disk cost in total FPS')
    ap.add_argument('--confidence',type=float,default=.25)
    ap.add_argument('--iou',type=float,default=.45)
    ap.add_argument('--track',action='store_true',help='Track between bounded background detections')
    ap.add_argument('--tracker-library',type=Path)
    ap.add_argument('--pan-tilt',type=Path,default=Path(__file__).parent/'pan_tilt.json')
    ap.add_argument('--control-fps',type=float,default=15)
    ap.add_argument('--detect-every',type=int,default=1)
    ap.add_argument('--detection-max-age',type=float,default=1.5,
                    help='Maximum detection age for bounded frame replay (seconds)')
    ap.add_argument('--camera-width',type=int,default=320)
    ap.add_argument('--camera-height',type=int,default=240)
    ap.add_argument('--selftest',action='store_true')
    args = ap.parse_args()
    if args.selftest:
        selftest(); return
    if (args.output is None or not 1<=args.frames<=10000 or
        not 0<=args.confidence<=1 or not 0<=args.iou<=1 or
        not 1<=args.control_fps<=120 or args.detect_every<1 or
        not .1<=args.detection_max_age<=5 or
        not 1<=args.camera_width<=4096 or not 1<=args.camera_height<=4096):
        ap.error('Provide --output and valid frame, rate, size and threshold arguments')
    if args.track and args.input_mode=='pipe':
        ap.error('--track requires shared DMA input for clean bounded shutdown')
    video=args.video or '/dev/video0'
    if args.image is None and not Path(video).exists():
        ap.error('No camera at '+video+'; connect USB HOST and check /dev/video*')
    args.output.mkdir(parents=True,exist_ok=False)
    tracker=Tracker(args.tracker_library) if args.track else None
    control=PanTilt(args.pan_tilt) if args.track else None
    history_limit=min(48,max(4,math.ceil(args.control_fps*args.detection_max_age)+2))
    records=[]; history=deque(maxlen=history_limit); future=None; target=None
    completed=0; tracked=0; latencies=[]; result=None; session=None
    sequence_start=time.monotonic()
    try:
        session=RuntimeSession(args.runtime.resolve(),args.parameters.resolve(),
                               args.output/'sequence',args.frames,mode=args.input_mode)
        with ExitStack() as stack:
            camera=(stack.enter_context(CameraSession(args.capture.resolve(),video,
                     args.camera_width,args.camera_height)) if args.image is None else None)
            worker=stack.enter_context(ThreadPoolExecutor(max_workers=1)) if args.track else None
            # Disarm before the executor waits for an in-flight DMA transaction.
            if control is not None:stack.callback(control.disable)
            startup_ms=(time.monotonic()-sequence_start)*1000
            loop_start=time.monotonic()
            for frame in range(args.frames):
                if args.track:
                    delay=loop_start+frame/args.control_fps-time.monotonic()
                    if delay>0: time.sleep(delay)
                started=time.monotonic(); frame_id=frame+1
                if camera:
                    image,capture_info=camera.capture()
                else:
                    with Image.open(str(args.image)) as source_image: image=source_image.convert('RGB')
                    capture_info={'source':str(args.image)}
                captured=time.monotonic()
                prefix=args.output/('frame%04d'%frame_id)
                history.append((frame_id,image.copy()))
                result=None
                if args.track:
                    if future is not None and future.done():
                        result=future.result();future=None
                        completed+=1;latencies.append(result['network_ms'])
                        target=apply_detection(tracker,result,history,time.monotonic(),args.detection_max_age)
                        if target is None and tracker.state.valid:
                            target=tracker.update(image)
                    elif tracker.state.valid:
                        target=tracker.update(image)
                    if future is None and (not tracker.state.valid or frame%args.detect_every==0):
                        future=worker.submit(infer_image,session,image.copy(),args,prefix,frame_id)
                    tracked+=int(target is not None)
                    steering=control.update(target,image.size)
                else:
                    result=infer_image(session,image,args,prefix,frame_id)
                    completed+=1;latencies.append(result['network_ms'])
                    steering={'enabled':False}
                ready=time.monotonic()
                boxes=result['detections'] if result else []
                if args.save_overlay:
                    draw=ImageDraw.Draw(image)
                    for box in boxes:
                        draw.rectangle(box['xyxy'],outline=(255,64,32))
                    if target is not None: draw.rectangle(target['xyxy'],outline=(32,255,64))
                    image.save(str(prefix)+'.overlay.png',compress_level=1)
                done=time.monotonic()
                record=dict(frame=frame_id,camera=capture_info,detection=result,
                            target=target,control=steering,
                            elapsed_ms=dict(capture=(captured-started)*1000,
                                detections_or_tracking_ready=(ready-started)*1000,
                                total=(done-started)*1000))
                records.append(record)
                print('CAMERA_FRAME frame=%d detections_completed=%d target=%d total_ms=%.3f'%
                      (frame_id,completed,int(target is not None),(done-started)*1000),flush=True)
            # The final already-submitted frame is counted only after it completes.
            if control is not None:control.disable()
            if future is not None:
                result=future.result();completed+=1;latencies.append(result['network_ms'])
                records.append(dict(final_background_detection=result))
            end=time.monotonic()
        session.close(allow_partial=args.track);session=None
        duration=end-loop_start
        summary=dict(status='PASS_CAMERA_SEQUENCE' if camera else 'PASS_IMAGE_SEQUENCE',
            input_size=INPUT_SIZE,positions=POSITIONS,build_id='0x47325502',
            duration_seconds=duration,startup_ms=startup_ms,capture_frames=args.frames,
            completed_detections=completed,successful_tracking_updates=tracked,
            detection_fps=completed/duration,tracking_output_fps=tracked/duration,
            capture_loop_fps=args.frames/duration,network_ms=latencies,
            detection_5fps_pass=completed/duration>=5,
            detection_15fps_pass=completed/duration>=15,
            tracking_15fps_pass=args.track and tracked/duration>=15,
            overlay_saved=args.save_overlay,board_measurement=camera is not None,
            tracking_enabled=args.track,detection_max_age_seconds=args.detection_max_age,
            tracking_history_frames=history_limit,physical_pan_tilt_tested=False,
            accuracy_map=None,accuracy_note='Requires a labelled bird evaluation set')
        (args.output/'frames.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records))
        (args.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        print(json.dumps(summary),flush=True)
    finally:
        try:
            if control is not None: control.disable()
        finally:
            if session is not None: session.close(check=False,allow_partial=args.track)


if __name__=='__main__':
    main()
