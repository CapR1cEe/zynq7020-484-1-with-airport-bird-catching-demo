"""Demand-driven board camera preview and real PL bird detections over UART."""
import base64
import argparse
import hashlib
import io
import json
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

EXPECTED_PARAMETERS_SHA256 = 'dc66425157588a3de922edcd26454e72f80da2047edf0c5dcbeb0c552a04d4d0'
DEFAULT_RUNTIME_CANDIDATES = (
    Path('/opt/tinyyolo_192_verified_20261102'),
    Path('/opt/tinyyolo'),
)


def parameter_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()


def validate_runtime(path):
    root = Path(path).expanduser()
    config = json.loads((root/'model_config.json').read_text(encoding='utf-8'))
    if config.get('input_size') != 192:
        raise ValueError('{} uses input_size={}, expected 192'.format(
            root, config.get('input_size', 'unknown')))
    if config.get('parameters_sha256') != EXPECTED_PARAMETERS_SHA256:
        raise ValueError('{} has an unexpected 192x192 parameter manifest'.format(root))
    parameters = root/'parameters.bin'
    if parameter_sha256(parameters) != EXPECTED_PARAMETERS_SHA256:
        raise ValueError('{} parameters.bin failed SHA-256 validation'.format(root))
    for name in ('camera_stream', 'tinyyolo_linux'):
        if not (root/name).is_file():
            raise FileNotFoundError('{} is missing {}'.format(root, name))
    return root.resolve(), config


def resolve_runtime(runtime_dir):
    requested = str(runtime_dir).strip()
    if requested and requested.casefold() != 'auto':
        return validate_runtime(Path(requested))
    candidates = list(DEFAULT_RUNTIME_CANDIDATES)
    opt = Path('/opt')
    if opt.is_dir():
        candidates.extend(sorted(opt.glob('tinyyolo*')))
    seen = set()
    errors = []
    for candidate in candidates:
        identity = str(candidate)
        if identity in seen:
            continue
        seen.add(identity)
        if not (candidate/'model_config.json').is_file():
            continue
        try:
            return validate_runtime(candidate)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(str(exc))
    detail = '; '.join(errors) if errors else 'no model_config.json found under /opt/tinyyolo*'
    raise RuntimeError('No verified TinyYOLO 192x192 runtime found: '+detail)


def emit(data):
    print('TY_PREVIEW ' + json.dumps(data, separators=(',', ':'), allow_nan=False), flush=True)


class Preview:
    def __init__(self, runtime_dir):
        self.runtime_root, self.model_config = resolve_runtime(runtime_dir)
        sys.path.insert(0, str(self.runtime_root))
        from camera_session import CameraSession
        self.CameraSession = CameraSession
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
            self.camera = self.CameraSession(str(self.runtime_root/'camera_stream'),
                                             '/dev/video0', self.width, self.height)
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
                    self.runtime = RuntimeSession(self.runtime_root/'tinyyolo_linux',
                        self.runtime_root/'parameters.bin',
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
                      camera_connected=True, board_session=str(self.session_directory),
                      runtime_dir=str(self.runtime_root),
                      model_input_size=self.model_config['input_size'])
        self.log.write(json.dumps(record)+'\n')
        self.log.flush()
        record['jpeg_base64'] = base64.b64encode(output.getvalue()).decode('ascii')
        emit(record)

    def close(self):
        self.close_camera()
        self.close_runtime()
        self.log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('runtime_dir', nargs='?', default='auto')
    args = parser.parse_args()
    try:
        preview = Preview(args.runtime_dir)
    except Exception as exc:
        emit(dict(kind='startup_error', error=str(exc)))
        return 2
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    emit(dict(kind='ready', board_session=str(preview.session_directory),
              runtime_dir=str(preview.runtime_root),
              model_input_size=preview.model_config['input_size']))
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
    raise SystemExit(main())
