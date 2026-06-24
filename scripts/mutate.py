#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
变异测试闸门 (mutation kill rate gate) — spec §4.5
"反证法"验证测试集质量: 往 RTL 注入已知 bug(变异体), 用现有测试集跑;
测试失败=变异被"杀死"(好), 测试仍通过=变异"存活"(测试有盲区)。

每个变异:
  1. 复制 golden RTL, 做一处字符串替换 -> sim/mut/<name>.sv
  2. 用主 Makefile 隔离构建并比对 (RTL=<变异> BUILD=sim/mut)
  3. compare 退出码: !=0 => 被杀死(测试发现差异); ==0 => 存活(测试没发现)
绝不改判定基准, 也不动 rtl/ 本体 (只读 golden, 变异写到 sim/mut/)。

kill rate = 杀死数 / 有效变异数, 闸门要求 >= --min-kill (默认 90)。

用法: python3 scripts/mutate.py --module fec_encoder --rtl rtl/fec_encoder.sv --min-kill 90
退出码: 0=达标, 非0=未达标/有变异未能注入。
"""
import argparse
import os
import subprocess
import sys

# 变异清单 (spec §4.5: 改G0/G1抽头、termination 4或6个0、漏清零、a0/a1调换)。
# find 必须在 golden RTL 中"恰好出现一次", 否则视为注入失败 (而非杀死)。
MUTATIONS = [
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
]

MUT_DIR = "sim/mut"


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--module", required=True)
    p.add_argument("--rtl", required=True, help="golden RTL (只读, 不被修改)")
    p.add_argument("--min-kill", type=float, default=90.0)
    a = p.parse_args()

    if not os.path.exists(a.rtl):
        print(f"[FAIL] mutation: 找不到 golden RTL {a.rtl}")
        sys.exit(2)
    with open(a.rtl) as f:
        golden = f.read()

    os.makedirs(MUT_DIR, exist_ok=True)

    # 确保激励就绪 (复用主流程的激励)
    r = sh(f"make stim MODULE={a.module}")
    if r.returncode != 0:
        print("[FAIL] mutation: make stim 失败\n" + r.stdout + r.stderr)
        sys.exit(2)

    killed, survived, inject_err = 0, [], []
    print(f"[mutation] 注入 {len(MUTATIONS)} 个变异, 逐个跑回归...")
    for m in MUTATIONS:
        n = golden.count(m["find"])
        if n != 1:
            inject_err.append((m["name"], f"find 出现 {n} 次 (应为1)"))
            print(f"  [INJ-ERR] {m['name']:11s} find 未唯一匹配 ({n})")
            continue
        mutsrc = golden.replace(m["find"], m["repl"], 1)
        path = os.path.join(MUT_DIR, m["name"] + ".sv")
        with open(path, "w") as f:
            f.write(mutsrc)
        # 隔离构建+比对+定向自检 (清掉上一个变异的增量编译产物, 避免串扰)
        # selfcheck 让 seq_start 清零不变量参与杀伤判定 (no_clear 类变异由此被杀)。
        sh(f"rm -rf {MUT_DIR}/csrc {MUT_DIR}/simv {MUT_DIR}/simv.daidir")
        r = sh(f"make compile sim compare sva selfcheck MODULE={a.module} RTL={path} BUILD={MUT_DIR}")
        if r.returncode != 0:
            killed += 1
            print(f"  [KILLED ] {m['name']:11s} {m['desc']}")
        else:
            survived.append(m["name"])
            print(f"  [SURVIVE] {m['name']:11s} {m['desc']}   <-- 测试盲区!")

    total = len(MUTATIONS) - len(inject_err)
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
