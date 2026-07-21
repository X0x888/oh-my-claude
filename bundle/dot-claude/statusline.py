#!/usr/bin/env python3

import hashlib
import fcntl
import json
import math
import os
import re
import secrets
import stat
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

# The statusline runs on every render tick, so every payload and filesystem
# walk needs a hard ceiling.  These limits are deliberately much larger than
# normal Claude Code payloads and the harness's 500-row per-session gate-event
# cap, while still preventing one malformed input or stale state tree from
# turning a UI refresh into an unbounded read.
_STATUSLINE_STDIN_MAX_CHARS = 1_048_576
_STATE_ROOT_SCAN_MAX_ENTRIES = 512
_STATE_ROOT_SESSION_MAX = 128
_SESSION_STATE_FILE_MAX_BYTES = 2 * 1_048_576
_SESSION_STATE_SCAN_MAX_BYTES = 8 * 1_048_576
_GATE_EVENT_FILE_MAX_BYTES = 2 * 1_048_576
_GATE_EVENT_FILE_MAX_LINES = 2_000
_GATE_EVENT_LINE_MAX_BYTES = 16_384
_GATE_EVENT_SCAN_MAX_BYTES = 16 * 1_048_576
_GATE_EVENT_SCAN_MAX_LINES = 10_000
_GATE_EVENT_DISPLAY_MAX = 9_999
_CACHE_FILE_MAX_BYTES = 64 * 1024
_CONF_FILE_MAX_BYTES = 256 * 1024
_VERSION_FILE_MAX_BYTES = 4 * 1024
_RATE_LIMIT_FILE_MAX_BYTES = 64 * 1024


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


_CACHE_LEAF_RE = re.compile(r"^claude-statusline-[A-Za-z0-9_.-]+\.json$")


def _same_file_identity(left, right):
    """True when two stat snapshots identify the same filesystem object."""
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _same_file_generation(left, right):
    """True when two fstat snapshots describe one unchanged generation."""
    return _same_file_identity(left, right) and (
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
    ) == (
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
    )


def _open_directory_nofollow(path):
    """Open and identify one real directory leaf without following it."""
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise OSError("directory-relative no-follow operations are unavailable")
    before = os.lstat(path)
    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise OSError("not a real directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(
        os, "O_CLOEXEC", 0
    )
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISDIR(opened.st_mode) or (
            before.st_dev,
            before.st_ino,
        ) != (opened.st_dev, opened.st_ino):
            raise OSError("directory generation changed while opening")
        return fd, opened
    except Exception:
        os.close(fd)
        raise


def _directory_path_matches(path, opened):
    """Re-prove that ``path`` still names the directory held by ``opened``."""
    try:
        current = os.lstat(path)
    except (OSError, ValueError):
        return False
    return (
        stat.S_ISDIR(current.st_mode)
        and not stat.S_ISLNK(current.st_mode)
        and (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino)
    )


def _stat_nofollow_at(directory_fd, leaf):
    """lstat one direct child of an already verified directory descriptor."""
    return os.stat(leaf, dir_fd=directory_fd, follow_symlinks=False)


def _create_private_temp_at(directory_fd, prefix, suffix):
    """Create a private random regular file beneath an anchored directory."""
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("no-follow file creation is unavailable")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    for _ in range(32):
        leaf = f"{prefix}{secrets.token_hex(12)}{suffix}"
        try:
            fd = os.open(leaf, flags, 0o600, dir_fd=directory_fd)
            return fd, leaf
        except FileExistsError:
            continue
    raise OSError("could not allocate a private temporary file")


def _private_cache_root_path():
    uid = os.getuid() if hasattr(os, "getuid") else 0
    return os.path.join(tempfile.gettempdir(), f"claude-statusline-cache-{uid}")


def _open_private_cache_root():
    """Return ``(path, fd, stat)`` for the verified private cache root."""
    uid = os.getuid() if hasattr(os, "getuid") else 0
    root = _private_cache_root_path()
    try:
        try:
            os.mkdir(root, 0o700)
        except FileExistsError:
            pass
        fd, opened = _open_directory_nofollow(root)
        if (
            (hasattr(opened, "st_uid") and opened.st_uid != uid)
            or stat.S_IMODE(opened.st_mode) != 0o700
        ):
            os.close(fd)
            return None
        return root, fd, opened
    except (OSError, TypeError, ValueError, NotImplementedError):
        return None


def _private_cache_root():
    """Return a verified per-user 0700 cache directory, or None.

    Cache filenames are predictable by design, so they must never be opened
    directly in the shared system temp directory. The directory creation is
    atomic; an existing symlink, foreign owner, or permissive directory makes
    caching fail closed for this tick.
    """
    opened = _open_private_cache_root()
    if opened is None:
        return None
    root, fd, _ = opened
    os.close(fd)
    return root


def _cache_path(namespace, identity):
    root = _private_cache_root()
    # Return a deterministic path even when caching is disabled. read_cache /
    # write_cache revalidate the parent and will no-op rather than touching it.
    if root is None:
        root = _private_cache_root_path()
    digest = hashlib.sha1(identity.encode("utf-8")).hexdigest()[:12]
    return os.path.join(root, f"claude-statusline-{namespace}-{digest}.json")


def cache_path_for(cwd):
    return _cache_path("git", cwd)


def _normalize_compat_toggle(value, enabled="on", disabled="off"):
    """Canonicalize the shared true/on/1/yes and false/off/0/no grammar.

    Invalid or empty text is not authoritative and returns None so the caller
    can fall through to the next config source.
    """
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if normalized in {"true", "on", "1", "yes"}:
        return enabled
    if normalized in {"false", "off", "0", "no"}:
        return disabled
    return None


def _effective_user_toggle(
    env_name, conf, key, default, enabled="on", disabled="off"
):
    """Resolve a statusline-only toggle as valid env > valid user > default."""
    env_value = os.environ.get(env_name)
    normalized = _normalize_compat_toggle(env_value, enabled, disabled)
    if normalized is not None:
        return normalized
    normalized = _normalize_compat_toggle(conf.get(key), enabled, disabled)
    if normalized is not None:
        return normalized
    return default


def _contains_terminal_control(value):
    if not isinstance(value, str):
        return True
    return any(unicodedata.category(ch) in {"Cc", "Cf"} for ch in value)


def _terminal_safe_text(value, fallback="", max_length=256):
    if not isinstance(value, str):
        value = str(value) if value is not None else fallback
    value = "".join(
        "?" if _contains_terminal_control(ch) else ch for ch in value
    )
    return value[:max_length] or fallback


def _recent_gate_block_signature(row, cutoff, now):
    """Canonical signature for one recent block row, else ``None``.

    Sweep-only attribution fields are intentionally excluded: the aggregate
    wraps the same live row with them, and native resume can copy that row into
    a differently named owner.  Retaining occurrence counts outside this
    helper means two byte-equivalent blocks in one ledger remain two blocks.
    """
    if not isinstance(row, dict) or row.get("event") != "block":
        return None
    ts = row.get("ts")
    if (
        isinstance(ts, bool)
        or not isinstance(ts, (int, float))
        or (isinstance(ts, float) and not math.isfinite(ts))
        or ts < cutoff
        or ts > now + 300
    ):
        return None
    event = {
        key: value
        for key, value in row.items()
        if key not in {"session_id", "project_key", "_live"}
    }
    try:
        return json.dumps(
            event,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError, OverflowError, RecursionError):
        return None


def _durable_gate_event_id(row):
    """Return a canonical producer-issued gate-event identity, else ``None``."""
    if not isinstance(row, dict):
        return None
    value = row.get("event_id")
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"ge:([A-Za-z0-9_.-]{1,128}):([1-9][0-9]{0,14})", value)
    if match is None:
        return None
    session_id = match.group(1)
    if ".." in session_id or re.fullmatch(r"\.+", session_id):
        return None
    return value


def _gate_event_producer_signature(row):
    """Canonical producer payload, excluding sweep-only attribution."""
    if not isinstance(row, dict):
        return None
    producer = {
        key: value
        for key, value in row.items()
        if key not in {"session_id", "project_key", "_live"}
    }
    try:
        return json.dumps(
            producer,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError, OverflowError, RecursionError):
        return None


# v1.42.x F-013: cross-session retention counter — "gates blocked in
# last 7 days" surfaced in the statusline so the user feels the
# harness's value passively (no /ulw-report needed). Aggressively
# cached: statusline ticks at ~300ms, gate-event scan is O(N sessions
# × file read), so we cache the count for 5 minutes per state root — that
# reduces compute by ~1000x while keeping the user-visible refresh
# rate within "I just opened a new session" perception. Suppress via
# `statusline_retention=off` in oh-my-claude.conf or
# OMC_STATUSLINE_RETENTION=off (env wins, matching drift-check).
def gates_blocked_last_7d(conf=None):
    """Return the bounded de-duplicated 7-day gate-block count.

    Swept sessions live in the quality-pack-wide ``gate_events.jsonl`` while
    active sessions retain a per-session ledger.  A native resume copies its
    source ledger into the target and fences the source with
    ``resume_transferred_to``.  Prefer those live owners, skip valid fenced
    sources, and merge the swept ledger without counting copied rows twice.
    """
    conf = _read_conf() if conf is None else conf
    flag = _effective_user_toggle(
        "OMC_STATUSLINE_RETENTION", conf, "statusline_retention", "on"
    )
    if flag == "off":
        return None
    state_root = _sessions_state_root()
    global_gate_path = os.path.join(os.path.dirname(state_root), "gate_events.jsonl")
    state_root_available = os.path.isdir(state_root)
    try:
        global_info = os.lstat(global_gate_path)
        global_present = stat.S_ISREG(global_info.st_mode) and not stat.S_ISLNK(
            global_info.st_mode
        )
        global_has_data = global_present and global_info.st_size > 0
    except (OSError, ValueError):
        global_present = False
        global_has_data = False
    if not state_root_available and not global_present:
        return None
    # Cache key: tied to the state-root directory (one user = one
    # answer), 5min TTL.
    cache_path = _cache_path("gates7d", state_root)
    cached = read_cache(cache_path, ttl_seconds=300)
    if cached is not None and isinstance(cached, dict) and "count" in cached:
        cached_count = cached["count"]
        if (
            cached.get("source_schema") == 4
            and isinstance(cached_count, int)
            and not isinstance(cached_count, bool)
            and 0 <= cached_count <= _GATE_EVENT_DISPLAY_MAX
        ):
            return cached_count
    now = time.time()
    cutoff = now - (7 * 86400)
    legacy_total = 0
    remaining_bytes = _GATE_EVENT_SCAN_MAX_BYTES
    remaining_lines = _GATE_EVENT_SCAN_MAX_LINES
    remaining_state_bytes = _SESSION_STATE_SCAN_MAX_BYTES
    live_sessions = []

    if state_root_available:
        for session_id in _sorted_session_entries(state_root):
            # The watchdog is synthetic daemon telemetry, not a user session.
            if session_id == "_watchdog":
                continue
            opened_session = _open_safe_session_dir(state_root, session_id)
            if opened_session is None:
                continue
            session_dir, session_fd, session_info = opened_session
            try:
                transfer_target = None
                state_bytes_consumed = 0
                if remaining_state_bytes > 0:
                    state_payload = _read_regular_nofollow_bytes_bounded_at(
                        "session_state.json",
                        min(_SESSION_STATE_FILE_MAX_BYTES, remaining_state_bytes),
                        directory_fd=session_fd,
                    )
                    if state_payload is not None:
                        state_bytes_consumed = len(state_payload)
                        state = _decode_json_object(state_payload)
                        candidate = (
                            state.get("resume_transferred_to")
                            if isinstance(state, dict)
                            else None
                        )
                        # A self-fence is corrupt rather than an ownership
                        # transfer; fail open so hand-edited state cannot hide
                        # telemetry.
                        if (
                            _usable_session_id(candidate)
                            and candidate != session_id
                        ):
                            transfer_target = candidate
                if not _directory_path_matches(session_dir, session_info):
                    continue
                remaining_state_bytes -= state_bytes_consumed
                live_sessions.append(
                    (
                        session_id,
                        (session_info.st_dev, session_info.st_ino),
                        transfer_target,
                    )
                )
            finally:
                try:
                    os.close(session_fd)
                except OSError:
                    pass

    # Reserve half of the aggregate budget when the swept ledger exists. This
    # keeps either source from starving the other while preserving the global
    # byte/line ceilings. Any unused live allowance flows to the swept read.
    live_byte_ceiling = remaining_bytes
    live_line_ceiling = remaining_lines
    if global_has_data:
        live_byte_ceiling -= remaining_bytes // 2
        live_line_ceiling -= remaining_lines // 2

    live_signature_counts = {}
    durable_events = {}
    conflicting_durable_event_ids = set()
    for session_id, session_identity, transfer_target in live_sessions:
        if transfer_target is not None:
            continue
        if (
            remaining_bytes <= 0
            or remaining_lines <= 0
            or live_byte_ceiling <= 0
            or live_line_ceiling <= 0
        ):
            break
        per_file_bytes = min(
            _GATE_EVENT_FILE_MAX_BYTES,
            remaining_bytes,
            live_byte_ceiling,
        )
        per_file_lines = min(
            _GATE_EVENT_FILE_MAX_LINES,
            remaining_lines,
            live_line_ceiling,
        )
        if per_file_bytes <= 0 or per_file_lines <= 0:
            break
        opened_session = _open_safe_session_dir(state_root, session_id)
        if opened_session is None:
            continue
        current_session_dir, session_fd, session_info = opened_session
        try:
            if (session_info.st_dev, session_info.st_ino) != session_identity:
                continue
            rows, consumed_bytes, examined_lines, _ = _read_bounded_jsonl_objects(
                "gate_events.jsonl",
                per_file_bytes,
                per_file_lines,
                directory_fd=session_fd,
            )
            if not _directory_path_matches(current_session_dir, session_info):
                continue
        finally:
            try:
                os.close(session_fd)
            except OSError:
                pass
        remaining_bytes -= consumed_bytes
        remaining_lines -= examined_lines
        live_byte_ceiling -= consumed_bytes
        live_line_ceiling -= examined_lines
        for row in rows:
            event_id = _durable_gate_event_id(row)
            if event_id is not None:
                producer_signature = _gate_event_producer_signature(row)
                prior = durable_events.get(event_id)
                if producer_signature is None:
                    conflicting_durable_event_ids.add(event_id)
                elif prior is None:
                    durable_events[event_id] = (
                        producer_signature,
                        _recent_gate_block_signature(row, cutoff, now) is not None,
                    )
                elif prior[0] != producer_signature:
                    conflicting_durable_event_ids.add(event_id)
                continue
            # A present producer-ID field is identity-bearing schema, not a
            # legacy row.  If its value is malformed, exclude the row instead
            # of silently reclassifying it as ID-less occurrence telemetry.
            if "event_id" in row:
                continue
            signature = _recent_gate_block_signature(row, cutoff, now)
            if signature is None:
                continue
            live_signature_counts[signature] = (
                live_signature_counts.get(signature, 0) + 1
            )
            legacy_total += 1

    # The global ledger can contain both copies of current live rows and older
    # rows that the per-session 500-row tail cap has already evicted. Producer
    # event IDs merge exact resume/bootstrap copies across both sources; one ID
    # with conflicting payloads is excluded as corrupt. Legacy ID-less rows use
    # occurrence merging: each live occurrence consumes at most one equal swept
    # occurrence, while older unique history remains visible.
    if remaining_bytes > 0 and remaining_lines > 0:
        global_rows, consumed_bytes, examined_lines, _ = _read_bounded_jsonl_objects(
            global_gate_path,
            remaining_bytes,
            remaining_lines,
            from_tail=True,
        )
        remaining_bytes -= consumed_bytes
        remaining_lines -= examined_lines
        matched_live_signatures = {}
        for row in global_rows:
            event_id = _durable_gate_event_id(row)
            if event_id is not None:
                producer_signature = _gate_event_producer_signature(row)
                prior = durable_events.get(event_id)
                if producer_signature is None:
                    conflicting_durable_event_ids.add(event_id)
                elif prior is None:
                    durable_events[event_id] = (
                        producer_signature,
                        _recent_gate_block_signature(row, cutoff, now) is not None,
                    )
                elif prior[0] != producer_signature:
                    conflicting_durable_event_ids.add(event_id)
                continue
            if "event_id" in row:
                continue
            signature = _recent_gate_block_signature(row, cutoff, now)
            if signature is None:
                continue
            matched = matched_live_signatures.get(signature, 0)
            if matched < live_signature_counts.get(signature, 0):
                matched_live_signatures[signature] = matched + 1
                continue
            legacy_total += 1
    durable_total = sum(
        1
        for event_id, (_, is_recent_block) in durable_events.items()
        if is_recent_block and event_id not in conflicting_durable_event_ids
    )
    total = min(legacy_total + durable_total, _GATE_EVENT_DISPLAY_MAX)
    write_cache(
        cache_path,
        {
            "source_schema": 4,
            "count": total,
            "computed_at": int(time.time()),
        },
    )
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
    cache_root = _open_private_cache_root()
    if cache_root is None:
        return None
    root, root_fd, root_info = cache_root
    fd = None
    try:
        if os.path.dirname(os.path.abspath(path)) != root:
            return None
        leaf = os.path.basename(path)
        if not _CACHE_LEAF_RE.fullmatch(leaf):
            return None
        info = _stat_nofollow_at(root_fd, leaf)
        uid = os.getuid() if hasattr(os, "getuid") else 0
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or (hasattr(info, "st_uid") and info.st_uid != uid)
            or stat.S_IMODE(info.st_mode) & 0o077
        ):
            return None
        flags = (
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        fd = os.open(leaf, flags, dir_fd=root_fd)
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (info.st_dev, info.st_ino) != (opened.st_dev, opened.st_ino)
            or (hasattr(opened, "st_uid") and opened.st_uid != uid)
            or stat.S_IMODE(opened.st_mode) & 0o077
            or opened.st_size > _CACHE_FILE_MAX_BYTES
        ):
            return None
        age = time.time() - opened.st_mtime
        if age < 0 or age > ttl_seconds:
            return None
        with os.fdopen(fd, "rb") as handle:
            fd = None
            payload = handle.read(_CACHE_FILE_MAX_BYTES + 1)
            after = os.fstat(handle.fileno())
        if (
            not _same_file_generation(opened, after)
            or len(payload) != opened.st_size
            or len(payload) > _CACHE_FILE_MAX_BYTES
            or not _directory_path_matches(root, root_info)
        ):
            return None
        return json.loads(payload.decode("utf-8"))
    except (
        FileNotFoundError,
        OSError,
        TypeError,
        ValueError,
        UnicodeError,
        json.JSONDecodeError,
        NotImplementedError,
    ):
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.close(root_fd)
        except OSError:
            pass


def write_cache(path, payload):
    cache_root = _open_private_cache_root()
    if cache_root is None:
        return
    root, root_fd, root_info = cache_root
    fd = None
    tmp_leaf = None
    try:
        if os.path.dirname(os.path.abspath(path)) != root:
            return
        leaf = os.path.basename(path)
        if not _CACHE_LEAF_RE.fullmatch(leaf):
            return
        uid = os.getuid() if hasattr(os, "getuid") else 0
        try:
            info = _stat_nofollow_at(root_fd, leaf)
        except FileNotFoundError:
            info = None
        if info is not None and (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or (hasattr(info, "st_uid") and info.st_uid != uid)
        ):
            return
        fd, tmp_leaf = _create_private_temp_at(root_fd, ".cache.", ".tmp")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = None
            json.dump(payload, handle)
            handle.flush()
            os.fsync(handle.fileno())
            tmp_info = os.fstat(handle.fileno())
        if tmp_info.st_size > _CACHE_FILE_MAX_BYTES:
            return
        if not _directory_path_matches(root, root_info):
            return
        os.replace(
            tmp_leaf,
            leaf,
            src_dir_fd=root_fd,
            dst_dir_fd=root_fd,
        )
        tmp_leaf = None
        published = _stat_nofollow_at(root_fd, leaf)
        published_is_ours = (
            stat.S_ISREG(published.st_mode)
            and not stat.S_ISLNK(published.st_mode)
            and (published.st_dev, published.st_ino)
            == (tmp_info.st_dev, tmp_info.st_ino)
        )
        if not published_is_ours:
            return
        if not _directory_path_matches(root, root_info):
            # The anchored rename may have won concurrently with a parent
            # retarget. Remove only the exact file we published from the old
            # generation; never touch the replacement directory by pathname.
            current = _stat_nofollow_at(root_fd, leaf)
            if (current.st_dev, current.st_ino) == (
                tmp_info.st_dev,
                tmp_info.st_ino,
            ):
                os.unlink(leaf, dir_fd=root_fd)
    except (
        OSError,
        TypeError,
        ValueError,
        NotImplementedError,
    ):
        return
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp_leaf is not None:
            try:
                os.unlink(tmp_leaf, dir_fd=root_fd)
            except OSError:
                pass
        try:
            os.close(root_fd)
        except OSError:
            pass


def _sessions_state_root():
    return os.environ.get("STATE_ROOT") or os.path.join(
        os.path.expanduser("~"), ".claude", "quality-pack", "state"
    )


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
    if len(session_id) > 128:
        return False
    if re.fullmatch(r"[A-Za-z0-9_.-]+", session_id) is None:
        return False
    if ".." in session_id or re.fullmatch(r"\.+", session_id):
        return False
    # Hidden state-root names are reserved for harness-global sentinels.
    if session_id.startswith("."):
        return False
    return True


def _open_safe_session_dir(state_root, session_id):
    """Open one direct, non-symlink session directory beneath state root."""
    if not _usable_session_id(session_id):
        return None
    root_fd = None
    session_fd = None
    try:
        root_real = os.path.realpath(state_root)
        root_fd, root_info = _open_directory_nofollow(root_real)
        if not _directory_path_matches(root_real, root_info):
            return None
        before = _stat_nofollow_at(root_fd, session_id)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            return None
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(
            os, "O_CLOEXEC", 0
        )
        session_fd = os.open(session_id, flags, dir_fd=root_fd)
        opened = os.fstat(session_fd)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            return None
        candidate = os.path.join(root_real, session_id)
        if not _directory_path_matches(candidate, opened):
            return None
        result = (candidate, session_fd, opened)
        session_fd = None
        return result
    except (OSError, TypeError, ValueError, NotImplementedError):
        return None
    finally:
        if session_fd is not None:
            try:
                os.close(session_fd)
            except OSError:
                pass
        if root_fd is not None:
            try:
                os.close(root_fd)
            except OSError:
                pass


def _open_regular_nofollow(path, directory_fd=None):
    """Open a regular non-symlink leaf for reading without following aliases."""
    before = (
        os.lstat(path)
        if directory_fd is None
        else _stat_nofollow_at(directory_fd, path)
    )
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise OSError("not a regular non-symlink file")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    fd = (
        os.open(path, flags)
        if directory_fd is None
        else os.open(path, flags, dir_fd=directory_fd)
    )
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or (before.st_dev, before.st_ino) != (
            info.st_dev,
            info.st_ino,
        ):
            raise OSError("not a regular file")
        return os.fdopen(fd, "r", encoding="utf-8")
    except Exception:
        os.close(fd)
        raise


def _read_regular_nofollow_bytes_bounded_at(path, max_bytes, directory_fd=None):
    """Read at most ``max_bytes`` from one stable regular-file generation.

    ``None`` is the fail-closed result for aliases, replacements, non-regular
    leaves, and files larger than the caller's budget. ``directory_fd`` anchors
    a direct child to an already verified parent when supplied.
    """
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or max_bytes < 0:
        return None
    fd = None
    try:
        before = (
            os.lstat(path)
            if directory_fd is None
            else _stat_nofollow_at(directory_fd, path)
        )
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
            return None
        flags = (
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        fd = (
            os.open(path, flags)
            if directory_fd is None
            else os.open(path, flags, dir_fd=directory_fd)
        )
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
            or opened.st_size > max_bytes
        ):
            return None
        with os.fdopen(fd, "rb") as handle:
            fd = None
            payload = handle.read(max_bytes + 1)
            after = os.fstat(handle.fileno())
        if (
            not _same_file_generation(opened, after)
            or len(payload) != opened.st_size
            or len(payload) > max_bytes
        ):
            return None
        return payload
    except (FileNotFoundError, OSError, TypeError, ValueError, NotImplementedError):
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


def _read_regular_nofollow_bytes_bounded(path, max_bytes):
    return _read_regular_nofollow_bytes_bounded_at(path, max_bytes)


def _read_regular_nofollow_tail_bytes_bounded(
    path, max_bytes, directory_fd=None
):
    """Read one bounded tail window from a stable regular-file generation.

    Returns ``(payload, selected_entire_file, starts_on_line_boundary)`` or
    ``None``. One byte immediately before a truncated window is inspected so
    the JSONL caller can discard a partial leading record without discarding a
    complete one. The preceding byte and one growth sentinel are structural
    probes and never enter the caller's byte budget.
    """
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or max_bytes < 0:
        return None
    fd = None
    try:
        before = (
            os.lstat(path)
            if directory_fd is None
            else _stat_nofollow_at(directory_fd, path)
        )
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
            return None
        flags = (
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        fd = (
            os.open(path, flags)
            if directory_fd is None
            else os.open(path, flags, dir_fd=directory_fd)
        )
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or (before.st_dev, before.st_ino) != (
            opened.st_dev,
            opened.st_ino,
        ):
            return None

        start = max(0, opened.st_size - max_bytes)
        probe_start = start - 1 if start > 0 else 0
        expected_read = opened.st_size - probe_start
        with os.fdopen(fd, "rb") as handle:
            fd = None
            handle.seek(probe_start)
            raw = handle.read(expected_read + 1)
            after = os.fstat(handle.fileno())
        if (
            not stat.S_ISREG(after.st_mode)
            or not _same_file_generation(opened, after)
            or len(raw) != expected_read
        ):
            return None

        if start > 0:
            if not raw:
                return None
            starts_on_line_boundary = raw[:1] == b"\n"
            payload = raw[1:]
        else:
            starts_on_line_boundary = True
            payload = raw
        if len(payload) > max_bytes:
            return None
        return payload, start == 0, starts_on_line_boundary
    except (FileNotFoundError, OSError, TypeError, ValueError, NotImplementedError):
        return None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


def _decode_json_object(payload):
    """Decode bounded UTF-8 JSON bytes when the top level is an object."""
    if not isinstance(payload, bytes):
        return None
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError):
        return None
    return value if isinstance(value, dict) else None


def _read_bounded_jsonl_objects(
    path, max_bytes, max_lines, *, from_tail=False, directory_fd=None
):
    """Return rows, byte/line accounting, and complete-admission status.

    ``from_tail`` still reads no more than ``max_bytes``, but selects the last
    ``max_lines`` newline-delimited records. Cross-session aggregates are
    append-ordered, so their newest bounded window is the useful one for a
    seven-day counter; per-session callers retain prefix behavior by default.
    """
    if not isinstance(max_lines, int) or isinstance(max_lines, bool) or max_lines <= 0:
        return [], 0, 0, False
    selected_entire_file = True
    starts_on_line_boundary = True
    if from_tail:
        tail_result = _read_regular_nofollow_tail_bytes_bounded(
            path, max_bytes, directory_fd=directory_fd
        )
        if tail_result is None:
            return [], 0, 0, False
        payload, selected_entire_file, starts_on_line_boundary = tail_result
    else:
        payload = _read_regular_nofollow_bytes_bounded_at(
            path, max_bytes, directory_fd=directory_fd
        )
        if payload is None:
            return [], 0, 0, False

    consumed_bytes = len(payload)
    if from_tail and not starts_on_line_boundary:
        first_newline = payload.find(b"\n")
        if first_newline < 0:
            return [], consumed_bytes, 0, False
        payload = payload[first_newline + 1 :]

    payload_len = len(payload)
    raw_lines = []
    if from_tail and payload_len > 0:
        end = payload_len
        if end > 0 and payload.endswith(b"\n"):
            end -= 1
        while end >= 0 and len(raw_lines) < max_lines:
            newline = payload.rfind(b"\n", 0, end)
            raw_lines.append(payload[newline + 1 : end])
            if newline < 0:
                end = -1
                break
            end = newline
        if end >= 0 and len(raw_lines) >= max_lines:
            selected_entire_file = False
        raw_lines.reverse()
    else:
        cursor = 0
        while cursor < payload_len and len(raw_lines) < max_lines:
            newline = payload.find(b"\n", cursor)
            if newline < 0:
                raw_lines.append(payload[cursor:])
                cursor = payload_len
            else:
                raw_lines.append(payload[cursor:newline])
                cursor = newline + 1
        if cursor < payload_len:
            selected_entire_file = False

    rows = []
    all_rows_admitted = True
    for raw_line in raw_lines:
        if raw_line.endswith(b"\r"):
            raw_line = raw_line[:-1]
        if not raw_line or len(raw_line) > _GATE_EVENT_LINE_MAX_BYTES:
            all_rows_admitted = False
            continue
        try:
            row = json.loads(raw_line.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError):
            all_rows_admitted = False
            continue
        if isinstance(row, dict):
            rows.append(row)
        else:
            all_rows_admitted = False
    fully_admitted = (
        selected_entire_file
        and all_rows_admitted
        and (payload_len == 0 or payload.endswith(b"\n"))
    )
    return rows, consumed_bytes, len(raw_lines), fully_admitted


def read_session_state(session_id):
    """Parse this session's session_state.json into a dict, or None.

    None covers every no-signal case: missing/foreign session_id, dir not
    yet created by the bash hooks (first ticks of a brand-new session),
    unreadable or malformed JSON, or a non-dict top level.
    """
    if not _usable_session_id(session_id):
        return None
    opened_session = _open_safe_session_dir(_sessions_state_root(), session_id)
    if opened_session is None:
        return None
    session_dir, session_fd, session_info = opened_session
    try:
        payload = _read_regular_nofollow_bytes_bounded_at(
            "session_state.json",
            _SESSION_STATE_FILE_MAX_BYTES,
            directory_fd=session_fd,
        )
        if payload is None or not _directory_path_matches(session_dir, session_info):
            return None
        return _decode_json_object(payload)
    finally:
        try:
            os.close(session_fd)
        except OSError:
            pass


def _sorted_session_entries(state_root):
    """Bounded session-dir names under state_root, newest-first by mtime.

    Shared by the fallback paths of harness_health / ulw_info /
    gate_summary — previously each carried its own listdir + mtime-sort
    copy, i.e. up to three full scans of a state root that can hold
    hundreds of session dirs, per ~300ms render tick.  Inspect at most
    ``_STATE_ROOT_SCAN_MAX_ENTRIES`` directory entries and retain at most
    ``_STATE_ROOT_SESSION_MAX`` valid sessions; a statusline is a best-effort
    indicator, so omitting excess history is safer than stalling the prompt.
    """
    candidates = []
    try:
        with os.scandir(state_root) as entries:
            for inspected, entry in enumerate(entries, start=1):
                if inspected > _STATE_ROOT_SCAN_MAX_ENTRIES:
                    break
                name = entry.name
                if name.startswith("."):
                    continue
                opened_session = _open_safe_session_dir(state_root, name)
                if opened_session is None:
                    continue
                session_dir, session_fd, session_info = opened_session
                try:
                    if _directory_path_matches(session_dir, session_info):
                        candidates.append((session_info.st_mtime_ns, name))
                finally:
                    try:
                        os.close(session_fd)
                    except OSError:
                        pass
    except (OSError, ValueError):
        return []
    candidates.sort(reverse=True)
    return [name for _, name in candidates[:_STATE_ROOT_SESSION_MAX]]


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
    except (subprocess.TimeoutExpired, OSError, ValueError, UnicodeError):
        return subprocess.CompletedProcess(
            args=["git", "-C", cwd, *args], returncode=1, stdout=""
        )


def _run_git_quiet(cwd, *args):
    """Run a Git predicate without ever buffering repository-sized output."""
    command = ["git", "-C", cwd, *args]
    try:
        return subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=False,
            check=False,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return subprocess.CompletedProcess(args=command, returncode=2)


def _git_tracked_files_dirty(cwd):
    """Return tracked-file dirtiness using quiet exit-status probes only."""
    combined = _run_git_quiet(cwd, "diff-index", "--quiet", "HEAD", "--")
    if combined.returncode in (0, 1):
        return combined.returncode == 1

    # An unborn branch has no HEAD. Preserve the historical tracked-only
    # policy by checking the staged index and worktree independently; errors
    # are no signal rather than a reason to print a false dirty marker.
    staged = _run_git_quiet(cwd, "diff", "--cached", "--quiet", "--")
    unstaged = _run_git_quiet(cwd, "diff-files", "--quiet", "--")
    return staged.returncode == 1 or unstaged.returncode == 1


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
    dirty = _git_tracked_files_dirty(cwd)

    payload = {"branch": branch, "dirty": dirty}
    write_cache(cache_file, payload)
    return payload


def _read_conf():
    """Read key=value pairs from ~/.claude/oh-my-claude.conf into a dict.

    The last valid write wins on duplicate statusline toggles, matching the
    runtime/config helper contract; a malformed later hand-edited row cannot
    erase an earlier valid choice. Other metadata remains ordinary last-write
    wins, matching install.sh's `set_conf` semantics. Blank lines and `#`
    comments are ignored. Returns an empty dict on missing or unreadable files.

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
        payload = _read_regular_nofollow_bytes_bounded(
            conf_path, _CONF_FILE_MAX_BYTES
        )
        if payload is None:
            return {}
        text = payload.decode("utf-8")
        for line in text.split("\n"):
            line = line.rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            # Bash/common.sh accepts exact `key=` rows. Treat whitespace
            # around the key as a malformed row too, so the statusline
            # cannot claim a different authority from runtime/show.
            if key != key.strip():
                continue
            value = value.strip()
            if (
                re.fullmatch(r"[A-Za-z0-9_]+", key) is None
                or _contains_terminal_control(value)
            ):
                continue
            if key == "installation_drift_check":
                value = _normalize_compat_toggle(
                    value, enabled="true", disabled="false"
                )
                if value is None:
                    continue
            elif key in {"statusline_retention", "statusline_width"}:
                value = _normalize_compat_toggle(value)
                if value is None:
                    continue
            elif key == "installed_version":
                if _parse_version(value) is None:
                    continue
            elif key == "installed_sha":
                if re.fullmatch(r"[0-9a-fA-F]{7,40}", value) is None:
                    continue
            elif key == "repo_path":
                if not value or len(value) > 4096 or not os.path.isabs(value):
                    continue
            result[key] = value
    except (FileNotFoundError, OSError, UnicodeError):
        # Never expose a partially decoded authority if a late read/decode
        # failure occurs after one or more valid-looking rows were yielded.
        return {}
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


_SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def _parse_version(value):
    """Parse SemVer core/prerelease components, or None when unorderable."""
    if (
        not isinstance(value, str)
        or len(value) > 128
        or _contains_terminal_control(value)
    ):
        return None
    match = _SEMVER_RE.fullmatch(value)
    if match is None:
        return None
    prerelease = match.group(4)
    identifiers = []
    if prerelease is not None:
        for identifier in prerelease.split("."):
            if identifier.isdigit():
                if len(identifier) > 1 and identifier.startswith("0"):
                    return None
                identifiers.append((0, int(identifier)))
            else:
                identifiers.append((1, identifier))
    try:
        core = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    except (ValueError, OverflowError):
        return None
    return (core, identifiers)


def _compare_versions(left, right):
    """Return -1/0/1 for two valid SemVer strings, else None."""
    left_parsed = _parse_version(left)
    right_parsed = _parse_version(right)
    if left_parsed is None or right_parsed is None:
        return None
    if left_parsed[0] != right_parsed[0]:
        return 1 if left_parsed[0] > right_parsed[0] else -1
    left_pre, right_pre = left_parsed[1], right_parsed[1]
    if not left_pre and not right_pre:
        return 0
    if not left_pre:
        return 1
    if not right_pre:
        return -1
    for left_id, right_id in zip(left_pre, right_pre):
        if left_id == right_id:
            continue
        if left_id[0] != right_id[0]:
            return -1 if left_id[0] == 0 else 1
        return 1 if left_id[1] > right_id[1] else -1
    if len(left_pre) == len(right_pre):
        return 0
    return 1 if len(left_pre) > len(right_pre) else -1


def _commits_ahead(repo_path, installed_sha):
    """Cached descendant-only commit distance; ``None`` = inconclusive.

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
    if (
        not isinstance(repo_path, str)
        or _contains_terminal_control(repo_path)
        or re.fullmatch(r"[0-9a-fA-F]{7,40}", str(installed_sha or "")) is None
    ):
        return None
    cache_path = _cache_path("drift", f"{repo_path}|{installed_sha}")
    cached = read_cache(cache_path, ttl_seconds=300)
    if (
        isinstance(cached, dict)
        and cached.get("source_schema") == 2
        and "descendant" in cached
        and "count" in cached
    ):
        cached_descendant = cached["descendant"]
        cached_count = cached["count"]
        if cached_descendant is False and cached_count is None:
            return None
        if cached_descendant is True and (
            isinstance(cached_count, int)
            and not isinstance(cached_count, bool)
            and cached_count >= 0
        ):
            return cached_count

    count = None
    descendant = False
    try:
        ancestor_result = subprocess.run(
            [
                "git",
                "-C",
                repo_path,
                "merge-base",
                "--is-ancestor",
                installed_sha,
                "HEAD",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError, ValueError, UnicodeError):
        ancestor_result = None
    if ancestor_result is not None and ancestor_result.returncode == 0:
        descendant = True
        try:
            result = subprocess.run(
                [
                    "git",
                    "-C",
                    repo_path,
                    "rev-list",
                    "--count",
                    f"{installed_sha}..HEAD",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
                timeout=2,
            )
        except (subprocess.TimeoutExpired, OSError, ValueError, UnicodeError):
            result = None
        if result is not None and result.returncode == 0:
            raw = (result.stdout or "").strip()
            try:
                count = int(raw or "0")
            except ValueError:
                count = None
        if count is None:
            descendant = False
    # returncode 1 is a proven reachable-but-divergent generation; all other
    # non-zero/exceptional results are likewise inconclusive. Both fail closed
    # and are cached so a rewritten checkout cannot spend a Git probe per tick.
    write_cache(
        cache_path,
        {
            "source_schema": 2,
            "descendant": descendant,
            "count": count,
            "computed_at": int(time.time()),
        },
    )
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

    SemVer precedence, including prereleases, decides whether the repository
    is strictly newer. Unparseable versions fail closed instead of treating
    arbitrary string inequality as an upgrade.

    Silently returns None when the check is disabled, when there is no
    installed version, when `repo_path` is unset, when the VERSION file
    is missing/unreadable (e.g. the clone was moved), or when the
    commit-distance probe fails (non-git repo, missing SHA, rewritten
    history). Disable via `installation_drift_check=false` in the conf
    or `OMC_INSTALLATION_DRIFT_CHECK=false`.
    """
    if not installed or _parse_version(installed) is None:
        return None
    conf = _read_conf() if conf is None else conf
    flag = _effective_user_toggle(
        "OMC_INSTALLATION_DRIFT_CHECK",
        conf,
        "installation_drift_check",
        "true",
        enabled="true",
        disabled="false",
    )
    if flag == "false":
        return None
    repo_path = conf.get("repo_path")
    if (
        not isinstance(repo_path, str)
        or not repo_path
        or _contains_terminal_control(repo_path)
        or len(repo_path) > 4096
        or not os.path.isabs(repo_path)
    ):
        return None
    try:
        version_payload = _read_regular_nofollow_bytes_bounded(
            os.path.join(repo_path, "VERSION"), _VERSION_FILE_MAX_BYTES
        )
        if version_payload is None:
            return None
        upstream = version_payload.decode("utf-8").split("\n", 1)[0].strip()
    except (FileNotFoundError, OSError, UnicodeError, ValueError):
        return None
    if not upstream or _contains_terminal_control(upstream):
        return None

    # Tag-ahead branch: VERSION file is newer than installed_version.
    if upstream != installed:
        precedence = _compare_versions(upstream, installed)
        if precedence is None or precedence <= 0:
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
        opened_session = _open_safe_session_dir(state_root, name)
        if opened_session is None:
            continue
        session_dir, session_fd, session_info = opened_session
        try:
            try:
                with _open_regular_nofollow(
                    "session_state.json", directory_fd=session_fd
                ) as state_handle:
                    state_info = os.fstat(state_handle.fileno())
                    age = now - state_info.st_mtime
            except (FileNotFoundError, OSError, ValueError):
                # This session never wrote state (partial bootstrap, test
                # fixture), or its state leaf is an alias/non-regular node.
                # Fall through to the next newest session rather than treating
                # that untrusted mtime as a positive activity signal.
                continue
            if not _directory_path_matches(session_dir, session_info):
                continue
        finally:
            try:
                os.close(session_fd)
            except OSError:
                pass
        if 0 <= age < 300:
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
    if session_id is not None:
        return None
    try:
        entries = _sorted_session_entries(state_root)
        if not entries:
            return "active"
        state = read_session_state(entries[0])
        if not isinstance(state, dict):
            return "active"
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
        selected_session_id = session_id
    elif session_id is not None:
        return None
    else:
        entries = _sorted_session_entries(state_root)
        if not entries:
            return None
        selected_session_id = entries[0]

    opened_session = _open_safe_session_dir(state_root, selected_session_id)
    if opened_session is None:
        return None
    session_dir, session_fd, session_info = opened_session
    try:
        rows, _, _, _ = _read_bounded_jsonl_objects(
            "gate_events.jsonl",
            _GATE_EVENT_FILE_MAX_BYTES,
            _GATE_EVENT_FILE_MAX_LINES,
            directory_fd=session_fd,
        )
        if not _directory_path_matches(session_dir, session_info):
            return None
    finally:
        try:
            os.close(session_fd)
        except OSError:
            pass

    blocks = 0
    resolutions = 0
    for row in rows:
        event = row.get("event")
        if event == "block":
            blocks = min(blocks + 1, _GATE_EVENT_DISPLAY_MAX)
        elif event == "finding-status-change":
            # A status change that closes a finding (anything away from
            # `pending`) counts as a resolution. The router writes shipped /
            # deferred / rejected.
            details = row.get("details")
            if not isinstance(details, dict):
                continue
            status = details.get("finding_status", "")
            if status and status != "pending":
                resolutions = min(resolutions + 1, _GATE_EVENT_DISPLAY_MAX)

    if blocks == 0 and resolutions == 0:
        return None

    parts = []
    if blocks > 0:
        parts.append(f"g:{blocks}")
    if resolutions > 0:
        parts.append(f"f:{resolutions}")
    return " ".join(parts)


def _valid_percentage(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value < 0 or value > 100:
        return None
    return value


def _valid_reset_timestamp(value):
    # Unix seconds through 2100 is deliberately generous for a rate-limit
    # window while rejecting booleans and absurd magnitudes.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value <= 0 or value > 4_102_444_800:
        return None
    return int(value)


def _valid_nonnegative_count(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value < 0 or value > 9_223_372_036_854_775_807:
        return None
    if isinstance(value, float) and not value.is_integer():
        return None
    return int(value)


def _valid_nonnegative_number(value, maximum=9_223_372_036_854_775_807):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value < 0 or value > maximum:
        return None
    return value


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
    if not _usable_session_id(session_id):
        return
    captured_at_ns = time.time_ns()

    windows = {}
    for name in ("five_hour", "seven_day"):
        block = rate_limits.get(name)
        if not isinstance(block, dict):
            continue
        entry = {}
        used = _valid_percentage(block.get("used_percentage"))
        # Filter inf/nan: persisting them serializes to non-strict JSON
        # (`Infinity` / `NaN`), which `stop-failure-handler.sh`'s `jq` reader
        # rejects with a parse error — silently breaking resume-watchdog
        # reset timing. Also: `int(float('inf'))` below would crash the
        # whole statusline before the sidecar ever lands.
        if used is not None:
            entry["used_percentage"] = used
        resets = _valid_reset_timestamp(block.get("resets_at"))
        if resets is not None:
            entry["resets_at_ts"] = resets
        if entry:
            windows[name] = entry

    if not windows:
        return

    state_root = _sessions_state_root()
    opened_session = _open_safe_session_dir(state_root, session_id)
    if opened_session is None:
        # Don't create the dir — bash hooks own session-dir lifecycle. If it
        # doesn't exist yet, the hook hasn't fired; skip and try next refresh.
        return
    session_dir, session_fd, session_info = opened_session

    payload = dict(windows)
    payload["captured_at_ts"] = captured_at_ns // 1_000_000_000
    payload["captured_at_ns"] = captured_at_ns

    target_leaf = "rate_limit_status.json"
    lock_leaf = ".rate_limit_status.lock"
    lock_fd = None
    fd = None
    tmp_leaf = None
    try:
        uid = os.getuid() if hasattr(os, "getuid") else 0
        pre_lock_info = None
        try:
            pre_lock_info = _stat_nofollow_at(session_fd, lock_leaf)
        except FileNotFoundError:
            pass
        if pre_lock_info is not None and (
            not stat.S_ISREG(pre_lock_info.st_mode)
            or stat.S_ISLNK(pre_lock_info.st_mode)
            or getattr(pre_lock_info, "st_uid", uid) != uid
            or pre_lock_info.st_nlink != 1
        ):
            return
        lock_flags = (
            os.O_CREAT
            | os.O_RDWR
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )
        lock_fd = os.open(lock_leaf, lock_flags, 0o600, dir_fd=session_fd)
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or (
            hasattr(lock_info, "st_uid") and lock_info.st_uid != uid
        ) or lock_info.st_nlink != 1:
            return
        if pre_lock_info is not None and (
            lock_info.st_dev,
            lock_info.st_ino,
        ) != (pre_lock_info.st_dev, pre_lock_info.st_ino):
            return
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        named_lock = _stat_nofollow_at(session_fd, lock_leaf)
        if (named_lock.st_dev, named_lock.st_ino) != (
            lock_info.st_dev,
            lock_info.st_ino,
        ):
            return
        if not _directory_path_matches(session_dir, session_info):
            return

        try:
            target_info = _stat_nofollow_at(session_fd, target_leaf)
        except FileNotFoundError:
            target_info = None
        if target_info is not None:
            if not stat.S_ISREG(target_info.st_mode) or stat.S_ISLNK(target_info.st_mode):
                return
            try:
                existing = _decode_json_object(
                    _read_regular_nofollow_bytes_bounded_at(
                        target_leaf,
                        _RATE_LIMIT_FILE_MAX_BYTES,
                        directory_fd=session_fd,
                    )
                )
                if isinstance(existing, dict):
                    existing_windows = {
                        name: existing[name]
                        for name in ("five_hour", "seven_day")
                        if isinstance(existing.get(name), dict)
                    }
                    # The StopFailure consumer needs the reset-window values,
                    # not a fresh statusline timestamp. Avoid an fsync+replace
                    # on every render tick when the canonical payload is
                    # unchanged.
                    if existing_windows == windows:
                        return
                    existing_ns = existing.get("captured_at_ns")
                    if (
                        not isinstance(existing_ns, int)
                        or isinstance(existing_ns, bool)
                        or existing_ns < 0
                    ):
                        legacy_ts = existing.get("captured_at_ts")
                        if (
                            isinstance(legacy_ts, int)
                            and not isinstance(legacy_ts, bool)
                            and legacy_ts >= 0
                        ):
                            existing_ns = legacy_ts * 1_000_000_000
                    if (
                        isinstance(existing_ns, int)
                        and not isinstance(existing_ns, bool)
                        and existing_ns <= time.time_ns() + 300_000_000_000
                        and existing_ns >= captured_at_ns
                    ):
                        return
            except (OSError, ValueError, UnicodeError, json.JSONDecodeError):
                pass
        fd, tmp_leaf = _create_private_temp_at(
            session_fd, ".rate_limit_status.", ".tmp"
        )
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = None
            json.dump(payload, handle, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
            tmp_info = os.fstat(handle.fileno())
        if tmp_info.st_size > _RATE_LIMIT_FILE_MAX_BYTES:
            raise OSError("oversized rate-limit status payload")
        if not _directory_path_matches(session_dir, session_info):
            raise OSError("session directory generation changed")
        try:
            target_info = _stat_nofollow_at(session_fd, target_leaf)
        except FileNotFoundError:
            target_info = None
        if target_info is not None:
            if not stat.S_ISREG(target_info.st_mode) or stat.S_ISLNK(
                target_info.st_mode
            ):
                raise OSError("unsafe rate-limit status target")
        os.replace(
            tmp_leaf,
            target_leaf,
            src_dir_fd=session_fd,
            dst_dir_fd=session_fd,
        )
        tmp_leaf = None
        published = _stat_nofollow_at(session_fd, target_leaf)
        published_is_ours = (
            stat.S_ISREG(published.st_mode)
            and not stat.S_ISLNK(published.st_mode)
            and (published.st_dev, published.st_ino)
            == (tmp_info.st_dev, tmp_info.st_ino)
        )
        if not published_is_ours:
            raise OSError("unsafe published rate-limit status")
        if not _directory_path_matches(session_dir, session_info):
            current = _stat_nofollow_at(session_fd, target_leaf)
            if (current.st_dev, current.st_ino) == (
                tmp_info.st_dev,
                tmp_info.st_ino,
            ):
                os.unlink(target_leaf, dir_fd=session_fd)
    except (OSError, ValueError, TypeError, NotImplementedError):
        return
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp_leaf is not None:
            try:
                os.unlink(tmp_leaf, dir_fd=session_fd)
            except OSError:
                pass
        if lock_fd is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(lock_fd)
            except OSError:
                pass
        try:
            os.close(session_fd)
        except OSError:
            pass


def _read_statusline_stdin_bounded():
    """Read one status payload without allowing an unbounded stdin buffer."""
    raw = sys.stdin.read(_STATUSLINE_STDIN_MAX_CHARS + 1)
    if not isinstance(raw, str) or len(raw) > _STATUSLINE_STDIN_MAX_CHARS:
        return None
    return raw.strip()


def main():
    raw = _read_statusline_stdin_bounded()
    try:
        data = json.loads(raw) if raw is not None and raw else {}
    except (json.JSONDecodeError, ValueError):
        data = {}

    cwd = safe_get(data, "workspace", "current_dir") or safe_get(data, "cwd") or os.getcwd()
    if not isinstance(cwd, str) or _contains_terminal_control(cwd):
        cwd = os.getcwd()
    dir_name = _terminal_safe_text(os.path.basename(cwd.rstrip(os.sep)) or cwd)
    model_name = _terminal_safe_text(
        safe_get(data, "model", "display_name")
        or safe_get(data, "model", "id")
        or "Claude",
        fallback="Claude",
    )
    style_name = _terminal_safe_text(
        safe_get(data, "output_style", "name") or "default", fallback="default"
    )
    # Defensive: a malformed payload with `used_percentage: Infinity` would
    # raise OverflowError out of int(float()) and crash the entire render
    # (no line 1, no line 2). Fall back to 0 rather than suppress — line 1's
    # context bar is non-optional so suppression isn't an option here. The
    # rate-limit / cache / API tokens below take the opposite tack: they
    # suppress on bad input because those tokens are conditional anyway.
    context_pct = _valid_percentage(
        safe_get(data, "context_window", "used_percentage", default=0)
    )
    pct = int(context_pct) if context_pct is not None else 0
    total_cost = _valid_nonnegative_number(
        safe_get(data, "cost", "total_cost_usd", default=0.0), maximum=1_000_000_000
    )
    if total_cost is None:
        total_cost = 0.0
    total_duration_ms = _valid_nonnegative_count(
        safe_get(data, "cost", "total_duration_ms", default=0)
    )
    if total_duration_ms is None:
        total_duration_ms = 0

    git = git_info(cwd)
    branch = _terminal_safe_text(git.get("branch", ""), max_length=512)
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
        ulw_domain = _terminal_safe_text(ulw_domain, fallback="active")
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
    _width_flag = _effective_user_toggle(
        "OMC_STATUSLINE_WIDTH", conf, "statusline_width", "on"
    )
    _fit_off = _width_flag == "off"
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

    total_in = _valid_nonnegative_count(
        safe_get(data, "context_window", "total_input_tokens", default=0)
    )
    total_out = _valid_nonnegative_count(
        safe_get(data, "context_window", "total_output_tokens", default=0)
    )
    total_in = 0 if total_in is None else total_in
    total_out = 0 if total_out is None else total_out

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
    five_hour_pct = _valid_percentage(five_hour_pct_raw)
    if five_hour_pct is not None:
        rl_pct = int(five_hour_pct)
        rl_plain = f"RL:{rl_pct}%"
        rl_colored = color(rl_plain, bar_color(rl_pct))
        countdown = format_reset_countdown(_valid_reset_timestamp(five_hour_resets))
        if countdown:
            rl_plain += f" R:{countdown}"
            rl_colored += color(f" R:{countdown}", f"{DIM}{WHITE}")
        line_two_tokens.append(["rl", rl_plain, rl_colored])

    # 7-day window: only render when used_percentage > 0. Fresh weeks would
    # otherwise add a constant `7d:0%` token to line 2 with no signal value.
    # Same color thresholds as the 5h bar so a hot 7-day reads RED at a glance.
    seven_day_pct_raw = safe_get(data, "rate_limits", "seven_day", "used_percentage", default=None)
    seven_day_resets = safe_get(data, "rate_limits", "seven_day", "resets_at", default=None)
    seven_day_pct = _valid_percentage(seven_day_pct_raw)
    if seven_day_pct is not None:
        d7_pct = int(seven_day_pct)
        if d7_pct > 0:
            d7_plain = f"7d:{d7_pct}%"
            d7_colored = color(d7_plain, bar_color(d7_pct))
            countdown = format_reset_countdown(_valid_reset_timestamp(seven_day_resets))
            if countdown:
                d7_plain += f" R:{countdown}"
                d7_colored += color(f" R:{countdown}", f"{DIM}{WHITE}")
            line_two_tokens.append(["d7", d7_plain, d7_colored])

    persist_rate_limit_status(data)

    # Denominator is cache-eligible tokens only (created + read), not total
    # input. Defensive cast: a malformed `Infinity` token-count would raise
    # OverflowError out of int() and crash the renderer; same family as the
    # rate-limit and context-window casts above. Falls back to 0 → cache
    # token suppressed entirely, matching the "no signal" branch.
    cache_create = _valid_nonnegative_count(
        safe_get(
            data,
            "context_window",
            "current_usage",
            "cache_creation_input_tokens",
            default=0,
        )
    )
    cache_read = _valid_nonnegative_count(
        safe_get(
            data,
            "context_window",
            "current_usage",
            "cache_read_input_tokens",
            default=0,
        )
    )
    if cache_create is None or cache_read is None:
        cache_create = 0
        cache_read = 0
    cache_total = cache_create + cache_read
    if cache_total > 0:
        cache_pct = int((cache_read / cache_total) * 100)
        line_two_tokens.append(_token("cache", f"C:{cache_pct}%", f"{DIM}{WHITE}"))

    api_duration_ms = _valid_nonnegative_count(
        safe_get(data, "cost", "total_api_duration_ms", default=0)
    )
    api_duration_ms = 0 if api_duration_ms is None else api_duration_ms
    wall_duration_ms = total_duration_ms
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
    try:
        main()
    except Exception:
        # A rendering bug must never blank the status bar: Claude Code
        # replaces the bar with this script's stdout on every tick, so an
        # uncaught exception (e.g. a wrong-typed payload field reaching a
        # numeric format) would exit 1 and wipe the line — and EMPTY
        # stdout blanks it just the same, so emit a minimal fallback line
        # rather than exiting silent. The next tick retries with fresh
        # payload.
        try:
            print("oh-my-claude")
        except Exception:
            pass
        sys.exit(0)
