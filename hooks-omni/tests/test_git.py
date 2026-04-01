#!/usr/bin/env python3
"""Tests for lib/git.py — git helper functions."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.git import get_branch_type


class TestGetBranchType:
    def test_feature_branch(self):
        assert get_branch_type("feature/add-login") == "feature"
        assert get_branch_type("feature/auth") == "feature"

    def test_fix_branch(self):
        assert get_branch_type("fix/null-pointer") == "fix"
        assert get_branch_type("fix/login-bug") == "fix"

    def test_hotfix_branch(self):
        assert get_branch_type("hotfix/critical-fix") == "hotfix"

    def test_other_branch(self):
        assert get_branch_type("main") == "other"
        assert get_branch_type("master") == "other"
        assert get_branch_type("develop") == "other"
        assert get_branch_type("release/1.0") == "other"
        assert get_branch_type("任意名字") == "other"

    def test_branch_without_prefix(self):
        assert get_branch_type("bugfix/mobile-ui") == "fix"
        assert get_branch_type("feature/myfeature") == "feature"
