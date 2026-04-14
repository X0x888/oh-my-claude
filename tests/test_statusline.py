#!/usr/bin/env python3
"""Tests for statusline.py — the Claude Code statusline widget."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

# Load statusline.py as a module from its bundle location
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATUSLINE_PATH = os.path.join(REPO_ROOT, "bundle", "dot-claude", "statusline.py")

spec = importlib.util.spec_from_file_location("statusline", STATUSLINE_PATH)
sl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sl)


class TestSafeGet(unittest.TestCase):
    def test_nested_access(self):
        data = {"a": {"b": {"c": 42}}}
        self.assertEqual(sl.safe_get(data, "a", "b", "c"), 42)

    def test_missing_key(self):
        data = {"a": {"b": 1}}
        self.assertIsNone(sl.safe_get(data, "a", "x"))

    def test_default(self):
        data = {"a": 1}
        self.assertEqual(sl.safe_get(data, "x", "y", default="fallback"), "fallback")

    def test_non_dict_intermediate(self):
        data = {"a": "string"}
        self.assertEqual(sl.safe_get(data, "a", "b", default=0), 0)

    def test_empty_keys(self):
        data = {"key": "value"}
        self.assertEqual(sl.safe_get(data), {"key": "value"})

    def test_none_value_returns_default(self):
        data = {"a": None}
        self.assertEqual(sl.safe_get(data, "a", default="fallback"), "fallback")


class TestFormatDuration(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(sl.format_duration(5000), "5s")

    def test_minutes(self):
        self.assertEqual(sl.format_duration(125000), "2m 05s")

    def test_hours(self):
        self.assertEqual(sl.format_duration(3_661_000), "1h 01m")

    def test_zero(self):
        self.assertEqual(sl.format_duration(0), "0s")

    def test_none(self):
        self.assertEqual(sl.format_duration(None), "0s")

    def test_negative(self):
        self.assertEqual(sl.format_duration(-1000), "0s")


class TestFormatCost(unittest.TestCase):
    def test_normal(self):
        self.assertEqual(sl.format_cost(1.5), "$1.50")

    def test_zero(self):
        self.assertEqual(sl.format_cost(0), "$0.00")

    def test_none(self):
        self.assertEqual(sl.format_cost(None), "$0.00")

    def test_small(self):
        self.assertEqual(sl.format_cost(0.003), "$0.00")

    def test_large(self):
        self.assertEqual(sl.format_cost(12.345), "$12.35")


class TestFormatTokens(unittest.TestCase):
    def test_small(self):
        self.assertEqual(sl.format_tokens(500), "500")

    def test_thousands(self):
        self.assertEqual(sl.format_tokens(1500), "1.5k")

    def test_millions(self):
        self.assertEqual(sl.format_tokens(1_500_000), "1.5M")

    def test_boundary_k(self):
        self.assertEqual(sl.format_tokens(1000), "1.0k")

    def test_boundary_m(self):
        self.assertEqual(sl.format_tokens(999_950), "1.0M")

    def test_zero(self):
        self.assertEqual(sl.format_tokens(0), "0")

    def test_none(self):
        self.assertEqual(sl.format_tokens(None), "0")

    def test_negative(self):
        self.assertEqual(sl.format_tokens(-100), "0")


class TestBarColor(unittest.TestCase):
    def test_low(self):
        self.assertEqual(sl.bar_color(50), sl.GREEN)

    def test_medium(self):
        self.assertEqual(sl.bar_color(75), sl.YELLOW)

    def test_high(self):
        self.assertEqual(sl.bar_color(95), sl.RED)

    def test_boundary_70(self):
        self.assertEqual(sl.bar_color(70), sl.YELLOW)

    def test_boundary_90(self):
        self.assertEqual(sl.bar_color(90), sl.RED)

    def test_boundary_69(self):
        self.assertEqual(sl.bar_color(69), sl.GREEN)


class TestMakeBar(unittest.TestCase):
    def test_zero(self):
        bar = sl.make_bar(0, width=10)
        self.assertEqual(bar, "----------")

    def test_full(self):
        bar = sl.make_bar(100, width=10)
        self.assertEqual(bar, "##########")

    def test_half(self):
        bar = sl.make_bar(50, width=10)
        self.assertEqual(bar, "#####-----")

    def test_over_100(self):
        bar = sl.make_bar(150, width=10)
        self.assertEqual(bar, "##########")

    def test_negative(self):
        bar = sl.make_bar(-10, width=10)
        self.assertEqual(bar, "----------")

    def test_default_width(self):
        bar = sl.make_bar(50)
        self.assertEqual(len(bar), 18)


class TestCachePath(unittest.TestCase):
    def test_deterministic(self):
        path1 = sl.cache_path_for("/some/dir")
        path2 = sl.cache_path_for("/some/dir")
        self.assertEqual(path1, path2)

    def test_different_dirs(self):
        path1 = sl.cache_path_for("/dir/a")
        path2 = sl.cache_path_for("/dir/b")
        self.assertNotEqual(path1, path2)

    def test_in_temp_dir(self):
        path = sl.cache_path_for("/test")
        self.assertTrue(path.startswith(tempfile.gettempdir()))

    def test_prefix(self):
        path = sl.cache_path_for("/test")
        self.assertIn("claude-statusline-", os.path.basename(path))


class TestReadWriteCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mktemp(suffix=".json")

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.remove(self.tmp)

    def test_write_then_read(self):
        payload = {"branch": "main", "dirty": False}
        sl.write_cache(self.tmp, payload)
        result = sl.read_cache(self.tmp, ttl_seconds=10)
        self.assertEqual(result, payload)

    def test_expired_cache(self):
        payload = {"branch": "main", "dirty": False}
        sl.write_cache(self.tmp, payload)
        # Set mtime to 20 seconds ago
        old_time = os.path.getmtime(self.tmp) - 20
        os.utime(self.tmp, (old_time, old_time))
        result = sl.read_cache(self.tmp, ttl_seconds=10)
        self.assertIsNone(result)

    def test_missing_file(self):
        result = sl.read_cache("/nonexistent/path.json", ttl_seconds=10)
        self.assertIsNone(result)

    def test_invalid_json(self):
        with open(self.tmp, "w") as f:
            f.write("not json")
        result = sl.read_cache(self.tmp, ttl_seconds=10)
        self.assertIsNone(result)


class TestInstalledVersion(unittest.TestCase):
    def test_reads_version(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            os.makedirs(claude_dir)
            conf = os.path.join(claude_dir, "oh-my-claude.conf")
            with open(conf, "w") as f:
                f.write("repo_path=/some/path\n")
                f.write("installed_version=1.0.0\n")
                f.write("model_tier=balanced\n")
            orig = os.path.expanduser
            os.path.expanduser = lambda p: p.replace("~", tmpdir)
            try:
                result = sl.installed_version()
                self.assertEqual(result, "1.0.0")
            finally:
                os.path.expanduser = orig

    def test_missing_file(self):
        orig = os.path.expanduser
        os.path.expanduser = lambda p: p.replace("~", "/nonexistent/dir")
        try:
            result = sl.installed_version()
            self.assertIsNone(result)
        finally:
            os.path.expanduser = orig


class TestMainIntegration(unittest.TestCase):
    """Test the full statusline by running the script as a subprocess."""

    def run_statusline(self, input_data):
        result = subprocess.run(
            [sys.executable, STATUSLINE_PATH],
            input=json.dumps(input_data),
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result

    def test_minimal_input(self):
        result = self.run_statusline({})
        self.assertEqual(result.returncode, 0)
        lines = result.stdout.strip().split("\n")
        self.assertEqual(len(lines), 2)

    def test_full_input(self):
        data = {
            "workspace": {"current_dir": "/tmp/my-project"},
            "model": {"display_name": "Opus 4", "id": "claude-opus-4-20250514"},
            "output_style": {"name": "OpenCode Compact"},
            "context_window": {
                "used_percentage": 45.5,
                "total_input_tokens": 150000,
                "total_output_tokens": 25000,
                "current_usage": {
                    "cache_creation_input_tokens": 50000,
                    "cache_read_input_tokens": 100000,
                },
            },
            "cost": {
                "total_cost_usd": 2.75,
                "total_duration_ms": 180000,
                "total_api_duration_ms": 120000,
            },
            "rate_limits": {
                "five_hour": {"used_percentage": 30},
            },
        }
        result = self.run_statusline(data)
        self.assertEqual(result.returncode, 0)
        lines = result.stdout.strip().split("\n")
        self.assertEqual(len(lines), 2)
        # Line 1: model, dir, style
        self.assertIn("Opus 4", lines[0])
        self.assertIn("my-project", lines[0])
        self.assertIn("OpenCode Compact", lines[0])
        # Line 2: context bar, tokens, cost, rate limit, cache, API
        self.assertIn("45%", lines[1])
        self.assertIn("$2.75", lines[1])
        self.assertIn("RL:30%", lines[1])
        self.assertIn("C:66%", lines[1])  # 100k read / 150k total = 66%
        self.assertIn("API:66%", lines[1])  # 120k / 180k = 66%

    def test_empty_input(self):
        result = subprocess.run(
            [sys.executable, STATUSLINE_PATH],
            input="",
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)

    def test_malformed_json_input(self):
        result = subprocess.run(
            [sys.executable, STATUSLINE_PATH],
            input="not valid json {{{",
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        lines = result.stdout.strip().split("\n")
        self.assertEqual(len(lines), 2)

    def test_zero_context(self):
        data = {
            "context_window": {"used_percentage": 0},
            "cost": {"total_cost_usd": 0, "total_duration_ms": 0},
        }
        result = self.run_statusline(data)
        self.assertEqual(result.returncode, 0)
        self.assertIn("0%", result.stdout)

    def test_high_context(self):
        data = {
            "context_window": {"used_percentage": 95},
            "cost": {"total_cost_usd": 0, "total_duration_ms": 0},
        }
        result = self.run_statusline(data)
        self.assertEqual(result.returncode, 0)
        self.assertIn("95%", result.stdout)


class TestRunGit(unittest.TestCase):
    def test_timeout_returns_failed_result(self):
        """run_git returns a non-zero CompletedProcess when subprocess times out."""
        original_run = subprocess.run

        def mock_run(*args, **kwargs):
            raise subprocess.TimeoutExpired(cmd=args[0], timeout=2)

        subprocess.run = mock_run
        try:
            result = sl.run_git("/tmp", "status")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
        finally:
            subprocess.run = original_run

    def test_timeout_parameter_is_set(self):
        """run_git passes a timeout to subprocess.run."""
        captured = {}
        original_run = subprocess.run

        def spy_run(*args, **kwargs):
            captured.update(kwargs)
            return subprocess.CompletedProcess(args=args[0], returncode=0, stdout="")

        subprocess.run = spy_run
        try:
            sl.run_git("/tmp", "status")
            self.assertIn("timeout", captured)
            self.assertEqual(captured["timeout"], 2)
        finally:
            subprocess.run = original_run


if __name__ == "__main__":
    unittest.main()
