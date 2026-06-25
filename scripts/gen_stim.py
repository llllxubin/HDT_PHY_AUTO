#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通用激励生成入口
用法: python3 scripts/gen_stim.py --module fec_encoder --out sim/fec_encoder/stim_bits.txt
新增模块: 在 GENERATORS 字典注册函数即可, Makefile 不用改。
"""
import argparse, os, random, sys

def gen_fec_encoder():
    random.seed(20260623)
    seqs = []
    seqs.append([1])
    seqs.append([0])
    seqs.append([0]*16)
    seqs.append([1]*16)
    seqs.append([1,0]*8)
    seqs.append([1,1,0,1,0,0,1,1])
    for _ in range(40):
        n = random.randint(1, 64)
        seqs.append([random.randint(0,1) for _ in range(n)])
    return seqs

def gen_puncturing():
    # puncturing 激励 (W1/modules/puncturing.md frozen §4.2).
    # 每个序列体 = 单 token/行, 与共享 main() 的写法兼容:
    #   line0: "R<rate>"  序列码率 0/1/2/3 (seq_start 拍锁存)
    #   line1..: "<a0><a1><v>" 3字符 cycle: a0,a1,valid(1=有效码对, 0=气泡拍)
    # seq_start 隐含落在每序列首个 valid 拍 (TB 据此驱动). 气泡拍 v=0 数据无关.
    # 覆盖 spec §4.2 corner: 透传/最短序列(截断)/整周期/背靠背切率/15-16 跨周期/气泡/cnt两形态.
    random.seed(20260626)
    L = {0: 2, 1: 4, 2: 6, 3: 30}  # 各率模式长度 (用于构造"整周期"与"截断"激励)

    def cyc(a0, a1, v=1):
        return f"{a0}{a1}{v}"

    def rand_cycles(n):
        return [cyc(random.randint(0, 1), random.randint(0, 1), 1) for _ in range(n)]

    seqs = []

    def seq(rate, body):
        seqs.append([f"R{rate}"] + body)

    # --- 1. rate=1/2 透传 (cnt 恒 2): 含全0/全1/交替/随机 ---
    seq(0, [cyc(0, 0)] * 4)
    seq(0, [cyc(1, 1)] * 4)
    seq(0, [cyc(0, 1), cyc(1, 0)] * 3)
    seq(0, rand_cycles(20))

    # --- 2. 每种率: 最短序列 (不足一个完整模式周期 -> 验证截断) ---
    for r in (1, 2, 3):
        seq(r, rand_cycles(1))                 # 仅 1 码对 (2 输入位 < L)
        seq(r, rand_cycles(max(1, L[r] // 4))) # 约 1/4 周期

    # --- 3. 每种率: 恰好整数个完整模式周期 (无截断对照) ---
    for r in (0, 1, 2, 3):
        pairs_per_period = L[r] // 2
        seq(r, rand_cycles(pairs_per_period * 2))  # 2 个完整周期

    # --- 4. 边界对齐: 首位(1)保留 / 模式含0位丢弃 都被激励 (随机已覆盖, 此处加确定性) ---
    for r in (1, 2, 3):
        seq(r, [cyc(1, 1)] * L[r])  # 全1输入跨多周期: 保留位即模式本身, cnt 两形态都出现

    # --- 5. 背靠背两序列且 rate 不同 (seq_start 相位复位 + punc_rate 重锁存) ---
    # 用相邻序列实现 (TB 序列间各发 seq_start). 这里穷举相邻不同率对.
    for r in (3, 2, 1, 0):
        seq(r, rand_cycles(8))

    # --- 6. 15/16 长模式跨多周期 (30bit 相位回绕): 长输入 ---
    seq(3, rand_cycles(50))   # 50 码对=100 位 > 3*L 周期, 充分回绕
    seq(3, [cyc(1, 1)] * 40)  # 确定性长序列

    # --- 7. 气泡拍 (code_in_valid 空拍): 模式相位保持不前进 ---
    # 在有效码对间插入 v=0 的气泡; 各率都测.
    for r in (0, 1, 2, 3):
        body = []
        for k in range(12):
            body.append(rand_cycles(1)[0])
            if k % 3 == 1:
                body.append(cyc(random.randint(0, 1), random.randint(0, 1), 0))  # 气泡
        seq(r, body)

    # --- 8. cnt=1 两形态 (a0留/a1丢 与 a0丢/a1留): 2/3 模式 [1,1,0,1] 天然产生 ---
    #   phase0..1 拍: keep,keep (cnt2); phase2..3 拍: drop a0, keep a1 (cnt1, a1-only)
    #   再加 3/4 模式 [1,1,0,1,0,1]: 出现 a0-only 与 a1-only.
    seq(1, rand_cycles(8))
    seq(2, rand_cycles(9))

    # --- 9. 大量随机 (各率混合, 加强覆盖率) ---
    for _ in range(40):
        r = random.randint(0, 3)
        n = random.randint(1, 40)
        body = []
        for _ in range(n):
            if random.random() < 0.12:
                body.append(cyc(random.randint(0, 1), random.randint(0, 1), 0))  # 偶发气泡
            else:
                body.append(rand_cycles(1)[0])
        seq(r, body)

    return seqs

def gen_not_implemented(name):
    def _f(): raise NotImplementedError(f"{name} 激励待实现 (W1 未 frozen)")
    return _f

GENERATORS = {
    "fec_encoder":      gen_fec_encoder,
    "interval_spacing": gen_not_implemented("interval_spacing"),
    "puncturing":       gen_puncturing,
    "symbol_mapper":    gen_not_implemented("symbol_mapper"),
    "symbol_assembler": gen_not_implemented("symbol_assembler"),
    "srrc_upsample":    gen_not_implemented("srrc_upsample"),
    "tx_ctrl_fsm":      gen_not_implemented("tx_ctrl_fsm"),
}

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--module", required=True)
    p.add_argument("--out",    required=True)
    a = p.parse_args()
    if a.module not in GENERATORS:
        print(f"[ERROR] 未注册模块: {a.module}"); sys.exit(1)
    seqs = GENERATORS[a.module]()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out,"w") as f:
        for si,seq in enumerate(seqs):
            f.write(f"# SEQ {si} len={len(seq)}\n")
            for b in seq: f.write(f"{b}\n")
    print(f"生成 {len(seqs)} 序列, {sum(len(s) for s in seqs)} bit -> {a.out}")

if __name__=="__main__": main()
