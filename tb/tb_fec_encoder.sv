// =============================================================
// fec_encoder testbench
// 读 sim/stim_bits.txt 激励 -> 驱动 DUT -> dump code_out 到 sim/rtl_dump.txt
// 序列边界: 每个 # SEQ 对应一次 seq_start (首bit) + seq_flush (数据末)
// 时钟域: 48MHz 单一时钟 (周期此处用 20.833ns 近似, 仿真不敏感)
// 判定: 离线由 scripts/compare.py vs Python golden 完成, 本 TB 只负责激励与 dump
// =============================================================
`timescale 1ns/1ps

module tb_fec_encoder;

  // ---- 时钟/复位 ----
  logic clk = 0;
  logic rst_n = 0;
  always #10.4167 clk = ~clk;   // ~48MHz

  // ---- DUT 接口 ----
  logic        bit_in;
  logic        bit_in_valid;
  logic        seq_start;
  logic        seq_flush;
  logic [1:0]  code_out;
  logic        code_out_valid;
  logic        term_done;

  // ---- 例化 DUT (待 W2 生成的 RTL) ----
  fec_encoder u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .bit_in         (bit_in),
    .bit_in_valid   (bit_in_valid),
    .seq_start      (seq_start),
    .seq_flush      (seq_flush),
    .code_out       (code_out),
    .code_out_valid (code_out_valid),
    .term_done      (term_done)
  );

  // ---- 激励解析: 读入所有序列 ----
  // 简化做法: 预读到队列。序列用 -1 作为分隔标记。
  integer stim_bits [$];   // 展平的bit, 序列边界用 sentinel -1
  integer fd, code, val;
  string  line;
  integer dump_fd;
  bit     first_bit_of_seq = 0;   // 序列首bit标志 (VCS要求先声明后用, 故上移至此)

  initial begin
    // 读激励文件
    fd = $fopen("sim/stim_bits.txt", "r");
    if (fd == 0) begin $display("[TB][FATAL] 打不开 stim_bits.txt"); $finish; end
    while (!$feof(fd)) begin
      code = $fgets(line, fd);
      if (code == 0) continue;
      if (line.substr(0,4) == "# SEQ") begin
        stim_bits.push_back(-1);          // 序列分隔标记
      end else if (line.substr(0,0) == "0" || line.substr(0,0) == "1") begin
        stim_bits.push_back(line.substr(0,0).atoi());
      end
    end
    $fclose(fd);

    // 打开 dump 文件
    dump_fd = $fopen("sim/rtl_dump.txt", "w");

    // 复位
    bit_in = 0; bit_in_valid = 0; seq_start = 0; seq_flush = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    drive_all();

    $fclose(dump_fd);
    $display("[TB] 完成, dump 写入 sim/rtl_dump.txt");
    $finish;
  end

  // ---- dump: 每当 code_out_valid 采样输出 ----
  // 用一个标志区分序列, 由 driver 在 seq_start 时写 # SEQ
  always @(posedge clk) begin
    if (rst_n && code_out_valid) begin
      $fwrite(dump_fd, "%0d %0d\n", code_out[0], code_out[1]); // a0=bit0, a1=bit1
    end
  end

  // ---- 驱动任务 ----
  task drive_all();
    integer i;
    bit in_seq;
    in_seq = 0;
    for (i = 0; i < stim_bits.size(); i = i + 1) begin
      if (stim_bits[i] == -1) begin
        // 序列分隔: 若前一序列在进行, 先 flush
        if (in_seq) flush_seq();
        // 新序列开始标记写入 dump
        $fwrite(dump_fd, "# SEQ\n");
        in_seq = 1;
        // 下一个有效bit将带 seq_start (在 send_bit 内处理)
        first_bit_of_seq = 1;
      end else begin
        send_bit(stim_bits[i][0]);
      end
    end
    if (in_seq) flush_seq();
  endtask

  // 送一个数据bit (背靠背, 无空拍)
  task send_bit(input bit b);
    @(negedge clk);
    bit_in       = b;
    bit_in_valid = 1;
    seq_start    = first_bit_of_seq;
    seq_flush    = 0;
    first_bit_of_seq = 0;
    @(posedge clk);
    @(negedge clk);
    bit_in_valid = 0;
    seq_start    = 0;
  endtask

  // 发 flush: 触发 5个0 termination, 等 term_done
  task flush_seq();
    @(negedge clk);
    seq_flush = 1;
    @(posedge clk);
    @(negedge clk);
    seq_flush = 0;
    // 等 termination 完成
    wait (term_done == 1);
    @(posedge clk);
  endtask

endmodule
