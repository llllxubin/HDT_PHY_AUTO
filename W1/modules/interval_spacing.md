# W1 模块规格契约 — interval_spacing

> 阶段B 草稿。本文件是喂给 W2(RTL生成)的唯一权威输入。
> 字段标记: [协议]=spec事实 · [决策✓]=已拍板 · [默认]=Claude填的合理默认值,待你review · [验证]=验证意图
> 上游顶层: 见 00_toplevel.md v0.3 (链路第①模块, 比特域最前)

---

## 0. 元信息
- module_name: `interval_spacing`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] HDT Core Spec Vol6 PartB §3.4.2 (Interval spacing), Table 3.4;
  Payload Zone 构成 §2.7.3; PDU Control 字段 §2.7.2 (PHY INT 2bit); rate 来源 §3.4 Table 3.2
- 在链路中的位置: MAC(已白化 Payload octet 流) → **[interval_spacing]** → fec_encoder → puncturing
- status: frozen   # draft / reviewed / frozen  —— 原已 frozen; 2026-06-25 加 pass-through 串化模式(升级为全链路通用 octet→bit 串化器, 服务 CH/PDU/fmt0, tx_ctrl_fsm ②) + bd_en 门控注脚(①); 降回 reviewed 待人重新 frozen
- 全局约定继承: 见 00_toplevel.md (48MHz 单一时钟域, 无 CDC; MAC kstart 锁存配置, 同步 pull)

---

## 1. 功能描述 [协议]

本模块是**全链路通用 octet→bit 串化器**,两种模式由 tx_ctrl_fsm 驱动 [决策✓ ②]:
- **(a) 切分模式** (`ivs_passthru=0`, fmt1 Payload): 按 Table 3.4 切 PHY Interval + zone padding;
- **(b) pass-through 串化模式** (`ivs_passthru=1`, Control Header / PDU Header / fmt0 PDU+PL):
  整 zone 当**一条连续序列**, 只串化、**不切分、不 zone padding**, 串满 `passthru_bit_len` 个 bit 即收尾。
两模式都做 octet→bit 串化、驱 rd_en、在序列首/末发 seq_start/seq_flush。`ivs_en=0` 时模块 idle 不产出
(preamble/PITS/idle 等非 bit-域期)。

把 MAC 送来的、**已白化**的 Payload Zone octet 流切成若干 "PHY Interval"(切分模式),并把每段
**串化为 1bit/cycle 喂给 fec_encoder**,同时在每段首/末发边界标记,使 FEC 对每个
PHY Interval 各自独立编码 + 追加 termination + 复位(§3.4.3)。

- **每段 octet 数 N** = `PHY INT`(2bit, 来自 PDU Control) × rate(RI) 查 **Table 3.4**:

  | PHY INT \ rate | HDT2 | HDT3 | HDT4 | HDT6 | HDT7.5 |
  |---|---|---|---|---|---|
  | 0b00 | 16 | 24 | 32 | 48 | 60 |
  | 0b01 | 32 | 48 | 64 | 96 | 120 |
  | 0b10 | 48 | 72 | 96 | 144 | 180 |
  | 0b11 | 64 | 96 | 128 | 192 | 240 |

  [协议] 这些 octet 数 **含 CRC,但不含 termination 与"符号补齐"padding 位**。
- **末段更短** [协议]:Payload Zone 总 octet 数 L 若非 N 的整数倍,最后一段比其它段短。
- **zone padding(本模块做)** [协议 §2.7.3 + 决策✓ KD-3]:format1 若 Payload Zone 总长
  L 落在 **1–15 octet**,本模块在末 CRC 后用**全 0 octet 补齐到 16 octet** 再切分;
  L 字段不计这些 padding(即输入给本模块的 L 是不含 padding 的真实长度)。L≥16 不补;
  L=0(Empty Payload)整个 Payload Zone 不存在 → 本模块不被调用。
  > 注意区分两种 padding: (a) 本模块做的 **zone padding(1–15→16)**; (b) symbol_mapper/
  > assembler 端的 **符号补齐 padding**(Table 3.4 已排除,不在本模块)。两者不同层面。
- **边界标记** [决策✓ KD-4 默认]:每个 PHY Interval 首个 bit 发 `seq_start`、末个数据 bit
  之后发 `seq_flush` 给 FEC(触发 termination + 编码器复位);与 fec_encoder/puncturing
  的 seq_start 同源,统一由控制状态机调度(D1/D4)。
- **粒度** [协议]:切分以 octet 为单位,边界恒落在 octet 边界;本模块再 octet→bit 串化。

本模块**不变换数据内容**:除 zone padding 外,比特原样透传,只做切分 + 串化 + 边界。

不变量(验证用):
- **长度守恒**:所有 PHY Interval 数据长度之和 = L_eff(L_eff = (1≤L≤15)?16:L);
  非末段长度恒 = N,末段长度 = L_eff − (段数−1)×N ∈ [1, N]。
- **段数**:`ceil(L_eff / N)`;`seq_flush` 拉高次数 = 段数。
- **串化守恒**:`bit_out_valid` 高的拍数 = L_eff × 8。
- **透传**:去掉 zone padding 后,输出 bit 序列 == 输入 octet 流按约定位序展开(逐位相等)。
- **确定性**:给定 (phy_int, rate, L, 输入数据) → 输出唯一确定。

---

## 2. 接口契约 [决策✓ + 默认]

```yaml
# ---- 上游: MAC Payload octet 流 (8bit/cycle, 同步 pull) ----
interface: ivs_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: valid_only      # 与比特域链路一致, 不反压; 同步 pull (rd_en 当拍取数当拍有效)
signals:
  - {name: octet_in,       dir: input,  width: 8, desc: "[协议] MAC 送来的已白化 Payload octet (含 CRC)"}
  - {name: octet_in_valid, dir: input,  width: 1, desc: "本拍 octet 有效 (同步 pull 当拍有效)"}
  - {name: rd_en,          dir: output, width: 1, desc: "[决策✓ KD-rd_en] 本模块驱动的 MAC FIFO 取数请求; 串化 1 octet/8拍, 故每 8 拍 pull 一次新 octet"}

# ---- 配置 (kstart 锁存, 序列内不变) ----
interface: ivs_cfg
signals:
  - {name: phy_int,        dir: input,  width: 2, desc: "[协议] PDU Control 的 PHY INT 字段, 选 Table 3.4 行"}
  - {name: rate_sel,       dir: input,  width: 3, desc: "[协议] Control Header RI (0b001=HDT2..0b101=HDT7.5), 选 Table 3.4 列"}
  - {name: payload_len,    dir: input,  width: 16, desc: "[决策✓ KD-2 / 位宽默认] Payload Zone 总 octet 数 L (不含 padding); 切分模式用; kstart 锁存"}
  - {name: ivs_en,         dir: input,  width: 1, desc: "[决策✓] 本模块使能(产出): bit-域 zone(CH/PDU/payload)期间为 1; 非串化期(preamble/PITS/idle)为 0 不产出"}
  - {name: ivs_passthru,   dir: input,  width: 1, desc: "[决策✓ ②] 1=pass-through(整 zone 串化, 不切分/padding, 用 passthru_bit_len 定长); 0=切分模式(fmt1 Payload, 用 Table3.4)"}
  - {name: passthru_bit_len, dir: input, width: 10, desc: "[决策✓ ②④] pass-through 的 zone bit 长(CH=57, PDU Header=(pdu_hdr_len+3)×8, ≤528); 串满即 seq_flush, 末 octet 可部分使用"}

# ---- 下游: 1bit/cycle 串行 + 边界, 直接喂 fec_encoder (bit_in/seq_start/seq_flush) ----
interface: ivs_out
protocol: valid_only
signals:
  - {name: bit_out,        dir: output, width: 1, desc: "[决策✓ KD-1] 串化后数据 bit (LSB-first: octet bit0 先出) -> fec_encoder.bit_in"}
  - {name: bit_out_valid,  dir: output, width: 1, desc: "输出 bit 有效 -> fec_encoder.bit_in_valid"}
  - {name: seq_start,      dir: output, width: 1, desc: "[决策✓ KD-4] PHY Interval 首 bit 标志 -> FEC 清零 & 下游相位复位"}
  - {name: seq_flush,      dir: output, width: 1, desc: "[决策✓ KD-4] PHY Interval 末数据 bit 后拉高 -> FEC 追加 termination"}

handshake_rules:
  - "ivs_en=0: 模块 idle 不产出 (preamble/PITS/idle 等非 bit-域期)"
  - "ivs_passthru=1 (CH/PDU Header/fmt0): 不查 Table3.4、不切分、不 zone padding; 串化 passthru_bit_len 个 bit (LSB-first, 末 octet 可只用前几 bit), 首 bit 发 seq_start, 串满后发 seq_flush"
  - "ivs_passthru=0 & ivs_en=1 (fmt1 Payload): 以下切分模式规则生效"
  - "[与 tx_ctrl_fsm 对齐 ①] rd_en '1 octet/8拍' 为使能时瞬时串化速率; 整体取数受 FSM bit-域门控(bd_en, 按符号率)节流, 平均远低于此, 防下游 assembler 浅 FIFO 溢出"
  - "N = Table3.4[phy_int][rate_sel]; payload_len/phy_int/rate_sel 在 kstart 锁存, 序列内不变"
  - "zone padding: 若 1<=payload_len<=15, 内部把有效长度补到 L_eff=16 (补的 octet 全 0); 否则 L_eff=payload_len"
  - "octet 计数器对每个 octet_in_valid +1; 计满 N 即段边界: 该段末 bit 串出后 seq_flush 拉高一拍, 下段首 bit 同拍 seq_start"
  - "[决策✓] 每个 octet 按 LSB-first 串化为 8 个 bit_out (bit0 先出)"
  - "末段: 计到 L_eff 末尾即收尾, 末段长度 = L_eff - (段数-1)*N, 可短于 N; 末段同样发 seq_flush"
  - "zone padding 的全 0 octet 也参与串化与计数 (它们是末段/16 octet 的一部分)"
  - "复位期间所有 valid/输出/边界为 0"
  - "[决策✓] 比特域全程无反压: 不出 ready, 不收下游 ready (与 FEC/puncturing 一致)"
```

> [决策✓ 全部已定] 串化位序 = LSB-first; payload_len = 16bit(已确认足够);
> rd_en 由本模块驱动; Table 3.4 二十格已人核对无误 (2026-06-25)。

---

## 3. 配置空间 [协议 + 决策]

| 参数 | 取值 | 说明 | 是否影响本模块 |
|---|---|---|---|
| PHY INT | 0b00/01/10/11 | 选 Table 3.4 行 | **是 — 与 rate 共同定 N** |
| rate (RI) | HDT2/3/4/6/7.5 | 选 Table 3.4 列 | **是 — 与 PHY INT 共同定 N** |
| payload_len L | 0 .. 最大 zone 长 | 定段数与末段长度 + 是否触发 zone padding | **是** |
| format (PFI) | short / fmt0 / fmt1 | 仅 fmt1 有 Payload 才启用 (ivs_en) | 否 — 折叠成 ivs_en |
| 调制方式 | π/4QPSK/8PSK/16QAM | 下游的事 | **否 (显式排除)** |
| 编码率打孔 | 2/3,3/4,15/16 | 下游 puncturing 的事 | **否 (显式排除)** — 本模块只用 rate 查 N, 不打孔 |
| termination/符号补齐 padding | — | 分别由 FEC / symbol 域做 | **否 (显式排除)** |

> 组合自检:本模块真正需要 cross 的维度 = **phy_int × rate(共 20 种 N) × L 的边界形态**
> (整除 / 非整除末段 / 1–15 触发 padding / L≤N 单段)。format/调制/打孔不在本模块分支。
> 验证关注 N 的 20 个取值 + L 相对 N 的三类边界,而非数据率全展开。

---

## 4. 验证意图 [验证 — 你 review 的核心]

### 4.1 判定锚点 [默认]
- **主锚点:Python 参考模型逐 byte/bit 比对,0 容差**(纯切分逻辑,无定点)。
  - 参考模型:输入 (phy_int, rate, L, octet 流) → 查 Table 3.4 得 N → zone padding → 按 N
    切段 → 按约定位序串化 → 产出 (bit 序列 + 每段 seq_start/seq_flush 时点)。
  - RTL dump (bit_out / seq_start / seq_flush) 与参考模型逐拍对齐比对。
  - 复用链:本模块输出可直接喂 fec_encoder 参考模型, 做 ivs→FEC→punc 三级联测。
- 辅助不变量(无需 golden):长度守恒 / 段数 = ceil(L_eff/N) / seq_flush 次数 = 段数 /
  串化拍数 = L_eff×8 / 去 padding 后透传逐位相等。

### 4.2 必查 corner case [默认, 待你补充]
- **L 恰为 N 整数倍**(无末段截断, 各段等长)。
- **L 非整数倍**(末段更短, 验证末段长度与 seq_flush)。
- **L ≤ N**(单段; 含 L=N 的临界)。
- **L = 1..15 触发 zone padding 到 16**(验证补 0 octet 数、计数、末段)。
- **L = 16**(刚好不触发 padding 的临界对照)。
- **N 取 20 个值的代表**(至少每个 phy_int 行 + 每个 rate 列被覆盖; 最小 N=16 / 最大 N=240)。
- **背靠背两包 rate/phy_int 不同**(验证 kstart 重锁存 N、计数器复位)。
- **octet_in_valid 气泡**(空拍时 octet 计数与串化不前进)。
- **ivs_en=0 旁路**(short/fmt0/empty payload 不产出)。
- **单 octet 段 / 末段长度=1**(边界最小)。

### 4.3 覆盖率目标 [默认]
```systemverilog
covergroup cg_ivs @(posedge clk);
  cp_phyint: coverpoint phy_int;                         // 4 行
  cp_rate:   coverpoint rate_sel { bins r[] = {[1:5]}; } // 5 列 (HDT2..7.5)
  x_N:       cross cp_phyint, cp_rate;                   // 20 种 N 全覆盖
  cp_tail:   coverpoint tail_kind;                       // {整除, 非整除末段, L<=N单段, padding}
  cp_pad:    coverpoint pad_active;                      // zone padding 触发/未触发
endgroup
```
- x_N: 100%(20 种 N 都激励)
- cp_tail / cp_pad: 100%(四类边界 + padding 两态)

### 4.4 接口断言 (由第2节契约生成)
- assert: 非末段, 相邻两次 seq_flush 之间恰好串出 N×8 个 bit_out_valid。
- assert: 每段首 bit 同拍 seq_start; seq_start 与 seq_flush 不同拍同源对齐。
- assert: 一个包内 seq_flush 总次数 == ceil(L_eff/N)。
- assert: ivs_en=0 时 bit_out_valid==0 且无 seq_start/seq_flush。
- assert: 1<=payload_len<=15 时实际串出 octet 数 == 16(padding 生效)。
- assert: 复位期 bit_out_valid / seq_start / seq_flush == 0。

### 4.5 充分性二级指标 [默认]
- mutation kill rate ≥ 90%。注入变异:Table 3.4 某格取错、N 计数差 1(off-by-one)、
  末段长度算错、漏 zone padding / pad 到错误长度、seq_flush 早/晚一拍、串化位序反转、
  漏 seq_start、ivs_en 旁路失效。好的测试集应全部杀死。

---

## 5. 架构与定点约束 [协议 + 默认]

- 定点:**N/A**(纯比特/计数逻辑,无算术乘累加)。
- 核心电路:
  - **Table 3.4 LUT**:{phy_int, rate_sel} → N(最大 240,需 8bit)。常量 case/ROM。
  - **octet 计数器** `oct_cnt`(模 N)+ **总长计数器**追踪到 L_eff(判末段/收尾)。
  - **zone padding 逻辑**:L∈[1,15] 时在真实 octet 耗尽后补全 0 octet 至 16。
  - **P/S 串化器**:8bit octet → 8 拍 1bit 输出([决策✓] LSB-first, bit0 先);串化期间本模块
    用 rd_en 节流 MAC pull(每 8 拍 pull 一次新 octet)。
  - **边界生成**:段首拍 seq_start、段末数据 bit 后 seq_flush(组合判定 + 1 级寄存对齐)。
- 流水线:[默认] 串化引入 octet→8bit 的速率转换;吞吐 = 1bit/cycle(48MHz 远高于
  最坏编码前比特率 7.5Mb/s,余量充足)。建议输出寄存 1 级,与 fec_encoder 同拍对齐。
- 时序风险:无长组合路径;LUT + 小计数器,深度浅,48MHz 无压力。
- 时钟:继承 48MHz 单一时钟域,无 CDC。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs Python 参考模型逐 byte/bit 比对 pass (0容差)
- [ ] 不变量: 长度守恒 + 段数 + seq_flush 次数 + 串化拍数 pass
- [ ] x_N 20种 100%, cp_tail / cp_pad 100%
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给你 review 的关键点 (本轮已全部确认)

1. **Table 3.4 二十格数值** [协议 ✓ 已人核对]:已对照原表逐格核对无误 (2026-06-25)。
2. **octet→bit 串化位序** [决策✓]:**LSB-first**(octet bit0 先串出)。参考模型/RTL 均以此为准。
3. **payload_len 位宽** [决策✓]:**16bit 足够**(覆盖最大 Payload Zone 长度)。
4. **MAC pull 的 rd_en 归属** [决策✓]:**由本模块驱动** rd_en(每 8 拍 pull 一次新 octet)。
5. **KD-4 边界标记归属** [决策✓]:seq_start/seq_flush 由本模块在 octet 边界产生,**交 FSM 统一对齐**
   (与 puncturing 同源)。
6. **zone padding 的全 0 octet** [决策✓]:padding 在末 CRC **之后**且全 0(§2.7.3),不过 CRC、
   白化在 MAC 侧——**padding octet 直接以全 0 进入串化即可,本模块不做额外处理**。
