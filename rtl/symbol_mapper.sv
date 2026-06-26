// =====================================================================
// symbol_mapper —— 蓝牙 HDT PHY TX 链路第④模块 (符号域入口)
// 权威规格: W1/modules/symbol_mapper.md (status=frozen)
// 功能: 把 puncturing 的变长比特流 (0/1/2 bit/cycle) 按 mod_sel 每
//       log2(M) bit 攒成一个符号 bit 组, 查星座 ROM 输出复符号 I/Q。
//   mod_sel: 00=π/4 QPSK(SB=2) / 01=8PSK(SB=3) / 10=16QAM(SB=4)
// 定点: I/Q 各 10bit 有符号 Q0.9 (value=code/512), +1.0 饱和到 +511。
// 流水线: 查表组合 + 1 级输出寄存 (spec §5)。
// 时钟: 48MHz 单一时钟域, 无 CDC; 异步复位同步释放(由外部保证), 低有效。
// =====================================================================
module symbol_mapper (
    input logic clk,
    input logic rst_n, // 异步复位同步释放, 低有效

    // ---- 上游: 来自 puncturing (valid_only, 不反压) ----
    input logic [1:0] code_in,      // bit0=发送序更早的位
    input logic [1:0] code_in_cnt,  // 本拍有效位数 0/1/2 (LSB起)
    input logic       seq_start,    // 序列/PHY Interval 首符号: k 复位 0
    input logic       sym_flush,    // 末符号补 0 凑齐并产出

    // ---- 配置 (kstart 锁存, 序列内不变) ----
    input logic [1:0] mod_sel,  // 00/01/10

    // ---- 下游: 符号 I/Q -> symbol_assembler (valid_only) ----
    output logic signed [9:0] sym_i,     // Q0.9
    output logic signed [9:0] sym_q,     // Q0.9
    output logic              sym_valid
);

  // -----------------------------------------------------------------
  // 量化码常量 (spec §1 量化码表, 已人核对; 逐 position 对回, 不在线重算)
  //   ±0.70710678 -> ±362 ; +1.0 -> +511(饱和不回绕) / -1.0 -> -512
  //   16QAM ÷√10 吸收进表常量: ±0.31623 -> ±162 ; ±0.94868 -> ±486
  // -----------------------------------------------------------------
  localparam logic signed [9:0] SqP = 10'sd362;  // +√2/2
  localparam logic signed [9:0] SqN = -10'sd362;  // -√2/2
  localparam logic signed [9:0] UnP = 10'sd511;  // +1.0 饱和到 +511
  localparam logic signed [9:0] UnN = -10'sd512;  // -1.0 精确
  localparam logic signed [9:0] ZeroV = 10'sd0;  // 0
  localparam logic signed [9:0] QamA = 10'sd162;  // +1/√10
  localparam logic signed [9:0] QamAn = -10'sd162;  // -1/√10
  localparam logic signed [9:0] QamB = 10'sd486;  // +3/√10
  localparam logic signed [9:0] QamBn = -10'sd486;  // -3/√10

  // -----------------------------------------------------------------
  // 状态寄存器
  //   acc_q  : bit 累加器 (移位寄存器, 先收到的 bit 经逐次左移占 MSB,
  //            即对齐 Table 行序 n0=MSB)
  //   cnt_q  : 累加器中已存的有效 bit 数 (0..SB-1)
  //   kpar_q : π/4 QPSK 的 k 奇偶 (仅 QPSK 使用); seq_start 复位 0
  // -----------------------------------------------------------------
  logic        [3:0] acc_q;
  logic        [2:0] cnt_q;
  logic              kpar_q;

  // 组合中间量
  logic        [2:0] sb;  // 每符号 bit 数 SB
  logic        [3:0] base_acc;
  logic        [2:0] base_cnt;
  logic              base_kpar;
  logic        [3:0] t_acc;
  logic        [2:0] t_cnt;
  logic              norm_emit;
  logic        [3:0] norm_idx;
  logic              emit_valid;
  logic        [3:0] emit_idx;
  logic        [3:0] acc_next;
  logic        [2:0] cnt_next;
  logic              kpar_next;
  logic signed [9:0] rom_i;
  logic signed [9:0] rom_q;

  // -----------------------------------------------------------------
  // SB: 每符号 bit 数 (由 mod_sel 决定)
  // -----------------------------------------------------------------
  always_comb begin
    case (mod_sel)
      2'b00:   sb = 3'd2;  // π/4 QPSK
      2'b01:   sb = 3'd3;  // 8PSK
      2'b10:   sb = 3'd4;  // 16QAM
      default: sb = 3'd2;  // 11 保留, 取 QPSK 避免 latch
    endcase
  end

  // -----------------------------------------------------------------
  // 比特累加 + 符号产出 (组合 next-state)
  //  - seq_start 当拍: 清空累加器与 k 奇偶 (新序列 n 复位)
  //  - 位序命门: code_in[0] 为发送序更早的位, 先移入; 每移入 1 bit 整体
  //    左移一位, 故累加满 SB 位后 n0(最先收到)落在 MSB, 与 Table 行序一致。
  //  - 单拍最多 2 个输入 bit, SB>=2, 故单拍最多产出 1 个符号。
  // -----------------------------------------------------------------
  always_comb begin
    base_acc  = seq_start ? 4'd0 : acc_q;
    base_cnt  = seq_start ? 3'd0 : cnt_q;
    base_kpar = seq_start ? 1'b0 : kpar_q;

    t_acc     = base_acc;
    t_cnt     = base_cnt;
    norm_emit = 1'b0;
    norm_idx  = 4'd0;

    // 气泡: code_in_cnt==0 拍累加器不前进、不产出
    if (code_in_cnt != 2'd0) begin
      // bit0 (发送序更早的位, 先移入)
      t_acc = {t_acc[2:0], code_in[0]};
      t_cnt = t_cnt + 3'd1;
      if (t_cnt == sb) begin
        norm_emit = 1'b1;
        norm_idx  = t_acc;  // 低 SB 位即符号 bit 组 (n0 在 MSB)
        t_acc     = 4'd0;
        t_cnt     = 3'd0;
      end
      // bit1 (仅当本拍两位均有效)
      if (code_in_cnt == 2'd2) begin
        t_acc = {t_acc[2:0], code_in[1]};
        t_cnt = t_cnt + 3'd1;
        if (t_cnt == sb) begin
          norm_emit = 1'b1;
          norm_idx  = t_acc;
          t_acc     = 4'd0;
          t_cnt     = 3'd0;
        end
      end
    end

    // flush: 末符号不足 SB bit 时补 0 凑齐并产出。
    //   左移 (SB - t_cnt) 位: 已收 bit 的 n0 移到 MSB, 低位补 0 即把缺失的
    //   较晚 bit (n 较大者) 置 0, 与 spec "末符号补 0 bit 凑齐" 一致。
    //   注: valid_only 单脉冲接口下, 同拍既产出整符号又留残余符号的输入
    //   不受支持 (FSM 保证 flush 拍至多产出 1 个符号)。
    if (sym_flush && (t_cnt != 3'd0)) begin
      emit_valid = 1'b1;
      emit_idx   = t_acc << (sb - t_cnt);
      acc_next   = 4'd0;
      cnt_next   = 3'd0;
    end else begin
      emit_valid = norm_emit;
      emit_idx   = norm_idx;
      acc_next   = t_acc;
      cnt_next   = t_cnt;
    end

    // π/4 QPSK: 每产出 1 符号翻转 k 奇偶 (其余调制不读取此位)
    kpar_next = base_kpar ^ emit_valid;
  end

  // -----------------------------------------------------------------
  // 星座 ROM (32 入口: QPSK 偶/奇各4 + 8PSK 8 + 16QAM 16)
  //   索引 = {mod_sel, (仅QPSK)base_kpar, 符号 bit 组 emit_idx}
  //   16QAM ÷√10 已吸收进表常量, 无在线除法/平方根。
  // -----------------------------------------------------------------
  always_comb begin
    rom_i = ZeroV;
    rom_q = ZeroV;
    case (mod_sel)
      // ---- π/4 QPSK (Table 7.4): 偶 k 与奇 k 用不同相位表 ----
      2'b00: begin
        case ({
          base_kpar, emit_idx[1:0]
        })
          // 偶符号 S_2k
          3'b000: begin
            rom_i = SqP;
            rom_q = SqP;
          end  // e^jπ/4
          3'b001: begin
            rom_i = SqN;
            rom_q = SqP;
          end  // e^j3π/4
          3'b010: begin
            rom_i = SqP;
            rom_q = SqN;
          end  // e^-jπ/4
          3'b011: begin
            rom_i = SqN;
            rom_q = SqN;
          end  // e^-j3π/4
          // 奇符号 S_2k+1 (偶基础 +π/4)
          3'b100: begin
            rom_i = ZeroV;
            rom_q = UnP;
          end  // e^jπ/2 = +j
          3'b101: begin
            rom_i = UnN;
            rom_q = ZeroV;
          end  // e^jπ  = -1
          3'b110: begin
            rom_i = UnP;
            rom_q = ZeroV;
          end  // e^0   = +1
          default: begin
            rom_i = ZeroV;
            rom_q = UnN;
          end  // e^-jπ/2 = -j
        endcase
      end
      // ---- 8PSK (Table 7.5) ----
      2'b01: begin
        case (emit_idx[2:0])
          3'b000: begin
            rom_i = UnP;
            rom_q = ZeroV;
          end  // e^0
          3'b001: begin
            rom_i = SqP;
            rom_q = SqP;
          end  // e^jπ/4
          3'b010: begin
            rom_i = SqN;
            rom_q = SqP;
          end  // e^j3π/4
          3'b011: begin
            rom_i = ZeroV;
            rom_q = UnP;
          end  // e^jπ/2
          3'b100: begin
            rom_i = SqP;
            rom_q = SqN;
          end  // e^-jπ/4
          3'b101: begin
            rom_i = ZeroV;
            rom_q = UnN;
          end  // e^-jπ/2
          3'b110: begin
            rom_i = UnN;
            rom_q = ZeroV;
          end  // e^-jπ
          default: begin
            rom_i = SqN;
            rom_q = SqN;
          end  // e^-j3π/4
        endcase
      end
      // ---- 16QAM (Table 7.6, ÷√10): I 由高 2 位, Q 由低 2 位 ----
      2'b10: begin
        case (emit_idx[3:0])
          4'h0: begin
            rom_i = QamBn;
            rom_q = QamBn;
          end  // -3-3j
          4'h1: begin
            rom_i = QamBn;
            rom_q = QamAn;
          end  // -3-1j
          4'h2: begin
            rom_i = QamBn;
            rom_q = QamB;
          end  // -3+3j
          4'h3: begin
            rom_i = QamBn;
            rom_q = QamA;
          end  // -3+1j
          4'h4: begin
            rom_i = QamAn;
            rom_q = QamBn;
          end  // -1-3j
          4'h5: begin
            rom_i = QamAn;
            rom_q = QamAn;
          end  // -1-1j
          4'h6: begin
            rom_i = QamAn;
            rom_q = QamB;
          end  // -1+3j
          4'h7: begin
            rom_i = QamAn;
            rom_q = QamA;
          end  // -1+1j
          4'h8: begin
            rom_i = QamB;
            rom_q = QamBn;
          end  // +3-3j
          4'h9: begin
            rom_i = QamB;
            rom_q = QamAn;
          end  // +3-1j
          4'ha: begin
            rom_i = QamB;
            rom_q = QamB;
          end  // +3+3j
          4'hb: begin
            rom_i = QamB;
            rom_q = QamA;
          end  // +3+1j
          4'hc: begin
            rom_i = QamA;
            rom_q = QamBn;
          end  // +1-3j
          4'hd: begin
            rom_i = QamA;
            rom_q = QamAn;
          end  // +1-1j
          4'he: begin
            rom_i = QamA;
            rom_q = QamB;
          end  // +1+3j
          default: begin
            rom_i = QamA;
            rom_q = QamA;
          end  // +1+1j
        endcase
      end
      default: begin
        rom_i = ZeroV;
        rom_q = ZeroV;
      end  // 保留
    endcase
  end

  // -----------------------------------------------------------------
  // 时序: 状态更新 + 1 级输出寄存
  //   复位期 sym_i/sym_q/sym_valid 全 0;
  //   非产出拍输出符号保持上一有效值 (valid_only: 仅 sym_valid 高时采样)。
  // -----------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_q     <= #1 4'd0;
      cnt_q     <= #1 3'd0;
      kpar_q    <= #1 1'b0;
      sym_i     <= #1 10'sd0;
      sym_q     <= #1 10'sd0;
      sym_valid <= #1 1'b0;
    end else begin
      acc_q     <= #1 acc_next;
      cnt_q     <= #1 cnt_next;
      kpar_q    <= #1 kpar_next;
      sym_valid <= #1 emit_valid;
      if (emit_valid) begin
        sym_i <= #1 rom_i;
        sym_q <= #1 rom_q;
      end
    end
  end

endmodule
