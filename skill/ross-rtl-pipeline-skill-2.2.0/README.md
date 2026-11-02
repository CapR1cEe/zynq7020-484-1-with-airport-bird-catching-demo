# ROSS 通用 RTL 流水线 Skill 2.2.0

本版继续保留**原有批注、中文设计说明、语义命名和手写式结构**。案例学习覆盖个人作者、
社区开源工程和学术实现；按源码、测试与测量证据选择方法。此前版本的必要验证记录保留。
这是社区 ROSS 兼容扩展，入口是 [vivado-rtl-pipeline-design](skills/vivado-rtl-pipeline-design/SKILL.md)。

## 这一轮学到了什么，如何落地

| 来源 | 吸收的方法 | skill 中的变化 |
|---|---|---|
| ZipCPU/wb2axip | skid 储存、输入假设与输出断言分工、不同缓冲选项 | 区分 proof、bounded check、cover；集成时验证上游满足假设 |
| PicoRV32 | 可选乘法寄存器、资源复用、不同延迟结果比较 | 同时检查真实接受率和延迟；额外寄存器不等于 II=1 |
| WangXuan95/FPGA-FixedPoint | 显式定点格式、舍入与饱和阶段 | 新增原创 nearest-even 舍入／饱和流水线与独立自检 |
| Abdelhadi Multiported-RAM | 读端口复制、XOR 反馈、冲突旁路 | 补充冲突合同、复制成本、旁路逻辑与内存响应对齐 |

本轮新增四个固定版本项目，结合此前研究共十三个项目来源。各案例记录读到的文件、
适用条件和没有验证的部分；不会把项目名气、仿真时钟或他人的 Fmax 当成本地性能结果。
上游测试源码经过阅读，未在本机执行上游回归或形式证明。

## 批注与手写风格

原有四份 RTL 和四份自检 testbench 与 2.1.0 **逐字节相同**。新增示例将舍入、饱和两级
寄存器明确写出，并在就近批注中解释负数 floor、半值取偶、扩位进位、饱和顺序、
overflow 含义、握手、reset 和剩余 ready 路径。不会为了套用某个项目而统一改名或删注释。
批注的前提变化时应更新解释。模块结构以便于维护和追踪流水级为准。

## 安装与调用

将 `skills/vivado-rtl-pipeline-design` 整个目录复制到客户端实际加载的 skills 根目录，
保留已有同名 skill 的副本后更新。使用 manifest 的加载器只合并本包的一条记录，
不要覆盖官方完整 manifest。支持本地插件的客户端可使用 `plugin.json`；具体安装入口仍需在目标环境验证。
重新加载后使用 `/vivado-rtl-pipeline-design`，或支持该语法的 `$vivado-rtl-pipeline-design`。
MCP 需要单独配置；该包不会改动 MCP 设置，也支持已安装的 Vivado CLI 和离线报告。

```text
使用 vivado-rtl-pipeline-design 优化我的 RTL。保留中文批注、现有命名与手写结构。
根据当前 top、golden、器件和 XDC 建立频率/II/延迟/资源合同。可学习个人作者、社区、
学术或官方案例，记录固定版本、实现和测试证据，吸收适用于本设计的方法与限制。
给出资源/端口规划、stage 表、可读 RTL 和独立自检，并根据实际布线报告迭代。
交付带批注 diff、实测结果和未完成项。
```

## 阅读与运行

- [新增社区案例和筛选方法](skills/vivado-rtl-pipeline-design/references/community-case-studies.md)
- [批注与手写 RTL 规范](skills/vivado-rtl-pipeline-design/references/readable-rtl.md)
- [流水线、资源与内存规划](skills/vivado-rtl-pipeline-design/references/pipeline-patterns.md)
- [TinyYOLO 项目经验](skills/vivado-rtl-pipeline-design/references/architecture-and-timing.md)
- [仿真与 MCP 使用](skills/vivado-rtl-pipeline-design/references/verification-and-mcp.md)
- [实际验证记录](validation/VALIDATION.md)与[机器可读证据](validation/evidence.json)

包完整性：`python -B validation/verify_package.py`。
独立复跑：`python -B validation/reproduce.py --build-dir <EXTERNAL_BUILD_DIR>
--vivado-bin <VIVADO_INSTALL>/bin --full-matrix`。需要已配置的工具；输出目录应在包外。
该命令运行 12 项 Python 测试、5 个默认 HDL 示例；`--full-matrix` 另加 6 组树与 7 组舍入配置。
Verilator lint 可使用 `--mode lint --backend verilator --verilator <EXECUTABLE>`。

## 结果边界

新舍入示例在八组配置中枚举全部输入位模式，并测试反压、在途复位、数据/状态/tag/last
对齐、两级延迟与 II=1；另做两个故障注入。最终运行结果和解压复现状态以验证记录为准。
没有对新模块测量资源、Fmax 或板上性能，也没有运行新的形式证明。
此前 200 MHz 完整 benchmark 的输出路径仍违例；内部路径正裕量不能代替整机签核。
旧的 OOC hold 失败与报告也继续保留。
不包含第三方实现、工具二进制或 TinyYOLO 私有数据。许可证：[MIT](LICENSE)；
来源与许可：[说明](THIRD_PARTY_NOTICES.md)。
