// =============================================================
// symbol_mapper testbench
// 读 sim/symbol_mapper/stim_bits.txt 激励 -> 驱动 DUT -> dump (sym_i,sym_q) 到 rtl_dump.txt
// 规格: W1/modules/symbol_mapper.md (frozen, spec_version 0.1) §1/§2/§4
//
// 黑盒原则: 仅通过 spec §2 端口契约驱动/采样, 不层次引用 DUT 内部累加器/k_parity/ROM。
//   覆盖率所需的 sym_bits/k_parity/pad_len 由 TB 侧按 spec §1 自行镜像 (不窥探 RTL)。
//
// 激励格式 (gen_stim.py symbol_mapper):
//   每序列体: line0="M<mod>"; line1.. = "<b0><b1><cnt><ss><fl>" (5字符/拍)
//     b0=code_in[0](先收到的位), b1=code_in[1], cnt=有效位数 0/1/2, ss=seq_start, fl=sym_flush
//
// dump 格式: 每序列一个 "# SEQ" 段, 段内每个 sym_valid=1 的符号一行 "<sym_i> <sym_q>"。
//   输出寄存(spec §5 1级流水): 用独立 posedge 监视器采样 sym_valid; 每序列驱动后排空
//   若干 cnt=0 空拍捕获尾符号。仅比对有序符号列, 流水延迟无关 (compare 逐符号 0容差)。
//
// 判定: 离线由 scripts/compare.py vs ref/symbol_mapper/ref_model.py 逐符号 0 容差比对。
// 覆盖率: cov_summary.txt; selfcheck: seq_start 复位 k -> 首符号偶 不变量。
// =============================================================
`timescale 1ns / 1ps

module tb_symbol_mapper;

  // ---- 时钟/复位 ----
  logic clk = 0;
  logic rst_n = 0;
  always #10.4167 clk = ~clk;  // ~48MHz

  // ---- DUT 接口 (spec §2) ----
  logic [1:0] code_in;
  logic [1:0] code_in_cnt;
  logic       seq_start;
  logic       sym_flush;
  logic [1:0] mod_sel;
  logic [9:0] sym_i;
  logic [9:0] sym_q;
  logic       sym_valid;

  symbol_mapper u_dut (
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

  // ---- 符号捕获: 独立 posedge 监视器 (与驱动解耦, 容忍寄存输出延迟) ----
  // 采样点 posedge+#1: DUT 输出寄存器已更新, 远离驱动用的 negedge, 无读写竞争。
  // 捕获到的符号按 cur_seq 归类; dumping=0 时 (selfcheck 期) 不采集。
  bit dumping = 0;
  int cur_seq = -1;
  int cap_i        [$];
  int cap_q        [$];
  int cap_seq      [$];

  always @(posedge clk) begin
    #1;
    if (dumping && sym_valid && rst_n) begin
      cap_i.push_back($signed(sym_i));
      cap_q.push_back($signed(sym_q));
      cap_seq.push_back(cur_seq);
    end
  end

  // ---- TB 侧符号镜像 (黑盒: 按 spec §1 推导, 不引用 DUT 内部) ----
  // 仅用于 covergroup 的 sym_bits / k_parity / pad_len, 不参与对错判定。
  int m_acc[$];  // 累加器: 到达序 bit, m_acc[0]=本符号 n0=MSB
  int m_k = 0;  // 符号索引 (QPSK 奇偶用), seq_start 复位
  int m_sb = 2;  // 当前 mod 的 SB
  int cov_mod = 0;
  int cov_bits = 0;
  int cov_kpar = 0;
  int cov_pad = 0;  // 0=整符号, >0=flush 补 0 位数
  bit cov_strobe = 0;

  function automatic int sb_of(input int mod);
    case (mod)
      0:       return 2;
      1:       return 3;
      default: return 4;
    endcase
  endfunction

  function automatic int grp_val(input int sb, input int pad);
    int v;
    v = 0;
    for (int i = 0; i < sb; i++) begin
      v = (v << 1) | ((i < sb - pad) ? (m_acc[i] & 1) : 0);
    end
    return v;
  endfunction

  // ---- 功能覆盖率 (spec §4.3) ----
  // 触发用任意跳变 @(cov_strobe): 每符号 toggle 一次, 双沿都采样 (posedge 仅采半数会漏)
  covergroup cg_symmap @(cov_strobe);
    cp_mod: coverpoint cov_mod {bins m[] = {0, 1, 2};}
    cp_qpsk: coverpoint cov_bits iff (cov_mod == 0) {bins b[] = {[0 : 3]};}
    cp_kpar: coverpoint cov_kpar iff (cov_mod == 0) {bins p[] = {0, 1};}
    cp_8psk: coverpoint cov_bits iff (cov_mod == 1) {bins b[] = {[0 : 7]};}
    cp_16qam: coverpoint cov_bits iff (cov_mod == 2) {bins b[] = {[0 : 15]};}
    x_qpsk: cross cp_qpsk, cp_kpar;  // 偶/奇 × 4 = 8 入口
    cp_flush: coverpoint cov_pad {bins pad[] = {1, 2, 3};}  // 各补 0 位数
  endgroup
  cg_symmap cg = new();

  // 镜像推进一拍, 产符号时 strobe 覆盖率
  task automatic mirror_step(input int b0, input int b1, input int cnt, input bit ss, input bit fl,
                             input int mod);
    int sb;
    sb = m_sb;
    if (ss) begin
      m_acc.delete();
      m_k = 0;
    end
    if (cnt >= 1) m_acc.push_back(b0 & 1);
    if (cnt >= 2) m_acc.push_back(b1 & 1);
    while (m_acc.size() >= sb) begin
      cov_mod    = mod;
      cov_bits   = grp_val(sb, 0);
      cov_kpar   = m_k & 1;
      cov_pad    = 0;
      cov_strobe = ~cov_strobe;
      repeat (sb) m_acc.pop_front();
      m_k = m_k + 1;
    end
    if (fl && m_acc.size() > 0) begin
      int pad;
      pad        = sb - m_acc.size();
      cov_mod    = mod;
      cov_bits   = grp_val(sb, pad);
      cov_kpar   = m_k & 1;
      cov_pad    = pad;
      cov_strobe = ~cov_strobe;
      m_acc.delete();
      m_k = m_k + 1;
    end
  endtask

  // ---- 激励解析: 预读全部序列 ----
  // token 编码: -1=SEQ 分隔; -100-mod=mod 头; 否则 b0*10000+b1*1000+cnt*100+ss*10+fl
  integer stim[$];
  integer fd, code;
  string line;
  integer dump_fd, cov_fd, sc_fd;
  int nseq = 0;

  initial begin
    fd = $fopen("sim/symbol_mapper/stim_bits.txt", "r");
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
      end else if (line.substr(0, 0) == "M") begin
        stim.push_back(-100 - line.substr(1, 1).atoi());
      end else if (line.substr(0, 0) == "0" || line.substr(0, 0) == "1") begin
        stim.push_back(line.substr(0, 0).atoi() * 10000 + line.substr(1, 1
                       ).atoi() * 1000 + line.substr(2, 2).atoi() * 100 + line.substr(3, 3
                       ).atoi() * 10 + line.substr(4, 4).atoi());
      end
    end
    $fclose(fd);

    // 复位
    code_in = 0;
    code_in_cnt = 0;
    seq_start = 0;
    sym_flush = 0;
    mod_sel = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    dumping = 1;
    drive_all();
    dumping = 0;
    @(posedge clk);

    // ---- 写 dump: 按序列归类捕获到的符号 (含 0 符号的空段) ----
    dump_fd = $fopen("sim/symbol_mapper/rtl_dump.txt", "w");
    for (int s = 0; s < nseq; s++) begin
      $fwrite(dump_fd, "# SEQ\n");
      foreach (cap_seq[idx]) begin
        if (cap_seq[idx] == s) $fwrite(dump_fd, "%0d %0d\n", cap_i[idx], cap_q[idx]);
      end
    end
    $fclose(dump_fd);

    write_coverage();
    check_seqstart_kreset();

    $display("[TB] 完成, %0d 序列, 捕获 %0d 符号 -> rtl_dump.txt", nseq, cap_i.size());
    $finish;
  end

  // ---- 主驱动: 背靠背逐拍, 序列末排空流水 ----
  task drive_all();
    integer i, tok;
    int b0, b1, cnt, ss, fl, mod;
    mod = 0;
    for (i = 0; i < stim.size(); i = i + 1) begin
      tok = stim[i];
      if (tok == -1) begin
        cur_seq = nseq;
        nseq = nseq + 1;
      end else if (tok <= -100) begin
        mod  = -100 - tok;
        m_sb = sb_of(mod);
      end else begin
        b0  = (tok / 10000) % 10;
        b1  = (tok / 1000) % 10;
        cnt = (tok / 100) % 10;
        ss  = (tok / 10) % 10;
        fl  = tok % 10;
        drive_cycle(b0, b1, cnt, ss[0], fl[0], mod);
        if (i + 1 >= stim.size() || stim[i+1] == -1) drain_pipe(mod);
      end
    end
  endtask

  // 背靠背驱动一拍 (negedge 施加, 持续一周期); 同步推进覆盖率镜像
  task automatic drive_cycle(input int b0, input int b1, input int cnt, input bit ss, input bit fl,
                             input int mod);
    @(negedge clk);
    code_in     = {b1[0], b0[0]};  // code_in[0]=b0 先收到
    code_in_cnt = cnt[1:0];
    seq_start   = ss;
    sym_flush   = fl;
    mod_sel     = mod[1:0];
    mirror_step(b0, b1, cnt, ss, fl, mod);
  endtask

  // 排空流水: 多发 cnt=0 空拍 (镜像 cnt=0 不产符号), 让寄存尾符号被监视器捕获到本序列
  task automatic drain_pipe(input int mod);
    @(negedge clk);
    code_in_cnt = 0;
    seq_start   = 0;
    sym_flush   = 0;
    mod_sel     = mod[1:0];
    repeat (4) @(negedge clk);
  endtask

  task write_coverage();
    cov_fd = $fopen("sim/symbol_mapper/cov_summary.txt", "w");
    $fwrite(cov_fd, "cp_mod %0.4f\n", cg.cp_mod.get_coverage());
    $fwrite(cov_fd, "cp_qpsk %0.4f\n", cg.cp_qpsk.get_coverage());
    $fwrite(cov_fd, "cp_kpar %0.4f\n", cg.cp_kpar.get_coverage());
    $fwrite(cov_fd, "cp_8psk %0.4f\n", cg.cp_8psk.get_coverage());
    $fwrite(cov_fd, "cp_16qam %0.4f\n", cg.cp_16qam.get_coverage());
    $fwrite(cov_fd, "x_qpsk %0.4f\n", cg.x_qpsk.get_coverage());
    $fwrite(cov_fd, "cp_flush %0.4f\n", cg.cp_flush.get_coverage());
    // 别名键 (check_cov.py 硬编码 REQUIRED=[cp_state,x_state_bit], fec 遗留): 取最小值
    //   cp_state    <- min(cp_mod, cp_8psk, cp_16qam)  (8PSK 8 + 16QAM 16 入口 + 三调制)
    //   x_state_bit <- min(x_qpsk, cp_flush)           (QPSK 偶奇×4=8 入口 + flush 各补0)
    $fwrite(cov_fd, "cp_state %0.4f\n", min3(cg.cp_mod.get_coverage(), cg.cp_8psk.get_coverage(),
                                             cg.cp_16qam.get_coverage()));
    $fwrite(
        cov_fd, "x_state_bit %0.4f\n",
        (cg.x_qpsk.get_coverage() < cg.cp_flush.get_coverage()) ? cg.x_qpsk.get_coverage() : cg.cp_flush.get_coverage());
    $fwrite(cov_fd, "overall %0.4f\n", cg.get_coverage());
    $fclose(cov_fd);
    $display("[TB] cp_mod=%0.1f x_qpsk=%0.1f cp_8psk=%0.1f cp_16qam=%0.1f cp_flush=%0.1f",
             cg.cp_mod.get_coverage(), cg.x_qpsk.get_coverage(), cg.cp_8psk.get_coverage(),
             cg.cp_16qam.get_coverage(), cg.cp_flush.get_coverage());
  endtask

  function automatic real min3(input real a, input real b, input real c);
    real m;
    m = (a < b) ? a : b;
    return (m < c) ? m : c;
  endfunction

  // ---- 定向自检: seq_start 复位 k -> 其后首产出符号为偶 (spec §1/§4.4) ----
  // 元变形不变量: 不同 k 历史 (脏/净) 下, 同一 (mod=QPSK, ss + 符号(0,0)) 输出必相同,
  //   且必为偶表值 (362,362)。漏复位 k 的变异 -> 脏历史下走奇表 (0,0)=(0,511) -> 失配 -> FAIL。
  task check_seqstart_kreset();
    int ia, qa, ib, qb;
    local_reset();
    apply_qpsk_start_capture(ia, qa);  // 净 k
    local_reset();
    run_qpsk_dirty();  // 堆脏 k (->1,2,3)
    apply_qpsk_start_capture(ib, qb);

    sc_fd = $fopen("sim/symbol_mapper/selfcheck.txt", "w");
    if (ia !== ib || qa !== qb) begin
      $fwrite(sc_fd, "FAIL kreset A=(%0d,%0d) B=(%0d,%0d)\n", ia, qa, ib, qb);
      $display("[CHECK] seq_start 复位 k 失效: A=(%0d,%0d) B=(%0d,%0d)", ia, qa, ib, qb);
    end else if (ia !== 362 || qa !== 362) begin
      $fwrite(sc_fd, "FAIL kreset 首符号非偶表(362,362): (%0d,%0d)\n", ia, qa);
      $display("[CHECK] seq_start 后首符号非偶: (%0d,%0d)", ia, qa);
    end else begin
      $fwrite(sc_fd, "PASS kreset 首符号偶 out=(%0d,%0d)\n", ia, qa);
      $display("[CHECK] seq_start 复位 k 不变量 PASS out=(%0d,%0d)", ia, qa);
    end
    $fclose(sc_fd);
  endtask

  task local_reset();
    @(negedge clk);
    rst_n = 0;
    code_in = 0;
    code_in_cnt = 0;
    seq_start = 0;
    sym_flush = 0;
    mod_sel = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // 喂 3 个 QPSK 符号 (无 ss 维持脏 k), 不采样
  task run_qpsk_dirty();
    for (int s = 0; s < 3; s++) begin
      @(negedge clk);
      code_in     = 2'b01;
      code_in_cnt = 2'b10;
      seq_start   = (s == 0);
      sym_flush   = 0;
      mod_sel     = 2'b00;
    end
    @(negedge clk);
    code_in_cnt = 0;
    seq_start   = 0;
  endtask

  // ss + QPSK 符号(0,0): 驱动并排空, 捕获唯一产出符号 (posedge+#1 采样)
  task apply_qpsk_start_capture(output int oi, output int oq);
    bit got;
    got = 0;
    oi  = 'x;
    oq  = 'x;
    @(negedge clk);
    code_in     = 2'b00;
    code_in_cnt = 2'b10;
    seq_start   = 1;
    sym_flush   = 0;
    mod_sel     = 2'b00;
    @(negedge clk);
    code_in_cnt = 0;
    seq_start   = 0;
    for (int j = 0; j < 6; j++) begin
      @(posedge clk);
      #1;
      if (sym_valid && !got) begin
        oi  = $signed(sym_i);
        oq  = $signed(sym_q);
        got = 1;
      end
    end
  endtask

endmodule
