# W1 模块规格契约 — symbol_mapper

> 阶段B 草稿。本文件是喂给 W2(RTL生成)的唯一权威输入。
> 字段标记: [协议]=spec事实 · [决策✓]=已拍板 · [默认]=Claude填的合理默认值,待你review · [验证]=验证意图
> 上游顶层: 见 00_toplevel.md v0.3 (链路第④模块, 符号域入口)

---

## 0. 元信息
- module_name: `symbol_mapper`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] HDT Core Spec Vol6 PartA §7.3 (Modulation), Table 7.4 (π/4 QPSK) /
  Table 7.5 (8PSK) / Table 7.6 (16QAM); 终止符号 §7.4.4; bit/符号补齐与 n 复位 §7.3
- 在链路中的位置: puncturing → **[symbol_mapper]** → symbol_assembler
- status: frozen   # draft / reviewed / frozen  —— 6 review点全确认(含三表/量化码人核对); frozen 留给人
- 全局约定继承: 见 00_toplevel.md (48MHz 单一时钟域, 无 CDC); 符号量化 10bit

---

## 1. 功能描述 [协议]

把 puncturing 输出的处理后比特流 `{bn}` 按当前调制每 log₂(M) bit 映射成一个复符号 `Sk`
(I/Q 各 10bit 定点),送 symbol_assembler。M=4(π/4 QPSK)/8(8PSK)/16(16QAM)。

**映射表**(`1`/`0` 为 bit, 复符号见下;PSK 为单位圆相位, 16QAM 为幅度点):

- **Table 7.4 π/4 QPSK** [协议] (2bit/符号, **偶 k 与奇 k 用不同相位表, 奇符号 +π/4**):

  | bits (n=4k+0,+1) | 偶符号 S₂ₖ | bits (n=4k+2,+3) | 奇符号 S₂ₖ₊₁ |
  |---|---|---|---|
  | (0,0) | e^jπ/4  | (0,0) | e^jπ/2 = +j |
  | (0,1) | e^j3π/4 | (0,1) | e^jπ  = −1 |
  | (1,0) | e^−jπ/4 | (1,0) | e^0   = +1 |
  | (1,1) | e^−j3π/4| (1,1) | e^−jπ/2 = −j |

- **Table 7.5 8PSK** [协议] (3bit/符号): (0,0,0)→e^0 · (0,0,1)→e^jπ/4 · (0,1,0)→e^j3π/4 ·
  (0,1,1)→e^jπ/2 · (1,0,0)→e^−jπ/4 · (1,0,1)→e^−jπ/2 · (1,1,0)→e^−jπ · (1,1,1)→e^−j3π/4。

- **Table 7.6 16QAM** [协议] (4bit/符号, 表列为 Sk×10, 即 Sk = 右列值 × 归一化系数):

  | bits | Sk×10 | bits | Sk×10 |
  |---|---|---|---|
  | 0000 | −3−3j | 1000 | +3−3j |
  | 0001 | −3−1j | 1001 | +3−1j |
  | 0010 | −3+3j | 1010 | +3+3j |
  | 0011 | −3+1j | 1011 | +3+1j |
  | 0100 | −1−3j | 1100 | +1−3j |
  | 0101 | −1−1j | 1101 | +1−1j |
  | 0110 | −1+3j | 1110 | +1+3j |
  | 0111 | −1+1j | 1111 | +1+1j |

  **归一化** [协议 §7.3.3 + 决策✓ KD-A]:spec 原文为 **÷√10**(原文"dividing the number in
  the right column by √10", 列头 "Sk × √10", 例 (−3+3j)÷√10);与 00_toplevel 一致。
  使 16QAM 平均功率=1 与 PSK 一致。→ 16QAM 分量取值 {±1/√10, ±3/√10} = {±0.31623, ±0.94868}。

**关键协议事实**:
- **bit→符号补齐** [协议 §7.3]:N 非 log₂(M) 整数倍时,**末符号补 0 bit 凑齐**。
- **bit 索引 n 复位** [协议 §7.3]:每个终止符号序列后 n 复位到 0。
- **符号索引 k 复位** [协议 §7.3.1]:fmt0 首个 PDU+PL 符号 k=0;fmt1 PDU Header 首符号 &
  **每个 PHY Interval 首符号** k=0。π/4 QPSK 的偶/奇相位选择依赖 k 的奇偶。
  [默认] Control Header 作为首序列, k 亦从 0 起(spec 未显式点名 CH, 取自然起点)。
- **终止符号** [协议 §7.4.4]:2 个符号 = 用**当前调制映射全 0 bit**。本模块不另设特例——
  上游(assembler/FSM)喂全 0 bit, 本模块照常映射即得(与 00_toplevel "复用 mapper 喂全0" 一致)。
- **PITS 不经本模块** [协议 §7.4.5]:训练序列符号在 symbol_assembler 端常量给出。

**定点格式** [决策✓ KD-B]:I/Q 各 **10bit 有符号, Q0.9**(value = code/512, 码范围 −512…+511)。
- 注意 **+1.0 不可精确表示** → PSK 的 +轴点(e^0=+1, e^jπ/2=+j)的 +1.0 **饱和到 +511(=0.998)**,
  −1.0 = −512 精确。非对称 ±1LSB 误差, EVM 影响可忽略。**饱和不回绕**。
- 量化码值(供参考模型/RTL 对齐, round-to-nearest):
  - 0 → 0;  ±0.70710678 → ±362;  +1.0 → +511(饱和) / −1.0 → −512
  - 16QAM ÷√10: ±0.31623 → ±162;  ±0.94868 → ±486

不变量(验证用):
- **确定性查表**:给定 (mod_sel, k 奇偶, 符号 bit 组) → 输出符号唯一确定。
- **逐符号 = 量化表值**:RTL 输出 I/Q 必等于本 doc 量化码表(对量化表 0 容差)。
- **bit 守恒**:每 log₂(M) 个输入 bit(末符号含补 0)产出恰好 1 个符号。
- **k 奇偶**:π/4 QPSK 相邻符号在偶/奇表间交替;seq_start 后首符号为偶(k=0)。

---

## 2. 接口契约 [决策✓ + 默认]

```yaml
# ---- 上游: 来自 puncturing (frozen punc_out: 变长 0/1/2 bit/cycle) ----
interface: sym_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: valid_only      # 与比特域链路一致, 不反压
signals:
  - {name: code_in,      dir: input,  width: 2, desc: "[协议/frozen] = puncturing.code_out; LSB(bit0) 为发送序更早的位"}
  - {name: code_in_cnt,  dir: input,  width: 2, desc: "[协议/frozen] = puncturing.code_out_cnt; 本拍有效位数 0/1/2 (LSB起)"}
  - {name: seq_start,    dir: input,  width: 1, desc: "[决策✓] 序列/PHY Interval 首符号标志, k 复位为 0; 由 FSM 同源发出"}
  - {name: sym_flush,    dir: input,  width: 1, desc: "[决策✓] 序列 bit 流结束: 末符号若不足 log2(M) bit, 补 0 凑齐并产出; 由 FSM 发 (seq_flush 家族)"}

# ---- 配置 (kstart 锁存) ----
interface: sym_cfg
signals:
  - {name: mod_sel,      dir: input,  width: 2, desc: "[决策✓] 调制选择 00=π/4QPSK 01=8PSK 10=16QAM; 由 FSM 按 rate 映射, kstart 锁存"}

# ---- 下游: 符号 I/Q -> symbol_assembler ----
interface: sym_out
protocol: valid_only
signals:
  - {name: sym_i,        dir: output, width: 10, desc: "[决策✓] 符号 I, 有符号 Q0.9 (code/512), +1.0 饱和 +511"}
  - {name: sym_q,        dir: output, width: 10, desc: "[决策✓] 符号 Q, 有符号 Q0.9"}
  - {name: sym_valid,    dir: output, width: 1,  desc: "符号有效 (攒够一符号或 flush 补齐时拉高一拍)"}

handshake_rules:
  - "按 mod_sel 定每符号 bit 数 SB = 2(QPSK)/3(8PSK)/4(16QAM)"
  - "bit 累加器按 code_in_cnt 移入 code_in 的有效位 (LSB 先, 即发送序更早的位先入); cnt=0(气泡)不前进"
  - "[决策✓ 位序] 同一符号内, 先收到的 bit 占该符号 bit 组的 MSB 位 (对齐 Table 行序 (n0,n1,...) n0=MSB)"
  - "累加器满 SB 位: 查表得 (sym_i,sym_q), sym_valid 拉高一拍, 累加器清空, k++"
  - "π/4 QPSK: 按当前 k 奇偶选 偶/奇 相位表; seq_start 当拍 k 复位 0 (下一个产出符号为偶)"
  - "sym_flush: 当前未满符号补 0 至 SB 位, 查表产出该末符号, 然后累加器/计数清空"
  - "mod_sel 在 kstart 锁存, 序列内不变"
  - "复位期间所有输出 (sym_i/sym_q/sym_valid) 为 0"
  - "[决策✓] 比特域→符号域不反压: 不出 ready, 不收下游 ready (与上游一致)"
```

> [决策✓ 全部已定] sym_flush 由 FSM 发(seq_flush 家族); 符号内 bit 组装位序 = 先收 bit 占 MSB;
> Control Header 的 k 从 0 起; 三张表数值与量化码已人核对无误 (2026-06-25)。

---

## 3. 配置空间 [协议 + 决策]

| 参数 | 取值 | 说明 | 是否影响本模块 |
|---|---|---|---|
| mod_sel | π/4QPSK / 8PSK / 16QAM | 选表 + 每符号 bit 数 SB | **是 — 主功能维度** |
| k 奇偶 | even / odd | 仅 π/4 QPSK 选偶/奇表 | **是 (仅 QPSK)** |
| 符号 bit 组值 | 2/3/4 bit 全组合 | 查表索引 | **是 — 每调制全遍历** |
| 16QAM 归一化 | ÷√10 [决策✓] | 吸收进定点表常量 | 表数值 (已定死) |
| rate (RI) | HDT2..7.5 | 仅经 rate→mod_sel 间接相关 | **否 (折叠成 mod_sel)** |
| format / 序列类型 | short/fmt0/fmt1 | 仅决定 seq_start/flush 时点 | **否 (上游给边界)** |
| 编码率打孔 | 2/3,3/4,15/16 | 上游 puncturing 的事 | **否 (显式排除)** |

> 组合自检:真正需 cross 的维度 = **mod_sel × (符号 bit 组全值) × (QPSK 的 k 奇偶)**。
> 即 QPSK: 2×4=8 入口(偶/奇×4); 8PSK: 8 入口; 16QAM: 16 入口。共 32 个查表入口须全覆盖。
> rate/format/打孔不在本模块分支。

---

## 4. 验证意图 [验证 — 你 review 的核心]

### 4.1 判定锚点 [默认]
- **主锚点:Python 参考模型 + 定点容差**(查表映射类)。
  - 参考模型:浮点理想星座(三表 + ÷√10)→ 按 Q0.9 量化(round-to-nearest, +1.0 饱和 +511)
    得"量化金标"。
  - **对量化金标 0 容差**:本模块是纯查表, RTL 输出必逐符号精确等于量化码表。
  - **对理想浮点 EVM 容差**:量化引入的 RMS 误差应远小于 Table 3.6 EVM 预算(本模块仅贡献
    量化噪声, SRRC 段再核 EVM 总账)。
- 辅助不变量(无需 golden):bit 守恒 / k 奇偶交替 / seq_start 后首符号为偶 / 确定性。

### 4.2 必查 corner case [默认, 待你补充]
- **三调制每个查表入口全遍历**(QPSK 偶/奇各 4、8PSK 8、16QAM 16,共 32)。
- **π/4 QPSK 偶/奇相位交替**:连续多符号验证 k 奇偶切换正确。
- **seq_start 复位 k**:序列中途 seq_start, 其后首符号回到偶表。
- **末符号补 0**(sym_flush):剩 1bit(QPSK)/1~2bit(8PSK)/1~3bit(16QAM)时补 0 凑齐。
- **+1.0 饱和点**:PSK 的 +1/+j 符号验证饱和到 +511(非回绕)。
- **16QAM 四象限极值点**(±3±3j/√10)与内点(±1±1j/√10)。
- **输入气泡** code_in_cnt=0 时累加器不前进。
- **跨拍攒符号**:cnt=1 与 cnt=2 混合输入下符号边界对齐(如 16QAM 需 2+2 或 1+1+1+1)。
- **背靠背两序列 mod_sel 不同**(kstart 重锁存)。

### 4.3 覆盖率目标 [默认]
```systemverilog
covergroup cg_symmap @(posedge clk);
  cp_mod:   coverpoint mod_sel { bins m[] = {0,1,2}; }      // 三调制
  cp_qpsk:  coverpoint sym_bits iff(mod_sel==0);            // QPSK 4 组合
  cp_kpar:  coverpoint k_parity iff(mod_sel==0);            // 偶/奇
  cp_8psk:  coverpoint sym_bits iff(mod_sel==1);            // 8PSK 8 组合
  cp_16qam: coverpoint sym_bits iff(mod_sel==2);            // 16QAM 16 组合
  x_qpsk:   cross cp_qpsk, cp_kpar;                         // 偶/奇 × 4 = 8 入口
  cp_flush: coverpoint flush_pad_len;                       // 末符号补 0 位数
endgroup
```
- 32 个查表入口 100%(x_qpsk + cp_8psk + cp_16qam 全覆盖)
- cp_flush: 各补 0 位数都激励

### 4.4 接口断言 (由第2节契约生成)
- assert: 每产出 1 符号 ⇔ 累加器吃满 SB 位 (或 flush 补齐)。
- assert: seq_start 后第一个产出符号的 k_parity == even。
- assert: mod_sel==0 时 sym_i/sym_q ∈ 量化表的 8 个 QPSK 码值。
- assert: sym_i/sym_q 永不出现 +512 (饱和到 +511)。
- assert: 复位期 sym_valid==0。
- assert: code_in_cnt==0 拍不产出符号 (除非恰好之前已攒满——不与气泡同拍)。

### 4.5 充分性二级指标 [默认]
- mutation kill rate ≥ 90%。注入变异:表某入口 I 或 Q 取错、偶/奇表互换、k 奇偶不复位、
  符号内 bit 位序反转(MSB/LSB)、SB 取错(2/3/4 混)、末符号漏补 0、+1.0 回绕代替饱和、
  16QAM 归一化系数错(÷10 vs ÷√10)。好的测试集应全部杀死。

---

## 5. 架构与定点约束 [协议 + 决策]

- 定点 [决策✓]:I/Q 各 10bit 有符号 Q0.9 (code/512);三表数值按 §1 量化码常量存。
  - 16QAM ÷√10 归一化吸收进表常量(不在线做除法/平方根)。
  - PSK √2/2 → ±362;单位 1.0 → +511(饱和)/−512。
- 核心电路:
  - **bit 累加器** + SB 计数器(SB=2/3/4 由 mod_sel)。按 code_in_cnt 移入 0/1/2 bit。
  - **星座 ROM**:常量表, 索引 = {mod_sel, (QPSK)k_parity, 符号 bit 组} → (sym_i, sym_q)。
    共 8(QPSK)+8(8PSK)+16(16QAM)=32 入口 × 2×10bit。
  - **k_parity** 触发器(仅 QPSK 用), seq_start 复位。
  - **flush 补 0**:sym_flush 时把累加器高位补 0 凑满 SB 再查表。
- 流水线:[默认] 查表组合 + 1 级输出寄存;符号产出节奏由输入 bit 速率决定(变长攒符号),
  峰值 2Msym/s 远低于 48MHz, 余量充足。
- 时序风险:ROM 查表 + 小累加器, 组合深度浅, 无除法/平方根(归一化已离线), 48MHz 无压力。
- 时钟:继承 48MHz 单一时钟域, 无 CDC。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs 量化金标逐符号比对 pass (0 容差)
- [ ] vs 理想浮点星座 EVM(量化噪声)≤ 预算
- [ ] 不变量: bit 守恒 + k 奇偶交替 + seq_start 复位 pass
- [ ] 32 查表入口 100% + cp_flush 覆盖
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给你 review 的关键点 (本轮已全部确认)

1. **三张表数值 + 量化码** [协议/定点 ✓ 已人核对]:Table 7.4/7.5/7.6 与量化码
   (±362 / +1.0→+511饱和 / 16QAM ±162、±486)已对照核对无误 (2026-06-25)。
2. **符号内 bit 组装位序** [决策✓ 命门]:先收到的 bit 占符号 bit 组 **MSB**(对齐 Table 行序
   (n0,n1,…) n0=MSB)。参考模型/RTL 均以此为准。
3. **16QAM 归一化 ÷√10** [协议 §7.3.3]:spec 原文确为 ÷√10(pdftotext 曾丢 √ 字形,已渲染图核正),
   与 00_toplevel 一致,无偏离。16QAM 平均功率=1 与 PSK 一致。
4. **+1.0 饱和到 +511** [决策✓ KD-B]:Q0.9 下 +1.0 饱和不回绕,接受非对称 ±1LSB。
5. **sym_flush 末符号补齐** [决策✓]:末符号不足 SB bit 补 0,由 FSM 发 sym_flush(seq_flush 家族)。
6. **Control Header 的 k 起点** [决策✓]:CH 作首序列 k 从 0 起。
