// =============================================================
// fec_encoder testbench
// 读 sim/fec_encoder/stim_bits.txt 激励 -> 驱动 DUT -> dump code_out 到 sim/fec_encoder/rtl_dump.txt
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

  // ---- 功能覆盖率 (spec §4.3): 32状态全遍历 + 状态×输入交叉 ----
  // 采样编码器内部状态 (层次引用) 与当拍输入比特; 复位期不计。
  covergroup cg_fec @(posedge clk);
    cp_state: coverpoint u_dut.enc_state iff (rst_n) { bins all[] = {[0:31]}; }
    cp_bit:   coverpoint bit_in           iff (rst_n && bit_in_valid);
    x_state_bit: cross cp_state, cp_bit;   // 每个状态下 0/1 输入都激励过
  endgroup
  cg_fec cg = new();

  // ---- 激励解析: 读入所有序列 ----
  // 简化做法: 预读到队列。序列用 -1 作为分隔标记。
  integer stim_bits [$];   // 展平的bit, 序列边界用 sentinel -1
  integer fd, code, val;
  string  line;
  integer dump_fd;
  integer cov_fd;
  bit     first_bit_of_seq = 0;   // 序列首bit标志 (VCS要求先声明后用, 故上移至此)
  bit     dump_en = 1;            // dump 使能: 主激励期=1; 定向自检期=0 (不污染 compare)

  initial begin
    // 读激励文件
    fd = $fopen("sim/fec_encoder/stim_bits.txt", "r");
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
    dump_fd = $fopen("sim/fec_encoder/rtl_dump.txt", "w");

    // 复位
    bit_in = 0; bit_in_valid = 0; seq_start = 0; seq_flush = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    drive_all();

    $fclose(dump_fd);

    // ---- 覆盖率汇总: 写 sim/fec_encoder/cov_summary.txt, 供 scripts/check_cov.py 闸门判定 ----
    cov_fd = $fopen("sim/fec_encoder/cov_summary.txt", "w");
    $fwrite(cov_fd, "cp_state %0.4f\n",    cg.cp_state.get_coverage());
    $fwrite(cov_fd, "x_state_bit %0.4f\n", cg.x_state_bit.get_coverage());
    $fwrite(cov_fd, "overall %0.4f\n",     cg.get_coverage());
    $fclose(cov_fd);
    $display("[TB] cp_state=%0.2f%% x_state_bit=%0.2f%%",
             cg.cp_state.get_coverage(), cg.x_state_bit.get_coverage());

    // ---- 定向自检: seq_start 清零不变量 (元变形, 无需 golden, 关 dump 不污染 compare) ----
    // 验证 spec §4.4 "seq_start 当拍编码器清零"; 专杀 no_clear 类变异 (漏清零)。
    dump_en = 0;
    check_seqstart_clear();

    $display("[TB] 完成, dump 写入 sim/fec_encoder/rtl_dump.txt");
    $finish;
  end

  // ---- dump: 每当 code_out_valid 采样输出 ----
  // 用一个标志区分序列, 由 driver 在 seq_start 时写 # SEQ
  always @(posedge clk) begin
    if (rst_n && code_out_valid && dump_en) begin
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

  // ---- 定向自检辅助任务 (seq_start 清零不变量) ----

  // 局部复位编码器: real/mutant 都清零, 作两场景公共起点
  task do_reset();
    @(negedge clk);
    rst_n = 0;
    bit_in = 0; bit_in_valid = 0; seq_start = 0; seq_flush = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // 喂一个数据bit, 不带 seq_start/flush (用于堆叠"脏状态")
  task feed_plain(input bit b);
    @(negedge clk);
    bit_in = b; bit_in_valid = 1; seq_start = 0; seq_flush = 0;
    @(posedge clk);
    @(negedge clk);
    bit_in_valid = 0;
  endtask

  // 带 seq_start 送首bit, 捕获其组合输出 (状态更新前采样)
  task start_and_capture(input bit b, output bit [1:0] o);
    @(negedge clk);
    bit_in = b; bit_in_valid = 1; seq_start = 1; seq_flush = 0;
    #1 o = code_out;          // 组合输出已稳定, posedge 尚未更新状态
    @(posedge clk);
    @(negedge clk);
    bit_in_valid = 0; seq_start = 0;
  endtask

  // 元变形不变量: seq_start 必清零 => 首bit输出只取决于该bit, 与历史脏状态无关。
  // 两种不同脏状态下对同一首bit的输出必须相等; no_clear 变异会令二者不同 -> $fatal。
  // 注: VCS 对 $fatal 仍返回退出码0, 无法靠仿真退出码闸门;
  // 故把结论写 sim/fec_encoder/selfcheck.txt, 由 Makefile selfcheck 目标读取并以退出码闸门。
  task check_seqstart_clear();
    bit [1:0] oa, ob;
    integer   sc_fd;
    // 场景A: 脏状态 = 11111 (喂5个1)
    do_reset();
    feed_plain(1); feed_plain(1); feed_plain(1); feed_plain(1); feed_plain(1);
    start_and_capture(1'b1, oa);
    // 场景B: 脏状态 = 00001 (喂1个1)
    do_reset();
    feed_plain(1);
    start_and_capture(1'b1, ob);

    sc_fd = $fopen("sim/fec_encoder/selfcheck.txt", "w");
    if (oa !== ob) begin
      $fwrite(sc_fd, "FAIL seqstart_clear A=%b B=%b\n", oa, ob);
      $display("[CHECK] seq_start 清零失效: 首bit输出依赖历史脏状态 (A=%b B=%b)", oa, ob);
    end else begin
      $fwrite(sc_fd, "PASS seqstart_clear oa=ob=%b\n", oa);
      $display("[CHECK] seq_start 清零不变量 PASS (oa=ob=%b)", oa);
    end
    $fclose(sc_fd);
  endtask

endmodule
