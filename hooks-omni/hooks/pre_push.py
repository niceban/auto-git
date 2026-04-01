#!/usr/bin/env python3
"""pre_push hook — execute squash push when awaiting_squash_push is true."""

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import (
    acquire_lock, state_read, state_write,
    get_branch, detect_base_ref
)
from lib.git import (
    git_reset_soft, git_force_push_with_lease,
    git_fetch, git_create_branch
)
from lib.hook import parse_hook_input, get_tool_name, silent_exit, output_permission_allowed
from lib.logger import log_event


def build_squash_message(branch: str, base_ref: str) -> str:
    """Build squash commit message from commit log, filtering checkpoint commits."""
    result = subprocess.run(
        ["git", "log", "--format=%s", f"{base_ref}..HEAD"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return f"squash({branch}): update"

    msgs = result.stdout.strip().splitlines()
    filtered = [m for m in msgs if not re.match(r"^checkpoint:", m)]
    if not filtered:
        filtered = msgs[-3:] if msgs else ["update"]

    return f"squash({branch}): {' | '.join(filtered[:10])}"


def create_backup_branch(branch: str) -> str:
    """Create backup branch before squash."""
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    backup = f"backup/{branch}-{ts}"
    result = subprocess.run(
        ["git", "branch", backup],
        capture_output=True, text=True
    )
    return backup if result.returncode == 0 else ""


def detect_remote_divergence(remote: str, base_ref: str) -> bool:
    """Check if remote main has diverged from local."""
    git_fetch(remote)
    result = subprocess.run(
        ["git", "log", "--left-right", f"{remote}/{base_ref}...HEAD", "--oneline"],
        capture_output=True, text=True
    )
    if result.returncode == 0 and result.stdout.strip():
        return bool(result.stdout.strip())
    return False


def execute_squash() -> tuple:
    """Execute squash push workflow. Returns (success, message)."""
    branch = get_branch()
    base = detect_base_ref()
    remote = "origin"

    with acquire_lock("pre_push"):
        state = state_read()
        if not state.get("awaiting_squash_push"):
            return False, "not awaiting squash push"

        # Create backup
        backup = create_backup_branch(branch)
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Detect divergence
        diverged = detect_remote_divergence(remote, base)
        if diverged:
            return False, f"remote {base} has diverged from local"

        # Build squash message
        squash_msg = build_squash_message(branch, f"origin/{base}")

        # Execute squash
        if not git_reset_soft(f"origin/{base}"):
            return False, f"git reset --soft origin/{base} failed"

        # Commit
        result = subprocess.run(
            ["git", "commit", "-m", squash_msg],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return False, f"git commit failed: {result.stderr}"

        # Push
        ok, err = git_force_push_with_lease(remote, branch)
        if not ok:
            return False, f"git push failed: {err}"

        # Update state
        state["awaiting_squash_push"] = False
        state["awaiting_merge_confirmation"] = True
        state["backup_branch"] = backup
        state["backup_created_at"] = now
        state_write(state)

    return True, "squash push complete"


def main():
    tool = get_tool_name()
    if tool != "Bash":
        output_permission_allowed()

    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "PreToolUse":
        output_permission_allowed()

    success, msg = execute_squash()
    log_event(
        hook_name="pre_push",
        event_type="called",
        outcome="success" if success else "skipped",
        trigger_reason=msg,
    )
    if not success:
        import sys
        print(f"pre_push: {msg}", file=sys.stderr)

    output_permission_allowed()


if __name__ == "__main__":
    main()
