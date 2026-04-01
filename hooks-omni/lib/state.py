#!/usr/bin/env python3
"""State management with atomic file locking via fcntl."""

import fcntl
import json
import os
import shutil
import subprocess
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

PLUGIN_DIR = Path(os.environ.get(
    "BRANCH_AUTONOMOUS_DIR",
    Path.home() / ".claude" / "plugins" / "branch-autonomous"
))
STATE_FILE = PLUGIN_DIR / "state.json"
STATE_LOCK = PLUGIN_DIR / "state.lock"
LOCK_FILE = PLUGIN_DIR / ".lock"


@contextmanager
def acquire_lock(name: str = "hook", timeout: float = 5.0):
    """Acquire exclusive lock using flock. Raises on timeout."""
    lock_path = LOCK_FILE
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as f:
        start = time.monotonic()
        while True:
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() - start >= timeout:
                    raise TimeoutError(f"Lock acquisition timeout: {name}")
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def state_read() -> dict:
    """Read state.json, return empty dict if missing or corrupted."""
    if not STATE_FILE.exists():
        return {}
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, PermissionError, IOError):
        return {}


def state_write(data: dict) -> None:
    """Atomic write: temp file + rename."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)


def state_update(jq_program: str) -> None:
    """Apply jq-style update to state.json with locking.
    Supports formats like:
      .key = "value"
      .key = true|false|null
      .key = $ENV_VAR
    """
    with acquire_lock("state_update"):
        data = state_read()
        for part in jq_program.split("|"):
            part = part.strip()
            if not part:
                continue
            # Split on first '=' to separate key from value
            if "=" not in part:
                continue
            key, val = part.split("=", 1)
            key = key.strip().lstrip(".")
            val = val.strip()
            if not key:
                continue
            if val == "true":
                data[key] = True
            elif val == "false":
                data[key] = False
            elif val == "null":
                data[key] = None
            elif val.startswith('"$'):
                data[key] = os.environ.get(val[2:-1], "")
            elif val.startswith('"') and val.endswith('"'):
                data[key] = val[1:-1]
        state_write(data)


def state_get(key: str) -> Any:
    """Get a single key from state."""
    data = state_read()
    return data.get(key)


def detect_base_ref() -> str:
    """Detect base ref (main or master)."""
    for base in ("main", "master"):
        result = subprocess.run(
            ["git", "rev-parse", "--verify", f"origin/{base}"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return base
    # fallback to HEAD
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else "HEAD"


def get_branch() -> str:
    """Get current branch name."""
    result = subprocess.run(
        ["git", "symbolic-ref", "--short", "HEAD"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True
        )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def get_branch_type(branch: str) -> str:
    """Derive branch type from branch name."""
    if branch.startswith("feature/"):
        return "feature"
    if branch.startswith("fix/"):
        return "fix"
    if branch.startswith("hotfix/"):
        return "hotfix"
    return "other"


def init_state(branch: Optional[str] = None) -> dict:
    """Initialize state.json with v4.0 schema."""
    branch = branch or get_branch()
    branch_type = get_branch_type(branch)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Get last tag info
    last_tag = ""
    commits_since_tag = 0
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        last_tag = result.stdout.strip()
        result = subprocess.run(
            ["git", "rev-list", "--count", "HEAD", f"^{last_tag}"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            commits_since_tag = int(result.stdout.strip())

    # Get last commit info
    last_commit_at = now
    last_commit_message = ""
    result = subprocess.run(
        ["git", "log", "-1", "--format=%aI"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        last_commit_at = result.stdout.strip()
    result = subprocess.run(
        ["git", "log", "-1", "--format=%s"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        last_commit_message = result.stdout.strip()

    # Preserve workflow flags if resuming same branch
    existing = state_read()
    if existing.get("branch") == branch:
        awaiting_squash_push = existing.get("awaiting_squash_push", False)
        awaiting_merge_confirmation = existing.get("awaiting_merge_confirmation", False)
        milestone_pending = existing.get("milestone_pending", False)
        semantic_intent = existing.get("semantic_intent", False)
        test_passed = existing.get("test_passed", False)
    else:
        awaiting_squash_push = False
        awaiting_merge_confirmation = False
        milestone_pending = False
        semantic_intent = False
        test_passed = False

    state = {
        "version": "4.0",
        "branch": branch,
        "branch_type": branch_type,
        "test_passed": test_passed,
        "test_passed_at": None,
        "test_failed_at": None,
        "uncommitted_files": 0,
        "uncommitted_lines": 0,
        "last_commit_at": last_commit_at,
        "last_commit_message": last_commit_message,
        "milestone": False,
        "milestone_reason": None,
        "awaiting_squash_push": awaiting_squash_push,
        "awaiting_merge_confirmation": awaiting_merge_confirmation,
        "commits_since_last_tag": commits_since_tag,
        "created_at": now,
        "semantic_intent": semantic_intent,
        "semantic_intent_reason": None,
        "last_prompt": "",
        "last_intent_at": None,
        "milestone_command_invoked": False,
        "milestone_command_msg": None,
        "milestone_pending": milestone_pending,
        "milestone_pending_reason": None,
        "milestone_pending_squash_suggestion": None,
        "milestone_pending_branch": None,
        "milestone_pending_commits": 0,
        "backup_branch": None,
        "backup_created_at": None,
    }
    with acquire_lock("init_state"):
        state_write(state)
    return state
