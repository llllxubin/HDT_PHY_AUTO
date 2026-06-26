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

def gen_symbol_mapper():
    # symbol_mapper 激励 (W1/modules/symbol_mapper.md frozen §4.2).
    # 序列体 token (与共享 main() 一行一 token 兼容):
    #   line0: "M<mod_sel>"  调制 0=π/4QPSK 1=8PSK 2=16QAM (kstart 锁存, 序列内不变)
    #   line1..: "<b0><b1><cnt><ss><fl>" 5字符/拍:
    #       b0=code_in[0](先收到的位), b1=code_in[1](后到), cnt=有效位数 0/1/2,
    #       ss=seq_start(该拍清 n 复位 k), fl=sym_flush(末符号补0产出)
    #   每序列首拍 ss=1 (锁存 mod, 复位 k). 序列末多发几拍 cnt=0 空拍由 TB 排空流水(此处不编码).
    # 覆盖 spec §4.2: 三调制全 32 入口 / 偶奇交替 / 中途 ss 复位 k / flush 各补0位数 /
    #   +1.0 饱和 / 16QAM 四象限极值+内点 / cnt=0 气泡 / cnt=1与2混合攒符号 / 背靠背异 mod。
    SB = {0: 2, 1: 3, 2: 4}
    seqs = []

    def emit(mod, cycles):
        # cycles: list of (b0,b1,cnt,ss,fl)
        body = [f"M{mod}"]
        for (b0, b1, cnt, ss, fl) in cycles:
            body.append(f"{b0}{b1}{cnt}{ss}{fl}")
        seqs.append(body)

    def pack2(bits, ss0=1):
        # 两位/拍 (cnt=2); 奇数尾位用 cnt=1; 首拍带 ss0
        cyc = []
        i = 0
        first = True
        while i < len(bits):
            ss = 1 if first else 0
            first = False
            if i + 1 < len(bits):
                cyc.append((bits[i], bits[i + 1], 2, ss, 0))
                i += 2
            else:
                cyc.append((bits[i], 0, 1, ss, 0))
                i += 1
        return cyc

    def pack1(bits, ss0=1):
        # 一位/拍 (cnt=1)
        cyc = []
        for idx, b in enumerate(bits):
            cyc.append((b, 0, 1, 1 if idx == 0 else 0, 0))
        return cyc

    def groups_to_bits(groups):
        # groups: list of tuple(bit...) 按 n0..(n0=先发=MSB) -> 扁平到达序位流
        bits = []
        for g in groups:
            bits.extend(g)
        return bits

    # ---- 1. 三调制全查表入口遍历 ----
    # QPSK: 每组合连发两次 -> 各组合都落在 偶(k even) 与 奇(k odd) 位置 => x_qpsk 8 入口全覆盖
    qpsk_groups = []
    for g in [(0, 0), (0, 1), (1, 0), (1, 1)]:
        qpsk_groups += [g, g]
    emit(0, pack2(groups_to_bits(qpsk_groups)))

    # 8PSK: 8 组合各一次 (parity 无关)
    psk8_groups = [(a, b, c) for a in (0, 1) for b in (0, 1) for c in (0, 1)]
    emit(1, pack2(groups_to_bits(psk8_groups)))

    # 16QAM: 16 组合各一次 (含四象限极值 0000/1010 与内点 0101/1111)
    qam_groups = [(a, b, c, d) for a in (0, 1) for b in (0, 1)
                  for c in (0, 1) for d in (0, 1)]
    emit(2, pack2(groups_to_bits(qam_groups)))

    # ---- 2. π/4 QPSK 偶/奇相位交替: 长串交替验证 k 奇偶切换 ----
    emit(0, pack2([0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 1]))  # 8 符号 k=0..7

    # ---- 3. 中途 seq_start 复位 k (序列干净, 无残留) ----
    # 先 3 个 QPSK 符号 (k=0,1,2), 再 ss 复位 -> 其后首符号回偶表
    c = pack2([0, 1, 1, 0, 1, 1])  # 3 符号: (0,1)(1,0)(1,1)
    c += [(0, 0, 2, 1, 0)]          # ss 复位 k -> 该符号 (0,0) 必为偶
    c += [(0, 1, 2, 0, 0)]          # 下一符号 (0,1) 奇
    emit(0, c)

    # ---- 3b. 中途 seq_start 携残留 (判定: 新序列 n=0 丢弃残留 1bit) ----
    # 喂 1bit 残留(未成符号) 后 ss 带新符号 bit; golden 丢弃残留 -> 首符号 (1,1) 偶。
    c = [(1, 0, 1, 1, 0)]           # 残留 1 bit (b0=1)
    c += [(1, 1, 2, 1, 0)]          # ss: 丢弃残留, 新符号 (1,1) 偶
    c += [(0, 0, 2, 0, 0)]          # 次符号 (0,0) 奇
    emit(0, c)

    # ---- 4. flush 各补 0 位数 ----
    # QPSK pad1: 喂 1bit 再 flush
    emit(0, [(1, 0, 1, 1, 0), (0, 0, 0, 0, 1)])
    # 8PSK pad1: 喂 2bit 再 flush ; pad2: 喂 1bit 再 flush
    emit(1, [(0, 1, 2, 1, 0), (0, 0, 0, 0, 1)])
    emit(1, [(1, 0, 1, 1, 0), (0, 0, 0, 0, 1)])
    # 16QAM pad1: 3bit; pad2: 2bit; pad3: 1bit
    emit(2, [(1, 0, 2, 1, 0), (1, 0, 1, 0, 0), (0, 0, 0, 0, 1)])  # 3 bit -> pad1
    emit(2, [(1, 1, 2, 1, 0), (0, 0, 0, 0, 1)])                   # 2 bit -> pad2
    emit(2, [(1, 0, 1, 1, 0), (0, 0, 0, 0, 1)])                   # 1 bit -> pad3
    # flush 累加器恰空 (whole 符号刚产完再 flush): 不应再产符号
    emit(0, [(0, 0, 2, 1, 0), (0, 0, 0, 0, 1)])  # 1 符号 (0,0) + 空 flush

    # ---- 5. +1.0 饱和点 (PSK +轴): QPSK 奇(1,0)=+1, 奇(0,0)=+j; 8PSK 000=+1, 011=+j ----
    # QPSK: 让 (1,0) 落奇位 -> +511; 先垫一符号
    emit(0, pack2([0, 0, 1, 0, 0, 0]))  # 符号0 (0,0)偶; 符号1 (1,0)奇=+1饱和; 符号2 (0,0)偶
    emit(1, pack2([0, 0, 0, 0, 1, 1]))  # 8PSK 000=+1 饱和, 011=+j 饱和

    # ---- 6. 16QAM 四象限极值 + 内点 (显式再点一遍) ----
    emit(2, pack2(groups_to_bits([(0, 0, 0, 0), (1, 0, 1, 0), (0, 1, 0, 1), (1, 1, 1, 1)])))

    # ---- 7. 输入气泡 cnt=0: 累加器不前进 ----
    c = [(0, 1, 2, 1, 0), (0, 0, 0, 0, 0), (1, 0, 2, 0, 0),
         (0, 0, 0, 0, 0), (1, 1, 2, 0, 0)]  # 3 符号, 中间夹气泡
    emit(0, c)

    # ---- 8. cnt=1 与 cnt=2 混合攒符号边界 (16QAM 需 4bit: 2+2 / 1+1+1+1 / 2+1+1) ----
    emit(2, [(0, 0, 2, 1, 0), (1, 0, 2, 0, 0)])                         # 2+2 -> 0010
    emit(2, pack1([0, 0, 1, 0]))                                        # 1+1+1+1 -> 0010
    emit(2, [(0, 0, 2, 1, 0), (1, 0, 1, 0, 0), (0, 0, 1, 0, 0)])        # 2+1+1 -> 0010
    # QPSK 跨拍 cnt=1 攒符号
    emit(0, [(0, 0, 1, 1, 0), (1, 0, 1, 0, 0)])                         # 1+1 -> (0,1)

    # ---- 9. 背靠背两序列不同 mod_sel (kstart 重锁存) ----
    emit(0, pack2(groups_to_bits([(0, 1), (1, 0)])))
    emit(1, pack2(groups_to_bits([(1, 0, 1), (0, 1, 1)])))
    emit(2, pack2(groups_to_bits([(1, 1, 0, 0), (0, 0, 1, 1)])))
    emit(0, pack2(groups_to_bits([(1, 1), (0, 0)])))

    # ---- 10. 随机加强 (各 mod 混合 + 偶发气泡 + 偶发末符号残留+flush) ----
    # 单序列里把"完整 bits + 可选残留"一次性扁平到一个 ss-only-首拍 的 cycle 流, 避免 ss 误置。
    random.seed(20260626)
    for _ in range(40):
        mod = random.randint(0, 2)
        sb = SB[mod]
        nsym = random.randint(1, 8)
        nbits = nsym * sb
        do_flush = random.random() < 0.4
        rem = random.randint(1, sb - 1) if do_flush else 0
        bits = [random.randint(0, 1) for _ in range(nbits + rem)]
        cyc = pack2(bits) if random.random() < 0.7 else pack1(bits)
        # 偶发气泡插入 (cnt=0, 不前进)
        if random.random() < 0.5 and len(cyc) > 1:
            pos = random.randint(1, len(cyc) - 1)
            cyc.insert(pos, (0, 0, 0, 0, 0))
        if do_flush:
            cyc.append((0, 0, 0, 0, 1))  # flush: 补齐尾部 rem 位残留
        emit(mod, cyc)

    return seqs

def gen_not_implemented(name):
    def _f(): raise NotImplementedError(f"{name} 激励待实现 (W1 未 frozen)")
    return _f

GENERATORS = {
    "fec_encoder":      gen_fec_encoder,
    "interval_spacing": gen_not_implemented("interval_spacing"),
    "puncturing":       gen_puncturing,
    "symbol_mapper":    gen_symbol_mapper,
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
