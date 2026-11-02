# 数据

`TinyYOLO_192/model/parameters.bin` 为 192×192 固定模型参数，12,213,056 字节。其 SHA-256 应与 `src/TinyYOLO_192/linux/model_config.json` 一致。

测试输入、golden 与期望哈希见 `sim/TinyYOLO_192/verification/golden_reference`；RTL 定点与闭环向量见 `sim/TinyYOLO_192/tests`。输入合同为 3×192×192、RGB CHW、float32 小端，数值范围 0–1，进入定点通路时按合同量化。没有在当前资料中找到对应训练工程或源 ONNX 权重，因此没有将其他输入尺寸的权重替代主工程参数。

离线视频及逐帧检测缓存放在 `src/video_demo/demo_assets`，属于电脑界面演示，来源、许可和 416×416 推理范围见该目录 README。
