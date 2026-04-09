#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import stat
from pathlib import Path


def _ensure_executable(path: Path) -> None:
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _ensure_gitignore_line(workdir: Path, line: str) -> None:
    gitignore_path = workdir / ".gitignore"
    if gitignore_path.exists():
        text = gitignore_path.read_text(encoding="utf-8", errors="ignore")
        if line in text.splitlines():
            return
        with gitignore_path.open("a", encoding="utf-8") as handle:
            if text and not text.endswith("\n"):
                handle.write("\n")
            handle.write(line + "\n")
        return
    gitignore_path.write_text(line + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install the persistent agent-team orchestrator scaffold into a repo."
    )
    parser.add_argument(
        "--workdir",
        default=".",
        help="Target repo/work directory (default: current directory).",
    )
    parser.add_argument(
        "--target",
        default="agent-team-orchestrator",
        help="Target folder name inside workdir (default: agent-team-orchestrator).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the existing target folder if present.",
    )
    parser.add_argument(
        "--no-gitignore",
        action="store_true",
        help="Do not add .codex/agent-team/ to .gitignore.",
    )
    args = parser.parse_args()

    workdir = Path(args.workdir).expanduser().resolve()
    skill_root = Path(__file__).resolve().parents[1]
    src_dir = skill_root / "assets" / "orchestrator"
    dst_dir = workdir / args.target

    if not src_dir.exists():
        raise SystemExit(f"Missing assets directory: {src_dir}")
    if not workdir.exists():
        raise SystemExit(f"Workdir does not exist: {workdir}")

    if dst_dir.exists():
        if args.force:
            shutil.rmtree(dst_dir)
        else:
            raise SystemExit(f"Target already exists: {dst_dir} (use --force to overwrite)")

    shutil.copytree(src_dir, dst_dir)

    for script_name in ("start-main.sh", "watchdog.sh", "stop-main.sh", "orchestrate.sh"):
        _ensure_executable(dst_dir / script_name)

    if not args.no_gitignore:
        _ensure_gitignore_line(workdir, ".codex/agent-team/")

    print(f"Installed: {dst_dir}")
    print("Next:")
    print(f"  {dst_dir}/start-main.sh {workdir}")
    print(f"  {dst_dir}/watchdog.sh {workdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
