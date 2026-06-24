# W1 模块规格契约 — fec_encoder

> 阶段B 打样模板。本文件是喂给 W2(RTL生成)的唯一权威输入。
> 字段标记: [协议]=spec事实 · [决策✓]=已拍板 · [默认]=Claude填的合理默认值,待你review · [验证]=验证意图
> 上游顶层: 见 00_toplevel.md v0.3 (链路第②模块)

---

## 0. 元信息
- module_name: `fec_encoder`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] HDT Core Spec Vol6 PartB §3.4.3 (Convolutional encoder), Figure 3.10
- 在链路中的位置: interval_spacing → **[fec_encoder]** → puncturing
- status: frozen   # draft / reviewed / frozen  —— 已冻结, 可进 W2

---

## 1. 功能描述 [协议]

对输入比特流做 rate-1/2 卷积编码。每输入 1 bit,输出 2 bit (a0, a1),a0 先发。
非系统、非递归,约束长度 K=6 (5 个延迟寄存器,32 状态),初始全 0。
每个 bit 序列末尾由上游发 flush,本模块自动追加 5 个 0 (termination),
使编码器回到全 0 态;下一序列重新从全 0 开始。

生成多项式:
- G0(x) = 1 + x² + x⁴ + x⁵   → 抽头 {0,2,4,5}
- G1(x) = 1 + x + x² + x³ + x⁵ → 抽头 {0,1,2,3,5}

> 不变量(验证用): 编码器对同一输入序列(含termination)的输出唯一确定;
> 序列结束后内部状态必回全 0。

---

## 2. 接口契约 [决策✓ + 默认]

```yaml
# ---- 上游: 逐bit接收 (来自 interval_spacing 或 MAC字节拆位) ----
interface: fec_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: valid_only      # [决策✓] 逐bit喂入, 上游保证节奏, FEC不反压上游
signals:
  - {name: bit_in,        dir: input,  width: 1, desc: "输入数据比特"}
  - {name: bit_in_valid,  dir: input,  width: 1, desc: "输入比特有效"}
  - {name: seq_start,     dir: input,  width: 1, desc: "[决策✓] 序列首bit标志,触发编码器清零"}
  - {name: seq_flush,     dir: input,  width: 1, desc: "[决策✓] 状态机发:本序列数据已完,FEC自动追加5个0 termination"}

# ---- 下游: 每输入1bit输出2bit (a0,a1) ----
interface: fec_out
protocol: valid_only
signals:
  - {name: code_out,      dir: output, width: 2, desc: "[默认] {a1,a0}, bit0=a0先发"}
  - {name: code_out_valid,dir: output, width: 1, desc: "输出有效"}
  - {name: term_done,     dir: output, width: 1, desc: "[默认] termination完成(5个0已编码完),供状态机切下一序列"}

handshake_rules:
  - "seq_start 与序列首个 bit_in_valid 同拍, 当拍编码器状态清零再吃首bit"
  - "seq_flush 后, 模块自动连续编码 5 个 0, 期间 code_out_valid 保持有效"
  - "termination 5个0编码完, term_done 拉高一拍, 内部状态回全0"
  - "复位期间所有 valid/输出为0"
  - "[默认] 暂不支持下游反压; 若 puncturing 需反压, 后续加 ready (待 D1 状态机定)"
```

> [默认待确认] 输出宽度定为 2bit 并行 ({a1,a0})。理由: 1bit进2bit出, 并行输出免去
> 输出端再做 2:1 串化, 下游 puncturing 按 2bit 组处理更自然。若你希望串行 1bit 输出
> (2 周期), 可改 —— 但会让吞吐和下游对齐复杂化。

---

## 3. 配置空间 [协议 + 决策✓]

| 参数 | 取值 | 说明 | 是否影响本模块 |
|---|---|---|---|
| 编码率 | 恒 1/2 | **FEC 本身永远 1/2 编码** | 否 — 打孔在下游 puncturing 做 |
| 序列类型 | CH / PDU Header / Payload / PHY Interval | 决定序列边界, 但编码逻辑相同 | 仅边界(seq_start/flush)不同 |
| 数据率 HDT2..7.5 | — | 与 FEC 编码逻辑无关 | **否 (显式排除)** |

> 关键认知 [决策✓]: 不同编码率(2/3,3/4,15/16)由下游 **puncturing** 实现,
> FEC 永远输出 1/2 码。本模块**无 rate 配置**, 配置空间极小 —— 组合爆炸不在这。
> 唯一的"组合"是: 不同序列长度 × termination 边界, 由 seq_start/seq_flush 覆盖。

---

## 4. 验证意图 [验证 — 你 review 的核心]

### 4.1 判定锚点 [决策✓]
- **主锚点: Python 参考模型逐bit比对**。
  - 参考模型: 纯 Python 实现同一卷积码(移位+XOR), 输入序列→输出2bit流。
  - RTL 仿真 dump `code_out`, 与参考模型逐bit对齐比对, 0 容差(纯逻辑无定点)。
- 辅助不变量(无需golden):
  - 序列(含5个0 termination)编码完, 内部 5 寄存器必为全 0 (formal 可证)。
  - 输出bit数 = (输入bit数 + 5) × 2。

### 4.2 必查 corner case [默认, 待你补充]
- 单bit序列 + termination (最短序列)
- seq_start 与 seq_flush 紧邻 (极短序列边界)
- 背靠背两序列 (前序列 term_done 后一拍即下一序列 seq_start) — 验证清零正确
- 全 0 输入序列 / 全 1 输入序列 (抽头激励极值)
- bit_in_valid 中间出现空拍(气泡)时编码器是否正确保持状态

### 4.3 覆盖率目标 [默认]
```systemverilog
covergroup cg_fec @(posedge clk);
  // 编码器32状态全遍历 — 卷积码核心覆盖目标
  cp_state: coverpoint enc_state { bins all[] = {[0:31]}; }
  // 输入bit取值
  cp_bit: coverpoint bit_in iff(bit_in_valid);
  // 状态×输入 交叉: 确保每个状态下0/1输入都激励过
  x_state_bit: cross cp_state, cp_bit;
  // 序列边界事件
  cp_evt: coverpoint {seq_start, seq_flush, term_done};
endgroup
```
- 状态遍历 cp_state: 100% (32状态全覆盖)
- 交叉 x_state_bit: 100% (state machine 完备性)

### 4.4 接口断言 (由第2节契约生成)
- assert: seq_start 当拍编码器清零
- assert: seq_flush 后恰好 5 个 0 被编码, term_done 才拉高
- assert: term_done 后内部状态 == 全0
- assert: 复位期 code_out_valid == 0

### 4.5 充分性二级指标 [默认]
- mutation kill rate ≥ 90%。注入变异: 改 G0/G1 抽头位置、termination 补4或6个0、
  漏清零、a0/a1 调换顺序。好的测试集应全部杀死。

---

## 5. 架构与定点约束 [协议 + 默认]

- 定点: **N/A** (纯比特逻辑, 无算术)
- 核心电路: 5-bit 移位寄存器 `enc_state[4:0]` + 两组 XOR 归约树
  - a0 = bit_in ^ enc_state[1] ^ enc_state[3] ^ enc_state[4]   (G0抽头{0,2,4,5}, 注意x⁰=当前bit)
  - a1 = bit_in ^ enc_state[0] ^ enc_state[1] ^ enc_state[2] ^ enc_state[4] (G1抽头{0,1,2,3,5})
  - [决策✓ — 已由用户对照 Figure 3.10 核对确认] 抽头与寄存器索引映射正确
- 流水线: [默认] 0级 (组合输出 + 1级状态寄存器), 单周期吞吐 1bit/cycle
- 时序: 组合路径 = 输入到 a0/a1 的 XOR 树, 深度浅, 无时序风险
- 时钟/吞吐核算 [决策✓]:
  - **全部模块工作在 48MHz 单一时钟域**, 无 CDC。
  - 最高有效比特率 7.5Mb/s, FEC 处理编码前比特, 逐bit节奏(8周期/字节)。
    48MHz 时钟下单周期处理 1bit 的吞吐余量充足(远高于最坏编码前比特率)。
  - 无跨时钟域处理, 简化复位与时序收敛。

---

## 6. 完成定义 [自动判定]

- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs Python 参考模型逐bit比对 pass (0容差)
- [ ] 不变量: 序列结束状态归零 pass (formal)
- [ ] cp_state 32状态 100%, x_state_bit 100%
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给你 review 的关键点 (打样模板特别标注)

1. ~~第5节抽头映射~~ — [已确认✓ 用户对照 Figure 3.10 核对, 正确]
2. ~~第2节输出宽度~~ — [已确认✓ 2bit 并行 {a1,a0}]
3. **第5节工作时钟** — [已定✓] 全部模块 48MHz 单一时钟域, 无 CDC。
4. **第4.2节 corner case** — 是否有 HDT 特有的边界我没列到。
