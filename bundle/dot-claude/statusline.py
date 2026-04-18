#!/usr/bin/env python3

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time


RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
WHITE = "\033[97m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
GREEN = "\033[32m"
RED = "\033[31m"
MAGENTA = "\033[35m"


def color(text, code):
    return f"{code}{text}{RESET}"


def safe_get(data, *keys, default=None):
    current = data
    for key in keys:
        if not isinstance(current, dict):
            return default
        current = current.get(key)
        if current is None:
            return default
    return current


def format_duration(total_ms):
    total_seconds = max(int(total_ms or 0) // 1000, 0)
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {seconds:02d}s"
    return f"{seconds}s"


def format_cost(total_cost):
    return f"${float(total_cost or 0.0):.2f}"


def format_tokens(count):
    count = max(int(count or 0), 0)
    if count >= 999_950:
        return f"{count / 1_000_000:.1f}M"
    if count >= 1_000:
        return f"{count / 1_000:.1f}k"
    return str(count)


def bar_color(pct):
    if pct >= 90:
        return RED
    if pct >= 70:
        return YELLOW
    return GREEN


def make_bar(pct, width=18):
    pct = max(0, min(int(pct), 100))
    filled = round((pct / 100.0) * width)
    return ("#" * filled) + ("-" * (width - filled))


def cache_path_for(cwd):
    digest = hashlib.sha1(cwd.encode("utf-8")).hexdigest()[:12]
    return os.path.join(tempfile.gettempdir(), f"claude-statusline-{digest}.json")


def read_cache(path, ttl_seconds):
    try:
        if time.time() - os.path.getmtime(path) > ttl_seconds:
            return None
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def write_cache(path, payload):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
    except OSError:
        pass


def run_git(cwd, *args):
    try:
        return subprocess.run(
            ["git", "-C", cwd, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=2,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            args=["git", "-C", cwd, *args], returncode=1, stdout=""
        )


def git_info(cwd):
    repo_check = run_git(cwd, "rev-parse", "--show-toplevel")
    if repo_check.returncode != 0:
        return {"branch": "", "dirty": False}

    cache_file = cache_path_for(cwd)
    cached = read_cache(cache_file, ttl_seconds=5)
    if cached:
        return cached

    branch = run_git(cwd, "branch", "--show-current").stdout.strip()
    dirty = bool(
        run_git(cwd, "status", "--porcelain", "--untracked-files=no").stdout.strip()
    )

    payload = {"branch": branch, "dirty": dirty}
    write_cache(cache_file, payload)
    return payload


def _read_conf():
    """Read key=value pairs from ~/.claude/oh-my-claude.conf into a dict.

    Last write wins on duplicate keys, matching the `set_conf` semantics
    in install.sh (which strips prior occurrences before appending). Blank
    lines and `#` comments are ignored. Returns an empty dict on missing
    or unreadable files.
    """
    conf_path = os.path.join(os.path.expanduser("~"), ".claude", "oh-my-claude.conf")
    result = {}
    try:
        with open(conf_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                result[key.strip()] = value.strip()
    except (FileNotFoundError, OSError):
        pass
    return result


def installed_version():
    """Read installed_version from oh-my-claude.conf, or None."""
    return _read_conf().get("installed_version") or None


def _parse_version(value):
    """Parse a dotted-int version (e.g. "1.7.0") into a tuple, or None."""
    if not value:
        return None
    try:
        return tuple(int(part) for part in value.split("."))
    except (ValueError, AttributeError):
        return None


def installation_drift(installed):
    """Return a drift descriptor when the source repo is ahead of the bundle.

    Two drift forms are reported:

    1. **Tag-ahead:** the repo's `VERSION` file is strictly newer than the
       installed bundle. Returns `{"version": "<repo-version>"}`.
    2. **Commits-ahead at same tag:** the repo's `VERSION` matches the
       installed bundle, but the repo's HEAD is ahead of the SHA recorded
       at install time (`installed_sha` in the conf). Closes the gap
       where a user pulls two unreleased commits onto a tagged release
       and the indicator would otherwise report "in sync" while the
       local install actually lags the working tree. Returns
       `{"version": "<repo-version>", "commits": N}`.

    For dotted-int versions, the tag-ahead indicator only fires when the
    repo is strictly newer — so a user bisecting on an older tag locally
    does not see a misleading "upgrade available" arrow. If either side
    fails dotted-int parsing (e.g. a pre-release tag like `1.7.0-rc1`),
    falls back to plain string inequality.

    Silently returns None when the check is disabled, when there is no
    installed version, when `repo_path` is unset, when the VERSION file
    is missing/unreadable (e.g. the clone was moved), or when the
    commit-distance probe fails (non-git repo, missing SHA, rewritten
    history). Disable via `installation_drift_check=false` in the conf
    or `OMC_INSTALLATION_DRIFT_CHECK=false`.
    """
    if not installed:
        return None
    conf = _read_conf()
    flag = os.environ.get("OMC_INSTALLATION_DRIFT_CHECK", conf.get("installation_drift_check", "true"))
    if flag.strip().lower() in {"false", "0", "no", "off"}:
        return None
    repo_path = conf.get("repo_path")
    if not repo_path:
        return None
    try:
        with open(os.path.join(repo_path, "VERSION"), "r", encoding="utf-8") as fh:
            upstream = fh.readline().strip()
    except (FileNotFoundError, OSError):
        return None
    if not upstream:
        return None

    # Tag-ahead branch: VERSION file is newer than installed_version.
    if upstream != installed:
        upstream_parsed = _parse_version(upstream)
        installed_parsed = _parse_version(installed)
        if upstream_parsed is not None and installed_parsed is not None:
            if upstream_parsed <= installed_parsed:
                return None
        return {"version": upstream}

    # Commits-ahead branch: VERSION matches, but HEAD may be ahead of the
    # SHA captured at install time. Reading `installed_sha` from the conf
    # rather than tag comparison catches the "pulled two unreleased
    # commits but didn't re-install" case the tag check by design misses.
    installed_sha = conf.get("installed_sha")
    if not installed_sha:
        return None
    try:
        result = subprocess.run(
            ["git", "-C", repo_path, "rev-list", "--count", f"{installed_sha}..HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if result.returncode != 0:
        # installed_sha is unreachable from HEAD (history rewritten,
        # branch force-pushed, SHA from a deleted branch). We earlier
        # returned a `(+?)` marker here to "signal uncertainty," but in
        # practice that produces a persistent noisy indicator on the
        # repo where oh-my-claude itself is developed — any rebase of
        # main orphans the installed_sha and the statusline reports
        # `↑v… (+?)` until the user re-runs install. Returning None
        # aligns with the other fail-closed branches: no drift shown
        # when the comparator cannot produce a trustworthy answer. The
        # tag-ahead branch above still surfaces drift for the common
        # "user forgot to re-install after bumping VERSION" case.
        return None
    raw = (result.stdout or "").strip()
    try:
        count = int(raw or "0")
    except ValueError:
        return None
    if count > 0:
        return {"version": upstream, "commits": count}
    return None


def harness_health():
    """Return 'active' when the most recent session has recent state writes.

    Tightened from the earlier "sentinel-or-hooks.log touched in 5 min"
    heuristic. `hooks.log` is a single global file touched by *any* hook
    in *any* session (including stale reviews or pre-compact writes from
    projects unrelated to the current conversation). Using it as the
    activity signal produced false-positive `[H:ok]` displays when a
    dormant session's tail-end hook had fired minutes ago.

    The refined check walks into the newest session directory under
    `STATE_ROOT` and looks at `session_state.json`'s mtime. State writes
    happen per-hook-invocation within an active session, so a recent
    mtime is a real "this install is being used right now" signal. A
    stale `hooks.log` from yesterday no longer lights the indicator.

    Returns None when no sessions exist, the newest session's state is
    older than 5 minutes, or the state directory cannot be read.
    """
    state_root = os.path.join(os.path.expanduser("~"), ".claude", "quality-pack", "state")
    if not os.path.isdir(state_root):
        return None

    try:
        entries = [
            name for name in os.listdir(state_root)
            if not name.startswith(".") and os.path.isdir(os.path.join(state_root, name))
        ]
    except OSError:
        return None

    if not entries:
        return None

    now = time.time()
    # Sort by directory mtime so we inspect the newest session first. A
    # stale newest means every older session is older still, so we bail
    # without further I/O once the freshest session fails the window.
    try:
        entries.sort(
            key=lambda name: os.path.getmtime(os.path.join(state_root, name)),
            reverse=True,
        )
    except OSError:
        return None

    for name in entries:
        state_file = os.path.join(state_root, name, "session_state.json")
        try:
            age = now - os.path.getmtime(state_file)
        except (FileNotFoundError, OSError):
            # This session never wrote state (partial bootstrap, test
            # fixture). Fall through to the next newest session rather
            # than treating a missing file as a negative signal.
            continue
        if age < 300:
            return "active"
        return None
    return None


def ulw_info():
    """Check if ULW mode is active and return the domain, or None."""
    state_root = os.path.join(os.path.expanduser("~"), ".claude", "quality-pack", "state")
    sentinel = os.path.join(state_root, ".ulw_active")
    if not os.path.isfile(sentinel):
        return None
    try:
        entries = [
            e for e in os.listdir(state_root)
            if not e.startswith(".") and os.path.isdir(os.path.join(state_root, e))
        ]
        if not entries:
            return "active"
        entries.sort(key=lambda e: os.path.getmtime(os.path.join(state_root, e)), reverse=True)
        state_file = os.path.join(state_root, entries[0], "session_state.json")
        with open(state_file, "r", encoding="utf-8") as fh:
            state = json.load(fh)
        return state.get("task_domain") or "active"
    except (OSError, json.JSONDecodeError, IndexError):
        return "active"


def main():
    raw = sys.stdin.read().strip()
    try:
        data = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, ValueError):
        data = {}

    cwd = safe_get(data, "workspace", "current_dir") or safe_get(data, "cwd") or os.getcwd()
    dir_name = os.path.basename(cwd.rstrip(os.sep)) or cwd
    model_name = safe_get(data, "model", "display_name") or safe_get(data, "model", "id") or "Claude"
    style_name = safe_get(data, "output_style", "name") or "default"
    pct = int(float(safe_get(data, "context_window", "used_percentage", default=0) or 0))
    total_cost = safe_get(data, "cost", "total_cost_usd", default=0.0)
    total_duration_ms = safe_get(data, "cost", "total_duration_ms", default=0)

    git = git_info(cwd)
    branch = git.get("branch", "")
    dirty = git.get("dirty", False)
    branch_text = f"git:{branch}{'*' if dirty else ''}" if branch else ""

    ulw_domain = ulw_info()
    omc_version = installed_version()
    omc_drift = installation_drift(omc_version)

    line_one_parts = [
        color(f"[{model_name}]", CYAN),
        color(dir_name, f"{BOLD}{WHITE}"),
    ]
    if ulw_domain:
        line_one_parts.append(color(f"[ULW:{ulw_domain}]", f"{BOLD}{MAGENTA}"))
    elif harness_health() == "active":
        line_one_parts.append(color("[H:ok]", f"{DIM}{GREEN}"))
    if branch_text:
        line_one_parts.append(color(branch_text, YELLOW))
    line_one_parts.append(color(f"style:{style_name}", f"{DIM}{BLUE}"))
    if omc_version:
        line_one_parts.append(color(f"v{omc_version}", f"{DIM}{WHITE}"))
        if isinstance(omc_drift, dict):
            drift_label = f"\u2191v{omc_drift.get('version', '?')}"
            commits = omc_drift.get("commits")
            if commits is not None:
                # `commits="?"` is the explicit "comparator failed"
                # marker set by installation_drift when `installed_sha`
                # is unreachable from HEAD. Showing (+?) surfaces the
                # uncertainty instead of silently hiding the signal.
                drift_label += f" (+{commits})"
            line_one_parts.append(color(drift_label, YELLOW))
        elif omc_drift:
            # Defensive: an older installation_drift impl may return a
            # bare string. Preserve backward-compatible rendering so an
            # in-place statusline.py update before a full reinstall does
            # not crash on a legacy return shape.
            line_one_parts.append(color(f"\u2191v{omc_drift}", YELLOW))

    total_in = safe_get(data, "context_window", "total_input_tokens", default=0)
    total_out = safe_get(data, "context_window", "total_output_tokens", default=0)

    # Cost: mark with * when ULW active — subagent costs are not included
    cost_str = format_cost(total_cost)
    cost_text = (color(cost_str, YELLOW) + color("*", DIM)) if ulw_domain else color(cost_str, YELLOW)

    usage_color = bar_color(pct)
    line_two_parts = [
        color(make_bar(pct), usage_color),
        color(f"{pct:>3}% ctx", usage_color),
        color(f"{format_tokens(total_in)}\u2191 {format_tokens(total_out)}\u2193", WHITE),
        cost_text,
        color(format_duration(total_duration_ms), BLUE),
    ]

    rl_pct_raw = safe_get(data, "rate_limits", "five_hour", "used_percentage", default=None)
    if rl_pct_raw is not None:
        try:
            rl_pct = int(float(rl_pct_raw))
            line_two_parts.append(color(f"RL:{rl_pct}%", bar_color(rl_pct)))
        except (ValueError, TypeError):
            pass

    # Denominator is cache-eligible tokens only (created + read), not total input
    cache_create = int(safe_get(data, "context_window", "current_usage", "cache_creation_input_tokens", default=0) or 0)
    cache_read = int(safe_get(data, "context_window", "current_usage", "cache_read_input_tokens", default=0) or 0)
    cache_total = cache_create + cache_read
    if cache_total > 0:
        cache_pct = int((cache_read / cache_total) * 100)
        line_two_parts.append(color(f"C:{cache_pct}%", f"{DIM}{WHITE}"))

    api_duration_ms = int(safe_get(data, "cost", "total_api_duration_ms", default=0) or 0)
    wall_duration_ms = int(total_duration_ms or 0)
    if wall_duration_ms > 0 and api_duration_ms > 0:
        api_pct = min(int((api_duration_ms / wall_duration_ms) * 100), 100)
        line_two_parts.append(color(f"API:{api_pct}%", f"{DIM}{WHITE}"))

    print("  ".join(line_one_parts))
    print("  ".join(line_two_parts))


if __name__ == "__main__":
    main()
