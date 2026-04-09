#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${1:-${WORKDIR:-$PWD}}"
WORKDIR="$(cd "$WORKDIR" && pwd)"

LOOP_DIR="$WORKDIR/.codex/agent-team"
PID_FILE="$LOOP_DIR/main.pid"
MAIN_SESSION_FILE="$LOOP_DIR/main.session"
STOP_FILE="$LOOP_DIR/STOP"
MAIN_LOCK_DIR="$LOOP_DIR/main.lock"
MAIN_LOCK_PID_FILE="$MAIN_LOCK_DIR/pid"
RUNS_DIR="$LOOP_DIR/runs"

mkdir -p "$LOOP_DIR"
touch "$STOP_FILE"

kill_pid() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    if ! ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex'; then
      echo "refusing to kill pid=$pid (does not look like codex)" >&2
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

tmux_session_alive() {
  [[ -f "$MAIN_SESSION_FILE" ]] || return 1
  local session
  session="$(cat "$MAIN_SESSION_FILE" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" >/dev/null 2>&1
}

kill_main_session() {
  local session
  session="$(cat "$MAIN_SESSION_FILE" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 0
  if tmux_session_alive; then
    echo "Stopping main tmux session ($session)..."
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
}

kill_run_processes() {
  local pid_file
  while IFS= read -r pid_file; do
    [[ -f "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping run process (pid=$pid)..."
      kill_pid "$pid"
    fi
  done < <(find "$RUNS_DIR" -name '*.pid' -type f 2>/dev/null | sort)
}

remove_stale_pid_file() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
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

if tmux_session_alive; then
  kill_main_session
elif [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    if ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex'; then
      echo "Stopping main agent (pid=$pid)..."
      kill_pid "$pid"
    else
      echo "STOP set; refusing to kill pid=$pid (does not look like codex)."
    fi
  else
    echo "STOP set; main agent not running."
  fi
else
  echo "STOP set; pid file not found."
fi

kill_run_processes
remove_stale_pid_file
remove_stale_main_session_file
remove_stale_main_lock
