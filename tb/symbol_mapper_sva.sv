// =============================================================
// symbol_mapper_sva — symbol_mapper 接口断言 (spec §4.4), 经 bind 绑定到 DUT
//
// 黑盒原则: 仅断言端口可观测契约, 不引用 DUT 内部累加器/k_parity/ROM。
//
// 闸门接入: VCS 对断言失败仍返回退出码0, 故自计错误数, final 块写
//   sim/symbol_mapper/sva_status.txt (PASS/FAIL), 由 Makefile sva 目标以退出码闸门。
//
// 断言 (spec §4.4):
//   A_RST   复位期 sym_valid==0 且 sym_i/sym_q==0
//   A_LEGAL sym_valid -> (sym_i,sym_q) ∈ 当前 mod_sel 的合法量化码集
//           (含"永不出现 +512": 合法集均在 [-512,+511] 且为表内值; 精确值由 compare 0容差兜底)
//   A_QFE   QPSK 时 seq_start 后首产出符号 k_parity==even (偶表值 |i|==362 && |q|==362)
// =============================================================
`timescale 1ns / 1ps

module symbol_mapper_sva (
    input logic       clk,
    input logic       rst_n,
    input logic [1:0] code_in,
    input logic [1:0] code_in_cnt,
    input logic       seq_start,
    input logic       sym_flush,
    input logic [1:0] mod_sel,
    input logic [9:0] sym_i,
    input logic [9:0] sym_q,
    input logic       sym_valid
);

  int unsigned err = 0;

  // ---- 合法量化码判定 (spec §1) ----
  function automatic bit in_set5(input int v);
    // QPSK/8PSK 分量集: {-512,-362,0,362,511}
    return (v == -512 || v == -362 || v == 0 || v == 362 || v == 511);
  endfunction

  function automatic bit qpsk_pair(input int i, input int q);
    // 8 个 QPSK 码值 (偶 4 + 奇 4)
    return (i == 362 && q == 362) || (i == -362 && q == 362) ||
           (i == 362 && q == -362) || (i == -362 && q == -362) ||
           (i == 0 && q == 511) || (i == -512 && q == 0) ||
           (i == 511 && q == 0) || (i == 0 && q == -512);
  endfunction

  function automatic bit psk8_pair(input int i, input int q);
    return (i == 511 && q == 0) || (i == 362 && q == 362) ||
           (i == -362 && q == 362) || (i == 0 && q == 511) ||
           (i == 362 && q == -362) || (i == 0 && q == -512) ||
           (i == -512 && q == 0) || (i == -362 && q == -362);
  endfunction

  function automatic bit qam16_comp(input int v);
    return (v == -486 || v == -162 || v == 162 || v == 486);
  endfunction

  function automatic bit legal(input logic [1:0] mod, input int i, input int q);
    case (mod)
      2'b00:   return qpsk_pair(i, q);
      2'b01:   return psk8_pair(i, q);
      2'b10:   return qam16_comp(i) && qam16_comp(q);
      default: return 1'b0;
    endcase
  endfunction

  // ---- A_RST: 复位期 sym_valid==0 且输出为 0 ----
  property p_rst;
    @(posedge clk) (!rst_n) |-> (!sym_valid && sym_i == 10'd0 && sym_q == 10'd0);
  endproperty
  a_rst :
  assert property (p_rst)
  else begin
    err++;
    $error("[SVA] A_RST 复位期输出非0: valid=%0b i=%0d q=%0d", sym_valid, $signed(sym_i),
           $signed(sym_q));
  end

  // ---- A_LEGAL: 产出符号必在合法量化码集 (永不出现 +512 / 非表值) ----
  property p_legal;
    @(posedge clk) disable iff (!rst_n) sym_valid |-> legal(
        mod_sel, $signed(sym_i), $signed(sym_q)
    );
  endproperty
  a_legal :
  assert property (p_legal)
  else begin
    err++;
    $error("[SVA] A_LEGAL 非法码值: mod=%0d i=%0d q=%0d", mod_sel, $signed(sym_i), $signed(
                                                                                           sym_q));
  end

  // ---- A_QFE: QPSK seq_start 后首产出符号为偶 (|i|==362 && |q|==362) ----
  // expect_even 在 seq_start 拍置位; 首个 QPSK sym_valid 检验后清零。
  // seq_start 同拍的 sym_valid 属上一序列尾 (流水), 用 !seq_start 排除。
  logic expect_even;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) expect_even <= 1'b0;
    else if (seq_start) expect_even <= 1'b1;
    else if (sym_valid && mod_sel == 2'b00 && expect_even) expect_even <= 1'b0;
  end

  function automatic bit is_even_qpsk(input int i, input int q);
    return ((i == 362 || i == -362) && (q == 362 || q == -362));
  endfunction

  property p_qfe;
    @(posedge clk) disable iff (!rst_n)
    (sym_valid && mod_sel == 2'b00 && expect_even && !seq_start) |->
        is_even_qpsk(
        $signed(sym_i), $signed(sym_q)
    );
  endproperty
  a_qfe :
  assert property (p_qfe)
  else begin
    err++;
    $error("[SVA] A_QFE seq_start 后首符号非偶: i=%0d q=%0d", $signed(sym_i), $signed(sym_q));
  end

  // ---- 结论落盘: 供 Makefile sva 目标以退出码闸门 ----
  final begin
    integer fd;
    fd = $fopen("sim/symbol_mapper/sva_status.txt", "w");
    if (err == 0) $fwrite(fd, "PASS sva 0 errors\n");
    else $fwrite(fd, "FAIL sva %0d errors\n", err);
    $fclose(fd);
    $display("[SVA] 断言失败计数 = %0d", err);
  end

endmodule

// ---- bind 到 DUT: 仅端口, 黑盒 ----
bind symbol_mapper symbol_mapper_sva u_symmap_sva (
    .clk        (clk),
    .rst_n      (rst_n),
    .code_in    (code_in),
    .code_in_cnt(code_in_cnt),
    .seq_start  (seq_start),
    .sym_flush  (sym_flush),
    .mod_sel    (mod_sel),
    .sym_i      (sym_i),
    .sym_q      (sym_q),
    .sym_valid  (sym_valid)
);
