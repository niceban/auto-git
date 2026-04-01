#!/usr/bin/env python3
"""Hook output helpers for hookSpecificOutput JSON."""

import json
import os
import sys
from typing import Any, Optional


def parse_hook_input() -> dict:
    """Parse hook input from HOOK_INPUT_FILE env var or stdin."""
    input_file = os.environ.get("HOOK_INPUT_FILE", "")
    if input_file and os.path.exists(input_file):
        with open(input_file) as f:
            return json.load(f)
    # Try reading from stdin
    try:
        data = json.load(sys.stdin)
        return data
    except (json.JSONDecodeError, IOError):
        pass
    return {}


def get_hook_name() -> str:
    """Get hook name from environment."""
    return os.environ.get("HOOK_NAME", "")


def get_tool_name() -> Optional[str]:
    """Get tool name from environment."""
    return os.environ.get("TOOL_NAME", None)


def output_permission_denied(reason: str) -> None:
    """Output permission denied JSON for PreToolUse."""
    result = {
        "hookSpecificOutput": {
            "permissionDecision": {
                "denied": True,
                "reason": reason
            }
        }
    }
    print(json.dumps(result), file=sys.stdout)
    sys.exit(0)


def output_permission_allowed() -> None:
    """Output permission allowed JSON for PreToolUse."""
    result = {
        "hookSpecificOutput": {
            "permissionDecision": {
                "denied": False
            }
        }
    }
    print(json.dumps(result), file=sys.stdout)
    sys.exit(0)


def output_continue_suggestion(
    hook_event: str,
    prompt: str,
    additional_context: Optional[list] = None
) -> None:
    """Output continueSuggestion JSON for Stop hook."""
    output = {
        "hookSpecificOutput": {
            "hookEventName": hook_event,
            "continueSuggestion": {
                "prompt": prompt
            }
        }
    }
    if additional_context:
        output["hookSpecificOutput"]["additionalContext"] = additional_context
    print(json.dumps(output), file=sys.stdout)
    sys.exit(0)


def silent_exit() -> None:
    """Exit silently with no output."""
    sys.exit(0)
