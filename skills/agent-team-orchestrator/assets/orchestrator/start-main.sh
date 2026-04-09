#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start-main.sh [WORKDIR]

Environment overrides:
  CODEX_BIN=codex
  SANDBOX_MODE=danger-full-access
  APPROVAL_POLICY=never
  CODEX_MODEL=
  MAX_REVIEW_ROUNDS=3
  MAX_PHASE_RETRIES=2
  STARTUP_GRACE_SECS=5
  START_MODE=auto
  DONE_GUARD_CMD=

State and logs are written under:
  WORKDIR/.codex/agent-team/
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
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
MAX_PHASE_RETRIES="${MAX_PHASE_RETRIES:-2}"
STARTUP_GRACE_SECS="${STARTUP_GRACE_SECS:-5}"
START_MODE="${START_MODE:-auto}"
DONE_GUARD_CMD="${DONE_GUARD_CMD:-}"

WORKDIR="${1:-${WORKDIR:-$PWD}}"
WORKDIR="$(cd "$WORKDIR" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PROMPTS_DIR="$SCRIPT_DIR/prompts"

LOOP_DIR="$WORKDIR/.codex/agent-team"
RUNS_DIR="$LOOP_DIR/runs"
MAIN_LOCK_DIR="$LOOP_DIR/main.lock"
MAIN_LOCK_PID_FILE="$MAIN_LOCK_DIR/pid"
STOP_FILE="$LOOP_DIR/STOP"
DONE_FILE="$LOOP_DIR/DONE"
PAUSED_FILE="$LOOP_DIR/PAUSED"

mkdir -p "$RUNS_DIR"

TODO_FILE="$LOOP_DIR/TODO.md"
STATE_FILE="$LOOP_DIR/STATE.md"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"

MAIN_PROMPT_FILE="$LOOP_DIR/main.prompt.md"
DEVELOPER_PROMPT_FILE="$LOOP_DIR/developer.prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/review.prompt.md"

if [[ ! -f "$TODO_FILE" ]]; then
  cat >"$TODO_FILE" <<'EOF'
# TODO
- [ ] Replace this placeholder by filling Goal/Constraints/DoD in STATE.md and then starting the main agent
EOF
fi

if [[ ! -f "$STATE_FILE" ]]; then
  cat >"$STATE_FILE" <<'EOF'
# STATE

## Goal
- (What are we trying to ship or fix?)

## Constraints
- (Important constraints, assumptions, and non-goals)

## Definition of Done
- (What must be true before the mission is complete?)

## Working Context
- (Keep durable context short; link to docs instead of pasting large content)

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

## Next (auto)
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

if [[ ! -f "$DEVELOPER_PROMPT_FILE" ]]; then
  cp "$TEMPLATE_PROMPTS_DIR/developer.prompt.md" "$DEVELOPER_PROMPT_FILE"
fi

if [[ ! -f "$REVIEW_PROMPT_FILE" ]]; then
  cp "$TEMPLATE_PROMPTS_DIR/review.prompt.md" "$REVIEW_PROMPT_FILE"
fi

if [[ -f "$WORKDIR/agent-team-orchestrator/orchestrate.sh" ]]; then
  chmod +x "$WORKDIR/agent-team-orchestrator/orchestrate.sh" 2>/dev/null || true
fi

PID_FILE="$LOOP_DIR/main.pid"
MAIN_SESSION_FILE="$LOOP_DIR/main.session"
LOG_FILE="$LOOP_DIR/main.run.log"
LAST_FILE="$LOOP_DIR/main.last.md"

tmux_session_alive() {
  [[ -f "$MAIN_SESSION_FILE" ]] || return 1
  local session
  session="$(cat "$MAIN_SESSION_FILE" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" >/dev/null 2>&1
}

is_running() {
  if tmux_session_alive; then
    return 0
  fi
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex' || return 1
}

remove_stale_pid_file() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
    fi
  fi
}

remove_stale_main_session_file() {
  if [[ -f "$MAIN_SESSION_FILE" ]] && ! tmux_session_alive; then
    rm -f "$MAIN_SESSION_FILE"
  fi
}

remove_stale_main_lock() {
  if [[ -d "$MAIN_LOCK_DIR" ]]; then
    local owner_pid
    owner_pid="$(cat "$MAIN_LOCK_PID_FILE" 2>/dev/null || true)"
    if [[ -z "$owner_pid" ]] || ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -f "$MAIN_LOCK_PID_FILE" 2>/dev/null || true
      rmdir "$MAIN_LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

prepare_resume_state() {
  remove_stale_pid_file
  remove_stale_main_session_file
  remove_stale_main_lock
  rm -f "$STOP_FILE" "$DONE_FILE" "$PAUSED_FILE"
}

if is_running; then
  echo "Main agent already running (pid=$(cat "$PID_FILE"))."
  echo "Log: $LOG_FILE"
  exit 0
fi

prepare_resume_state
date +%s >"$HEARTBEAT_FILE" || true

startup_completed_cleanly() {
  [[ -f "$LAST_FILE" || -f "$DONE_FILE" || -f "$PAUSED_FILE" ]]
}

wait_for_startup_health() {
  local deadline=$((SECONDS + STARTUP_GRACE_SECS))
  while (( SECONDS < deadline )); do
    if startup_completed_cleanly; then
      return 0
    fi
    sleep 1
  done

  if is_running || startup_completed_cleanly; then
    return 0
  fi
  return 1
}

resolve_start_mode() {
  case "$START_MODE" in
    tmux|nohup)
      printf '%s\n' "$START_MODE"
      ;;
    auto)
      if command -v tmux >/dev/null 2>&1; then
        printf 'tmux\n'
      else
        printf 'nohup\n'
      fi
      ;;
    *)
      echo "Unsupported START_MODE=$START_MODE" >&2
      exit 2
      ;;
  esac
}

start_via_nohup() {
  nohup env TERM=xterm CODEX_BIN="$CODEX_BIN" SANDBOX_MODE="$SANDBOX_MODE" APPROVAL_POLICY="$APPROVAL_POLICY" CODEX_MODEL="$CODEX_MODEL" MAX_REVIEW_ROUNDS="$MAX_REVIEW_ROUNDS" MAX_PHASE_RETRIES="$MAX_PHASE_RETRIES" DONE_GUARD_CMD="$DONE_GUARD_CMD" "${cmd[@]}" <"$MAIN_PROMPT_FILE" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  rm -f "$MAIN_SESSION_FILE"
}

start_via_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for START_MODE=tmux" >&2
    exit 2
  fi
  local session_name="agent_team_$(date +%s)"
  local quoted_cmd=""
  local arg
  for arg in "${cmd[@]}"; do
    printf -v quoted_cmd '%s%q ' "$quoted_cmd" "$arg"
  done
  local shell_cmd
  shell_cmd="cd $(printf '%q' "$WORKDIR") && env TERM=xterm CODEX_BIN=$(printf '%q' "$CODEX_BIN") SANDBOX_MODE=$(printf '%q' "$SANDBOX_MODE") APPROVAL_POLICY=$(printf '%q' "$APPROVAL_POLICY") CODEX_MODEL=$(printf '%q' "$CODEX_MODEL") MAX_REVIEW_ROUNDS=$(printf '%q' "$MAX_REVIEW_ROUNDS") MAX_PHASE_RETRIES=$(printf '%q' "$MAX_PHASE_RETRIES") DONE_GUARD_CMD=$(printf '%q' "$DONE_GUARD_CMD") ${quoted_cmd}< $(printf '%q' "$MAIN_PROMPT_FILE") > $(printf '%q' "$LOG_FILE") 2>&1"
  tmux new-session -d -s "$session_name" "$shell_cmd"
  printf '%s\n' "$session_name" >"$MAIN_SESSION_FILE"
  rm -f "$PID_FILE"
}

cmd=("$CODEX_BIN")
if [[ -n "$CODEX_MODEL" ]]; then
  cmd+=("-m" "$CODEX_MODEL")
fi
cmd+=("-a" "$APPROVAL_POLICY" "exec" "-s" "$SANDBOX_MODE")
cmd+=("--skip-git-repo-check" "--color" "never" "-C" "$WORKDIR")
cmd+=("--output-last-message" "$LAST_FILE" "-")

echo "Starting main orchestrator..."
echo "- workdir: $WORKDIR"
echo "- sandbox: $SANDBOX_MODE"
echo "- approval: $APPROVAL_POLICY"
echo "- review rounds: $MAX_REVIEW_ROUNDS"
echo "- startup grace: ${STARTUP_GRACE_SECS}s"
launch_mode="$(resolve_start_mode)"
echo "- start mode: $launch_mode"
if [[ -n "$CODEX_MODEL" ]]; then
  echo "- model: $CODEX_MODEL"
fi
if [[ -n "$DONE_GUARD_CMD" ]]; then
  echo "- done guard: $DONE_GUARD_CMD"
fi
echo "- pid file: $PID_FILE"
echo "- session file: $MAIN_SESSION_FILE"
echo "- log file: $LOG_FILE"

case "$launch_mode" in
  tmux)
    start_via_tmux
    ;;
  nohup)
    start_via_nohup
    ;;
esac

if wait_for_startup_health; then
  if [[ -f "$MAIN_SESSION_FILE" ]]; then
    echo "Started (session=$(cat "$MAIN_SESSION_FILE"))."
  else
    echo "Started (pid=$(cat "$PID_FILE"))."
  fi
  exit 0
fi

remove_stale_pid_file
remove_stale_main_session_file
echo "Main agent failed during startup."
echo "Log: $LOG_FILE"
if [[ -s "$LOG_FILE" ]]; then
  echo "Last log lines:"
  tail -n 40 "$LOG_FILE"
fi
exit 1
