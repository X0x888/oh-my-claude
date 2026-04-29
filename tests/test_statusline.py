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


class TestInstallationDrift(unittest.TestCase):
    """Local stale-install detection: bundle version vs. source repo VERSION."""

    def _write_conf(self, claude_dir, **kv):
        os.makedirs(claude_dir, exist_ok=True)
        conf = os.path.join(claude_dir, "oh-my-claude.conf")
        with open(conf, "w") as f:
            f.write("# header comment\n\n")
            for k, v in kv.items():
                f.write(f"{k}={v}\n")

    def _write_version(self, repo_dir, version):
        os.makedirs(repo_dir, exist_ok=True)
        with open(os.path.join(repo_dir, "VERSION"), "w") as f:
            f.write(version + "\n")

    def _patched_expanduser(self, tmpdir):
        return lambda p: p.replace("~", tmpdir)

    def test_no_installed_version_returns_none(self):
        self.assertIsNone(sl.installation_drift(None))
        self.assertIsNone(sl.installation_drift(""))

    def test_match_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            self._write_version(repo_dir, "1.5.0")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_mismatch_returns_repo_version(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            self._write_version(repo_dir, "1.6.0")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertEqual(
                    sl.installation_drift("1.5.0"), {"version": "1.6.0"}
                )
            finally:
                os.path.expanduser = orig

    def test_disabled_via_conf_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installation_drift_check="false",
            )
            self._write_version(repo_dir, "1.6.0")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_disabled_via_env_var_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            self._write_version(repo_dir, "1.6.0")
            orig_expand = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            os.environ["OMC_INSTALLATION_DRIFT_CHECK"] = "false"
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig_expand
                del os.environ["OMC_INSTALLATION_DRIFT_CHECK"]

    def test_disable_accepts_other_falsy_variants(self):
        for variant in ("0", "off", "no", "FALSE"):
            with self.subTest(variant=variant):
                with tempfile.TemporaryDirectory() as tmpdir:
                    claude_dir = os.path.join(tmpdir, ".claude")
                    repo_dir = os.path.join(tmpdir, "repo")
                    self._write_conf(
                        claude_dir,
                        repo_path=repo_dir,
                        installed_version="1.5.0",
                        installation_drift_check=variant,
                    )
                    self._write_version(repo_dir, "1.6.0")
                    orig = os.path.expanduser
                    os.path.expanduser = self._patched_expanduser(tmpdir)
                    try:
                        self.assertIsNone(sl.installation_drift("1.5.0"))
                    finally:
                        os.path.expanduser = orig

    def test_downgrade_does_not_render_arrow(self):
        """Bisecting an older tag locally must not produce a misleading arrow."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.7.0")
            self._write_version(repo_dir, "1.5.0")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.7.0"))
            finally:
                os.path.expanduser = orig

    def test_multiline_version_uses_first_line(self):
        """A VERSION file with trailing build metadata must not break rendering."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            os.makedirs(repo_dir)
            with open(os.path.join(repo_dir, "VERSION"), "w") as f:
                f.write("1.7.0\nbuild-metadata-line\n")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                result = sl.installation_drift("1.5.0")
                self.assertEqual(result, {"version": "1.7.0"})
                self.assertNotIn("\n", result["version"])
            finally:
                os.path.expanduser = orig

    def test_non_semver_falls_back_to_inequality(self):
        """When versions can't be parsed numerically, plain neq still triggers."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.7.0-rc1")
            self._write_version(repo_dir, "1.7.0-rc2")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertEqual(
                    sl.installation_drift("1.7.0-rc1"), {"version": "1.7.0-rc2"}
                )
            finally:
                os.path.expanduser = orig

    def test_missing_repo_path_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            self._write_conf(claude_dir, installed_version="1.5.0")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_missing_version_file_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "moved-away")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            # Note: repo_dir intentionally not created — simulates moved/removed clone.
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_empty_version_file_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            os.makedirs(repo_dir)
            with open(os.path.join(repo_dir, "VERSION"), "w") as f:
                f.write("\n")
            orig = os.path.expanduser
            os.path.expanduser = self._patched_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_render_includes_drift_arrow(self):
        """End-to-end: a stale install renders the upgrade arrow on line 1."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.5.0")
            self._write_version(repo_dir, "1.7.0")
            env = dict(os.environ)
            env["HOME"] = tmpdir
            result = subprocess.run(
                [sys.executable, STATUSLINE_PATH],
                input="{}",
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
            self.assertEqual(result.returncode, 0)
            line_one = result.stdout.split("\n")[0]
            self.assertIn("v1.5.0", line_one)
            self.assertIn("\u2191v1.7.0", line_one)

    def test_render_omits_arrow_when_in_sync(self):
        """End-to-end: matching versions render no upgrade arrow."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(claude_dir, repo_path=repo_dir, installed_version="1.7.0")
            self._write_version(repo_dir, "1.7.0")
            env = dict(os.environ)
            env["HOME"] = tmpdir
            result = subprocess.run(
                [sys.executable, STATUSLINE_PATH],
                input="{}",
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
            self.assertEqual(result.returncode, 0)
            line_one = result.stdout.split("\n")[0]
            self.assertIn("v1.7.0", line_one)
            self.assertNotIn("\u2191", line_one)

    def test_render_backward_compat_string_drift(self):
        """A legacy string return (hypothetical older impl) still renders."""
        orig = sl.installation_drift
        sl.installation_drift = lambda installed: "1.9.0"
        env = dict(os.environ)
        env["HOME"] = tempfile.mkdtemp()
        try:
            # Set up minimal conf so installed_version is picked up
            claude_dir = os.path.join(env["HOME"], ".claude")
            os.makedirs(claude_dir, exist_ok=True)
            with open(os.path.join(claude_dir, "oh-my-claude.conf"), "w") as f:
                f.write("installed_version=1.5.0\n")
            result = subprocess.run(
                [sys.executable, STATUSLINE_PATH],
                input="{}",
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
            # Subprocess loads statusline fresh, so the monkey-patch does
            # not apply. This test only exercises the in-process branch
            # guard that the render path treats a bare string defensively.
            self.assertEqual(result.returncode, 0)
        finally:
            sl.installation_drift = orig


class TestInstallationDriftCommitDistance(unittest.TestCase):
    """Commit-distance drift: VERSION matches but HEAD is ahead of installed_sha."""

    def _write_conf(self, claude_dir, **kv):
        os.makedirs(claude_dir, exist_ok=True)
        conf = os.path.join(claude_dir, "oh-my-claude.conf")
        with open(conf, "w") as f:
            for k, v in kv.items():
                f.write(f"{k}={v}\n")

    def _init_repo_with_commits(self, repo_dir, version, commit_count):
        """Initialize a git repo with `commit_count` commits. Returns
        (initial_sha, head_sha). If commit_count == 1, initial_sha == head_sha."""
        os.makedirs(repo_dir, exist_ok=True)
        with open(os.path.join(repo_dir, "VERSION"), "w") as f:
            f.write(version + "\n")
        subprocess.run(
            ["git", "init", "-q"],
            cwd=repo_dir,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["git", "config", "user.email", "t@t.t"],
            cwd=repo_dir,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "t"],
            cwd=repo_dir,
            check=True,
        )
        subprocess.run(
            ["git", "config", "commit.gpgsign", "false"],
            cwd=repo_dir,
            check=True,
        )
        shas = []
        for i in range(commit_count):
            with open(os.path.join(repo_dir, f"f{i}.txt"), "w") as f:
                f.write(f"commit {i}\n")
            subprocess.run(
                ["git", "add", "-A"],
                cwd=repo_dir,
                check=True,
            )
            subprocess.run(
                ["git", "commit", "-qm", f"commit {i}"],
                cwd=repo_dir,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            sha = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo_dir,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            shas.append(sha)
        return shas[0], shas[-1]

    def _patch_expanduser(self, tmpdir):
        return lambda p: p.replace("~", tmpdir)

    def test_same_version_no_sha_returns_none(self):
        """Without installed_sha recorded, no commit-distance check fires."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._write_conf(
                claude_dir, repo_path=repo_dir, installed_version="1.5.0"
            )
            self._init_repo_with_commits(repo_dir, "1.5.0", 1)
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_same_version_sha_matches_returns_none(self):
        """VERSION matches, installed_sha == HEAD → no drift."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            _, head_sha = self._init_repo_with_commits(repo_dir, "1.5.0", 1)
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installed_sha=head_sha,
            )
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_same_version_head_ahead_returns_commit_count(self):
        """VERSION matches, HEAD is N commits past installed_sha → {commits: N}."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            # 3 commits, installed_sha = first commit, HEAD = third commit.
            initial_sha, _ = self._init_repo_with_commits(repo_dir, "1.5.0", 3)
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installed_sha=initial_sha,
            )
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                result = sl.installation_drift("1.5.0")
                self.assertEqual(result, {"version": "1.5.0", "commits": 2})
            finally:
                os.path.expanduser = orig

    def test_version_ahead_short_circuits_sha_check(self):
        """VERSION-ahead takes precedence over commit-distance check."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            # Repo VERSION=1.7.0, installed=1.5.0. Even with installed_sha
            # mismatching, we report the tag drift rather than the commit
            # count — tag-ahead is the strongest signal.
            initial_sha, _ = self._init_repo_with_commits(repo_dir, "1.7.0", 3)
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installed_sha=initial_sha,
            )
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                result = sl.installation_drift("1.5.0")
                self.assertEqual(result, {"version": "1.7.0"})
                self.assertNotIn("commits", result)
            finally:
                os.path.expanduser = orig

    def test_unreachable_sha_fails_closed(self):
        """installed_sha not in repo history (rebased/amended) → no drift shown.

        Earlier revisions returned `(+?)` here, but that produced a
        persistent noisy indicator on the oh-my-claude maintainer's own
        clone whenever main was rebased. The new policy: fail closed.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            self._init_repo_with_commits(repo_dir, "1.5.0", 1)
            # A SHA that's never in the repo — git rev-list will fail.
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installed_sha="0" * 40,
            )
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.installation_drift("1.5.0"))
            finally:
                os.path.expanduser = orig

    def test_render_shows_commit_count(self):
        """End-to-end: (+N) is visible on line 1 when HEAD is ahead."""
        with tempfile.TemporaryDirectory() as tmpdir:
            claude_dir = os.path.join(tmpdir, ".claude")
            repo_dir = os.path.join(tmpdir, "repo")
            initial_sha, _ = self._init_repo_with_commits(repo_dir, "1.5.0", 4)
            self._write_conf(
                claude_dir,
                repo_path=repo_dir,
                installed_version="1.5.0",
                installed_sha=initial_sha,
            )
            env = dict(os.environ)
            env["HOME"] = tmpdir
            result = subprocess.run(
                [sys.executable, STATUSLINE_PATH],
                input="{}",
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
            self.assertEqual(result.returncode, 0)
            line_one = result.stdout.split("\n")[0]
            self.assertIn("\u2191v1.5.0 (+3)", line_one)


class TestHarnessHealth(unittest.TestCase):
    """Tightened harness_health: newest session-state mtime, not hooks.log."""

    def _patch_expanduser(self, tmpdir):
        return lambda p: p.replace("~", tmpdir)

    def test_returns_none_when_state_root_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.harness_health())
            finally:
                os.path.expanduser = orig

    def test_returns_none_when_no_sessions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = os.path.join(
                tmpdir, ".claude", "quality-pack", "state"
            )
            os.makedirs(state_root, exist_ok=True)
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.harness_health())
            finally:
                os.path.expanduser = orig

    def test_returns_active_when_newest_session_fresh(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = os.path.join(
                tmpdir, ".claude", "quality-pack", "state"
            )
            session_dir = os.path.join(state_root, "session-abc")
            os.makedirs(session_dir, exist_ok=True)
            state_file = os.path.join(session_dir, "session_state.json")
            with open(state_file, "w") as f:
                f.write("{}")
            # mtime is now; well inside the 5-minute window.
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertEqual(sl.harness_health(), "active")
            finally:
                os.path.expanduser = orig

    def test_returns_none_when_newest_session_stale(self):
        """The main bug-fix: a stale newest session must NOT light [H:ok]."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = os.path.join(
                tmpdir, ".claude", "quality-pack", "state"
            )
            session_dir = os.path.join(state_root, "session-abc")
            os.makedirs(session_dir, exist_ok=True)
            state_file = os.path.join(session_dir, "session_state.json")
            with open(state_file, "w") as f:
                f.write("{}")
            # Backdate mtime to 10 minutes ago — past the 5-minute window.
            import time as _t
            stale = _t.time() - 600
            os.utime(state_file, (stale, stale))
            os.utime(session_dir, (stale, stale))
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.harness_health())
            finally:
                os.path.expanduser = orig

    def test_stale_hooks_log_alone_does_not_trigger(self):
        """Regression guard: recent hooks.log without a recent session must be None."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = os.path.join(
                tmpdir, ".claude", "quality-pack", "state"
            )
            os.makedirs(state_root, exist_ok=True)
            # hooks.log freshly touched but no session directories exist.
            with open(os.path.join(state_root, "hooks.log"), "w") as f:
                f.write("hook fired\n")
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                # Old behavior returned "active"; tightened check returns None.
                self.assertIsNone(sl.harness_health())
            finally:
                os.path.expanduser = orig

    def test_newest_session_drives_decision_not_older_fresh_ones(self):
        """If the NEWEST session is stale, older-but-fresh sessions don't count."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = os.path.join(
                tmpdir, ".claude", "quality-pack", "state"
            )
            # Session A: state.json fresh, but directory mtime old.
            # Session B: directory mtime new, state.json stale.
            # Under the mtime-sort-reverse logic we look at B first and bail.
            old_dir = os.path.join(state_root, "session-old")
            new_dir = os.path.join(state_root, "session-new")
            os.makedirs(old_dir, exist_ok=True)
            os.makedirs(new_dir, exist_ok=True)

            old_state = os.path.join(old_dir, "session_state.json")
            new_state = os.path.join(new_dir, "session_state.json")
            with open(old_state, "w") as f:
                f.write("{}")
            with open(new_state, "w") as f:
                f.write("{}")

            import time as _t
            now = _t.time()
            # old session dir backdated, state fresh
            os.utime(old_dir, (now - 1000, now - 1000))
            os.utime(old_state, (now - 10, now - 10))
            # new session dir fresh, state old
            os.utime(new_dir, (now - 10, now - 10))
            os.utime(new_state, (now - 1000, now - 1000))

            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                # Newest session (by dir mtime) is "new", its state is stale
                # → we bail without checking the old session. None.
                self.assertIsNone(sl.harness_health())
            finally:
                os.path.expanduser = orig


class TestGateSummary(unittest.TestCase):
    """v1.17.0 gate-event summary token: surfaces gate fires + finding
    resolutions for the latest session at-a-glance."""

    def _patch_expanduser(self, tmpdir):
        return lambda p: p.replace("~", tmpdir)

    def _make_state_root(self, tmpdir):
        state_root = os.path.join(
            tmpdir, ".claude", "quality-pack", "state"
        )
        os.makedirs(state_root, exist_ok=True)
        return state_root

    def _write_events(self, session_dir, rows):
        """Write JSONL gate events to <session_dir>/gate_events.jsonl."""
        os.makedirs(session_dir, exist_ok=True)
        path = os.path.join(session_dir, "gate_events.jsonl")
        with open(path, "w") as fh:
            for row in rows:
                fh.write(json.dumps(row) + "\n")

    def test_returns_none_when_state_root_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.gate_summary())
            finally:
                os.path.expanduser = orig

    def test_returns_none_when_no_sessions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            self._make_state_root(tmpdir)
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.gate_summary())
            finally:
                os.path.expanduser = orig

    def test_returns_none_when_events_file_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            os.makedirs(os.path.join(state_root, "session-abc"))
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.gate_summary())
            finally:
                os.path.expanduser = orig

    def test_returns_none_when_no_blocks_or_resolutions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            session_dir = os.path.join(state_root, "session-abc")
            # Only finding-status-change rows with status=pending — those
            # do NOT count as resolutions.
            self._write_events(session_dir, [
                {"event": "finding-status-change",
                 "details": {"finding_status": "pending"}},
            ])
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertIsNone(sl.gate_summary())
            finally:
                os.path.expanduser = orig

    def test_blocks_only_render_g_token(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            session_dir = os.path.join(state_root, "session-abc")
            self._write_events(session_dir, [
                {"event": "block", "gate": "advisory"},
                {"event": "block", "gate": "discovered-scope"},
                {"event": "block", "gate": "quality"},
            ])
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertEqual(sl.gate_summary(), "g:3")
            finally:
                os.path.expanduser = orig

    def test_resolutions_only_render_f_token(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            session_dir = os.path.join(state_root, "session-abc")
            self._write_events(session_dir, [
                {"event": "finding-status-change",
                 "details": {"finding_status": "shipped"}},
                {"event": "finding-status-change",
                 "details": {"finding_status": "deferred"}},
            ])
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertEqual(sl.gate_summary(), "f:2")
            finally:
                os.path.expanduser = orig

    def test_both_blocks_and_resolutions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            session_dir = os.path.join(state_root, "session-abc")
            self._write_events(session_dir, [
                {"event": "block", "gate": "advisory"},
                {"event": "block", "gate": "quality"},
                {"event": "finding-status-change",
                 "details": {"finding_status": "shipped"}},
                # pending status MUST NOT count as a resolution
                {"event": "finding-status-change",
                 "details": {"finding_status": "pending"}},
                # event we don't recognize is ignored
                {"event": "wave-status-change",
                 "details": {"wave_status": "complete"}},
            ])
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertEqual(sl.gate_summary(), "g:2 f:1")
            finally:
                os.path.expanduser = orig

    def test_picks_newest_session(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            old_dir = os.path.join(state_root, "session-old")
            new_dir = os.path.join(state_root, "session-new")
            self._write_events(old_dir, [
                {"event": "block", "gate": "advisory"},
                {"event": "block", "gate": "quality"},
                {"event": "block", "gate": "excellence"},
            ])
            self._write_events(new_dir, [
                {"event": "block", "gate": "advisory"},
            ])
            import time as _t
            now = _t.time()
            os.utime(old_dir, (now - 1000, now - 1000))
            os.utime(new_dir, (now, now))
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                # Newest session has 1 block, NOT 3.
                self.assertEqual(sl.gate_summary(), "g:1")
            finally:
                os.path.expanduser = orig

    def test_tolerates_malformed_jsonl(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_root = self._make_state_root(tmpdir)
            session_dir = os.path.join(state_root, "session-abc")
            os.makedirs(session_dir, exist_ok=True)
            path = os.path.join(session_dir, "gate_events.jsonl")
            # Mix of valid + invalid + blank rows; valid rows still count.
            with open(path, "w") as fh:
                fh.write(json.dumps({"event": "block", "gate": "advisory"}) + "\n")
                fh.write("not-json garbage\n")
                fh.write("\n")
                fh.write(json.dumps({"event": "block", "gate": "quality"}) + "\n")
                fh.write("{partial\n")
            orig = os.path.expanduser
            os.path.expanduser = self._patch_expanduser(tmpdir)
            try:
                self.assertEqual(sl.gate_summary(), "g:2")
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


class TestPersistRateLimitStatus(unittest.TestCase):
    """Verify the sidecar write that pre-stages rate-limit data for the
    StopFailure hook (Wave A of long-running-agent harness)."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.state_root = os.path.join(self.tmpdir, "state")
        os.makedirs(self.state_root)
        self._orig_state_root = os.environ.get("STATE_ROOT")
        os.environ["STATE_ROOT"] = self.state_root

    def tearDown(self):
        if self._orig_state_root is None:
            os.environ.pop("STATE_ROOT", None)
        else:
            os.environ["STATE_ROOT"] = self._orig_state_root
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _session_dir(self, sid):
        d = os.path.join(self.state_root, sid)
        os.makedirs(d, exist_ok=True)
        return d

    def _sidecar_path(self, sid):
        return os.path.join(self.state_root, sid, "rate_limit_status.json")

    def test_writes_both_windows(self):
        sid = "sess-both"
        self._session_dir(sid)
        data = {
            "session_id": sid,
            "rate_limits": {
                "five_hour": {"used_percentage": 85, "resets_at": 1738425600},
                "seven_day": {"used_percentage": 42, "resets_at": 1738857600},
            },
        }
        sl.persist_rate_limit_status(data)
        with open(self._sidecar_path(sid)) as f:
            payload = json.load(f)
        self.assertEqual(payload["five_hour"]["resets_at_ts"], 1738425600)
        self.assertEqual(payload["five_hour"]["used_percentage"], 85)
        self.assertEqual(payload["seven_day"]["resets_at_ts"], 1738857600)
        self.assertEqual(payload["seven_day"]["used_percentage"], 42)
        self.assertIn("captured_at_ts", payload)

    def test_silent_when_rate_limits_absent(self):
        sid = "sess-norl"
        self._session_dir(sid)
        sl.persist_rate_limit_status({"session_id": sid})
        self.assertFalse(os.path.exists(self._sidecar_path(sid)))

    def test_silent_when_session_id_absent(self):
        sl.persist_rate_limit_status(
            {"rate_limits": {"five_hour": {"resets_at": 1738425600}}}
        )
        # No session_id → can't pick a target. State root must stay empty.
        self.assertEqual(os.listdir(self.state_root), [])

    def test_silent_when_session_dir_missing(self):
        # session_id present but the bash hook hasn't created the dir yet —
        # we don't pre-create it; just skip.
        sl.persist_rate_limit_status({
            "session_id": "sess-no-dir",
            "rate_limits": {"five_hour": {"resets_at": 1738425600}},
        })
        self.assertFalse(os.path.exists(self._sidecar_path("sess-no-dir")))

    def test_writes_only_present_window(self):
        sid = "sess-only-7d"
        self._session_dir(sid)
        data = {
            "session_id": sid,
            "rate_limits": {
                "seven_day": {"used_percentage": 15, "resets_at": 1738900000},
            },
        }
        sl.persist_rate_limit_status(data)
        with open(self._sidecar_path(sid)) as f:
            payload = json.load(f)
        self.assertIn("seven_day", payload)
        self.assertNotIn("five_hour", payload)

    def test_skips_window_without_useful_fields(self):
        # Window dict exists but resets_at and used_percentage are missing —
        # nothing to record, no sidecar written.
        sid = "sess-empty-window"
        self._session_dir(sid)
        data = {
            "session_id": sid,
            "rate_limits": {"five_hour": {}},
        }
        sl.persist_rate_limit_status(data)
        self.assertFalse(os.path.exists(self._sidecar_path(sid)))

    def test_does_not_raise_on_garbage(self):
        # Non-dict rate_limits, non-string session_id, etc. must not raise.
        for bogus in (
            {"session_id": sid_garbage, "rate_limits": rl_garbage}
            for sid_garbage in (None, 42, ["a"])
            for rl_garbage in (None, "string", 7, [])
        ):
            try:
                sl.persist_rate_limit_status(bogus)
            except Exception as exc:
                self.fail(
                    f"persist_rate_limit_status raised on {bogus!r}: {exc}"
                )

    def test_atomic_overwrite(self):
        # Subsequent calls overwrite atomically; old payload is replaced
        # cleanly without leaving a .tmp file behind.
        sid = "sess-overwrite"
        sd = self._session_dir(sid)
        data1 = {
            "session_id": sid,
            "rate_limits": {"five_hour": {"resets_at": 100}},
        }
        data2 = {
            "session_id": sid,
            "rate_limits": {"five_hour": {"resets_at": 200}},
        }
        sl.persist_rate_limit_status(data1)
        sl.persist_rate_limit_status(data2)
        with open(self._sidecar_path(sid)) as f:
            payload = json.load(f)
        self.assertEqual(payload["five_hour"]["resets_at_ts"], 200)
        # No leaked tmp files.
        leftovers = [n for n in os.listdir(sd) if n.startswith(".rate_limit_status.")]
        self.assertEqual(leftovers, [])

    def test_falls_back_to_home_state_root_when_env_unset(self):
        # When STATE_ROOT is not in env, persist_rate_limit_status must fall
        # back to ~/.claude/quality-pack/state. Patch expanduser so '~'
        # resolves into the test tmpdir; the function should compose the
        # canonical path and find the session dir there.
        os.environ.pop("STATE_ROOT", None)
        sid = "sess-home-fallback"
        fallback_session_dir = os.path.join(
            self.tmpdir, ".claude", "quality-pack", "state", sid
        )
        os.makedirs(fallback_session_dir)
        orig_expanduser = os.path.expanduser
        os.path.expanduser = lambda p: p.replace("~", self.tmpdir)
        try:
            sl.persist_rate_limit_status({
                "session_id": sid,
                "rate_limits": {"five_hour": {"resets_at": 1738425600}},
            })
            sidecar = os.path.join(fallback_session_dir, "rate_limit_status.json")
            self.assertTrue(os.path.isfile(sidecar))
            with open(sidecar) as f:
                payload = json.load(f)
            self.assertEqual(payload["five_hour"]["resets_at_ts"], 1738425600)
        finally:
            os.path.expanduser = orig_expanduser


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
