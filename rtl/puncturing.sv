// =============================================================
// puncturing — HDT TX PHY 打孔模块 (链路第③模块)
//
// 规格: W1/modules/puncturing.md (frozen, spec_version 0.1)
//       接口契约: docs/integration/HANDOFF.md v0.1
//       协议: HDT Core Spec Vol6 PartB §3.4.4, Table 3.5
//
// 功能: 对 FEC 输出的 1/2 码流 (每拍 2bit {a1,a0}, a0 先发) 按编码率对应的
//   打孔模式逐位删/留, 把有效码率提到 2/3 / 3/4 / 15/16; 1/2 时模式 [1 1] 透传。
//   模式按发送序逐位施加: 相位 p 对应 a0, 相位 p+1 对应 a1。
//   `1`=保留, `0`=丢弃。每拍消耗 2 个输入位 → 相位 +2 (模 L 回绕)。
//
// 接口 (HANDOFF v0.1):
//   - valid_only, 无反压; 输出变长 0/1/2 bit/cycle (code_out + code_out_cnt)。
//   - code_out: LSB(bit0) 对齐发送序更早的位 (a0 侧); cnt<2 时高位无效。
//   - code_out_cnt: 本拍保留位数 0/1/2 (从 LSB 起取 cnt 位)。
//
// 流水: 0 级 (组合输出 + 1 级相位寄存器)。唯一寄存器是模式相位 phase,
//   在下一拍更新。seq_start 当拍把相位复位为 0 再施加首码对, 并锁存 punc_rate。
//
// 风格: 中文注释; 时序块非阻塞赋值一律加 #1; 异步复位同步释放, rst_n 低有效。
// =============================================================
`timescale 1ns / 1ps

module puncturing (
    input logic clk,
    input logic rst_n, // 异步复位同步释放, 低有效

    // ---- 上游: 来自 fec_encoder (2bit/cycle 并行, valid_only) ----
    input logic [1:0] code_in,        // {a1,a0}, bit0=a0 先发
    input logic       code_in_valid,  // 输入码对有效 (= FEC code_out_valid)
    input logic       seq_start,      // 序列首码对标志, 相位复位到 0, 锁存 punc_rate
    input logic [1:0] punc_rate,      // 00=1/2 01=2/3 10=3/4 11=15/16; seq_start 拍锁存

    // ---- 下游: 变长 0/1/2 bit/cycle (打孔后码流) -> symbol_mapper ----
    output logic [1:0] code_out,      // 保留位, LSB 对齐发送序更早的位; cnt<2 时高位无效
    output logic [1:0] code_out_cnt  // 本拍有效位数 0/1/2
);

  // ------------------------------------------------------------
  // 编码率编码 (HANDOFF §1.5 / spec Table 3.5)
  // ------------------------------------------------------------
  // 命名: verible parameter-name-style 要求 UpperCamelCase, 名中不得含下划线。
  localparam logic [1:0] RateHalf = 2'b00;  // 1/2
  localparam logic [1:0] Rate2of3 = 2'b01;  // 2/3
  localparam logic [1:0] Rate3of4 = 2'b10;  // 3/4
  localparam logic [1:0] Rate15of16 = 2'b11;  // 15/16

  // ------------------------------------------------------------
  // 打孔模式常量 (发送序, 索引 0 = 模式首位, 对应序列首个 a0)
  //   存为 30bit 向量, bit[i] = 模式第 i 位 (i 从 0 起)。短模式高位补 0 (不会被索引到)。
  //   `1`=保留 / `0`=丢弃, 与 Table 3.5 逐位一致 (spec §7.5 已人核对)。
  //
  // 位宽依据: 最长模式 15/16 为 30 位, 故统一用 30bit 向量承载所有模式。
  // 写法说明: 用拼接 {第29位, ..., 第0位}, 从左到右是 bit29→bit0, 故把模式
  //   逐位倒着写以使 bit0 = 模式首位。这里直接用 30'b... 二进制字面量, 最左是 bit29。
  // ------------------------------------------------------------
  // 模式 (发送序, 首位在左):
  //   2/3 : 1 1 0 1
  //   3/4 : 1 1 0 1 0 1
  //  15/16: 1 1 0 1 1 0 1 0 1 0 0 1 0 1 0 1 1 0 1 0 0 1 0 1 0 1 1 0 0 1
  // 转成 bit0=首位的向量: 把上面序列按 bit0,bit1,... 填, 即二进制字面量需镜像书写。

  // 2/3 模式: 发送序 [1 1 0 1] -> bit0=1 bit1=1 bit2=0 bit3=1, 高位补0
  localparam logic [29:0] Pat2of3 = 30'b00_0000_0000_0000_0000_0000_0000_1011;
  //                                        bit3..bit0 = 1011 (=bit3=1,bit2=0,bit1=1,bit0=1)

  // 3/4 模式: 发送序 [1 1 0 1 0 1] -> bit0..bit5 = 1,1,0,1,0,1
  //   即 bit5..bit0 = 1 0 1 0 1 1 = 6'b101011
  localparam logic [29:0] Pat3of4 = 30'b00_0000_0000_0000_0000_0000_0010_1011;

  // 15/16 模式: 发送序 (position0 在最左, position i = bit[i]), 逐位对回 Table 3.5:
  //   pos:0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29
  //   bit:1 1 0 1 1 0 1 0 1 0 0  1  0  1  0  1  1  0  1  0  0  1  0  1  0  1  1  0  0  1
  //   关键: position14=0 (丢), position15=1 (留)。
  //   写成 bit29..bit0 (把上面 bit 行倒序):
  //   1 0 0 1 1 0 1 0 1 0 0 1 0 1 1 0 1 0 1 0 0 1 0 1 0 1 0 1 1 1
  localparam logic [29:0] Pat15of16 = 30'b10_0110_1010_0101_1010_1001_0101_1011;

  // ------------------------------------------------------------
  // 模式长度 L (按 punc_rate)
  // ------------------------------------------------------------
  // 位宽依据: 最大 L=30, 需 5bit。
  function automatic logic [4:0] pat_len(input logic [1:0] rate);
    unique case (rate)
      RateHalf:   pat_len = 5'd2;
      Rate2of3:   pat_len = 5'd4;
      Rate3of4:   pat_len = 5'd6;
      Rate15of16: pat_len = 5'd30;
      default:    pat_len = 5'd2;  // 不可达, 兜底防 latch
    endcase
  endfunction

  // 选模式向量
  function automatic logic [29:0] pat_vec(input logic [1:0] rate);
    unique case (rate)
      RateHalf:   pat_vec = 30'h3FFF_FFFF;  // 全 1 (透传); 任意相位两位都保留
      Rate2of3:   pat_vec = Pat2of3;
      Rate3of4:   pat_vec = Pat3of4;
      Rate15of16: pat_vec = Pat15of16;
      default:    pat_vec = 30'h3FFF_FFFF;  // 不可达, 兜底
    endcase
  endfunction

  // ------------------------------------------------------------
  // 相位寄存器 (1 级)
  //   phase ∈ [0, L-2], 每个 valid 拍 +2 回绕。由于从 0 起步、步长 2、L 偶数,
  //   phase 恒为偶数且 ≤ L-2, 故 phase 与 phase+1 都是合法模式索引 (< L)。
  // 位宽依据: 最大 phase 值 = L-2 = 28, 需 5bit。
  // ------------------------------------------------------------
  logic [4:0] phase;

  // 本拍生效的率 / 相位 (seq_start 当拍用新率+相位0)
  logic [1:0] eff_rate;  // 本拍施加所用率
  logic [4:0] eff_phase;  // 本拍施加所用相位
  logic [4:0] eff_len;  // 本拍率对应模式长 L

  // 锁存的率寄存器 (序列内保持)
  logic [1:0] rate_reg;

  always_comb begin
    // seq_start 当拍: 用输入 punc_rate 与相位 0; 否则用已锁存率与当前相位寄存器
    if (seq_start) begin
      eff_rate  = punc_rate;
      eff_phase = 5'd0;
    end else begin
      eff_rate  = rate_reg;
      eff_phase = phase;
    end
    eff_len = pat_len(eff_rate);
  end

  // ------------------------------------------------------------
  // 组合: 取相位处两位模式掩码, 对 {a0,a1} 判定保留, 打包输出
  //   a0 = code_in[0] (发送序更早), 模式位 = pat[eff_phase]
  //   a1 = code_in[1],               模式位 = pat[eff_phase+1]
  //   输出 LSB 对齐发送序更早的保留位:
  //     - 两位都留: code_out={a1,a0}, cnt=2
  //     - 只留 a0 : code_out[0]=a0,   cnt=1
  //     - 只留 a1 : code_out[0]=a1,   cnt=1 (a1 是该拍唯一保留位, 放 LSB)
  //     - 都丢    : cnt=0
  // ------------------------------------------------------------
  logic [29:0] cur_pat;
  logic        keep_a0;  // 模式: a0 是否保留
  logic        keep_a1;  // 模式: a1 是否保留
  logic        a0_bit;
  logic        a1_bit;

  logic [ 1:0] out_data_c;
  logic [ 1:0] out_cnt_c;

  always_comb begin
    cur_pat = pat_vec(eff_rate);
    a0_bit = code_in[0];
    a1_bit = code_in[1];

    // 取相位处掩码位 (eff_phase, eff_phase+1 均合法索引)
    // 用变量右移再取最低位, 等价于变量下标位选; iverilog 不支持 always_* 内的
    // 变量常量位选 (会把所有位算进去), 故改此写法。结果 1-bit, & 1'b1 后位宽匹配。
    keep_a0 = (cur_pat >> eff_phase) & 1'b1;
    keep_a1 = (cur_pat >> (eff_phase + 5'd1)) & 1'b1;

    // 默认值 (防 latch / 覆盖所有路径)
    out_data_c = 2'b00;
    out_cnt_c = 2'b00;

    if (code_in_valid) begin
      // 按发送序逐位施加: 先 a0 后 a1
      if (keep_a0 && keep_a1) begin
        // 两位都留: LSB=a0 (更早), 高位=a1
        out_data_c = {a1_bit, a0_bit};
        out_cnt_c  = 2'd2;
      end else if (keep_a0 && !keep_a1) begin
        // 只留 a0
        out_data_c = {1'b0, a0_bit};
        out_cnt_c  = 2'd1;
      end else if (!keep_a0 && keep_a1) begin
        // 只留 a1 (唯一保留位放 LSB)
        out_data_c = {1'b0, a1_bit};
        out_cnt_c  = 2'd1;
      end else begin
        // 两位全丢: 气泡
        out_data_c = 2'b00;
        out_cnt_c  = 2'd0;
      end
    end
    // code_in_valid 低: 保持默认 0 输出 (无输入不产出)
  end

  // ---- 组合输出 (0 级流水) ----
  // 复位期钳 0 (HANDOFF §1.3: 复位期间 code_out / code_out_cnt 为 0), 不依赖上游驱动。
  assign code_out     = rst_n ? out_data_c : 2'b00;
  assign code_out_cnt = rst_n ? out_cnt_c : 2'b00;

  // ------------------------------------------------------------
  // 时序: 相位推进 + 率锁存
  //   - seq_start 拍: 锁存 punc_rate; 本拍以相位 0 施加, 下一拍相位 = (0+2) 回绕。
  //   - 普通 valid 拍: 相位 +2 回绕。
  //   - 气泡拍 (code_in_valid 低): 相位保持不前进 (HANDOFF §1.2)。
  // ------------------------------------------------------------
  // 下一相位 (本拍消耗 2 位后的相位)
  logic [4:0] next_phase;
  logic [4:0] adv_phase;  // eff_phase + 2

  always_comb begin
    adv_phase  = eff_phase + 5'd2;
    // 回绕: 到达 L 则回 0 (eff_len ∈ {2,4,6,30}, 偶数, adv 恰可命中 L)
    next_phase = (adv_phase >= eff_len) ? 5'd0 : adv_phase;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase    <= #1 5'd0;
      rate_reg <= #1 RateHalf;  // 复位默认 1/2, 等 seq_start 重锁存
    end else begin
      if (seq_start) begin
        // 序列首拍: 锁存率; 若该拍 valid 则相位前进到 next_phase(基于相位0), 否则保持 0
        rate_reg <= #1 punc_rate;
        phase    <= #1 code_in_valid ? next_phase : 5'd0;
      end else if (code_in_valid) begin
        // 普通数据拍: 相位 +2 回绕
        phase <= #1 next_phase;
      end
      // 气泡拍 (非 seq_start 且 !code_in_valid): 相位与率保持
    end
  end

endmodule
