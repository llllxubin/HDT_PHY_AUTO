# symbol_mapper 迭代日志 (journal)

> append-only 流水账, 记录 design↔verify 每一轮来回, 供人工审阅。既有条目永不回改/删除。
> 分工: PROGRESS.md=状态快照(可覆盖) / symbol_mapper_vreport.md=成品报告 / 本文件=过程流水账。

- 模块: `symbol_mapper`
- 规格: `W1/modules/symbol_mapper.md` (frozen v0.1)
- 接口契约: `docs/integration/HANDOFF.md`(上游 puncturing 边界)+ spec §2(本模块端口)
- 起始: 2026-06-26

---

## [step 1] design v1 — 2026-06-26 (未提交)
- **动作**: rtl-design 子agent 按 frozen spec + HANDOFF 产出 `rtl/symbol_mapper.sv`
  (三段 comb: SB选择 / bit累加+产出 / 星座ROM 32入口 + 1级输出寄存)。
- **结果**: verible lint **exit 0**(编排方独立复跑确认, 非仅信子agent)。回归未跑(verify 侧待建)。
- **编排方独立审计**: 逐表对回 spec §1 量化码(362/511/−512/162/486)与 Table 7.4/7.5/7.6
  全 32 入口 + MSB-first 位序 → 均符合。未见抽头错位。
- **待 verify 把关的接口假设**(设计侧"实现选择"声明, 非 bug, 需 ref_model/激励统一):
  1. **seq_start 当拍清空 bit 累加器**(spec 仅明写 k 复位; 设计据 §1 "n 复位" 推得)。
  2. **单拍单产出**: 16QAM/8PSK 若某拍既完成整符号又残留部分 bit 且同拍 sym_flush →
     flush 覆盖正常符号丢一符号。设计假设 FSM 不如此发 flush(接口契约假设)。
- **处置**: 转 verify 侧建环境; 上述两假设要么经 ref_model 一致体现、要么暴露为接口问题走 HANDOFF。
- **产物·commit**: `rtl/symbol_mapper.sv`(v1, 未提交, 待 verify 跑通后连同验证物一起入库)。

## [step 2] verify 验证环境 + 回归一次通过 — 2026-06-26
- **动作**: rtl-verify 子agent 写 `ref/symbol_mapper/ref_model.py`(独立按 spec §1 推导量化金标)、
  `tb/tb_symbol_mapper.sv` + `tb/symbol_mapper_sva.sv`(bind),注册 gen_stim/compare,
  加 mutate.py 的 symbol_mapper 变异组(9 条)。
- **结果**: **PASS — make test 与 make verify MODULE=symbol_mapper 均 exit 0**(编排方独立复跑确认)。
  各 gate: lint 0warn / VCS compile 端口一次对上 / **compare 65序列252符号 0容差** /
  coverage 100%(cp_mod/x_qpsk/cp_8psk/cp_16qam 共32入口 + cp_flush) / sva 0errors /
  selfcheck PASS / **mutation 9/9=100%**。
- **发现 bug**: 无。RTL v1 一次通过(与 puncturing 不同, 三表+量化码+位序在设计侧即正确)。
- **两个接口假设的判定**(step1 提出): **均判为「一致」, 非 finding**。
  1. seq_start 当拍清 acc + k=0: golden 按 spec §1/§2 建模, 激励含中途 seq_start 携残留 1bit
     的 corner(gen_stim SEQ「3b」), DUT 与 golden 逐符号 0 容差 → 一致。
  2. flush 与整符号同拍: golden 按 spec §2 建模, 激励把 flush 落在 cnt=0 单独拍(每拍至多 1 符号,
     合 valid_only 单脉冲); flush 各补0位数(QPSK pad1/8PSK pad1,2/16QAM pad1,2,3)及"flush 时
     acc 恰空→不产符号"均覆盖, 全 0 容差 → 一致。
- **验证侧两处工程细节**(留给后续模块复用): 覆盖率 covergroup 触发须用 `@(cov_strobe)` 双沿
  (单 posedge 只采半数符号致 cp_16qam 卡 15/16); 符号捕获用独立 `@(posedge clk) #1` 监视器,
  内联采样叠流水延迟会整段漏采。
- **处置**: 无需处置, 模块收口。
- **产物·commit**: 见本轮 commit。
