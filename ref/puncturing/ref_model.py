#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puncturing 模块 Python 参考模型 (verify 侧黄金模型, 判定基准)

权威来源 (独立按 spec 推导, 不窥探 rtl 内部实现):
  W1/modules/puncturing.md (frozen, spec_version 0.1) §1, Table 3.5
  docs/integration/HANDOFF.md v0.1 §1.2 / §1.5

模型语义 (黑盒, 仅依赖 spec/HANDOFF):
- 输入: FEC 输出码流, 按发送序 [a0, a1, a0, a1, ...] (a0 先发).
  每 cycle DUT 收一个码对 {a1,a0}; 码流上 a0=偶相位, a1=奇相位.
- 打孔模式按 punc_rate 选取 (Table 3.5), 1=保留 / 0=丢弃.
- 模式相位从序列起点 (seq_start) 复位为 0, 每消耗 1 个输入位 +1, 模式长 L 回绕.
- 序列末按到达位数自然截断 (无需补齐整周期).
- rate=1/2 模式 [1,1]: 透传 (cnt 恒 2, code_out == code_in).
- code_out: bit0(LSB) 对齐发送序更早的位 (a0 侧); cnt<2 时高位无效, 保留位 LSB 起打包.
"""

# Table 3.5 打孔模式 (发送序; index0=a0; 1=保留 0=丢弃)
PATTERNS = {
    0: [1, 1],                                           # 1/2  L=2  K=2 (不打孔/透传)
    1: [1, 1, 0, 1],                                     # 2/3  L=4  K=3
    2: [1, 1, 0, 1, 0, 1],                               # 3/4  L=6  K=4
    3: [1, 1, 0, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1,  # 15/16 L=30 K=16
        1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1],
}


def pattern(rate):
    """返回 punc_rate 对应打孔模式 (list of 0/1)."""
    if rate not in PATTERNS:
        raise ValueError(f"非法 punc_rate: {rate}")
    return PATTERNS[rate]


def puncture_cycles(pairs, rate):
    """
    cycle 级期望 (与 DUT 变长输出逐拍对齐).
    pairs: list of (a0, a1), 发送序 a0 先.
    返回 [(cnt, code_out_val), ...]:
      - cnt: 本拍有效位数 0/1/2
      - code_out_val: 2bit 整数, 保留位从 LSB 起打包 (cnt<2 高位补0)
    打包规则 (HANDOFF §1.2):
      两位都留 -> cnt=2, val={a1,a0}
      仅 a0 留 -> cnt=1, val[0]=a0
      仅 a1 留 -> cnt=1, val[0]=a1 (压到 LSB)
      都丢   -> cnt=0, val=0
    """
    p = pattern(rate)
    L = len(p)
    phase = 0
    out = []
    for (a0, a1) in pairs:
        bits = []
        if p[phase % L] == 1:
            bits.append(a0 & 1)
        if p[(phase + 1) % L] == 1:
            bits.append(a1 & 1)
        val = 0
        for j, b in enumerate(bits):
            val |= b << j
        out.append((len(bits), val))
        phase = (phase + 2) % L
    return out


def puncture_stream(in_bits, rate):
    """
    序列级保留位流 (验证保序/守恒/恒等不变量).
    in_bits: 发送序位流 [a0, a1, a0, a1, ...]; 起点相位 0, 末尾按到达位数截断.
    """
    p = pattern(rate)
    L = len(p)
    return [b for i, b in enumerate(in_bits) if p[i % L] == 1]
