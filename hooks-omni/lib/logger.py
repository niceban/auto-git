#!/usr/bin/env python3
"""Structured logger for hooks-omni — records all hook events."""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock

# Global log file path in user's Claude data directory
_HOOKS_OMNI_ROOT = Path.home() / ".claude" / "hooks-omni"
_LOG_DIR = _HOOKS_OMNI_ROOT / "logs"
_LOG_FILE = _LOG_DIR / "events.jsonl"
_ANALYSIS_FILE = _HOOKS_OMNI_ROOT / "logs" / "analysis_summary.json"
_lock = Lock()


def _ensure_log_dir():
    """Ensure log directory exists."""
    _LOG_DIR.mkdir(parents=True, exist_ok=True)


def _now_iso():
    """Return current UTC timestamp in ISO format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log_event(
    hook_name: str,
    event_type: str,
    outcome: str,
    user_input: str = "",
    command: str = "",
    trigger_reason: str = "",
    extra: dict = None,
) -> None:
    """Append a structured log entry to the event log.

    Args:
        hook_name: Name of the hook (e.g. "semantic_trigger", "guard_bash")
        event_type: Type of event ("called", "triggered", "allowed", "denied", "error", "silent")
        outcome: Result ("success", "blocked", "skipped", "error")
        user_input: User prompt (for UserPromptSubmit hooks)
        command: Bash command (for PreToolUse hooks)
        trigger_reason: Why the hook triggered (e.g. matched keyword, dangerous pattern)
        extra: Additional context dict
    """
    entry = {
        "timestamp": _now_iso(),
        "hook": hook_name,
        "event": event_type,
        "outcome": outcome,
        "user_input": user_input[:200] if user_input else "",
        "command": command[:300] if command else "",
        "trigger_reason": trigger_reason,
        "extra": extra or {},
    }

    with _lock:
        _ensure_log_dir()
        try:
            with open(_LOG_FILE, "a") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except Exception:
            # Never let logging failure break hook execution
            pass


def get_stats() -> dict:
    """Load all log entries and compute aggregate statistics.

    Returns:
        dict with keys: total_events, by_hook, by_outcome, by_trigger, recent (last 20)
    """
    stats = {
        "total_events": 0,
        "by_hook": {},
        "by_outcome": {},
        "by_trigger": {},
        "recent": [],
        "span": {"first": None, "last": None},
    }

    if not _LOG_FILE.exists():
        return stats

    entries = []
    try:
        with open(_LOG_FILE) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except Exception:
        return stats

    stats["total_events"] = len(entries)
    if not entries:
        return stats

    stats["span"]["first"] = entries[0]["timestamp"]
    stats["span"]["last"] = entries[-1]["timestamp"]
    stats["recent"] = entries[-20:]

    for e in entries:
        hook = e.get("hook", "unknown")
        outcome = e.get("outcome", "unknown")
        trigger = e.get("trigger_reason", "none")

        stats["by_hook"][hook] = stats["by_hook"].get(hook, 0) + 1
        stats["by_outcome"][outcome] = stats["by_outcome"].get(outcome, 0) + 1
        if trigger and trigger != "none":
            stats["by_trigger"][trigger] = stats["by_trigger"].get(trigger, 0) + 1

    return stats


def print_summary() -> None:
    """Print a human-readable summary of hook activity."""
    stats = get_stats()
    print("=" * 60)
    print("hooks-omni Activity Summary")
    print("=" * 60)

    if stats["total_events"] == 0:
        print("No events recorded yet.")
        return

    print(f"\nTotal events: {stats['total_events']}")
    if stats["span"]["first"]:
        print(f"Period: {stats['span']['first']} → {stats['span']['last']}")

    print(f"\nBy hook:")
    for hook, count in sorted(stats["by_hook"].items(), key=lambda x: -x[1]):
        print(f"  {hook}: {count}")

    print(f"\nBy outcome:")
    for outcome, count in sorted(stats["by_outcome"].items(), key=lambda x: -x[1]):
        print(f"  {outcome}: {count}")

    if stats["by_trigger"]:
        print(f"\nTop triggers:")
        for trigger, count in sorted(stats["by_trigger"].items(), key=lambda x: -x[1])[:10]:
            print(f"  [{trigger}]: {count}")

    print(f"\nRecent events:")
    for e in stats["recent"]:
        ts = e["timestamp"][-14:-5]
        print(f"  {ts} {e['hook']}/{e['event']} → {e['outcome']} "
              f"(reason={e['trigger_reason'] or 'none'[:30]})")


if __name__ == "__main__":
    print_summary()
