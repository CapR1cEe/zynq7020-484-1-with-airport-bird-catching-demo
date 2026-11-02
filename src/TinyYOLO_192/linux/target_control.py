"""Single bird target selection, native tracking, and disabled-by-default PWM.

Coordinates are camera pixels. Detection FPS and tracking FPS stay separate.
PWM writes require explicit sysfs channel paths in an enabled configuration.
"""
import ctypes
import json
import math
from pathlib import Path
import threading
import time


class TrackerState(ctypes.Structure):
    _fields_ = [('valid',ctypes.c_int32),('missed',ctypes.c_int32),
                *[(k,ctypes.c_float) for k in ('x','y','w','h','quality')],
                ('pattern',ctypes.c_uint8*1024)]


class Tracker:
    def __init__(self, library=None):
        library = library or Path(__file__).parent/'libtinyyolo_tracker.so'
        self.lib=ctypes.CDLL(str(library))
        args=[ctypes.POINTER(TrackerState),ctypes.c_void_p,ctypes.c_int,ctypes.c_int]
        self.lib.ty_tracker_seed.argtypes=args+[ctypes.c_float]*4
        self.lib.ty_tracker_seed.restype=ctypes.c_int
        self.lib.ty_tracker_update.argtypes=args
        self.lib.ty_tracker_update.restype=ctypes.c_int
        self.state=TrackerState()

    def seed(self, image, detections):
        w,h=image.size
        candidates=[d for d in detections if d.get('class_id',0)==0 and
                    math.isfinite(d.get('score',float('nan'))) and d['score']>=.25]
        def rank(d):
            a,b,c,e=d['xyxy']
            distance=math.hypot(((a+c)*.5-w*.5)/w,((b+e)*.5-h*.5)/h)
            return d['score']-.35*distance
        self.state.valid=0
        for detection in sorted(candidates,key=rank,reverse=True):
            x,y,x2,y2=detection['xyxy']
            pixels=image.convert('L').tobytes()
            if self.lib.ty_tracker_seed(ctypes.byref(self.state),pixels,w,h,x,y,x2-x,y2-y)>0:
                return self.box('detection')
        return None

    def update(self,image):
        pixels=image.convert('L').tobytes();w,h=image.size
        if self.lib.ty_tracker_update(ctypes.byref(self.state),pixels,w,h)>0:
            return self.box('tracking')
        return None

    def box(self,source):
        t=self.state
        return dict(xyxy=[t.x,t.y,t.x+t.w,t.y+t.h],quality=t.quality,source=source,class_id=0)


class PanTilt:
    """Configured permission persists across target loss; faults latch closed.

    Each arm stages both duty cycles before enabling either channel. A separate
    watchdog disarms both axes if capture or processing stops updating control.
    """
    WATCHDOG_SECONDS = .5

    def __init__(self,configuration=None):
        self.config=json.loads(Path(configuration).read_text()) if configuration else {'enabled':False}
        self.enabled=self.config.get('enabled') is True
        self.active=False;self.fault=None
        self.channels=[];self.positions=[1500.,1500.];self.last=None
        self._lock=threading.RLock()
        self._stop=threading.Event()
        self._thread=None
        if self.enabled:
            for key in ('pan','tilt'):
                axis=self.config[key]
                path=Path(axis['sysfs_path']).resolve()
                if not path.is_dir() or not str(path).startswith('/sys/devices/'):
                    raise ValueError('PWM must resolve to a Linux sysfs device')
                lo,hi,center=axis['min_us'],axis['max_us'],axis['center_us']
                gain=axis.get('gain_us_per_second',300)
                if (not all(math.isfinite(v) for v in (lo,hi,center,gain)) or
                    not 500<=lo<center<hi<=2500 or axis['direction'] not in (-1,1) or
                    not 0<gain<=5000):
                    raise ValueError('Invalid servo limits or direction')
                if (path/'period').read_text().strip()!='20000000':
                    raise ValueError('Configure a 50 Hz PWM period before enabling control')
                self.channels.append((path,axis))
            if len({p for p,_ in self.channels})!=2:raise ValueError('Axes must use distinct PWM channels')
            self.positions=[a['center_us'] for _,a in self.channels]
            self._off()
            self._thread=threading.Thread(target=self._watchdog,daemon=True)
            self._thread.start()

    def _off(self):
        """Caller holds the lock, except during single-threaded construction."""
        self.active=False
        self.last=None
        errors=[]
        for path,_ in self.channels:
            try:(path/'enable').write_text('0')
            except OSError as error:errors.append(error)
        if errors:
            self.enabled=False
            self.fault=str(errors[0])
            raise errors[0]

    def _watchdog(self):
        while not self._stop.wait(.05):
            with self._lock:
                if (self.active and self.last is not None and
                    time.monotonic()-self.last>self.WATCHDOG_SECONDS):
                    try:self._off()
                    except OSError:
                        # _off already attempted both channels and latched the fault.
                        return

    def disable(self):
        """Final shutdown; a later update cannot re-arm this instance."""
        self._stop.set()
        try:
            with self._lock:
                self.enabled=False
                self._off()
        finally:
            if self._thread is not None and self._thread is not threading.current_thread():
                self._thread.join()

    def update(self,box,size,now=None):
        with self._lock:
            if self.fault is not None:raise RuntimeError('PWM fault: '+self.fault)
            if not self.enabled:return {'enabled':False}
            now=time.monotonic() if now is None else now
            if box is None:
                if self.active:self._off()
                return {'enabled':False,'reason':'target_lost'}
            w,h=size;a,b,c,d=box['xyxy']
            if (not all(math.isfinite(v) for v in (now,w,h,a,b,c,d)) or
                w<=0 or h<=0 or not 0<=a<c<=w or not 0<=b<d<=h):
                self._off()
                raise ValueError('Invalid target coordinates, image size or control timestamp')
            if self.last is not None and (now<self.last or now-self.last>self.WATCHDOG_SECONDS):
                self._off()
                return {'enabled':False,'reason':'watchdog'}
            error=[(a+c)/w-1,(b+d)/h-1]
            dt=.02 if self.last is None else min(.1,now-self.last)
            positions=[]
            for i,(_,axis) in enumerate(self.channels):
                delta=0 if abs(error[i])<.04 else error[i]*axis['direction']*axis.get('gain_us_per_second',300)*dt
                delta=max(-500*dt,min(500*dt,delta))
                positions.append(max(axis['min_us'],min(axis['max_us'],self.positions[i]+delta)))
            try:
                for i,(path,_) in enumerate(self.channels):
                    (path/'duty_cycle').write_text(str(round(positions[i]*1000)))
                if not self.active:
                    for path,_ in self.channels:(path/'enable').write_text('1')
            except OSError as error:
                self.enabled=False;self.fault=str(error)
                try:self._off()
                except OSError:pass
                raise
            # Separate sysfs devices cannot provide atomic dual-axis publication.
            self.positions=positions;self.last=now;self.active=True
            return {'enabled':True,'pulse_us':self.positions.copy()}
