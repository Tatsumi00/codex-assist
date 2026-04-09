# codex-assist

Reusable Codex skills for long-running repository work.

## Included skills

### `agent-team-orchestrator`

A planner-driven repo workflow that enforces:

- task planning via `STATE.md` and `TODO.md`
- developer implementation rounds
- mandatory `codex review`
- retry / pause / resume behavior
- watchdog recovery

Current status:

- hardened and smoke-tested
- `tmux` is the preferred long-run host
- `nohup` remains as a fallback start mode

Source:

- `skills/agent-team-orchestrator/SKILL.md`

### `codex-subagent-orchestrator`

A lighter long-run queue runner that keeps the main agent small and spawns fresh subagents per TODO item.

Current status:

- included as-is
- usable baseline
- reliability hardening is still planned

Source:

- `skills/codex-subagent-orchestrator/SKILL.md`

## Layout

```text
skills/
  agent-team-orchestrator/
  codex-subagent-orchestrator/
```

Each skill keeps its own:

- `SKILL.md`
- `agents/`
- `assets/`
- `scripts/`

## Notes

- This repo is a source repository for the skills themselves, not a single runnable app.
- The agent-team variant is the more production-ready option right now.
- The subagent long-run variant is intentionally kept here so it can be hardened next.
