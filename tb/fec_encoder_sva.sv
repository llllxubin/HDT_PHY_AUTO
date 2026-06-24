// =============================================================
// fec_encoder_sva — fec_encoder 接口断言 (spec §4.4), 经 bind 绑定到 DUT
//
// 为何独立成模块 + bind: 保持 rtl/fec_encoder.sv 可综合、无断言污染;
// checker 经 bind 在 DUT 作用域内实例化, 可直接按名访问其内部信号
// (enc_state/term_cnt/term_active) 与端口, 无需层次引用。
//
// 闸门接入: VCS 对断言失败仍返回退出码0, 故本模块自计错误数, 在 final 块写
// sim/fec_encoder/sva_status.txt (PASS/FAIL), 由 Makefile `sva` 目标以退出码闸门。
//
// 四条断言 (spec §4.4):
//   A1 seq_start 当拍编码器清零      -> 首bit后状态 == {4'b0, 首bit}
//   A2 seq_flush 后恰好5个0, term_done 才拉高 -> flush 起第5拍 term_done
//   A3 term_done 后内部状态全0
//   A4 复位期 code_out_valid == 0
// =============================================================
`timescale 1ns/1ps

module fec_encoder_sva (
    input logic       clk,
    input logic       rst_n,
    input logic       bit_in,
    input logic       bit_in_valid,
    input logic       seq_start,
    input logic       seq_flush,
    input logic [1:0] code_out,
    input logic       code_out_valid,
    input logic       term_done,
    // ---- DUT 内部信号 (bind .* 按名连接) ----
    input logic [4:0] enc_state,
    input logic [2:0] term_cnt,
    input logic       term_active
);

  int unsigned err = 0;

  // ---- A1: seq_start 当拍编码器清零 ----
  // 带 seq_start 吃首bit后, 下一拍状态必为 {4'b0, 该首bit} (与历史脏状态无关)。
  property p_seqstart_clear;
    @(posedge clk) disable iff (!rst_n)
    (bit_in_valid && seq_start) |=> (enc_state == {4'b0, $past(bit_in)});
  endproperty
  a_seqstart_clear: assert property (p_seqstart_clear)
    else begin err++; $error("[SVA] A1 seq_start 未清零: enc_state=%b", enc_state); end

  // ---- A2: seq_flush 后恰好 5 个 0 被编码, term_done 才拉高 ----
  // flush 触发拍(第1个0)起, 第5拍(##5)term_done 拉高一拍。
  property p_flush_to_termdone;
    @(posedge clk) disable iff (!rst_n)
    (seq_flush && !term_active && !bit_in_valid) |-> ##5 term_done;
  endproperty
  a_flush_to_termdone: assert property (p_flush_to_termdone)
    else begin err++; $error("[SVA] A2 flush 后 term_done 时序错"); end

  // term_done 只能在第5个0(term_active 且 term_cnt==4)那拍之后拉高
  property p_termdone_only_at5;
    @(posedge clk) disable iff (!rst_n)
    term_done |-> $past(term_active && (term_cnt == 3'd4));
  endproperty
  a_termdone_only_at5: assert property (p_termdone_only_at5)
    else begin err++; $error("[SVA] A2 term_done 非在第5个0后拉高"); end

  // ---- A3: term_done 后内部状态全 0 ----
  property p_state_zero_on_termdone;
    @(posedge clk) disable iff (!rst_n)
    term_done |-> (enc_state == 5'd0);
  endproperty
  a_state_zero_on_termdone: assert property (p_state_zero_on_termdone)
    else begin err++; $error("[SVA] A3 term_done 时状态非全0: enc_state=%b", enc_state); end

  // ---- A4: 复位期 code_out_valid == 0 ----
  property p_reset_valid0;
    @(posedge clk) (!rst_n) |-> (code_out_valid == 1'b0);
  endproperty
  a_reset_valid0: assert property (p_reset_valid0)
    else begin err++; $error("[SVA] A4 复位期 code_out_valid 非0"); end

  // ---- 结论落盘: 供 Makefile sva 目标以退出码闸门 ----
  final begin
    integer fd;
    fd = $fopen("sim/fec_encoder/sva_status.txt", "w");
    if (err == 0) $fwrite(fd, "PASS sva 0 errors\n");
    else          $fwrite(fd, "FAIL sva %0d errors\n", err);
    $fclose(fd);
    $display("[SVA] 断言失败计数 = %0d", err);
  end

endmodule

// ---- bind 到 DUT: .* 在 fec_encoder 作用域内按名连接全部端口与内部信号 ----
bind fec_encoder fec_encoder_sva u_fec_sva (.*);
