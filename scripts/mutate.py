#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
变异测试闸门 (mutation kill rate gate) — spec §4.5
"反证法"验证测试集质量: 往 RTL 注入已知 bug(变异体), 用现有测试集跑;
测试失败=变异被"杀死"(好), 测试仍通过=变异"存活"(测试有盲区)。

每个变异:
  1. 复制 golden RTL, 做一处字符串替换 -> sim/<module>/mut/<name>.sv
  2. 用主 Makefile 隔离构建并比对 (RTL=<变异> BUILD=sim/<module>/mut)
  3. compare 退出码: !=0 => 被杀死(测试发现差异); ==0 => 存活(测试没发现)
绝不改判定基准, 也不动 rtl/ 本体 (只读 golden, 变异写到 sim/<module>/mut/)。

kill rate = 杀死数 / 有效变异数, 闸门要求 >= --min-kill (默认 90)。

用法: python3 scripts/mutate.py --module fec_encoder --rtl rtl/fec_encoder.sv --min-kill 90
退出码: 0=达标, 非0=未达标/有变异未能注入。
"""
import argparse
import os
import subprocess
import sys

# 变异清单 (spec §4.5) —— 按模块键控。
# 每个模块一组变异算子; --module 选对应组。某模块未定义 => 清晰报错, 不静默通过。
# find 必须在该模块 golden RTL 中"恰好出现一次", 否则视为注入失败 (而非杀死)。
#
# 注: 各模块变异语义彼此独立。fec_encoder 6 条已验证 100% 杀死, 重构时原样保留, 不改语义。
MUTATIONS_BY_MODULE = {
    # ---- fec_encoder (spec §4.5: 改G0/G1抽头、termination 4或6个0、漏清零、a0/a1调换) ----
    "fec_encoder": [
        {"name": "g0_tap",     "desc": "G0抽头 s[3]->s[2]",
         "find": "a0 = b ^ s[1] ^ s[3] ^ s[4];",
         "repl": "a0 = b ^ s[1] ^ s[2] ^ s[4];"},
        {"name": "g1_drop",    "desc": "G1漏抽头 去掉 s[2]",
         "find": "a1 = b ^ s[0] ^ s[1] ^ s[2] ^ s[4];",
         "repl": "a1 = b ^ s[0] ^ s[1] ^ s[4];"},
        {"name": "swap_a0a1",  "desc": "a0/a1 调换顺序",
         "find": "return {a1, a0};",
         "repl": "return {a0, a1};"},
        {"name": "term_4zero", "desc": "termination 只补 4 个 0",
         "find": "if (term_cnt == 3'd4) begin",
         "repl": "if (term_cnt == 3'd3) begin"},
        {"name": "term_6zero", "desc": "termination 补 6 个 0",
         "find": "if (term_cnt == 3'd4) begin",
         "repl": "if (term_cnt == 3'd5) begin"},
        {"name": "no_clear",   "desc": "漏 seq_start 清零",
         "find": "eff_state = seq_start ? 5'd0 : enc_state;",
         "repl": "eff_state = enc_state;"},
    ],

    # ---- puncturing (spec §4.5: 改模式某位、模式长/相位推进错、a0/a1调换、漏复位、回绕off-by-one) ----
    # find 串均已核对在 rtl/puncturing.sv 中唯一出现。各变异均语法合法、可编译、语义确错,
    # 应由现有 compare(逐bit) / sva / selfcheck 杀死。
    "puncturing": [
        # 翻 Pat15of16 一位 (bit0: 1->0): 破坏 15/16 相位0 处 a0 保留 -> compare 逐bit 杀。
        {"name": "pat15_tap",   "desc": "Pat15of16 翻 bit0 (1->0)",
         "find": "30'b10_0110_1010_0101_1010_1001_0101_1011",
         "repl": "30'b10_0110_1010_0101_1010_1001_0101_1010"},
        # 相位推进 +2 改 +1: 每拍只前进 1 相位, 与"每拍消耗2位"不符 -> 相位全乱 -> compare 杀。
        {"name": "adv_plus1",   "desc": "相位推进 +2 -> +1",
         "find": "adv_phase  = eff_phase + 5'd2;",
         "repl": "adv_phase  = eff_phase + 5'd1;"},
        # keep_a0 误读 a1 的模式位 (索引 +1): a0/a1 保留判定错位 -> compare 杀。
        {"name": "keep_misidx", "desc": "keep_a0 读 eff_phase+1 的模式位",
         "find": "keep_a0 = (cur_pat >> eff_phase) & 1'b1;",
         "repl": "keep_a0 = (cur_pat >> (eff_phase + 5'd1)) & 1'b1;"},
        # 回绕条件 >= 改 >: adv==L 时不回绕, 相位越界 -> 模式索引错 -> compare 杀。
        {"name": "wrap_off1",   "desc": "回绕 >= 改为 > (off-by-one)",
         "find": "next_phase = (adv_phase >= eff_len) ? 5'd0 : adv_phase;",
         "repl": "next_phase = (adv_phase > eff_len) ? 5'd0 : adv_phase;"},
        # seq_start 拍漏把 eff_phase 置 0: 用残留相位施加首码对 -> 相位复位失效
        #   -> selfcheck(seq_start 相位复位不变量) + compare 杀。
        {"name": "no_seqreset", "desc": "seq_start 拍 eff_phase 不置0",
         "find": "eff_phase = 5'd0;",
         "repl": "eff_phase = phase;"},
        # 破坏 rate=1/2 透传: 模式向量翻一位 (全1 -> bit0=0), 1/2 不再恒等
        #   -> SVA A1(透传不变量) + compare 杀。
        {"name": "break_pass",  "desc": "rate=1/2 模式向量 bit0 置0 (破坏透传)",
         "find": "RateHalf:   pat_vec = 30'h3FFF_FFFF;",
         "repl": "RateHalf:   pat_vec = 30'h3FFF_FFFE;"},
    ],
}

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--module", required=True)
    p.add_argument("--rtl", required=True, help="golden RTL (只读, 不被修改)")
    p.add_argument("--min-kill", type=float, default=90.0)
    a = p.parse_args()

    # 选本模块的变异组; 未定义 => 清晰报错 (不静默通过)。
    if a.module not in MUTATIONS_BY_MODULE:
        print(f"[FAIL] mutation: 模块 {a.module} 未定义变异组 "
              f"(可用: {sorted(MUTATIONS_BY_MODULE)})")
        sys.exit(3)
    mutations = MUTATIONS_BY_MODULE[a.module]

    # 隔离构建目录按模块命名空间, 与 Makefile SIM_DIR=sim/<MODULE> 一致, 不污染主构建。
    mut_dir = os.path.join("sim", a.module, "mut")

    if not os.path.exists(a.rtl):
        print(f"[FAIL] mutation: 找不到 golden RTL {a.rtl}")
        sys.exit(2)
    with open(a.rtl) as f:
        golden = f.read()

    os.makedirs(mut_dir, exist_ok=True)

    # 确保激励就绪 (复用主流程的激励)
    r = sh(f"make stim MODULE={a.module}")
    if r.returncode != 0:
        print("[FAIL] mutation: make stim 失败\n" + r.stdout + r.stderr)
        sys.exit(2)

    killed, survived, inject_err = 0, [], []
    print(f"[mutation] 注入 {len(mutations)} 个变异, 逐个跑回归...")
    for m in mutations:
        n = golden.count(m["find"])
        if n != 1:
            inject_err.append((m["name"], f"find 出现 {n} 次 (应为1)"))
            print(f"  [INJ-ERR] {m['name']:11s} find 未唯一匹配 ({n})")
            continue
        mutsrc = golden.replace(m["find"], m["repl"], 1)
        path = os.path.join(mut_dir, m["name"] + ".sv")
        with open(path, "w") as f:
            f.write(mutsrc)
        # 隔离构建+比对+定向自检 (清掉上一个变异的增量编译产物, 避免串扰)
        # selfcheck 让 seq_start 清零不变量参与杀伤判定 (no_clear 类变异由此被杀)。
        sh(f"rm -rf {mut_dir}/csrc {mut_dir}/simv {mut_dir}/simv.daidir")
        r = sh(f"make compile sim compare sva selfcheck MODULE={a.module} RTL={path} BUILD={mut_dir}")
        if r.returncode != 0:
            killed += 1
            print(f"  [KILLED ] {m['name']:11s} {m['desc']}")
        else:
            survived.append(m["name"])
            print(f"  [SURVIVE] {m['name']:11s} {m['desc']}   <-- 测试盲区!")

    total = len(mutations) - len(inject_err)
    if inject_err:
        print(f"[FAIL] mutation: {len(inject_err)} 个变异未能注入 (RTL 文本变了?), 修正后重跑")
        sys.exit(3)
    if total == 0:
        print("[FAIL] mutation: 无有效变异")
        sys.exit(3)

    rate = 100.0 * killed / total
    print(f"[mutation] 杀死 {killed}/{total} = {rate:.1f}%  (存活: {survived or '无'})")
    if rate < a.min_kill:
        print(f"[FAIL] mutation: kill rate {rate:.1f}% < {a.min_kill:.1f}%")
        sys.exit(4)
    print(f"[PASS] mutation: kill rate {rate:.1f}% >= {a.min_kill:.1f}%")
    sys.exit(0)


if __name__ == "__main__":
    main()
