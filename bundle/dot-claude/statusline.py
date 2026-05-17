#!/usr/bin/env python3

import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import time


# v1.42.x F-020: honor NO_COLOR (the cross-tool de-facto standard;
# https://no-color.org) and OMC_PLAIN (oh-my-claude project convention
# used by install banner, time card, status summary). When either is
# set to a non-empty value, color() becomes a passthrough and ASCII
# glyphs replace Unicode where ambiguous. The check happens at module
# import so the statusline doesn't recompute per render-tick.
_PLAIN_MODE = bool(os.environ.get("NO_COLOR")) or bool(os.environ.get("OMC_PLAIN"))

# Unicode glyphs that have plain-ASCII fallbacks. The drift-arrow ↑
# and rate-limit ↑/↓ tokens previously had no fallback — on a LANG=C
# terminal or a log-capture pipe they would render as `?`. Centralize
# the fallback table here so future surfaces use the same shape.
_GLYPH_FALLBACK = {
    "↑": "^",  # ↑ → ^ (up-arrow: drift indicator, token-in counter)
    "↓": "v",  # ↓ → v (down-arrow: token-out counter)
}


def glyph(unicode_char, override=None):
    """Return `unicode_char` in normal mode, the ASCII fallback in plain mode.

    `override` lets a caller provide a context-specific fallback that
    beats the global table (e.g., ↑ → "+" makes sense in a drift label
    but ↑ → "^" makes sense for a token counter).
    """
    if not _PLAIN_MODE:
        return unicode_char
    if override is not None:
        return override
    return _GLYPH_FALLBACK.get(unicode_char, unicode_char)


RESET = "" if _PLAIN_MODE else "\033[0m"
BOLD = "" if _PLAIN_MODE else "\033[1m"
DIM = "" if _PLAIN_MODE else "\033[2m"
WHITE = "" if _PLAIN_MODE else "\033[97m"
CYAN = "" if _PLAIN_MODE else "\033[36m"
YELLOW = "" if _PLAIN_MODE else "\033[33m"
BLUE = "" if _PLAIN_MODE else "\033[34m"
GREEN = "" if _PLAIN_MODE else "\033[32m"
RED = "" if _PLAIN_MODE else "\033[31m"
MAGENTA = "" if _PLAIN_MODE else "\033[35m"


def color(text, code):
    # v1.42.x F-020: in plain mode the codes are empty strings so the
    # output is identical to the raw text; explicit guard avoids
    # emitting bare RESET sequences when code happens to be empty.
    if not code:
        return text
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


def format_reset_countdown(resets_at_ts, now=None):
    """Compact countdown to a future epoch timestamp for the statusline.

    Used by the rate-limit indicators to show "when does the 5-hour /
    7-day window reset" without bloating line 2. Returns an empty string
    when the input is missing, unparseable, or already past — the
    statusline omits the token entirely in that case rather than
    rendering filler like "0s" or "expired".

    The format intentionally drops separators (`1h23m`, not `1h 23m`) so
    the countdown can sit next to the percent token without the renderer
    inserting double-spaces between visually-related fields.

    Examples (relative to a fixed `now`):
        99000s  → "1d3h"
        12345s  → "3h25m"
        2700s   → "45m"
        45s     → "<1m"
        0s/past → ""
    """
    if not resets_at_ts:
        return ""
    try:
        target = int(resets_at_ts)
    except (ValueError, TypeError, OverflowError):
        # OverflowError catches `int(float('inf'))`. A malformed payload with
        # `resets_at: Infinity` must not crash the statusline; treat it as
        # "no useful reset info" the same as None / past / unparseable.
        return ""
    if target <= 0:
        return ""
    current = int(now if now is not None else time.time())
    delta = target - current
    if delta <= 0:
        return ""
    if delta < 60:
        return "<1m"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        hours, remainder = divmod(delta, 3600)
        minutes = remainder // 60
        if minutes:
            return f"{hours}h{minutes:02d}m"
        return f"{hours}h"
    days, remainder = divmod(delta, 86400)
    hours = remainder // 3600
    if hours:
        return f"{days}d{hours}h"
    return f"{days}d"


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
    """Render a horizontal usage bar.

    v1.42.x F-018: unified on `█/░` (the block-glyph aesthetic used by
    the time-card stacked bar in `lib/timing.sh`) so the brand-signature
    block-glyph reads consistently across surfaces. `OMC_PLAIN`/
    `NO_COLOR` mode falls back to `#/-` for terminals that can't render
    Unicode block characters.
    """
    pct = max(0, min(int(pct), 100))
    filled = round((pct / 100.0) * width)
    if _PLAIN_MODE:
        return ("#" * filled) + ("-" * (width - filled))
    return ("█" * filled) + ("░" * (width - filled))


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


def gate_summary():
    """Count block events in the latest session's gate_events.jsonl.

    Returns a string like ``g:3 f:2`` when the latest session has 3 gate
    blocks and 2 finding resolutions (shipped/deferred/rejected); returns
    just ``g:3`` when no findings closed, or ``f:2`` when blocks are
    zero. Returns None when the file is missing, empty, or unreadable —
    the statusline omits the token entirely when there is no signal.

    Block events are the harness's "I caught something" signal.
    Finding-status-change events with a non-pending status are the
    "I closed the loop" signal. Surfacing both at a glance answers "is
    the harness actually doing anything for me?" without forcing the
    user to run /ulw-report. ``g:`` is gates, ``f:`` is findings (NOT
    "reviews" — reviewer invocations are a separate signal not surfaced
    here, see /ulw-report's reviewer activity table for that).
    """
    state_root = os.path.join(os.path.expanduser("~"), ".claude", "quality-pack", "state")
    if not os.path.isdir(state_root):
        return None

    try:
        entries = [
            e for e in os.listdir(state_root)
            if not e.startswith(".") and os.path.isdir(os.path.join(state_root, e))
        ]
    except OSError:
        return None
    if not entries:
        return None

    try:
        entries.sort(
            key=lambda e: os.path.getmtime(os.path.join(state_root, e)),
            reverse=True,
        )
    except OSError:
        return None

    events_file = os.path.join(state_root, entries[0], "gate_events.jsonl")
    blocks = 0
    resolutions = 0
    try:
        with open(events_file, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                event = row.get("event")
                if event == "block":
                    blocks += 1
                elif event == "finding-status-change":
                    # A status change that closes a finding (anything
                    # away from `pending`) counts as a resolution. The
                    # router writes shipped / deferred / rejected.
                    status = (row.get("details") or {}).get("finding_status", "")
                    if status and status != "pending":
                        resolutions += 1
    except (FileNotFoundError, OSError):
        return None

    if blocks == 0 and resolutions == 0:
        return None

    parts = []
    if blocks > 0:
        parts.append(f"g:{blocks}")
    if resolutions > 0:
        parts.append(f"f:{resolutions}")
    return " ".join(parts)


def persist_rate_limit_status(data):
    # Side-effect: stash rate-limit reset windows into a per-session sidecar so
    # the StopFailure hook can build a resume_request when Claude Code
    # terminates on a rate cap. The hook payload doesn't carry rate_limits, so
    # the statusLine path is the only place this data is reachable. Silent
    # no-op when fields are absent (raw API-key sessions, no session_id, etc.)
    # — never raise.
    rate_limits = safe_get(data, "rate_limits")
    if not isinstance(rate_limits, dict):
        return
    session_id = safe_get(data, "session_id")
    if not session_id or not isinstance(session_id, str):
        return

    windows = {}
    for name in ("five_hour", "seven_day"):
        block = rate_limits.get(name)
        if not isinstance(block, dict):
            continue
        entry = {}
        used = block.get("used_percentage")
        # Filter inf/nan: persisting them serializes to non-strict JSON
        # (`Infinity` / `NaN`), which `stop-failure-handler.sh`'s `jq` reader
        # rejects with a parse error — silently breaking resume-watchdog
        # reset timing. Also: `int(float('inf'))` below would crash the
        # whole statusline before the sidecar ever lands.
        if isinstance(used, (int, float)) and math.isfinite(used):
            entry["used_percentage"] = used
        resets = block.get("resets_at")
        if isinstance(resets, (int, float)) and math.isfinite(resets) and resets > 0:
            entry["resets_at_ts"] = int(resets)
        if entry:
            windows[name] = entry

    if not windows:
        return

    state_root = os.environ.get("STATE_ROOT") or os.path.join(
        os.path.expanduser("~"), ".claude", "quality-pack", "state"
    )
    session_dir = os.path.join(state_root, session_id)
    if not os.path.isdir(session_dir):
        # Don't create the dir — bash hooks own session-dir lifecycle. If it
        # doesn't exist yet, the hook hasn't fired; skip and try next refresh.
        return

    payload = dict(windows)
    payload["captured_at_ts"] = int(time.time())

    target = os.path.join(session_dir, "rate_limit_status.json")
    try:
        fd, tmp_path = tempfile.mkstemp(
            prefix=".rate_limit_status.", suffix=".tmp", dir=session_dir
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(payload, handle)
            os.replace(tmp_path, target)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError:
        return


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
    # Defensive: a malformed payload with `used_percentage: Infinity` would
    # raise OverflowError out of int(float()) and crash the entire render
    # (no line 1, no line 2). Fall back to 0 rather than suppress — line 1's
    # context bar is non-optional so suppression isn't an option here. The
    # rate-limit / cache / API tokens below take the opposite tack: they
    # suppress on bad input because those tokens are conditional anyway.
    try:
        pct = int(float(safe_get(data, "context_window", "used_percentage", default=0) or 0))
    except (ValueError, TypeError, OverflowError):
        pct = 0
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

    # v1.17.0: surface gate-fire / finding-resolution counts at-a-glance
    # so the user can tell whether the harness is actively intervening
    # this session without running /ulw-report. Only renders when there
    # IS signal — silent when the session has been clean.
    gate_text = gate_summary()
    if gate_text:
        line_one_parts.append(color(f"[{gate_text}]", f"{DIM}{YELLOW}"))

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
        color(f"{format_tokens(total_in)}{glyph(chr(0x2191), '^')} {format_tokens(total_out)}{glyph(chr(0x2193), 'v')}", WHITE),
        cost_text,
        color(format_duration(total_duration_ms), BLUE),
    ]

    # 5-hour window: render whenever Claude Code surfaces a percent. Append
    # `R:<countdown>` (dim) when `resets_at` is in the future — answers the
    # "when do I get my budget back?" question without forcing /ulw-report.
    five_hour_pct_raw = safe_get(data, "rate_limits", "five_hour", "used_percentage", default=None)
    five_hour_resets = safe_get(data, "rate_limits", "five_hour", "resets_at", default=None)
    if five_hour_pct_raw is not None:
        try:
            rl_pct = int(float(five_hour_pct_raw))
            rl_token = color(f"RL:{rl_pct}%", bar_color(rl_pct))
            countdown = format_reset_countdown(five_hour_resets)
            if countdown:
                rl_token += color(f" R:{countdown}", f"{DIM}{WHITE}")
            line_two_parts.append(rl_token)
        except (ValueError, TypeError, OverflowError):
            pass

    # 7-day window: only render when used_percentage > 0. Fresh weeks would
    # otherwise add a constant `7d:0%` token to line 2 with no signal value.
    # Same color thresholds as the 5h bar so a hot 7-day reads RED at a glance.
    seven_day_pct_raw = safe_get(data, "rate_limits", "seven_day", "used_percentage", default=None)
    seven_day_resets = safe_get(data, "rate_limits", "seven_day", "resets_at", default=None)
    if seven_day_pct_raw is not None:
        try:
            d7_pct = int(float(seven_day_pct_raw))
            if d7_pct > 0:
                d7_token = color(f"7d:{d7_pct}%", bar_color(d7_pct))
                countdown = format_reset_countdown(seven_day_resets)
                if countdown:
                    d7_token += color(f" R:{countdown}", f"{DIM}{WHITE}")
                line_two_parts.append(d7_token)
        except (ValueError, TypeError, OverflowError):
            pass

    persist_rate_limit_status(data)

    # Denominator is cache-eligible tokens only (created + read), not total
    # input. Defensive cast: a malformed `Infinity` token-count would raise
    # OverflowError out of int() and crash the renderer; same family as the
    # rate-limit and context-window casts above. Falls back to 0 → cache
    # token suppressed entirely, matching the "no signal" branch.
    try:
        cache_create = int(safe_get(data, "context_window", "current_usage", "cache_creation_input_tokens", default=0) or 0)
        cache_read = int(safe_get(data, "context_window", "current_usage", "cache_read_input_tokens", default=0) or 0)
    except (ValueError, TypeError, OverflowError):
        cache_create = 0
        cache_read = 0
    cache_total = cache_create + cache_read
    if cache_total > 0:
        cache_pct = int((cache_read / cache_total) * 100)
        line_two_parts.append(color(f"C:{cache_pct}%", f"{DIM}{WHITE}"))

    try:
        api_duration_ms = int(safe_get(data, "cost", "total_api_duration_ms", default=0) or 0)
        wall_duration_ms = int(total_duration_ms or 0)
    except (ValueError, TypeError, OverflowError):
        api_duration_ms = 0
        wall_duration_ms = 0
    if wall_duration_ms > 0 and api_duration_ms > 0:
        api_pct = min(int((api_duration_ms / wall_duration_ms) * 100), 100)
        line_two_parts.append(color(f"API:{api_pct}%", f"{DIM}{WHITE}"))

    print("  ".join(line_one_parts))
    print("  ".join(line_two_parts))


if __name__ == "__main__":
    main()
