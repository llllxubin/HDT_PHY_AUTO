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

def not_impl(name):
    def _f(*a): raise NotImplementedError(f"{name} 比对逻辑待实现")
    return _f

COMPARATORS = {
    "fec_encoder":      compare_fec_encoder,
    "interval_spacing": not_impl("interval_spacing"),
    "puncturing":       not_impl("puncturing"),
    "symbol_mapper":    not_impl("symbol_mapper"),
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
