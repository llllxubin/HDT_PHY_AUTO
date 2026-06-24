# HDT TX PHY — W1 规格套件

把蓝牙 HDT TX PHY 协议转化为可交付 agent 实现的模块级规格 (W1) 的工作成果与可复用流程。

## 目录结构

```
W1_HDT_TX/
├── README.md              本文件
├── SKILL.md               ★ W1 流程方法论 (Claude 自动加载, 跨项目复用)
├── _TEMPLATE_module.md    ★ 空白模块 W1 模板 (七章骨架)
├── 00_toplevel.md         HDT TX 顶层数据通路 (v0.3, 阶段A 定稿)
└── modules/
    └── fec_encoder.md     已 frozen, 阶段B 打样样板, 可进 W2
```

★ = 可复用资产, 做任何新 PHY/DSP 模块都能用。

## 当前进度

- 阶段A (顶层地图): **完成**。链路 = MAC字节流 → interval_spacing → fec_encoder
  → puncturing → symbol_mapper → symbol_assembler → srrc_upsample → IQ@12MHz。
- 阶段B (逐模块 W1): fec_encoder **已 frozen**, 其余 6 个待起草。
- 全局已定: 48MHz 单一时钟域; 符号率 2Msym/s; ×6 上采样; SRRC β=0.4, 31抽头,
  系数7bit, IQ 12bit; symbol_mapper 10bit; LFSR 白化在 MAC 侧 (本 PHY 不做)。

## 剩余 6 个模块 (套 _TEMPLATE_module.md)

| 模块 | 规格就绪度 | 待定关键点 |
|---|---|---|
| interval_spacing | 高 (Table 3.4) | 边界逻辑、末段不足处理 |
| puncturing | 高 (Table 3.5) | 模式相位复位、与FEC 2bit对齐 |
| symbol_mapper | 高 (Table 7.4-7.6) | k索引复位、16QAM定点 |
| symbol_assembler | 高 (§7.4) | LTS: ZC-ROM(D7)、组装顺序状态机 |
| srrc_upsample | 中 | 定点细化、EVM裕量MATLAB确认、12MHz节拍如何在48MHz产生 |
| tx_ctrl_fsm | 中 | 统一调度三比特域模块(D1)、段边界flush |

顶层文档第6-7节有完整的开放问题 (D1/D5/D7/O4/O6/O7) 清单。

## 迁移到 Claude Code 接着干

本套件即"跨环境记忆载体"。在 Claude Code 终端:

1. 把整个 W1_HDT_TX/ 放进工程 repo, git 管理。
2. SKILL.md 放到 Claude Code 能识别 skill 的位置 (或在会话中让 Claude 先读它),
   Claude 即自动遵循这套 W1 方法论, 无需重述来龙去脉。
3. 让 Claude 先读 00_toplevel.md + SKILL.md + 一份已 frozen 的 fec_encoder.md,
   即可无缝接续起草剩余模块。
4. Claude Code 相比网页端的增量能力: 直接读写本地 RTL、实跑 Verible/VCS/Questa/
   Python参考模型/git, 真正闭合 W2→W3→W4→W5 自动回归 (网页端只能产出文件)。

## 复用到别的模块/项目

- 新模块: 复制 _TEMPLATE_module.md, 按七章填, 遵守 [协议]/[决策✓]/[默认]/[验证] 标记。
- 新项目: SKILL.md 与模板可直接搬, 先做该项目的 00_toplevel.md 顶层地图再逐模块。
- 判定锚点按 SKILL.md 决策表选, 不给每个模块硬造 MATLAB 模型。

## 下一步建议

并行推进两条线:
- 规格线: 继续起草 6 个模块 W1 (interval_spacing / puncturing 最快, 规格已明确)。
- 基础设施线: 建判定基础设施 (golden比对框架、covergroup骨架、mutation注入、
  YAML→SV interface+SVA 生成脚本)、单命令回归入口 (make test MODULE=xxx)。
  基础设施一次建好全模块复用, 是前期投入的复利点。
```
