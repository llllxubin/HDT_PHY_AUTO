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

def gen_not_implemented(name):
    def _f(): raise NotImplementedError(f"{name} 激励待实现 (W1 未 frozen)")
    return _f

GENERATORS = {
    "fec_encoder":      gen_fec_encoder,
    "interval_spacing": gen_not_implemented("interval_spacing"),
    "puncturing":       gen_not_implemented("puncturing"),
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
