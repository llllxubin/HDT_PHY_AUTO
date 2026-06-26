#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
symbol_mapper 模块 Python 参考模型 (verify 侧黄金模型, 判定基准)

权威来源 (独立按 spec §1 推导, 不窥探 rtl 内部实现):
  W1/modules/symbol_mapper.md (frozen, spec_version 0.1) §1 (三表+量化码) / §2 (接口/位序)
  docs/integration/HANDOFF.md (上游 puncturing 变长 0/1/2 bit/cycle 边界)

铁律3 + 项目 memory: 量化金标按 spec §1 独立推导, 逐 position 对回 Table 7.4/7.5/7.6;
  不照抄 RTL, 不拿中途镜像串自洽印证。本文件末 __main__ 自检对回 spec §1 的硬数值。

定点 (spec §1/§5 KD-B): I/Q 各 10bit 有符号 Q0.9, value = code/512, 码 [-512, +511]。
  量化 = round-to-nearest(value*512), 再饱和到 [-512, +511]。饱和不回绕。
  对回 spec §1 硬码: 0->0 / ±0.70710678->±362 / +1.0->+511(饱和) / -1.0->-512 /
                     16QAM ÷√10: ±0.31623->±162 / ±0.94868->±486。

位序命门 (spec §2 决策✓): 同一符号内先收到的 bit 占该符号 bit 组 MSB (n0=MSB)。
  code_in[0] (LSB) 为发送序更早的位, 先入累加器; 故 push 顺序 = b0 然后 b1。
  符号 bit 组 = (第1个收到的 bit 作 n0=MSB, ..., 最后收到的作 LSB)。

接口语义判定 (spec §1/§2, 非照抄 RTL):
  - seq_start: 序列首符号标志。spec §1「每终止符号序列后 n 复位 0」+ §2「k 复位 0」
    => seq_start 当拍清空未满 bit 累加器 (新序列 n=0) 且 k=0, 再处理本拍输入位。
  - sym_flush: spec §2「末符号若不足 log2(M) bit, 补 0 凑齐并产出」=> flush 时若累加器非空,
    高位... (按位序: 缺的是后到的 LSB 侧) 补 0 至 SB 位查表产出, 然后清空。累加器空则不产出。
"""

import math

# ---- 调制 -> 每符号 bit 数 SB ----
SB_BY_MOD = {0: 2, 1: 3, 2: 4}  # 0=π/4 QPSK, 1=8PSK, 2=16QAM


def quantize(v):
    """Q0.9 量化: round-to-nearest 再饱和 [-512,+511]; +1.0 饱和 +511 不回绕。"""
    code = math.floor(v * 512.0 + 0.5)  # round-half-up
    if code > 511:
        code = 511
    if code < -512:
        code = -512
    return code


def _q_iq(re, im):
    return (quantize(re), quantize(im))


# ============================================================
# Table 7.4 π/4 QPSK (2bit/符号). 偶符号 S_2k 与奇符号 S_2k+1 用不同相位表。
# 索引键 = (n0, n1), n0=MSB=先收到的 bit。相位 -> 单位圆点 (cos, sin)。
# ============================================================
def _angle_pt(theta):
    return _q_iq(math.cos(theta), math.sin(theta))


PI = math.pi
QPSK_EVEN = {  # S_2k (偶)
    (0, 0): _angle_pt(PI / 4),     # e^{jπ/4}   -> (+362,+362)
    (0, 1): _angle_pt(3 * PI / 4), # e^{j3π/4}  -> (-362,+362)
    (1, 0): _angle_pt(-PI / 4),    # e^{-jπ/4}  -> (+362,-362)
    (1, 1): _angle_pt(-3 * PI / 4),# e^{-j3π/4} -> (-362,-362)
}
QPSK_ODD = {  # S_2k+1 (奇, +π/4 相对偶, 落在轴上)
    (0, 0): _angle_pt(PI / 2),     # e^{jπ/2}=+j -> (0,+511)
    (0, 1): _angle_pt(PI),         # e^{jπ}=-1   -> (-512,0)
    (1, 0): _angle_pt(0.0),        # e^{0}=+1    -> (+511,0)  (+1.0 饱和+511)
    (1, 1): _angle_pt(-PI / 2),    # e^{-jπ/2}=-j-> (0,-512)
}

# ============================================================
# Table 7.5 8PSK (3bit/符号). 索引 (n0,n1,n2), n0=MSB。
# ============================================================
PSK8 = {
    (0, 0, 0): _angle_pt(0.0),        # e^0      -> (+511,0)
    (0, 0, 1): _angle_pt(PI / 4),     # e^{jπ/4} -> (+362,+362)
    (0, 1, 0): _angle_pt(3 * PI / 4), # e^{j3π/4}-> (-362,+362)
    (0, 1, 1): _angle_pt(PI / 2),     # e^{jπ/2}=+j -> (0,+511)
    (1, 0, 0): _angle_pt(-PI / 4),    # e^{-jπ/4}-> (+362,-362)
    (1, 0, 1): _angle_pt(-PI / 2),    # e^{-jπ/2}=-j-> (0,-512)
    (1, 1, 0): _angle_pt(-PI),        # e^{-jπ}=-1 -> (-512,0)
    (1, 1, 1): _angle_pt(-3 * PI / 4),# e^{-j3π/4}-> (-362,-362)
}

# ============================================================
# Table 7.6 16QAM (4bit/符号). 索引 (n0,n1,n2,n3), n0=MSB。
# 表给 (I,Q) ∈ {-3,-1,+1,+3}; 归一化 ÷√10; 量化 ±1/√10->±162, ±3/√10->±486。
# ============================================================
_SQRT10 = math.sqrt(10.0)
_QAM16_RAW = {
    (0, 0, 0, 0): (-3, -3), (1, 0, 0, 0): (+3, -3),
    (0, 0, 0, 1): (-3, -1), (1, 0, 0, 1): (+3, -1),
    (0, 0, 1, 0): (-3, +3), (1, 0, 1, 0): (+3, +3),
    (0, 0, 1, 1): (-3, +1), (1, 0, 1, 1): (+3, +1),
    (0, 1, 0, 0): (-1, -3), (1, 1, 0, 0): (+1, -3),
    (0, 1, 0, 1): (-1, -1), (1, 1, 0, 1): (+1, -1),
    (0, 1, 1, 0): (-1, +3), (1, 1, 1, 0): (+1, +3),
    (0, 1, 1, 1): (-1, +1), (1, 1, 1, 1): (+1, +1),
}
QAM16 = {k: _q_iq(i / _SQRT10, q / _SQRT10) for k, (i, q) in _QAM16_RAW.items()}


def lookup(mod_sel, bits, k_parity):
    """查表: bits = tuple 长度 SB (n0=MSB 先收到的 bit). k_parity 仅 QPSK 用 (0=偶,1=奇)。"""
    if mod_sel == 0:
        tab = QPSK_EVEN if (k_parity == 0) else QPSK_ODD
        return tab[bits]
    if mod_sel == 1:
        return PSK8[bits]
    if mod_sel == 2:
        return QAM16[bits]
    raise ValueError(f"非法 mod_sel: {mod_sel}")


def map_symbols(cycles, mod_sel):
    """
    逐符号金标。
    cycles: list of (b0, b1, cnt, ss, fl):
        b0 = code_in[0] (先收到的位), b1 = code_in[1] (后收到的位),
        cnt ∈ {0,1,2} 本拍有效位数 (从 LSB/b0 起), ss = seq_start, fl = sym_flush。
    mod_sel: 0/1/2 (序列内不变, kstart 锁存)。
    返回 [(sym_i, sym_q), ...] 按产出顺序。
    """
    SB = SB_BY_MOD[mod_sel]
    acc = []   # 累加器: 按到达顺序存 bit, acc[0]=最早=本符号 n0=MSB
    k = 0      # 符号索引, 仅 QPSK 用其奇偶; seq_start 复位 0
    out = []

    for (b0, b1, cnt, ss, fl) in cycles:
        if ss:
            # 新序列: n 复位 0 (清空未满累加器), k 复位 0
            acc = []
            k = 0
        # 移入本拍有效位 (b0 先, b1 后)
        if cnt >= 1:
            acc.append(b0 & 1)
        if cnt >= 2:
            acc.append(b1 & 1)
        # 攒满即产出 (每符号最多 1 次/拍, 见 spec: cnt<=2, SB>=2)
        while len(acc) >= SB:
            grp = tuple(acc[:SB])
            del acc[:SB]
            out.append(lookup(mod_sel, grp, k & 1))
            k += 1
        # flush: 末符号补 0 凑齐 (缺的是后到的 LSB 侧, 补 0)
        if fl and len(acc) > 0:
            grp = tuple(acc + [0] * (SB - len(acc)))
            acc = []
            out.append(lookup(mod_sel, grp, k & 1))
            k += 1
    return out


# ---- 自检: 硬码对回 spec §1 量化码 (非 gate, 仅人核对独立性) ----
if __name__ == "__main__":
    assert quantize(0.0) == 0
    assert quantize(0.70710678) == 362 and quantize(-0.70710678) == -362
    assert quantize(1.0) == 511 and quantize(-1.0) == -512
    assert quantize(0.31623) == 162 and quantize(-0.31623) == -162
    assert quantize(0.94868) == 486 and quantize(-0.94868) == -486
    # QPSK 偶 (0,0)=e^{jπ/4}
    assert QPSK_EVEN[(0, 0)] == (362, 362)
    assert QPSK_EVEN[(0, 1)] == (-362, 362)
    # QPSK 奇 (1,0)=+1 饱和, (0,1)=-1
    assert QPSK_ODD[(1, 0)] == (511, 0)
    assert QPSK_ODD[(0, 1)] == (-512, 0)
    assert QPSK_ODD[(0, 0)] == (0, 511)
    assert QPSK_ODD[(1, 1)] == (0, -512)
    # 8PSK 端点
    assert PSK8[(0, 0, 0)] == (511, 0)
    assert PSK8[(1, 1, 0)] == (-512, 0)
    assert PSK8[(0, 1, 1)] == (0, 511)
    # 16QAM 四象限极值 + 内点
    assert QAM16[(0, 0, 0, 0)] == (-486, -486)
    assert QAM16[(1, 0, 1, 0)] == (486, 486)
    assert QAM16[(0, 1, 0, 1)] == (-162, -162)
    assert QAM16[(1, 1, 1, 1)] == (162, 162)
    # +512 永不出现
    for tab in (QPSK_EVEN, QPSK_ODD, PSK8, QAM16):
        for (i, q) in tab.values():
            assert -512 <= i <= 511 and -512 <= q <= 511
    print("[ref_model self-check] PASS: 量化金标对回 spec §1 全部一致")
