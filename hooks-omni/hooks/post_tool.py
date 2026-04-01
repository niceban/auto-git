#!/usr/bin/env python3
"""post_tool hook — detect test PASS and checkpoint auto-commit threshold."""

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import acquire_lock, state_read, state_write, get_branch
from lib.config import config_get_int, config_get
from lib.git import count_uncommitted_files, count_uncommitted_lines, git_add_and_commit
from lib.hook import parse_hook_input, get_tool_name, silent_exit
from lib.logger import log_event

_TEST_PASS_PATTERNS = [
    r"\bPASS\b", r"\bok\b", r"\b✓\b",
    r"All tests passed", r"\bpassed\b(?! [a-z])", r"100%\s*passed",
]


def detect_test_pass(output: str) -> bool:
    """Detect test PASS patterns in tool output."""
    for p in _TEST_PASS_PATTERNS:
        if re.search(p, output, re.IGNORECASE):
            return True
    return False


def checkpoint_if_needed() -> None:
    """Auto-commit if thresholds exceeded."""
    files = count_uncommitted_files()
    lines = count_uncommitted_lines()

    threshold_files = config_get_int("uncommitted_files_threshold", 5)
    threshold_lines = config_get_int("uncommitted_lines_threshold", 1000)

    if files < threshold_files and lines < threshold_lines:
        return

    prefix = config_get("auto_commit_message_prefix", "checkpoint: auto-save")
    msg = f"{prefix} {datetime.now().strftime('%Y%m%d-%H%M%S')}"

    if git_add_and_commit(msg):
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        last_msg = subprocess.run(
            ["git", "log", "-1", "--format=%s"],
            capture_output=True, text=True
        ).stdout.strip()
        with acquire_lock("post_tool"):
            state = state_read()
            state["last_commit_at"] = now
            state["last_commit_message"] = last_msg
            state_write(state)


def main():
    tool = get_tool_name()
    if tool not in ("Bash", "Write"):
        silent_exit()

    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "PostToolUse":
        silent_exit()

    # Get tool output
    output = ""
    if isinstance(hook_input.get("toolResult"), dict):
        output = hook_input["toolResult"].get("output", "")

    # Detect test PASS
    detected_pass = detect_test_pass(output)
    if detected_pass:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with acquire_lock("post_tool"):
            state = state_read()
            state["test_passed"] = True
            state["test_passed_at"] = now
            state_write(state)

    # Check checkpoint thresholds
    checkpoint_if_needed()

    log_event(
        hook_name="post_tool",
        event_type="called",
        outcome="success",
        command="",
        trigger_reason="test_pass" if detected_pass else "",
        extra={"test_passed": detected_pass},
    )
    silent_exit()


if __name__ == "__main__":
    main()
