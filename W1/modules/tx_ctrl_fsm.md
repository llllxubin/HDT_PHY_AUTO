# W1 模块规格契约 — tx_ctrl_fsm

> 字段标记: [协议]=spec事实 · [决策✓]=人已拍板 · [默认]=待确认 · [验证]=验证意图
> status 只有 frozen 才允许进入 W2。
> 本模块**最后做**: 协调全部已 frozen 模块, 前置依赖全部锁定后其 W1 才稳。

---

## 0. 元信息
- module_name: `tx_ctrl_fsm`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] Vol 6 Part A §7.1 (packet formats)/§7.2 (PHY Intervals, Table 7.2/7.3)/§7.4 (training/terminating/PITS); Part B §2.7 (packet format)/§3.4 (coding, Table 3.2/3.3)
- 在链路中的位置: **[tx_ctrl_fsm]** 旁挂协调 interval_spacing/fec_encoder/puncturing/symbol_mapper/symbol_assembler/srrc_upsample (全链路控制枢纽)
- status: draft   # draft / reviewed / frozen  —— 4决策点全拍板(CTE出范围/逐zone重配/原子包/行为不变量+formal); frozen 留给人
- 全局约定继承: 见 00_toplevel.md (48MHz 单时钟域无 CDC; 异步复位同步释放 rst_n 低有效; MAC kstart 锁存配置)

---

## 1. 功能描述 [协议]

tx_ctrl_fsm 是 TX PHY 的**全链路时序协调器**。消费 MAC 的 `kstart`,在该拍锁存包描述符
(format/RI/PHY_INT/payload_len/u),据 format 编排整个包的 **zone 时间线**,向 6 个数据通路
模块发**节拍对齐**的控制信号 (seq_start/phase/mod_sel/punc_rate/...),驱动一个完整包从
Preamble 走到末尾 flush,再回 IDLE。**原子包**: 包内忽略新 kstart。

### 1.1 包时间线 (三种 format)
```
short : Preamble → CtrlHdr(+2term) → 尾flush → IDLE
fmt0  : Preamble → CtrlHdr(+2term) → PDU+Payload合一序列(+2term) → 尾flush → IDLE
fmt1  : Preamble → CtrlHdr(+2term) → PDU_Header(+2term)
        → [PHY_Interval#i(+2term) → (若非末段) PITS]×N → 尾flush → IDLE
```

### 1.2 协议事实 (W1a)
- **Preamble** [§7.4]: 9×STS(4符号) + GI(4) + 2×LTS(17) = **74 符号**;非调制数据,由 assembler 本地产。
- **终止符号** [§7.4.4]: 每个 bit 序列(CH / PDU / 每 PHY Interval / fmt0 PDU+PL)后插 **2 符号**,
  用**所在 zone 的调制**表示全 0 bit(经 mapper 喂全 0 产生)。
- **PITS** [§7.4.5]: **6 符号** {−1,+1,+1,+1,−1,+1},**仅 fmt1、interval 之间**(末段后不插)。
- **PHY Interval 符号数** [§7.2 Table 7.2]: PHY_INT 0/1/2/3 → 128/256/384/512 符号(payload,与 rate 无关);
  含 term+pad 的符号流总长见 Table 7.3(rate 相关, 130~133/…);**末段可更短**。
- **per-zone 编码/调制** [§7.3 Table 7.1 / Part B Table 3.2/3.3]:

  | Zone | 调制 mod_sel | 编码率 punc_rate | 来源 |
  |---|---|---|---|
  | Control Header | **π/4 QPSK (00)** | **1/2 (00, 不打孔)** | CH 恒 2Mb/s 1/2 [PartB §3.4] |
  | PDU Header (fmt1) | **rate 调制** (Table7.1) | **1/2 (00, 不打孔)** | Table 3.3 恒 1/2 (有效率反推=rate调制) |
  | PDU+Payload (fmt0) | rate 调制 | **rate 率** (Table 3.2) | Table 3.2 |
  | Payload Interval (fmt1) | rate 调制 | rate 率 (Table 3.2) | Table 3.2 |

  rate 调制: HDT2/3→QPSK(00) · HDT4→8PSK(01) · HDT6/7.5→16QAM(10)。
  rate 率 (Table 3.2): HDT2→1/2(00) · HDT3→3/4(10) · HDT4→2/3(01) · HDT6→3/4(10) · HDT7.5→15/16(11)。
  RI(3bit) ∈ {001,010,011,100,101} 在 Control Header 内, kstart 锁存。
- **尾 flush** [继承 srrc 决策]: 末终止符号后 FSM 喂 **3 个纯 0 符号**(assembler phase=IDLE, 出 0)
  推干净 SRRC 群延迟(15 样本)尾巴。
- **CTE** [§7.1]: fmt0/1 *可* 含 CTE → **[决策✓ 本轮出范围]**, FSM 不编排。

不变量:
- **zone 顺序**: 严格 Preamble→CtrlHdr→(format 分支)→尾flush→IDLE, 不可乱序/跳级。
- **终止符号守恒**: 每个 bit 序列后恰 2 终止符号。
- **PITS 规则**: 仅 fmt1, 仅 interval 之间, 末 interval 后 0 个。
- **pkt_start 唯一**: 每包恰 1 次, 在包首。
- **last_interval 唯一**: 恰在最后一个 PHY Interval 拉高(fmt1)。
- **原子完成 (liveness)**: 每个被接受的 kstart 必在有限拍后回 IDLE, 无死锁。
- **per-zone 配置正确**: mod_sel/punc_rate 在每 zone 取上表值, zone 内稳定。

---

## 2. 接口契约 [决策✓]

> FSM 的输出控制束**逐一对应**各 frozen 模块的控制输入端口(1:1 直连)。

```yaml
# ---- 来自 MAC / Control (kstart 锁存) ----
interface: fsm_mac_in
clock: clk
reset: rst_n
protocol: pulse_latch     # kstart 当拍锁存全部描述符
signals:
  - {name: kstart,      dir: input,  width: 1,  desc: "[协议] 包启动脉冲; BUSY 期间忽略(原子包)"}
  - {name: ri,          dir: input,  width: 3,  desc: "[协议] rate indicator 001..101 (HDT2/3/4/6/7.5)"}
  - {name: pfi,         dir: input,  width: 2,  desc: "[协议] format: 0=short 1=fmt0 2=fmt1"}
  - {name: phy_int,     dir: input,  width: 2,  desc: "[协议] PHY_INT 00/01/10/11 -> 128/256/384/512 符号/interval"}
  - {name: payload_len, dir: input,  width: 16, desc: "[协议/继承] Payload 总 octet 数 L (不含 padding)"}
  - {name: lts_u,       dir: input,  width: 4,  desc: "[决策✓ O7] LTS 选择 u (1..15)"}

# ---- 节拍输入: 符号率 strobe (用于 phase 内符号计数) ----
interface: fsm_pacing
signals:
  - {name: sym_tick,    dir: input,  width: 1,  desc: "[决策✓] 2Msym/s strobe (= srrc.sym_req, 每 24 拍); FSM 据此数符号"}

# ---- 输出 -> interval_spacing (kstart 锁存值 + 边界对齐) ----
interface: fsm_to_int_spacing
signals:
  - {name: is_payload_len, dir: output, width: 16, desc: "= int_spacing.payload_len"}
  - {name: is_phy_int,     dir: output, width: 2,  desc: "= int_spacing.phy_int"}
  - {name: is_rate_sel,    dir: output, width: 3,  desc: "= int_spacing.rate_sel (Table3.4 选 N octet)"}
  - {name: is_enable,      dir: output, width: 1,  desc: "[决策✓] payload zone 期间使能 int_spacing 取数/切分 (仅 fmt1 Payload)"}

# ---- 输出 -> puncturing ----
interface: fsm_to_punc
signals:
  - {name: punc_seq_start, dir: output, width: 1,  desc: "= puncturing.seq_start; 序列/interval 首码对, 打孔相位复位"}
  - {name: punc_rate,      dir: output, width: 2,  desc: "= puncturing.punc_rate; 按 zone 表驱动(CH/PDU=1/2)"}

# ---- 输出 -> symbol_mapper ----
interface: fsm_to_mapper
signals:
  - {name: map_seq_start,  dir: output, width: 1,  desc: "= symbol_mapper.seq_start; 符号索引 k 复位"}
  - {name: map_sym_flush,  dir: output, width: 1,  desc: "= symbol_mapper.sym_flush; 末符号补0凑齐"}
  - {name: mod_sel,        dir: output, width: 2,  desc: "= symbol_mapper.mod_sel; 按 zone 表驱动(CH=QPSK)"}

# ---- 输出 -> symbol_assembler ----
interface: fsm_to_asm
signals:
  - {name: asm_pfi,        dir: output, width: 2,  desc: "= assembler.pfi"}
  - {name: asm_lts_u,      dir: output, width: 4,  desc: "= assembler.lts_u"}
  - {name: asm_phase,      dir: output, width: 2,  desc: "= assembler.phase; 0=PREAMBLE 1=DATA 2=PITS 3=IDLE"}
  - {name: asm_phase_start, dir: output, width: 1, desc: "= assembler.phase_start; 进入新 phase 本地计数清零"}
  - {name: asm_last_interval, dir: output, width: 1, desc: "= assembler.last_interval; 末 interval 后不发 PITS"}

# ---- 输出 -> srrc_upsample ----
interface: fsm_to_srrc
signals:
  - {name: pkt_start,      dir: output, width: 1,  desc: "= srrc.pkt_start; 包首清延迟线 (每包恰 1 次)"}

# ---- 状态输出 (给 MAC/顶层) ----
interface: fsm_status
signals:
  - {name: tx_busy,        dir: output, width: 1,  desc: "[决策✓] 包处理中 (IDLE 外); BUSY 期间 kstart 被忽略"}

handshake_rules:
  - "kstart 仅在 IDLE 被接受; BUSY 期间 kstart 忽略(原子包), tx_busy=1"
  - "kstart 当拍锁存 {ri,pfi,phy_int,payload_len,lts_u}, 包内不变; 同拍 pkt_start->srrc"
  - "mod_sel/punc_rate 按 §1.2 zone 表驱动: 进入新 zone 在该 zone 首(seq_start 同源)切换, zone 内稳定"
  - "各下游 seq_start/phase_start 与该级数据通路的首有效 beat 同拍对齐 (对齐不变量, 见 §5/§4)"
  - "终止符号: 每 bit 序列后, FSM 经 mapper 喂全 0 产 2 终止符号(当前 zone 调制)"
  - "PITS: 仅 fmt1 interval 之间; asm_last_interval=1 的 interval 后不发 PITS phase"
  - "尾 flush: 末终止符号后 asm_phase=IDLE 持续 3 个 sym_tick (出 3 纯 0 符号) 再回 IDLE 主态"
  - "复位/IDLE: 所有输出控制为去激活值(seq_start/phase_start/pkt_start=0, phase=IDLE, tx_busy=0)"
```

> [全部已定] 4 决策点(CTE范围/逐zone重配/原子包/对齐表达)均人拍板, 见 §7。

---

## 3. 配置空间 [协议 + 决策]

| 参数 | 取值范围 | 说明 | 是否影响本模块 |
|---|---|---|---|
| format (pfi) | short/fmt0/fmt1 | 决定 zone 序列分支 | **是(核心)** |
| RI (rate) | HDT2/3/4/6/7.5 (5) | 决定 per-zone mod_sel/punc_rate | **是(核心)** |
| PHY_INT | 00/01/10/11 | interval 符号数 → 影响 interval 计数/时长 | **是(fmt1)** |
| payload_len | 0..65535 octet | 决定 fmt1 interval 个数 N 与末段长度 | **是(fmt1)** |
| lts_u | 1..15 | 透传 assembler; FSM 仅锁存转发 | 否(透传) |
| CTE | 含/不含 | **[决策✓ 出范围]** 本轮不编排 | **否(显式排除)** |
| 白化 | — | MAC 侧完成 | **否(显式排除)** |

> 组合自检: 需 cross 的核心维度 = format × RI × PHY_INT × (interval 个数: 1/中/末段更短);
> CTE/白化/lts_u 取值 与控制序列结构正交。

---

## 4. 验证意图 [验证]

### 4.1 判定锚点 (控制/时序类 → formal SVA 证明)
- **主锚点**: **formal SVA** 证明 §1 全部不变量(安全性 + liveness), 0 容差。
- 辅锚点: 约束随机仿真覆盖 format×RI×PHY_INT 组合 + 背靠背包; 与 Python 参考时间线比对 phase/控制序列。
- 容差: 0(纯控制逻辑)。

### 4.2 必查 corner case
- 三 format 各跑通; short(仅CH)最短路径。
- 5 个 RI 的 per-zone mod_sel/punc_rate 切换正确(尤其 CH=QPSK→payload=16QAM 边界切换)。
- fmt1: N=1(单 interval, 无 PITS) / N>1(interval 间有 PITS, 末段无) / 末 interval 更短。
- 4 个 PHY_INT 值。
- payload_len 边界: 0(无 payload?) / 1 octet / 跨 interval 整除与非整除。
- 背靠背两包描述符不同(验证 kstart 重锁存、状态/计数复位)。
- BUSY 期间来 kstart(须被忽略, 原子包)。
- 尾 flush 恰 3 纯 0 符号。

### 4.3 覆盖率目标
```systemverilog
covergroup cg_fsm @(posedge clk);
  cp_state   : coverpoint fsm_state;                          // 所有宏状态
  cp_fmt     : coverpoint pfi {bins s={0}; bins f0={1}; bins f1={2};}
  cp_ri      : coverpoint ri  {bins r[] = {1,2,3,4,5};}
  cp_phyint  : coverpoint phy_int {bins p[] = {[0:3]};}
  cp_nintv   : coverpoint n_interval {bins one={1}; bins few={[2:4]}; bins many={[5:$]};}
  x_fmt_ri   : cross cp_fmt, cp_ri;                           // format×rate
  x_zone_mod : cross fsm_state, mod_sel;                      // 每 zone 调制正确组合
endgroup
```
- functional coverage 目标: 状态/format/RI/PHY_INT 100%; cross format×RI ≥ 95%。

### 4.4 接口断言 (由 §2 契约生成 → 即 formal 主体)
- assert: kstart in BUSY → 状态/锁存值不变 (原子包)。
- assert: zone 顺序合法 (状态转移图唯一, 无非法跳转)。
- assert: mod_sel/punc_rate 在每 zone == §1.2 表值。
- assert: PITS 仅 fmt1 且 last_interval=0 之后出现; last 之后 0 个。
- assert: pkt_start 每包恰 1 拍; 每 bit 序列后恰 2 终止符号; 尾 flush 恰 3 符号。
- assert (liveness): kstart 被接受 ⟹ 有限拍后 tx_busy 落回 0 (`s_eventually`)。
- assert (对齐): 各级 seq_start/phase_start 与该级首有效 beat 同拍(行为不变量, 见 §5)。

### 4.5 充分性二级指标
- mutation kill rate 目标: ≥ 95%(控制逻辑应高)。注入变异:
  漏抑制末段 PITS / 终止符号数错(1或3) / 某 zone mod_sel 错 / interval 计数 ±1 /
  尾 flush 符号数错 / pkt_start 多发或漏发 / zone 顺序错。

---

## 5. 架构与定点约束 [决策✓]
- 定点: **N/A**(纯控制逻辑, 无数据通路算术)。
- 核心电路:
  - **主状态机**: IDLE / PREAMBLE / CTRLHDR / PDU(fmt0合一·fmt1独立) / INTERVAL / PITS / TERM / TAILFLUSH。
  - **计数器**: phase 内符号计数(由 sym_tick 驱动, 比 74/6/2/3 等定长)、interval 计数(对 N)、
    bit 序列计数(对 zone bit 长)。
  - **per-zone 配置 LUT**: RI → (mod_sel, punc_rate, 调制 bit/符号); zone 状态选 CH(固定 QPSK,1/2) /
    PDU(rate调制,1/2) / Payload(rate调制,rate率)。
  - **interval 个数 N**: 由 payload_len/phy_int/RI(Table 3.4 octet 尺寸)计算; 末段判定驱动 last_interval。
- **控制-数据对齐 [决策✓ 行为不变量]**: W1 **不锁**各级具体流水延迟(留 W2); 契约用**对齐不变量**
  表达: "到达第 X 级的 seq_start/phase_start 与该级首有效 beat 同拍"。W2 用延迟匹配(对每级
  累计延迟移位控制脉冲)实现, formal SVA 证该不变量。FSM 是**中心式延迟匹配枢纽**(继承 frozen 契约)。
- 流水线: 控制逻辑, 状态/计数寄存; 无长算术路径。
- 时序风险: 低(纯控制); 注意 per-zone LUT 与状态译码组合深度, 48MHz 宽松。
- 时钟: 继承 48MHz 单时钟域。sym_tick 每 24 拍。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] formal SVA 证明 §1 全部不变量 pass (安全性 + liveness, 无 vacuous)
- [ ] 接口断言全 pass (原子包/zone顺序/per-zone配置/PITS/终止/flush/对齐)
- [ ] 三 format × 5 RI × 4 PHY_INT 仿真跑通, vs Python 时间线参考一致
- [ ] 背靠背包 / N=1 / 末段更短 corner pass
- [ ] 覆盖率达标 (状态/format/RI/PHY_INT 100%; cross ≥95%)
- [ ] mutation kill rate ≥ 95%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给人 review 的关键点
> 本轮 4 决策已确认; 另有 2 处跨模块整合点需你确认(可能回触 frozen 模块的小注脚)。

**本轮已定 (4 决策):**
1. **[决策✓] CTE 出范围**: 本轮 FSM 不编排 CTE(spec 列为可选)。
2. **[决策✓] 逐 zone 重配**: kstart 一次锁存包描述符; FSM 按 zone 驱动 mod_sel/punc_rate,
   zone 内稳定、边界切换; 模块"kstart锁存"重解为"zone首(seq_start)重锁存"。
3. **[决策✓] 原子包**: 包内忽略新 kstart, 跑到 IDLE。
4. **[决策✓] 对齐表达**: 行为不变量 + formal 证, W1 不锁各级延迟。

**待你确认的整合点 (有默认, 可能需 frozen 模块加注脚):**
5. **[默认] CH/PDU Header 的 octet→bit 串化路径**: interval_spacing 现 frozen 为"仅 fmt1 Payload"
   做切分。CH 与 PDU Header 同样要把 MAC octet 串成 bit 喂 FEC。建议**复用 interval_spacing 的串化
   通路、但旁路 interval 切分/padding(整 zone 当单序列)**, 由 FSM 的 `is_enable`/模式位控制。
   → 这可能要给 interval_spacing 补一条"pass-through 模式"注脚。**请确认路由方案。**
6. **[默认] 终止符号/尾 flush 的 0 源**: 终止符号 = mapper 喂全 0(已定); 尾 flush 3 符号 =
   assembler phase=IDLE 出 0。需确认 **assembler IDLE 相在 sym_tick 下输出 0+valid**(与其 frozen
   契约 phase=3 一致), 否则尾 flush 改走 mapper 喂 0。
7. **[验证] 符号计数节拍**: FSM 用 sym_tick(=srrc.sym_req)数符号定 phase 时长; 确认 preamble 74 /
   PITS 6 / 终止 2 / flush 3 这些定长计数,与 assembler 本地计数**不重复打架**(分工: assembler 产
   符号内容, FSM 管 phase 切换时刻)。
