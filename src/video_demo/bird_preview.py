"""Live board-camera preview, focus aid and actual TinyYOLO bird detections."""
import argparse
import base64
from datetime import datetime
import io
import json
from pathlib import Path
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageTk
import cv2
import numpy as np
from board_link import BoardLink
from preview_color import PreviewWhiteBalance

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / 'live'
OUTPUT.mkdir(exist_ok=True)
BG, SURFACE, TEXT, MUTED, RULE, GREEN = '#F7F6F3', '#FFFFFF', '#2F3437', '#787774', '#EAEAEA', '#346538'


class PreviewClient:
    def __init__(self, port='COM5'):
        self.link = BoardLink(port)
        self.pending = b''
        self.started = False
        self.latest = None
        self.white_balance = PreviewWhiteBalance()

    def start(self):
        source = ROOT / 'bird_preview_board.py'
        import hashlib
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        deployed = self.link.command('sha256sum /tmp/tinyyolo_bird_preview.py', check=False)
        if digest not in deployed:
            self.link.upload(source, '/tmp/tinyyolo_bird_preview.py')
        self.link.serial.write(b'python3 -u /tmp/tinyyolo_bird_preview.py 2>/tmp/tinyyolo_bird_preview_errors.log\r')
        self.started = True
        return self.read_message(15)

    def read_message(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                offset = line.find(b'TY_PREVIEW ')
                if offset >= 0:
                    return json.loads(line[offset+11:].strip())
                continue
            self.pending += self.link.serial.read(self.link.serial.in_waiting or 1)
            if len(self.pending) > 2_000_000:
                raise RuntimeError('Serial frame exceeded the size limit')
        raise TimeoutError('Camera preview response timed out')

    def frame(self, detect=False, width=320, height=240, confidence=.25):
        request = dict(action='frame', detect=detect, width=width, height=height, confidence=confidence)
        started = time.monotonic()
        self.link.serial.write((json.dumps(request)+'\n').encode('ascii'))
        message = self.read_message(35)
        message['roundtrip_ms'] = (time.monotonic()-started)*1000
        message['received_at'] = datetime.now().isoformat(timespec='milliseconds')
        if message.get('kind') == 'frame':
            jpeg = base64.b64decode(message.pop('jpeg_base64'), validate=True)
            raw_image = Image.open(io.BytesIO(jpeg)).convert('RGB')
            image, gains = self.white_balance.apply(raw_image)
            gray = cv2.cvtColor(np.asarray(raw_image), cv2.COLOR_RGB2GRAY)
            # Focus score is comparable only for the same scene and resolution.
            x, y = gray.shape[1]//4, gray.shape[0]//4
            score = cv2.Laplacian(gray[y:3*y, x:3*x], cv2.CV_64F).var()
            message['focus_score'] = round(float(score), 1)
            message['preview_color'] = dict(method='gray_world', gains_rgb=gains, preview_only=True)
            self.latest = message.copy()
            try:
                (OUTPUT/'last_frame_raw.jpg').write_bytes(jpeg)
                image.save(OUTPUT/'last_frame.jpg', format='JPEG', quality=90)
                temporary = OUTPUT/'status.tmp'
                temporary.write_text(json.dumps(message, ensure_ascii=False, indent=2), encoding='utf-8')
                try:
                    temporary.replace(OUTPUT/'status.json')
                except PermissionError:
                    pass  # A Windows reader may briefly hold the previous status file.
                with (OUTPUT/'events.jsonl').open('a', encoding='utf-8') as log:
                    log.write(json.dumps(message, ensure_ascii=False)+'\n')
            except OSError:
                pass  # Local logging must never stop the board's live preview.
            message['image'] = image
            message['raw_image'] = raw_image
        return message

    def close(self):
        if self.started:
            try:
                self.link.serial.write(b'{"action":"quit"}\n')
                self.read_message(12)
            except Exception:
                pass
        self.link.close()


class PreviewWindow(tk.Tk):
    def __init__(self, port):
        super().__init__()
        self.title('TinyYOLO · 相机预览与鸟类检测')
        self.geometry('1120x770')
        self.minsize(920, 640)
        self.configure(bg=BG)
        self.messages = queue.Queue(maxsize=2)
        self.settings = dict(detect=False, width=320, height=240, confidence=.25)
        self.stop = threading.Event()
        self.reconnect = threading.Event()
        self.connected = False
        self.closing = False
        self.last_message = None
        self.last_image = None
        self.last_raw_image = None
        self.last_corrected_image = None
        self.color_enabled = tk.BooleanVar(value=True)
        self.last_receive = None
        control = OUTPUT/'control.json'
        self.control_stamp = control.stat().st_mtime_ns if control.exists() else None
        self.photo = None
        self.port = port
        self._build()
        self.protocol('WM_DELETE_WINDOW', self._close)
        self.after(50, self._drain)
        self.worker = threading.Thread(target=self._worker, daemon=True)
        self.worker.start()
        self.lift()
        self.attributes('-topmost', True)
        self.after(1800, lambda: self.attributes('-topmost', False))

    def label(self, parent, text, size=10, color=TEXT, **kw):
        return tk.Label(parent, text=text, bg=parent['bg'], fg=color,
                        font=('Microsoft YaHei UI', size), **kw)

    def _build(self):
        style = ttk.Style(self)
        style.theme_use('clam')
        style.configure('Preview.TCombobox', fieldbackground=SURFACE, padding=6,
                        font=('Microsoft YaHei UI',9), bordercolor=RULE)
        outer = tk.Frame(self, bg=BG, padx=24, pady=20)
        outer.pack(fill='both', expand=True)
        header = tk.Frame(outer, bg=BG)
        header.pack(fill='x', pady=(0, 18))
        self.heading = self.label(header, '相机预览', 20)
        self.heading.pack(side='left')
        self.connection = self.label(header, self.port+' · 正在读取开发板', 10, MUTED)
        self.connection.pack(side='right')
        body = tk.Frame(outer, bg=BG)
        body.pack(fill='both', expand=True)
        sidebar = tk.Frame(body, bg=SURFACE, padx=16, pady=14, width=256,
                           highlightbackground=RULE, highlightthickness=1)
        sidebar.pack(side='right', fill='y', padx=(16, 0))
        sidebar.pack_propagate(False)
        self.sidebar = sidebar
        self.label(sidebar, '鸟类检测', 14).pack(anchor='w')
        self.mode_label = self.label(sidebar, '调焦预览', 9, MUTED)
        self.mode_label.pack(anchor='w', pady=(2, 10))
        actions=tk.Frame(sidebar,bg=SURFACE)
        actions.pack(fill='x',pady=(0,12))
        self.detect_button = tk.Button(actions, text='开始检测', command=self._toggle_detect,
            bg=TEXT, fg='white', activebackground='#454B4F', activeforeground='white',
            bd=0, padx=9, pady=6, font=('Microsoft YaHei UI', 9), cursor='hand2', state='disabled')
        self.detect_button.pack(side='left',fill='x',expand=True)
        self.reconnect_button = tk.Button(actions, text='重新连接', command=self._request_reconnect,
            bg='#F1F0ED', fg=TEXT, activebackground='#E8E7E3', bd=0, padx=9,pady=6,
            font=('Microsoft YaHei UI',9), cursor='hand2')
        self.reconnect_button.pack(side='right',padx=(6,0))
        self.resolution_label = self.label(sidebar, '预览画质', 9, MUTED)
        self.resolution_label.pack(anchor='w')
        self.resolution = ttk.Combobox(sidebar, state='readonly', style='Preview.TCombobox',
                                      values=('快速预览 · 320 × 240', '细节预览 · 640 × 480'))
        self.resolution.current(0)
        self.resolution.pack(fill='x', pady=(4,0))
        self.resolution.bind('<<ComboboxSelected>>', self._resolution_changed)
        self.color_toggle = tk.Checkbutton(sidebar, text='颜色校正', variable=self.color_enabled,
            command=self._color_changed, bg=SURFACE, fg=TEXT, activebackground=SURFACE,
            selectcolor=SURFACE, bd=0, highlightthickness=0,
            font=('Microsoft YaHei UI', 9), cursor='hand2', anchor='w')
        self.color_toggle.pack(anchor='w', pady=(6, 0))
        tk.Frame(sidebar, height=1, bg=RULE).pack(fill='x', pady=10)
        self.label(sidebar, '目标相对画面中心', 10).pack(anchor='w')
        self.values = {}
        coordinates = tk.Frame(sidebar,bg=SURFACE)
        coordinates.pack(fill='x',pady=(7,8))
        for col,(key,name) in enumerate((('x','X / 水平 · px'),('y','Y / 垂直 · px'))):
            coordinates.columnconfigure(col,weight=1,uniform='offset')
            column=tk.Frame(coordinates,bg=SURFACE)
            column.grid(row=0,column=col,sticky='nw')
            self.label(column,name,9,MUTED).pack(anchor='w')
            value=self.label(column,'—',16)
            value.pack(anchor='w',pady=(3,0))
            self.values[key] = value
        self.metric_labels = {}
        for key,name in (('confidence','目标置信度'),('focus','中心清晰度'),('fps','刷新率')):
            row=tk.Frame(sidebar,bg=SURFACE)
            row.pack(fill='x',pady=4)
            self.metric_labels[key] = self.label(row,name,9,MUTED)
            self.metric_labels[key].pack(side='left')
            value=self.label(row,'—',10)
            value.pack(side='right')
            self.values[key]=value
        tk.Frame(sidebar,height=1,bg=RULE).pack(fill='x',pady=10)
        self.hint = self.label(sidebar, '调焦时保持景物不动，比较中心清晰度。\n颜色校正仅用于预览，可取消查看原图。',
                              8,MUTED,justify='left',wraplength=210)
        self.hint.pack(anchor='w')
        self.canvas = tk.Canvas(body, bg='#242829', highlightbackground=RULE, highlightthickness=1, bd=0)
        self.canvas.pack(side='left', fill='both', expand=True)
        self.canvas.bind('<Configure>', lambda event: self._draw())
        self.status = self.label(outer, '正在打开摄像头…', 9, MUTED, anchor='w',justify='left',height=2)
        self.status.pack(fill='x', pady=(10, 2))
        self.status.bind('<Configure>',lambda event:self.status.configure(wraplength=max(200,event.width-8)))
        self.label(outer, '画面中心为 (0, 0) · X 向右为正，Y 向下为正 · 坐标单位 px', 9, MUTED).pack(anchor='w')

    def _toggle_detect(self):
        if not self.connected or self.closing:
            return
        self.settings['detect'] = not self.settings['detect']
        active = self.settings['detect']
        self.detect_button.configure(text='停止检测' if active else '开始检测')
        self.mode_label.configure(text='鸟类检测中' if active else '调焦预览', fg=GREEN if active else MUTED)
        if not active:
            for key in ('x', 'y', 'confidence'):
                self.values[key].configure(text='—')
        self._draw()

    def _request_reconnect(self):
        self.connected=False
        self.detect_button.configure(state='disabled')
        self.status.configure(text='正在重新连接摄像头…',fg=MUTED)
        self.reconnect.set()

    def _resolution_changed(self, _event):
        self.settings['width'], self.settings['height'] = ((640, 480) if self.resolution.current() else (320, 240))

    def _color_changed(self):
        self.last_image = self.last_corrected_image if self.color_enabled.get() else self.last_raw_image
        self._draw()

    def _put(self, message):
        try:
            self.messages.put_nowait(message)
        except queue.Full:
            self.messages.get_nowait()
            self.messages.put_nowait(message)

    def _worker(self):
        while not self.stop.is_set():
            client = None
            self.reconnect.clear()
            try:
                self._put(dict(kind='connecting'))
                client = PreviewClient(self.port)
                ready = client.start()
                if ready.get('kind') != 'ready':
                    raise RuntimeError(str(ready))
                failures = 0
                while not self.stop.is_set() and not self.reconnect.is_set():
                    message = client.frame(**self.settings.copy())
                    self._put(message)
                    failures = failures+1 if message.get('kind') == 'error' else 0
                    if failures >= 3:
                        raise RuntimeError('Camera failed repeatedly: '+message.get('error',''))
                    self.stop.wait(.12 if failures == 0 else 1)
            except Exception as exc:
                self._put(dict(kind='error', error=str(exc)))
            finally:
                if client:
                    client.close()
            if not self.stop.is_set():
                self.reconnect.wait(3)

    def _drain(self):
        control = OUTPUT/'control.json'
        try:
            stamp = control.stat().st_mtime_ns
            if stamp != self.control_stamp:
                data = json.loads(control.read_text(encoding='utf-8'))
                self.control_stamp = stamp
                if data.get('close'):
                    self._close()
                    return
                if data.get('reconnect'):
                    self._request_reconnect()
                if 'detect' in data and bool(data['detect']) != self.settings['detect']:
                    self._toggle_detect()
                if data.get('width') in (320,640):
                    self.resolution.current(1 if data['width']==640 else 0)
                    self._resolution_changed(None)
                if 'color_correction' in data:
                    self.color_enabled.set(bool(data['color_correction']))
                    self._color_changed()
        except (OSError,ValueError):
            pass
        try:
            while True:
                message = self.messages.get_nowait()
                if message.get('kind') != 'frame':
                    self.connected=False
                    self.detect_button.configure(state='disabled')
                    for key in ('x','y','confidence','fps'):
                        self.values[key].configure(text='—')
                    self.connection.configure(text=self.port+' · 正在连接',fg=MUTED)
                    if message.get('kind') == 'error':
                        no_camera=message.get('camera_connected') is False
                        text=('未检测到板端摄像头。接回开发板 USB HOST 后会自动恢复。' if no_camera else
                              '相机连接暂不可用，正在重试。也可点击「重新连接」。')
                        self.status.configure(text=text,fg='#9F2F2D')
                        self.connection.configure(text=self.port+(' · 摄像头未连接' if no_camera else ' · 等待连接'),fg='#956400')
                        try:
                            with (OUTPUT/'ui_errors.log').open('a',encoding='utf-8') as log:
                                log.write(datetime.now().isoformat()+' '+message.get('error','')+'\n')
                        except OSError:
                            pass
                    else:
                        self.status.configure(text='正在连接开发板并打开摄像头…',fg=MUTED)
                    continue
                self.connected=True
                self.detect_button.configure(state='normal')
                self.last_corrected_image = message.pop('image')
                self.last_raw_image = message.pop('raw_image')
                self.last_image = self.last_corrected_image if self.color_enabled.get() else self.last_raw_image
                self.last_message = message
                now = time.monotonic()
                if self.last_receive is not None:
                    self.values['fps'].configure(text=f'{1/max(.01,now-self.last_receive):.1f} fps')
                self.last_receive = now
                self.connection.configure(text=f"{self.port} · {message['width']} × {message['height']} · 已连接", fg=GREEN)
                self.values['focus'].configure(text=str(message['focus_score']))
                detected = message['target_detected'] and self.settings['detect']
                self.values['x'].configure(text=f"{message['target_dx_px']:+.1f}" if detected else '—')
                self.values['y'].configure(text=f"{message['target_dy_px']:+.1f}" if detected else '—')
                self.values['confidence'].configure(text=f"{message['target_confidence']:.0%}" if detected else '—')
                error = message.get('detection_error')
                note = ('检测程序暂不可用，预览继续运行。' if error else
                        ('检测到鸟类' if detected else '未检测到鸟类') if message['detection_enabled'] else
                        '请缓慢转动镜头调焦，观察画面中央细节；清晰后点击「开始检测」。')
                self.status.configure(text=note, fg='#9F2F2D' if error else MUTED)
                self._draw()
        except queue.Empty:
            pass
        if self.last_receive is not None and time.monotonic()-self.last_receive > 7:
            self.connection.configure(text=self.port+' · 画面等待更新', fg='#956400')
            for key in ('x','y','confidence','fps'):
                self.values[key].configure(text='—')
        if self.closing:
            return
        self.after(60, self._drain)

    def _draw(self):
        canvas = self.canvas
        canvas.delete('all')
        w, h = canvas.winfo_width(), canvas.winfo_height()
        if self.last_image is None:
            canvas.create_text(w/2, h/2, text='等待开发板画面', fill='#D2D6D3', font=('Microsoft YaHei UI', 13))
            return
        image = self.last_image
        ratio = min(w/image.width, h/image.height)
        iw, ih = max(1,int(image.width*ratio)), max(1,int(image.height*ratio))
        left, top = (w-iw)/2, (h-ih)/2
        self.photo = ImageTk.PhotoImage(image.resize((iw,ih), Image.Resampling.BILINEAR))
        canvas.create_image(w/2, h/2, image=self.photo)
        canvas.create_line(w/2-14,h/2,w/2+14,h/2,fill='#EEEEDE',width=1)
        canvas.create_line(w/2,h/2-14,w/2,h/2+14,fill='#EEEEDE',width=1)
        message = self.last_message
        if not self.settings['detect']:
            return
        sx, sy = iw/message['width'], ih/message['height']
        for box in message.get('detections', []):
            x1,y1,x2,y2 = box['xyxy']
            x1,x2 = left+x1*sx, left+x2*sx
            y1,y2 = top+y1*sy, top+y2*sy
            canvas.create_rectangle(x1,y1,x2,y2,outline='#A1DE8C',width=2)
            canvas.create_text(x1+4,max(top+10,y1-10),anchor='w',text=f"bird {box['score']:.0%}",
                               fill='#A1DE8C',font=('Segoe UI',10,'bold'))

    def _close(self):
        if self.closing:
            return
        self.closing=True
        self.stop.set()
        self.reconnect.set()
        self.status.configure(text='正在关闭摄像头与检测程序…')
        self.detect_button.configure(state='disabled')
        self._await_close()

    def _await_close(self):
        if self.worker.is_alive():
            self.after(100, self._await_close)
        else:
            self.destroy()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', default='COM5')
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--detect', action='store_true')
    args = parser.parse_args()
    if args.probe:
        client = PreviewClient(args.port)
        try:
            print(client.start(), flush=True)
            frame = client.frame(detect=args.detect)
            frame.pop('image', None)
            frame.pop('raw_image', None)
            print(json.dumps(frame, ensure_ascii=False), flush=True)
        finally:
            client.close()
    else:
        PreviewWindow(args.port).mainloop()
