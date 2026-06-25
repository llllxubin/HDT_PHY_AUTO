# HANDOFF.md —— Design ↔ Verify 交接物契约

> **本文件是 Design 与 Verify 两个子agent 之间唯一的合法通信通道。**
> 两个子agent 不能直接对话(子agent 只向主会话汇报),也禁止互读对方代码。
> 它们各自只读本文件来对齐接口与约定。任何接口变更,必须【先改本文件】,
> 再由对应一方据此更新代码。主会话(编排者)负责裁决本文件的变更。

---

## 0. 当前交接模块

| 字段 | 值 |
|------|----|
| 模块名 | `puncturing` |
| W1 规格 | `W1/modules/puncturing.md` spec_version 0.1 (frozen) |
| 契约版本 | v0.1 |
| 最后更新 | 2026-06-25 |

---

## 1. 接口契约(双方共同遵守的唯一真相)

> Design 按此定义端口;Verify 按此驱动/采样 DUT。
> 任一方【不得】绕过本节、通过读对方代码来推断接口。

### 1.1 端口表

| 端口名 | 方向 | 位宽 | 含义 |
|--------|------|------|------|
| `clk` | input | 1 | 48MHz 单一时钟域,上升沿触发 |
| `rst_n` | input | 1 | 异步复位、同步释放、低有效 |
| `code_in` | input | 2 | FEC code_out,`{a1,a0}`,bit0=a0 先发 |
| `code_in_valid` | input | 1 | 输入码对有效(= FEC code_out_valid) |
| `seq_start` | input | 1 | 序列首个码对标志;打孔模式相位复位到 0;与该序列首个 code_in_valid 同拍 |
| `punc_rate` | input | 2 | 编码率选择:`2'b00`=1/2, `2'b01`=2/3, `2'b10`=3/4, `2'b11`=15/16;seq_start 拍锁存,序列内保持不变 |
| `code_out` | output | 2 | 本拍输出的保留位;LSB(bit0) 对齐发送序更早的位(a0 侧);cnt<2 时高位无效 |
| `code_out_cnt` | output | 2 | 本拍有效位数,取值 0/1/2(从 LSB 起取 cnt 位) |

### 1.2 握手 / 流控协议

- **协议类型**:valid_only,无反压,无 ready 信号
- 上游(fec_encoder → puncturing):逐拍接收 FEC 输出,不反压上游
- 下游(puncturing → symbol_mapper):变长 0/1/2 bit/cycle,零缓冲零反压零延迟(组合输出)
- `code_in_valid` 低时模式相位保持不前进,`code_out_cnt` 输出 0
- `code_out_cnt==0` 的拍(两位全丢或 code_in_valid 低)下游累加器不前进(气泡)

### 1.3 复位后行为

- 复位期间:`code_out = 2'b00`,`code_out_cnt = 2'b00`
- 复位期间模式相位寄存器清零
- 复位释放后等待 `seq_start` 拍锁存 `punc_rate` 并复位相位,再开始正常工作

### 1.4 延迟契约(latency)

- **0 级流水线**:组合输出,无寄存延迟
- `code_in_valid` 有效的同拍,`code_out` / `code_out_cnt` 即有效输出
- 唯一的寄存器是模式相位寄存器(1 级),在下一拍更新相位状态
- **Design 改流水线级数 = 必须先更新本节**,Verify 据此对齐参考模型时序

### 1.5 punc_rate 编码与打孔模式对照

| punc_rate | 编码率 | 模式(发送序,a0先) | 模式长 L | 每周期保留数 K |
|-----------|--------|-------------------|----------|---------------|
| `2'b00` | 1/2 | `[1,1]` | 2 | 2 |
| `2'b01` | 2/3 | `[1,1,0,1]` | 4 | 3 |
| `2'b10` | 3/4 | `[1,1,0,1,0,1]` | 6 | 4 |
| `2'b11` | 15/16 | `[1,1,0,1,1,0,1,0,1,0,0,1,0,1,0,1,1,0,1,0,0,1,0,1,0,1,1,0,0,1]` | 30 | 16 |

> 模式按发送序逐位施加于 FEC 输出:先 a0 后 a1,即相位 0 对应 a0、相位 1 对应 a1、
> 相位 2 对应下一码对的 a0,依此类推。`1`=保留,`0`=丢弃。

---

## 2. 交接物清单(谁产出什么、放哪)

### 2.1 Design → 主会话(产出)
- [ ] `rtl/puncturing.sv` —— 可综合 RTL
- [ ] 语法/lint 干净(PostToolUse hook 自动验证)
- [ ] 在回复中声明:实现了契约 v0.1 的所有端口、关键设计决策(相位计数器位宽、模式 ROM 实现方式)

### 2.2 Verify → 主会话(产出)
- [ ] `tb/tb_puncturing.sv` —— testbench
- [ ] `tb/puncturing_sva.sv` —— 接口断言(见 §1.5 断言列表)
- [ ] `ref/puncturing/ref_model.py` —— Python 参考模型
- [ ] `gen_stim.py` 中 puncturing 的激励注册
- [ ] `compare.py` 中 puncturing 的逐 bit 比对注册
- [ ] 覆盖率点清单(追溯到 W1 §4.3)

### 2.3 主会话(编排者)持有
- [ ] 运行回归的权限(只有主会话/确定性脚本能 `make`)
- [ ] PASS/FAIL 裁定权(回归 exit 0)
- [ ] 本文件的变更裁决权

---

## 3. 接口断言清单(由 §1 契约直接生成,Verify 负责实现)

```systemverilog
// A1: rate=1/2 透传不变量
assert property (@(posedge clk) disable iff (!rst_n)
  (code_in_valid && punc_rate == 2'b00) |-> 
  (code_out_cnt == 2'b10 && code_out == code_in));

// A2: seq_start 当拍相位必须复位(复位后首拍模式从位 0 开始)
// 由 Design 内部相位寄存器保证,Verify 通过覆盖率 cp_phase 间接验证

// A3: code_out_cnt 永不越界
assert property (@(posedge clk) disable iff (!rst_n)
  code_out_cnt <= 2'b10);

// A4: 复位期输出为 0
assert property (@(posedge clk)
  !rst_n |-> (code_out == 2'b00 && code_out_cnt == 2'b00));

// A5: 无输入不产出
assert property (@(posedge clk) disable iff (!rst_n)
  !code_in_valid |-> code_out_cnt == 2'b00);
```

---

## 4. 接口变更协议

1. **谁需要改接口,谁先提变更**:在第 5 节登记 CR
2. **主会话裁决**:接受则更新第 1 节 + 升版本号
3. **双方据新契约更新代码**
4. **禁止"先改代码后补契约"**

> 契约版本号变化 = 双方都要重新对齐。版本不变 = 接口稳定,各自独立迭代内部实现。

---

## 5. 变更请求(CR)记录

| CR# | 提出方 | 内容 | 主会话裁决 | 新版本 |
|-----|--------|------|-----------|--------|
| — | — | — | — | — |

---

## 6. 已知隔离裂缝(阶段一已知风险)

- ⚠️ Verify 有 Bash,**物理上能 `cat rtl/puncturing.sv`**。rtl-verify.md 已禁止"按 RTL 内部写测试",但这是软约束。阶段一可接受(观察期);若发现 Verify 贴合 RTL 行为,阶段二加 PreToolUse hook 拦截其读 `rtl/*.sv`。
- ⚠️ 子 agent 的 `ask` 权限失效(碰到 ask 当 deny),关键文件保护对子 agent 靠 `tools` 白名单兜底。
