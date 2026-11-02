"""Demand-driven board camera preview and real PL bird detections over UART."""
import base64
import io
import json
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

sys.path.insert(0, '/opt/tinyyolo')
from camera_session import CameraSession


def emit(data):
    print('TY_PREVIEW ' + json.dumps(data, separators=(',', ':'), allow_nan=False), flush=True)


class Preview:
    def __init__(self):
        self.camera = None
        self.runtime = None
        self.width, self.height = 320, 240
        self.frame = 0
        self.capture_failures = 0
        self.session_directory = Path(tempfile.mkdtemp(prefix='tinyyolo_live_'))
        self.log = (self.session_directory / 'detections.jsonl').open('a')
        self.previous_boxes = []

    def close_camera(self):
        if self.camera is not None:
            try:
                self.camera.close()
            except Exception:
                pass
            self.camera = None

    def close_runtime(self):
        if self.runtime is not None:
            self.runtime.close(check=False, allow_partial=True)
            self.runtime = None

    def capture(self):
        if self.camera is None:
            self.camera = CameraSession('/opt/tinyyolo/camera_stream', '/dev/video0', self.width, self.height)
        timer = threading.Timer(7, self.camera.process.kill)
        timer.daemon = True
        timer.start()
        try:
            return self.camera.capture()
        except Exception:
            self.close_camera()
            raise
        finally:
            timer.cancel()

    def request(self, command):
        requested_width = int(command.get('width', self.width))
        requested_height = int(command.get('height', self.height))
        if (requested_width, requested_height) not in ((320, 240), (640, 480)):
            raise ValueError('Unsupported preview size')
        if (requested_width, requested_height) != (self.width, self.height):
            self.close_camera()
            self.width, self.height = requested_width, requested_height
        started = time.monotonic()
        image, capture = self.capture()
        self.frame += 1
        self.capture_failures = 0
        captured = time.monotonic()
        boxes, error, inference_ms = [], None, None
        if command.get('detect', False):
            try:
                from tinyyolo_session import RuntimeSession
                from camera_infer import infer_image
                if self.runtime is None or self.runtime.index >= 9990:
                    self.close_runtime()
                    self.runtime = RuntimeSession(Path('/opt/tinyyolo/tinyyolo_linux'),
                        Path('/opt/tinyyolo/parameters.bin'),
                        self.session_directory / ('network_%06d' % self.frame), 10000, mode='dma-int8')
                args = SimpleNamespace(input_mode='dma-int8', save_input=False,
                                       confidence=float(command.get('confidence', .25)), iou=.45)
                result = infer_image(self.runtime, image, args, self.session_directory/'input', self.frame)
                boxes = result['detections']
                inference_ms = result['network_ms']
            except Exception as exc:
                error = str(exc)
                self.close_runtime()
        else:
            self.close_runtime()
        width, height = image.size
        target = max(boxes, key=lambda b: b['score']) if boxes else None
        dx = (target['xyxy'][0]+target['xyxy'][2])/2-width/2 if target else None
        dy = (target['xyxy'][1]+target['xyxy'][3])/2-height/2 if target else None
        preview = image.copy()
        preview.thumbnail((self.width, self.height))
        output = io.BytesIO()
        preview.save(output, format='JPEG', quality=65)
        record = dict(kind='frame', frame=self.frame, camera_sequence=capture['sequence'],
                      width=width, height=height, preview_width=preview.width, preview_height=preview.height,
                      board_monotonic_s=time.monotonic(), capture_ms=(captured-started)*1000,
                      inference_ms=inference_ms, detection_enabled=bool(command.get('detect', False)),
                      detection_error=error, detections=boxes, target_detected=target is not None,
                      target_dx_px=dx, target_dy_px=dy, target_confidence=target['score'] if target else None,
                      camera_connected=True, board_session=str(self.session_directory))
        self.log.write(json.dumps(record)+'\n')
        self.log.flush()
        record['jpeg_base64'] = base64.b64encode(output.getvalue()).decode('ascii')
        emit(record)

    def close(self):
        self.close_camera()
        self.close_runtime()
        self.log.close()


def main():
    preview = Preview()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    emit(dict(kind='ready', board_session=str(preview.session_directory)))
    try:
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if command.get('action') == 'quit':
                    break
                preview.request(command)
            except Exception as exc:
                preview.capture_failures += 1
                emit(dict(kind='error', error=str(exc), camera_connected=Path('/dev/video0').exists(),
                          consecutive_failures=preview.capture_failures))
    finally:
        preview.close()
        emit(dict(kind='stopped'))


if __name__ == '__main__':
    main()
