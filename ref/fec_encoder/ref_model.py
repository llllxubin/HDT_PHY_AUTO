#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fec_encoder 参考模型 (golden)
HDT Core Spec Vol6 PartB §3.4.3, rate-1/2 卷积码, K=6
G0 = 1 + x^2 + x^4 + x^5   抽头 {0,2,4,5}
G1 = 1 + x + x^2 + x^3 + x^5 抽头 {0,1,2,3,5}

抽头映射已与 RTL 约定核对一致 (用户对照 Figure 3.10 确认):
  当前输入 bit 视为 x^0; enc_state[i] 保存前 i+1 个历史 bit。
  a0 = bit ^ s[1] ^ s[3] ^ s[4]
  a1 = bit ^ s[0] ^ s[1] ^ s[2] ^ s[4]
其中移位约定: s[0] 是最近一个历史 bit, 移位时 s = [bit, s0,s1,s2,s3] 取低5位。

本模型是判定基准, 必须与 RTL 抽头/移位约定严格一致, 否则比对失去意义。
"""

def fec_encode_sequence(data_bits):
    """
    对一个完整序列编码 (调用方已在末尾追加 5 个 0 termination, 或用下方 with_termination)。
    输入: data_bits = [0/1, ...]
    输出: [(a0, a1), ...] 每输入1bit产出一对
    """
    s = [0, 0, 0, 0, 0]  # s[0]=最近历史bit ... s[4]=最久
    out = []
    for bit in data_bits:
        b = bit & 1
        a0 = b ^ s[1] ^ s[3] ^ s[4]
        a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4]
        out.append((a0, a1))
        # 移位: 当前 bit 进入 s[0], 其余右移, 丢弃 s[4]
        s = [b, s[0], s[1], s[2], s[3]]
    return out, s


def fec_encode_with_termination(data_bits):
    """
    完整序列编码 = 数据 + 5个0 termination。
    返回 (码流 list[(a0,a1)], 末态 s)。末态应为全0 (不变量)。
    """
    full = list(data_bits) + [0, 0, 0, 0, 0]
    out, s = fec_encode_sequence(full)
    return out, s


def encode_to_flat_bits(data_bits):
    """码流展平为发送顺序 bit 序列 (a0 先发): [a0,a1,a0,a1,...]"""
    pairs, _ = fec_encode_with_termination(data_bits)
    flat = []
    for a0, a1 in pairs:
        flat.append(a0)
        flat.append(a1)
    return flat


if __name__ == "__main__":
    import sys, json
    # 用法: ref_model.py <input_bits_file>  输出 golden 到 stdout (每行一个 a0,a1)
    # input_bits_file: 每行一个 0/1, 代表一个序列的数据 bit (不含 termination)
    if len(sys.argv) < 2:
        # 自检: 全0输入5bit
        demo = [0, 0, 0, 0, 0]
        pairs, end = fec_encode_with_termination(demo)
        print("# self-test 全0输入:")
        for a0, a1 in pairs:
            print(f"{a0} {a1}")
        print(f"# 末态(应全0): {end}")
        # 不变量自检
        assert end == [0, 0, 0, 0, 0], "termination 后末态非全0!"
        # 长度不变量: (输入+5)*1 对
        assert len(pairs) == len(demo) + 5, "输出对数 != 输入+5"
        print("# 不变量自检通过")
        sys.exit(0)
    with open(sys.argv[1]) as f:
        data = [int(line.strip()) for line in f if line.strip() in ("0", "1")]
    pairs, end = fec_encode_with_termination(data)
    for a0, a1 in pairs:
        print(f"{a0} {a1}")
