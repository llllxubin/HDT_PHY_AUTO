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
