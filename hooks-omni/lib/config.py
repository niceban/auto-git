#!/usr/bin/env python3
"""Config management - reads config.json with defaults."""

import json
import os
from pathlib import Path

PLUGIN_DIR = Path(os.environ.get(
    "BRANCH_AUTONOMOUS_DIR",
    Path.home() / ".claude" / "plugins" / "branch-autonomous"
))
CONFIG_FILE = PLUGIN_DIR / "config.json"

_DEFAULTS = {
    "uncommitted_files_threshold": 5,
    "uncommitted_lines_threshold": 1000,
    "milestone_commits_threshold": 10,
    "auto_commit_message_prefix": "checkpoint: auto-save",
    "auto_cleanup_after_merge": True,
}


def config_get(key: str, default: str = "") -> str:
    """Get config value, falling back to defaults."""
    if not CONFIG_FILE.exists():
        return str(_DEFAULTS.get(key, default))
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        val = cfg.get(key)
        if val is not None:
            return str(val)
    except (json.JSONDecodeError, IOError):
        pass
    return str(_DEFAULTS.get(key, default))


def config_get_int(key: str, default: int = 0) -> int:
    """Get config as int."""
    val = config_get(key, str(default))
    try:
        return int(val)
    except ValueError:
        return default


def config_get_bool(key: str, default: bool = False) -> bool:
    """Get config as bool."""
    val = config_get(key, str(default)).lower()
    return val in ("true", "1", "yes")
