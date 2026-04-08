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
    return subprocess.run(
        ["git", "-C", cwd, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
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


MAGENTA = "\033[35m"


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
    data = json.loads(raw) if raw else {}

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

    line_one_parts = [
        color(f"[{model_name}]", CYAN),
        color(dir_name, f"{BOLD}{WHITE}"),
    ]
    if ulw_domain:
        line_one_parts.append(color(f"[ULW:{ulw_domain}]", f"{BOLD}{MAGENTA}"))
    if branch_text:
        line_one_parts.append(color(branch_text, YELLOW))
    line_one_parts.append(color(f"style:{style_name}", f"{DIM}{BLUE}"))

    total_in = safe_get(data, "context_window", "total_input_tokens", default=0)
    total_out = safe_get(data, "context_window", "total_output_tokens", default=0)

    usage_color = bar_color(pct)
    line_two = "  ".join(
        [
            color(make_bar(pct), usage_color),
            color(f"{pct:>3}% ctx", usage_color),
            color(f"{format_tokens(total_in)}\u2191 {format_tokens(total_out)}\u2193", WHITE),
            color(format_cost(total_cost), YELLOW),
            color(format_duration(total_duration_ms), BLUE),
        ]
    )

    print("  ".join(line_one_parts))
    print(line_two)


if __name__ == "__main__":
    main()
