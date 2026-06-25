// =============================================================
// puncturing_sva — puncturing 接口断言 (spec §4.4 / HANDOFF §3), 经 bind 绑定到 DUT
//
// 黑盒原则: 仅断言端口可观测契约, 不引用 DUT 内部相位寄存器。
//   A2 (seq_start 相位复位) 属内部状态, 由 TB selfcheck + 覆盖率间接验证, 此处不写。
//
// 闸门接入: VCS 对断言失败仍返回退出码0, 故自计错误数, final 块写
//   sim/puncturing/sva_status.txt (PASS/FAIL), 由 Makefile sva 目标以退出码闸门。
//
// 断言 (HANDOFF §3 / spec §4.4):
//   A1 rate=1/2 透传不变量: valid && rate==00 |-> cnt==2 && code_out==code_in
//   A3 code_out_cnt 永不越界: cnt <= 2
//   A4 复位期输出为 0: !rst_n |-> code_out==0 && cnt==0
//   A5 无输入不产出: !code_in_valid |-> cnt==0
// =============================================================
`timescale 1ns / 1ps

module puncturing_sva (
    input logic       clk,
    input logic       rst_n,
    input logic [1:0] code_in,
    input logic       code_in_valid,
    input logic       seq_start,
    input logic [1:0] punc_rate,
    input logic [1:0] code_out,
    input logic [1:0] code_out_cnt
);

  int unsigned err = 0;

  // ---- A1: rate=1/2 透传不变量 (组合输出, 同拍判定) ----
  property p_passthrough;
    @(posedge clk) disable iff (!rst_n)
    (code_in_valid && (punc_rate == 2'b00)) |->
      (code_out_cnt == 2'b10 && code_out == code_in);
  endproperty
  a_passthrough :
  assert property (p_passthrough)
  else begin
    err++;
    $error("[SVA] A1 rate=1/2 透传失效: cnt=%0d out=%b in=%b", code_out_cnt, code_out, code_in);
  end

  // ---- A3: code_out_cnt 永不越界 (<=2) ----
  property p_cnt_range;
    @(posedge clk) disable iff (!rst_n) (code_out_cnt <= 2'b10);
  endproperty
  a_cnt_range :
  assert property (p_cnt_range)
  else begin
    err++;
    $error("[SVA] A3 code_out_cnt 越界: %0d", code_out_cnt);
  end

  // ---- A4: 复位期输出为 0 ----
  property p_reset_zero;
    @(posedge clk) (!rst_n) |-> (code_out == 2'b00 && code_out_cnt == 2'b00);
  endproperty
  a_reset_zero :
  assert property (p_reset_zero)
  else begin
    err++;
    $error("[SVA] A4 复位期输出非0: out=%b cnt=%0d", code_out, code_out_cnt);
  end

  // ---- A5: 无输入不产出 (valid 低 -> cnt==0) ----
  property p_no_input_no_output;
    @(posedge clk) disable iff (!rst_n) (!code_in_valid) |-> (code_out_cnt == 2'b00);
  endproperty
  a_no_input_no_output :
  assert property (p_no_input_no_output)
  else begin
    err++;
    $error("[SVA] A5 无输入仍产出: cnt=%0d", code_out_cnt);
  end

  // ---- 结论落盘: 供 Makefile sva 目标以退出码闸门 ----
  final begin
    integer fd;
    fd = $fopen("sim/puncturing/sva_status.txt", "w");
    if (err == 0) $fwrite(fd, "PASS sva 0 errors\n");
    else $fwrite(fd, "FAIL sva %0d errors\n", err);
    $fclose(fd);
    $display("[SVA] 断言失败计数 = %0d", err);
  end

endmodule

// ---- bind 到 DUT: 仅端口, 黑盒 ----
bind puncturing puncturing_sva u_punc_sva (
    .clk          (clk),
    .rst_n        (rst_n),
    .code_in      (code_in),
    .code_in_valid(code_in_valid),
    .seq_start    (seq_start),
    .punc_rate    (punc_rate),
    .code_out     (code_out),
    .code_out_cnt (code_out_cnt)
);
