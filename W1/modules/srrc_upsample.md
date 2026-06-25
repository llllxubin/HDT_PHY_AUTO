# W1 模块规格契约 — srrc_upsample

> 字段标记: [协议]=spec事实 · [决策✓]=人已拍板 · [默认]=待确认 · [验证]=验证意图
> status 只有 frozen 才允许进入 W2。

---

## 0. 元信息
- module_name: `srrc_upsample`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] Vol 6 Part A §7.5 (Pulse shaping / P(f)); §3.6 (v(t), EVM); Table 3.6 (EVM 上限); p(t) 同 [Vol 2] Part A §3.2.1.3
- 在链路中的位置: symbol_assembler → **[srrc_upsample]** → (模拟前端 / DAC)
- status: frozen   # draft / reviewed / frozen  —— 8决策点全拍板(含§7.5 P(f)渲染核对)+尾零flush口径确认; frozen 留给人
- 全局约定继承: 见 00_toplevel.md (48MHz 单一时钟域无 CDC; 异步复位同步释放 rst_n 低有效)

---

## 1. 功能描述 [协议]

把 symbol_assembler 给出的 **2 Msym/s 复符号流**(I/Q 各 10bit Q0.9)经
**平方根升余弦 (SRRC) 脉冲整形 + ×6 上采样**,产出 **12 MHz 复基带样本流 v(t)**
(I/Q 各 12bit Q2.9),送模拟前端。载波调制 s(t)=Re{v(t)·e^{j2πF_c t}} 在模拟侧,
本模块只产基带 v(t)。

**协议事实 (W1a, §7.5 已渲染图核对——pdftotext 曾吞 √ 与 |f|):**
- 整形滤波器为 **square-root raised cosine**,频域幅度
  `|P(f)| = 1` (0≤|f|≤(1−β)/2T);
  中段 = **√( ½ (1 − sin( π(2|f|T−1) / 2β )) )` ← 是升余弦的**平方根**;
  `0` (elsewhere)。
- 滚降 **β = 0.4** [协议];符号周期 **T = 0.5 µs** (2 Msym/s) [协议]。
- 时域 p(t) = P(f) 的 IFT;**spec 不给时域抽头表**,抽头由 MATLAB golden 生成(见 §5)。
- 输出信号 `v(t) = Σ_{k=0}^{N/log2(M)−1} S_k · p(t − kT_s)` [协议 §3.6]。
- 整形质量以 **RMS EVM** 度量(1000 符号 / 1500 包),最紧限 **HDT4 payload −16 dB** [Table 3.6]。

**工程参数 (继承全局, 非 spec):** 31 抽头 (span=5 符号)、系数 7bit、×6 上采样、IQ 12bit。

不变量:
- **采样率关系**: 每 1 输入符号 ↔ 6 输出样本 (×6);48MHz 下符号请求每 24 拍、输出每 4 拍。
- **固定时延**: 输出相对输入恒定群延迟 = (31−1)/2 = **15 样本** (= 2.5 符号),与数据无关。
- **线性相位**: SRRC 抽头对称 → 相位线性,无群延迟失真。
- **冷启动确定性**: 包起始延迟线清零后,给定符号流 → 输出逐样本唯一确定 (可对 golden bit-exact)。
- **调制无关**: 滤波行为与 M (4/8/16) / rate / format 无关,只处理 I/Q 数值。

---

## 2. 接口契约 [决策✓]

```yaml
# ---- 上游符号流: 来自 symbol_assembler.asm_out, 本模块驱动 sym_req 拉 ----
interface: srrc_sym_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: pull            # [决策✓ 继承] SRRC 产 2Msym/s tick 拉, assembler 当拍给符号
signals:
  - {name: sym_req,    dir: output, width: 1,  desc: "[决策✓] 符号率请求 -> assembler.sym_req; 48MHz 下每 24 拍一拍"}
  - {name: sym_i,      dir: input,  width: 10, desc: "[协议/继承] = assembler.out_i, 有符号 Q0.9 (code/512)"}
  - {name: sym_q,      dir: input,  width: 10, desc: "[协议/继承] = assembler.out_q, 有符号 Q0.9"}
  - {name: sym_valid,  dir: input,  width: 1,  desc: "= assembler.out_valid, 响应 sym_req 当拍有效"}

# ---- 控制: 来自 tx_ctrl_fsm ----
interface: srrc_ctrl
signals:
  - {name: pkt_start,  dir: input,  width: 1,  desc: "[决策✓] 包起始脉冲: 清空延迟线/多相状态, preamble 冷启动"}

# ---- 下游: 12 MHz 复基带 -> 模拟前端 / DAC ----
interface: srrc_iq_out
protocol: valid_only      # [决策✓] 无反压, 12MHz 节拍连续出
signals:
  - {name: iq_i,       dir: output, width: 12, desc: "[决策✓ Q2.9] v(t) 实部 (code/512, 范围 ±4.0), 末级 round-half-up + 饱和"}
  - {name: iq_q,       dir: output, width: 12, desc: "[决策✓ Q2.9] v(t) 虚部"}
  - {name: iq_valid,   dir: output, width: 1,  desc: "12MHz 样本有效 tick (48MHz 下每 4 拍一拍)"}

handshake_rules:
  - "sym_req 每 24 拍一拍 (2Msym/s); 同拍 assembler 回 sym_i/sym_q/sym_valid"
  - "每输入 1 符号, iq_out 在该符号周期内产 6 个样本 (iq_valid 每 4 拍一拍, ×6)"
  - "pkt_start 当拍: 延迟线全清 0, 多相 commutator 复位到首相; 此后输出对该包冷启动确定"
  - "2 个终止符号按有效符号处理(其脉冲与数据符号一样需完整成形, 不兼作 flush)"
  - "尾部 flush 由 tx_ctrl_fsm 负责: FSM 在最后一个符号(末终止符号)之后另补 ⌈15/6⌉=3 个纯 0 符号(=18 样本 ≥ 15 群延迟), 推干净末符号尾巴; 本模块为纯流式滤波器, 不设 drain 计数器/last 端口"
  - "复位期间 sym_req=0, iq_valid=0, iq_i/iq_q=0"
```

> [全部已定] 8 决策点(滤波结构/系数定点/舍入饱和/输出格式/golden源/EVM锚点/边界flush/相位约定)均人拍板, 见 §7。

---

## 3. 配置空间 [协议 + 决策]

SRRC 滤波器对所有速率/调制/格式**完全相同**,β/抽头/系数为**编译期常量**,运行期**无可配项**。

| 参数 | 取值范围 | 说明 | 是否影响本模块 |
|---|---|---|---|
| β (滚降) | 0.4 | [协议] 编译期常量 | 否(固定常量, 不 cross) |
| 抽头数 / span | 31 / 5符号 | [继承] 编译期常量 | 否(固定常量) |
| 上采样率 L | 6 | [继承] 编译期常量 | 否(固定常量) |
| M (4/8/16 调制) | — | SRRC 只处理 I/Q 数值 | **否(显式排除)** |
| LE HDT rate (HDT2/3/4) | — | 滤波器与速率无关; 仅 EVM 阈值不同(验证侧) | **否(显式排除, 仅验证目标用)** |
| packet format (short/fmt0/fmt1) | — | 纯流式, 与包结构无关 | **否(显式排除)** |
| 符号峰值幅度 | Q0.9 各分量 ±1.0(饱和±511) | 决定过冲/饱和裕量 | 是(corner 用) |

> 组合爆炸自检: 本模块**无运行期配置维度**需 cross; 唯一激励维度是输入符号序列(幅度/相位组合),
> rate/M/format 与本模块行为正交,仅 rate 用于选 EVM 验收阈值。

---

## 4. 验证意图 [验证]

### 4.1 判定锚点 (DSP 定点类 → MATLAB golden + EVM, 双锚点)
- **主锚点 (指标闸门)**: MATLAB **浮点理想** SRRC 输出为 ideal,定点 RTL 输出对其算
  **RMS EVM**,对标 Table 3.6,须满足最紧 **HDT4 payload ≤ −16 dB**(留设计裕量)。
- **辅锚点 (功能闸门)**: RTL 输出 vs **量化后 MATLAB** 参考流 **逐样本 bit-exact (0 容差)**。
- **系数契约**: 7bit 量化系数表由 §5 配方在 W2 重生成,与 spec 附的 16 唯一码 bit-exact 自检。
- 容差: 功能闸门 0 容差; 指标闸门 EVM ≤ Table 3.6 阈值。

### 4.2 必查 corner case
- **包起始冷启动**: pkt_start 后延迟线全 0,首样本起对 golden bit-exact。
- **背靠背包**: 两包间 pkt_start 必须清干净延迟线,验证上一包拖尾不污染下一包 preamble。
- **单符号 / 最短包**: preamble-only 等极短序列经群延迟正确吐出。
- **尾零 flush**: 末终止符号后 FSM 另补 3 个纯 0 符号(=18样本≥15群延迟),末符号脉冲尾部完整吐出。
- **峰值/过冲饱和**: 16QAM 外点连串 + SRRC 过冲(理论峰 ~±1.5),验证 Q2.9 不溢出/饱和点正确。
- **多相全相覆盖**: 一个符号周期内 6 个样本(全部多相分支)都被激励。

### 4.3 覆盖率目标
```systemverilog
covergroup cg_srrc @(posedge clk);
  cp_phase   : coverpoint poly_phase {bins ph[] = {[0:5]};}      // 6 多相分支全覆盖
  cp_sat     : coverpoint out_saturate {bins hit = {1}; bins no = {0};}
  cp_coldstart : coverpoint pkt_start_seen;                       // 冷启动后首样本路径
  cp_symamp  : coverpoint sym_abs_max {bins low; bins mid; bins peak;} // 含外点峰值
endgroup
```
- functional coverage 目标: 100% (多相分支/饱和命中与否/冷启动)
- cross 目标: phase × sym_amp ≥ 90%

### 4.4 接口断言 (由 §2 契约生成)
- assert: sym_req 周期严格 24 拍 (2Msym/s tick 稳定)。
- assert: 每个 sym_req 周期内 iq_valid 恰好 6 拍 (×6, 每 4 拍一拍)。
- assert: pkt_start 后固定 15 样本群延迟首个有效数据样本出现。
- assert: 复位/IDLE 期间 iq_i=iq_q=0, iq_valid=0。
- assert: iq_i/iq_q 落在 Q2.9 合法范围, 越界即饱和(无回绕)。

### 4.5 充分性二级指标
- mutation kill rate 目标: ≥ 90%。注入变异:
  系数符号位翻转 / 单抽头错值 / 多相分支错序 / 舍入改为截断 / 去掉饱和(改回绕) /
  群延迟 ±1 样本错位 / 延迟线复位漏清。

---

## 5. 架构与定点约束 [决策✓]

### 5.1 定点方案
| 信号 | 格式 | 说明 |
|---|---|---|
| 输入符号 sym_i/q | 10bit 有符号 **Q0.9** | value=code/512, 继承 assembler |
| 系数 h | 7bit 有符号 **Q0.6 峰值归一** | value=code/64, ±1.0; 峰值抽头缩放占满量程 → 饱和到 63 |
| 累加器 | 全精度 (~Q?.15 + 守护位) | 单相 ~5–6 抽头, 10b×7b 积 = Q0.15, 求和需 ~⌈log2(taps)⌉ 守护位 |
| 输出 iq_i/q | 12bit 有符号 **Q2.9** | value=code/512(同输入 LSB 权重), 2 整数位容纳过冲(~±1.5), 饱和门 ±4.0 |
- 末级: 累加器 → **round-half-up** 对齐到 Q2.9 → 越界**对称饱和**(无回绕)。

### 5.2 系数 golden 配方 (W1 冻结的契约真值)
```matlab
% 权威源: MATLAB. W2 跑同一脚本重生成 7bit 系数表, bit-exact 自检
beta = 0.4;        % [协议 §7.5]
span = 5;          % 符号跨度 -> taps = span*sps + 1 = 31
sps  = 6;          % 上采样 ×6
h  = rcosdesign(beta, span, sps, 'sqrt');   % 31 抽头 SRRC, 线性相位对称(默认 Σh²=1)
hq = round(h ./ max(abs(h)) .* 64);          % 峰值归一 -> Q0.6
hq(hq > 63) = 63;                            % +1.0 越界饱和到 63/64
% hq: 31 个 7bit 有符号码, 对称 -> 16 唯一系数 (spec 附 informative 表, 不手抄真值)
```
> 契约真值 = 上述**配方 + 量化规则**(非手抄数表);spec 另附 16 唯一码作 informative 对照。

### 5.3 核心电路
- **6 相 polyphase 插值器**: 31 抽头按多相分解为 6 个子滤波器(每相 5–6 抽头),
  各对真实符号求积累加(无 zero-stuff 浪费),commutator 按固定时间序吐 6 样本/符号。
- 抽头对称 → 可折叠为 ~16 唯一系数(W2 实现优化, 不入 I/O 契约)。
- **相位约定**: I/O 契约**不锁"相几=符号中心"的相号**(纯 W2 内部细节);只钉
  ① 6 样本/符号、按时间先后排;② 固定群延迟 15 样本;③ 逐样本 bit-exact 对 golden
  (golden 唯一确定各相分配,相号叫 0/2/3 都自洽)。

### 5.4 流水线 / 时序
- 流水级数: [默认] W2 按乘加树定,目标 48MHz 宽松收敛;群延迟(数据相关 0)固定 15 样本。
- 时序风险: 10b×7b 乘法器 ×(每相抽头)+ 加法树。48MHz 周期 ~20.8ns 宽松,风险低;
  最坏路径为单相乘加树,必要时插 1 级流水(不影响群延迟语义,只增固定延迟)。
- 时钟: 继承 48MHz 单时钟域。sym_req 每 24 拍;iq_valid 每 4 拍。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass (sym_req 周期 / ×6 节拍 / 群延迟 / 饱和)
- [ ] vs 量化 MATLAB 参考流 逐样本 bit-exact pass
- [ ] RMS EVM ≤ Table 3.6 阈值 (至少 HDT4 −16 dB, 留裕量) pass
- [ ] 不变量 pass (采样率关系 / 固定群延迟 / 冷启动确定性)
- [ ] 覆盖率达标 (多相 6 分支 / 饱和 / 冷启动 100%; cross ≥90%)
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给人 review 的关键点
> 本轮 8 决策已全部确认, 记录如下供复核:
1. **[决策✓] §7.5 P(f) 渲染核对**: 中段是升余弦的 **√**(pdftotext 曾吞 √/|f|); β=0.4, T=0.5µs。
2. **[决策✓] 滤波结构**: 6 相 polyphase(省 5/6 ×0 乘法), 非 zero-stuff 直接型。
3. **[决策✓] 系数定点**: 7bit Q0.6 峰值归一(value=code/64, +1.0 饱和 63)。
4. **[决策✓] 输出格式**: 12bit Q2.9(同输入 LSB 权重, 2 整数位容过冲, ±4.0 饱和)。
5. **[决策✓] 末级舍入/饱和**: round-half-up + 对称饱和(无回绕, 防 DC 偏置恶化 EVM)。
6. **[决策✓] golden 源**: MATLAB `rcosdesign('sqrt')` 配方冻结为契约真值; EVM 双锚点
   (浮点理想算 EVM + 量化 MATLAB 逐样本 bit-exact 功能闸门)。
7. **[决策✓] 边界 flush**: pkt_start 清延迟线; 2 终止符号按有效符号处理, 尾部 flush 由
   **tx_ctrl_fsm 在末终止符号后另补 3 个纯 0 符号**(⌈15/6⌉, =18样本≥15群延迟)负责,
   本模块纯流式(无 drain/last 端口)。← **此耦合待 tx_ctrl_fsm 模块收口**。
8. **[决策✓] 相位约定**: I/O 契约不锁相号, 只钉 6样本/符号时间序 + 15样本固定群延迟 +
   bit-exact 对 golden。
