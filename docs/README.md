# docs/ — 项目文档归置规范

本目录存放**给人读的文档**(设计说明、验证报告、集成记录)。
与 `W1/`(给实现用的规格契约)严格区分:

| 目录 | 性质 | 读者 | 写法 |
|---|---|---|---|
| `W1/` | 规格**契约** | RTL生成agent严格遵守 | 紧凑、字段化、可机器解析 |
| `docs/` | **文档** | 人(你/评审/未来的你) | 叙述性、解释"为什么" |

不要把两者混淆: W1 是"必须照做的规格", docs 是"解释和记录"。

## 目录用途

```
docs/
├── design/         微架构设计说明: 为什么这么设计、结构选择理由、PPA权衡、时序考量
├── verification/   验证文档: 验证计划、覆盖率报告、回归结果、EVM分析(DSP模块)
├── integration/    集成文档: 模块互联、接口对接记录、跨模块时序、与MAC/驱动层对接
└── meeting_notes/  决策记录、评审纪要、关键问题讨论(可选)
```

## 命名规范

- 按 `<模块名>_<文档类型>.md` 命名, 模块名与 W1/rtl 中一致。
- design:        `fec_encoder_design.md`
- verification:  `fec_encoder_vplan.md`(计划) / `fec_encoder_vreport.md`(报告) / `fec_encoder_journal.md`(迭代日志)
- integration:   `tx_chain_integration.md`(链路级) / `<模块>_intf.md`(单模块接口)
- 链路级/跨模块文档用 `tx_chain_` 或 `toplevel_` 前缀。

## 各类文档应包含什么

### design/<module>_design.md
- 微架构框图(数据通路、流水级)
- 关键设计决策及理由(为什么这个位宽/这个结构/这个流水深度)
- PPA 权衡说明
- 已知时序风险与对策
- 与 W1 spec 的对应关系(实现是否偏离 spec, 偏离的理由)

### verification/<module>_vreport.md
- 回归结果(make test 的 PASS 记录、日期)
- 覆盖率数据(functional/cross/code coverage 实测值 vs 目标)
- mutation kill rate 结果
- 未覆盖项说明(若有 coverage hole, 为何可接受)
- DSP 模块: EVM 实测 vs spec 上限

### verification/<module>_journal.md  (迭代日志, append-only)
- design↔verify **每一轮来回**的原始流水账: 出 RTL→验证→发现 bug→修→再验证…
- **append-only**: 既有 step 永不回改/删除, 只在末尾追加。供人工审阅过程, 区别于
  vreport(成品结论)与 PROGRESS.md(可覆盖的状态快照)。
- 模板见 `verification/_journal_template.md`; 每轮收口后由编排方(主 agent)追加一条 step。
- 一条 step 必含: 动作 / 结果(PASS·FAIL+卡点 gate) / 发现的 bug(现象+定位+判定依据) /
  处置(反馈谁改什么) / 产物·commit。

### integration/
- 模块间接口对接的实际信号连接
- 跨模块时序图
- 集成测试结果

## 与 spec 原文的关系

- 协议原文在 `spec/HDT_PHY_core.pdf`(版权文档, 不外传、不进公开仓库)。
- docs/ 里引用协议时, 注明章节号即可, **不要大段复制原文**。

## 何时写文档

- **design**: 模块 RTL 实现稳定后写(实现细节清楚时质量最高)。
- **verification report**: 回归通过、覆盖率达标后写(有真实数据)。
- **verification journal**: 贯穿全程, **每轮 design/verify 收口后即追加**(不等模块完成)。
- 不要在实现前写设计文档(那是 W1 的事, 不是 docs)。

## 让 agent 写文档时

明确指定路径和类型, 例:
"把 fec_encoder 的微架构设计写到 docs/design/fec_encoder_design.md,
包含数据通路框图、抽头映射决策理由、流水线选择、时序风险。"
