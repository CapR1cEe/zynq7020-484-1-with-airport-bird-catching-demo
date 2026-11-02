# TinyYOLO 飞鸟视频演示

双击 `启动视频演示.cmd`，可离线查看约 23 秒的飞鸟视频，自动循环播放。界面沿用项目现有的简约桌面 UI，显示鸟类检测框、主目标中心、相对中心的 X/Y 像素坐标、置信度和播放进度。支持暂停、继续、重播和开关检测框。原片色彩默认保持不变。

本演示不连接串口、开发板、摄像头或舵机。检测框来自项目已有的 YOLOv3-tinyu 鸟类 ONNX 模型（416 × 416 输入），在电脑上通过 OpenCV DNN 实际计算后缓存，按视频帧同步回放。坐标和置信度由这些检测结果计算，未手工编造。本包播放不需要安装模型或推理框架。单帧推理时间是生成缓存时的电脑 CPU 耗时，视频帧率来自素材，不代表开发板的实时性能。

坐标使用 1280 × 720 原始画面：中心是 (0, 0)，右方 X 为正、下方 Y 为正；X/Y 指向主目标检测框的中心。窗口缩放不改变坐标单位。未检出目标或关闭检测时显示“—”。

## 运行环境

Windows Python 3.11 或更新版本，需要 tkinter。当前电脑使用 `C:\Python314\python.exe`，可直接启动。

若另一台电脑未安装依赖，请在本目录运行：

```powershell
python -m pip install -r requirements.txt
```

## 文件

- `启动视频演示.cmd`：演示入口。
- `bird_video_demo.py`：视频模式、ONNX 解码与录屏代码。
- `bird_preview.py`：与项目相同的桌面 UI。
- `demo_assets/eagle_flying.mp4`：演示项目使用的飞鸟画面。
- `demo_assets/eagle_detections.json`：563 帧真实电脑模型检测结果、坐标和耗时，附视频与模型 SHA-256。
- `demo_live/status.json`：播放时每秒更新的状态，明确标注 `source=video_demo` 和 `hardware_connected=false`，与实际板端日志分别保存。
- `TinyYOLO_bird_UI_demo.mp4`：同一界面的录屏，可直接播放，无需安装 Python。

录屏文件采用 H.264 / yuv420p，24 fps，无音频。界面中的数据来自缓存回放。若要重新生成检测缓存，可运行 `python bird_video_demo.py --prepare --model 模型路径`。本包没有附带模型权重。

## 视频素材来源

Mixkit：**Eagle gliding in a clear sky, bottom view**。

- 作品页：https://mixkit.co/free-stock-video/eagle-gliding-in-a-clear-sky-bottom-view-1706/
- 页面标示许可：Mixkit Stock Video Free License。
- 许可条款：https://mixkit.co/license/#videoFree

素材用于本项目 UI 演示，后续使用请遵循来源页面的许可条款。
