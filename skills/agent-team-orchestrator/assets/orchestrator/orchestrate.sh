#!/usr/bin/env bash
set -euo pipefail

LOOP_DIR=".codex/agent-team"
TODO_FILE="$LOOP_DIR/TODO.md"
STATE_FILE="$LOOP_DIR/STATE.md"
HEARTBEAT_FILE="$LOOP_DIR/heartbeat"
STOP_FILE="$LOOP_DIR/STOP"
DONE_FILE="$LOOP_DIR/DONE"
PAUSED_FILE="$LOOP_DIR/PAUSED"
FAILED_FILE="$LOOP_DIR/FAILED.md"
REPLAN_FILE="$LOOP_DIR/REPLAN"
DEADLINE_FILE="$LOOP_DIR/DEADLINE_AT"
DEADLINE_STOPPED_FILE="$LOOP_DIR/DEADLINE_STOPPED"
FINAL_SUMMARY_FILE="$LOOP_DIR/FINAL_SUMMARY.md"
RUNS_DIR="$LOOP_DIR/runs"
TASK_BASELINES_DIR="$LOOP_DIR/task-baselines"
MAIN_LOCK_DIR="$LOOP_DIR/main.lock"
MAIN_LOCK_PID_FILE="$MAIN_LOCK_DIR/pid"
DEVELOPER_PROMPT_FILE="$LOOP_DIR/developer.prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/review.prompt.md"

mkdir -p "$RUNS_DIR"
mkdir -p "$TASK_BASELINES_DIR"

CODEX_BIN="${CODEX_BIN:-codex}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
MAX_PHASE_RETRIES="${MAX_PHASE_RETRIES:-2}"
SUBPROCESS_POLL_SECS="${SUBPROCESS_POLL_SECS:-2}"
DONE_GUARD_CMD="${DONE_GUARD_CMD:-}"
MILESTONE_HOOK_CMD="${MILESTONE_HOOK_CMD:-}"

write_heartbeat() {
  date +%s >"$HEARTBEAT_FILE" 2>/dev/null || true
}

normalize_task_line() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*//'
}

read_int() {
  python3 - "$1" <<'PY'
import sys

value = sys.argv[1].strip()
try:
    print(int(value))
except ValueError:
    raise SystemExit(1)
PY
}

count_pending_tasks() {
  if [[ ! -f "$TODO_FILE" ]]; then
    echo 0
    return 0
  fi
  grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]' "$TODO_FILE" 2>/dev/null || echo 0
}

count_completed_tasks() {
  if [[ ! -f "$TODO_FILE" ]]; then
    echo 0
    return 0
  fi
  grep -cE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]' "$TODO_FILE" 2>/dev/null || echo 0
}

deadline_epoch() {
  [[ -f "$DEADLINE_FILE" ]] || return 1
  python3 - "$DEADLINE_FILE" <<'PY'
from datetime import datetime
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").strip()
if not text:
    raise SystemExit(1)
normalized = text.replace("Z", "+00:00")
dt = datetime.fromisoformat(normalized)
if dt.tzinfo is None:
    raise SystemExit(2)
print(int(dt.timestamp()))
PY
}

deadline_is_reached() {
  local deadline
  deadline="$(deadline_epoch 2>/dev/null || true)"
  [[ -n "$deadline" ]] || return 1
  local now
  now="$(date +%s)"
  (( now >= deadline ))
}

write_final_summary() {
  local reason="$1"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  local pending
  pending="$(count_pending_tasks)"
  local completed
  completed="$(count_completed_tasks)"
  local next_row
  next_row="$(next_task || true)"
  local next_text="none"
  if [[ -n "${next_row:-}" ]]; then
    next_text="$(normalize_task_line "${next_row#*$'\t'}")"
  fi
  cat >"$FINAL_SUMMARY_FILE" <<EOF
# FINAL SUMMARY

- Reason: $reason
- Finished at: $now
- Completed tasks: $completed
- Pending tasks: $pending
- Next pending task: $next_text
- Workdir: $(pwd)
EOF
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
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
template = """# STATE

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
"""

text = path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""
if not text.strip():
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(template, encoding="utf-8")
    raise SystemExit(0)

required = {
    "NOW": "## Now (auto)",
    "LAST": "## Last (auto)",
    "BLOCKERS": "## Blockers (auto)",
    "NEXT": "## Next (auto)",
}
for key, title in required.items():
    begin = f"<!-- BEGIN AUTO {key} -->"
    end = f"<!-- END AUTO {key} -->"
    if begin in text and end in text:
      continue
    section = f"\n\n{title}\n{begin}\n- none\n{end}\n"
    text = text.rstrip() + section

if "## Notes / Links" not in text:
    text = text.rstrip() + "\n\n## Notes / Links\n- (Freeform)\n"

path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
}

state_set_auto() {
  local key="$1"
  local body="${2:-}"
  ensure_state_file
  STATE_AUTO_BODY="$body" python3 - "$STATE_FILE" "$key" <<'PY'
import re
import sys
import os
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2].upper()
body = os.environ.get("STATE_AUTO_BODY", "").rstrip("\n")
text = path.read_text(encoding="utf-8", errors="ignore")
begin = f"<!-- BEGIN AUTO {key} -->"
end = f"<!-- END AUTO {key} -->"
replacement = begin + "\n" + (body.strip() or "- none") + "\n" + end
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), flags=re.S)
if pattern.search(text):
    text = pattern.sub(replacement, text)
else:
    titles = {
        "NOW": "Now (auto)",
        "LAST": "Last (auto)",
        "BLOCKERS": "Blockers (auto)",
        "NEXT": "Next (auto)",
    }
    title = titles.get(key, f"{key} (auto)")
    text = text.rstrip() + f"\n\n## {title}\n" + replacement + "\n"
path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY
}

next_task() {
  python3 - <<'PY'
from pathlib import Path

todo = Path(".codex/agent-team/TODO.md")
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
todo = Path(".codex/agent-team/TODO.md")
lines = todo.read_text(encoding="utf-8", errors="ignore").splitlines(True)
if not (1 <= line_no <= len(lines)):
    raise SystemExit(0)

lines[line_no - 1] = lines[line_no - 1].replace("- [ ]", "- [x]", 1)
todo.write_text("".join(lines), encoding="utf-8")
PY
}

append_failed_log() {
  local run_id="$1"
  local phase="$2"
  local outcome="$3"
  local rc="$4"
  local task_line="$5"
  local run_dir="$6"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    if [[ ! -f "$FAILED_FILE" ]]; then
      echo "# FAILED"
    fi
    echo "- [$now] run=$run_id phase=$phase outcome=$outcome exit=$rc task=${task_line#- [ ] } see=$run_dir"
  } >>"$FAILED_FILE"
}

parse_outcome() {
  local last_file="$1"
  python3 - "$last_file" <<'PY'
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

file_contains_turn_interrupted() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import sys
from pathlib import Path

lines = [line.strip().lower() for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").splitlines()]
meaningful = [line for line in lines if line]
tail = meaningful[-8:]
raise SystemExit(0 if any(line == "turn interrupted" for line in tail) else 1)
PY
}

file_contains_cli_usage_error() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import sys
from pathlib import Path

lines = [line.strip().lower() for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").splitlines()]
meaningful = [line for line in lines if line]
head = meaningful[:8]
head_blob = "\n".join(head)

if head and head[0].startswith("error:"):
    raise SystemExit(0)
if head and head[0].startswith("usage:"):
    raise SystemExit(0)
if "the argument" in head_blob and "usage:" in head_blob:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

review_passes() {
  local review_file="$1"
  local review_last_file="${2:-}"
  python3 - "$review_file" "$review_last_file" <<'PY'
import re
import sys
from pathlib import Path

review_path = Path(sys.argv[1])
review_last_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
text = ""
if review_last_path and review_last_path.exists():
    text = review_last_path.read_text(encoding="utf-8", errors="ignore").lower()
elif review_path.exists():
    text = review_path.read_text(encoding="utf-8", errors="ignore").lower()

pass_patterns = [
    r"\bno findings\b",
    r"\bno actionable findings\b",
    r"\bno blocking findings\b",
    r"\bi found no issues\b",
    r"\bno issues found\b",
]
for pattern in pass_patterns:
    if re.search(pattern, text):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

run_done_guard() {
  local run_dir="$1"
  if [[ -z "$DONE_GUARD_CMD" ]]; then
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

run_milestone_hook() {
  local run_dir="$1"
  local line_no="$2"
  local task_text="$3"
  if [[ -z "$MILESTONE_HOOK_CMD" ]]; then
    return 0
  fi
  printf '%s\n' "$MILESTONE_HOOK_CMD" >"$run_dir/hook.cmd"
  local completed pending
  completed="$(count_completed_tasks)"
  pending="$(count_pending_tasks)"
  set +e
  HOOK_RUN_DIR="$run_dir" \
  HOOK_LOOP_DIR="$LOOP_DIR" \
  HOOK_TASK_LINE_NO="$line_no" \
  HOOK_TASK_TEXT="$task_text" \
  HOOK_COMPLETED_TASKS="$completed" \
  HOOK_PENDING_TASKS="$pending" \
    bash -lc "$MILESTONE_HOOK_CMD" >"$run_dir/hook.log" 2>&1
  local hook_rc=$?
  set -e
  printf '%s\n' "$hook_rc" >"$run_dir/hook.exit"
  if (( hook_rc == 0 )); then
    return 0
  fi
  return "$hook_rc"
}

kill_process_tree() {
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

wait_with_heartbeat() {
  local pid="$1"
  local label="$2"
  while kill -0 "$pid" 2>/dev/null; do
    write_heartbeat
    if [[ -f "$STOP_FILE" ]]; then
      state_set_auto "NOW" "- stopping ($label pid=$pid)"
      kill_process_tree "$pid"
      break
    fi
    sleep "$SUBPROCESS_POLL_SECS"
  done
  set +e
  wait "$pid"
  local rc=$?
  set -e
  return "$rc"
}

pause_with_message() {
  local run_id="$1"
  local phase="$2"
  local outcome="$3"
  local rc="$4"
  local task_line="$5"
  local see_path="$6"

  cat >"$PAUSED_FILE" <<EOF
PAUSED (created $(date '+%Y-%m-%d %H:%M:%S'))
workdir: $(pwd)
run: $run_id
phase: $phase
outcome: $outcome
exit: $rc
task: $task_line
see: $see_path

Fix the issue, update TODO/STATE if needed, then remove this file to resume:
  rm "$PAUSED_FILE"
EOF

  state_set_auto "NOW" "- paused"
  state_set_auto "BLOCKERS" "- [$run_id] $phase outcome=$outcome exit=$rc (see $see_path)"
  next_task_text="$(normalize_task_line "$task_line")"
  state_set_auto "NEXT" "- $next_task_text"
}

if [[ ! -f "$DEVELOPER_PROMPT_FILE" || ! -f "$REVIEW_PROMPT_FILE" ]]; then
  echo "Missing prompt files under $LOOP_DIR. Run start-main.sh once to scaffold them." >&2
  exit 2
fi

if ! acquire_main_lock; then
  write_heartbeat
  exit 0
fi

while true; do
  ensure_state_file

  if [[ -f "$PAUSED_FILE" ]]; then
    write_heartbeat
    exit 0
  fi

  if [[ -f "$STOP_FILE" ]]; then
    state_set_auto "NOW" "- stopping (STOP file present)"
    state_set_auto "NEXT" "- none"
    write_final_summary "stop requested"
    write_heartbeat
    exit 0
  fi

  if deadline_is_reached; then
    touch "$DEADLINE_STOPPED_FILE"
    rm -f "$DONE_FILE" 2>/dev/null || true
    next_row="$(next_task || true)"
    if [[ -n "${next_row:-}" ]]; then
      next_line="${next_row#*$'\t'}"
      state_set_auto "NEXT" "- $(normalize_task_line "$next_line")"
    else
      state_set_auto "NEXT" "- none"
    fi
    state_set_auto "NOW" "- stopped (deadline reached)"
    state_set_auto "LAST" "- deadline reached before starting a new task"
    state_set_auto "BLOCKERS" "- none"
    write_final_summary "deadline reached"
    write_heartbeat
    exit 0
  fi

  task_row="$(next_task || true)"
  if [[ -z "${task_row:-}" ]]; then
    touch "$DONE_FILE"
    rm -f "$DEADLINE_STOPPED_FILE" 2>/dev/null || true
    rm -f "$REPLAN_FILE" 2>/dev/null || true
    state_set_auto "NOW" "- idle (no pending tasks)"
    state_set_auto "BLOCKERS" "- none"
    state_set_auto "NEXT" "- none"
    write_final_summary "all tasks completed"
    write_heartbeat
    exit 0
  fi

  line_no="${task_row%%$'\t'*}"
  task_line="${task_row#*$'\t'}"
  task_text="$(normalize_task_line "$task_line")"

  state_set_auto "NOW" "- working: $task_text"
  state_set_auto "BLOCKERS" "- none"
  state_set_auto "NEXT" "- $task_text"

  review_round=1
  review_feedback_file=""
  task_baseline_dir="$TASK_BASELINES_DIR/$line_no"
  mkdir -p "$task_baseline_dir"

  while true; do
    run_id="$(date +%s)-${line_no}-${review_round}"
    run_dir="$RUNS_DIR/$run_id"
    mkdir -p "$run_dir"
    printf 'line=%s\nround=%s\ntask=%s\n' "$line_no" "$review_round" "$task_text" >"$run_dir/meta.txt"
    if [[ "$review_round" -eq 1 && ! -f "$task_baseline_dir/review.base.status.z" ]]; then
      git status --porcelain=v1 -z >"$task_baseline_dir/review.base.status.z"
      python3 - "$task_baseline_dir" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys

baseline_dir = Path(sys.argv[1])
snapshots_dir = baseline_dir / "files"
if snapshots_dir.exists():
    shutil.rmtree(snapshots_dir)
snapshots_dir.mkdir(parents=True, exist_ok=True)

blob = subprocess.run(
    ["git", "status", "--porcelain=v1", "-z"],
    capture_output=True,
    text=True,
    check=True,
).stdout

paths = []
i = 0
n = len(blob)
while i < n:
    if blob[i] == "\0":
        i += 1
        continue
    code = blob[i:i+2]
    i += 3
    end = blob.index("\0", i)
    path = blob[i:end]
    i = end + 1
    if code[0] in "RC":
        end2 = blob.index("\0", i)
        path = blob[i:end2]
        i = end2 + 1
    paths.append(path)

for rel in paths:
    src = Path(rel)
    if src.exists() and src.is_file():
        dst = snapshots_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
PY
    fi

    developer_attempt=1
    while true; do
      state_set_auto "NOW" "- developer round $review_round attempt $developer_attempt: $task_text"

      developer_prompt="$run_dir/developer.prompt.md"
      {
        cat "$DEVELOPER_PROMPT_FILE"
        echo
        echo "TASK:"
        echo "$task_line"
        if [[ -n "$review_feedback_file" && -f "$review_feedback_file" ]]; then
          echo
          echo "REVIEW FEEDBACK TO ADDRESS:"
          cat "$review_feedback_file"
        fi
      } >"$developer_prompt"

      rm -f "$run_dir/developer.last.md" "$run_dir/developer.run.log" "$run_dir/developer.pid"
      dev_cmd=("$CODEX_BIN")
      if [[ -n "${CODEX_MODEL:-}" ]]; then
        dev_cmd+=("-m" "$CODEX_MODEL")
      fi
      dev_cmd+=("-a" "${APPROVAL_POLICY:-never}" "exec" "-s" "${SUBAGENT_SANDBOX_MODE:-${SANDBOX_MODE:-danger-full-access}}")
      dev_cmd+=("--skip-git-repo-check" "--color" "never" "-C" ".")
      dev_cmd+=("--output-last-message" "$run_dir/developer.last.md" "-")
      printf '%q ' "${dev_cmd[@]}" >"$run_dir/developer.cmd.txt"
      printf '\n' >>"$run_dir/developer.cmd.txt"
      "${dev_cmd[@]}" <"$developer_prompt" >"$run_dir/developer.run.log" 2>&1 &
      dev_pid=$!
      echo "$dev_pid" >"$run_dir/developer.pid"

      if wait_with_heartbeat "$dev_pid" "developer"; then
        dev_rc=0
      else
        dev_rc=$?
      fi

      if [[ -f "$STOP_FILE" ]]; then
        state_set_auto "LAST" "- [$run_id] stopped during developer round $review_round"
        write_heartbeat
        exit 0
      fi

      dev_outcome="$(parse_outcome "$run_dir/developer.last.md" 2>/dev/null || true)"
      if [[ -z "${dev_outcome:-}" ]]; then
        dev_outcome="unknown"
      fi

      if [[ "$dev_outcome" == "ready_for_review" || "$dev_outcome" == "done" ]]; then
        state_set_auto "LAST" "- [$run_id] developer outcome=$dev_outcome exit=$dev_rc (see $run_dir/developer.last.md)"
        break
      fi

      if file_contains_turn_interrupted "$run_dir/developer.run.log" && (( developer_attempt < MAX_PHASE_RETRIES )); then
        state_set_auto "LAST" "- [$run_id] developer interrupted; retrying attempt $((developer_attempt + 1))"
        developer_attempt=$((developer_attempt + 1))
        write_heartbeat
        continue
      fi

      if file_contains_cli_usage_error "$run_dir/developer.run.log"; then
        append_failed_log "$run_id" "developer" "developer_cli_error" "$dev_rc" "$task_line" "$run_dir"
        pause_with_message "$run_id" "developer" "developer_cli_error" "$dev_rc" "$task_line" "$run_dir/developer.run.log"
        write_heartbeat
        exit 0
      fi

      state_set_auto "LAST" "- [$run_id] developer outcome=$dev_outcome exit=$dev_rc (see $run_dir/developer.run.log)"
      append_failed_log "$run_id" "developer" "$dev_outcome" "$dev_rc" "$task_line" "$run_dir"
      pause_with_message "$run_id" "developer" "$dev_outcome" "$dev_rc" "$task_line" "$run_dir/developer.run.log"
      write_heartbeat
      exit 0
    done

    review_attempt=1
    state_set_auto "NOW" "- review round $review_round: $task_text"

    review_prompt="$run_dir/review.prompt.md"
    python3 - "$run_dir" "$REVIEW_PROMPT_FILE" "$task_line" "$task_baseline_dir" <<'PY' >"$review_prompt"
from pathlib import Path
import subprocess
import sys

run_dir = Path(sys.argv[1])
template_path = Path(sys.argv[2])
task_line = sys.argv[3]
baseline_dir = Path(sys.argv[4])

def parse_status_z(blob: str):
    entries = []
    untracked = set()
    i = 0
    n = len(blob)
    while i < n:
      if blob[i] == "\0":
        i += 1
        continue
      code = blob[i:i+2]
      i += 3
      end = blob.index("\0", i)
      path = blob[i:end]
      i = end + 1
      if code[0] in "RC":
        end2 = blob.index("\0", i)
        path = blob[i:end2]
        i = end2 + 1
      entries.append(path)
      if code == "??":
        untracked.add(path)
    return entries, untracked

baseline_blob = (baseline_dir / "review.base.status.z").read_text(encoding="utf-8", errors="ignore")
snapshots_dir = baseline_dir / "files"
current_blob = subprocess.run(
    ["git", "status", "--porcelain=v1", "-z"],
    capture_output=True,
    text=True,
    check=True,
).stdout

baseline_paths, baseline_untracked = parse_status_z(baseline_blob)
current_paths, current_untracked = parse_status_z(current_blob)
all_paths = sorted(set(baseline_paths) | set(current_paths))

def diff_pair(old_path, new_path):
    left = str(old_path) if old_path is not None else "/dev/null"
    right = str(new_path) if new_path is not None else "/dev/null"
    proc = subprocess.run(
        ["git", "diff", "--no-index", "--binary", "--", left, right],
        capture_output=True,
        text=True,
    )
    if proc.returncode not in (0, 1):
        raise subprocess.CalledProcessError(proc.returncode, proc.args, proc.stdout, proc.stderr)
    return proc.stdout.rstrip("\n")

file_diffs = []
for rel in all_paths:
    before = snapshots_dir / rel
    after = Path(rel)
    before_file = before if before.exists() and before.is_file() else None
    after_file = after if after.exists() and after.is_file() else None
    text = diff_pair(before_file, after_file)
    if text:
        file_diffs.append((rel, text))

bundle_lines = []
bundle_lines.append(template_path.read_text(encoding="utf-8", errors="ignore").rstrip("\n"))
bundle_lines.append("")
bundle_lines.append("TASK:")
bundle_lines.append(task_line)
bundle_lines.append("")
bundle_lines.append("Review scope:")
bundle_lines.append("- Only the diff bundle below.")
bundle_lines.append("- Baseline: workspace snapshot taken before the first developer round for this task.")
bundle_lines.append("")
bundle_lines.append("Current changed files:")
if file_diffs:
    for path, _ in file_diffs:
        bundle_lines.append(f"- {path}")
else:
    bundle_lines.append("(none)")
bundle_lines.append("")
bundle_lines.append("Diff bundle:")
if file_diffs:
    for path, text in file_diffs:
        bundle_lines.append(f"FILE: {path}")
        bundle_lines.append("```diff")
        bundle_lines.append(text)
        bundle_lines.append("```")
else:
    bundle_lines.append("(none)")

bundle_text = "\n".join(bundle_lines).rstrip("\n") + "\n"
(run_dir / "review.bundle.md").write_text(bundle_text, encoding="utf-8")
sys.stdout.write(bundle_text)
PY

    while true; do
      rm -f "$run_dir/review.last.md" "$run_dir/review.md" "$run_dir/review.pid"
      review_cmd=("$CODEX_BIN")
      if [[ -n "${CODEX_MODEL:-}" ]]; then
        review_cmd+=("-m" "$CODEX_MODEL")
      fi
      review_cmd+=("exec" "-s" "${SUBAGENT_SANDBOX_MODE:-${SANDBOX_MODE:-danger-full-access}}")
      review_cmd+=("--skip-git-repo-check" "--color" "never" "-C" "." "--output-last-message" "$run_dir/review.last.md" "-")
      printf '%q ' "${review_cmd[@]}" >"$run_dir/review.cmd.txt"
      printf '\n' >>"$run_dir/review.cmd.txt"
      cp "$review_prompt" "$run_dir/review.context.md"
      "${review_cmd[@]}" <"$review_prompt" >"$run_dir/review.md" 2>&1 &
      review_pid=$!
      echo "$review_pid" >"$run_dir/review.pid"

      if wait_with_heartbeat "$review_pid" "review"; then
        review_rc=0
      else
        review_rc=$?
      fi

      if [[ -f "$STOP_FILE" ]]; then
        state_set_auto "LAST" "- [$run_id] stopped during review round $review_round"
        write_heartbeat
        exit 0
      fi

      if review_passes "$run_dir/review.md" "$run_dir/review.last.md"; then
        state_set_auto "LAST" "- [$run_id] review passed (see $run_dir/review.md)"
        if ! run_done_guard "$run_dir"; then
          guard_rc="$(cat "$run_dir/guard.exit" 2>/dev/null || true)"
          [[ -n "$guard_rc" ]] || guard_rc=1
          append_failed_log "$run_id" "guard" "guard_failed" "$guard_rc" "$task_line" "$run_dir"
          pause_with_message "$run_id" "guard" "guard_failed" "$guard_rc" "$task_line" "$run_dir/guard.log"
          write_heartbeat
          exit 0
        fi

        mark_done "$line_no" || true
        state_set_auto "NOW" "- idle"
        state_set_auto "BLOCKERS" "- none"
        next_row="$(next_task || true)"
        if [[ -n "${next_row:-}" ]]; then
          next_line="${next_row#*$'\t'}"
          state_set_auto "NEXT" "- $(normalize_task_line "$next_line")"
        else
          state_set_auto "NEXT" "- none"
        fi
        if ! run_milestone_hook "$run_dir" "$line_no" "$task_text"; then
          hook_rc="$(cat "$run_dir/hook.exit" 2>/dev/null || true)"
          [[ -n "$hook_rc" ]] || hook_rc=1
          append_failed_log "$run_id" "hook" "hook_failed" "$hook_rc" "$task_line" "$run_dir"
          pause_with_message "$run_id" "hook" "hook_failed" "$hook_rc" "$task_line" "$run_dir/hook.log"
          write_heartbeat
          exit 0
        fi
        break 2
      fi

      if file_contains_turn_interrupted "$run_dir/review.md" && (( review_attempt < MAX_PHASE_RETRIES )); then
        state_set_auto "LAST" "- [$run_id] review interrupted; retrying attempt $((review_attempt + 1))"
        review_attempt=$((review_attempt + 1))
        write_heartbeat
        continue
      fi

      if file_contains_cli_usage_error "$run_dir/review.md"; then
        append_failed_log "$run_id" "review" "review_cli_error" "$review_rc" "$task_line" "$run_dir"
        pause_with_message "$run_id" "review" "review_cli_error" "$review_rc" "$task_line" "$run_dir/review.md"
        write_heartbeat
        exit 0
      fi

      append_failed_log "$run_id" "review" "findings" "$review_rc" "$task_line" "$run_dir"
      state_set_auto "LAST" "- [$run_id] review requested changes (see $run_dir/review.md)"

      if (( review_round >= MAX_REVIEW_ROUNDS )); then
        pause_with_message "$run_id" "review" "max_review_rounds" "$review_rc" "$task_line" "$run_dir/review.md"
        write_heartbeat
        exit 0
      fi

      review_feedback_file="$run_dir/review.md"
      review_round=$((review_round + 1))
      write_heartbeat
      break
    done
  done

  write_heartbeat
done
