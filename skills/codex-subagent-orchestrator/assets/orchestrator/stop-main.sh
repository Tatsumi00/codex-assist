#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${1:-${WORKDIR:-$PWD}}"
WORKDIR="$(cd "$WORKDIR" && pwd)"

LOOP_DIR="$WORKDIR/.codex/loop"
PID_FILE="$LOOP_DIR/main.pid"
STOP_FILE="$LOOP_DIR/STOP"
SUBAGENTS_DIR="$LOOP_DIR/subagents"

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

kill_subagents() {
  local pid_file
  for pid_file in "$SUBAGENTS_DIR"/*/pid; do
    [[ -f "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping subagent (pid=$pid)..."
      kill_pid "$pid"
    fi
  done
}

if [[ -f "$PID_FILE" ]]; then
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

kill_subagents
