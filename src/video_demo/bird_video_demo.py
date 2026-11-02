"""Offline video demonstration using real, cached CPU bird detections.

The board client is never created. Frames and detections share a frame index;
coordinates always refer to the original video, before preview resizing.
"""
import argparse
import ctypes
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import threading
import time
import tkinter as tk

import cv2
import numpy as np
from PIL import Image, ImageGrab

from bird_preview import PreviewWindow, SURFACE, TEXT, MUTED, RULE, GREEN

ROOT = Path(__file__).resolve().parent
DEFAULT_VIDEO = ROOT / 'demo_assets' / 'eagle_flying.mp4'
DEFAULT_DATA = ROOT / 'demo_assets' / 'eagle_detections.json'
DEFAULT_MODEL = Path(r'D:\ultralytics-main\runs\detect\train-3\weights\best_fp32_416.onnx')
SOURCE_URL = 'https://mixkit.co/free-stock-video/eagle-gliding-in-a-clear-sky-bottom-view-1706/'


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class BirdDetector:
    def __init__(self, model, confidence=.35):
        self.net = cv2.dnn.readNetFromONNX(str(model))
        self.confidence = confidence

    def detect(self, bgr):
        height, width = bgr.shape[:2]
        ratio = min(416 / width, 416 / height)
        resized_w, resized_h = round(width * ratio), round(height * ratio)
        left, top = (416 - resized_w) // 2, (416 - resized_h) // 2
        padded = np.full((416, 416, 3), 114, dtype=np.uint8)
        padded[top:top + resized_h, left:left + resized_w] = cv2.resize(bgr, (resized_w, resized_h))
        blob = cv2.dnn.blobFromImage(padded, 1 / 255., (416, 416), swapRB=True)
        started = time.perf_counter()
        self.net.setInput(blob)
        rows = self.net.forward()[0].T
        elapsed = (time.perf_counter() - started) * 1000
        rows = rows[rows[:, 4] >= self.confidence]
        boxes, scores = [], []
        for cx, cy, bw, bh, score in rows:
            x1 = float(np.clip((cx - bw / 2 - left) / ratio, 0, width))
            y1 = float(np.clip((cy - bh / 2 - top) / ratio, 0, height))
            x2 = float(np.clip((cx + bw / 2 - left) / ratio, 0, width))
            y2 = float(np.clip((cy + bh / 2 - top) / ratio, 0, height))
            if x2 > x1 and y2 > y1:
                boxes.append([x1, y1, x2 - x1, y2 - y1])
                scores.append(float(score))
        keep = cv2.dnn.NMSBoxes(boxes, scores, self.confidence, .45)
        detections = []
        for index in np.asarray(keep).reshape(-1):
            x, y, w, h = boxes[int(index)]
            detections.append(dict(xyxy=[round(v, 2) for v in (x, y, x + w, y + h)],
                                   score=round(scores[int(index)], 5)))
        return sorted(detections, key=lambda item: item['score'], reverse=True), elapsed


def prepare(video, model, destination):
    capture = cv2.VideoCapture(str(video))
    if not capture.isOpened():
        raise RuntimeError(f'Cannot open video: {video}')
    fps = capture.get(cv2.CAP_PROP_FPS)
    width, height = int(capture.get(3)), int(capture.get(4))
    if not math.isfinite(fps) or fps <= 0:
        capture.release()
        raise ValueError('Video has an invalid frame rate')
    detector = BirdDetector(model)
    records = []
    previous = None
    try:
        while True:
            ok, image = capture.read()
            if not ok:
                break
            detections, elapsed = detector.detect(image)
            if detections:
                # Prefer the previous target where possible. With the selected
                # single-bird clip, this also avoids false positives elsewhere.
                def distance(box):
                    a, b, c, d = box['xyxy']
                    center = ((a + c) / 2, (b + d) / 2)
                    origin = previous or (width / 2, height / 2)
                    return math.hypot(center[0] - origin[0], center[1] - origin[1])
                primary = min(detections, key=distance)
                x1, y1, x2, y2 = primary['xyxy']
                previous = ((x1 + x2) / 2, (y1 + y2) / 2)
                primary['primary'] = True
            else:
                previous = None
                primary = None
            records.append(dict(
                frame=len(records), time_s=round(len(records) / fps, 6),
                detections=detections, target_detected=primary is not None,
                target_dx_px=round(previous[0] - width / 2, 2) if primary else None,
                target_dy_px=round(previous[1] - height / 2, 2) if primary else None,
                target_confidence=primary['score'] if primary else None,
                inference_ms=round(elapsed, 2)))
            if len(records) % 120 == 0:
                print(f'Prepared {len(records)} frames', flush=True)
    finally:
        capture.release()
    if not records:
        raise RuntimeError('No decodable video frames')
    data = dict(schema=1, source='offline_video', source_url=SOURCE_URL,
                license_url='https://mixkit.co/license/#videoFree',
                video_sha256=sha256(video), model_sha256=sha256(model),
                model='YOLOv3-tinyu bird / ONNX 416 / OpenCV CPU',
                coordinate_convention='source pixels; X right positive; Y down positive',
                width=width, height=height, fps=fps, frame_count=len(records),
                duration_s=len(records) / fps, frames=records)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    times = [r['inference_ms'] for r in records]
    print(json.dumps(dict(frames=len(records), detected=sum(r['target_detected'] for r in records),
                          duration_s=data['duration_s'], median_inference_ms=float(np.median(times)),
                          output=str(destination)), ensure_ascii=False), flush=True)


class VideoDemoWindow(PreviewWindow):
    def __init__(self, video, data_path, record=None, auto_close=False):
        if sys.platform == 'win32':
            try:
                ctypes.windll.shcore.SetProcessDpiAwareness(2)
            except (AttributeError, OSError):
                ctypes.windll.user32.SetProcessDPIAware()
        self.video_path = Path(video)
        self.data = json.loads(Path(data_path).read_text(encoding='utf-8'))
        if sha256(video) != self.data['video_sha256']:
            raise ValueError('Video differs from the file used for detections. Run --prepare again.')
        self.capture = cv2.VideoCapture(str(video))
        if not self.capture.isOpened():
            raise RuntimeError(f'Cannot open video: {video}')
        self.demo_output = ROOT / 'demo_live'
        self.demo_output.mkdir(exist_ok=True)
        self.playback_start = time.monotonic()
        self.paused_at = None
        self.last_index = -1
        self.last_log_at = 0
        self.record_path = Path(record).resolve() if record else None
        self.auto_close = auto_close
        self.record_done = threading.Event()
        self.record_error = None
        self.recorder = None
        self.export_index = None
        super().__init__('视频演示')
        self.title('TinyYOLO · 飞鸟视频演示')
        self.geometry('1280x800+80+40')
        self.playback_start = time.monotonic()
        if self.record_path:
            self.after(2000, self._start_recording)

    def _build(self):
        # Use a fixed 96-DPI UI inside a DPI-aware window. Screen capture and
        # Tk geometry then share physical pixels, including at 150% scaling.
        self.tk.call('tk', 'scaling', 96 / 72)
        super()._build()
        self.heading.configure(text='TinyYOLO / 视频演示')
        self.settings['detect'] = True
        self.color_enabled.set(False)
        self.detect_button.configure(text='停止检测', state='normal')
        self.mode_label.configure(text='鸟类检测 · 电脑模型结果回放', fg=GREEN)
        self.resolution_label.configure(text='视频画面')
        self.resolution.configure(values=(f"原片 · {self.data['width']} × {self.data['height']}",), state='disabled')
        self.resolution.current(0)
        self.reconnect_button.configure(text='重新播放')
        self.metric_labels['focus'].configure(text='单帧推理 / CPU')
        self.metric_labels['fps'].configure(text='视频帧率')
        self.hint.configure(text='逐帧回放电脑模型检测结果。\n开发板与云台未连接。')
        tk.Frame(self.sidebar, height=1, bg=RULE).pack(fill='x', pady=12)
        self.progress_label = self.label(self.sidebar, '00:00 / 00:23', 10, MUTED)
        self.progress_label.pack(anchor='w')
        self.timeline = tk.Canvas(self.sidebar, bg='#EFEFEB', height=3, bd=0, highlightthickness=0)
        self.timeline.pack(fill='x', pady=(8, 10))
        self.pause_button = tk.Button(self.sidebar, text='暂停播放', command=self._toggle_pause,
            bg='#F1F0ED', fg=TEXT, activebackground='#E8E7E3', bd=0, padx=12, pady=7,
            font=('Microsoft YaHei UI', 9), cursor='hand2')
        self.pause_button.pack(anchor='w')
        self.label(self.sidebar, '素材 / Mixkit · Eagle gliding', 8, MUTED).pack(anchor='w', pady=(12, 0))
        self.status.configure(text='正在读取本地演示视频…')

    def _worker(self):
        # Override the hardware worker. No serial port is opened in video mode.
        return

    def _request_reconnect(self):
        self.playback_start = time.monotonic()
        if self.paused_at is not None:
            self.paused_at = self.playback_start
        self.last_index = -1

    def _toggle_pause(self):
        now = time.monotonic()
        if self.paused_at is None:
            self.paused_at = now
        else:
            self.playback_start += now - self.paused_at
            self.paused_at = None
        self.pause_button.configure(text='继续播放' if self.paused_at is not None else '暂停播放')
        self._update_source()

    def _toggle_detect(self):
        super()._toggle_detect()
        self.mode_label.configure(text='鸟类检测 · 电脑模型结果回放' if self.settings['detect'] else '视频预览',
                                  fg=GREEN if self.settings['detect'] else MUTED)
        self.last_index = -1

    def _update_source(self):
        state = '已暂停' if self.paused_at is not None else '播放中'
        self.connection.configure(text=f"本地视频 · {self.data['width']} × {self.data['height']} · {state}", fg=GREEN)

    def _drain(self, reschedule=True):
        if self.closing:
            return
        if self.export_index is not None and reschedule:
            self.after(12, self._drain)
            return
        try:
            moment = self.paused_at if self.paused_at is not None else time.monotonic()
            elapsed = max(0., moment - self.playback_start)
            index = (self.export_index if self.export_index is not None else
                     int(elapsed * self.data['fps']) % self.data['frame_count'])
            if index != self.last_index:
                if index != self.last_index + 1:
                    self.capture.set(cv2.CAP_PROP_POS_FRAMES, index)
                ok, bgr = self.capture.read()
                if not ok:
                    raise RuntimeError(f'Cannot decode frame {index}')
                raw = Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
                self.last_raw_image = raw
                # Natural stock footage should retain its original white balance.
                self.last_corrected_image = raw
                if self.color_enabled.get():
                    from preview_color import PreviewWhiteBalance
                    if not hasattr(self, 'video_wb'):
                        self.video_wb = PreviewWhiteBalance()
                    self.last_corrected_image, _ = self.video_wb.apply(raw)
                self.last_image = self.last_corrected_image if self.color_enabled.get() else raw
                entry = self.data['frames'][index]
                self.last_message = dict(entry, width=self.data['width'], height=self.data['height'])
                self.connected = True
                self.last_index = index
                self._update_source()
                active = entry['target_detected'] and self.settings['detect']
                self.values['x'].configure(text=f"{entry['target_dx_px']:+.1f}" if active else '—')
                self.values['y'].configure(text=f"{entry['target_dy_px']:+.1f}" if active else '—')
                self.values['confidence'].configure(text=f"{entry['target_confidence']:.0%}" if active else '—')
                self.values['focus'].configure(text=f"{entry['inference_ms']:.1f} ms")
                self.values['fps'].configure(text=f"{self.data['fps']:.2f} fps")
                seconds = index / self.data['fps']
                self.progress_label.configure(text=f"{self._clock(seconds)} / {self._clock(self.data['duration_s'])}")
                self.timeline.delete('all')
                self.timeline.create_rectangle(0, 0, self.timeline.winfo_width() * seconds / self.data['duration_s'], 3,
                                               fill=GREEN, outline='')
                note = ('已检测到鸟类，主目标坐标随视频更新。' if active else
                        '当前帧未检测到鸟类。' if self.settings['detect'] else '视频预览，检测已停止。')
                self.status.configure(text=note + '  视频演示 · 电脑模型结果回放 · 未连接硬件', fg=MUTED)
                self._draw()
                if time.monotonic() - self.last_log_at >= 1:
                    (self.demo_output / 'status.json').write_text(
                        json.dumps(dict(source='video_demo', hardware_connected=False, playing=self.paused_at is None,
                                        detection_enabled=self.settings['detect'], **self.last_message),
                                   ensure_ascii=False, indent=2), encoding='utf-8')
                    self.last_log_at = time.monotonic()
        except Exception as exc:
            self.status.configure(text=f'视频演示暂不可用：{exc}', fg='#9F2F2D')
        if reschedule:
            self.after(12, self._drain)

    @staticmethod
    def _clock(seconds):
        seconds = int(seconds)
        return f'{seconds // 60:02d}:{seconds % 60:02d}'

    def _draw(self):
        super()._draw()
        if not self.last_image or not self.last_message or not self.settings['detect']:
            return
        message = self.last_message
        if not message['target_detected']:
            return
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        scale = min(w / message['width'], h / message['height'])
        x = w / 2 + message['target_dx_px'] * scale
        y = h / 2 + message['target_dy_px'] * scale
        self.canvas.create_line(w / 2, h / 2, x, y, fill='#E4E9D5', dash=(4, 5), width=1)
        self.canvas.create_oval(x - 4, y - 4, x + 4, y + 4, fill='#A1DE8C', outline='')
        self.canvas.create_text(w / 2 + 19, h / 2 + 13, text='(0, 0)', anchor='w',
                                fill='#EEEEDE', font=('Segoe UI', 9))

    def _start_recording(self):
        self.record_path.parent.mkdir(parents=True, exist_ok=True)
        self._request_reconnect()
        for button in (self.pause_button, self.reconnect_button, self.detect_button):
            button.configure(state='disabled', disabledforeground='white' if button is self.detect_button else TEXT)
        self.color_toggle.configure(state='disabled')
        self.resizable(False, False)
        self.overrideredirect(True)
        self.attributes('-topmost', False)
        self.update_idletasks()
        self.export_index = 0
        hwnd = ctypes.windll.user32.GetAncestor(self.winfo_id(), 2)
        self.recorder = threading.Thread(target=self._record, args=(hwnd,), daemon=True)
        self.recorder.start()
        self.after(200, self._check_recording)

    def _grab_export(self, hwnd, index, result, ready):
        try:
            # Render an exact source frame, then capture on Tk's own thread.
            # This prevents stale text from cross-thread PrintWindow calls and
            # never includes other desktop windows or operating-system overlays.
            self.export_index = index
            self._drain(reschedule=False)
            self.update_idletasks()
            result['image'] = ImageGrab.grab(window=hwnd).convert('RGB')
        except Exception as exc:
            result['error'] = str(exc)
        finally:
            ready.set()

    def _export_image(self, hwnd, index):
        ready = threading.Event()
        result = {}
        self.after(0, self._grab_export, hwnd, index, result, ready)
        if not ready.wait(15):
            raise RuntimeError('UI capture timed out')
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['image']

    def _record(self, hwnd):
        process = None
        error_stream = None
        try:
            sys.path.insert(0, str(ROOT / 'demo_tools'))
            import imageio_ffmpeg
            image = self._export_image(hwnd, 0)
            width, height = image.width // 2 * 2, image.height // 2 * 2
            error_stream = self.record_path.with_suffix('.encoder.log').open('wb')
            command = [imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-hide_banner', '-loglevel', 'error',
                       '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{width}x{height}', '-r', '24',
                       '-i', '-', '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                       '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(self.record_path)]
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                       stderr=error_stream, creationflags=subprocess.CREATE_NO_WINDOW)
            duration = self.data['duration_s']
            count = round(duration * 24)
            for i in range(count):
                if self.stop.is_set():
                    break
                index = min(int(i / 24 * self.data['fps']), self.data['frame_count'] - 1)
                image = self._export_image(hwnd, index).crop((0, 0, width, height))
                if i in (0, 120, 288):
                    image.save(self.record_path.parent / f'ui_frame_{i:04d}.png')
                process.stdin.write(image.tobytes())
            process.stdin.close()
            if process.wait(timeout=30):
                raise RuntimeError('Video encoder failed; see encoder log')
        except Exception as exc:
            self.record_error = str(exc)
        finally:
            if process and process.poll() is None:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
            if error_stream:
                error_stream.close()
            self.record_done.set()

    def _check_recording(self):
        if not self.record_done.is_set():
            self.after(200, self._check_recording)
            return
        result = dict(ok=self.record_error is None, output=str(self.record_path), error=self.record_error)
        self.record_path.with_suffix('.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        self.export_index = None
        if self.auto_close:
            self._close()
        else:
            for button in (self.pause_button, self.reconnect_button, self.detect_button, self.color_toggle):
                button.configure(state='normal')
            self.overrideredirect(False)
            self.attributes('-topmost', False)
            self.resizable(True, True)

    def _close(self):
        if self.closing:
            return
        self.closing = True
        self.stop.set()
        self.capture.release()
        self._finish_close()

    def _finish_close(self):
        if self.recorder and self.recorder.is_alive():
            self.after(100, self._finish_close)
        else:
            self.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, default=DEFAULT_VIDEO)
    parser.add_argument('--data', type=Path, default=DEFAULT_DATA)
    parser.add_argument('--model', type=Path, default=DEFAULT_MODEL)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--record', type=Path)
    parser.add_argument('--auto-close', action='store_true')
    args = parser.parse_args()
    if args.prepare:
        prepare(args.video, args.model, args.data)
    else:
        VideoDemoWindow(args.video, args.data, args.record, args.auto_close).mainloop()


if __name__ == '__main__':
    main()
