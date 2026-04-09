---
name: codex-subagent-orchestrator
description: Set up and operate a long-running Codex orchestrator (main agent process that spawns fresh `codex exec` subagents per TODO item + a watchdog to restart on stalls) using disk-backed TODO/STATE files to run for hours while keeping context small. Use when you want Codex to keep working continuously, swap subagents frequently, or avoid context window blow-ups with restartable loops.
---

# Codex Subagent Orchestrator

## Install scaffold into a repo

Run:

`python3 ~/.codex/skills/codex-subagent-orchestrator/scripts/install.py --workdir <REPO_DIR>`

This creates (or updates) a `codex-orchestrator/` folder in the repo containing:

- `start-main.sh`: start the main Codex agent (background)
- `orchestrate.sh`: deterministic loop (pick next TODO → spawn subagent → heartbeat → mark done)
- `watchdog.sh`: monitor heartbeat and auto-restart main agent
- `stop-main.sh`: stop main agent and set STOP flag
- `prompts/`: main + subagent prompts

## Run

- Start main agent: `./codex-orchestrator/start-main.sh <REPO_DIR>`
- Start watchdog: `./codex-orchestrator/watchdog.sh <REPO_DIR>`

## Operate

- Add tasks to `.codex/loop/TODO.md` as `- [ ] ...`
- Watch `.codex/loop/STATE.md`, `.codex/loop/main.run.log`, and `.codex/loop/subagents/*/`
- Stop with `touch .codex/loop/STOP` (or run `./codex-orchestrator/stop-main.sh <REPO_DIR>`)

## Reliability defaults

- Single-instance lock is enabled: duplicate `orchestrate.sh` / `watchdog.sh` processes for the same workdir will exit immediately.
- Optional done gate: set `DONE_GUARD_CMD='your check command'` before `start-main.sh`; TODO is marked done only if this command exits with `0`.

## Keep context stable (recommended)

The “main agent” is intentionally dumb: it just runs `orchestrate.sh`.

To keep long-term continuity **without** blowing up the chat context window:

- The orchestrator edits short **auto** sections in `.codex/loop/STATE.md`: `Now/Last/Blockers/Next`.
- Durable context can live in `.codex/loop/STATE.md` (Goal / Constraints / DoD / Working Context), but **you don't have to maintain it manually**: subagents are prompted to read it and to write short durable bullets when they discover important decisions.
- If you truly want *zero* state maintenance, make each TODO item self-contained (include links/acceptance criteria). Then the system can run unattended until a task is blocked.

### Pause on non-done outcomes

If a subagent’s final message is not `Outcome: done` (e.g. `partial/blocked/unknown`), the orchestrator will:

- **not** check the TODO item
- create `.codex/loop/PAUSED` and exit
- watchdog will idle until you remove `PAUSED`

Resume: `rm .codex/loop/PAUSED`

### Optional restart policies (not default)

You can still periodically restart the main agent to keep it fresh:

- `.codex/loop/RESTART_EACH_TASK` → exit after each done task
- `.codex/loop/RESTART_EVERY_TASKS` (integer) → exit after N done tasks
- `.codex/loop/RESTART_EVERY_SECS` (integer) → exit after running for N seconds

## Sandbox/network note

Ensure the main agent’s command sandbox allows **network access**, otherwise spawning `codex exec` subagents from inside the main agent will fail.
