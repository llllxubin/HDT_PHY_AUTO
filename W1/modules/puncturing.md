# W1 模块规格契约 — puncturing

> 阶段B 草稿。本文件是喂给 W2(RTL生成)的唯一权威输入。
> 字段标记: [协议]=spec事实 · [决策✓]=已拍板 · [默认]=Claude填的合理默认值,待你review · [验证]=验证意图
> 上游顶层: 见 00_toplevel.md v0.3 (链路第③模块)

---

## 0. 元信息
- module_name: `puncturing`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] HDT Core Spec Vol6 PartB §3.4.4 (Puncturing), Table 3.5;
  编码率来源 §3.4 Table 3.2 / Table 3.3
- 在链路中的位置: fec_encoder → **[puncturing]** → symbol_mapper
- status: frozen   # draft / reviewed / frozen  —— 5决策点已拍板+Table3.5已人核对; frozen 留给人
- 全局约定继承: 见 00_toplevel.md (48MHz 单一时钟域, 无 CDC)

---

## 1. 功能描述 [协议]

对 FEC 编码器输出的 1/2 码流做**打孔**(puncturing):按编码率对应的打孔模式,
删除模式中标记为 0 的比特、保留标记为 1 的比特,从而把有效编码率提高到
2/3、3/4 或 15/16;编码率 1/2 时模式为 `[1 1]`,等价于**不打孔**(透传)。

- 打孔模式作用于 FEC 输出的**发送顺序码流**:FEC 每输入 1bit 输出 2bit `{a1,a0}`、
  `a0` 先发,故模式按 `…, a0, a1, a0, a1, …` 的顺序逐位施加。
- 模式从每个编码序列起点开始循环,**重复直到该编码序列结束**;最后一次模式重复
  **按数据长度截断**(无需补齐整周期)。
- 编码率由 Control Header 的 Rate Indicator (RI) 决定(§3.4 Table 3.2:fmt0 的
  PDU Header+Payload / fmt1 的 Payload Zone)。**Control Header 恒 1/2、不打孔**;
  **fmt1 的 PDU Header 恒 1/2**(Table 3.3)。即"该序列用什么率"由上游控制逻辑按
  序列类型 + RI 映射后给本模块(见 §2 `punc_rate`),本模块只忠实施加对应模式。

打孔模式(Table 3.5,`1`=保留 / `0`=丢弃):

| 编码率 | 模式 | 模式长 L | 保留数 K | 校验 (L/2)/K |
|---|---|---|---|---|
| 1/2 | `[1 1]` | 2 | 2 | 1/2(=不打孔) |
| 2/3 | `[1 1 0 1]` | 4 | 3 | 2/3 |
| 3/4 | `[1 1 0 1 0 1]` | 6 | 4 | 3/4 |
| 15/16 | `[1 1 0 1 1 0 1 0 1 0 0 1 0 1 0 1 1 0 1 0 0 1 0 1 0 1 1 0 0 1]` | 30 | 16 | 15/16 |

> 打孔施加于**整个**编码序列输出,包含 FEC termination 的 5 个 0 对应的 10 个输出
> 比特(termination 是编码序列的一部分,不另作豁免)。

不变量(验证用):
- **恒等**:`rate=1/2` 时输出码流 == 输入码流(逐位相等,位序不变)。
- **守恒/长度关系**:对恰好 N 个完整模式周期的输入(N×L 位),输出 = N×K 位;
  一般情形输出位数 = 所消耗输入位上模式 `1` 的个数。
- **保序**:只删不重排,输出位的相对顺序与输入一致。
- **确定性**:给定(`rate`、输入码流、序列边界),输出唯一确定。

---

## 2. 接口契约 [决策 + 默认]

```yaml
# ---- 上游: 来自 fec_encoder (2bit/cycle 并行, valid_only) ----
interface: punc_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: valid_only      # [默认] 逐拍接收 FEC 输出, 不反压上游 (与 FEC 一致)
signals:
  - {name: code_in,       dir: input,  width: 2, desc: "[协议] FEC code_out, {a1,a0}, bit0=a0 先发"}
  - {name: code_in_valid, dir: input,  width: 1, desc: "输入码对有效 (= FEC code_out_valid)"}
  - {name: seq_start,     dir: input,  width: 1, desc: "[决策✓] 序列首个码对标志, 打孔模式相位复位到0; 由统一控制状态机在序列/PHY Interval 首码对同拍发出"}
  - {name: punc_rate,     dir: input,  width: 2, desc: "[决策✓] 编码率选择 00=1/2 01=2/3 10=3/4 11=15/16; 由控制状态机按序列类型+RI 映射, seq_start 拍锁存"}

# ---- 下游: 变长 0/1/2 bit/cycle (打孔后码流) -> symbol_mapper ----
# [决策✓ A] 输出接口 = 变长 0/1/2 bit/cycle, 零缓冲零反压 (见 §7.1)
interface: punc_out
protocol: valid_only
signals:
  - {name: code_out,      dir: output, width: 2, desc: "[决策✓] 本拍输出的保留位, LSB(bit0) 对齐发送序更早的位 (a0 侧); cnt<2 时高位无效"}
  - {name: code_out_cnt,  dir: output, width: 2, desc: "[决策✓] 本拍有效位数 0/1/2 (从 LSB 起取 cnt 位)"}

handshake_rules:
  - "code_in_valid 高时, 按当前模式相位对该码对的两位 (先 a0 后 a1) 逐一判定保留/丢弃"
  - "seq_start 与该序列首个 code_in_valid 同拍, 当拍把模式相位复位为 0 再施加首码对"
  - "模式相位每消耗一个输入位 +1, 到模式长度 L 回绕 (按 punc_rate 选 L)"
  - "punc_rate 在 seq_start 拍锁存, 序列内保持不变"
  - "rate=1/2: 模式 [1 1], code_out_cnt 恒为 2, code_out == code_in (透传)"
  - "序列末由 code_in_valid 拉低自然结束; 最后一次模式重复按到达位数截断 (无需补齐)"
  - "[决策✓] code_out_cnt==0 的拍 (两位全丢 或 code_in_valid 低) 下游累加器不前进 (气泡)"
  - "复位期间所有输出 (code_out / code_out_cnt) 为 0"
  - "[决策✓ A] 比特域全程无反压: 本模块不出 ready, 不收下游 ready; 与上游 FEC valid_only 一致"
```

> [决策✓ A] 输出接口 = **变长 0/1/2 bit/cycle**(`code_out[1:0]` + `code_out_cnt[1:0]`),
> 零缓冲、零反压、零延迟(组合输出)。理由:输入 2bit/cycle 并行带大量气泡(峰值占空 ~16%),
> 下游 symbol_mapper 本就要按 2/3/4 bit 攒符号,变长位流恰好原样递交其累加器;
> 整条比特域链路保持 valid_only 无反压一致。已否决:(a) 串行 1bit+弹性FIFO+反压
> ——FEC 是 valid_only 反压无处可灌,为下游不需要的"整齐"付出 FIFO/流控代价;
> (b) 字节打包——符号 2/3/4bit 与字节不对齐,打包后还要再拆,纯 overhead。详见 §7.1。

---

## 3. 配置空间 [协议 + 决策]

| 参数 | 取值 | 说明 | 是否影响本模块 |
|---|---|---|---|
| 编码率 punc_rate | 1/2, 2/3, 3/4, 15/16 | 选打孔模式 (Table 3.5) | **是 — 唯一功能维度** |
| 序列类型 | CH / PDU Header / Payload / PHY Interval | 仅决定"用哪个率"与边界 | 否 — 由上游映射成 punc_rate + seq_start |
| format (PFI) | short / fmt0 / fmt1 | 同上,经控制逻辑映射 | 否 |
| 数据率 HDT2..7.5 | — | 仅经 RI→编码率间接相关 | **否 (显式排除)** |
| 调制方式 | π/4QPSK/8PSK/16QAM | 下游 symbol_mapper 的事 | **否 (显式排除)** |

> 组合自检:本模块真正需要 cross 的维度是 **punc_rate × 模式相位 × 输入位值**;
> format/序列类型/数据率/调制**不在本模块内分支**(上游已折叠成 punc_rate 与 seq_start)。
> 配置空间小:4 种率 × 模式相位,无组合爆炸。

---

## 4. 验证意图 [验证 — 你 review 的核心]

### 4.1 判定锚点 [默认]
- **主锚点:Python 参考模型逐 bit 比对,0 容差**(纯比特逻辑,无定点)。
  - 参考模型:对 FEC 输出码流(发送序 `[a0,a1,…]`),按 punc_rate 选模式,逐位
    保留/丢弃,序列边界复位相位,输出保留位流。RTL dump 与之逐位对齐比对。
  - 复用链:可直接喂 `ref/fec_encoder/ref_model.py` 的输出作为本模型输入,做
    "FEC→puncturing"两级联测(也便于端到端不变量)。
- 辅助不变量(无需 golden):
  - `rate=1/2` 输出 == 输入(恒等)。
  - 完整周期输出长度 = N×K;一般情形 = 模式 `1` 计数。
  - 保序:输出位序与输入一致。

### 4.2 必查 corner case [默认, 待你补充]
- `rate=1/2` 透传(模式 `[1 1]`,cnt 恒 2)。
- 每种 rate 的**最短序列**:输入不足一个完整模式周期(验证截断正确)。
- 输入**恰好整数个模式周期**(无截断的对照)。
- 模式**末位为 0 被丢弃** / **首位为 1 保留**的边界对齐。
- **背靠背两序列且 rate 不同**(验证 seq_start 相位复位 + punc_rate 重锁存)。
- **15/16 长模式跨多周期**(30bit 相位回绕)。
- 输入**气泡**(`code_in_valid` 空拍)时模式相位保持不前进。
- 一个输入码对内 **a0 保留/a1 丢弃** 与 **a0 丢弃/a1 保留** 两种 packing(cnt=1 两形态)。

### 4.3 覆盖率目标 [默认]
```systemverilog
covergroup cg_punc @(posedge clk);
  cp_rate:  coverpoint punc_rate iff (code_in_valid) { bins r[] = {[0:3]}; } // 4 率全遍历
  cp_phase: coverpoint phase     iff (code_in_valid);                       // 模式相位全遍历
  cp_cnt:   coverpoint code_out_cnt;                                        // 0/1/2 都出现
  x_rate_phase: cross cp_rate, cp_phase;  // 每率下相位走遍
endgroup
```
- cp_rate / cp_cnt: 100%
- x_rate_phase: 100%(每种率的模式相位都激励过)

### 4.4 接口断言 (由第2节契约生成)
- assert: `punc_rate==1/2` 时 `code_out_cnt==2` 且 `code_out==code_in`(透传不变量)。
- assert: `seq_start` 当拍模式相位复位为 0。
- assert: `code_out_cnt` ∈ {0,1,2}(永不越界)。
- assert: 复位期 `code_out_cnt==0`。
- assert: `code_in_valid` 为低时 `code_out_cnt==0`(无输入不产出)。

### 4.5 充分性二级指标 [默认]
- mutation kill rate ≥ 90%。注入变异:改模式某位(1↔0)、模式长度取错(L±2)、
  相位不复位(漏 seq_start)、漏截断/补齐整周期、a0/a1 处理顺序调换、cnt 计数错、
  punc_rate 译码错。好的测试集应全部杀死。

---

## 5. 架构与定点约束 [协议 + 默认]

- 定点:**N/A**(纯比特逻辑,无算术)。
- 核心电路:
  - 打孔模式查表:按 punc_rate 选模式(最长 30bit);可用常量 case/ROM。
  - 模式相位计数器 `phase`(模 L,L∈{2,4,6,30});每拍消耗 2 个输入位 → +2 回绕。
  - 每拍组合:取当前相位处两位模式 → 对 `{a0,a1}` 得保留掩码 → 打包成
    `code_out`(LSB 对齐发送序更早的位)+ `code_out_cnt`(掩码内 1 的个数)。
  - 相位寄存(1 级);`seq_start` 时相位置 0。
- 流水线:[默认] **0 级**(组合输出 + 1 级相位寄存器),单周期吞吐 1 码对/cycle
  ——与 fec_encoder 风格一致,组合输出与上下游同拍对齐,避免跨序列边界竞争。
- 时序风险:组合路径 = 查表 + 2-bit mux + 小型 popcount/packing,深度浅,48MHz
  裕量充足,无风险。
- 时钟:继承 48MHz 单一时钟域,无 CDC。

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs Python 参考模型逐 bit 比对 pass (0容差)
- [ ] 不变量:rate=1/2 恒等 + 长度/保序 pass
- [ ] cp_rate / cp_cnt 100%, x_rate_phase 100%
- [ ] mutation kill rate ≥ 90%
- [ ] 回归脚本整体 exit 0

---

## 7. 留给你 review 的关键点

1. **输出接口格式(最重要)** → **[决策✓ A] 变长 0/1/2 bit/cycle**(`code_out`+`code_out_cnt`)。
   下面把否决另两案的理由写直白(供后人复核,免得再卡在同样的地方):

   - **为什么 A 不需要缓冲/反压**:数据是稀稀拉拉来的,不是拍拍都满。峰值
     (HDT7.5/16QAM)下,打孔输入码流约 15 Mb/s,FEC 每拍给 2 bit → 每秒只需 ~750 万个
     "有数据的拍";而时钟 48 MHz = 每秒 4800 万拍。750万 ÷ 4800万 ≈ **16%**——即每 100 拍
     里只有约 16 拍真有数据,其余 84 拍是空拍(气泡)。数据这么慢,下游每拍都来得及收走,
     永远不会堆积,所以**不用 FIFO 排队、也不用"下游喊停上游等"的反压**;当拍用组合逻辑
     算完就当拍输出(**零延迟**)。

   - **为什么否决 (b) 字节打包**:打包 = 攒够 8 bit(1 字节)再一次输出。但下游要的不是
     字节,而是**符号**:QPSK=2bit、8PSK=3bit、16QAM=4bit 一组。问题在 **8 不能被 3 整除**
     (8PSK):一个字节装不下整数个 3bit 符号(8=3+3+2,最后 2bit 是半个符号,要跨到下个
     字节才能拼完)。于是 puncturing 先把零散 bit **打包**成字节,symbol_mapper 收到后**还得
     把字节拆开重新按 3bit 切**——打包再拆包,绕一圈回原点,中间两道功夫纯属白做。
     方案 A 直接把零散 0/1/2 bit 递给下游累加器,**根本不经过"字节"这个中间形态**。

   - **为什么否决 (a) 串行 1bit+FIFO+反压**:它唯一的好处是给下游一条整齐的 1bit 流,
     但代价是引入 FIFO + 反压;而上游 FEC 是 valid_only **不接受反压**,反压无处可灌,
     只能靠 FIFO"永不溢出"兜底。为一个下游根本不需要的"整齐"付出这套复杂度,不划算。

   关联 00_toplevel.md 的 **D3**:选 A 等于给比特域定调——**全程无 FIFO、无反压**。
2. **模式相位复位的边界来源** → **[决策✓]**:`seq_start` 由统一控制状态机
   (00_toplevel.md D1/D4)在每个序列(及 fmt1 每 PHY Interval 各自独立)的首个码对
   同拍发出,与 FEC 序列边界/termination 复位严格对齐。本模块只消费 `seq_start`。
3. **rate 选择职责划分** → **[决策✓]**:控制状态机按"序列类型 + RI"映射出 `punc_rate`
   (CH / fmt1 PDU Header 强制 1/2),本模块**只施加模式、不判断序列类型**。职责清晰。
4. **模式作用的位序** → **[决策✓]**:按发送序 `[a0, a1]` 逐位施加(与 FEC `a0` 先发一致),
   非以码对为单位整丢整留。
5. **15/16 的 30bit 模式** [协议 ✓ 已人核对]:30bit 模式(16 个 `1`)及三种短模式已对照
   Table 3.5 逐位核对无误 (2026-06-25)。
