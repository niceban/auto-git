#!/usr/bin/env python3
"""stop hook — checkpoint threshold check + milestone detection + confirmation prompts."""

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import (
    acquire_lock, state_read, state_write,
    get_branch, detect_base_ref, get_last_tag, get_commits_since_tag,
    get_branch_type
)
from lib.config import config_get_int, config_get
from lib.git import (
    count_uncommitted_files, count_uncommitted_lines,
    git_add_and_commit, is_on_protected_branch
)
from lib.hook import (
    parse_hook_input,
    output_continue_suggestion, silent_exit
)
from lib.logger import log_event

_CONVENTIONAL_TYPES = (
    "feat", "fix", "perf", "ci", "docs", "test",
    "chore", "build", "refactor", "style", "ops", "revert"
)


def checkpoint_if_needed() -> None:
    """Run checkpoint threshold check from stop hook."""
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
        with acquire_lock("stop"):
            state = state_read()
            state["last_commit_at"] = now
            state["last_commit_message"] = last_msg
            state_write(state)


def get_diff_stats(base_ref: str) -> tuple:
    """Return (files, insertions, deletions)."""
    remote_ref = f"origin/{base_ref}"
    result = subprocess.run(
        ["git", "diff", "--shortstat", f"{remote_ref}..HEAD"],
        capture_output=True, text=True
    )
    stat = result.stdout.strip()
    files = insertions = deletions = 0
    if stat:
        for part in stat.split(","):
            part = part.strip()
            if "file" in part:
                try:
                    files = int(part.split()[0])
                except (IndexError, ValueError):
                    pass
            if "insertion" in part:
                try:
                    insertions = int(part.split()[0])
                except (IndexError, ValueError):
                    pass
            if "deletion" in part:
                try:
                    deletions = int(part.split()[0])
                except (IndexError, ValueError):
                    pass
    return files, insertions, deletions


def next_tag(current_tag: str) -> str:
    """Bump minor version."""
    if not current_tag or current_tag == "v0.0.0":
        return "v0.1.0"
    try:
        parts = current_tag.lstrip("v").split(".")
        major, minor = int(parts[0]), int(parts[1])
        return f"v{major}.{minor + 1}.0"
    except (IndexError, ValueError):
        return "v1.0.0"


def get_commit_messages(base_ref: str, limit: int = 10) -> str:
    """Get commit messages between base and HEAD, filtered."""
    result = subprocess.run(
        ["git", "log", "--format=%s", f"origin/{base_ref}..HEAD"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return ""
    msgs = result.stdout.strip().splitlines()
    filtered = [m for m in msgs if not re.match(r"^checkpoint:", m)]
    return "|".join(filtered[:limit])


def build_cc_suggestion(branch: str, msgs: str) -> str:
    """Build conventional commit suggestion."""
    branch_scope = branch.split("/", 1)[-1] if "/" in branch else branch
    first_msg = msgs.split("|")[0] if msgs else "update"
    first_msg = re.sub(r"^[a-z]+:\s*", "", first_msg)
    first_msg = re.sub(r"[^a-z0-9\s]", "", first_msg.lower())[:30]
    return f"feat({branch_scope}): {first_msg}"


def main():
    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "Stop":
        silent_exit()

    branch = get_branch()
    if branch in ("main", "master"):
        silent_exit()
    if is_on_protected_branch(branch):
        silent_exit()

    # Run checkpoint check
    checkpoint_if_needed()

    with acquire_lock("stop"):
        state = state_read()

        # Interaction Point 2: Merge confirmation
        if state.get("awaiting_merge_confirmation"):
            log_event(
                hook_name="stop",
                event_type="called",
                outcome="prompt",
                trigger_reason="merge_confirmation",
                extra={"branch": branch},
            )
            base = detect_base_ref()
            files, ins, dels = get_diff_stats(base)
            current_tag = get_last_tag() or "v0.0.0"
            nxt = next_tag(current_tag)

            prompt = (
                f"Merge ready! [{files} files, +{ins}/-{dels}] "
                f"Branch: {branch}. Tag: {current_tag} → {nxt}. "
                f"回复 /merge confirm 执行合并，或 /merge cancel 取消"
            )
            output_continue_suggestion(
                "Stop",
                prompt,
                [
                    {
                        "type": "text",
                        "title": "Merge Summary",
                        "content": f"Files: {files} | +{ins}/-{dels} | Branch: {branch}"
                    },
                    {
                        "type": "text",
                        "title": "Version Tag",
                        "content": f"Current: {current_tag} | Suggested: {nxt}"
                    },
                    {
                        "type": "reference",
                        "title": "Merge Ready",
                        "content": "awaiting_merge_confirmation=true | /merge confirm | /merge cancel"
                    }
                ]
            )
            return  # Not reached

        # Skip if in squash workflow
        if state.get("awaiting_squash_push"):
            silent_exit()

        # Skip if not WORKING
        workflow_state = state.get("workflow_state", "WORKING")
        if workflow_state not in ("WORKING", "null", None, ""):
            silent_exit()

        # Reprompt if milestone pending
        if state.get("milestone_pending"):
            log_event(
                hook_name="stop",
                event_type="called",
                outcome="prompt",
                trigger_reason="milestone_pending",
                extra={"reason": state.get("milestone_pending_reason")},
            )
            prompt = "/milestone confirm — 您有待确认的 milestone，请回复 /milestone 确认或 /milestone cancel"
            output_continue_suggestion(
                "Stop",
                prompt,
                [
                    {
                        "type": "reference",
                        "title": "Milestone Pending",
                        "content": f"reason={state.get('milestone_pending_reason')} | /milestone confirm | /milestone cancel"
                    }
                ]
            )
            return

        # Check milestone triggers
        commits_since_tag = get_commits_since_tag(get_last_tag())
        milestone_threshold = config_get_int("milestone_commits_threshold", 10)
        test_passed = state.get("test_passed", False)
        semantic_intent = state.get("semantic_intent", False)
        milestone_reason = None
        milestone = False

        # Trigger 1: semantic + test_passed
        if semantic_intent and test_passed:
            milestone = True
            milestone_reason = state.get("semantic_intent_reason", "semantic_trigger")

        # Trigger 2: commits threshold
        if not milestone and commits_since_tag >= milestone_threshold:
            milestone = True
            milestone_reason = "commits_threshold"

        # Trigger 3: conventional commit + test_passed
        if not milestone and test_passed:
            last_msg = subprocess.run(
                ["git", "log", "-1", "--format=%s"],
                capture_output=True, text=True
            ).stdout.strip()
            if re.match(r"^(feat|fix|perf|ci|docs|test|chore|build|refactor|style|ops|revert):", last_msg):
                milestone = True
                milestone_reason = "conventional_commit"

        if milestone and test_passed:
            base = detect_base_ref()
            msgs = get_commit_messages(base)
            cc_suggestion = build_cc_suggestion(branch, msgs)
            squash_suggestion = f"squash({branch}): {msgs.replace('|', ' | ')}"
            files, ins, dels = get_diff_stats(base)

            # Store milestone_pending
            state["milestone_pending"] = True
            state["milestone_pending_reason"] = milestone_reason
            state["milestone_pending_squash_suggestion"] = squash_suggestion
            state["milestone_pending_branch"] = branch
            state["milestone_pending_commits"] = commits_since_tag
            state_write(state)

            log_event(
                hook_name="stop",
                event_type="called",
                outcome="prompt",
                trigger_reason=f"milestone_detected:{milestone_reason}",
                extra={"branch": branch, "commits": commits_since_tag, "files": files},
            )
            prompt = (
                f"Milestone ready! [{commits_since_tag} commits, {files} files, +{ins}/-{dels}] "
                f"Branch: {branch}. Commit建议: {cc_suggestion}. "
                f"回复 /milestone confirm 执行 squash，或 /milestone cancel 取消"
            )
            output_continue_suggestion(
                "Stop",
                prompt,
                [
                    {
                        "type": "text",
                        "title": "Task Summary",
                        "content": f"Commits: {commits_since_tag} | Files: {files} | Changes: +{ins}/-{dels} | Branch: {branch}"
                    },
                    {
                        "type": "text",
                        "title": "Conventional Commits",
                        "content": cc_suggestion
                    },
                    {
                        "type": "reference",
                        "title": "Milestone Pending",
                        "content": f"reason={milestone_reason} | /milestone confirm | /milestone cancel"
                    }
                ]
            )
            return

    log_event(
        hook_name="stop",
        event_type="called",
        outcome="silent",
        trigger_reason="none",
    )
    silent_exit()


if __name__ == "__main__":
    main()
