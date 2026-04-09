# Codex 主进程 + 子进程（Subagent）+ Watchdog 模板

目标：让**一个长期运行的 Codex 进程**作为“主 Agent”，在本地持续从 TODO 里取任务；每个任务交给**新的 `codex exec` 子进程**（subagent）去执行；外部 watchdog 脚本负责监控主进程是否卡住/退出并自动拉起。

> 注意：要让“主 Codex 进程里启动子 Codex 进程”跑得通，主进程的 sandbox 里执行的命令需要**网络访问**（否则子进程无法调用模型）。

## 快速开始

1) 选择一个工作目录（建议是 git repo 根目录）：

```bash
WORKDIR=/path/to/your/repo
```

2) 启动主 Agent（后台运行，写 PID/日志/状态文件到 `$WORKDIR/.codex/loop/`）：

```bash
./codex-orchestrator/start-main.sh "$WORKDIR"
```

3) 启动 watchdog（前台循环监控；你也可以用 `nohup ... &` 放后台）：

```bash
./codex-orchestrator/watchdog.sh "$WORKDIR"
```

4) 编辑任务列表：

- `$WORKDIR/.codex/loop/TODO.md`

5) 看日志/状态：

- 主进程日志：`$WORKDIR/.codex/loop/main.run.log`
- 主进程最后输出：`$WORKDIR/.codex/loop/main.last.md`
- 心跳：`$WORKDIR/.codex/loop/heartbeat`
- 子进程目录：`$WORKDIR/.codex/loop/subagents/`

## 防止主 Agent 上下文变大（推荐）

核心思路：把“长期记忆/项目上下文”放进磁盘里的 `STATE.md`（可控、可读、可编辑），主进程只负责跑 `orchestrate.sh`，并且只在 `STATE.md` 的 `Now/Last/Blockers/Next (auto)` 段里写入**短**状态。

不想自己维护也可以：subagent 会被提示在需要时把“重要的长期决策/约束/结论”写进 `STATE.md` 的 **Working Context**（很短的 bullet），你主要只要维护 `TODO.md`。

### 自动暂停（避免瞎重试/爆上下文）

当 subagent 的最终输出不是 `Outcome: done`（比如 `partial/blocked/unknown`）时，orchestrator 会：

- **不会**把 TODO 打勾
- 写入 `PAUSED` 文件并退出
- watchdog 看到 `PAUSED` 会进入 idle（不再反复重启主进程）

恢复方式：修复问题/调整 TODO 后，删除 `PAUSED`：

```bash
rm "$WORKDIR/.codex/loop/PAUSED"
```

### 可选：定期重启主进程（不是默认）

你仍然可以让 watchdog 定期拉起“新主进程”来避免累积上下文，但这不再是默认/推荐的唯一方案：

```bash
# 每完成 1 个任务就退出（极限缩小主上下文）
touch "$WORKDIR/.codex/loop/RESTART_EACH_TASK"

# 每完成 N 个任务退出一次
echo 10 >"$WORKDIR/.codex/loop/RESTART_EVERY_TASKS"

# 每运行 T 秒退出一次（例如 1 小时）
echo 3600 >"$WORKDIR/.codex/loop/RESTART_EVERY_SECS"
```

### 无人值守连续推进（重要）

如果你不希望遇到阻塞就停机，开启 auto-skip：

```bash
touch "$WORKDIR/.codex/loop/AUTO_SKIP_BLOCKED"
```

开启后，`Outcome: blocked/partial/unknown` 的任务会：

- 从 `- [ ]` 改为 `- [~] ... (auto-skip:...)`
- 记录到 `"$WORKDIR/.codex/loop/FAILED.md"`
- 主循环继续处理下一条 TODO（不会写 `PAUSED` 停机）

### 单实例锁（默认开启）

- 主循环使用 `"$WORKDIR/.codex/loop/main.lock"`，watchdog 使用 `"$WORKDIR/.codex/loop/watchdog.lock"`。
- 同一工作目录里重复启动时，后启动的实例会直接退出，不会抢任务。
- 若发现陈旧锁（pid 已失效），脚本会自动回收后继续运行。

### 可选：DONE 质量门禁（推荐）

你可以让任务在勾选前先跑一个校验命令：

```bash
DONE_GUARD_CMD='npm test -- --runInBand' ./codex-orchestrator/start-main.sh "$WORKDIR"
```

行为：

- 仅当 subagent 输出 `Outcome: done` 时触发门禁命令。
- 命令执行成功（exit 0）才会把 TODO 从 `- [ ]` 改成 `- [x]`。
- 命令失败会写 `PAUSED` 并停机，任务保持未勾选；日志写到对应 `subagents/<run_id>/guard.log`。

## 停止

```bash
touch "$WORKDIR/.codex/loop/STOP"
```

watchdog 会看到 `STOP` 并停止（也会尝试结束主进程）。

## 建议加到 .gitignore

```gitignore
.codex/loop/
```

## 安全/配置要点

- 默认脚本用 `codex -a never exec -s danger-full-access ...` 来避免“无交互卡住”，但这意味着主/子进程都能在本机执行命令且可联网；请只在你信任的目录里跑。
- 如果你想更保守：把 `SANDBOX_MODE=workspace-write`，并在 `~/.codex/config.toml` 里开启 `[sandbox_workspace_write] network_access = true`，否则子进程无法联网。

## TODO 打勾规则（很重要）

orchestrator 只会在 subagent 最终输出包含 `Outcome: done` 时，把对应的 `- [ ]` 改成 `- [x]`。如果配置了 `DONE_GUARD_CMD`，还必须门禁命令通过。
