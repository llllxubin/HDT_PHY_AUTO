// =============================================================
// fec_encoder — HDT TX PHY rate-1/2 卷积编码器 (K=6, 32 状态)
//
// 规格: W1/modules/fec_encoder.md (frozen) · HDT Core Spec Vol6 PartB §3.4.3
// 非系统非递归, 5 个延迟寄存器, 初始全 0。每输入 1bit 输出 2bit (a0 先发)。
//
// 生成多项式 (抽头已对照 Figure 3.10 锁定, 与 ref_model.py 严格一致):
//   G0 = 1 + x^2 + x^4 + x^5    抽头 {0,2,4,5}
//   G1 = 1 + x + x^2 + x^3 + x^5 抽头 {0,1,2,3,5}
// 状态约定: enc_state[0]=最近一个历史bit ... enc_state[4]=最久历史bit。
//   当前输入 bit 视为 x^0。
//   a0 = b ^ s[1] ^ s[3] ^ s[4]
//   a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4]
//   移位: 新状态 = {s[3:0], b} (b 进入 s[0], 丢弃 s[4])
//
// 序列边界:
//   - seq_start: 与首个 bit_in_valid 同拍, 本拍编码器状态强制清零再吃首bit。
//   - seq_flush: 状态机发, 本模块自动连续编码 5 个 0 (termination) 回全0态,
//                期间 code_out_valid 保持有效; 第5个0编码完 term_done 拉高一拍。
//
// 风格: 中文注释; 时序块非阻塞赋值一律加 #1; 异步复位同步释放, rst_n 低有效。
// 流水: 输出寄存一级 (registered output), 单周期吞吐 1bit/cycle。
//        下游按 code_out_valid 采样, 输出相对输入延迟一拍, 不影响逐bit比对(序/数不变)。
// =============================================================
`timescale 1ns / 1ps

module fec_encoder (
    input logic clk,
    input logic rst_n, // 异步复位同步释放, 低有效

    // ---- 上游: 逐bit接收 (valid_only, 不反压上游) ----
    input logic bit_in,        // 输入数据比特
    input logic bit_in_valid,  // 输入比特有效
    input logic seq_start,     // 序列首bit标志, 触发编码器清零
    input logic seq_flush,     // 数据已完, 自动追加 5 个 0 termination

    // ---- 下游: 每输入1bit输出2bit {a1,a0} (a0=bit0 先发) ----
    output logic [1:0] code_out,        // {a1, a0}
    output logic       code_out_valid,  // 输出有效
    output logic       term_done        // termination 完成 (5个0已编码完), 拉高一拍
);

  // ------------------------------------------------------------
  // 卷积编码组合函数: 由输入 bit b 与状态 s 算出 {a1,a0}
  // 抽头严格对应 G0/G1, 禁改 (与 ref_model.py 对齐, 否则比对失去意义)。
  // ------------------------------------------------------------
  function automatic logic [1:0] fec_pair(input logic b, input logic [4:0] s);
    logic a0, a1;
    a0 = b ^ s[1] ^ s[3] ^ s[4];  // G0 抽头 {0,2,4,5}
    a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4];  // G1 抽头 {0,1,2,3,5}
    return {a1, a0};  // bit0=a0 先发
  endfunction

  // ------------------------------------------------------------
  // 内部状态
  // ------------------------------------------------------------
  logic [4:0] enc_state;  // 5 个延迟寄存器, s[0]=最近历史bit
  logic       term_active;  // 正在做 termination (连续编码 5 个 0)
  logic [2:0] term_cnt;  // 已编码的 termination 0 个数 (1..5)

  // 本拍数据编码所用状态: seq_start 时强制清零, 否则用当前状态
  logic [4:0] cur_state;
  assign cur_state = (bit_in_valid && seq_start) ? 5'd0 : enc_state;

  // ------------------------------------------------------------
  // 主时序: 数据编码 / termination 自动追加 / 边界清零
  // 优先级: 数据 bit > termination。二者本不同拍 (上游保证), 不会同拍冲突。
  // ------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enc_state      <= #1 5'd0;
      code_out       <= #1 2'd0;
      code_out_valid <= #1 1'b0;
      term_done      <= #1 1'b0;
      term_active    <= #1 1'b0;
      term_cnt       <= #1 3'd0;
    end else begin
      // 默认: 输出无效、term_done 不拉高 (单拍脉冲)
      code_out_valid <= #1 1'b0;
      term_done      <= #1 1'b0;

      if (bit_in_valid) begin
        // ---- 正常数据 bit: 用 cur_state 编码, 状态左移吃入 bit_in ----
        code_out       <= #1 fec_pair(bit_in, cur_state);
        code_out_valid <= #1 1'b1;
        enc_state      <= #1{cur_state[3:0], bit_in};
      end else if (seq_flush || term_active) begin
        // ---- termination: 连续编码 5 个 0, effbit=0 用当前状态 ----
        code_out       <= #1 fec_pair(1'b0, enc_state);
        code_out_valid <= #1 1'b1;
        enc_state      <= #1{enc_state[3:0], 1'b0};

        if (!term_active) begin
          // 由 seq_flush 触发, 本拍即第 1 个 0
          term_active <= #1 1'b1;
          term_cnt    <= #1 3'd1;
        end else if (term_cnt == 3'd4) begin
          // 本拍是第 5 个 0: termination 结束, 状态此后回全0
          term_active <= #1 1'b0;
          term_cnt    <= #1 3'd0;
          term_done   <= #1 1'b1;   // 拉高一拍, 供状态机切下一序列
        end else begin
          term_cnt <= #1 term_cnt + 3'd1;
        end
      end
      // 否则: 气泡拍 (无 valid/flush/term), enc_state 保持, 输出无效
    end
  end

endmodule
