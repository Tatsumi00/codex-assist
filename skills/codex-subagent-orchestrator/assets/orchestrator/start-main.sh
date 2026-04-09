#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start-main.sh [WORKDIR]

Environment overrides:
  CODEX_BIN=codex
  SANDBOX_MODE=danger-full-access      # or workspace-write, read-only
  APPROVAL_POLICY=never                # or on-request, on-failure, untrusted
  CODEX_MODEL=                         # optional, e.g. o3
  DONE_GUARD_CMD=                      # optional quality gate command before TODO is marked done

State/logs are written under:
  WORKDIR/.codex/loop/
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CODEX_BIN="${CODEX_BIN:-codex}"
SANDBOX_MODE="${SANDBOX_MODE:-danger-full-access}"
APPROVAL_POLICY="${APPROVAL_POLICY:-never}"
CODEX_MODEL="${CODEX_MODEL:-}"
DONE_GUARD_CMD="${DONE_GUARD_CMD:-}"

WORKDIR="${1:-${WORKDIR:-$PWD}}"
WORKDIR="$(cd "$WORKDIR" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PROMPTS_DIR="$SCRIPT_DIR/prompts"

LOOP_DIR="$WORKDIR/.codex/loop"
SUBAGENTS_DIR="$LOOP_DIR/subagents"

mkdir -p "$SUBAGENTS_DIR"

TODO_FILE="$LOOP_DIR/TODO.md"
STATE_FILE="$LOOP_DIR/STATE.md"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"

MAIN_PROMPT_FILE="$LOOP_DIR/main.prompt.md"
SUBAGENT_PROMPT_FILE="$LOOP_DIR/subagent.prompt.md"

if [[ ! -f "$TODO_FILE" ]]; then
  cat >"$TODO_FILE" <<'EOF'
# TODO
- [ ] Replace this with your real tasks
EOF
fi

if [[ ! -f "$STATE_FILE" ]]; then
  cat >"$STATE_FILE" <<'EOF'
# STATE

## Goal
- (What are we trying to achieve?)

## Constraints
- (Important constraints, assumptions, non-goals)

## Definition of Done
- (What does "done" mean for this effort?)

## Working Context
- (Keep this short; link to docs instead of pasting large context)

## Now (auto)
<!-- BEGIN AUTO NOW -->
- idle
<!-- END AUTO NOW -->

## Last (auto)
<!-- BEGIN AUTO LAST -->
- none
<!-- END AUTO LAST -->

## Blockers (auto)
<!-- BEGIN AUTO BLOCKERS -->
- none
<!-- END AUTO BLOCKERS -->

## Next
<!-- BEGIN AUTO NEXT -->
- none
<!-- END AUTO NEXT -->

## Notes / Links
- (Freeform)
EOF
fi

if [[ ! -f "$MAIN_PROMPT_FILE" ]]; then
  cp "$TEMPLATE_PROMPTS_DIR/main.prompt.md" "$MAIN_PROMPT_FILE"
fi

if [[ ! -f "$SUBAGENT_PROMPT_FILE" ]]; then
  cp "$TEMPLATE_PROMPTS_DIR/subagent.prompt.md" "$SUBAGENT_PROMPT_FILE"
fi

if [[ -f "$WORKDIR/codex-orchestrator/orchestrate.sh" ]]; then
  chmod +x "$WORKDIR/codex-orchestrator/orchestrate.sh" 2>/dev/null || true
fi

PID_FILE="$LOOP_DIR/main.pid"
LOG_FILE="$LOOP_DIR/main.run.log"
LAST_FILE="$LOOP_DIR/main.last.md"

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex' || return 1
}

if is_running; then
  echo "Main agent already running (pid=$(cat "$PID_FILE"))."
  echo "Log: $LOG_FILE"
  exit 0
fi

rm -f "$LOOP_DIR/DONE"
date +%s >"$HEARTBEAT_FILE" || true

cmd=("$CODEX_BIN")
if [[ -n "$CODEX_MODEL" ]]; then
  cmd+=("-m" "$CODEX_MODEL")
fi
cmd+=("-a" "$APPROVAL_POLICY" "exec" "-s" "$SANDBOX_MODE")
cmd+=("--skip-git-repo-check" "--color" "never" "-C" "$WORKDIR")
cmd+=("--output-last-message" "$LAST_FILE" "-")

echo "Starting main agent..."
echo "- workdir: $WORKDIR"
echo "- sandbox: $SANDBOX_MODE"
echo "- approval: $APPROVAL_POLICY"
if [[ -n "$CODEX_MODEL" ]]; then
  echo "- model: $CODEX_MODEL"
fi
if [[ -n "$DONE_GUARD_CMD" ]]; then
  echo "- done guard: $DONE_GUARD_CMD"
fi
echo "- pid file: $PID_FILE"
echo "- log file: $LOG_FILE"

nohup env TERM=xterm SANDBOX_MODE="$SANDBOX_MODE" APPROVAL_POLICY="$APPROVAL_POLICY" CODEX_BIN="$CODEX_BIN" CODEX_MODEL="$CODEX_MODEL" DONE_GUARD_CMD="$DONE_GUARD_CMD" "${cmd[@]}" <"$MAIN_PROMPT_FILE" >"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"

echo "Started (pid=$(cat "$PID_FILE"))."
