# symbol_mapper 微架构设计说明

- 模块: `symbol_mapper`(链路第④级,符号域入口: puncturing → **symbol_mapper** → symbol_assembler)
- 规格: `W1/modules/symbol_mapper.md`(frozen, spec_version 0.1)— 唯一权威输入
- 接口契约: `docs/integration/HANDOFF.md`(上游 puncturing 边界)+ spec §2(本模块端口)
- 协议: HDT Core Spec Vol6 PartA §7.3(Modulation), Table 7.4(π/4 QPSK)/7.5(8PSK)/7.6(16QAM)
- RTL: `rtl/symbol_mapper.sv`

> 本文解释"为什么这么设计", 给人读; 规格契约见 `W1/`。

## 1. 模块功能概述

把 puncturing 输出的变长比特流(每拍 0/1/2 bit)按当前调制 `mod_sel` 每 log₂(M) bit 攒成一个符号
bit 组, 查星座 ROM 输出复符号 (I/Q 各 10bit 定点 Q0.9), 送 symbol_assembler。
M=4(π/4 QPSK)/8(8PSK)/16(16QAM)。本模块只做"攒 bit + 查表", 不做调制决策(上游 FSM 给 mod_sel)。

## 2. 数据通路框图

```
  mod_sel(2) ──► [SB 选择] ── SB=2/3/4
  code_in[1:0]  ─┐
  code_in_cnt ───┼─► [bit 累加器(移位) + SB 计数] ──► emit_idx(符号 bit 组) ──┐
  seq_start ─────┤        (cnt=0 气泡不前进; seq_start 当拍清空)              ▼
  sym_flush ─────┘                                              [星座 ROM 32入口] ──► (rom_i,rom_q)
  k_parity 触发器(仅 QPSK, seq_start 复位) ──► 选 偶/奇 相位表 ──┘                     │
                                                                          [1级输出寄存] ──► sym_i/sym_q/sym_valid
```

- **唯一时序状态**: `acc_q`(bit 移位累加器 4bit)+ `cnt_q`(累加器内有效 bit 数)+ `kpar_q`(QPSK 的 k 奇偶)。
- **流水线 1 级**: 查表组合 + 1 级输出寄存(spec §5)。`sym_valid` 与 `sym_i/sym_q` 同拍寄出对齐。

## 3. 比特累加与符号 bit 组装(命门: 位序)

- **位序**(spec §2 决策✓): 同一符号内**先收到的 bit 占 MSB**(对齐 Table 行序 (n0,n1,…) n0=MSB)。
- 实现: 移位累加器 `t_acc = {t_acc[2:0], bit}`, `code_in[0]`(发送序更早的位)先移入; 每入 1 bit 整体
  左移, 满 SB 位时 n0(最先收到)自然落 MSB, 低 SB 位即 Table 行序索引 `emit_idx`。
- 单拍最多 2 个输入 bit 且 SB≥2, 故**单拍至多产出 1 个符号**(与 valid_only 单脉冲接口一致)。
- 气泡 `code_in_cnt==0`: 累加器不前进、不产出。

## 4. 星座 ROM(32 入口, ÷√10 离线吸收)

索引 = {mod_sel,(仅 QPSK)base_kpar, 符号 bit 组 emit_idx} → (rom_i, rom_q)。共 8(QPSK 偶/奇各4)
+ 8(8PSK)+ 16(16QAM)= 32 入口。三表数值逐行对回 spec Table 7.4/7.5/7.6。

### 4.1 量化码常量(spec §1, Q0.9 = code/512)
| 取值 | 码 | 说明 |
|---|---|---|
| 0 | 0 | — |
| ±√2/2 = ±0.70710678 | ±362 | PSK 45°点 |
| +1.0 | **+511(饱和不回绕)** | Q0.9 无法精确表示 +1.0 |
| −1.0 | −512 | 精确 |
| 16QAM ±1/√10 = ±0.31623 | ±162 | ÷√10 已吸收进常量 |
| 16QAM ±3/√10 = ±0.94868 | ±486 | 同上 |

- **+1.0 饱和**(spec §1 决策✓ KD-B): PSK 的 +轴点(e^0=+1, e^jπ/2=+j)的 +1.0 饱和到 +511,
  非对称 ±1LSB, EVM 可忽略; **永不出现 +512**。
- **16QAM ÷√10**(spec §7.3.3): 归一化在表常量里离线吸收, RTL 不做在线除法/平方根。

### 4.2 π/4 QPSK 偶/奇相位表(spec Table 7.4)
偶 k 与奇 k 用**不同**相位表(奇符号相当于偶基础 +π/4)。`base_kpar` 选表:
- seq_start 当拍 `base_kpar=0` → 其后首个产出符号用**偶**表(k=0)。
- `kpar_next = base_kpar ^ emit_valid`: 每产出 1 符号翻转。其余调制不读取此位。

## 5. flush 末符号补 0(spec §2)

`sym_flush` 且累加器非空时: `emit_idx = t_acc << (SB − t_cnt)` —— 把已收 bit 的 n0 移到 MSB、
低位(较晚的 n)补 0, 再查表产出该末符号, 随后累加器/计数清空。
若 flush 拍累加器恰空(t_cnt==0)则不产符号(`t_cnt != 0` 守门)。

## 6. 时序行为

- **seq_start**: 当拍清空 bit 累加器与 k 奇偶(spec §1 "每序列后 n 复位 0" + k 复位)。
- **复位期**: `sym_i/sym_q/sym_valid` 全 0。
- **非产出拍**: 仅 `emit_valid` 时更新 `sym_i/sym_q`(valid_only 下游只在 sym_valid 高时采样;
  保持上一有效值利于波形观察, 不影响功能)。

## 7. 时序风险评估

- 无除法/平方根(16QAM 归一化离线吸收进表常量)。
- 组合路径: SB 选择 + 小移位累加器 + 32 入口 ROM 查表, 深度浅; 峰值 2Msym/s 远低于 48MHz, 余量充足。
- 时序块非阻塞赋值一律 `#1`; 异步复位同步释放, rst_n 低有效; 无 latch、无组合环。

## 8. 与 W1 spec 的对应关系

实现严格遵循 frozen spec, 无偏离。两处 spec 未显式约束的实现选择, 已由验证侧独立按 spec §1/§2
建模 golden 确认**与 spec 一致**(见 `symbol_mapper_journal.md` step2):
1. **seq_start 当拍清空 bit 累加器**(spec 仅明写 k 复位; 据 §1 "n 复位" 推得)。
2. **flush 与整符号不同拍**(单拍至多 1 符号, 合 valid_only 单脉冲); RTL 注释标注此为 FSM 接口契约假设。
- mod_sel==2'b11 为保留值, ROM 输出 0 / SB 取 QPSK, 纯为避免 latch(spec 只定义 00/01/10)。

## 9. 验证结论(摘要)

`make test` 与 `make verify MODULE=symbol_mapper` 均 exit 0: compare 65序列/252符号 0容差,
32 查表入口 + cp_flush 覆盖率 100%, SVA 0 errors, mutation 9/9=100%。详见
`docs/verification/symbol_mapper_vreport.md`。**RTL v1 一次通过, 无 DUT bug**。
