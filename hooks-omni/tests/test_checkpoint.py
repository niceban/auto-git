#!/usr/bin/env python3
"""Tests for checkpoint threshold logic in post_tool.py."""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "hooks"))

# Import the pass patterns
_TEST_PASS_PATTERNS = [
    r"\bPASS\b", r"\bok\b", r"\b✓\b",
    r"All tests passed", r"\bpassed\b(?! [a-z])", r"100%\s*passed",
]


def detect_test_pass(output):
    for p in _TEST_PASS_PATTERNS:
        if re.search(p, output, re.IGNORECASE):
            return True
    return False


class TestTestPassDetection:
    def test_pass_pattern(self):
        assert detect_test_pass("Tests: PASS")

    def test_ok_pattern(self):
        assert detect_test_pass("test ok ")

    def test_checkmark_pattern(self):
        assert detect_test_pass("✓ All tests passed")

    def test_all_tests_passed(self):
        assert detect_test_pass("All tests passed")

    def test_passed_pattern(self):
        assert detect_test_pass("5 passed")

    def test_100_percent(self):
        assert detect_test_pass("100% passed")

    def test_fail_is_not_pass(self):
        assert not detect_test_pass("FAIL: 3 tests failed")

    def test_empty_is_not_pass(self):
        assert not detect_test_pass("")

    def test_no_false_positives(self):
        assert not detect_test_pass("passed parameters to function")
        assert not detect_test_pass("bypass authentication")
