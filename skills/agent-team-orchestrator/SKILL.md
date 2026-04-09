---
name: agent-team-orchestrator
description: "Set up a persistent Codex agent team for repository work where the main Codex session acts as planner/orchestrator, generates or refreshes a task plan, and then continuously executes that plan with at least two roles for each task: a developer agent that implements the task and a codex review phase that must pass before the task is marked done. Use when the user wants long-running autonomous work in a repo, a plan-driven backlog executor, or a repeatable develop-then-review loop with watchdog recovery."
---

# Agent Team Orchestrator

Install the scaffold into the target repo:

`python3 ~/.codex/skills/agent-team-orchestrator/scripts/install.py --workdir <REPO_DIR>`

This creates an `agent-team-orchestrator/` folder in the repo and uses `.codex/agent-team/` for state.

## Operate

Seed the mission in `.codex/agent-team/STATE.md`:

- Fill `Goal`
- Fill `Constraints`
- Fill `Definition of Done`
- Keep `Working Context` short and durable

Then start the long-running processes:

- Main orchestrator: `./agent-team-orchestrator/start-main.sh <REPO_DIR>`
- Watchdog: `./agent-team-orchestrator/watchdog.sh <REPO_DIR>`

Stop with either:

- `touch <REPO_DIR>/.codex/agent-team/STOP`
- `./agent-team-orchestrator/stop-main.sh <REPO_DIR>`

## Workflow

The installed workflow is:

1. Main Codex session reads `STATE.md` and `TODO.md`
2. If the task list is missing, placeholder, or `REPLAN` exists, the main session generates or refreshes the plan
3. The orchestrator loop picks the next unchecked task
4. A developer agent implements the task and reports `Outcome: ready_for_review` when the change is ready
5. `codex review` runs on the current workspace changes
6. If review passes, the task is marked done; if review fails, the feedback is fed back into another developer attempt
7. If a task blocks, review keeps failing, or validation fails, the loop pauses and waits for human intervention

## Task Design Rules

Write plan items as small, reviewable units. Good tasks are:

- one feature slice
- one bug fix
- one refactor with a clear boundary
- one documentation or test addition tied to a concrete code change

Avoid TODO items that bundle many unrelated subsystems.

## Files

The scaffold manages these files under `.codex/agent-team/`:

- `STATE.md`: durable goal, constraints, and compact progress state
- `TODO.md`: ordered checklist of planned tasks
- `REPLAN`: optional flag; if present, the main orchestrator rewrites the pending plan
- `PAUSED`: created when a task needs intervention
- `DONE`: created when no unchecked tasks remain
- `runs/`: per-attempt developer and review logs

## Guardrails

- Prefer a dedicated branch or otherwise controlled worktree. `codex review --uncommitted` is most reliable when unrelated changes are not mixed into the same workspace.
- Use `DONE_GUARD_CMD='your test command'` before `start-main.sh` if a task should only be checked off after an external validation command passes.
- Keep `Working Context` in `STATE.md` short. Put durable decisions there, not large transcripts.

## Customize

Useful environment variables for `start-main.sh` and `watchdog.sh`:

- `CODEX_MODEL`: set the model for developer and main sessions
- `SANDBOX_MODE`: default `danger-full-access`
- `APPROVAL_POLICY`: default `never`
- `MAX_REVIEW_ROUNDS`: maximum developer/review iterations per task
- `SUBPROCESS_POLL_SECS`: developer/review worker poll interval, default `2`
- `DONE_GUARD_CMD`: command that must exit `0` before a reviewed task is marked done
- `STALE_SECS`: watchdog heartbeat timeout

If you need to tune agent behavior, edit the prompt templates copied into `.codex/agent-team/` after the first start:

- `main.prompt.md`
- `developer.prompt.md`
- `review.prompt.md`
