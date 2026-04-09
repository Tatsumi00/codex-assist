#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR=".codex/loop"
TODO_FILE="$LOOP_DIR/TODO.md"
STATE_FILE="$LOOP_DIR/STATE.md"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"
STOP_FILE="$LOOP_DIR/STOP"
DONE_FILE="$LOOP_DIR/DONE"
PAUSED_FILE="$LOOP_DIR/PAUSED"
FAILED_FILE="$LOOP_DIR/FAILED.md"
RESTART_EACH_TASK_FILE="$LOOP_DIR/RESTART_EACH_TASK"
RESTART_EVERY_TASKS_FILE="$LOOP_DIR/RESTART_EVERY_TASKS"
RESTART_EVERY_SECS_FILE="$LOOP_DIR/RESTART_EVERY_SECS"
AUTO_SKIP_BLOCKED_FILE="$LOOP_DIR/AUTO_SKIP_BLOCKED"
SUBAGENTS_DIR="$LOOP_DIR/subagents"
SUBAGENT_PROMPT_FILE="$LOOP_DIR/subagent.prompt.md"
MAIN_LOCK_DIR="$LOOP_DIR/main.lock"
MAIN_LOCK_PID_FILE="$MAIN_LOCK_DIR/pid"

mkdir -p "$SUBAGENTS_DIR"

CODEX_BIN="${CODEX_BIN:-codex}"

write_heartbeat() {
  date +%s >"$HEARTBEAT_FILE" 2>/dev/null || true
}

normalize_task_line() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*//'
}

auto_skip_blocked_enabled() {
  case "${AUTO_SKIP_BLOCKED:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac
  [[ -f "$AUTO_SKIP_BLOCKED_FILE" ]]
}

read_int_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  python3 - "$path" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
m = re.search(r"-?\d+", text)
if not m:
    raise SystemExit(1)
print(int(m.group(0)))
PY
}

lock_owner_is_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q '[c]odex' || return 1
}

release_main_lock() {
  local owner_pid
  owner_pid="$(cat "$MAIN_LOCK_PID_FILE" 2>/dev/null || true)"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$MAIN_LOCK_PID_FILE" 2>/dev/null || true
    rmdir "$MAIN_LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_main_lock() {
  while true; do
    if mkdir "$MAIN_LOCK_DIR" 2>/dev/null; then
      echo "$$" >"$MAIN_LOCK_PID_FILE"
      trap 'release_main_lock' EXIT INT TERM
      return 0
    fi

    local owner_pid
    owner_pid="$(cat "$MAIN_LOCK_PID_FILE" 2>/dev/null || true)"
    if lock_owner_is_alive "$owner_pid"; then
      return 1
    fi

    rm -f "$MAIN_LOCK_PID_FILE" 2>/dev/null || true
    rmdir "$MAIN_LOCK_DIR" 2>/dev/null || true
    sleep 1
  done
}

ensure_state_file() {
  python3 - "$STATE_FILE" <<'PY'
from __future__ import annotations

from pathlib import Path
import re

path = Path(".codex/loop/STATE.md") if len(__import__("sys").argv) < 2 else Path(__import__("sys").argv[1])
legacy = path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""

TEMPLATE = """# STATE

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
"""

def _extract_legacy_field(text: str, name: str) -> str:
    m = re.search(rf"^\s*-\s*{re.escape(name)}\s*:\s*(.*)$", text, flags=re.M)
    if not m:
        return ""
    return m.group(1).strip()

def _migrate_if_needed(text: str) -> str:
    if "<!-- BEGIN AUTO NOW -->" in text:
        return text

    now = _extract_legacy_field(text, "Now")
    last = _extract_legacy_field(text, "Last")
    nxt = _extract_legacy_field(text, "Next")
    blockers = _extract_legacy_field(text, "Blockers")

    other_lines = []
    for line in text.splitlines():
        if line.strip() == "# STATE":
            continue
        if re.match(r"^\s*-\s*(Now|Last|Next|Blockers)\s*:", line):
            continue
        if line.strip():
            other_lines.append(line.rstrip())

    out = TEMPLATE
    if nxt:
        pattern_next = re.compile(r"^## Next\n.*?\n\n## Notes / Links\n", flags=re.S | re.M)
        out = pattern_next.sub("## Next\n- " + nxt + "\n\n## Notes / Links\n", out)
    if other_lines:
        out += "\n\n## Notes (migrated)\n" + "\n".join(other_lines) + "\n"

    def set_auto(key: str, body: str) -> None:
        nonlocal out
        begin = f"<!-- BEGIN AUTO {key} -->"
        end = f"<!-- END AUTO {key} -->"
        repl = begin + "\n" + (body.strip() or "- none") + "\n" + end
        pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), flags=re.S)
        out = pattern.sub(repl, out)

    if now:
        set_auto("NOW", "- " + now)
    if last:
        set_auto("LAST", "- " + last)
    if blockers:
        set_auto("BLOCKERS", "- " + blockers)
    return out

text = legacy.strip()
if not text:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(TEMPLATE, encoding="utf-8")
else:
    migrated = _migrate_if_needed(legacy)
    if migrated != legacy:
        path.write_text(migrated.rstrip() + "\n", encoding="utf-8")
PY
}

state_set_auto() {
  local key="$1"
  ensure_state_file
  python3 -c 'from __future__ import annotations

import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2].upper()
body = sys.stdin.read().rstrip("\n")

text = path.read_text(encoding="utf-8", errors="ignore")

begin = f"<!-- BEGIN AUTO {key} -->"
end = f"<!-- END AUTO {key} -->"

replacement = begin + "\n" + (body.strip() or "- none") + "\n" + end

pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), flags=re.S)
if pattern.search(text):
    text = pattern.sub(replacement, text)
else:
    if key == "NEXT" and "## Next" in text:
        section = re.compile(r"(?sm)^## Next\n.*?(?=^##\s|\Z)")
        text = section.sub("## Next\n" + replacement + "\n\n", text)
    else:
        title = {
            "NOW": "Now (auto)",
            "LAST": "Last (auto)",
            "BLOCKERS": "Blockers (auto)",
            "NEXT": "Next",
        }.get(key, f"{key} (auto)")
        text = text.rstrip() + f"\n\n## {title}\n{replacement}\n"

path.write_text(text.rstrip() + "\n", encoding="utf-8")' "$STATE_FILE" "$key"
}

next_task() {
  python3 - <<'PY'
from pathlib import Path

todo = Path(".codex/loop/TODO.md")
if not todo.exists():
    raise SystemExit(0)

for i, line in enumerate(todo.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1):
    if line.lstrip().startswith("- [ ]"):
        print(f"{i}\t{line.rstrip()}")
        raise SystemExit(0)
PY
}

mark_done() {
  local line_no="$1"
  python3 - "$line_no" <<'PY'
import sys
from pathlib import Path

line_no = int(sys.argv[1])
todo = Path(".codex/loop/TODO.md")
lines = todo.read_text(encoding="utf-8", errors="ignore").splitlines(True)
if not (1 <= line_no <= len(lines)):
    raise SystemExit(0)

lines[line_no - 1] = lines[line_no - 1].replace("- [ ]", "- [x]", 1)
todo.write_text("".join(lines), encoding="utf-8")
PY
}

mark_skipped() {
  local line_no="$1"
  local outcome="$2"
  python3 - "$line_no" "$outcome" <<'PY'
import sys
from pathlib import Path

line_no = int(sys.argv[1])
outcome = sys.argv[2]
todo = Path(".codex/loop/TODO.md")
lines = todo.read_text(encoding="utf-8", errors="ignore").splitlines(True)
if not (1 <= line_no <= len(lines)):
    raise SystemExit(0)

line = lines[line_no - 1]
line = line.replace("- [ ]", "- [~]", 1)
line = line.rstrip("\n")
if f"(auto-skip:{outcome})" not in line:
    line += f" (auto-skip:{outcome})"
lines[line_no - 1] = line + "\n"
todo.write_text("".join(lines), encoding="utf-8")
PY
}

append_failed_log() {
  local run_id="$1"
  local outcome="$2"
  local rc="$3"
  local task_line="$4"
  local run_dir="$5"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    if [[ ! -f "$FAILED_FILE" ]]; then
      echo "# FAILED"
    fi
    echo "- [$now] run=$run_id outcome=$outcome exit=$rc task=${task_line#- [ ] } see=$run_dir/last.md"
  } >>"$FAILED_FILE"
}

parse_outcome() {
  local last_file="$1"
  python3 - "$last_file" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

text = path.read_text(encoding="utf-8", errors="ignore")
m = re.search(r"^\s*Outcome\s*[:：]\s*([a-zA-Z_-]+)", text, flags=re.I | re.M)
if not m:
    raise SystemExit(2)
print(m.group(1).strip().lower())
PY
}

run_done_guard() {
  local run_dir="$1"
  if [[ -z "${DONE_GUARD_CMD:-}" ]]; then
    return 0
  fi
  printf '%s\n' "$DONE_GUARD_CMD" >"$run_dir/guard.cmd"
  set +e
  bash -lc "$DONE_GUARD_CMD" >"$run_dir/guard.log" 2>&1
  local guard_rc=$?
  set -e
  printf '%s\n' "$guard_rc" >"$run_dir/guard.exit"
  if (( guard_rc == 0 )); then
    return 0
  fi
  return "$guard_rc"
}

pause_for_guard_failure() {
  local run_id="$1"
  local guard_rc="$2"
  local task_line="$3"
  local run_dir="$4"

  append_failed_log "$run_id" "guard_failed" "$guard_rc" "$task_line" "$run_dir"

  cat >"$PAUSED_FILE" <<EOF
PAUSED (created $(date '+%Y-%m-%d %H:%M:%S'))
workdir: $(pwd)
run: $run_id
outcome: guard_failed
exit: $guard_rc
task: $task_line
guard_cmd: $DONE_GUARD_CMD
see: $run_dir/guard.log

Fix the issue, update TODO/STATE if needed, then remove this file to resume:
  rm "$PAUSED_FILE"
EOF

  state_set_auto "NOW" <<'EOF'
- paused
EOF
  state_set_auto "BLOCKERS" <<EOF
- [$run_id] guard_failed exit=$guard_rc (see $run_dir/guard.log)
EOF
  next_task_text="$(normalize_task_line "$task_line")"
  state_set_auto "NEXT" <<EOF
- $next_task_text
EOF
}

kill_subagent() {
  local pid="$1"
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}

if [[ ! -f "$SUBAGENT_PROMPT_FILE" ]]; then
  echo "Missing $SUBAGENT_PROMPT_FILE. Run start-main.sh once to scaffold prompts." >&2
  exit 2
fi

if ! acquire_main_lock; then
  write_heartbeat
  exit 0
fi

START_TS="$(date +%s)"
TASKS_DONE=0

while true; do
  ensure_state_file

  if [[ -f "$PAUSED_FILE" ]]; then
    write_heartbeat
    exit 0
  fi

  if [[ -f "$STOP_FILE" ]]; then
    state_set_auto "NOW" <<'EOF'
- stopping (STOP file present)
EOF
    state_set_auto "NEXT" <<'EOF'
- none
EOF
    write_heartbeat
    exit 0
  fi

  task_row="$(next_task || true)"
  if [[ -z "${task_row:-}" ]]; then
    touch "$DONE_FILE"
    state_set_auto "NOW" <<'EOF'
- idle (no pending tasks)
EOF
    state_set_auto "NEXT" <<'EOF'
- none
EOF
    write_heartbeat
    exit 0
  fi

  line_no="${task_row%%$'\t'*}"
  task_line="${task_row#*$'\t'}"

  run_id="$(date +%s)"
  run_dir="$SUBAGENTS_DIR/$run_id"
  mkdir -p "$run_dir"
  printf 'todo_line_number=%s\n%s\n' "$line_no" "$task_line" >"$run_dir/task.txt"

  state_set_auto "NOW" <<EOF
- [$run_id] $task_line
EOF
  next_task_text="$(normalize_task_line "$task_line")"
  state_set_auto "NEXT" <<EOF
- $next_task_text
EOF

  sub_prompt="$run_dir/prompt.md"
  {
    cat "$SUBAGENT_PROMPT_FILE"
    echo
    echo "TASK:"
    echo "$task_line"
  } >"$sub_prompt"

  approval="${APPROVAL_POLICY:-never}"
  sandbox="${SUBAGENT_SANDBOX_MODE:-${SANDBOX_MODE:-danger-full-access}}"

  cmd=("$CODEX_BIN")
  if [[ -n "${CODEX_MODEL:-}" ]]; then
    cmd+=("-m" "$CODEX_MODEL")
  fi
  cmd+=("-a" "$approval" "exec" "-s" "$sandbox")
  cmd+=(
    "--skip-git-repo-check"
    "--color" "never"
    "-C" "."
    "--output-last-message" "$run_dir/last.md"
    "-"
  )

  printf '%q ' "${cmd[@]}" >"$run_dir/cmd.txt"
  printf '\n' >>"$run_dir/cmd.txt"

  "${cmd[@]}" <"$sub_prompt" >"$run_dir/run.log" 2>&1 &

  sub_pid=$!
  echo "$sub_pid" >"$run_dir/pid"

  stop_requested=0
  while kill -0 "$sub_pid" 2>/dev/null; do
    write_heartbeat
    if [[ -f "$STOP_FILE" ]]; then
      state_set_auto "NOW" <<EOF
- stopping (terminating subagent pid=$sub_pid)
EOF
      stop_requested=1
      kill_subagent "$sub_pid"
      break
    fi
    sleep 20
  done
  set +e
  wait "$sub_pid"
  rc=$?
  set -e

  if (( stop_requested == 1 )); then
    state_set_auto "LAST" <<EOF
- [$run_id] stopped (subagent pid=$sub_pid exit=$rc)
EOF
    state_set_auto "NOW" <<'EOF'
- stopping (STOP file present)
EOF
    write_heartbeat
    exit 0
  fi

  outcome=""
  outcome="$(parse_outcome "$run_dir/last.md" 2>/dev/null || true)"
  if [[ -z "${outcome:-}" ]]; then
    outcome="unknown"
  fi

  state_set_auto "LAST" <<EOF
- [$run_id] outcome=$outcome exit=$rc (see $run_dir/last.md)
EOF

  if [[ "$outcome" == "done" ]]; then
    if ! run_done_guard "$run_dir"; then
      guard_rc="$(cat "$run_dir/guard.exit" 2>/dev/null || true)"
      if [[ -z "$guard_rc" ]]; then
        guard_rc=1
      fi
      state_set_auto "LAST" <<EOF
- [$run_id] guard_failed exit=$guard_rc (see $run_dir/guard.log)
EOF
      pause_for_guard_failure "$run_id" "$guard_rc" "$task_line" "$run_dir"
      write_heartbeat
      exit 0
    fi

    mark_done "$line_no" || true
    TASKS_DONE=$((TASKS_DONE + 1))
    state_set_auto "NOW" <<'EOF'
- idle
EOF
    state_set_auto "BLOCKERS" <<'EOF'
- none
EOF
    next_row="$(next_task || true)"
    if [[ -n "${next_row:-}" ]]; then
      next_line="${next_row#*$'\t'}"
      next_task_text="$(normalize_task_line "$next_line")"
      state_set_auto "NEXT" <<EOF
- $next_task_text
EOF
    else
      state_set_auto "NEXT" <<'EOF'
- none
EOF
    fi
  elif [[ "$outcome" == "partial" || "$outcome" == "blocked" || "$outcome" == "unknown" ]]; then
    if auto_skip_blocked_enabled; then
      mark_skipped "$line_no" "$outcome" || true
      append_failed_log "$run_id" "$outcome" "$rc" "$task_line" "$run_dir"
      state_set_auto "NOW" <<EOF
- auto-skip ($outcome), continuing
EOF
      state_set_auto "BLOCKERS" <<EOF
- latest auto-skip: [$run_id] outcome=$outcome exit=$rc (see $run_dir/last.md)
EOF
      next_row="$(next_task || true)"
      if [[ -n "${next_row:-}" ]]; then
        next_line="${next_row#*$'\t'}"
        next_task_text="$(normalize_task_line "$next_line")"
        state_set_auto "NEXT" <<EOF
- $next_task_text
EOF
      else
        state_set_auto "NEXT" <<'EOF'
- none
EOF
      fi
      write_heartbeat
      continue
    fi

    cat >"$PAUSED_FILE" <<EOF
PAUSED (created $(date '+%Y-%m-%d %H:%M:%S'))
workdir: $(pwd)
run: $run_id
outcome: $outcome
exit: $rc
task: $task_line
see: $run_dir/last.md

Fix the issue, update TODO/STATE if needed, then remove this file to resume:
  rm "$PAUSED_FILE"
EOF
    state_set_auto "NOW" <<'EOF'
- paused
EOF
    state_set_auto "BLOCKERS" <<EOF
- [$run_id] outcome=$outcome exit=$rc (see $run_dir/last.md)
EOF
    next_task_text="$(normalize_task_line "$task_line")"
    state_set_auto "NEXT" <<EOF
- $next_task_text
EOF
    write_heartbeat
    exit 0
  fi

  write_heartbeat

  if [[ -f "$RESTART_EACH_TASK_FILE" ]]; then
    exit 0
  fi

  if n_tasks="$(read_int_file "$RESTART_EVERY_TASKS_FILE" 2>/dev/null)"; then
    if (( n_tasks > 0 && TASKS_DONE >= n_tasks )); then
      exit 0
    fi
  fi

  if n_secs="$(read_int_file "$RESTART_EVERY_SECS_FILE" 2>/dev/null)"; then
    now="$(date +%s)"
    if (( n_secs > 0 && (now - START_TS) >= n_secs )); then
      exit 0
    fi
  fi
done
