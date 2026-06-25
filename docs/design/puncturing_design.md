# puncturing 微架构设计说明

- 模块: `puncturing` (链路第③级: fec_encoder → **puncturing** → symbol_mapper)
- 规格: `W1/modules/puncturing.md` (frozen, spec_version 0.1) — 唯一权威输入
- 接口契约: `docs/integration/HANDOFF.md` v0.1
- 协议: HDT Core Spec Vol6 PartB §3.4.4 (Puncturing), Table 3.5
- RTL: `rtl/puncturing.sv`

> 本文解释"为什么这么设计", 给人读; 规格契约见 `W1/`。

## 1. 模块功能概述

对 FEC 编码器输出的 1/2 码流做**打孔**: 按编码率对应的打孔模式 (Table 3.5) 逐位删/留,
把有效编码率提到 2/3、3/4、15/16; 编码率 1/2 时模式为 `[1 1]`, 等价不打孔 (透传)。

- FEC 每拍输出 2bit 码对 `{a1,a0}`, `a0` 先发。打孔模式作用于**发送顺序码流**
  `…, a0, a1, a0, a1, …`, `1`=保留 / `0`=丢弃。
- 模式从每个编码序列起点 (`seq_start`) 开始循环, 重复到序列结束; 末次重复按到达位数截断。
- 本模块只忠实施加 `punc_rate` 选定的模式, 不做码率决策 (上游控制状态机决定)。

## 2. 数据通路框图

```
                punc_rate(2) ──┐ (seq_start 拍锁存)
                               ▼
  code_in[1:0] ──► [模式查表 pat_vec/pat_len] ──► 相位处两位掩码 keep_a0/keep_a1
  (a0=bit0)        (按 eff_rate 选 30bit 模式)           │
  code_in_valid ───────────────────────────────────────┼──► [变长打包] ──► code_out[1:0]
                                                         │                   code_out_cnt[1:0]
  相位寄存器 phase(5b) ──► eff_phase ──► (>>eff_phase 取最低位)
        ▲                                  └──► (>>eff_phase+1 取最低位)
        └── next_phase = (eff_phase+2) 模 L 回绕 (仅 valid 拍前进; 气泡拍保持)
```

- **唯一时序状态**: `phase` (模式相位, 5bit) + `rate_reg` (序列内锁存的码率)。
- **0 级流水**: `code_out`/`code_out_cnt` 当拍组合产出 (HANDOFF §1.4), 零延迟零缓冲零反压。

## 3. 打孔模式存储与相位索引

### 3.1 模式常量 (Table 3.5)
四个模式存为 30-bit `localparam` (最长 15/16 为 30 位, 统一承载), `bit[i]` = 模式发送序第 i 位。

| 码率 punc_rate | 模式 (发送序) | L | K |
|---|---|---|---|
| 1/2 `00` | `[1 1]` (常量用全 1 向量, 任意相位两位都留) | 2 | 2 |
| 2/3 `01` | `[1 1 0 1]` | 4 | 3 |
| 3/4 `10` | `[1 1 0 1 0 1]` | 6 | 4 |
| 15/16 `11` | `[1 1 0 1 1 0 1 0 1 0 0 1 0 1 0 1 1 0 1 0 0 1 0 1 0 1 1 0 0 1]` | 30 | 16 |

### 3.2 相位推进与索引
- 每个 valid 拍消耗 2 个输入位 → `phase += 2` 模 L 回绕。L ∈ {2,4,6,30} 全偶, phase 从 0 起、步长 2,
  故 phase 恒为偶且 ≤ L−2, `phase` 与 `phase+1` 始终是合法模式索引 (< L)。
- `keep_a0 = pat[phase]`, `keep_a1 = pat[phase+1]` (phase 对应 a0、phase+1 对应 a1)。
- **实现细节**: 取相位位用**变量右移取最低位** `(cur_pat >> eff_phase) & 1'b1`, 而非变量下标位选。
  原因: 工程仿真器 VCS 支持两者, 但变量下标位选在某些工具 (iverilog) 会被错误处理;
  右移写法等价且工具友好, 不引入 lint 告警。

### 3.3 变长输出打包 (HANDOFF §1.2)
按发送序先 a0 后 a1 判定, 保留位从 LSB 起打包:

| keep_a0, keep_a1 | code_out | code_out_cnt |
|---|---|---|
| 1,1 | `{a1,a0}` | 2 |
| 1,0 | `{1'b0, a0}` | 1 |
| 0,1 | `{1'b0, a1}` (唯一保留位压到 LSB) | 1 |
| 0,0 | `0` (气泡) | 0 |

下游从 LSB 起取 cnt 位, 故"只留 a1"时 a1 必须放 LSB。

## 4. 时序行为

- **seq_start**: 与序列首个 `code_in_valid` 同拍。当拍用输入 `punc_rate` + 相位 0 施加首码对
  (组合路径走 `eff_rate`/`eff_phase`), 同拍把 `punc_rate` 锁存进 `rate_reg`, 相位寄存器按
  "从相位 0 推进"更新到下一拍值。
- **普通 valid 拍**: 用 `rate_reg` 与当前 `phase`, 相位 +2 回绕。
- **气泡拍** (`code_in_valid` 低): 相位与码率**保持不前进** (HANDOFF §1.2), 输出 cnt=0。
- **复位期**: `code_out`/`code_out_cnt` 组合钳 0 (HANDOFF §1.3), 不依赖上游驱动。

## 5. 流水线级数选择 (0 级)

HANDOFF §1.4 要求组合输出。变长 0/1/2 输出与下游 symbol_mapper 的逐拍取位天然对齐, 加流水反而引入
相位/输出错拍。组合路径仅"查表 + 2-bit mux + 小型打包", 48MHz 下时序裕量充足。

## 6. 时序风险评估

- 无除法/取模运算器 (回绕用比较 `adv_phase >= eff_len ? 0 : adv_phase`)。
- 组合路径短 (查表 + 移位取位 + 打包), 无 latch、无组合环。
- 时序块非阻塞赋值一律加 `#1`; 异步复位同步释放, rst_n 低有效。

## 7. 与 W1 spec 的对应关系

实现严格遵循 frozen spec, 无偏离。一处实现选择 spec 未显式约束: "只留 a1"时未用高位置 0
(`{1'b0,a1}`), HANDOFF §1.1 注明 cnt<2 时高位无效, 故安全且利于波形可读。

### 7.1 修复记录 — 15/16 抽头 bit14/15 颠倒 (2026-06)
初版 RTL 的 `Pat15of16` 常量把 bit14/bit15 写反 (该 nibble `0110` 应为 `1010`), 导致 15/16 模式
phase14 处把"留 a1/丢 a0"错成"留 a0/丢 a1"。回归在 (rate=15/16, phase=14) 暴露 14 处不匹配。
对回 Table 3.5 (position14=0, position15=1) 逐位核实后修正常量。教训: 常量必须逐 position 对回
权威 spec, 不对回自己的中间推导 (详见验证报告 §7 与项目 memory)。
