#!/usr/bin/env python3
"""session_start hook — initialize state.json on Claude session start."""

import os
import sys
from pathlib import Path

# Add lib to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import get_branch, init_state, state_read, state_write
from lib.hook import parse_hook_input, silent_exit
from lib.logger import log_event

PLUGIN_DIR = Path(os.environ.get(
    "BRANCH_AUTONOMOUS_DIR",
    Path.home() / ".claude" / "plugins" / "branch-autonomous"
))


def main():
    hook_input = parse_hook_input()
    hook_name = hook_input.get("hookName", "") or os.environ.get("HOOK_NAME", "")

    # Only handle SessionStart
    if hook_name != "SessionStart":
        silent_exit()

    branch = get_branch()

    # Guard: skip main
    if branch in ("main", "master"):
        silent_exit()

    # Init or resume state
    init_state(branch)

    log_event(
        hook_name="session_start",
        event_type="called",
        outcome="success",
        extra={"branch": branch},
    )
    silent_exit()


if __name__ == "__main__":
    main()
