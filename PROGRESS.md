# PROGRESS — fec_encoder 实现进度

> Claude Code 每轮迭代结束更新本文件。会话压缩后先读此文件恢复上下文, 不靠记忆。
> 人也可读此文件快速了解 agent 干到哪了。

## 当前状态
- 阶段: **已通过** ✅ (rtl/fec_encoder.sv 实现完成, make test exit 0)
- make test 最近结果: **PASS** — lint 0 warning + 46序列/1706对全匹配 0容差
- RTL 文件: rtl/fec_encoder.sv (存在, ~135行, 组合输出版)

## 已尝试方案 (避免重复踩坑)
| 轮次 | 改动 | make test 结果 | 失败原因/结论 |
|---|---|---|---|
| 0 | 建基础设施 (装verible+建Makefile) | make stim PASS | RTL 未写 |
| 1 | 初版RTL: registered输出 | compile FAIL→修TB→compare FAIL | TB声明顺序bug(已修); registered输出致序列0少1对 |
| 2 | 改组合输出 (spec §5 0级流水) | **PASS exit 0** | 组合输出与TB posedge采样对齐, 边界竞争消除 |

## 当前卡点
- 无。fec_encoder 0容差比对已通过。

## 下一步 (增量, 非阻塞 — spec 完成定义剩余项)
- 覆盖率闸门: TB 加 covergroup(cp_state 32状态/x_state_bit), 回归加收敛门槛 (当前 -cm 仅采集未gate)。
- mutation kill rate ≥90%: 二级指标, 需搭变异注入。
- formal: 序列末态归零不变量 (当前靠输出比对间接保证)。
- 上述均需改 TB/加脚本, 属 ask 权限, 待用户决定是否本阶段做。

## 环境/TB 已知问题记录
> 首次跑通时踩到的环境坑(VCS选项/库路径/TB时序), 记在这, 后续模块复用时省事。
- 工具: VCS O-2018.09-SP2 (license 27000@localhost), python3 3.8, GNU make 4.2.1。
- Verible 原本未装 → 已装 v0.0-4080 静态包到 ~/.local (软链 ~/.local/bin), lint 闸门可用。
- Makefile 已建: make test = lint→stim→compile→sim→compare。lint 纳入闸门(有warning即fail)。
- 路径耦合: TB 硬编码 sim/stim_bits.txt 与 sim/rtl_dump.txt; gen_stim/compare 须用同路径(Makefile已对齐)。
- simv 必须从工程根运行 (TB 用相对路径), Makefile 的 sim 目标已保证 CWD=根。
- 覆盖率: VCS -cm 已采集, 但暂未作为 test 失败条件 (先过0容差比对, 覆盖率/mutation 后续加)。
