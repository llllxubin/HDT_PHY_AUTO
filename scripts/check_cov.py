#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
覆盖率闸门 (coverage gate)
读 TB 写出的 sim/<module>/cov_summary.txt, 校验功能覆盖率达标, 否则非0退出。

spec §4.3 目标: cp_state 100% (32状态全遍历), x_state_bit 100% (状态×输入交叉)。
本脚本是闸门, 判定独立于 RTL: 只看覆盖率数字是否达阈值。

用法: python3 scripts/check_cov.py --summary sim/fec_encoder/cov_summary.txt [--min 100.0]
退出码: 0=达标, 非0=未达标/文件缺失。
"""
import argparse
import os
import sys

# 必须达标的覆盖点 (spec §4.3)
REQUIRED = ["cp_state", "x_state_bit"]


def parse_summary(path):
    cov = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) == 2:
                try:
                    cov[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return cov


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--summary", required=True)
    p.add_argument("--min", type=float, default=100.0, help="各覆盖点最低百分比")
    a = p.parse_args()

    if not os.path.exists(a.summary):
        print(f"[FAIL] coverage: 找不到覆盖率汇总 {a.summary} (sim 是否跑过?)")
        sys.exit(2)

    cov = parse_summary(a.summary)
    missing = [k for k in REQUIRED if k not in cov]
    if missing:
        print(f"[FAIL] coverage: 汇总缺少覆盖点 {missing}")
        sys.exit(3)

    bad = {k: cov[k] for k in REQUIRED if cov[k] < a.min}
    detail = ", ".join(f"{k}={cov[k]:.2f}%" for k in REQUIRED)
    if bad:
        print(f"[FAIL] coverage: 未达 {a.min:.1f}% — {detail}")
        sys.exit(4)

    print(f"[PASS] coverage: 全部 >= {a.min:.1f}% — {detail}")
    sys.exit(0)


if __name__ == "__main__":
    main()
