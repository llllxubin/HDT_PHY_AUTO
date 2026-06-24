# fec_encoder 微架构设计说明

> 给人读的设计文档。规格契约见 `W1/modules/fec_encoder.md`(frozen),
> 本文解释"为什么这么实现"。协议原文仅注章节号,不复制。
> 对应 RTL: `rtl/fec_encoder.sv`。撰写日期 2026-06-24(RTL 稳定后)。

---

## 1. 模块功能概述

`fec_encoder` 是 HDT TX PHY 链路第②模块(`interval_spacing → [fec_encoder] → puncturing`)。
对输入比特流做 **rate-1/2 卷积编码**:每输入 1 bit 输出 2 bit `{a1, a0}`,`a0` 先发。

- 非系统、非递归卷积码,约束长度 **K=6**(5 个延迟寄存器,32 状态),初始全 0。
- 生成多项式(协议 HDT Core Spec Vol6 PartB §3.4.3, Figure 3.10):
  - `G0(x) = 1 + x² + x⁴ + x⁵`  → 抽头 `{0,2,4,5}`
  - `G1(x) = 1 + x + x² + x³ + x⁵` → 抽头 `{0,1,2,3,5}`
- 序列末尾由上游发 `seq_flush`,本模块自动追加 **5 个 0**(termination),使编码器
  回到全 0 态;下一序列由 `seq_start` 重新从全 0 开始。
- FEC 永远输出 1/2 码,**无 rate 配置**;不同编码率由下游 `puncturing` 打孔实现。
  配置空间极小,无组合爆炸。
- 接口协议 `valid_only`:逐 bit 喂入,上游保证节奏,FEC 不反压上游;48MHz 单一
  时钟域,无 CDC。

不变量(验证用):同一输入序列(含 termination)的输出唯一确定;序列结束后内部
5 个寄存器必回全 0。

---

## 2. 数据通路框图

```
                          seq_start
                              │ (清零选择)
        bit_in ───────────────┼──────────────────────────────┐
                              ▼                               │
                     ┌─────────────────┐                     │
   bit_in_valid ───► │  输入选择 (组合)  │  eff_bit            │
   seq_flush ──────► │  优先级:         │──────────┐          │
   term_active ────► │  数据>termination│          │          │
                     └─────────────────┘          │          │
                              │ eff_state          │          │
                              │ (seq_start?0:state)│          │
                              ▼                    ▼          │
        ┌───────────────────────────────────────────────┐    │
        │  卷积组合函数 fec_pair(b, s)  —— 0 级流水        │    │
        │                                                │    │
        │  a0 = b ^ s[1] ^ s[3] ^ s[4]      (G0 {0,2,4,5})│    │
        │  a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4](G1{0,1,2,3,5})│  │
        └───────────────────────────────────────────────┘    │
                              │ {a1,a0}                        │
              rst_n 钳0 ──────┤                                │
                              ▼                                │
                  code_out[1:0] = {a1,a0}  (组合输出, a0=bit0) │
                  code_out_valid           (组合输出)          │
                                                               │
        移位寄存器 (1 级时序, posedge clk):                     │
        ┌──────────────────────────────────────────┐          │
        │  enc_state[4:0]   s[0]=最近历史bit          │◄─────────┘
        │  do_encode 时: enc_state <= {eff_state[3:0], eff_bit}
        │  s[0]◄eff_bit, 其余左移, 丢弃 s[4]
        └──────────────────────────────────────────┘
                              ▲
        termination 状态机 (1 级时序):
          term_active / term_cnt[2:0] / term_done(脉冲)
          seq_flush→第1个0 ... 第5个0→term_done 拉高一拍,状态回全0
```

要点:从 `bit_in`/`eff_state` 到 `code_out` 是纯组合 XOR 树(0 级流水);唯一的时序
元件是 `enc_state` 移位寄存器与 termination 计数/脉冲逻辑。

---

## 3. G0/G1 抽头映射与寄存器索引对应

### 3.1 状态约定

`enc_state[4:0]` 是 5 个延迟寄存器,约定 **`s[0]` = 最近一个历史 bit … `s[4]` = 最久
历史 bit**;当前输入 bit 视为 `x⁰`。移位时新 bit 进 `s[0]`,其余左移,丢弃 `s[4]`:
`enc_state <= {eff_state[3:0], eff_bit}`。

### 3.2 多项式 → 抽头 → 寄存器索引

| 多项式 | 数学抽头(x 的幂) | 对应信号 | RTL 表达式 |
|---|---|---|---|
| G0 = 1+x²+x⁴+x⁵ | {0,2,4,5} | b, s[1], s[3], s[4] | `a0 = b ^ s[1] ^ s[3] ^ s[4]` |
| G1 = 1+x+x²+x³+x⁵ | {0,1,2,3,5} | b, s[0], s[1], s[2], s[4] | `a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4]` |

**幂次 → 索引的换算理由**:`x⁰` 是当前输入 bit `b`;`xⁿ`(n≥1)对应"n 拍前的
bit",即 `s[n-1]`(因为 `s[0]` 存的是 1 拍前 / 最近历史 bit)。

- G0 抽头 {0,2,4,5}:`x⁰=b`, `x²=s[1]`, `x⁴=s[3]`, `x⁵=s[4]`。
- G1 抽头 {0,1,2,3,5}:`x⁰=b`, `x¹=s[0]`, `x²=s[1]`, `x³=s[2]`, `x⁵=s[4]`。

### 3.3 选择理由 / 约束

- 抽头映射**已由用户对照 Figure 3.10 核对锁定**(spec §5 / §7),与
  `ref/fec_encoder/ref_model.py` 注释严格一致。这是判定锚点的前提:RTL 与参考模型
  必须用同一抽头/移位约定,否则逐 bit 比对失去意义。
- 因此抽头位置、移位方向、`a0`/`a1` 顺序均为**锁定项,严禁"优化"**。mutation
  测试专门注入"抽头平移""漏抽头""a0/a1 调换"来证明任何偏离都会被测试杀死
  (见验证报告 §5)。
- 输出顺序 `code_out = {a1, a0}`,`bit0=a0` 先发(spec §2 决策),便于下游
  `puncturing` 按 2bit 组处理,免去输出端再做 2:1 串化。

---

## 4. seq_start / seq_flush / term_done 时序说明

三个边界信号决定序列起止,均与 `valid_only` 协议配合。

### 4.1 seq_start —— 序列首 bit 清零

- 与序列首个 `bit_in_valid` **同拍**。该拍组合路径用 `eff_state = 0`(而非当前
  `enc_state`)编码首 bit,使首 bit 输出只取决于该 bit 本身,与上一序列残留的
  脏状态无关。
- 时序:`eff_state = seq_start ? 5'd0 : enc_state`(组合);本拍 posedge 后
  `enc_state <= {4'b0, 首bit}`。
- 由 SVA **A1** 与定向自检(meta-morphic)双重保证:两种不同脏状态下对同一首 bit
  的输出必须相等。

### 4.2 seq_flush —— 自动 termination

- 上游在序列数据末尾后发 `seq_flush`。本模块自此**自动连续编码 5 个 0**回到全 0 态,
  期间 `code_out_valid` 保持有效。
- 实现:`seq_flush` 触发拍即第 1 个 0(`term_active←1, term_cnt←1`);其后
  `term_active` 续编,`term_cnt` 计到 5。组合路径在 `seq_flush || term_active` 时
  喂 `eff_bit=0`、用当前 `enc_state`。
- 优先级:数据 bit > termination(`bit_in_valid` 优先)。二者按协议不同拍,
  不会同拍冲突;若出现数据拍,termination 计数被复位。

### 4.3 term_done —— 完成脉冲

- 第 5 个 0 编码完(`term_active && term_cnt==4` 那拍),`term_done` **拉高一拍**
  (寄存输出,单拍脉冲),供上游状态机切下一序列;同时 `term_active←0, term_cnt←0`,
  此后 `enc_state` 回全 0。
- 由 SVA **A2**(flush 起第 5 拍 term_done、且 term_done 只在第 5 个 0 后拉高)与
  **A3**(term_done 时 `enc_state==0`)保证。

### 4.4 背靠背两序列

前序列 `term_done` 后,下一拍即可来下一序列的 `seq_start`+首 bit;因首 bit 走清零
路径,无需额外等待。corner case 中专门覆盖。

---

## 5. 流水线级数选择理由(0 级)

实现采用 **0 级流水**:组合输出 + 1 级状态寄存器,单周期吞吐 1 bit/cycle。

- **吞吐余量充足**:全链路 48MHz 单时钟,最高有效比特率 7.5Mb/s,FEC 处理编码前
  比特(逐 bit,8 周期/字节)。48MHz 下单周期处理 1bit 远高于最坏编码前比特率,
  无需为吞吐加流水。
- **组合路径浅**:`code_out` 仅是 4~5 输入 XOR 树,深度浅,48MHz(~20.8ns 周期)
  时序裕量极大,无打拍必要。
- **对齐简单 / 避免边界竞争**:组合输出在"喂入该 bit 的当拍"即有效,与上游驱动
  /下游采样同拍对齐。曾试过 registered 输出(见 PROGRESS.md 轮次 1):输出延迟一拍
  会跨越序列边界,与下一序列起始竞争,导致序列 0 少 1 对。改组合输出后边界竞争消除,
  0 容差比对通过。
- **代价**:0 级流水把组合负担留给下游时序收敛;鉴于路径极浅,这一代价可忽略。

---

## 6. 时序风险评估

| 风险点 | 评估 | 对策 |
|---|---|---|
| 组合输出关键路径 | 低。`code_out` = 浅 XOR 树 + rst_n 钳 0,48MHz 裕量大 | 无需打拍;若未来上调时钟可加 1 级输出寄存(需同步调整边界对齐) |
| 组合环 / latch | 无。`always_comb` 全分支赋值,无自反馈 | lint(verible)0 warning 闸门把守 |
| 复位 | 异步复位同步释放,rst_n 低有效;时序块全分支非阻塞 `#1` | 复位期组合输出钳 0(`code_out`/`code_out_valid`),使"复位期输出为 0"契约不依赖上游驱动;SVA A4 把守 |
| 序列边界竞争 | 已消除(0 级组合输出);registered 方案曾致边界少 1 对 | 见 §5;compare 0 容差 + 背靠背 corner 把守 |
| CDC | 无。全模块 48MHz 单时钟域 | spec §5 决策,无跨域处理 |
| 优先级冲突(数据 vs termination) | 协议保证不同拍;RTL 仍显式 `bit_in_valid` 优先,稳健 | 优先级编码 + termination 计数在数据拍复位 |

整体时序风险低:无算术、无 CDC、组合路径浅,主要工程关注点在序列边界对齐,已通过
组合输出方案 + 回归闸门覆盖。

---

## 7. 与 W1 spec 的对应关系

实现严格遵循 frozen spec,无功能性偏离:

- 抽头/移位/输出顺序:与 spec §1/§5 + ref_model.py 一致(锁定项)。
- 接口与握手:与 spec §2 一致(valid_only、seq_start 同拍清零、flush 后 5 个 0、
  term_done 一拍、复位期输出 0)。
- 流水级数:spec §5 默认 0 级,本实现采纳。
- 输出宽度:2bit 并行 `{a1,a0}`(spec §2 默认已确认)。

唯一"实现加固"(非偏离):复位期对 `code_out`/`code_out_valid` 组合钳 0,使
spec §2"复位期所有输出为 0"契约不依赖上游是否驱动输入(支撑 SVA A4)。
