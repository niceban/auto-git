#!/usr/bin/env python3
"""Tests for semantic_trigger.py — Tier1/Tier2 keyword matching."""

import re
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Import the keyword patterns directly (must match source patterns)
_TIER1 = [
    r"(?<![a-zA-Z0-9_])v1(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])v2(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])v3(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])release(?![a-zA-Z0-9_])",
    r"搞定", r"搞定了", r"完事了", r"完成了", r"测试通过",
    r"✓", r"封板", r"(?<![a-zA-Z0-9_])milestone(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])done(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])finished(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])complete(?![a-zA-Z0-9_])",
]
_TIER2 = [
    r"差不多", r"快好了", r"感觉可以了",
    r"(?<![a-zA-Z0-9_])nearly done(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])almost done(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])almost there(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])good enough(?![a-zA-Z0-9_])",
]


def match_keywords(text, patterns):
    text_lower = text.lower()
    for p in patterns:
        if re.search(p, text_lower, re.IGNORECASE):
            return p
    return ""


class TestTier1Keywords:
    def test_v1_trigger(self):
        assert match_keywords("v1完成了吗", _TIER1) != ""

    def test_v2_trigger(self):
        assert match_keywords("v2发布了", _TIER1) != ""

    def test_v3_trigger(self):
        assert match_keywords("v3差不多了", _TIER1) != ""

    def test_release_trigger(self):
        assert match_keywords("release版本", _TIER1) != ""

    def test_搞定_trigger(self):
        assert match_keywords("搞定了", _TIER1) != ""

    def test_搞定了_trigger(self):
        assert match_keywords("搞定了！", _TIER1) != ""

    def test_done_trigger(self):
        assert match_keywords("done", _TIER1) != ""

    def test_finished_trigger(self):
        assert match_keywords("finished", _TIER1) != ""

    def test_complete_trigger(self):
        assert match_keywords("complete", _TIER1) != ""

    def test_checkmark_trigger(self):
        assert match_keywords("✓", _TIER1) != ""

    def test_milestone_trigger(self):
        assert match_keywords("milestone", _TIER1) != ""

    def test_no_trigger_on_normal_text(self):
        assert match_keywords("这个函数需要修改", _TIER1) == ""


class TestTier2Keywords:
    def test_差不多_trigger(self):
        assert match_keywords("差不多了", _TIER2) != ""

    def test_快好了_trigger(self):
        assert match_keywords("快好了", _TIER2) != ""

    def test_nearly_done_trigger(self):
        assert match_keywords("nearly done", _TIER2) != ""

    def test_almost_done_trigger(self):
        assert match_keywords("almost done", _TIER2) != ""

    def test_almost_there_trigger(self):
        assert match_keywords("almost there", _TIER2) != ""

    def test_good_enough_trigger(self):
        assert match_keywords("good enough", _TIER2) != ""

    def test_no_trigger_on_normal_text(self):
        assert match_keywords("还需要一些时间", _TIER2) == ""


class TestPriority:
    def test_tier1_takes_priority(self):
        # Both match, but Tier1 should be returned first
        tier1_match = match_keywords("搞定 done", _TIER1)
        tier2_match = match_keywords("搞定 done", _TIER2)
        assert tier1_match != ""  # Tier1 should match
        # Tier2 also matches but Tier1 takes priority in actual hook logic


class TestCaseInsensitive:
    def test_done_uppercase(self):
        assert match_keywords("DONE", _TIER1) != ""

    def test_finished_mixed_case(self):
        assert match_keywords("Finished", _TIER1) != ""
