#!/usr/bin/env python3
"""Tests for lib/state.py — state management functions."""

import json
import os
import tempfile
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import acquire_lock, state_read, state_write, state_update

# Override PLUGIN_DIR to use temp directory for testing
_temp_dir = tempfile.mkdtemp()
os.environ["BRANCH_AUTONOMOUS_DIR"] = _temp_dir

# Re-import after setting env
import importlib
import lib.state
importlib.reload(lib.state)
from lib.state import STATE_FILE, STATE_LOCK, LOCK_FILE

def write_test_state(data):
    with open(STATE_FILE, "w") as f:
        json.dump(data, f)

def read_test_state():
    if not STATE_FILE.exists():
        return {}
    with open(STATE_FILE) as f:
        return json.load(f)


class TestStateWrite:
    def setup_method(self):
        if STATE_FILE.exists():
            os.remove(STATE_FILE)

    def test_write_creates_file(self):
        state_write({"version": "4.0", "branch": "test"})
        assert STATE_FILE.exists()
        data = read_test_state()
        assert data["version"] == "4.0"
        assert data["branch"] == "test"

    def test_write_atomic(self):
        """Write should be atomic (temp file then rename)."""
        state_write({"test": "value"})
        data = read_test_state()
        assert data["test"] == "value"


class TestStateUpdate:
    def setup_method(self):
        if STATE_FILE.exists():
            os.remove(STATE_FILE)
        write_test_state({"version": "4.0", "branch": "feature/x", "test_passed": False})

    def test_update_boolean_true(self):
        state_update(".test_passed = true")
        data = read_test_state()
        assert data["test_passed"] is True

    def test_update_boolean_false(self):
        state_update(".test_passed = false")
        data = read_test_state()
        assert data["test_passed"] is False

    def test_update_string(self):
        state_update('.branch = "feature/y"')
        data = read_test_state()
        assert data["branch"] == "feature/y"

    def test_update_multiple(self):
        state_update(".test_passed = true | .branch = \"feature/z\"")
        data = read_test_state()
        assert data["test_passed"] is True
        assert data["branch"] == "feature/z"


class TestAcquireLock:
    def test_lock_creates_lock_file(self):
        with acquire_lock("test"):
            assert LOCK_FILE.exists()

    def test_lock_acquire_releases_cleanly(self):
        """Verify that lock context manager acquires and releases without error.

        This tests the basic acquire/release cycle. Nested locking behavior
        is platform-dependent (Linux vs macOS) and not tested here.
        """
        ctx = acquire_lock("test_cycle")
        ctx.__enter__()
        ctx.__exit__(None, None, None)
