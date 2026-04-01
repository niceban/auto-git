#!/usr/bin/env python3
"""semantic_trigger hook — silently detect user intent from prompts."""

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import acquire_lock, state_read, state_write
from lib.hook import parse_hook_input, silent_exit
from lib.logger import log_event

# Tier1: immediate trigger
# Note: (?<![a-zA-Z0-9_]) and (?![a-zA-Z0-9_]) provide correct Unicode-aware
# boundaries that: (1) match before CJK chars, (2) don't match inside words
_TIER1 = [
    r"(?<![a-zA-Z0-9_])v1(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])v2(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])v3(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])release(?![a-zA-Z0-9_])",
    r"搞定", r"搞定了", r"完事了", r"完成了", r"测试通过",
    r"✓", r"封板", r"(?<![a-zA-Z0-9_])milestone(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])done(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])finished(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])complete(?![a-zA-Z0-9_])",
]
# Tier2: strong signal
_TIER2 = [
    r"差不多", r"快好了", r"感觉可以了",
    r"(?<![a-zA-Z0-9_])nearly done(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])almost done(?![a-zA-Z0-9_])",
    r"(?<![a-zA-Z0-9_])almost there(?![a-zA-Z0-9_])", r"(?<![a-zA-Z0-9_])good enough(?![a-zA-Z0-9_])",
]


def match_keywords(text: str, patterns: list) -> str:
    text_lower = text.lower()
    for p in patterns:
        if re.search(p, text_lower, re.IGNORECASE):
            return p
    return ""


def main():
    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "UserPromptSubmit":
        silent_exit()

    # Get user prompt from input
    prompt = ""
    if isinstance(hook_input.get("userInput"), dict):
        prompt = hook_input["userInput"].get("prompt", "")
    elif isinstance(hook_input.get("prompt"), str):
        prompt = hook_input["prompt"]

    if not prompt:
        silent_exit()

    # Check Tier1
    matched = match_keywords(prompt, _TIER1)
    tier = 1
    if not matched:
        matched = match_keywords(prompt, _TIER2)
        tier = 2 if matched else ""

    if not matched:
        silent_exit()

    # Update state
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with acquire_lock("semantic_trigger"):
        state = state_read()
        state["semantic_intent"] = True
        state["semantic_intent_reason"] = matched
        state["milestone_pending"] = True
        state["last_prompt"] = prompt
        state["last_intent_at"] = now
        state_write(state)

    log_event(
        hook_name="semantic_trigger",
        event_type="triggered",
        outcome="success",
        user_input=prompt,
        trigger_reason=f"tier{tier}:{matched}",
    )
    # ZERO stdout output — this is the critical requirement
    silent_exit()


if __name__ == "__main__":
    main()
