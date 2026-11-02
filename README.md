# TinyYOLO 192×192 飞鸟视觉与云台实验系统

作者：Luo Siyuan  
团队：CaPr1cEe

本项目基于 Zynq-7020，实现 192×192 输入的 TinyYOLO 推理、USB 相机取图、电脑预览和目标坐标显示，并附独立双轴舵机试验与 ROSS RTL 流水线 skill 2.2.0。主工程器件为 `xc7z020clg484-1`，PL 计算时钟 240 MHz，24 项点积通路与 16 路输出通道并行。

## 目录与入口

| 目录 | 内容 |
|---|---|
| `src/` | 冻结主工程 RTL、PS/Linux 源码；新版相机 UI、坐标状态更新、舵机与离线视频演示 |
| `sim/` | 原始 testbench、测试向量、回归脚本入口和已有验证记录 |
| `build/` | Vivado 工程、原构建脚本、综合实现报告、可移植工程组装入口 |
| `board/` | 位流、硬件平台、ARM 程序、板级操作入口及舵机测量记录 |
| `data/` | 192×192 模型参数与输入数据约定 |
| `skill/` | ROSS 兼容 RTL 流水线 skill、示例、验证、许可证与参考来源 |
| `report/` | 技术报告和中英文海报 |

## 快速复现

需要 Python 3.11 或更新版本，FPGA 构建使用 Vivado 2025.2。电脑 UI 还需要 tkinter 与其 `requirements.txt` 中的依赖。

1. 在本目录执行 `python build/prepare_project.py`。源码、参数、工程和验证文件会按原相对路径组装到 `build/workspace/TinyYOLO_192`，提交源文件不会被改写。可用 `--output D:/TinyYOLO_192_work` 指定新的空目录，较短的英文路径适合 Vivado 原生工具。
2. 打开组装目录中的 `OPEN_PROJECT.bat`，或用 Vivado 打开 `vivado/TinyYOLO_192.xpr`。该工程包含已保存的综合与实现结果。
3. 完整重新构建：进入组装目录，执行 `powershell -ExecutionPolicy Bypass -File scripts/rebuild_clockfix.ps1 -Vivado C:/AMDDesigntools/2025.2/Vivado/bin/vivado.bat`。命令依次重新综合、实现、导出，并检查时序与时钟拓扑。
4. 仿真入口和复跑方法见 [sim/README.md](sim/README.md)。已有结果与本次整理检查分开记录。
5. 板端部署、位流选择及 UI 启动见 [board/README.md](board/README.md)。只查看 UI，可先安装 `src/pc_ui/requirements.txt` 的依赖，再双击 `src/pc_ui/启动预览.cmd`。
6. 舵机工程分别执行 `python build/prepare_project.py --project servo_pan_tilt` 或 `--project servo_calibration` 组装；需要恢复 TinyYOLO 时，先组装主工程，或设置 `TINYYOLO_RESTORE_BIT` 指向明确选择的推理位流。

## 版本与验证范围

主工程始终使用 **192×192** 输入，参数文件 SHA-256 为 `dc66425157588a3de922edcd26454e72f80da2047edf0c5dcbeb0c552a04d4d0`。`src/TinyYOLO_192` 保留冻结核心，最近的界面、板端状态更新和舵机试验单独放在并列目录，避免覆盖既有验证基线。

- `board/TinyYOLO_192/firmware/final_192.*` 是最终时序修正版，保存建立余量 +0.067 ns、保持余量 +0.020 ns 的实现报告。该位流尚缺完整板级推理复测。
- `board/TinyYOLO_192/firmware/baseline/board_verified_192.*` 对应已有板级数值验证。基线单次推理约 727 ms、约 1.38 FPS，低于 5 FPS 目标；相机短序列完成计算，但有效鸟类检测与完整视觉云台闭环尚未证实。
- `src/servo_pan_tilt` 是独立双轴连续 PWM 试验，使用 H20/H19、50 Hz，回零脉宽 1560/2200 µs。边界路径为 1200/1900 µs 至 1870/2300 µs。最新记录包含 30 步接近和 120 步连续扫动；当时相机未连接，记录未确认物理运动或实测引脚波形。
- `src/board_updates/camera_infer.py` 增加实时目标中心坐标输出；受保护的串口更新脚本保留在 `src/servo_pan_tilt/deploy_live_status.ps1`。新版程序与冻结核心分别保存。
- `src/video_demo` 是离线 UI 演示，使用 **416×416 电脑模型的缓存检测结果**。视频帧率和电脑推理耗时不作为 192×192 板端性能。其录屏、素材来源及许可随演示保留。
- 当前资料没有与板端内核匹配的预编译 `.ko` 或完整 Linux 系统镜像。驱动源码、Makefile 和设备树合同已包含；重新部署需要现有板端系统及对应内核构建目录。未补造缺失镜像或测试结果。

整理修复了工程路径与启动脚本；原始日志中的数值、失败项、历史源文件哈希与验证边界保留。原始文件和提交文件的哈希映射见 `build/file_identity.json`。关键模型、位流、XSA 和 DCP 采用原文件，完整性可执行 `python build/verify_submission.py` 检查；本次离线检查结果见 `build/package_checks.json`。
