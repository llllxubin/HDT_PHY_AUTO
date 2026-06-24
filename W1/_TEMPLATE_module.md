# W1 模块规格契约 — <module_name>

> 复制本模板起草新模块的 W1。填写时遵守标记约定,删掉本行及所有 (说明) 注释。
> 字段标记约定:
>   [协议]   = 直接来自 spec 的事实 (W1a 整理, 人 review)
>   [决策✓]  = 已由人拍板的工程决策 (W1b)
>   [默认]   = Claude 填的合理默认值, 待人 review (review 后改成 [决策✓])
>   [验证]   = 验证意图
> 流程铁律: status 只有 frozen 才允许进入 W2 (RTL 生成)。

---

## 0. 元信息
- module_name: `<module_name>`
- spec_version: 0.1 (draft)
- protocol_ref: [协议] <spec 卷/章/图表号>
- 在链路中的位置: <上游模块> → **[<本模块>]** → <下游模块>
- status: draft   # draft / reviewed / frozen
- 全局约定继承: 见 00_toplevel.md (如 48MHz 单一时钟域等)

---

## 1. 功能描述 [协议]
> 用自己的话讲清: 输入 → 处理 → 输出。附关键协议事实(多项式/规则/表格)。
> 末尾列出"核心不变量"(验证可直接用的、必然成立的性质)。

<功能一段话>

不变量:
- <不变量1, 如 自反/守恒/往返/长度关系>
- <不变量2>

---

## 2. 接口契约 [决策 + 默认]
> 端口/位宽/方向/握手。handshake_rules 后续会转成 SVA 自动检查。

```yaml
interface: <name>_in
clock: clk
reset: rst_n              # 异步复位同步释放, 低有效
protocol: <valid_only | valid_ready_handshake>
signals:
  - {name: <sig>, dir: input,  width: <n>, desc: "<说明>"}
  # ...
handshake_rules:
  - "<规则1: 何时采样/何时有效>"
  - "<规则2: valid 稳定性等>"
  - "复位期间所有 valid/输出为 0"

interface: <name>_out
protocol: <...>
signals:
  - {name: <sig>, dir: output, width: <n>, desc: "<说明>"}
```

> [默认待确认] <列出本章里需要人拍板的接口选择, 如位宽/串并/反压>

---

## 3. 配置空间 [协议 + 决策]
> 列出所有可变参数及范围。**务必显式标注哪些维度与本模块无关(排除)**,
> 防止 agent 过度生成无意义组合。这章同时是验证 covergroup 的输入。

| 参数 | 取值范围 | 说明 | 是否影响本模块 |
|---|---|---|---|
| <param> | <range> | <desc> | 是 / **否(显式排除)** |

> 组合爆炸自检: 本模块真正需要 cross 的维度是 <...>; 不需要的是 <...>。

---

## 4. 验证意图 [验证 — 人 review 的核心]

### 4.1 判定锚点 (按模块类型选, 见 SKILL.md 决策表)
- 主锚点: <Golden参考模型 / formal property / 往返不变量 / pairwise> ...
- 辅锚点: <...>
- 容差: <0容差(纯逻辑) / 定点容差±N / EVM上限>

### 4.2 必查 corner case
- <最短输入 / 边界值 / 背靠背 / 反压 / 极值激励 ...>

### 4.3 覆盖率目标 (进回归脚本做硬门槛)
```systemverilog
covergroup cg_<module> @(posedge clk);
  // coverpoint / cross ...
endgroup
```
- functional coverage 目标: <%>
- cross 目标: <%>

### 4.4 接口断言 (由第2节契约生成)
- assert: <...>

### 4.5 充分性二级指标
- mutation kill rate 目标: ≥ <%>。注入变异: <列出针对本模块的变异类型>

---

## 5. 架构与定点约束 [协议 + 决策]
- 定点: <N/A(纯逻辑) / IQ位宽/系数位宽/量化预算>
- 核心电路: <结构描述>
- 流水线: <级数 + 理由>
- 时序风险: <长组合路径 / 除法器 / 大扇出 等, 及对策>
- 时钟: 继承 48MHz 单一时钟域 (除非本模块另有说明)

---

## 6. 完成定义 [自动判定]
- [ ] 编译通过 (exit 0)
- [ ] Verible lint 0 warning
- [ ] 所有接口 SVA pass
- [ ] vs <判定锚点> pass
- [ ] 不变量 pass (formal/仿真)
- [ ] 覆盖率达标
- [ ] mutation kill rate ≥ <%>
- [ ] 回归脚本整体 exit 0

---

## 7. 留给人 review 的关键点
> 把最易错、最需人盯的点单独拎出, 引导注意力。
1. **<最易错点, 如抽头映射/位宽增长/边界对齐>**
2. <其他待确认默认值>
