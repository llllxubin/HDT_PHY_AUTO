# PROGRESS — fec_encoder 实现进度

> Claude Code 每轮迭代结束更新本文件。会话压缩后先读此文件恢复上下文, 不靠记忆。
> 人也可读此文件快速了解 agent 干到哪了。

## 当前状态
- 阶段: **基础设施就绪, RTL 未开始** (等用户发"开始"指令再写 rtl/fec_encoder.sv)
- make test 最近结果: 仅 `make stim` 验证通过 (46序列/1476bit); 其余步骤待 RTL
- RTL 文件: rtl/fec_encoder.sv (尚不存在)

## 已尝试方案 (避免重复踩坑)
| 轮次 | 改动 | make test 结果 | 失败原因/结论 |
|---|---|---|---|
| 0 | 建基础设施 (装verible+建Makefile) | make stim PASS | RTL 未写, 未跑完整 test |

## 当前卡点
- 无。等用户 go-ahead 后开始写 RTL。

## 下一步
- 实现 rtl/fec_encoder.sv (抽头见 spec §5 / ref_model.py): 
  a0=bit^s1^s3^s4, a1=bit^s0^s1^s2^s4, 移位 s={bit,s0,s1,s2,s3};
  code_out={a1,a0}; seq_start清零; seq_flush后自动追加5个0并拉term_done; #1非阻塞。
- 然后 make test, FAIL 则按报错改 RTL (每轮先 commit)。

## 环境/TB 已知问题记录
> 首次跑通时踩到的环境坑(VCS选项/库路径/TB时序), 记在这, 后续模块复用时省事。
- 工具: VCS O-2018.09-SP2 (license 27000@localhost), python3 3.8, GNU make 4.2.1。
- Verible 原本未装 → 已装 v0.0-4080 静态包到 ~/.local (软链 ~/.local/bin), lint 闸门可用。
- Makefile 已建: make test = lint→stim→compile→sim→compare。lint 纳入闸门(有warning即fail)。
- 路径耦合: TB 硬编码 sim/stim_bits.txt 与 sim/rtl_dump.txt; gen_stim/compare 须用同路径(Makefile已对齐)。
- simv 必须从工程根运行 (TB 用相对路径), Makefile 的 sim 目标已保证 CWD=根。
- 覆盖率: VCS -cm 已采集, 但暂未作为 test 失败条件 (先过0容差比对, 覆盖率/mutation 后续加)。
