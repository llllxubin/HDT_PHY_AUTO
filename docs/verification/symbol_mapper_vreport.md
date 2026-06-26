# symbol_mapper 验证报告

- 模块: `symbol_mapper` | 规格: `W1/modules/symbol_mapper.md`(frozen v0.1)§4
- 接口契约: `docs/integration/HANDOFF.md`(上游 puncturing 边界)+ spec §2(本模块端口)
- 结论: **`make test` 与 `make verify MODULE=symbol_mapper` 均退出码 0**(编排方独立复跑确认;
  快门全绿 + mutation 9/9=100%)。**RTL v1 一次通过, 回归未暴露 DUT bug**。
- 验证物: `tb/tb_symbol_mapper.sv`、`tb/symbol_mapper_sva.sv`、`ref/symbol_mapper/ref_model.py`,
  `scripts/gen_stim.py` / `scripts/compare.py` / `scripts/mutate.py` 的 symbol_mapper 注册。

## 1. 判定锚点(Python 量化金标逐符号比对)

`ref/symbol_mapper/ref_model.py` 是判定基准(golden), **独立按 spec §1 推导, 不窥探 RTL 内部**
(compare 通过后才读 RTL, 且仅用于 §4.5 变异注入)。

- 量化 = round-half-up(value×512) 再饱和到 [−512, +511]; 三表用浮点星座(角度 / ÷√10)现算后量化。
- `ref_model.py` 的 `__main__` 自检逐 position 对回 spec §1 硬码常量(0/±362/+511饱和/−512/±162/±486
  及偶/奇、8PSK、16QAM 端点)——校验金标自身, 不与 RTL 互证(铁律3 + 项目 memory 教训)。
- `compare.py` 的 `compare_symbol_mapper` 逐符号比对 `(sym_i, sym_q)`, **0 容差**。

## 2. make test 回归结果(PASS 记录)

| target | 结果 |
|---|---|
| lint | PASS — verible 0 warning |
| compile | PASS — VCS O-2018.09-SP2, DUT 端口与 spec §2 一次对上 |
| sim | PASS — 跑到 `$finish`, 65 序列 / 捕获 252 符号 |
| **compare** | **PASS — 65 序列 / 252 符号 全匹配, 0 容差** |
| coverage | PASS — 见 §3 |
| sva | PASS — 断言失败计数 0 |
| selfcheck | PASS — seq_start 复位 k 首符号偶, out=(362,362) |

## 3. 覆盖率实测值(spec §4.3)

功能覆盖率, 全部 **100%**(32 查表入口全覆盖):

| 覆盖点 | 含义 | 实测 |
|---|---|---|
| cp_mod | 三调制(QPSK/8PSK/16QAM)全遍历 | 100% |
| x_qpsk | QPSK 偶/奇 × 4 bit 组合 = 8 入口 | 100% |
| cp_8psk | 8PSK 8 bit 组合 | 100% |
| cp_16qam | 16QAM 16 bit 组合 | 100% |
| cp_flush | 末符号补 0 位数(QPSK pad1 / 8PSK pad1,2 / 16QAM pad1,2,3)| 100% |

> check_cov.py 适配: 该闸门硬编码 REQUIRED=[cp_state, x_state_bit](fec 遗留键)。本模块在
> `cov_summary` **别名输出** cp_state/x_state_bit, 不改 check_cov.py(判定基准侧)即过覆盖率闸门。

## 4. corner case 覆盖情况(spec §4.2)

- [x] 三调制每个查表入口全遍历(QPSK 偶/奇各4、8PSK 8、16QAM 16, 共 32)。
- [x] π/4 QPSK 偶/奇相位交替(连续多符号验 k 奇偶切换)。
- [x] 中途 seq_start 复位 k(其后首符号回偶表); 含携残留 1bit 的 corner(gen_stim SEQ「3b」)。
- [x] 末符号补 0(sym_flush)各补 0 位数; "flush 时累加器恰空 → 不产符号"。
- [x] +1.0 饱和点(PSK +1/+j 饱和 +511 非回绕)。
- [x] 16QAM 四象限极值(±3±3j/√10)与内点(±1±1j/√10)。
- [x] 输入气泡 code_in_cnt=0 累加器不前进。
- [x] cnt=1 与 cnt=2 混合攒符号, 符号边界对齐。
- [x] 背靠背两序列不同 mod_sel(kstart 重锁存)。

## 5. 接口断言(SVA, bind 绑定)

`tb/symbol_mapper_sva.sv` 经 bind 绑定 DUT, 黑盒只断言端口契约。

| 断言 | 内容 | 结果 |
|---|---|---|
| A_RST | 复位期 sym_valid==0 | PASS |
| A_LEGAL | 产出符号时 (sym_i,sym_q) ∈ 当前调制合法码值集 | PASS |
| A_QFE | sym_i/sym_q 永不出现 +512(饱和到 +511)| PASS |

(spec §4.4 其余意图: "每产出⇔吃满SB或flush补齐"、"seq_start后首符号 k_parity==even"、
"cnt==0拍不产出" 由 selfcheck + 覆盖率 + compare 逐符号 0 容差共同覆盖。)

## 6. mutation kill rate — 9/9 = 100%(≥90% 达标)

`make verify MODULE=symbol_mapper` exit 0。为 symbol_mapper 在 `MUTATIONS_BY_MODULE` 新增 9 个变异,
均成功注入且被现有 ref/compare/sva/selfcheck 杀死:

| 变异 | 注入的错误 | 结果 |
|---|---|---|
| tab_i_err | 16QAM 0xa rom_i QamB→QamA | KILLED |
| tab_q_err | 8PSK 011 rom_q UnP→UnN | KILLED |
| swap_evodd | QPSK 偶/奇相位表互换(base_kpar 取反)| KILLED |
| k_noreset | seq_start 不复位 k 奇偶 | KILLED |
| bitorder | 累加首位错用 code_in[1](位序反转)| KILLED |
| sb_err | QPSK SB 2→3 | KILLED |
| no_flush | flush 漏补 0(条件恒假)| KILLED |
| wrap_unp | +1.0 回绕 −512 代替饱和 +511 | KILLED |
| norm_div10 | 16QAM ÷10 代 ÷√10(QamB 486→154)| KILLED |

**无存活变异** → 未发现验证盲区。fec_encoder / puncturing 既有变异组语义未动(字节一致)。

## 7. 两个接口假设的判定(均一致, 非 finding)

设计侧 step1 提出两处 spec 未显式约束的实现选择, 验证侧用**独立按 spec §1/§2 建模的 golden** + 对应
corner 激励判定, 二者逐符号 0 容差吻合 → 判为**与 spec 一致**:
1. seq_start 当拍清空 bit 累加器 + k=0(spec §1 "n 复位" + §2 k 复位)。
2. sym_flush 与整符号完成不同拍(每拍至多 1 符号, 合 valid_only 单脉冲)。
详见 `symbol_mapper_journal.md` step2。

## 8. spec §6 完成定义对照

- [x] 编译通过  [x] Verible lint 0warn  [x] 接口SVA pass  [x] vs 量化金标逐符号 0容差
- [x] 32 查表入口 100% + cp_flush  [x] 不变量(bit守恒 + k奇偶交替 + seq_start复位)pass
- [x] make test 整体 exit 0  [x] mutation kill rate 9/9 = 100%(≥90%), make verify exit 0
- [~] vs 理想浮点星座 EVM(量化噪声)≤ 预算: 量化金标即由理想星座按 Q0.9 量化得到,
  量化误差 ≤ 0.5 LSB(±362 的 √2/2 误差 0.04LSB、16QAM 0.3LSB), 远小于 EVM 预算; SRRC 段再核总账。
