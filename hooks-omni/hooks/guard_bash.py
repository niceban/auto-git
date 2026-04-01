#!/usr/bin/env python3
"""guard_bash hook — block dangerous commands on protected branches."""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import get_branch, state_read, state_write, acquire_lock
from lib.git import git_create_branch, is_on_protected_branch
from lib.hook import (
    parse_hook_input, get_tool_name,
    output_permission_denied, output_permission_allowed, silent_exit
)
from lib.logger import log_event

# Dangerous patterns on protected branches
_DANGEROUS_PATTERNS = [
    (r"git\s+push.*\bmain\b", "git push to main is denied on protected branch"),
    (r"git\s+push.*\bmaster\b", "git push to master is denied on protected branch"),
    (r"git\s+push\s+--force(?!\s+--force-with-lease)(?=$|\s)", "git push --force requires --force-with-lease"),
    (r"git\s+push\s+-[fF](?!\s+--force-with-lease)(?=$|\s)", "git push -f requires --force-with-lease"),
    (r"git\s+reset\s+--hard", "git reset --hard is denied on protected branches"),
    (r"git\s+clean\s+-[xX]", "git clean -x/-X is denied on protected branches"),
    (r"git\s+branch\s+-d\s+main", "cannot delete main branch"),
    (r"git\s+branch\s+-D\s+main", "cannot delete main branch"),
    (r"git\s+branch\s+-d\s+master", "cannot delete master branch"),
    (r"git\s+branch\s+-D\s+master", "cannot delete master branch"),
    (r"git\s+merge.*\binto\s+(main|master)\b", "git merge onto main/master is denied"),
    (r"git\s+rebase.*\bonto\s+(main|master)\b", "git rebase onto main/master is denied"),
]

# Redirection dangerous patterns
_REDIRECT_PATTERNS = [
    (r">\s*/", "dangerous absolute redirection"),
    (r">>\s*/", "dangerous absolute redirection"),
    (r"\btee\s+.*>", "dangerous tee redirection"),
]


def is_dangerous(cmd: str) -> tuple:
    """Check if command matches dangerous patterns. Returns (dangerous, reason)."""
    for pattern, reason in _DANGEROUS_PATTERNS:
        if re.search(pattern, cmd, re.IGNORECASE):
            return True, reason
    for pattern, reason in _REDIRECT_PATTERNS:
        if re.search(pattern, cmd, re.IGNORECASE):
            return True, reason
    return False, ""


def auto_create_feature_branch(cmd: str) -> bool:
    """If git commit on main, create feature branch and commit there."""
    if not re.match(r"git\s+commit\b", cmd, re.IGNORECASE):
        return False
    branch = get_branch()
    if branch not in ("main", "master"):
        return False

    import subprocess, shlex
    from datetime import datetime
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    new_branch = f"feature/autosave-{ts}"

    # Create feature branch from current HEAD
    result = subprocess.run(["git", "checkout", "-b", new_branch],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return False

    # Commit on new branch (use shlex.split to handle quoted args)
    result = subprocess.run(shlex.split(cmd), capture_output=True, text=True)
    return result.returncode == 0


def main():
    tool = get_tool_name()
    if tool != "Bash":
        log_event(hook_name="guard_bash", event_type="called", outcome="skipped", trigger_reason="not_bash")
        output_permission_allowed()

    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "PreToolUse":
        log_event(hook_name="guard_bash", event_type="called", outcome="skipped", trigger_reason="not_pretool")
        output_permission_allowed()

    # Get command from input
    cmd = ""
    if isinstance(hook_input.get("toolUseInput"), dict):
        cmd = hook_input["toolUseInput"].get("command", "")
    if not cmd:
        # Fallback: read from HOOK_COMMAND env
        cmd = os.environ.get("HOOK_COMMAND", "")

    if not cmd:
        log_event(hook_name="guard_bash", event_type="called", outcome="skipped", trigger_reason="no_command")
        output_permission_allowed()

    branch = get_branch()

    # Check for git commit on main → auto-create branch
    if re.match(r"git\s+commit\b", cmd, re.IGNORECASE):
        if is_on_protected_branch(branch):
            if auto_create_feature_branch(cmd):
                # Committed on new branch, allow
                log_event(hook_name="guard_bash", event_type="called", outcome="allowed", command=cmd, trigger_reason="auto_branch_commit")
                output_permission_allowed()
            else:
                log_event(hook_name="guard_bash", event_type="called", outcome="blocked", command=cmd, trigger_reason="auto_branch_failed")
                output_permission_denied("Failed to create feature branch for commit on main")

    # Not on protected branch → allow
    if not is_on_protected_branch(branch):
        log_event(hook_name="guard_bash", event_type="called", outcome="allowed", command=cmd, trigger_reason="not_protected")
        output_permission_allowed()

    # On protected branch → check for dangerous commands
    dangerous, reason = is_dangerous(cmd)
    if dangerous:
        log_event(hook_name="guard_bash", event_type="called", outcome="blocked", command=cmd, trigger_reason=reason)
        output_permission_denied(reason)

    log_event(hook_name="guard_bash", event_type="called", outcome="allowed", command=cmd, trigger_reason="safe_command")
    output_permission_allowed()


if __name__ == "__main__":
    main()
