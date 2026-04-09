#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  watchdog.sh [WORKDIR]

What it does:
  - Ensures the main orchestrator is running
  - Watches the heartbeat file and restarts the main process if stale
  - Stops when STOP exists

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

LOOP_DIR="$WORKDIR/.codex/agent-team"
PID_FILE="$LOOP_DIR/main.pid"
MAIN_SESSION_FILE="$LOOP_DIR/main.session"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"
STOP_FILE="$LOOP_DIR/STOP"
DONE_FILE="$LOOP_DIR/DONE"
TODO_FILE="$LOOP_DIR/TODO.md"
PAUSED_FILE="$LOOP_DIR/PAUSED"
MAIN_LOCK_DIR="$LOOP_DIR/main.lock"
MAIN_LOCK_PID_FILE="$MAIN_LOCK_DIR/pid"
WATCHDOG_LOG="$LOOP_DIR/watchdog.log"
WATCHDOG_LOCK_DIR="$LOOP_DIR/watchdog.lock"
WATCHDOG_LOCK_PID_FILE="$WATCHDOG_LOCK_DIR/pid"
RUNS_DIR="$LOOP_DIR/runs"

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

tmux_session_alive() {
  [[ -f "$MAIN_SESSION_FILE" ]] || return 1
  local session
  session="$(cat "$MAIN_SESSION_FILE" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session" >/dev/null 2>&1
}

main_is_alive() {
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

cleanup_stale_runtime_state() {
  remove_stale_pid_file
  remove_stale_main_session_file
  remove_stale_main_lock
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

kill_main_session() {
  local session
  session="$(cat "$MAIN_SESSION_FILE" 2>/dev/null || true)"
  [[ -n "$session" ]] || return 0
  if tmux_session_alive; then
    log "terminating tmux session ($session)"
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
}

stop_main_orchestrator() {
  if tmux_session_alive; then
    kill_main_session
    return 0
  fi
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill_pid "$pid"
    fi
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
      log "terminating run process (pid=$pid, pidfile=$pid_file)"
      kill_pid "$pid"
    fi
  done < <(find "$RUNS_DIR" -name '*.pid' -type f 2>/dev/null | sort)
}

if ! acquire_watchdog_lock; then
  exit 0
fi

log "watchdog started (workdir=$WORKDIR, stale=${STALE_SECS}s, interval=${CHECK_EVERY_SECS}s)"

last_paused_mtime=""

while true; do
  if [[ -f "$STOP_FILE" ]]; then
    if main_is_alive; then
      log "STOP detected; terminating main agent"
      stop_main_orchestrator
    else
      log "STOP detected; main agent not running"
    fi
    kill_run_processes
    log "watchdog exiting"
    exit 0
  fi

  if [[ -f "$PAUSED_FILE" ]]; then
    mtime="$(get_mtime_epoch "$PAUSED_FILE" 2>/dev/null || echo 0)"
    if [[ "$mtime" != "$last_paused_mtime" ]]; then
      log "PAUSED present; watchdog will idle until removed (see $PAUSED_FILE)"
      last_paused_mtime="$mtime"
    fi
    if main_is_alive; then
      log "PAUSED present; terminating main agent"
      stop_main_orchestrator
    fi
    kill_run_processes
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

  if ! main_is_alive; then
    cleanup_stale_runtime_state
    log "main agent not running; starting..."
    "$START_SCRIPT" "$WORKDIR" >>"$WATCHDOG_LOG" 2>&1 || true
  fi

  if [[ -f "$HEARTBEAT_FILE" ]]; then
    now="$(date +%s)"
    hb="$(get_mtime_epoch "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
    age=$((now - hb))
    if (( age > STALE_SECS )); then
      if main_is_alive; then
        log "heartbeat stale (${age}s); restarting main agent"
        stop_main_orchestrator
      else
        log "heartbeat stale (${age}s); main agent already down"
      fi
      kill_run_processes
      cleanup_stale_runtime_state
      "$START_SCRIPT" "$WORKDIR" >>"$WATCHDOG_LOG" 2>&1 || true
    fi
  else
    log "heartbeat missing; waiting for main agent to create it"
  fi

  sleep "$CHECK_EVERY_SECS"
done
