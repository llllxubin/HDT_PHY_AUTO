# <module> 迭代日志 (journal) — 模板

> 复制本文件为 `docs/verification/<module>_journal.md`, 删掉本行与下面"模板说明"块后使用。

<!-- 模板说明 (用前删除)
- 性质: **append-only 流水账**, 记录 design↔verify 每一轮来回, 供人工审阅。
  既有条目**永不回改/删除**; 只在文件末尾追加新 step。
- 与其它文件的分工 (别混):
  - `PROGRESS.md`        : 当前状态快照, 供会话压缩后恢复上下文 —— **可覆盖**, 只留结论。
  - `<module>_vreport.md`: 通过后的成品验证报告 —— 一次性精修, 给结论。
  - `<module>_journal.md`: **本文件**, 过程原始流水账 —— append-only, 给过程。
- 谁写: **编排方(主 agent)** 在每轮 design 或 verify 收口后追加一条。
- 一个 step = 一轮有意义的动作 (出 RTL / 跑验证 / 修 bug / 跑 mutation)。
  发现 bug 必记 (现象+定位+判定依据); 处置要写清"反馈谁改什么"。
-->

- 模块: `<module>`
- 规格: `W1/modules/<module>.md` (frozen v<X.Y>)
- 接口契约: `docs/integration/HANDOFF.md` v<X.Y>
- 起始: <YYYY-MM-DD>

---

## [step N] <design v_k | verify | fix | mutation> — <YYYY-MM-DD> (commit `<sha>`)
- **动作**: <做了什么, 谁做的 (design/verify)>
- **结果**: <PASS exit0 / FAIL exit<code>, 卡在哪个 gate (lint/compile/compare/sva/...)>
- **发现 bug**: <无 / 现象(哪个配置、几处不匹配) + 定位(根因) + 判定依据(对回哪份权威源)>
- **处置**: <反馈谁改什么 / 无需处置>
- **产物·commit**: <涉及文件 + commit sha>
