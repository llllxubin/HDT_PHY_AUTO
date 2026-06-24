# W1 模块规格契约 — symbol_assembler

> 阶段B 草稿。本文件是喂给 W2(RTL生成)的唯一权威输入。
> 字段标记: [协议]=spec事实 · [决策✓]=已拍板 · [默认]=Claude填的合理默认值,待你review · [验证]=验证意图
> 上游顶层: 见 00_toplevel.md v0.3 (链路第⑤模块, 符号域组装)

---

## 0. 元信息
- module_name: `symbol_assembler`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] HDT Core Spec Vol6 PartA §7.4 (Training sequences):
  §7.4.1 STS · §7.4.2 LTS(Zadoff-Chu)+ Table 7.7 · §7.4.3 GI · §7.4.4 终止符号 · §7.4.5 PITS;
  PCA→u: Vol6 PartB §2.7.1.1
- 在链路中的位置: symbol_mapper → **[symbol_assembler]** → srrc_upsample
- status: frozen   # draft / reviewed / frozen  —— 4决策+6 review点全确认(含LTS公式/p表/量化码人核对); frozen 留给人
- 全局约定继承: 见 00_toplevel.md (48MHz 单一时钟域, 无 CDC); 符号 Q0.9 (继承 symbol_mapper KD-B)

---

## 1. 功能描述 [协议]

把**训练符号**(常量 / LTS-ROM)与**数据符号**(来自 symbol_mapper,含终止符号)按组装顺序
多路选,拼成完整符号流,以恒定 2Msym/s 送 srrc_upsample。

**训练符号** [协议]:
- **STS** §7.4.1:4 符号 `{−1, −j, +j, +1}`(发送序)。
- **LTS** §7.4.2:17 符号 Zadoff-Chu `xu(0..16)`,公式(已渲染图核对):

  **xu(k) = e^(−j · πu·k(k+1)/17) × e^(j · 2π·p/17)**, k=0..16

  u 来自 PCA(`u = PCA[31:0] mod 15 + 1`, 取值 1..15;**u=16 保留不用**),
  p 由 u 查 **Table 7.7**(已核对):

  | u | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | (16) |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
  | p | 2 | 7 | 12 | 12 | 4 | 13 | 8 | 14 | 15 | 13 | 12 | 10 | 5 | 15 | 14 | (0) |

- **GI** §7.4.3:= LTS 末 4 符号 `xu(13..16)` 的拷贝(放在第一个 LTS **之前**)。
- **preamble** §7.4:`9×STS + GI + 2×LTS`(发送序)。
- **终止符号** §7.4.4:每符号流后 2 符号 = 当前调制映射全 0 bit;**由 symbol_mapper 产出**
  (FSM 喂全 0),经数据通路进本模块,**本模块不另算**。
- **PITS** §7.4.5:6 符号 `{−1,+1,+1,+1,−1,+1}`,仅 fmt1 PHY Interval **之间**插入,
  **最后一个 Interval 后不加**;PITS 是裸 ±1,非数据符号。

**组装顺序** [协议]:
```
preamble → CH符号 + 2终止
  → (fmt0) PDU+PL符号 + 2终止
  → (fmt1) PDU Header符号 + 2终止 → [ PHY Interval符号 + 2终止 + PITS ] × N   (末段无 PITS)
short 格式: preamble → CH符号 + 2终止   (无 PDU/Payload)
```

**定点**:训练符号沿用 mapper 的 **Q0.9**(进 SRRC 一致)。量化码(round-to-nearest, +1.0 饱和):
- `−1 → (I,Q)=(−512, 0)` · `+1 → (+511, 0)` · `−j → (0, −512)` · `+j → (0, +511)`
- STS `{−1,−j,+j,+1}` → `[(−512,0),(0,−512),(0,+511),(+511,0)]`
- PITS → `[(−512,0),(+511,0),(+511,0),(+511,0),(−512,0),(+511,0)]`
- LTS/GI:单位幅复符号,cos/sin 量化到 Q0.9(由公式离线生成 ROM)。

**架构定调** [决策✓ 本轮]:
- **D7**:LTS 预存 **复符号 ROM**(16×17 个 Q0.9 复符号,按 u 查;GI 取该 u 的 xu(13..16))。
- **O7**:**MAC 在 kstart 给 u(4bit)**,PHY 用 Table 7.7 小 ROM 查 p(或直接按 u 选 LTS-ROM);
  PHY 不做 mod15 除法。
- **pacing**:mapper 输出后置**符号 FIFO** 吸收抖动;输出由 **SRRC 按符号率拉**(2Msym/s tick)。
- **序列驱动**:本模块**本地计数器**产固定训练结构;**tx_ctrl_fsm 给粗粒度 phase + start**
  (含 last_interval 标志,用于末段不加 PITS)。

不变量(验证用):
- **结构**:preamble 恒为 9×STS(4)+GI(4)+2×LTS(17)= 36+ ... 即 9·4+4+2·17 = 74 符号。
- **GI=LTS尾**:GI 4 符号逐符号等于该 u 的 xu(13..16)。
- **PITS 位置**:fmt1 中 PITS 出现 N−1 次(N 个 interval 之间),末段后无 PITS。
- **数据透传**:数据符号(含终止符号)逐符号等于 FIFO 取出值(本模块不改数据符号)。
- **符号率**:输出恒 2Msym/s(每 SRRC tick 出 1 符号),无丢符号/无重复。

---

## 2. 接口契约 [决策✓ + 默认]

```yaml
# ---- 上游数据: 来自 symbol_mapper (数据符号 + 终止符号), 经符号 FIFO ----
interface: asm_data_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: valid_only      # mapper valid 推入 FIFO
signals:
  - {name: din_i,       dir: input,  width: 10, desc: "[协议/继承] = symbol_mapper.sym_i (Q0.9)"}
  - {name: din_q,       dir: input,  width: 10, desc: "[协议/继承] = symbol_mapper.sym_q (Q0.9)"}
  - {name: din_valid,   dir: input,  width: 1,  desc: "= symbol_mapper.sym_valid, 推入符号 FIFO"}

# ---- 配置 (kstart 锁存) ----
interface: asm_cfg
signals:
  - {name: pfi,         dir: input,  width: 2,  desc: "[协议] format: 0=short 1=fmt0 2=fmt1 (决定组装序列)"}
  - {name: lts_u,       dir: input,  width: 4,  desc: "[决策✓ O7] LTS 选择 u (1..15), MAC 在 kstart 给; 选 LTS/GI ROM 与查 p"}

# ---- 控制: 来自 tx_ctrl_fsm (粗粒度 phase) ----
interface: asm_ctrl
signals:
  - {name: phase,       dir: input,  width: 2,  desc: "[决策✓] 当前组装相: 0=PREAMBLE 1=DATA(取FIFO) 2=PITS 3=IDLE"}
  - {name: phase_start, dir: input,  width: 1,  desc: "[决策✓] 进入新 phase 标志, 本地计数器复位"}
  - {name: last_interval,dir: input, width: 1,  desc: "[决策✓] 当前为最后一个 PHY Interval (其后不进 PITS phase)"}

# ---- 下游: 符号流 -> srrc_upsample, SRRC 按符号率拉 ----
interface: asm_out
protocol: pull            # [决策✓] SRRC 产 2Msym/s tick 拉, 本模块当拍给符号
signals:
  - {name: sym_req,     dir: input,  width: 1,  desc: "[决策✓ pacing] SRRC 符号率请求 (2Msym/s, 48MHz下每24拍一次)"}
  - {name: out_i,       dir: output, width: 10, desc: "[决策✓] 输出符号 I (Q0.9) -> srrc"}
  - {name: out_q,       dir: output, width: 10, desc: "[决策✓] 输出符号 Q (Q0.9)"}
  - {name: out_valid,   dir: output, width: 1,  desc: "本拍输出符号有效 (响应 sym_req)"}

handshake_rules:
  - "sym_req 一拍 = 输出一个符号: out_valid 同拍高, out_i/out_q = 当前 phase 选出的符号"
  - "phase=PREAMBLE: 本地计数器依次产 9×STS(4) -> GI(4=xu13..16) -> LTS#1(17) -> LTS#2(17)"
  - "phase=DATA: 从符号 FIFO 弹出一个数据符号 (CH/PDU/PL/终止符号已按序在 FIFO 中)"
  - "phase=PITS: 本地计数器产 6 个 PITS 常量符号"
  - "phase_start 当拍本地符号计数器清零"
  - "last_interval=1 的 interval 数据+2终止后, FSM 不再发 PITS phase (末段无 PITS)"
  - "lts_u/pfi 在 kstart 锁存, 包内不变"
  - "符号 FIFO 由 din_valid 推入, sym_req&phase=DATA 弹出; FIFO 不应在 DATA phase 空 (见 §4 断言)"
  - "复位期间所有输出 (out_i/out_q/out_valid) 为 0"
```

> [全部已定] (1) 符号 FIFO 深度 = 参数化 DEPTH(默认 8), 具体值留 W2 仿真收敛; (2) phase/
> last_interval 由 FSM 给, 本侧契约现冻结, 待 tx_ctrl_fsm W1 对齐; (3) LTS-ROM 存 16 项按 u 直接索引;
> (4) 训练符号量化码与 LTS 公式/p 表已人核对无误 (2026-06-25)。

---

## 3. 配置空间 [协议 + 决策]

| 参数 | 取值 | 说明 | 是否影响本模块 |
|---|---|---|---|
| pfi (format) | short/fmt0/fmt1 | 决定组装序列分支 | **是 — 序列结构维度** |
| lts_u | 1..15 | 选 LTS/GI ROM + p | **是 — 16 组 LTS** |
| N (interval 数) | 1..M | fmt1 的 PITS 次数 = N−1 | **是 (经 phase/last_interval)** |
| 调制 mod_sel | π/4QPSK/8PSK/16QAM | 数据符号已由 mapper 映射 | **否 (显式排除)** — 终止符号也由 mapper 出 |
| rate / 打孔 | — | 上游的事 | **否 (显式排除)** |
| 符号 bit 内容 | — | 数据符号透传, 不解释 | **否** |

> 组合自检:需 cross 的维度 = **pfi(3) × lts_u(15) × interval 边界(N=1 / N>1 末段无PITS)**。
> 数据符号内容/调制不在本模块分支(透传)。LTS ROM 15 组须全覆盖。

---

## 4. 验证意图 [验证 — 你 review 的核心]

### 4.1 判定锚点 [默认]
- **主锚点:Python 参考模型 + 序列结构检查**(组装/胶水类)。
  - 参考模型:按 pfi/u/N 生成完整符号序列(preamble + CH + 数据 + 终止 + PITS),
    训练符号用 §1 量化码、LTS 用公式量化;数据符号用占位 tag 比对位置。
  - RTL 输出符号流与参考模型**逐符号比对**:位置(结构)+ 训练符号值 0 容差;
    数据符号比对其来自 FIFO 的值(透传一致)。
- **LTS ROM vs 公式**:ROM 272 个复符号由 §1 公式离线生成,RTL ROM 与之逐符号 0 容差
  (生成脚本与量化口径独立于 RTL)。
- 辅助不变量:preamble 74 符号结构 / GI=xu(13..16) / PITS 出现 N−1 次 / 符号率恒定。

### 4.2 必查 corner case [默认, 待你补充]
- **三种 format 组装序列**(short / fmt0 / fmt1)全走通。
- **fmt1 N=1**(单 interval:完全无 PITS)与 **N≥2**(PITS 出现 N−1 次, 末段后无)。
- **preamble 结构**:9 次 STS、GI=该 u 的 xu(13..16)、2 次 LTS。
- **lts_u 扫 1..15**(LTS/GI ROM 全覆盖);u=16 不应被选(保留)。
- **终止符号位置**:每符号流后恰 2 个(来自 FIFO)。
- **+1.0 饱和**:STS 的 +1/+j、PITS 的 +1 输出为 +511(非回绕)。
- **符号 FIFO 不下溢**:DATA phase 拉取时 FIFO 始终非空(mapper 16% 占空, 余量足)。
- **phase 切换边界**:phase_start 复位本地计数, 相邻 phase 无丢/重符号。
- **背靠背两包 pfi/u 不同**(kstart 重锁存)。

### 4.3 覆盖率目标 [默认]
```systemverilog
covergroup cg_asm @(posedge clk);
  cp_pfi:    coverpoint pfi { bins f[] = {0,1,2}; }        // 三 format
  cp_u:      coverpoint lts_u { bins u[] = {[1:15]}; }     // 15 组 LTS
  cp_phase:  coverpoint phase;                              // 4 phase
  cp_pits_n: coverpoint pits_count;                         // PITS 出现次数 (含 0=N1)
  x_pfi_phase: cross cp_pfi, cp_phase;                      // 各 format 的 phase 走遍
endgroup
```
- cp_pfi / cp_u(15组)/ cp_phase: 100%
- cp_pits_n: 含 0(N=1)与 ≥1

### 4.4 接口断言 (由第2节契约生成)
- assert: phase=DATA & sym_req 时符号 FIFO 非空(无下溢)。
- assert: preamble phase 共输出 74 符号后才离开。
- assert: GI 4 符号 == 该 u 的 LTS xu(13..16)。
- assert: last_interval 后无 PITS phase。
- assert: out_valid 仅在 sym_req 当拍为高(符号率受 SRRC 控)。
- assert: 复位期 out_valid==0。

### 4.5 充分性二级指标 [默认]
- mutation kill rate ≥ 90%。注入变异:STS 重复次数错(8/10)、GI 取错符号(xu(12..15))、
  LTS 顺序/u 选错、PITS 符号值或个数错、末段误加 PITS、组装顺序错位、终止符号漏/多、
  LTS ROM 某符号 I/Q 取错。好的测试集应全部杀死。

---

## 5. 架构与定点约束 [协议 + 决策]

- 定点 [决策✓]:符号 I/Q 各 10bit Q0.9(继承 mapper);训练符号常量按 §1 量化码。
- 核心电路:
  - **符号 FIFO**:吸收 mapper 突发与 SRRC 恒速拉之间的速率差;[决策✓] 深度 = 参数化 `DEPTH`
    (默认 8),具体值留 W2 门级仿真收敛(原则:≥ mapper 最坏突发与 SRRC 恒速拉的缓冲需求)。
  - **STS/PITS 常量表**:小 ROM/case(4 + 6 个 Q0.9 复符号)。
  - **LTS 复符号 ROM** [决策✓ D7 + §7.4]:存 16 项(u=1..16,u=16 保留不选),按 lts_u **直接索引**;
    16×17 个 Q0.9 复符号(I/Q 各 10bit ≈ 16·17·20 = 5440bit);GI = 该 u 的 xu(13..16) 取 ROM 后 4 项。
  - **Table 7.7 小 ROM**:u→p(若 LTS ROM 已按 u 索引, p 仅用于离线生成, 可不在线存)。
  - **本地序列计数器** [决策✓]:PREAMBLE(74)/PITS(6)子计数;phase_start 复位。
  - **输出 mux**:按 phase 选 {训练计数器符号 / FIFO 数据符号 / PITS},sym_req 驱动。
- 流水线:[默认] ROM 查表 + mux 组合 + 1 级输出寄存;符号率 2Msym/s(每 24 拍 1 符号)远低于
  48MHz, 余量充足。
- 时序风险:无算术(归一化/exp 离线进 ROM),仅查表+mux,组合浅,48MHz 无压力。
- 时钟:继承 48MHz 单一时钟域,无 CDC。SRRC 的 2Msym/s tick 在 48MHz 下为节拍使能(非独立时钟域)。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs Python 参考模型逐符号比对 pass(结构+训练符号 0 容差)
- [ ] LTS ROM vs 公式逐符号比对 pass(定点容差)
- [ ] 不变量: preamble 74 结构 + GI=xu(13..16) + PITS N−1 次 pass
- [ ] cp_pfi / cp_u(15) / cp_phase 100%
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给你 review 的关键点 (本轮已全部确认)

1. **LTS 公式 + Table 7.7 + 训练符号量化码** [协议/定点 ✓ 已人核对]:ZC 公式(已渲染图核)、
   p 表、STS/PITS 量化码(±511/∓512)、LTS ROM 生成口径已核对无误 (2026-06-25)。
2. **符号 FIFO 深度** [决策✓]:参数化 `DEPTH`(默认 8),具体值留 W2 门级仿真收敛。
3. **phase / last_interval 接口** [决策✓]:本模块本地计数产训练结构,FSM 给 phase+start+last_interval;
   **本侧契约现冻结**,待 tx_ctrl_fsm W1(最后做)对齐。
4. **LTS ROM u 范围** [决策✓]:存 16 项(u=1..16,u=16 保留不选),按 u 直接索引。
5. **u/p 来源** [决策✓ O7]:MAC 在 kstart 给 u(4bit),PHY 查 p(非 PCA)。
6. **终止符号归属** [决策✓]:由 symbol_mapper 产(FSM 喂全 0)经 FIFO 进本模块,本模块不另算,
   与 symbol_mapper §1 口径一致。
