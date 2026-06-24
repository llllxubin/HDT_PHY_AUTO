# HDT TX PHY — 顶层数据通路 (W1 阶段A · v0.3 定稿)

> 范围:whitening 及之前(encryption/CRC)在 MAC 侧。本 PHY TX 从 interval spacing 起,
> 终点 = 符号映射 + SRRC 成型 + 上采样到 12MHz 的 IQ,交模拟驱动层。
> 标记: [协议]=spec事实 · [决策]=待拍板 · [开放]=待澄清 · [确认✓]=本轮已定

---

## 1. 完整链路 (比特域 → 符号/采样域)

```
            ┌──────── 配置端口 (kstart 锁存) ────────┐
            │ format(PFI)·RI(rate)·PHY INT·zone长度  │
            │ Control Header 字段值 (供控制逻辑)      │
            ▼                                         ▼
MAC FIFO ─rd_en→ ┌──────── 比特域 ────────┐    ┌──────────┐
(当拍8bit有效)→  │ ① interval spacing      │←──│ 控制状态机│
                 │   (仅 fmt1 Payload)     │   │(序列/段) │
                 │ ② FEC encoder (1/2,K=6) │   └──────────┘
                 │ ③ puncturing            │
                 └───────────┬─────────────┘
                             │ 处理后比特流
                 ┌───────── 符号/采样域 ──────────┐
                 │ ④ symbol_mapper               │
                 │    π/4QPSK / 8PSK / 16QAM      │
                 │    (仅数据符号+终止符号)        │
                 │ ⑤ symbol_assembler            │
                 │    拼 preamble+CH+数据+PITS+终止│
                 │    (训练符号常量/ZC-ROM 多路选)│
                 │ ⑥ srrc_upsample               │
                 │    β=0.4, 2Msym/s → 12MHz (×6) │
                 └───────────┬───────────────────┘
                             ▼  IQ @ 12MHz, 12bit
                       模拟驱动层

通路顺序 [确认✓]: 所有训练序列均为"符号"(2Msym/s域),故符号组装在 SRRC 之前,
完整符号流统一过 SRRC,保证成型一致、相位连续。
```

---

## 2. 关键参数 [确认✓]

| 项 | 值 | 来源 |
|---|---|---|
| **时钟域** | **全部模块 48MHz 单一时钟域, 无 CDC** | 决策 |
| 符号率 | 恒定 2 Msym/s, Ts=0.5µs (与rate/调制无关) | 3.6 |
| 上采样比 | **恒定 ×6** (2M→12M) | 推导 |
| SRRC 滚降 β | 0.4 | 7.5 |
| 五种 rate 差异来源 | 每符号 bit 数 (2/3/4),非符号率 | 7.1 |

> 全局时钟约定: 后续所有模块 W1 默认继承 48MHz 单一时钟域。
> 注意: 数据通路跨越 48MHz(比特/符号处理) 与 12MHz(IQ输出采样率) 两个**速率**,
> 但 12MHz 输出是 48MHz 下的降速节拍(48/12=4)或由 SRRC 上采样逻辑在 48MHz 内生成,
> **不构成独立时钟域** —— SRRC 模块 W1 需明确 12MHz IQ 节拍如何在 48MHz 时钟下产生。

---

## 3. rate / 调制 / 编码 对照 [协议]

| Rate | 有效比特率 | 调制 | bit/符号 | Payload编码率(fmt0/fmt1 PL) |
|---|---|---|---|---|
| HDT2 | 2 Mb/s | π/4 QPSK | 2 | 1/2 |
| HDT3 | 3 Mb/s | π/4 QPSK | 2 | 3/4 |
| HDT4 | 4 Mb/s | 8PSK | 3 | 2/3 |
| HDT6 | 6 Mb/s | 16QAM | 4 | 3/4 |
| HDT7.5 | 7.5 Mb/s | 16QAM | 4 | 15/16 |

- Control Header: 恒 1/2、不打孔、2Mb/s
- fmt1 PDU Header: 恒 1/2、不打孔 (Table 3.3)
- fmt0 PDU Header+Payload / fmt1 Payload: 按上表 (Table 3.2)

---

## 4. 三种 format 序列路径 [协议]

| Format | PFI | 序列 |
|---|---|---|
| short | 0 | 仅 Control Header |
| format 0 | 0 | CH + (PDU Header+Payload 合一序列) |
| format 1 | 1 | CH + PDU Header(独立) + Payload Zone(多 PHY Interval, 各自独立 FEC+termination) |

---

## 5. 模块规格速查 [协议]

### ① interval spacing (仅 fmt1 Payload)
- 按 octet 切 PHY Interval,每段 octet 数 = Table 3.4 (PHY INT × rate)
- 含 CRC,不含 termination/padding;末段可更短

### ② FEC encoder
- rate 1/2, K=6, 32 状态, 5 寄存器, 非系统非递归
- G0=1+x²+x⁴+x⁵ , G1=1+x+x²+x³+x⁵ ; 初始全0
- 每序列末追加 5 个 0 (termination) 回全0态
- fmt1: 每个 PHY Interval 末各插一次 termination → 段边界编码器复位
- a0 先发

### ③ puncturing (Table 3.5)
- 1/2:[11] · 2/3:[1101] · 3/4:[110101] · 15/16:30bit
- 模式循环,末次截断对齐

### ⑤ symbol_assembler [确认✓ 规格]
训练序列全部是符号(2Msym/s),不经 symbol_mapper(数据符号和终止符号除外):
- STS: 4 符号 {-1, -j, j, 1}
- LTS: 17 符号 Zadoff-Chu, xu(k)=e^(-jπuk(k+1)/17)·e^(j2πp/17), u来自PCA, p查Table7.7
  → **建议: 按 u=1..16 预存 16×17 复符号 ROM,查表免算 exp** [决策 D7]
- GI: LTS 末 4 符号 {xu(13..16)} 拷贝
- 终止符号: 2 符号, 用当前调制表示全0bit (复用 symbol_mapper 喂全0)
- PITS: 6 符号 {-1,+1,+1,+1,-1,+1}, 仅 fmt1 interval 之间, 最后 interval 后不加
- preamble = 9×STS + GI + 2×LTS
- 组装顺序:
  preamble → CH符号+2终止 → (fmt0)PDU+PL+2终止
  → (fmt1)PDU Header+2终止 → [PHYInterval+2终止+PITS]×N (末段无PITS)

### ⑥ srrc_upsample [确认✓ 定点]
- SRRC β=0.4, ×6 上采样, **6相 polyphase**
- **31 抽头, 系数 7bit, IQ 输出 12bit** (输入符号 10bit)
- 内部乘累加位宽增长需规划 [决策 D5 细化]
- 验收锚点: RMS EVM < Table 3.6 上限 (按 rate); 7bit系数下16QAM裕量须MATLAB确认

### ④ symbol_mapper [确认✓]
- π/4 QPSK: 2bit/符号, 偶/奇符号 k 不同相位表(奇符号偏移π/4), Table 7.4
- 8PSK: 3bit/符号, Table 7.5
- 16QAM: 4bit/符号, Table 7.6, **÷√10 归一化吸收进定点表, 符号量化 10bit**
- 符号索引 k 复位: fmt0 首个PDU+PL符号; fmt1 PDU Header首符号 & 每PHY Interval首符号
- bit 不足凑整符号补 0; PSK类直接存I/Q定点查表

---

## 6. 架构决策点 [决策]

- **D1** 三比特域模块协调: 统一控制状态机 (推荐) vs 各自独立+边界串联?
- **D3** 数据通路位宽/吞吐: MAC 8bit/次, FEC 逐bit。bit-serial? 7.5Mb/s 吞吐对时钟要求?
- **D4** 段边界 flush: FEC清零+打孔相位复位+符号k复位, 由状态机统一发?
- **D5 [新]** SRRC 定点方案: IQ 位宽? 系数位宽/抽头数? 单级polyphase vs 多级? CSD/查表?
- **D6 [新]** symbol_mapper 星座定点位宽 (尤其 16QAM ÷√10 的精度预算, 影响 EVM)

---

## 7. 待澄清开放问题 [开放]

- ~~O5 训练序列拼装归属~~ → [确认✓] 归本 PHY, 设 symbol_assembler 模块, 在 SRRC 前
- **O6** 输出给驱动层接口: IQ 位宽12bit已定; I/Q 并行还是串行? 连续流还是带握手?
- **O3** Control Header 的 termination: 比特域FEC的5-bit termination, 与符号域的2个终止符号
  是两个不同层面的东西 → [确认✓ 理解] 比特域termination(5个0bit)在FEC; 符号域终止符号(2符号)在assembler。两者都存在,不矛盾。
- **O4** CTE 是否需 TX 处理? (spec 提到 fmt0/1 可含 CTE)
- **D7 [新]** LTS Zadoff-Chu: 16组ROM预存(推荐) vs 实时算?
- **O7 [新]** PCA→u→p 的推导(2.7.1.1 + Table7.7)由 PHY 做还是 MAC 给 u?

---

## 8. 模块清单 (7个模块, 阶段B 逐个起草)

| 模块 | 文件 | 状态 |
|---|---|---|
| tx_ctrl_fsm | modules/tx_ctrl_fsm.md | 待 D1 (默认统一状态机) |
| interval_spacing | modules/interval_spacing.md | 规格已明,待起草 |
| fec_encoder | modules/fec_encoder.md | 规格已明,待起草 |
| puncturing | modules/puncturing.md | draft 已起草,待 review (输出接口 §7.1 待拍板) |
| symbol_mapper | modules/symbol_mapper.md | 规格已明,待起草 |
| symbol_assembler | modules/symbol_assembler.md | 规格已明,待 D7 |
| srrc_upsample | modules/srrc_upsample.md | 定点已定,待 D5细化/EVM确认 |
