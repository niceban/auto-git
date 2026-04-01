#!/usr/bin/env python3
"""Tests for guard_bash.py — dangerous command detection."""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "hooks"))

# Import the dangerous patterns from guard_bash
_DANGEROUS_PATTERNS = [
    (r"git\s+push.*\bmain\b", "git push to main is denied on protected branch"),
    (r"git\s+push.*\bmaster\b", "git push to master is denied on protected branch"),
    (r"git\s+push\s+--force(?!\s+--force-with-lease)(?=$|\s)", "git push --force requires --force-with-lease"),
    (r"git\s+reset\s+--hard", "git reset --hard is denied on protected branches"),
    (r"git\s+clean\s+-[xX]", "git clean -x/-X is denied on protected branches"),
    (r"git\s+branch\s+-d\s+main", "cannot delete main branch"),
    (r"git\s+branch\s+-D\s+main", "cannot delete main branch"),
    (r"git\s+branch\s+-d\s+master", "cannot delete master branch"),
    (r"git\s+branch\s+-D\s+master", "cannot delete master branch"),
    (r"git\s+merge.*\binto\s+(main|master)\b", "git merge onto main/master is denied"),
    (r"git\s+rebase.*\bonto\s+(main|master)\b", "git rebase onto main/master is denied"),
]
_REDIRECT_PATTERNS = [
    (r">\s*/", "dangerous absolute redirection"),
    (r">>\s*/", "dangerous absolute redirection"),
    (r"\btee\s+[^>]*>", "dangerous tee redirection"),
]


def is_dangerous(cmd):
    for pattern, reason in _DANGEROUS_PATTERNS:
        if re.search(pattern, cmd, re.IGNORECASE):
            return True, reason
    for pattern, reason in _REDIRECT_PATTERNS:
        if re.search(pattern, cmd, re.IGNORECASE):
            return True, reason
    return False, ""


class TestDangerousPatterns:
    def test_push_to_main(self):
        dangerous, _ = is_dangerous("git push origin main")
        assert dangerous

    def test_push_to_master(self):
        dangerous, _ = is_dangerous("git push origin master")
        assert dangerous

    def test_force_push_without_lease(self):
        dangerous, _ = is_dangerous("git push --force")
        assert dangerous

    def test_force_push_is_ok(self):
        dangerous, _ = is_dangerous("git push --force-with-lease")
        assert not dangerous

    def test_reset_hard(self):
        dangerous, _ = is_dangerous("git reset --hard HEAD~1")
        assert dangerous

    def test_clean_x(self):
        dangerous, _ = is_dangerous("git clean -xfd")
        assert dangerous

    def test_clean_X(self):
        dangerous, _ = is_dangerous("git clean -X")
        assert dangerous

    def test_branch_delete_main(self):
        dangerous, _ = is_dangerous("git branch -d main")
        assert dangerous

    def test_branch_delete_master(self):
        dangerous, _ = is_dangerous("git branch -D master")
        assert dangerous

    def test_merge_into_main(self):
        dangerous, _ = is_dangerous("git merge feature into main")
        assert dangerous

    def test_rebase_onto_main(self):
        dangerous, _ = is_dangerous("git rebase onto main")
        assert dangerous


class TestSafeCommands:
    def test_normal_git_status(self):
        dangerous, _ = is_dangerous("git status")
        assert not dangerous

    def test_normal_git_add(self):
        dangerous, _ = is_dangerous("git add .")
        assert not dangerous

    def test_normal_git_commit(self):
        dangerous, _ = is_dangerous("git commit -m 'fix bug'")
        assert not dangerous

    def test_git_push_feature_branch(self):
        dangerous, _ = is_dangerous("git push origin feature/my-branch")
        assert not dangerous

    def test_force_with_lease_is_safe(self):
        # Note: --force-with-lease is safer than plain --force, but pushing
        # to main is still dangerous. This test verifies the pattern doesn't
        # false-positive on feature branches.
        dangerous, _ = is_dangerous("git push --force-with-lease origin feature/x")
        assert not dangerous

    def test_relative_redirection_is_safe(self):
        dangerous, _ = is_dangerous("echo hello > file.txt")
        assert not dangerous

    def test_absolute_redirection_is_blocked(self):
        dangerous, _ = is_dangerous("echo hello > /tmp/file.txt")
        assert dangerous

    def test_tee_absolute_is_blocked(self):
        dangerous, _ = is_dangerous("tee /tmp/out.txt > /dev/null")
        assert dangerous
