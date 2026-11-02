"""Exercise native tracking and camera ownership without claiming board FPS."""
import argparse
import array
from contextlib import redirect_stdout
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'linux'))
from PIL import Image
import camera_infer as camera
import camera_session
import target_control


def require(ok, message):
    if not ok: raise AssertionError(message)


def rejected(call, message):
    try: call()
    except (ValueError, RuntimeError, OSError): return
    raise AssertionError(message)


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--cc', default=os.environ.get('CC') or shutil.which('gcc') or
                    'C:/msys64/ucrt64/bin/gcc.exe')
    args = ap.parse_args()
    out = Path(os.path.abspath(str(args.output))); out.mkdir(parents=True, exist_ok=False)
    library = out/('tracker_host.dll' if os.name=='nt' else 'tracker_host.so')
    cc = args.cc
    env = dict(os.environ, PATH=str(Path(cc).parent)+os.pathsep+os.environ['PATH'])
    dll_directory = os.add_dll_directory(str(Path(cc).parent)) if hasattr(os,'add_dll_directory') else None
    build = subprocess.run([cc, '-std=c11', '-O3', '-Wall', '-Wextra', '-Werror',
        *(['-fPIC'] if os.name=='posix' else []),
        '-shared', str(ROOT/'linux/tracker_core.c'), '-o', str(library), '-lm'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=env, check=True)
    (out/'compile.log').write_text(build.stdout+build.stderr)
    rng = random.Random(5502)
    patch = Image.frombytes('L', (40,32), bytes(rng.randrange(20,210) for _ in range(1280)))
    def scene(x, y, item=patch, size=(192,128)):
        image = Image.new('L', size, 8); image.paste(item, (x,y)); return image.convert('RGB')
    def detection(x,y,w=40,h=32):
        return [dict(class_id=0, score=.9, xyxy=[x,y,x+w,y+h])]
    tracker = target_control.Tracker(library)
    checks = []
    require(tracker.seed(scene(60,40), detection(60,40)) is not None, 'Native seed failed')
    start = time.perf_counter()
    for x,y in [(64,42),(69,45),(72,48),(77,50)]:
        box = tracker.update(scene(x,y))
        require(box is not None and max(abs(a-b) for a,b in zip(box['xyxy'],[x,y,x+40,y+32]))<.01,
                'Tracker lost a translation within its search window')
    elapsed = time.perf_counter()-start
    checks.append(dict(name='integer_translation', frames=4, exact=True,
                       host_ms_per_frame=elapsed*250, board_timing=False))
    bright = patch.point(lambda x:x+18)
    box = tracker.update(scene(80,53,bright))
    require(box is not None and abs(box['xyxy'][0]-80)<.01 and box['quality']>.99,
            'Zero-mean brightness compensation failed')
    checks.append(dict(name='brightness_offset', offset=18))
    require(tracker.update(Image.new('RGB',(192,128),(100,100,100))) is None and not tracker.state.valid,
            'Occlusion did not invalidate control target')
    require(tracker.seed(scene(2,1),detection(2,1)) is not None, 'Reacquisition failed')
    require(tracker.update(scene(0,0)) is not None, 'Image edge tracking failed')
    require(tracker.seed(Image.new('RGB',(192,128),(30,30,30)),detection(60,40)) is None,
            'Unobservable low-texture crop was accepted')
    require(tracker.seed(scene(60,40),detection(-1,0)) is None, 'Out-of-bounds seed accepted')
    checks.append(dict(name='occlusion_reacquire_boundaries_low_texture'))
    # Smooth texture avoids nearest-neighbor aliasing while exercising scale search.
    smooth = Image.frombytes('L',(12,10),bytes(rng.randrange(30,200) for _ in range(120)))
    smooth = smooth.resize((60,40),Image.BILINEAR)
    require(tracker.seed(scene(50,35,smooth),detection(50,35,60,40)) is not None, 'Scale seed failed')
    scaled = smooth.resize((63,42),Image.BILINEAR)
    box = tracker.update(scene(53,37,scaled))
    require(box is not None and max(abs(a-b) for a,b in zip(box['xyxy'],[53,37,116,79]))<2,
            'Scale search exceeded two-pixel tolerance')
    checks.append(dict(name='five_percent_scale', bbox=box['xyxy'], tolerance_pixels=2))

    ppm = io.BytesIO(); scene(60,40).save(ppm,format='PPM'); payload=ppm.getvalue()
    def packet(seq=1, magic=b'TYF1', w=192, h=128, data=payload):
        return struct.pack('<4sIIIIIQ',magic,len(data),seq,w,h,0,123456)+data
    class Process:
        def __init__(self,data=b'',status=0):
            self.stdin=io.BytesIO();self.stdout=io.BytesIO(data);self.status=status
        def wait(self,timeout=None):return self.status
        def terminate(self):self.status=-15
        def kill(self):self.status=-9
    p=Process(packet()+packet())
    with mock.patch.object(camera_session.subprocess,'Popen',return_value=p):
        capture=camera_session.CameraSession('mock','mock')
    image,info=capture.capture()
    require(image.size==(192,128) and info['sequence']==1,'Camera packet decoding failed')
    rejected(capture.capture,'Repeated frame sequence accepted');capture.close();capture.close()
    for data in (packet()[:12],packet()[:-5],packet(magic=b'BAD!'),packet(w=191),packet(w=0)):
        with mock.patch.object(camera_session.subprocess,'Popen',return_value=Process(data)):
            capture=camera_session.CameraSession('mock','mock')
        rejected(capture.capture,'Malformed camera packet accepted');capture.close()
    with mock.patch.object(camera_session.subprocess,'Popen',return_value=Process(status=7)):
        capture=camera_session.CameraSession('mock','mock')
    rejected(capture.close,'Failed camera process accepted')
    checks.append(dict(name='camera_protocol', malformed_cases=5, repeated_sequence_rejected=True))

    values=array.array('f',[0.]*(5*camera.POSITIONS))
    for channel,value in enumerate((48.,48.,24.,20.,.9)): values[channel*camera.POSITIONS]=value
    if sys.byteorder!='little':values.byteswap()
    raw=values.tobytes()
    class FakeRuntime:
        instances=[]
        def __init__(self,*args,**kwargs):
            self.storage=bytearray(3*camera.INPUT_SIZE**2);self.index=0
            self.active=False;self.closed=False;self.max_active=0;self.last_network_ms=25
            self.allow_partial=None;self.frames=args[3];self.hashes=[]
            self.instances.append(self)
        def input_view(self):
            require(not self.active,'DMA overwritten during inference')
            return memoryview(self.storage)
        def infer(self,data):
            require(data is None and not self.active,'Concurrent runtime access')
            self.active=True;self.max_active=1
            before=bytes(self.storage);self.hashes.append(hashlib.sha256(before).hexdigest())
            time.sleep(.025)
            require(before==bytes(self.storage),'In-flight DMA bytes changed')
            self.index+=1;self.active=False
            return raw
        def close(self,check=True,allow_partial=False):
            require(not self.active,'Runtime closed before DMA drained')
            self.closed=True;self.allow_partial=allow_partial
    options=SimpleNamespace(input_mode='dma-int8',save_input=False,confidence=.25,iou=.45)
    fake=FakeRuntime(None,None,None,1)
    result=camera.infer_image(fake,scene(60,40),options,out/'unused',1)
    expected,_=camera.preprocess(scene(60,40),dtype='int8')
    require(bytes(fake.storage)==expected and result['frame_id']==1 and len(result['detections'])==1,
            'DMA producer bytes or detector output differ')
    checks.append(dict(name='dma_infer_image', bytes=len(expected), matches_preprocess=True))
    class ReplayTracker:
        def __init__(self):self.state=SimpleNamespace(valid=1);self.seen=[]
        def seed(self,image,boxes):self.seen.append(('seed',image));return {'xyxy':[0,0,4,4]}
        def update(self,image):self.seen.append(('update',image));return {'xyxy':[0,0,4,4]}
    replay=ReplayTracker()
    camera.apply_detection(replay,dict(submitted_at=1.,frame_id=3,detections=[{}]),[(2,'a'),(3,'b'),(4,'c')],1.7)
    require(replay.seen==[('seed','b'),('update','c')],'Delayed detection replay ordering differs')
    require(camera.apply_detection(replay,dict(submitted_at=1.,frame_id=3),[],2.6) is None and
            replay.state.valid==1,'Stale refresh invalidated an independent current tracker')
    replay_frames=[(i+1,scene(60+i*2,40)) for i in range(12)]
    late=dict(submitted_at=1.,frame_id=1,detections=detection(60,40))
    target=camera.apply_detection(tracker,late,replay_frames,1.7)
    require(target is not None and abs(target['xyxy'][0]-82)<.01 and
            late['tracking_replay']['replayed_frames']==11,'700 ms native detection replay failed')
    before=bytes(tracker.state)
    for result,frames,status in (
        (dict(submitted_at=1.,frame_id=1,detections=[]),replay_frames,'no_detection'),
        (dict(submitted_at=1.,frame_id=0,detections=detection(60,40)),replay_frames,'rejected_missing_anchor'),
        (dict(submitted_at=1.,frame_id=1,detections=detection(60,40)),[replay_frames[0],replay_frames[2]],'rejected_history_gap'),
        (dict(submitted_at=1.,frame_id=1,detections=detection(60,40)),[(1,Image.new('RGB',(192,128)))],'rejected_tracking')):
        require(camera.apply_detection(tracker,result,frames,1.7) is None and
                result['tracking_replay']['status']==status and bytes(tracker.state)==before,
                'A rejected detector refresh corrupted current tracking')
    checks.append(dict(name='delayed_detection_native_replay', detector_delay_seconds=.7,
                       replayed_frames=11,stale_deadline_seconds=1.5,failed_refresh_preserves_target=True))
    class FakeCamera:
        def __init__(self,*args):self.number=0;self.closed=False
        def __enter__(self):return self
        def __exit__(self,*args):self.closed=True
        def capture(self):
            self.number+=1
            return scene(60,40),dict(sequence=self.number)
    control_path=out/'disabled.json';control_path.write_text('{"enabled":false}')
    video=out/'mockvideo';video.touch()
    for track in (False,True):
        dest=out/('async' if track else 'sync')
        argv=['camera_infer.py','--output',str(dest),'--video',str(video),'--frames','12' if track else '3',
              '--control-fps','120','--tracker-library',str(library),'--pan-tilt',str(control_path)]
        if track:argv.append('--track')
        with mock.patch.object(sys,'argv',argv),mock.patch.object(camera,'RuntimeSession',FakeRuntime),\
             mock.patch.object(camera,'CameraSession',FakeCamera),redirect_stdout(io.StringIO()):
            camera.main()
        summary=json.loads((dest/'summary.json').read_text());runtime=FakeRuntime.instances[-1]
        require(runtime.closed and runtime.index==summary['completed_detections'],'Detection count or cleanup differs')
        require(summary['completed_detections']<=summary['capture_frames'],'Detection count exceeds captured frames')
        if track:
            require(1<runtime.index<12 and runtime.allow_partial,'Async loop accumulated work or failed partial close')
            require(summary['capture_loop_fps']>summary['detection_fps'],'Tracking substituted for detection FPS')
        else:require(runtime.index==3 and not runtime.allow_partial,'Synchronous detector did not process each frame')
        summary['status']='PASS_MOCK_PIPELINE_ONLY'
        summary['board_measurement']=False
        summary['test_doubles']=['RuntimeSession','CameraSession']
        for key in ('detection_fps','tracking_output_fps','capture_loop_fps',
                    'detection_5fps_pass','detection_15fps_pass','tracking_15fps_pass'):
            summary['mock_'+key]=summary[key];summary[key]=None
        (dest/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        checks.append(dict(name='mock_async_main' if track else 'mock_sync_main',
                           completed_detections=runtime.index,capture_frames=summary['capture_frames'],
                           max_inflight=runtime.max_active,board_measurement=False))
    disabled=target_control.PanTilt(control_path)
    require(disabled.update({'xyxy':[0,0,4,4]},(192,128))=={'enabled':False},'Default PWM unexpectedly enabled')
    disabled.disable()
    from check_pan_tilt import check_control
    checks.extend(check_control())
    # Exercise exception unwind while a DMA worker still owns the input.
    events=[];worker_started=threading.Event()
    class PendingRuntime(FakeRuntime):
        def infer(self,data):
            self.active=True;worker_started.set();time.sleep(.05)
            self.index+=1;self.active=False;events.append('worker_done')
            return raw
        def close(self,**kwargs):
            events.append('runtime_close');super().close(**kwargs)
    class BrokenCamera(FakeCamera):
        def capture(self):
            if self.number:
                require(worker_started.wait(1),'Worker did not start')
                raise RuntimeError('injected capture failure')
            return super().capture()
    class RecordedControl:
        def __init__(self,*args):pass
        def disable(self):events.append('pwm_off')
        def update(self,*args):return {'enabled':False}
    argv=['camera_infer.py','--track','--output',str(out/'exception_cleanup'),
          '--video',str(video),'--frames','4','--control-fps','120','--tracker-library',str(library)]
    with mock.patch.object(sys,'argv',argv),mock.patch.object(camera,'RuntimeSession',PendingRuntime),\
         mock.patch.object(camera,'CameraSession',BrokenCamera),mock.patch.object(camera,'PanTilt',RecordedControl),\
         redirect_stdout(io.StringIO()):
        rejected(camera.main,'Injected capture exception was hidden')
    require(events.index('pwm_off')<events.index('worker_done')<events.index('runtime_close'),
            'PWM shutdown or DMA drain ordering is unsafe')
    checks.append(dict(name='exception_shutdown_order',events=events))
    record=dict(status='PASS_OFFLINE_TRACKING_CAMERA_PIPELINE', build_id='0x47325502',
        input_size=camera.INPUT_SIZE, checks=checks,board_tested=False,camera_tested=False,
        detection_fps_measured=None,accuracy_map=None,
        source_sha256={p:sha(ROOT/p) for p in ('linux/camera_infer.py','linux/camera_session.py',
            'linux/target_control.py','linux/tracker_core.c','linux/tinyyolo_session.py',
            'linux/model_config.json','scripts/check_tracking_pipeline.py','scripts/check_pan_tilt.py')})
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(record['status'])
    if dll_directory is not None:dll_directory.close()


if __name__=='__main__':main()
