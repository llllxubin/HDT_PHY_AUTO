#!/usr/bin/env bash
# =============================================================
# Stop hook: agent 宣布结束时, 强制跑一次 make test
# 用途: 落实"完成=exit 0, 不可自行宣布完成"铁律 —— 用机制保证, 非靠自觉。
#       agent 想停时, 没过回归就把它"拉回"继续干。
# 当前状态: 默认未在 settings.json 启用。威力大但需手感后再开,
#           否则首次调试期 agent 会被频繁拉回, 干扰你观察。
# 退出码约定 (Claude Code Stop hook): 非0 = 阻止停止, 把 stderr 反馈给 agent。
# =============================================================
set -uo pipefail

echo "[Stop hook] 结束前强制校验: make test ..."
if make test > /tmp/stop_hook_test.log 2>&1; then
  echo "[Stop hook] make test PASS, 允许结束。"
  exit 0
else
  echo "[Stop hook] make test 未通过, 不允许结束。最近日志:" >&2
  tail -n 20 /tmp/stop_hook_test.log >&2
  echo "请根据上面失败信息继续修复 RTL, 不要停。" >&2
  exit 1   # 非0: 阻止停止, agent 继续
fi
