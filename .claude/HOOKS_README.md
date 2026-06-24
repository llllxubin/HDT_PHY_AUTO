# Hooks 使用说明

hooks 是事件触发的确定性脚本, **不经 agent 判断, 必然执行**。
它补上 CLAUDE.md(引导, 可能违反) 和 权限(被动门) 之外的主动自动化层。

## 三层控制对比

| 层 | 强度 | 作用 | 文件 |
|---|---|---|---|
| CLAUDE.md | 引导(可能违反) | 告诉 agent 应该怎么做 | CLAUDE.md |
| permissions | 被动门 | 能不能做某事 (allow/ask/deny) | settings.json |
| hooks | 主动触发(必然) | 某事发生时自动做另一件事 | settings.json + .claude/hooks/*.sh |

## 当前已启用

**PostToolUse** (matcher: Edit|Write) → `post_edit_sv.sh`
agent 每次改 .sv/.v 后, 自动:
1. verible-verilog-format 原地整理排版 (改外观不改逻辑)
2. verible-verilog-lint 静态检查 (只读, 问题输出给 agent 自修)
不阻断 agent。安全高价值, 首选启用。

## 暂禁用 (跑顺单agent后再开)

存放在 settings.json 的 `_disabled_hooks` 段。**启用方法**: 把对应块从
`_disabled_hooks` 剪切, 合并进 `hooks` 段 (同名 key 合并数组)。

### Stop → `stop_force_test.sh`  (威力大, 谨慎开)
agent 想结束时强制跑 make test, 没过就阻止结束、把失败信息反馈让它继续。
落实"完成=exit0, 不可自行宣布完成"铁律。
**为何先禁用**: 首次调试期 agent 会被频繁拉回, 干扰你观察其行为。
对它有手感、单agent能稳定跑通后再开。

### SessionStart → `session_start_progress.sh`  (抗压缩)
会话开始/压缩恢复时自动把 PROGRESS.md 注入上下文, 不靠 agent 记得读。
**为何先禁用**: 先确认你的 Claude Code 版本 SessionStart 的注入方式与传参,
再开以免上下文重复或格式问题。

## 重要提醒

1. **hook 传参方式随 Claude Code 版本不同**。post_edit_sv.sh 里用
   `CLAUDE_TOOL_FILE_PATH` 取被改文件路径, 并做了"扫 rtl/" 兜底。
   首次用请按你版本文档确认环境变量名, 对不上则改脚本顶部。
2. **退出码语义**: PostToolUse 用 exit 0 不阻断; Stop 用非0 阻止结束。
   各 hook 类型的退出码含义以官方文档为准。
3. hook 脚本要**快**。高频的 PostToolUse 只放 format/lint, 不放仿真。
4. 配置/脚本改完, 重启 Claude Code 会话使其生效。
