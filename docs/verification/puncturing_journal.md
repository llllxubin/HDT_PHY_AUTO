# puncturing 迭代日志 (journal)

> append-only 流水账, 记录 design↔verify 每一轮来回, 供人工审阅。既有条目永不回改/删除。
> 分工: PROGRESS.md=状态快照(可覆盖) / puncturing_vreport.md=成品报告 / 本文件=过程流水账。
> 本文件为 puncturing 完成后**回溯补记**(模板上线前已收口), 故 step 由 git 历史重建。

- 模块: `puncturing`
- 规格: `W1/modules/puncturing.md` (frozen v0.1)
- 接口契约: `docs/integration/HANDOFF.md` v0.1
- 起始: 2026-06-25

---

## [step 1] design v1 + verify 验证环境 — 2026-06-25 (commit `9c6fca3`)
- **动作**: design 侧出 `rtl/puncturing.sv` 首版(组合输出, 1 级相位寄存器), 并修 7 处
  verible lint(localparam 命名 SNAKE→UpperCamel); verify 侧写 `tb/tb_puncturing.sv` +
  `tb/puncturing_sva.sv` + `ref/puncturing/ref_model.py`, 在 `gen_stim.py`/`compare.py` 注册。
- **结果**: **FAIL — make test exit 6 (compare)**。69 序列中 14 处不匹配, **全部**集中在
  (rate=15/16, phase=14)。
- **发现 bug**: DUT 抽头错位。最小复现: 序列13 cycle7, 相位=14, 输入 (a0,a1)=(1,0) 时
  golden=(cnt=1,code_out=0) 留 a1, RTL=(cnt=1,code_out=1) 误留 a0。
  定位: `Pat15of16` 常量 bit14/bit15 颠倒。
  **判定依据**: 不盲信刚写的 ref_model, 把失败点对回**冻结规格 Table 3.5**
  (position14=0 丢 a0 / position15=1 留 a1) 逐位核实 → 确认 RTL 错、golden 对(铁律3)。
- **处置**: 反馈 design 侧:`Pat15of16` nibble bit15:12 `0110`→`1010`(仅换 bit14/bit15),
  并订正同源镜像错的误导性注释。
- **产物·commit**: `rtl/puncturing.sv`(v1)、`tb/*`、`ref/puncturing/ref_model.py`、
  `scripts/gen_stim.py`/`compare.py` 注册 → `9c6fca3`。

## [step 2] design fix 抽头 — 2026-06-26 (commit `e388d70`)
- **动作**: design 侧改 `Pat15of16` bit14/15(`0110`→`1010`), 订正注释。未动其它逻辑。
- **结果**: **PASS — make test exit 0**。compare 69 序列 / 1204 cycle 全匹配 0 容差;
  coverage 100%(cp_rate/cp_cnt/cp_phase/x_rate_phase); sva 0 errors; selfcheck PASS。
- **发现 bug**: 无(回归全绿)。
- **处置**: 无需处置。
- **产物·commit**: `rtl/puncturing.sv` 7 insert/5 delete → `e388d70`。
- **根因教训**: step1 设计侧初版"自检通过", 是拿常量比对了**自己镜像错的中间推导**,
  两边同源错才自洽。已写入项目 memory(校验常量必须逐 position 对回权威 spec)。

## [step 3] mutation 杀伤率 — 2026-06-26 (commit `d86af5e`)
- **动作**: 跑 `make verify MODULE=puncturing`。`scripts/mutate.py` 重构为按模块字典
  `MUTATIONS_BY_MODULE`(fec_encoder 原 6 条字节级不动), 为 puncturing 新增 6 条变异:
  pat15_tap / adv_plus1 / keep_misidx / wrap_off1 / no_seqreset / break_pass。
- **结果**: **PASS — make verify exit 0**, mutation kill rate **6/6 = 100%**(≥90% 达标),
  无存活变异 → 无验证盲区。
- **发现 bug**: 无。
- **处置**: 无需处置。验证环境对每类典型错误均有杀伤。
- **产物·commit**: `scripts/mutate.py` → `d86af5e`。

---

## 收口判定 (spec §4 完成定义)
- [x] make test exit 0  [x] make verify exit 0  [x] lint 0warn  [x] vs golden 0 容差
- [x] 功能覆盖率 100%  [x] 接口 SVA pass  [x] mutation 6/6=100%
- 详细成品结论见 `docs/verification/puncturing_vreport.md`。
