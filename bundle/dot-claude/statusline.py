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
    """Return the repo VERSION when the source repo is ahead of the bundle.

    The repo path is recorded by `install.sh` as `repo_path` in
    `~/.claude/oh-my-claude.conf`. Drift is detected by reading the first
    line of `${repo_path}/VERSION` and comparing it against the installed
    bundle's recorded version.

    For dotted-int versions, the indicator only fires when the repo is
    strictly newer than the bundle — so a user bisecting on an older tag
    locally does not see a misleading "upgrade available" arrow. If
    either side fails dotted-int parsing (e.g. a pre-release tag like
    `1.7.0-rc1`), falls back to plain string inequality so the signal
    still surfaces.

    Silently returns None when the check is disabled, when there is no
    installed version, when `repo_path` is unset, or when the VERSION
    file is missing/unreadable (e.g. the clone was moved). Disable via
    `installation_drift_check=false` in the conf or
    `OMC_INSTALLATION_DRIFT_CHECK=false`.
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
    if not upstream or upstream == installed:
        return None
    upstream_parsed = _parse_version(upstream)
    installed_parsed = _parse_version(installed)
    if upstream_parsed is not None and installed_parsed is not None:
        if upstream_parsed <= installed_parsed:
            return None
    return upstream


def harness_health():
    """Check if the harness is actively intercepting hooks.

    Returns 'active' if the sentinel or hooks.log was touched in the
    last 5 minutes, None otherwise.
    """
    state_root = os.path.join(os.path.expanduser("~"), ".claude", "quality-pack", "state")
    for candidate in [
        os.path.join(state_root, ".ulw_active"),
        os.path.join(state_root, "hooks.log"),
    ]:
        try:
            age = time.time() - os.path.getmtime(candidate)
            if age < 300:
                return "active"
        except (FileNotFoundError, OSError):
            continue
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
        if omc_drift:
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
