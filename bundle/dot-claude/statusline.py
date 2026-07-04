#!/usr/bin/env python3

import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import unicodedata


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


# v1.42.x F-013: cross-session retention counter — "gates blocked in
# last 7 days" surfaced in the statusline so the user feels the
# harness's value passively (no /ulw-report needed). Aggressively
# cached: statusline ticks at ~300ms, gate-event scan is O(N sessions
# × file read), so we cache the count for 5 minutes per (cwd) — that
# reduces compute by ~1000x while keeping the user-visible refresh
# rate within "I just opened a new session" perception. Suppress via
# `statusline_retention=off` in oh-my-claude.conf or
# OMC_STATUSLINE_RETENTION=off (env wins, matching drift-check).
def gates_blocked_last_7d(conf=None):
    """Return integer count of `event=='block'` gate events across all
    sessions in the last 7 days, or None on missing data / disabled."""
    conf = _read_conf() if conf is None else conf
    flag = os.environ.get("OMC_STATUSLINE_RETENTION", conf.get("statusline_retention", "on"))
    if flag.strip().lower() in ("off", "false", "0", "no"):
        return None
    state_root = _sessions_state_root()
    if not os.path.isdir(state_root):
        return None
    # Cache key: tied to the state-root directory (one user = one
    # answer), 5min TTL.
    cache_path = os.path.join(
        tempfile.gettempdir(),
        f"claude-statusline-gates7d-{hashlib.sha1(state_root.encode()).hexdigest()[:12]}.json",
    )
    cached = read_cache(cache_path, ttl_seconds=300)
    if cached is not None and isinstance(cached, dict) and "count" in cached:
        return int(cached["count"])
    cutoff = time.time() - (7 * 86400)
    total = 0
    try:
        for session_id in os.listdir(state_root):
            ge_path = os.path.join(state_root, session_id, "gate_events.jsonl")
            if not os.path.isfile(ge_path):
                continue
            try:
                with open(ge_path, "r", encoding="utf-8") as handle:
                    for line in handle:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            row = json.loads(line)
                        except (json.JSONDecodeError, ValueError):
                            continue
                        if row.get("event") != "block":
                            continue
                        ts = row.get("ts")
                        if ts is None:
                            continue
                        try:
                            ts_num = float(ts)
                        except (ValueError, TypeError):
                            continue
                        if ts_num >= cutoff:
                            total += 1
            except OSError:
                continue
    except OSError:
        return None
    write_cache(cache_path, {"count": total, "computed_at": int(time.time())})
    return total


# v1.42.x F-017: terminal-width budget. Returns the COLUMNS env var if
# set, else os.get_terminal_size's width, else None (unknown — render
# the full line). v1.48-pre upgraded the consumer from a fixed <100-col
# breakpoint to a real fit computation — see _fit_line.
def term_width_budget():
    raw = os.environ.get("COLUMNS")
    if raw:
        try:
            return int(raw)
        except (ValueError, TypeError):
            pass
    try:
        return os.get_terminal_size().columns
    except (OSError, ValueError, AttributeError):
        return None


# v1.48-pre width-fit engine (excellence F1 on the F-017 follow-up):
# the earlier collapse was a fixed <100-col breakpoint, which meant a
# 120-col terminal still got the full worst-case ~158-col line 1 (ULW +
# goal + gates + long branch + drift), and at ≤99 cols the line still
# wrapped because the branch name — the dominant token — was never
# bounded. Lines are now assembled as [key, plain, colored] token
# triples and shed/shrunk through an ordered step list until the plain
# width fits the terminal. Steps run only while the line is over
# budget; a line that already fits renders in full at ANY width (no
# more dropping tokens a 90-col terminal had room for). If every step
# runs and the core identity tokens still exceed the width, we render
# what remains — the terminal wraps, but nothing sane is left to cut.
def _visible_width(text):
    """Terminal display cells for `text`, not codepoints.

    `len()` undercounts CJK/emoji — East-Asian Wide/Fullwidth codepoints
    render as 2 cells (a branch like `功能/中文分支` measures half its
    true width and the engine would judge an overflowing line to fit) —
    and overcounts combining marks (Mn/Me) and format chars like the
    ZWJ (Cf), which render 0 cells. stdlib heuristic; deliberately no
    wcwidth dependency, and no grapheme-cluster segmentation (emoji ZWJ
    sequences still overcount — error is in the safe over-shrink
    direction).
    """
    width = 0
    for ch in text:
        if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
            continue
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def _line_width(tokens):
    """Visible width of a token line: plain cell widths + 2-space joins."""
    if not tokens:
        return 0
    return sum(_visible_width(t[1]) for t in tokens) + 2 * (len(tokens) - 1)


def _fit_line(tokens, width, steps):
    """Apply `steps` (fn(tokens, width) -> tokens) until the line fits.

    `width=None` (unknown terminal) skips fitting entirely — callers
    gate the `statusline_width=off` opt-out by passing None.
    """
    if width is None:
        return tokens
    for step in steps:
        if _line_width(tokens) <= width:
            return tokens
        tokens = step(tokens, width)
    return tokens


def _drop_token(key):
    """Fit step: remove the token with this key (no-op when absent)."""
    def step(tokens, _width):
        return [t for t in tokens if t[0] != key]
    return step


def _token(key, plain, code):
    """Assemble a [key, plain, colored] line token."""
    return [key, plain, color(plain, code)]


def _shorten_git(tokens, _width):
    """Fit step: `git:branch*` → `b:branch*`."""
    out = []
    for t in tokens:
        if t[0] == "git" and t[1].startswith("git:"):
            out.append(_token("git", "b:" + t[1][4:], YELLOW))
        else:
            out.append(t)
    return out


def _trim_countdowns(tokens, _width):
    """Fit step: strip the ` R:<countdown>` suffix from the rate-limit
    tokens, keeping the percentages. Discovered on the 80-col preview:
    with BOTH windows hot the two countdowns push line 2 to ~84 cells
    after every other shed step, and the ladder gave up into a wrap.
    Timing is the first rate-limit data to lose; the percent budget is
    never shed. Recolors from the percent value (same bar_color rule
    used at assembly)."""
    out = []
    for t in tokens:
        if t[0] in ("rl", "d7") and " R:" in t[1]:
            base = t[1].split(" R:", 1)[0]
            try:
                pct_val = int(base.split(":", 1)[1].rstrip("%"))
            except (ValueError, IndexError):
                pct_val = 0
            out.append(_token(t[0], base, bar_color(pct_val)))
        else:
            out.append(t)
    return out


def _truncate_git(tokens, width):
    """Fit step: bound the branch name — the dominant line-1 token.

    Trims one codepoint at a time until the LINE fits (cell-accurate
    for wide CJK/emoji chars, since each pass remeasures via
    _line_width), floored at 5 branch codepoints; appends an ellipsis
    and preserves the dirty `*`. Guard: skip entirely when even the
    floored result would be no narrower than the untrimmed name — in
    plain mode the ellipsis is ".." (2 cells), so trimming a 6-7 char
    branch would otherwise WIDEN the token (review F1).
    """
    out = list(tokens)
    for i, t in enumerate(out):
        if t[0] != "git":
            continue
        head, _, name = t[1].partition(":")
        suffix = "*" if name.endswith("*") else ""
        if suffix:
            name = name[:-1]
        ell = glyph(chr(0x2026), "..")
        if _visible_width(name) <= _visible_width(name[:5]) + _visible_width(ell):
            break
        while len(name) > 5 and _line_width(out) > width:
            name = name[:-1]
            out[i] = _token("git", f"{head}:{name}{ell}{suffix}", YELLOW)
        break
    return out


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


def _sessions_state_root():
    return os.path.join(os.path.expanduser("~"), ".claude", "quality-pack", "state")


# Distinguishes "caller did not supply a pre-read state" from "caller
# read the state and it was None" in ulw_info/goal_armed — main() reads
# session_state.json once per tick and threads it through both, the same
# single-read discipline as the conf threading.
_UNSET = object()


def _usable_session_id(session_id):
    """True when the payload's session_id can safely name a state dir.

    v1.48-pre session-attribution fix: `ulw_info` and `gate_summary`
    previously picked the newest-mtime session directory — with two
    concurrent Claude Code windows, window B's statusline rendered window
    A's ULW domain, gate counts, and cost `*` marker (whichever session
    wrote state last). A usable session_id pins those reads to THIS
    session's dir; the newest-mtime scan survives only for payloads
    without one. Rejects ids carrying path separators or a leading dot —
    a session id is a flat directory name, and the sentinel/hidden-file
    namespace must stay unreachable from payload data.
    """
    if not session_id or not isinstance(session_id, str):
        return False
    if os.sep in session_id or session_id.startswith("."):
        return False
    return True


def read_session_state(session_id):
    """Parse this session's session_state.json into a dict, or None.

    None covers every no-signal case: missing/foreign session_id, dir not
    yet created by the bash hooks (first ticks of a brand-new session),
    unreadable or malformed JSON, or a non-dict top level.
    """
    if not _usable_session_id(session_id):
        return None
    path = os.path.join(_sessions_state_root(), session_id, "session_state.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    return state if isinstance(state, dict) else None


def _sorted_session_entries(state_root):
    """Session dir names under state_root, newest-first by mtime; [] on any error.

    Shared by the fallback paths of harness_health / ulw_info /
    gate_summary — previously each carried its own listdir + mtime-sort
    copy, i.e. up to three full scans of a state root that can hold
    hundreds of session dirs, per ~300ms render tick.
    """
    try:
        entries = [
            name for name in os.listdir(state_root)
            if not name.startswith(".") and os.path.isdir(os.path.join(state_root, name))
        ]
    except OSError:
        return []
    if not entries:
        return []
    try:
        entries.sort(
            key=lambda name: os.path.getmtime(os.path.join(state_root, name)),
            reverse=True,
        )
    except OSError:
        return []
    return entries


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
    # Cache check FIRST. The previous shape ran `rev-parse --show-toplevel`
    # before consulting the cache, which meant one git subprocess on every
    # ~300ms render tick with the cache only saving the branch/status pair.
    # Caching the not-a-repo answer too means a fresh-cache tick spawns
    # zero subprocesses regardless of directory kind.
    cache_file = cache_path_for(cwd)
    cached = read_cache(cache_file, ttl_seconds=5)
    if isinstance(cached, dict) and "branch" in cached:
        return cached

    repo_check = run_git(cwd, "rev-parse", "--show-toplevel")
    if repo_check.returncode != 0:
        payload = {"branch": "", "dirty": False}
        write_cache(cache_file, payload)
        return payload

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

    Flags parsed HERE (Python-side, user-level conf only — the project
    overlay never reaches this file): `installation_drift_check`,
    `statusline_retention`, `statusline_width`. These are intentionally
    absent from common.sh `_parse_conf_file()` and listed in
    `tools/check-flag-coordination.sh` PARSER_EXEMPT_FLAGS — keep the
    three in lockstep when adding a statusline flag.
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


def installed_version(conf=None):
    """Read installed_version from oh-my-claude.conf, or None.

    `conf` lets main() share one parsed conf across the helpers that need
    it (installed_version, installation_drift, gates_blocked_last_7d, the
    width budget) instead of each re-reading the file per render tick.
    Omitted → self-serve, preserving the standalone call shape.
    """
    conf = _read_conf() if conf is None else conf
    return conf.get("installed_version") or None


def _parse_version(value):
    """Parse a dotted-int version (e.g. "1.7.0") into a tuple, or None."""
    if not value:
        return None
    try:
        return tuple(int(part) for part in value.split("."))
    except (ValueError, AttributeError):
        return None


def _commits_ahead(repo_path, installed_sha):
    """Cached `git rev-list --count <installed_sha>..HEAD`; None = probe failed.

    The probe result is cached for 5 minutes keyed on (repo_path,
    installed_sha) — without the cache this subprocess ran on every
    ~300ms statusline tick in the steady state (VERSION matching is the
    normal condition on a maintainer's machine; see gates_blocked_last_7d
    for the same tick-budget reasoning). Failures are cached too: a repo
    where the probe fails (unreachable SHA after a rebase, hung object
    store hitting the 2s timeout) must not re-pay the subprocess — or the
    full timeout — per tick. Staleness tradeoff: a fresh `git pull` can
    take up to 5 minutes to move the (+N) count; acceptable for an
    install-drift indicator.
    """
    cache_key = hashlib.sha1(f"{repo_path}|{installed_sha}".encode("utf-8")).hexdigest()[:12]
    cache_path = os.path.join(
        tempfile.gettempdir(), f"claude-statusline-drift-{cache_key}.json"
    )
    cached = read_cache(cache_path, ttl_seconds=300)
    if isinstance(cached, dict) and "count" in cached:
        return cached["count"]

    count = None
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
        result = None
    if result is not None and result.returncode == 0:
        raw = (result.stdout or "").strip()
        try:
            count = int(raw or "0")
        except ValueError:
            count = None
    write_cache(cache_path, {"count": count, "computed_at": int(time.time())})
    return count


def installation_drift(installed, conf=None):
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
    conf = _read_conf() if conf is None else conf
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
    # None means the probe failed — installed_sha unreachable from HEAD
    # (history rewritten, branch force-pushed, SHA from a deleted branch),
    # timeout, or garbage output. We earlier returned a `(+?)` marker for
    # the unreachable case to "signal uncertainty," but in practice that
    # produces a persistent noisy indicator on the repo where oh-my-claude
    # itself is developed — any rebase of main orphans the installed_sha
    # and the statusline reports `↑v… (+?)` until the user re-runs
    # install. Returning None aligns with the other fail-closed branches:
    # no drift shown when the comparator cannot produce a trustworthy
    # answer. The tag-ahead branch above still surfaces drift for the
    # common "user forgot to re-install after bumping VERSION" case.
    count = _commits_ahead(repo_path, installed_sha)
    if count is None:
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
    state_root = _sessions_state_root()
    if not os.path.isdir(state_root):
        return None

    # Newest-first by directory mtime: a stale newest means every older
    # session is older still, so we bail without further I/O once the
    # freshest session fails the window.
    entries = _sorted_session_entries(state_root)
    if not entries:
        return None

    now = time.time()
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


def ulw_info(session_id=None, state=_UNSET):
    """Check if ULW mode is active FOR THIS SESSION and return the domain.

    The `.ulw_active` sentinel is a global empty touch-file (any ULW
    session anywhere creates it; `/ulw-off` removes it), so it can only
    serve as the cheap fast-path gate. Per-session truth is this
    session's own `workflow_mode == "ultrawork"` in session_state.json —
    without it, a non-ULW window rendered `[ULW:…]` (plus the cost `*`
    marker) whenever any OTHER window was in ULW and happened to be the
    newest-mtime session.

    A usable session_id is authoritative both ways: state missing or
    unreadable → no ULW claim (a brand-new session's first ticks must
    not borrow another window's mode — that is the exact contamination
    this fix closes). The legacy newest-mtime heuristic survives only
    for payloads that carry no session_id at all.
    """
    state_root = _sessions_state_root()
    sentinel = os.path.join(state_root, ".ulw_active")
    if not os.path.isfile(sentinel):
        return None
    if _usable_session_id(session_id):
        if state is _UNSET:
            state = read_session_state(session_id)
        if isinstance(state, dict) and state.get("workflow_mode") == "ultrawork":
            return state.get("task_domain") or "active"
        return None
    try:
        entries = _sorted_session_entries(state_root)
        if not entries:
            return "active"
        state_file = os.path.join(state_root, entries[0], "session_state.json")
        with open(state_file, "r", encoding="utf-8") as fh:
            state = json.load(fh)
        return state.get("task_domain") or "active"
    except (OSError, json.JSONDecodeError, IndexError):
        return "active"


def goal_armed(session_id=None, state=_UNSET):
    """True when this session's /goal relentless driver is armed and not paused.

    Armed = `goal_objective` non-empty in this session's state and
    `goal_paused` not set to "1" (the `/goal pause` marker). A paused or
    cleared goal renders nothing — the statusline shows only the mode
    that is actively driving; `/goal` (status) covers the rest. No
    newest-mtime fallback here: goal state is meaningless cross-session,
    so without a resolvable session_id there is no signal.
    """
    if state is _UNSET:
        state = read_session_state(session_id)
    if not isinstance(state, dict):
        return False
    objective = state.get("goal_objective")
    if not objective or not str(objective).strip():
        return False
    if str(state.get("goal_paused", "")) == "1":
        return False
    return True


def gate_summary(session_id=None):
    """Count block events in THIS session's gate_events.jsonl.

    Returns a string like ``g:3 f:2`` when the session has 3 gate
    blocks and 2 finding resolutions (shipped/deferred/rejected); returns
    just ``g:3`` when no findings closed, or ``f:2`` when blocks are
    zero. Returns None when the file is missing, empty, or unreadable —
    the statusline omits the token entirely when there is no signal.

    Session targeting (v1.48-pre): a usable session_id pins the read to
    that session's dir — a missing dir or missing events file means THIS
    session is clean and renders no token, never a fall-through to some
    other session's numbers. The newest-mtime scan remains solely for
    payloads without a session_id.

    Block events are the harness's "I caught something" signal.
    Finding-status-change events with a non-pending status are the
    "I closed the loop" signal. Surfacing both at a glance answers "is
    the harness actually doing anything for me?" without forcing the
    user to run /ulw-report. ``g:`` is gates, ``f:`` is findings (NOT
    "reviews" — reviewer invocations are a separate signal not surfaced
    here, see /ulw-report's reviewer activity table for that).
    """
    state_root = _sessions_state_root()
    if not os.path.isdir(state_root):
        return None

    if _usable_session_id(session_id):
        session_dir = os.path.join(state_root, session_id)
    else:
        entries = _sorted_session_entries(state_root)
        if not entries:
            return None
        session_dir = os.path.join(state_root, entries[0])

    events_file = os.path.join(session_dir, "gate_events.jsonl")
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

    # One conf parse and one session-state read per tick, shared by every
    # consumer below; one session_id extraction, threading per-session
    # attribution through ulw_info / goal_armed / gate_summary
    # (v1.48-pre fix — see ulw_info).
    conf = _read_conf()
    session_id = safe_get(data, "session_id")
    session_state = read_session_state(session_id)

    ulw_domain = ulw_info(session_id, state=session_state)
    omc_version = installed_version(conf)
    omc_drift = installation_drift(omc_version, conf)

    # Lines assemble as [key, plain, colored] triples (_token) so the fit
    # engine can measure visible width and rewrite tokens (see _fit_line).
    line_one_tokens = [
        _token("model", f"[{model_name}]", CYAN),
        _token("dir", dir_name, f"{BOLD}{WHITE}"),
    ]
    if ulw_domain:
        line_one_tokens.append(_token("mode", f"[ULW:{ulw_domain}]", f"{BOLD}{MAGENTA}"))
    elif harness_health() == "active":
        line_one_tokens.append(_token("mode", "[H:ok]", f"{DIM}{GREEN}"))

    # /goal relentless driver armed for THIS session — the one mode where
    # the harness behaves most differently (Stop stays blocked until the
    # goal is attested done), so it earns a glanceable token next to the
    # ULW mode cluster. Paused/cleared goals render nothing.
    if goal_armed(session_id, state=session_state):
        line_one_tokens.append(_token("goal", "[goal]", f"{BOLD}{MAGENTA}"))

    # v1.17.0: surface gate-fire / finding-resolution counts at-a-glance
    # so the user can tell whether the harness is actively intervening
    # this session without running /ulw-report. Only renders when there
    # IS signal — silent when the session has been clean.
    gate_text = gate_summary(session_id)
    if gate_text:
        line_one_tokens.append(_token("gates", f"[{gate_text}]", f"{DIM}{YELLOW}"))

    if branch_text:
        line_one_tokens.append(_token("git", branch_text, YELLOW))
    line_one_tokens.append(_token("style", f"style:{style_name}", f"{DIM}{BLUE}"))
    if omc_version:
        line_one_tokens.append(_token("version", f"v{omc_version}", f"{DIM}{WHITE}"))
        if isinstance(omc_drift, dict):
            drift_label = f"{glyph(chr(0x2191), '^')}v{omc_drift.get('version', '?')}"
            commits = omc_drift.get("commits")
            if commits is not None:
                # Commits-ahead-at-same-tag drift: `commits` is a
                # positive int (installation_drift returns None for
                # failed/zero probes — the historical `(+?)` uncertainty
                # marker was retired as fail-closed noise).
                drift_label += f" (+{commits})"
            line_one_tokens.append(_token("drift", drift_label, YELLOW))
        elif omc_drift:
            # Defensive: an older installation_drift impl may return a
            # bare string. Preserve backward-compatible rendering so an
            # in-place statusline.py update before a full reinstall does
            # not crash on a legacy return shape.
            line_one_tokens.append(_token("drift", f"{glyph(chr(0x2191), '^')}v{omc_drift}", YELLOW))

    # Width-fit (v1.48-pre, upgrading v1.42.x F-017): shed/shrink
    # lowest-priority tokens until each line fits the terminal. Unknown
    # width (no COLUMNS, no tty) or `statusline_width=off` (env
    # OMC_STATUSLINE_WIDTH wins) → render everything.
    _width_flag = os.environ.get("OMC_STATUSLINE_WIDTH", conf.get("statusline_width", "on"))
    _fit_off = _width_flag.strip().lower() in ("off", "false", "0", "no")
    _term_w = None if _fit_off else term_width_budget()

    line_one_tokens = _fit_line(
        line_one_tokens,
        _term_w,
        [
            _drop_token("style"),
            _shorten_git,
            _truncate_git,
            _drop_token("drift"),
        ],
    )

    total_in = safe_get(data, "context_window", "total_input_tokens", default=0)
    total_out = safe_get(data, "context_window", "total_output_tokens", default=0)

    # Cost: mark with * when ULW active — subagent costs are not included.
    # Composite coloring → build the triple by hand.
    cost_str = format_cost(total_cost)
    if ulw_domain:
        cost_token = ["cost", cost_str + "*", color(cost_str, YELLOW) + color("*", DIM)]
    else:
        cost_token = ["cost", cost_str, color(cost_str, YELLOW)]

    usage_color = bar_color(pct)
    tokens_str = f"{format_tokens(total_in)}{glyph(chr(0x2191), '^')} {format_tokens(total_out)}{glyph(chr(0x2193), 'v')}"
    line_two_tokens = [
        _token("bar", make_bar(pct), usage_color),
        _token("pct", f"{pct:>3}% ctx", usage_color),
        _token("tokens", tokens_str, WHITE),
        cost_token,
        _token("duration", format_duration(total_duration_ms), BLUE),
    ]
    # v1.42.x F-013: retention counter. When the harness has blocked
    # gates in the last 7d, surface `[gw:N]` so the user sees the
    # value passively instead of needing /ulw-report. Silent when 0 (no
    # blocks = no value-evidence = no need to render).
    _g7d = gates_blocked_last_7d(conf)
    if _g7d is not None and _g7d > 0:
        # Token shape `[gw:N]` — gates this week. Distinct from the
        # session-level `[g:N f:M]` token AND the 7-day rate-limit
        # token `7d:NN%` (the test suite asserts the latter's absence
        # by bare-substring match, so any token containing `7d:` would
        # collide). `gw` reads as "gates / week" and keeps line 2
        # compact when retention signal is non-zero.
        line_two_tokens.append(_token("gw", f"[gw:{_g7d}]", f"{DIM}{GREEN}"))

    # 5-hour window: render whenever Claude Code surfaces a percent. Append
    # `R:<countdown>` (dim) when `resets_at` is in the future — answers the
    # "when do I get my budget back?" question without forcing /ulw-report.
    five_hour_pct_raw = safe_get(data, "rate_limits", "five_hour", "used_percentage", default=None)
    five_hour_resets = safe_get(data, "rate_limits", "five_hour", "resets_at", default=None)
    if five_hour_pct_raw is not None:
        try:
            rl_pct = int(float(five_hour_pct_raw))
            rl_plain = f"RL:{rl_pct}%"
            rl_colored = color(rl_plain, bar_color(rl_pct))
            countdown = format_reset_countdown(five_hour_resets)
            if countdown:
                rl_plain += f" R:{countdown}"
                rl_colored += color(f" R:{countdown}", f"{DIM}{WHITE}")
            line_two_tokens.append(["rl", rl_plain, rl_colored])
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
                d7_plain = f"7d:{d7_pct}%"
                d7_colored = color(d7_plain, bar_color(d7_pct))
                countdown = format_reset_countdown(seven_day_resets)
                if countdown:
                    d7_plain += f" R:{countdown}"
                    d7_colored += color(f" R:{countdown}", f"{DIM}{WHITE}")
                line_two_tokens.append(["d7", d7_plain, d7_colored])
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
        line_two_tokens.append(_token("cache", f"C:{cache_pct}%", f"{DIM}{WHITE}"))

    try:
        api_duration_ms = int(safe_get(data, "cost", "total_api_duration_ms", default=0) or 0)
        wall_duration_ms = int(total_duration_ms or 0)
    except (ValueError, TypeError, OverflowError):
        api_duration_ms = 0
        wall_duration_ms = 0
    if wall_duration_ms > 0 and api_duration_ms > 0:
        api_pct = min(int((api_duration_ms / wall_duration_ms) * 100), 100)
        line_two_tokens.append(_token("api", f"API:{api_pct}%", f"{DIM}{WHITE}"))

    def shrink_bar(tokens, _width):
        """Fit step: last resort before giving up — halve the ctx bar."""
        out = []
        for t in tokens:
            if t[0] == "bar":
                out.append(_token("bar", make_bar(pct, width=10), usage_color))
            else:
                out.append(t)
        return out

    # Line-2 fit: diagnostics shed first (least actionable), then the
    # bar compresses (lossless-ish), then the rate-limit countdowns trim
    # (timing before budget). The rate-limit percentages are never shed.
    line_two_tokens = _fit_line(
        line_two_tokens,
        _term_w,
        [
            _drop_token("api"),
            _drop_token("cache"),
            _drop_token("gw"),
            shrink_bar,
            _trim_countdowns,
        ],
    )

    print("  ".join(t[2] for t in line_one_tokens))
    print("  ".join(t[2] for t in line_two_tokens))


if __name__ == "__main__":
    main()
