from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "skills" / "agent-team-orchestrator" / "assets" / "orchestrator"
ORCHESTRATOR = ASSET_DIR / "orchestrate.sh"
START_MAIN = ASSET_DIR / "start-main.sh"
WATCHDOG = ASSET_DIR / "watchdog.sh"
PROMPTS_DIR = ASSET_DIR / "prompts"


def _write_fake_codex(fake_codex_path: Path) -> None:
    fake_codex_path.write_text(
        """#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    state_path = Path(os.environ["FAKE_CODEX_STATE"])
    payload = json.loads(state_path.read_text())
    index = payload.get("index", 0)
    steps = payload["steps"]
    if index >= len(steps):
        raise SystemExit("fake codex ran out of scripted steps")

    step = steps[index]
    payload["index"] = index + 1
    state_path.write_text(json.dumps(payload))

    args = sys.argv[1:]
    output_last = None
    for idx, arg in enumerate(args):
        if arg == "--output-last-message" and idx + 1 < len(args):
            output_last = Path(args[idx + 1])
            break

    prompt = sys.stdin.read()
    if "Review scope:" in prompt:
        role = "review"
    elif "# Role: developer" in prompt:
        role = "developer"
    else:
        role = "main"
    expected_role = step["role"]
    if role != expected_role:
        raise SystemExit(f"expected role {expected_role}, got {role}")

    stdout = step.get("stdout", "")
    if stdout:
        sys.stdout.write(stdout)
        if not stdout.endswith("\\n"):
            sys.stdout.write("\\n")

    if output_last and "last" in step:
        output_last.write_text(step["last"], encoding="utf-8")

    mutate_file = step.get("mutate_file")
    if mutate_file:
        target = Path(mutate_file)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(step.get("mutate_content", ""), encoding="utf-8")

    mutate_from_env = step.get("mutate_from_env")
    if mutate_from_env:
        targets = mutate_from_env if isinstance(mutate_from_env, list) else [mutate_from_env]
        for item in targets:
            target = Path(str(item["path"]))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(os.environ.get(str(item["env"]), ""), encoding="utf-8")

    return int(step.get("exit_code", 0))


if __name__ == "__main__":
    raise SystemExit(main())
""",
        encoding="utf-8",
    )
    fake_codex_path.chmod(0o755)


def _setup_temp_repo(tmp_path: Path, steps: list[dict[str, object]]) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    repo.mkdir()

    shutil.copy2(ORCHESTRATOR, repo / "orchestrate.sh")
    shutil.copy2(START_MAIN, repo / "start-main.sh")
    shutil.copy2(WATCHDOG, repo / "watchdog.sh")
    (repo / ".codex" / "agent-team").mkdir(parents=True)

    for prompt_name in ("main.prompt.md", "developer.prompt.md", "review.prompt.md"):
        shutil.copy2(PROMPTS_DIR / prompt_name, repo / ".codex" / "agent-team" / prompt_name)

    (repo / ".codex" / "agent-team" / "STATE.md").write_text(
        "# STATE\n\n## Goal\n- test\n\n## Constraints\n- test\n\n## Definition of Done\n- test\n\n## Working Context\n- test\n",
        encoding="utf-8",
    )
    (repo / ".codex" / "agent-team" / "TODO.md").write_text(
        "# TODO\n- [ ] Finish the scripted task\n",
        encoding="utf-8",
    )

    tracked = repo / "tracked.txt"
    tracked.write_text("baseline\n", encoding="utf-8")
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True, text=True)
    subprocess.run(["git", "config", "user.email", "tests@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Tests"], cwd=repo, check=True)
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo, check=True, capture_output=True, text=True)

    fake_codex = tmp_path / "fake-codex"
    _write_fake_codex(fake_codex)
    state_file = tmp_path / "fake-codex-state.json"
    state_file.write_text(json.dumps({"index": 0, "steps": steps}), encoding="utf-8")
    fake_codex_wrapper = tmp_path / "fake-codex-wrapper"
    fake_codex_wrapper.write_text(
        "#!/usr/bin/env bash\n"
        f"export FAKE_CODEX_STATE={state_file}\n"
        f"exec {fake_codex} \"$@\"\n",
        encoding="utf-8",
    )
    fake_codex_wrapper.chmod(0o755)
    return repo, state_file


def _run_orchestrator(
    repo: Path, state_file: Path, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CODEX_BIN"] = str(state_file.parent / "fake-codex-wrapper")
    env["MAX_REVIEW_ROUNDS"] = "3"
    env["MAX_PHASE_RETRIES"] = "2"
    env["SUBPROCESS_POLL_SECS"] = "0"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(repo / "orchestrate.sh")],
        cwd=repo,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _run_start_main(
    repo: Path, state_file: Path, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["CODEX_BIN"] = str(state_file.parent / "fake-codex-wrapper")
    env["MAX_REVIEW_ROUNDS"] = "3"
    env["MAX_PHASE_RETRIES"] = "2"
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(repo / "start-main.sh"), str(repo)],
        cwd=repo,
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_orchestrator_stops_at_deadline_and_writes_final_summary(tmp_path: Path) -> None:
    repo, state_file = _setup_temp_repo(tmp_path, steps=[])
    (repo / ".codex" / "agent-team" / "DEADLINE_AT").write_text(
        "2000-01-01T00:00:00+00:00\n", encoding="utf-8"
    )

    result = _run_orchestrator(repo, state_file)

    assert result.returncode == 0
    assert (repo / ".codex" / "agent-team" / "DEADLINE_STOPPED").exists()
    assert not (repo / ".codex" / "agent-team" / "DONE").exists()
    summary = (repo / ".codex" / "agent-team" / "FINAL_SUMMARY.md").read_text(encoding="utf-8")
    assert "Reason: deadline reached" in summary
    assert "Pending tasks: 1" in summary
    assert json.loads(state_file.read_text(encoding="utf-8"))["index"] == 0


def test_orchestrator_runs_milestone_hook_after_task_completion(tmp_path: Path) -> None:
    steps = [
        {
            "role": "developer",
            "last": "Outcome: ready_for_review\nSummary: ready\nTests: not run\nFiles: tracked.txt\n",
            "mutate_file": "tracked.txt",
            "mutate_content": "after developer\n",
        },
        {"role": "review", "last": "No findings.\nResidual risk: none.\n", "stdout": "No findings.\n"},
    ]
    repo, state_file = _setup_temp_repo(tmp_path, steps)

    hook_file = repo / "hook.txt"
    result = _run_orchestrator(
        repo,
        state_file,
        {
            "MILESTONE_HOOK_CMD": f"printf '%s|%s|%s' \"$HOOK_TASK_LINE_NO\" \"$HOOK_TASK_TEXT\" \"$HOOK_COMPLETED_TASKS\" > {hook_file}",
        },
    )

    assert result.returncode == 0
    assert (repo / ".codex" / "agent-team" / "DONE").exists()
    assert hook_file.exists()
    assert hook_file.read_text(encoding="utf-8") == "2|Finish the scripted task|1"


def test_start_main_writes_deadline_file_and_passes_hook_env(tmp_path: Path) -> None:
    steps = [
        {
            "role": "main",
            "last": "main launched\n",
            "mutate_from_env": {
                "path": "main-hook-env.txt",
                "env": "MILESTONE_HOOK_CMD",
            },
        }
    ]
    repo, state_file = _setup_temp_repo(tmp_path, steps)

    result = _run_start_main(
        repo,
        state_file,
        {
            "DEADLINE_AT": "2030-01-02T03:04:05+00:00",
            "MILESTONE_HOOK_CMD": "echo hook-ran",
        },
    )

    assert result.returncode == 0
    deadline_file = repo / ".codex" / "agent-team" / "DEADLINE_AT"
    assert deadline_file.exists()
    assert deadline_file.read_text(encoding="utf-8").strip() == "2030-01-02T03:04:05+00:00"

    env_file = repo / "main-hook-env.txt"
    for _ in range(50):
        if env_file.exists():
            break
        subprocess.run(["sleep", "0.1"], check=True)
    assert env_file.exists()
    assert env_file.read_text(encoding="utf-8") == "echo hook-ran"


def test_watchdog_exits_when_deadline_stopped_exists(tmp_path: Path) -> None:
    repo, _ = _setup_temp_repo(tmp_path, steps=[])
    loop_dir = repo / ".codex" / "agent-team"
    (loop_dir / "DEADLINE_STOPPED").write_text("deadline reached\n", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(repo / "watchdog.sh"), str(repo)],
        cwd=repo,
        env={**os.environ, "CHECK_EVERY_SECS": "1", "STALE_SECS": "1"},
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )

    assert result.returncode == 0
    log_text = (loop_dir / "watchdog.log").read_text(encoding="utf-8")
    assert "DEADLINE_STOPPED present; watchdog exiting" in log_text
