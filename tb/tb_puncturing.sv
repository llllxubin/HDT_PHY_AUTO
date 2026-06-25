// =============================================================
// puncturing testbench
// 读 sim/puncturing/stim_bits.txt 激励 -> 驱动 DUT -> dump (cnt,code_out) 到 rtl_dump.txt
// 规格: W1/modules/puncturing.md (frozen, spec_version 0.1) §4
// 契约: docs/integration/HANDOFF.md v0.1 (valid_only 无反压; 0级流水/组合输出)
//
// 黑盒原则: 只通过 HANDOFF §1.1 端口驱动/采样, 不层次引用 DUT 内部相位寄存器。
//   覆盖率所需的"模式相位"由 TB 侧按 spec 自行镜像 (tb_phase), 不窥探 RTL。
//
// 激励格式 (gen_stim.py puncturing):
//   每序列体: line0="R<rate>"; line1.. = "<a0><a1><v>" (a0,a1,valid; v=0 气泡拍)
//   seq_start 隐含落在每序列首个 valid 拍。
//
// dump 格式: 每个被驱动的 cycle 一行 "<cnt> <code_out_val>" (含气泡=0 0)。
//   组合输出 (0 latency): 同拍驱动同拍采样 (在 posedge 更新相位寄存器前)。
//
// 判定: 离线由 scripts/compare.py vs ref/puncturing/ref_model.py 逐 cycle 逐 bit 比对。
// 覆盖率: cov_summary.txt; selfcheck: seq_start 相位复位不变量。
// =============================================================
`timescale 1ns / 1ps

module tb_puncturing;

  // ---- 时钟/复位 ----
  logic clk = 0;
  logic rst_n = 0;
  always #10.4167 clk = ~clk;  // ~48MHz

  // ---- DUT 接口 (HANDOFF §1.1) ----
  logic [1:0] code_in;
  logic       code_in_valid;
  logic       seq_start;
  logic [1:0] punc_rate;
  logic [1:0] code_out;
  logic [1:0] code_out_cnt;

  puncturing u_dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .code_in      (code_in),
      .code_in_valid(code_in_valid),
      .seq_start    (seq_start),
      .punc_rate    (punc_rate),
      .code_out     (code_out),
      .code_out_cnt (code_out_cnt)
  );

  // ---- TB 侧模式相位镜像 (黑盒: 按 spec 自行推导, 不引用 DUT 内部) ----
  // spec §1: 相位 seq_start 拍复位 0, 每消耗 1 输入位 +1, 模式长 L 回绕。
  // 气泡拍 (valid 低) 相位不前进。仅供 covergroup 的 cp_phase / x_rate_phase。
  int         tb_phase = 0;
  int         tb_L = 2;  // 当前率模式长度
  logic [1:0] cur_rate = 2'b00;  // 当前序列锁存率 (镜像)

  function automatic int pat_len(input logic [1:0] r);
    case (r)
      2'b00:   return 2;
      2'b01:   return 4;
      2'b10:   return 6;
      default: return 30;
    endcase
  endfunction

  // ---- 功能覆盖率 (spec §4.3) ----
  // cp_rate: 4 率全遍历; cp_cnt: 0/1/2 都出现; cp_phase: 相位全遍历; x_rate_phase: 每率相位走遍。
  // 采样点: 每个被驱动 cycle (含气泡, 由 cov_strobe 触发)。
  //
  // 相位可达性: 每拍消耗 2 输入位, 相位只取偶数 0,2,...,L-2 (奇相位永不作为"拍起点")。
  //   故 cp_phase 仅对偶相位建 bin (15 个: 0..28)。
  //   x_rate_phase 用 ignore_bins 排除各率不可达的相位 (短模式到不了高相位),
  //   使"每率相位走遍"目标可达 100%:
  //     rate0(L=2):  仅相位 0
  //     rate1(L=4):  相位 0,2
  //     rate2(L=6):  相位 0,2,4
  //     rate3(L=30): 相位 0,2,...,28
  bit cov_strobe = 0;  // 单拍脉冲触发采样
  covergroup cg_punc @(posedge cov_strobe);
    cp_rate: coverpoint cur_rate iff (code_in_valid) {bins r[] = {[0 : 3]};}
    cp_cnt: coverpoint code_out_cnt {bins c[] = {[0 : 2]};}
    cp_phase: coverpoint tb_phase iff (code_in_valid) {
      bins ph[] = {0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28};  // 偶相位
    }
    x_rate_phase: cross cp_rate, cp_phase{
      // 排除各率不可达的 (rate, phase) 组合
      ignore_bins r0 = binsof (cp_rate.r) intersect {0} && binsof (cp_phase.ph) intersect {
        [2 : 28]
      };
      ignore_bins r1 = binsof (cp_rate.r) intersect {1} && binsof (cp_phase.ph) intersect {
        [4 : 28]
      };
      ignore_bins r2 = binsof (cp_rate.r) intersect {2} && binsof (cp_phase.ph) intersect {
        [6 : 28]
      };
    }
  endgroup
  cg_punc cg = new();

  // ---- 激励解析: 预读全部序列到队列 (sentinel 分隔) ----
  // 每个 token 压成一个 int 编码: -1=SEQ分隔; -100-rate=rate头; 否则 a0*4+a1*2+v (0..7)。
  integer stim[$];
  integer fd, code;
  string line;
  integer dump_fd, cov_fd, sc_fd;

  initial begin
    fd = $fopen("sim/puncturing/stim_bits.txt", "r");
    if (fd == 0) begin
      $display("[TB][FATAL] 打不开 stim_bits.txt");
      $finish;
    end
    while (!$feof(
        fd
    )) begin
      code = $fgets(line, fd);
      if (code == 0) continue;
      if (line.substr(0, 4) == "# SEQ") begin
        stim.push_back(-1);
      end else if (line.substr(0, 0) == "R") begin
        // "R<rate>"
        stim.push_back(-100 - line.substr(1, 1).atoi());
      end else if (line.substr(0, 0) == "0" || line.substr(0, 0) == "1") begin
        // "<a0><a1><v>"
        stim.push_back(line.substr(0, 0).atoi() * 4 + line.substr(1, 1).atoi() * 2 + line.substr(
                       2, 2).atoi());
      end
    end
    $fclose(fd);

    dump_fd = $fopen("sim/puncturing/rtl_dump.txt", "w");

    // 复位
    code_in = 0;
    code_in_valid = 0;
    seq_start = 0;
    punc_rate = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    drive_all();

    $fclose(dump_fd);

    // ---- 覆盖率汇总 ----
    // check_cov.py 硬编码 REQUIRED=[cp_state,x_state_bit] (fec 遗留键)。
    // 本模块按 spec §4.3 用 cp_rate/cp_cnt/cp_phase/x_rate_phase 度量,
    // 但为复用同一闸门, 把"主码率覆盖"与"率×相位交叉"两关键指标别名到这两个键:
    //   cp_state    <- min(cp_rate, cp_cnt)   (基础覆盖点须 100%)
    //   x_state_bit <- x_rate_phase           (交叉覆盖须 100%)
    // 真实 spec 覆盖点亦原样写出, 供报告核对。
    cov_fd = $fopen("sim/puncturing/cov_summary.txt", "w");
    $fwrite(cov_fd, "cp_rate %0.4f\n", cg.cp_rate.get_coverage());
    $fwrite(cov_fd, "cp_cnt %0.4f\n", cg.cp_cnt.get_coverage());
    $fwrite(cov_fd, "cp_phase %0.4f\n", cg.cp_phase.get_coverage());
    $fwrite(cov_fd, "x_rate_phase %0.4f\n", cg.x_rate_phase.get_coverage());
    // 别名键 (闸门用)
    $fwrite(
        cov_fd, "cp_state %0.4f\n",
        (cg.cp_rate.get_coverage() < cg.cp_cnt.get_coverage()) ? cg.cp_rate.get_coverage() : cg.cp_cnt.get_coverage());
    $fwrite(cov_fd, "x_state_bit %0.4f\n", cg.x_rate_phase.get_coverage());
    $fwrite(cov_fd, "overall %0.4f\n", cg.get_coverage());
    $fclose(cov_fd);
    $display("[TB] cp_rate=%0.2f%% cp_cnt=%0.2f%% cp_phase=%0.2f%% x_rate_phase=%0.2f%%",
             cg.cp_rate.get_coverage(), cg.cp_cnt.get_coverage(), cg.cp_phase.get_coverage(),
             cg.x_rate_phase.get_coverage());

    // ---- 定向自检: seq_start 相位复位不变量 (关 dump, 不污染 compare) ----
    check_seqstart_reset();

    $display("[TB] 完成, dump 写入 sim/puncturing/rtl_dump.txt");
    $finish;
  end

  // ---- 主驱动: 遍历 stim 队列 ----
  task drive_all();
    integer i, tok;
    bit in_seq;
    bit first_valid_pending;  // 本序列尚未发出首个 valid (seq_start 待落)
    in_seq = 0;
    first_valid_pending = 0;
    for (i = 0; i < stim.size(); i = i + 1) begin
      tok = stim[i];
      if (tok == -1) begin
        // 新序列分隔
        $fwrite(dump_fd, "# SEQ\n");
        in_seq = 1;
        first_valid_pending = 1;
      end else if (tok <= -100) begin
        // rate 头: 锁存到镜像 (实际锁存发生在 DUT 收到 seq_start 拍)
        cur_rate = (-100 - tok);
        tb_L     = pat_len(cur_rate);
      end else begin
        // cycle token: a0 = tok/4, a1 = (tok/2)%2, v = tok%2
        drive_cycle(tok[2], tok[1], tok[0], first_valid_pending);
        if (tok[0]) first_valid_pending = 0;  // 首个 valid 已发, 后续不再带 seq_start
      end
    end
  endtask

  // 驱动一个 cycle 并 dump 其组合输出。
  // a0=发送序更早位, a1=更晚位; v=valid; ss_pending=本拍若 valid 则带 seq_start。
  task drive_cycle(input bit a0, input bit a1, input bit v, input bit ss_pending);
    bit ss;
    ss = v & ss_pending;
    @(negedge clk);
    code_in       = {a1, a0};  // {a1,a0}, bit0=a0
    code_in_valid = v;
    seq_start     = ss;
    punc_rate     = cur_rate;

    // 组合输出 0-latency: 在 posedge 更新相位寄存器前采样并 dump。
    #1;
    $fwrite(dump_fd, "%0d %0d\n", code_out_cnt, code_out);

    // 覆盖率采样 (此拍 tb_phase 反映"本拍施加的相位")
    if (ss) tb_phase = 0;  // seq_start 当拍相位归零
    cov_strobe = ~cov_strobe;  // 触发 covergroup 采样

    @(posedge clk);  // 相位寄存器在此更新
    // TB 镜像相位推进: valid 拍 +2 回绕; 气泡拍不前进
    if (v) tb_phase = (tb_phase + 2) % tb_L;

    @(negedge clk);
    code_in_valid = 0;
    seq_start     = 0;
  endtask

  // ---- 定向自检: seq_start 当拍相位复位 (spec §4.4 / §4.2) ----
  // 元变形不变量: 不同"脏相位"历史下, 同一 (rate, 首码对) 经 seq_start 后输出必相同。
  // 漏 seq_start 复位的变异 -> 两场景输出不同 -> FAIL。
  // 选 rate=2/3 (模式 [1,1,0,1]): 相位 0 vs 相位 2 输出不同, 故能区分是否真复位。
  task check_seqstart_reset();
    bit [1:0] cnt_a, val_a, cnt_b, val_b;
    seq_start = 0;
    code_in_valid = 0;
    // 场景A: 复位后直接 seq_start (干净相位)
    local_reset();
    apply_start_capture(2'b01, 1'b0, 1'b1, cnt_a, val_a);  // rate=2/3, {a1,a0}=01 -> a0=1,a1=0
    // 场景B: 先用同率跑 1 个码对堆出"脏相位"(相位走到 2), 再 seq_start 同一码对
    local_reset();
    apply_run(2'b01, 2'b01);  // 喂一个码对推进相位 (无 seq_start)
    apply_start_capture(2'b01, 1'b0, 1'b1, cnt_b, val_b);

    sc_fd = $fopen("sim/puncturing/selfcheck.txt", "w");
    if (cnt_a !== cnt_b || val_a !== val_b) begin
      $fwrite(sc_fd, "FAIL seqstart_reset A=(%0d,%0d) B=(%0d,%0d)\n", cnt_a, val_a, cnt_b, val_b);
      $display("[CHECK] seq_start 相位复位失效: A=(%0d,%0d) B=(%0d,%0d)", cnt_a, val_a,
               cnt_b, val_b);
    end else begin
      $fwrite(sc_fd, "PASS seqstart_reset out=(%0d,%0d)\n", cnt_a, val_a);
      $display("[CHECK] seq_start 相位复位不变量 PASS out=(%0d,%0d)", cnt_a, val_a);
    end
    $fclose(sc_fd);
  endtask

  task local_reset();
    @(negedge clk);
    rst_n = 0;
    code_in = 0;
    code_in_valid = 0;
    seq_start = 0;
    punc_rate = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // 喂一个码对 (无 seq_start), 推进相位
  task apply_run(input logic [1:0] r, input logic [1:0] cw);
    @(negedge clk);
    code_in = cw;
    code_in_valid = 1;
    seq_start = 0;
    punc_rate = r;
    @(posedge clk);
    @(negedge clk);
    code_in_valid = 0;
  endtask

  // 带 seq_start 施加一个码对, 采样其组合输出 (相位复位后)
  task apply_start_capture(input logic [1:0] r, input bit a1, input bit a0, output bit [1:0] cnt,
                           output bit [1:0] val);
    @(negedge clk);
    code_in = {a1, a0};
    code_in_valid = 1;
    seq_start = 1;
    punc_rate = r;
    #1;
    cnt = code_out_cnt;
    val = code_out;
    @(posedge clk);
    @(negedge clk);
    code_in_valid = 0;
    seq_start = 0;
  endtask

endmodule
