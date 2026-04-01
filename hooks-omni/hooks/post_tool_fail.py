#!/usr/bin/env python3
"""post_tool_fail hook — detect test failure."""

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import acquire_lock, state_read, state_write
from lib.hook import parse_hook_input, silent_exit
from lib.logger import log_event


def main():
    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    if hook_name != "PostToolUseFailure":
        silent_exit()

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with acquire_lock("post_tool_fail"):
        state = state_read()
        state["test_passed"] = False
        state["test_failed_at"] = now
        state_write(state)

    log_event(
        hook_name="post_tool_fail",
        event_type="called",
        outcome="success",
        trigger_reason="tool_failed",
    )
    silent_exit()


if __name__ == "__main__":
    main()
