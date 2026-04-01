#!/usr/bin/env python3
"""Git command wrappers."""

import subprocess
from datetime import datetime, timezone
from typing import Optional, Tuple


def run(cmd: list, **kwargs) -> subprocess.CompletedProcess:
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(cmd, **kwargs)


def get_branch() -> str:
    result = run(["git", "symbolic-ref", "--short", "HEAD"])
    if result.returncode != 0:
        result = run(["git", "rev-parse", "--short", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def get_branch_type(branch: str) -> str:
    if branch.startswith("feature/"):
        return "feature"
    if branch.startswith("fix/") or branch.startswith("bugfix/"):
        return "fix"
    if branch.startswith("hotfix/"):
        return "hotfix"
    return "other"


def count_uncommitted_files() -> int:
    result = run(["git", "status", "--porcelain"])
    if result.returncode != 0:
        return 0
    return len([l for l in result.stdout.strip().splitlines() if l])


def count_uncommitted_lines() -> int:
    result = run(["git", "diff", "--stat"])
    if result.returncode != 0:
        return 0
    # Parse "X files changed, Y insertions(+), Z deletions(-)"
    stat = result.stdout.strip()
    total = 0
    for part in stat.split(","):
        part = part.strip()
        if "insertion" in part:
            try:
                total += int(part.split()[0])
            except (IndexError, ValueError):
                pass
        if "deletion" in part:
            try:
                total += int(part.split()[0])
            except (IndexError, ValueError):
                pass
    return total


def get_last_tag() -> str:
    result = run(["git", "describe", "--tags", "--abbrev=0"])
    return result.stdout.strip() if result.returncode == 0 else ""


def get_commits_since_tag(tag: str) -> int:
    if not tag:
        return 0
    result = run(["git", "rev-list", "--count", "HEAD", f"^{tag}"])
    if result.returncode == 0:
        try:
            return int(result.stdout.strip())
        except ValueError:
            pass
    return 0


def get_last_commit_message() -> str:
    result = run(["git", "log", "-1", "--format=%s"])
    return result.stdout.strip() if result.returncode == 0 else ""


def get_last_commit_timestamp() -> str:
    result = run(["git", "log", "-1", "--format=%aI"])
    ts = result.stdout.strip() if result.returncode == 0 else ""
    if not ts:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return ts


def git_fetch(remote: str = "origin") -> bool:
    result = run(["git", "fetch", remote])
    return result.returncode == 0


def git_add_and_commit(message: str) -> bool:
    result = run(["git", "add", "-A"])
    if result.returncode != 0:
        return False
    result = run(["git", "commit", "-q", "-m", message])
    return result.returncode == 0


def git_reset_soft(ref: str) -> bool:
    result = run(["git", "reset", "--soft", ref])
    return result.returncode == 0


def git_force_push_with_lease(remote: str = "origin", branch: Optional[str] = None) -> Tuple[bool, str]:
    branch = branch or get_branch()
    result = run(["git", "push", "--force-with-lease", remote, branch])
    return result.returncode == 0, result.stderr or result.stdout


def git_checkout(branch: str) -> bool:
    result = run(["git", "checkout", branch])
    return result.returncode == 0


def git_merge(branch: str, message: str) -> bool:
    result = run(["git", "merge", branch, "--no-ff", "-m", message])
    return result.returncode == 0


def git_tag_create(tag: str) -> bool:
    result = run(["git", "tag", tag])
    return result.returncode == 0


def git_push(remote: str, ref: str) -> bool:
    result = run(["git", "push", remote, ref])
    return result.returncode == 0


def git_branch_delete(branch: str, force: bool = False) -> bool:
    flag = "-D" if force else "-d"
    result = run(["git", "branch", flag, branch])
    return result.returncode == 0


def git_create_branch(branch: str, start_ref: str = "HEAD") -> bool:
    result = run(["git", "checkout", "-b", branch, start_ref])
    return result.returncode == 0


def is_on_protected_branch(branch: str) -> bool:
    protected = ("main", "master", "develop")
    return branch in protected or branch.startswith("release/") or branch.startswith("hotfix/")


def is_safe_branch(branch: str) -> bool:
    unsafe = ("main", "master", "develop", "release/", "hotfix/")
    return not any(branch.startswith(u) for u in unsafe)
