#!/usr/bin/env python3
"""简洁的只读云台与板端状态监视器。"""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import ttk


ROOT = Path(__file__).resolve().parent
BACKEND = ROOT / "pan_tilt_monitor_backend.ps1"
BG = "#F4F6F5"
CARD = "#FFFFFF"
INK = "#1E2A32"
MUTED = "#718087"
LINE = "#E5EAE8"
GREEN = "#24845A"
AMBER = "#A76B16"
RED = "#B64A47"


class Monitor(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("云台实时监测")
        self.geometry("1040x760")
        self.minsize(900, 680)
        self.configure(bg=BG)
        self.queue = queue.Queue()
        self.backend = None
        self.reader = None
        self.connected = False
        self.target_offset = None
        self.target_frame_size = (640, 480)
        self.port = tk.StringVar(value="COM5")
        self.status = {}
        self._configure_style()
        self._build()
        self.protocol("WM_DELETE_WINDOW", self._close)
        self.after(100, self._drain_queue)
        self.after(250, self._toggle_connection)

    def _configure_style(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("Port.TEntry", fieldbackground=CARD, foreground=INK,
                        bordercolor=LINE, lightcolor=LINE, darkcolor=LINE, padding=7)
        style.configure("Connect.TButton", background="#243943", foreground="white",
                        padding=(14, 8), borderwidth=0, font=("Segoe UI", 9, "bold"))
        style.map("Connect.TButton", background=[("active", "#38515C")])

    def _card(self, parent, padx=0, pady=0):
        frame = tk.Frame(parent, bg=CARD, highlightbackground=LINE, highlightthickness=1)
        frame.grid_configure(padx=padx, pady=pady, sticky="nsew")
        return frame

    @staticmethod
    def _label(parent, text, size=10, color=INK, weight="normal", **kwargs):
        return tk.Label(parent, text=text, bg=CARD, fg=color,
                        font=("Segoe UI", size, weight), **kwargs)

    def _build(self):
        outer = tk.Frame(self, bg=BG, padx=28, pady=22)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)

        header = tk.Frame(outer, bg=BG)
        header.grid(row=0, column=0, sticky="ew", pady=(0, 20))
        header.columnconfigure(0, weight=1)
        title = tk.Frame(header, bg=BG)
        title.grid(row=0, column=0, sticky="w")
        tk.Label(title, text="PT", bg="#DCEAE4", fg=GREEN,
                 font=("Segoe UI", 10, "bold"), width=4, height=2).pack(side="left", padx=(0, 13))
        heading = tk.Frame(title, bg=BG)
        heading.pack(side="left")
        tk.Label(heading, text="云台实时监测", bg=BG, fg=INK,
                 font=("Segoe UI", 19, "bold")).pack(anchor="w")
        tk.Label(heading, text="开发板串口数据 · 只读", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", pady=(2, 0))

        controls = tk.Frame(header, bg=BG)
        controls.grid(row=0, column=1, sticky="e")
        tk.Label(controls, text="串口", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(0, 7))
        ttk.Entry(controls, textvariable=self.port, width=9, style="Port.TEntry").pack(side="left", padx=(0, 8))
        self.connect_button = ttk.Button(controls, text="连接", style="Connect.TButton",
                                         command=self._toggle_connection)
        self.connect_button.pack(side="left")

        self.connection_line = tk.Frame(outer, bg=BG)
        self.connection_line.grid(row=1, column=0, sticky="ew", pady=(0, 13))
        self.conn_dot = tk.Label(self.connection_line, text="●", bg=BG, fg=MUTED,
                                 font=("Segoe UI", 10))
        self.conn_dot.pack(side="left")
        self.conn_text = tk.Label(self.connection_line, text="尚未连接", bg=BG, fg=MUTED,
                                  font=("Segoe UI", 9))
        self.conn_text.pack(side="left", padx=(6, 0))
        self.update_text = tk.Label(self.connection_line, text="每秒读取一次", bg=BG,
                                    fg=MUTED, font=("Segoe UI", 9))
        self.update_text.pack(side="right")

        summary = tk.Frame(outer, bg=BG)
        summary.grid(row=2, column=0, sticky="ew", pady=(0, 14))
        for col in range(4):
            summary.columnconfigure(col, weight=1, uniform="summary")
        self.summary = {}
        for col, (key, title_text) in enumerate((
                ("inference", "TinyYOLO"), ("camera", "USB 摄像头"),
                ("controller", "云台控制"), ("runtime", "运行时间"))):
            card = tk.Frame(summary, bg=CARD, padx=15, pady=13,
                            highlightbackground=LINE, highlightthickness=1)
            card.grid(row=0, column=col, sticky="nsew", padx=(0 if col == 0 else 8, 0))
            tk.Label(card, text=title_text, bg=CARD, fg=MUTED,
                     font=("Segoe UI", 9)).pack(anchor="w")
            value = tk.Label(card, text="—", bg=CARD, fg=INK,
                             font=("Segoe UI", 15, "bold"))
            value.pack(anchor="w", pady=(7, 2))
            detail = tk.Label(card, text="等待板端数据", bg=CARD, fg=MUTED,
                              font=("Segoe UI", 8))
            detail.pack(anchor="w")
            self.summary[key] = (value, detail)

        body = tk.Frame(outer, bg=BG)
        body.grid(row=3, column=0, sticky="nsew")
        outer.rowconfigure(3, weight=1)
        body.columnconfigure(0, weight=3, uniform="body")
        body.columnconfigure(1, weight=2, uniform="body")
        body.rowconfigure(0, weight=1)

        left = tk.Frame(body, bg=BG)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        right = tk.Frame(body, bg=BG)
        right.grid(row=0, column=1, sticky="nsew", padx=(8, 0))

        target = tk.Frame(left, bg=CARD, padx=18, pady=16,
                          highlightbackground=LINE, highlightthickness=1)
        target.pack(fill="x", pady=(0, 14))
        target_header = tk.Frame(target, bg=CARD)
        target_header.pack(fill="x")
        self._label(target_header, "目标相对画面中心", 11, INK, "bold").pack(side="left")
        self.target_state = self._label(target_header, "等待检测数据", 8, MUTED)
        self.target_state.pack(side="right")
        self._label(target, "X：向右为正    Y：向下为正    原点：画面中心", 9, MUTED).pack(anchor="w", pady=(4, 12))

        offsets = tk.Frame(target, bg=CARD)
        offsets.pack(fill="x", pady=(0, 12))
        offsets.columnconfigure(0, weight=1, uniform="offset")
        offsets.columnconfigure(1, weight=1, uniform="offset")
        self.target_x = tk.Frame(offsets, bg="#F7F9F8", padx=14, pady=10)
        self.target_x.grid(row=0, column=0, sticky="nsew", padx=(0, 6))
        self.target_y = tk.Frame(offsets, bg="#F7F9F8", padx=14, pady=10)
        self.target_y.grid(row=0, column=1, sticky="nsew", padx=(6, 0))
        for panel, label in ((self.target_x, "水平偏移 X"), (self.target_y, "垂直偏移 Y")):
            tk.Label(panel, text=label, bg="#F7F9F8", fg=MUTED,
                     font=("Segoe UI", 9)).pack(anchor="w")
        self.target_x_value = tk.Label(self.target_x, text="— px", bg="#F7F9F8", fg=INK,
                                       font=("Segoe UI", 21, "bold"))
        self.target_x_value.pack(anchor="w", pady=(4, 0))
        self.target_y_value = tk.Label(self.target_y, text="— px", bg="#F7F9F8", fg=INK,
                                       font=("Segoe UI", 21, "bold"))
        self.target_y_value.pack(anchor="w", pady=(4, 0))

        self.target_plot = tk.Canvas(target, height=170, bg="#FBFCFB", bd=0,
                                     highlightthickness=1, highlightbackground=LINE)
        self.target_plot.pack(fill="x")
        self.target_plot.bind("<Configure>", lambda _event: self._draw_target_plot(), add="+")
        self._draw_target_plot()
        self._label(target, "中心为 (0, 0)；坐标单位为像素。相机或检测数据不可用时不显示坐标。",
                    8, MUTED, wraplength=680, justify="left").pack(anchor="w", pady=(10, 0))

        command = tk.Frame(left, bg=CARD, padx=18, pady=16,
                           highlightbackground=LINE, highlightthickness=1)
        command.pack(fill="both", expand=True)
        self._label(command, "控制器接口", 11, INK, "bold").pack(anchor="w")
        self._label(command, "GPIO 与当前命令总线", 9, MUTED).pack(anchor="w", pady=(3, 12))
        self.metrics = {}
        for key, label in (("gpio", "GPIO 导出"),
                           ("busy", "运行状态"), ("width", "当前共享脉宽总线")):
            row = tk.Frame(command, bg=CARD)
            row.pack(fill="x", pady=8)
            tk.Label(row, text=label, bg=CARD, fg=MUTED,
                     font=("Segoe UI", 9)).pack(side="left")
            value = tk.Label(row, text="—", bg=CARD, fg=INK,
                             font=("Segoe UI", 9, "bold"))
            value.pack(side="right")
            self.metrics[key] = value
            tk.Frame(command, bg=LINE, height=1).pack(fill="x")
        self._label(command, "监视器仅读取串口状态，不会驱动舵机。", 8, MUTED).pack(anchor="w", pady=(10, 0))

        system = tk.Frame(right, bg=CARD, padx=18, pady=16,
                          highlightbackground=LINE, highlightthickness=1)
        system.pack(fill="both", expand=True)
        self._label(system, "系统信息", 11, INK, "bold").pack(anchor="w")
        self._label(system, "板端状态与加速器遥测", 9, MUTED).pack(anchor="w", pady=(3, 12))
        self.system_values = {}
        for key, label in (("fault", "加速器故障遥测"), ("kernel", "Linux 内核"),
                           ("load", "系统负载"), ("uptime", "系统运行时间"),
                           ("latency", "串口往返")):
            row = tk.Frame(system, bg=CARD)
            row.pack(fill="x", pady=9)
            tk.Label(row, text=label, bg=CARD, fg=MUTED,
                     font=("Segoe UI", 9)).pack(side="left")
            value = tk.Label(row, text="—", bg=CARD, fg=INK,
                             font=("Segoe UI", 9, "bold"))
            value.pack(side="right")
            self.system_values[key] = value
            tk.Frame(system, bg=LINE, height=1).pack(fill="x")
        tk.Label(system, text="数据来源：板端 Linux 串口状态查询", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 8), wraplength=280, justify="left").pack(anchor="w", pady=(12, 0))

        footer = tk.Frame(outer, bg=BG)
        footer.grid(row=4, column=0, sticky="ew", pady=(13, 0))
        tk.Label(footer, text="状态每秒更新 4 次 · X/Y 为目标框中心相对画面中心的像素偏移",
                 bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(anchor="w")

    def _toggle_connection(self):
        if self.backend and self.backend.poll() is None:
            self._stop_backend()
            self.connected = False
            self.connect_button.configure(text="连接")
            self.conn_dot.configure(fg=MUTED)
            self.conn_text.configure(text="已断开")
            return
        port = self.port.get().strip().upper()
        if not port:
            self.conn_text.configure(text="请输入串口号")
            return
        self.port.set(port)
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            self.backend = subprocess.Popen(
                ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
                 "-ExecutionPolicy", "Bypass", "-File", str(BACKEND), "-Port", port],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                creationflags=creationflags)
        except OSError as exc:
            self.conn_text.configure(text=f"无法启动串口监视：{exc}")
            return
        self.connect_button.configure(text="断开")
        self.conn_dot.configure(fg=AMBER)
        self.conn_text.configure(text=f"正在连接 {port}…")
        self.reader = threading.Thread(target=self._read_backend, daemon=True)
        self.reader.start()

    def _read_backend(self):
        process = self.backend
        if not process or not process.stdout:
            return
        try:
            for line in process.stdout:
                try:
                    self.queue.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            self.queue.put({"connected": False, "error": "监视进程已退出"})

    def _drain_queue(self):
        try:
            while True:
                self.status = self.queue.get_nowait()
                self._render(self.status)
        except queue.Empty:
            pass
        self.after(100, self._drain_queue)

    @staticmethod
    def _fmt_time(seconds):
        seconds = max(0, int(seconds))
        hours, remainder = divmod(seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours:
            return f"{hours}小时 {minutes}分"
        if minutes:
            return f"{minutes}分 {seconds}秒"
        return f"{seconds}秒"

    def _draw_target_plot(self):
        canvas = getattr(self, "target_plot", None)
        if canvas is None or not canvas.winfo_exists():
            return
        canvas.delete("all")
        width = max(300, canvas.winfo_width())
        height = max(140, canvas.winfo_height())
        left, right = 24, width - 24
        top, bottom = 14, height - 14
        center_x = (left + right) / 2
        center_y = (top + bottom) / 2
        canvas.create_rectangle(left, top, right, bottom, outline=LINE, fill="#FBFCFB")
        for fraction in (0.25, 0.75):
            x = left + (right - left) * fraction
            y = top + (bottom - top) * fraction
            canvas.create_line(x, top, x, bottom, fill="#EDF0EF")
            canvas.create_line(left, y, right, y, fill="#EDF0EF")
        canvas.create_line(center_x, top, center_x, bottom, fill="#99A9A4", dash=(3, 3))
        canvas.create_line(left, center_y, right, center_y, fill="#99A9A4", dash=(3, 3))
        canvas.create_oval(center_x - 3, center_y - 3, center_x + 3, center_y + 3,
                           fill="#718087", outline="")
        if self.target_offset is None:
            canvas.create_text(center_x, center_y - 17, text="等待目标坐标", fill=MUTED,
                               font=("Segoe UI", 9))
            return
        dx, dy = self.target_offset
        frame_width, frame_height = self.target_frame_size
        point_x = center_x + dx / max(1, frame_width / 2) * (right - left) / 2
        point_y = center_y + dy / max(1, frame_height / 2) * (bottom - top) / 2
        point_x = min(right - 5, max(left + 5, point_x))
        point_y = min(bottom - 5, max(top + 5, point_y))
        canvas.create_line(center_x, center_y, point_x, point_y, fill=GREEN, width=2)
        canvas.create_oval(point_x - 6, point_y - 6, point_x + 6, point_y + 6,
                           fill=GREEN, outline="white", width=2)

    def _render_target(self, status, camera_ok):
        detected = bool(status.get("target_detected"))
        dx = status.get("target_dx_px")
        dy = status.get("target_dy_px")
        if detected and isinstance(dx, (int, float)) and isinstance(dy, (int, float)):
            self.target_offset = (float(dx), float(dy))
            self.target_frame_size = (max(1, int(status.get("frame_width", 640))),
                                      max(1, int(status.get("frame_height", 480))))
            self.target_x_value.configure(text=f"{dx:+.1f} px", fg=GREEN)
            self.target_y_value.configure(text=f"{dy:+.1f} px", fg=GREEN)
            quality = status.get("target_quality")
            detail = f" · 跟踪质量 {quality:.0%}" if isinstance(quality, (int, float)) else ""
            source = status.get("target_source")
            state = "已锁定目标" if source == "detection" else "跟踪中"
            self.target_state.configure(text=f"{state}{detail}", fg=GREEN)
        else:
            self.target_offset = None
            self.target_x_value.configure(text="— px", fg=INK)
            self.target_y_value.configure(text="— px", fg=INK)
            if not camera_ok:
                self.target_state.configure(text="摄像头未连接", fg=RED)
            elif status.get("detector_state") == "starting":
                self.target_state.configure(text="检测程序启动中", fg=AMBER)
            elif not status.get("detector_available", False):
                self.target_state.configure(text="检测程序不可用", fg=AMBER)
            else:
                self.target_state.configure(text="未检测到目标", fg=AMBER)
        self._draw_target_plot()

    def _render(self, status):
        is_connected = bool(status.get("connected"))
        self.connected = is_connected
        self.conn_dot.configure(fg=GREEN if is_connected else RED)
        if is_connected:
            self.conn_text.configure(text=f"{status.get('port', self.port.get())} 已连接")
            self.update_text.configure(text=f"最近更新 {status.get('updated_at', '—')}")
        else:
            error = status.get("error", "等待板端连接")
            self.conn_text.configure(text=f"{status.get('port', self.port.get())} · {error}")
            self.update_text.configure(text="自动重试中")

        if not is_connected:
            self._render_target({}, False)
            self.summary["inference"][0].configure(text="未连接", fg=MUTED)
            self.summary["inference"][1].configure(text="连接开发板后读取")
            self.summary["camera"][0].configure(text="—", fg=MUTED)
            self.summary["camera"][1].configure(text="等待板端数据")
            self.summary["controller"][0].configure(text="—", fg=MUTED)
            self.summary["controller"][1].configure(text="等待板端数据")
            self.summary["runtime"][0].configure(text="—", fg=MUTED)
            self.summary["runtime"][1].configure(text="等待板端数据")
            return

        inference = status.get("inference", False)
        self.summary["inference"][0].configure(
            text="设备就绪" if inference else "设备不可用", fg=GREEN if inference else RED)
        self.summary["inference"][1].configure(
            text="/dev/tinyyolo0 已加载" if inference else "/dev/tinyyolo0 未加载")

        camera = status.get("camera", "missing")
        camera_ok = camera not in ("missing", "", "None")
        self.summary["camera"][0].configure(text="已连接" if camera_ok else "未连接",
                                             fg=GREEN if camera_ok else MUTED)
        self.summary["camera"][1].configure(text=camera if camera_ok else "未检测到 /dev/video0")
        self._render_target(status, camera_ok)

        busy = status.get("busy", False)
        exported = status.get("gpio_exported", False)
        self.summary["controller"][0].configure(text="运行中" if busy else "空闲",
                                                 fg=AMBER if busy else GREEN)
        self.summary["controller"][1].configure(
            text="命令 GPIO 已导出" if exported else "舵机控制接口空闲")
        self.summary["runtime"][0].configure(text=self._fmt_time(status.get("uptime_s", 0)), fg=INK)
        self.summary["runtime"][1].configure(text=f"负载 {status.get('load', 0):.2f}")

        self.metrics["gpio"].configure(text="已导出" if exported else "空闲",
                                        fg=AMBER if exported else MUTED)
        self.metrics["busy"].configure(text="忙" if busy else ("完成" if status.get("done") else "空闲"),
                                        fg=AMBER if busy else GREEN)
        width = status.get("bus_width_us", 0)
        width_text = f"{width} μs · 共享总线" if exported and busy and 1000 <= width <= 2300 else "空闲时无脉宽回读"
        self.metrics["width"].configure(text=width_text)

        self.system_values["fault"].configure(
            text="当前接口未提供", fg=MUTED)
        kernel = str(status.get("kernel", "—"))
        if len(kernel) > 18:
            kernel = kernel[:15] + "…"
        self.system_values["kernel"].configure(text=kernel)
        self.system_values["load"].configure(text=f"{status.get('load', 0):.2f}")
        self.system_values["uptime"].configure(text=self._fmt_time(status.get("uptime_s", 0)))
        self.system_values["latency"].configure(text=f"{status.get('latency_ms', '—')} ms")

    def _close(self):
        self._stop_backend()
        self.destroy()

    def _stop_backend(self):
        if self.backend and self.backend.poll() is None:
            if self.backend.stdin:
                try:
                    self.backend.stdin.write("STOP\n")
                    self.backend.stdin.flush()
                except OSError:
                    pass
            try:
                self.backend.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.backend.terminate()
                try:
                    self.backend.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.backend.kill()
        self.backend = None


if __name__ == "__main__":
    Monitor().mainloop()
