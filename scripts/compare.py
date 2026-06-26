#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通用比对框架
用法: python3 scripts/compare.py --module fec_encoder --dump ... --stim ... --ref ...
退出码: 0=PASS, 非0=FAIL。新增模块在 COMPARATORS 注册即可。
"""
import argparse, importlib.util, os, sys

def compare_fec_encoder(stim_path, dump_path, ref_mod):
    def parse_seqs(path, is_dump):
        seqs, cur = [], None
        with open(path) as f:
            for line in f:
                line=line.strip()
                if line.startswith("# SEQ"):
                    if cur is not None: seqs.append(cur)
                    cur=[]
                elif line and not line.startswith("#"):
                    cur.append(tuple(int(x) for x in line.split()) if is_dump else int(line))
        if cur is not None: seqs.append(cur)
        return seqs
    if not os.path.exists(dump_path):
        return False, f"找不到RTL dump: {dump_path}"
    stim_seqs = parse_seqs(stim_path, False)
    dump_seqs = parse_seqs(dump_path, True)
    if len(stim_seqs) != len(dump_seqs):
        return False, f"序列数不符: 激励{len(stim_seqs)} vs RTL{len(dump_seqs)}"
    total = 0
    for si,(data,rtl) in enumerate(zip(stim_seqs, dump_seqs)):
        golden, end = ref_mod.fec_encode_with_termination(data)
        if end != [0,0,0,0,0]: return False, f"序列{si} golden末态非全0"
        if len(golden)!=len(rtl): return False, f"序列{si} 长度不符: golden{len(golden)} vs RTL{len(rtl)}"
        for k,(g,r) in enumerate(zip(golden,rtl)):
            if g!=r: return False, f"序列{si} 第{k}对失配: golden{g} vs RTL{r}"
        total+=len(golden)
    return True, f"{len(stim_seqs)}序列, {total}对全匹配, 0容差"

def compare_puncturing(stim_path, dump_path, ref_mod):
    # puncturing 逐 cycle 逐 bit 比对 (0 容差).
    # stim 序列体: line0="R<rate>"; line1.. = "<a0><a1><v>" (a0,a1,valid).
    # dump 序列体: 每个被驱动的 cycle 一行 "<cnt> <code_out_val>" (含气泡拍, 气泡=0 0).
    # golden 用 ref_mod.pattern 独立推导 (相位序列起点复位; 气泡拍 cnt=0 且相位不前进).
    def parse_stim(path):
        seqs, cur = [], None
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("# SEQ"):
                    if cur is not None:
                        seqs.append(cur)
                    cur = {"rate": None, "cyc": []}
                elif not line or line.startswith("#"):
                    continue
                elif line.startswith("R"):
                    cur["rate"] = int(line[1:])
                else:  # "<a0><a1><v>"
                    cur["cyc"].append((int(line[0]), int(line[1]), int(line[2])))
        if cur is not None:
            seqs.append(cur)
        return seqs

    def parse_dump(path):
        seqs, cur = [], None
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("# SEQ"):
                    if cur is not None:
                        seqs.append(cur)
                    cur = []
                elif line and not line.startswith("#"):
                    parts = line.split()
                    cur.append((int(parts[0]), int(parts[1])))  # (cnt, val)
        if cur is not None:
            seqs.append(cur)
        return seqs

    def golden_cycles(rate, cyc):
        p = ref_mod.pattern(rate)
        L = len(p)
        phase = 0
        out = []
        for (a0, a1, v) in cyc:
            if v == 0:
                out.append((0, 0))      # 气泡: 不产出, 相位保持不前进
                continue
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

    if not os.path.exists(dump_path):
        return False, f"找不到RTL dump: {dump_path}"
    stim_seqs = parse_stim(stim_path)
    dump_seqs = parse_dump(dump_path)
    if len(stim_seqs) != len(dump_seqs):
        return False, f"序列数不符: 激励{len(stim_seqs)} vs RTL{len(dump_seqs)}"
    total = 0
    for si, (s, rtl) in enumerate(zip(stim_seqs, dump_seqs)):
        golden = golden_cycles(s["rate"], s["cyc"])
        if len(golden) != len(rtl):
            return False, f"序列{si} cycle数不符: golden{len(golden)} vs RTL{len(rtl)}"
        for k, (g, r) in enumerate(zip(golden, rtl)):
            if g != r:
                return False, (f"序列{si} cycle{k} 失配(rate={s['rate']}): "
                               f"golden(cnt={g[0]},val={g[1]}) vs RTL(cnt={r[0]},val={r[1]})")
        total += len(golden)
    return True, f"{len(stim_seqs)}序列, {total}cycle 全匹配, 0容差"

def compare_symbol_mapper(stim_path, dump_path, ref_mod):
    # symbol_mapper 逐符号 0 容差比对量化金标 (spec §4.1).
    # stim 序列体: line0="M<mod>"; line1.. = "<b0><b1><cnt><ss><fl>" (5字符/拍).
    # dump 序列体: 每个 sym_valid=1 的符号一行 "<sym_i> <sym_q>" (有符号十进制).
    #   (含 TB 排空流水捕获的尾符号; 流水延迟无关, 仅比对有序符号列。)
    # golden 用 ref_mod.map_symbols 独立按 spec §1 推导, 逐符号 (i,q) 精确比对。
    def parse_stim(path):
        seqs, cur = [], None
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("# SEQ"):
                    if cur is not None:
                        seqs.append(cur)
                    cur = {"mod": None, "cyc": []}
                elif not line or line.startswith("#"):
                    continue
                elif line.startswith("M"):
                    cur["mod"] = int(line[1:])
                else:  # "<b0><b1><cnt><ss><fl>"
                    cur["cyc"].append((int(line[0]), int(line[1]), int(line[2]),
                                       int(line[3]), int(line[4])))
        if cur is not None:
            seqs.append(cur)
        return seqs

    def parse_dump(path):
        seqs, cur = [], None
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("# SEQ"):
                    if cur is not None:
                        seqs.append(cur)
                    cur = []
                elif line and not line.startswith("#"):
                    parts = line.split()
                    cur.append((int(parts[0]), int(parts[1])))  # (sym_i, sym_q)
        if cur is not None:
            seqs.append(cur)
        return seqs

    if not os.path.exists(dump_path):
        return False, f"找不到RTL dump: {dump_path}"
    stim_seqs = parse_stim(stim_path)
    dump_seqs = parse_dump(dump_path)
    if len(stim_seqs) != len(dump_seqs):
        return False, f"序列数不符: 激励{len(stim_seqs)} vs RTL{len(dump_seqs)}"
    total = 0
    for si, (s, rtl) in enumerate(zip(stim_seqs, dump_seqs)):
        golden = ref_mod.map_symbols(s["cyc"], s["mod"])
        if len(golden) != len(rtl):
            return False, (f"序列{si} 符号数不符(mod={s['mod']}): "
                           f"golden{len(golden)} vs RTL{len(rtl)}")
        for k, (g, r) in enumerate(zip(golden, rtl)):
            if g != r:
                return False, (f"序列{si} 第{k}符号失配(mod={s['mod']}): "
                               f"golden(i={g[0]},q={g[1]}) vs RTL(i={r[0]},q={r[1]})")
        total += len(golden)
    return True, f"{len(stim_seqs)}序列, {total}符号 全匹配, 0容差"

def not_impl(name):
    def _f(*a): raise NotImplementedError(f"{name} 比对逻辑待实现")
    return _f

COMPARATORS = {
    "fec_encoder":      compare_fec_encoder,
    "interval_spacing": not_impl("interval_spacing"),
    "puncturing":       compare_puncturing,
    "symbol_mapper":    compare_symbol_mapper,
    "symbol_assembler": not_impl("symbol_assembler"),
    "srrc_upsample":    not_impl("srrc_upsample"),
    "tx_ctrl_fsm":      not_impl("tx_ctrl_fsm"),
}

def load_ref(path):
    spec = importlib.util.spec_from_file_location("ref_model", path)
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--module", required=True)
    p.add_argument("--dump",   required=True)
    p.add_argument("--stim",   required=True)
    p.add_argument("--ref",    required=True)
    a = p.parse_args()
    if a.module not in COMPARATORS:
        print(f"[ERROR] 未注册模块: {a.module}"); sys.exit(1)
    if not os.path.exists(a.ref):
        print(f"[FAIL] 找不到参考模型: {a.ref}"); sys.exit(2)
    ok, msg = COMPARATORS[a.module](a.stim, a.dump, load_ref(a.ref))
    print(f"[{'PASS' if ok else 'FAIL'}] {a.module}: {msg}")
    sys.exit(0 if ok else 6)

if __name__=="__main__": main()
