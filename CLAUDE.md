# CLAUDE.md — fec_encoder

开工前必读: 本文件 + `../W1_HDT_TX/SKILL.md` + `PROGRESS.md`(恢复进度)。

## 铁律 (压缩后也须保持)

1. 只实现 status=frozen 的 spec (`../W1_HDT_TX/modules/fec_encoder.md`)。非 frozen 停下问人。
2. 完成 = `make test` 退出码 0。**不可自行宣布完成**,以 exit code 为准。
3. 判定基准独立: `ref/ref_model.py`、`scripts/compare.py`、spec 三者**禁止改**。
   测试不过就改 RTL, 绝不改判定基准来迁就 bug。
4. FEC 抽头映射已锁定 (spec §5 + ref_model.py 注释), 严格一致, 不"优化"。
5. 每改 RTL 前先 `git commit` 存档。连续 3 轮无进展则停, 写明卡点问人, 不无限重试。

## 工作流

```
读 spec(frozen)+PROGRESS.md → 改 rtl/fec_encoder.sv → make test
  PASS → 更新 PROGRESS.md, 报告, 停
  FAIL → 读报错 → 改 RTL → 重试 (每轮先 commit)
```

## 状态外化 (抗会话压缩)

每轮结束更新 `PROGRESS.md`: 当前状态/已试方案/卡点/下一步。
压缩后先读 PROGRESS.md 恢复, 不靠记忆。

## RTL 风格

- 中文注释, 复杂逻辑说明设计意图。
- 时序块非阻塞赋值一律加 #1 (含复位与正常分支): `q <= #1 d;`
- 异步复位同步释放, rst_n 低有效; 零 latch/组合环。

## 详情索引 (需要时再读, 不必常驻)

- 接口/位宽/握手: spec 第2节
- 验证充分性目标(覆盖率/mutation): spec 第4节
- 回归各步骤: Makefile
- 权限边界: .claude/settings.json (工具层强制, 非靠自觉)

## 协议原文使用边界

- HDT 协议原文在 `spec/HDT_PHY_core.pdf`。
- 实现**已 frozen** 的模块时: 以 `W1/modules/<module>.md` 为唯一权威输入,
  **不查协议原文** —— frozen spec 已是协议要点的提炼, 查原文反而易被无关细节带偏。
- **仅在**为新模块做 W1a(协议消化、起草规格)时, 才读 `spec/` 原文相关章节。
- 原文受版权保护: 不外传、不进公开仓库、docs 中引用只注章节号不大段复制。

## 文档归置 (写文档时)

- 给人读的文档放 `docs/`(不是 `W1/`, W1 是规格契约非文档)。
- 设计说明 → `docs/design/<module>_design.md`
- 验证报告 → `docs/verification/<module>_vreport.md`
- 集成文档 → `docs/integration/`
- 规范详见 `docs/README.md`。
- 时机: 设计文档在 RTL 稳定后写, 验证报告在回归通过、覆盖率达标后写。
