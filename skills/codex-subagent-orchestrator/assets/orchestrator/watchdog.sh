#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  watchdog.sh [WORKDIR]

What it does:
  - Ensures main Codex agent is running (starts it if missing)
  - Watches heartbeat file; if stale, restarts main agent
  - Stops when STOP file exists

Environment overrides:
  CHECK_EVERY_SECS=30
  STALE_SECS=900
  START_SCRIPT=.../start-main.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

WORKDIR="${1:-${WORKDIR:-$PWD}}"
WORKDIR="$(cd "$WORKDIR" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT="${START_SCRIPT:-$SCRIPT_DIR/start-main.sh}"

CHECK_EVERY_SECS="${CHECK_EVERY_SECS:-30}"
STALE_SECS="${STALE_SECS:-900}"

LOOP_DIR="$WORKDIR/.codex/loop"
PID_FILE="$LOOP_DIR/main.pid"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"
STOP_FILE="$LOOP_DIR/STOP"
DONE_FILE="$LOOP_DIR/DONE"
TODO_FILE="$LOOP_DIR/TODO.md"
PAUSED_FILE="$LOOP_DIR/PAUSED"
WATCHDOG_LOG="$LOOP_DIR/watchdog.log"
WATCHDOG_LOCK_DIR="$LOOP_DIR/watchdog.lock"
WATCHDOG_LOCK_PID_FILE="$WATCHDOG_LOCK_DIR/pid"

mkdir -p "$LOOP_DIR"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$WATCHDOG_LOG" >/dev/null
}

watchdog_lock_owner_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q '[w]atchdog.sh' || return 1
}

release_watchdog_lock() {
  local owner_pid
  owner_pid="$(cat "$WATCHDOG_LOCK_PID_FILE" 2>/dev/null || true)"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$WATCHDOG_LOCK_PID_FILE" 2>/dev/null || true
    rmdir "$WATCHDOG_LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_watchdog_lock() {
  while true; do
    if mkdir "$WATCHDOG_LOCK_DIR" 2>/dev/null; then
      echo "$$" >"$WATCHDOG_LOCK_PID_FILE"
      trap 'release_watchdog_lock' EXIT INT TERM
      return 0
    fi

    local owner_pid
    owner_pid="$(cat "$WATCHDOG_LOCK_PID_FILE" 2>/dev/null || true)"
    if watchdog_lock_owner_alive "$owner_pid"; then
      log "watchdog already running (pid=$owner_pid); exiting duplicate"
      return 1
    fi

    rm -f "$WATCHDOG_LOCK_PID_FILE" 2>/dev/null || true
    rmdir "$WATCHDOG_LOCK_DIR" 2>/dev/null || true
    sleep 1
  done
}

pid_is_alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex' || return 1
}

get_mtime_epoch() {
  local file="$1"
  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
  else
    stat -c %Y "$file"
  fi
}

kill_pid() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    if ! ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex'; then
      log "refusing to kill pid=$pid (does not look like codex)"
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
  for pid_file in "$LOOP_DIR/subagents"/*/pid; do
    [[ -f "$pid_file" ]] || continue
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      log "terminating subagent (pid=$pid, pidfile=$pid_file)"
      kill_pid "$pid"
    fi
  done
}

if ! acquire_watchdog_lock; then
  exit 0
fi

log "watchdog started (workdir=$WORKDIR, stale=${STALE_SECS}s, interval=${CHECK_EVERY_SECS}s)"

last_paused_mtime=""

while true; do
  if [[ -f "$STOP_FILE" ]]; then
    if pid_is_alive; then
      pid="$(cat "$PID_FILE")"
      log "STOP detected; terminating main agent (pid=$pid)"
      kill_pid "$pid"
    else
      log "STOP detected; main agent not running"
    fi
    kill_subagents
    log "watchdog exiting"
    exit 0
  fi

  if [[ -f "$PAUSED_FILE" ]]; then
    mtime="$(get_mtime_epoch "$PAUSED_FILE" 2>/dev/null || echo 0)"
    if [[ "$mtime" != "$last_paused_mtime" ]]; then
      log "PAUSED present; watchdog will idle until removed (see $PAUSED_FILE)"
      last_paused_mtime="$mtime"
    fi
    if pid_is_alive; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      if [[ -n "$pid" ]]; then
        log "PAUSED present; terminating main agent (pid=$pid)"
        kill_pid "$pid"
      fi
    fi
    kill_subagents
    sleep "$CHECK_EVERY_SECS"
    continue
  else
    last_paused_mtime=""
  fi

  if [[ -f "$DONE_FILE" ]]; then
    if [[ -f "$TODO_FILE" ]] && grep -qF -- "- [ ]" "$TODO_FILE"; then
      log "DONE present but TODO has unchecked items; clearing DONE"
      rm -f "$DONE_FILE"
    else
      log "DONE present and no pending tasks; watchdog exiting"
      exit 0
    fi
  fi

  if ! pid_is_alive; then
    log "main agent not running; starting..."
    "$START_SCRIPT" "$WORKDIR" >>"$WATCHDOG_LOG" 2>&1 || true
  fi

  if [[ -f "$HEARTBEAT_FILE" ]]; then
    now="$(date +%s)"
    hb="$(get_mtime_epoch "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
    age=$((now - hb))
    if (( age > STALE_SECS )); then
      if pid_is_alive; then
        pid="$(cat "$PID_FILE")"
        log "heartbeat stale (${age}s); restarting main agent (pid=$pid)"
        kill_pid "$pid"
      else
        log "heartbeat stale (${age}s); main agent already down"
      fi
      kill_subagents
      "$START_SCRIPT" "$WORKDIR" >>"$WATCHDOG_LOG" 2>&1 || true
    fi
  else
    log "heartbeat missing; waiting for main agent to create it"
  fi

  sleep "$CHECK_EVERY_SECS"
done
