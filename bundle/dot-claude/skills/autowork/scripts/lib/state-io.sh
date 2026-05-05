# shellcheck shell=bash
# state-io.sh — State I/O subsystem for oh-my-claude.
#
# Sourced by common.sh AFTER STATE_ROOT, STATE_JSON, validate_session_id,
# and log_anomaly are defined. Inherits `set -euo pipefail` from the
# caller (no shebang, no top-level `set` line — this is a sourced library).
#
# Public API:
#   ensure_session_dir            — create ${STATE_ROOT}/${SESSION_ID}/
#   session_file <name>           — path under the session dir
#   read_state <key>              — JSON state read; falls back to plain file
#   write_state <key> <value>     — JSON state write (atomic via temp+mv)
#   write_state_batch k1 v1 ...   — multi-key atomic write (one jq call)
#   append_state <key> <value>    — append a line to ${session}/${key}
#   append_limited_state          — append + tail-truncate to max lines
#   with_state_lock <fn> [args]   — run <fn> under the session mutex
#   with_state_lock_batch ...     — atomic write_state_batch under lock
#
# Private:
#   _state_validated              — per-process flag: state-file validated?
#   _ensure_valid_state           — recover from corrupt session_state.json
#   _lock_mtime                   — BSD/GNU stat compat for lock-staleness

# --- Path helpers ---

ensure_session_dir() {
  if ! validate_session_id "${SESSION_ID}"; then
    log_anomaly "common" "invalid session_id format, skipping: ${SESSION_ID:0:40}"
    exit 0
  fi
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  chmod 700 "${STATE_ROOT}/${SESSION_ID}" 2>/dev/null || true
}

session_file() {
  printf '%s/%s/%s\n' "${STATE_ROOT}" "${SESSION_ID}" "$1"
}

# --- JSON-backed state ---

# Validate and recover state file. If the state file exists but is not
# valid JSON, archive the corrupt file and reset to empty object. This
# prevents the cascade where corrupt state → all read_state returns
# empty → stop-guard silently bypasses all quality gates.
#
# Cached per-process: the validation runs once per hook invocation (each
# hook is a fresh bash process). Subsequent write_state/write_state_batch
# calls in the same process skip the jq validation — they trust their own
# writes from this process, which went through jq already.
_state_validated=0

_ensure_valid_state() {
  if [[ "${_state_validated}" -eq 1 ]]; then
    return
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"

  if [[ ! -f "${state_file}" ]]; then
    printf '{}\n' >"${state_file}"
    _state_validated=1
    return
  fi

  # v1.32.0 Wave C (Item 7 state-fuzz): the original `jq empty` check
  # caught syntactically-invalid JSON but accepted JSON that's a valid
  # NON-OBJECT root (array, string, number, bool, null). On those,
  # subsequent write_state's `jq '.[$k] = $v'` errors with "Cannot
  # index <type> with string" — and (worse) leaves the broken state
  # file in place. The two-stage validation:
  #   stage 1 — file is non-empty (zero-byte files are silent
  #             archives from a prior crash mid-write; treat as corrupt)
  #   stage 2 — root must be an object (so `.[$k] = $v` is well-typed)
  # `jq -e 'type == "object"'` returns 0 only when both conditions
  # hold, false-y otherwise. Catches the full malformation matrix
  # exercised by tests/test-state-fuzz.sh.
  local needs_recovery=0
  if [[ ! -s "${state_file}" ]]; then
    needs_recovery=1
  elif ! jq -e 'type == "object"' "${state_file}" >/dev/null 2>&1; then
    needs_recovery=1
  fi

  if [[ "${needs_recovery}" -eq 1 ]]; then
    local archive recovered_ts
    recovered_ts="$(date +%s)"
    archive="$(session_file "${STATE_JSON}.corrupt.${recovered_ts}")"
    mv "${state_file}" "${archive}" 2>/dev/null || true
    # Persist a sticky recovery marker on the rebuilt state. Without it,
    # subsequent `read_state task_intent` (etc.) returns empty for the
    # rest of the session, the stop-guard's intent gate evaluates to
    # false, and ALL quality gates silently disarm — the user keeps
    # shipping work with no review/verify/excellence enforcement and
    # nothing in the user-facing transcript signals the gates went away.
    # Both `recovered_from_corrupt_ts` and `recovered_from_corrupt_archive`
    # are read by prompt-intent-router on the next UserPromptSubmit so
    # a systemMessage warning surfaces to the user.
    printf '{"recovered_from_corrupt_ts":%s,"recovered_from_corrupt_archive":"%s"}\n' \
      "${recovered_ts}" "${archive//\"/\\\"}" >"${state_file}"
    log_anomaly "common" "corrupt state detected and archived: ${archive}"
  fi

  _state_validated=1
}

write_state() {
  local key="$1"
  local value="$2"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  _ensure_valid_state

  if jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" >"${temp_file}"; then
    mv "${temp_file}" "${state_file}"
  else
    rm -f "${temp_file}"
    return 1
  fi
}

write_state_batch() {
  if [[ $(( $# % 2 )) -ne 0 ]]; then
    printf 'write_state_batch: odd number of arguments (%d)\n' "$#" >&2
    return 1
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  _ensure_valid_state

  local jq_filter="."
  local args=()
  local idx=0

  while [[ $# -ge 2 ]]; do
    args+=(--arg "k${idx}" "$1" --arg "v${idx}" "$2")
    jq_filter="${jq_filter} | .[(\$k${idx})] = \$v${idx}"
    shift 2
    idx=$((idx + 1))
  done

  if jq "${args[@]}" "${jq_filter}" "${state_file}" >"${temp_file}"; then
    mv "${temp_file}" "${state_file}"
  else
    rm -f "${temp_file}"
    return 1
  fi
}

append_state() {
  local key="$1"
  local value="$2"
  printf '%s\n' "${value}" >>"$(session_file "${key}")"
}

# Lock-protected body of append_limited_state. Extracted so the public
# function can wrap with_state_lock around the read-modify-write cycle
# without the lock helper paying the function-resolution cost on every
# caller.
_append_limited_state_locked() {
  local target="$1"
  local value="$2"
  local max_lines="$3"
  local temp
  temp="$(mktemp "${target}.XXXXXX")" || return 1
  printf '%s\n' "${value}" >>"${target}"
  tail -n "${max_lines}" "${target}" >"${temp}" 2>/dev/null || cp "${target}" "${temp}"
  mv "${temp}" "${target}"
}

append_limited_state() {
  local key="$1"
  local value="$2"
  local max_lines="${3:-20}"
  local target

  target="$(session_file "${key}")"

  # v1.31.0 Wave 2 (sre-lens F-1): lock-protect the read-modify-write
  # cycle. Without the lock, two concurrent SubagentStop hooks racing
  # this function on gate_events.jsonl can lose rows: peer A appends
  # row_a, reads tail (includes row_a + prior history), but before
  # peer A's mv runs, peer B appends row_b. Peer A's mv then writes
  # the tail snapshot that did NOT see row_b — row_b is silently
  # dropped. Council Phase 8 fan-out (5 parallel reviewers writing
  # 30+ gate_events) is the worst-case workload. with_state_lock
  # serializes the cycle; the lock is mkdir-as-mutex (~5ms) and the
  # contention window is bounded by the per-session gate-event cap
  # (default 500). When SESSION_ID is unset (test rigs, /omc-config
  # without a session), fall through to the unlocked path so callers
  # outside an active session continue to work.
  if [[ -n "${SESSION_ID:-}" ]]; then
    # v1.31.2 quality-reviewer F-3: do NOT fall through to the unlocked
    # path on LOCK-ACQUISITION FAILURE. Pre-Wave-1.31.2 behavior used
    # `with_state_lock ... || _append_limited_state_locked ...` which
    # silently retried unlocked when the lock cap fired (default 60
    # attempts ~ 3s) — re-introducing the row-tearing race the lock
    # was designed to prevent under heavy council Phase 8 fan-out.
    # `with_state_lock` already calls `log_anomaly` on cap exhaustion,
    # so the loss is auditable. Returning early is the correct
    # degradation: better to drop ONE row (recorded in the anomaly log)
    # than to tear ROWS in the JSONL append cycle.
    with_state_lock _append_limited_state_locked "${target}" "${value}" "${max_lines}"
  else
    # SESSION_ID unset (test rigs, /omc-config without a session,
    # synthetic _watchdog daemon writes) — no lock dir to compute
    # against. Fall through to the unlocked path; concurrent writers
    # are not a credible threat shape outside an active session.
    _append_limited_state_locked "${target}" "${value}" "${max_lines}"
  fi
}

read_state() {
  local key="$1"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"

  if [[ -f "${state_file}" ]]; then
    # Distinguish "key absent" from "key present with empty value" so
    # write_state(key, "") (a deliberate clear) does NOT silently revive
    # a stale legacy sidecar with the same name. v1.29.0 metis F-3 fix.
    # `has(key)` is the presence test; the sentinel threads the absence
    # signal through jq -r's string-only stdout. The sentinel is unlikely
    # to appear as a legitimate state value (33 bytes of underscores +
    # caps + suffix). Test 6 (missing-key fallback) preserved; the new
    # behavior is that empty-string values are returned verbatim instead
    # of falling through to the sidecar.
    local result
    result="$(jq -r --arg k "${key}" '
      if has($k) then
        (.[$k] // "")
      else
        "__OMC_KEY_ABSENT__"
      end
    ' "${state_file}" 2>/dev/null || printf '__OMC_KEY_ABSENT__')"

    if [[ "${result}" != "__OMC_KEY_ABSENT__" ]]; then
      printf '%s' "${result}"
      return
    fi
  fi

  # Fallback: individual file (backwards compat for keys that legacy
  # code wrote to a sidecar before the JSON-state migration). Only
  # reached when the JSON key is absent — NOT when it was cleared to
  # empty. This preserves the deliberate-clear semantic that callers
  # like prompt-intent-router.sh:97-106 rely on (clearing 8 keys to ""
  # at every UserPromptSubmit must NOT revive stale legacy sidecars).
  cat "$(session_file "${key}")" 2>/dev/null || true
}

# read_state_keys k1 k2 k3 ...
#
# Bulk-read N keys from session_state.json in a single jq invocation.
# Emits one line per key, in the order given. Missing keys emit an
# empty line — preserving positional alignment so the caller can index
# the output by argument position.
#
# Usage:
#   mapfile -t values < <(read_state_keys task_intent task_domain ulw_active)
#   intent="${values[0]}"
#   domain="${values[1]}"
#   active="${values[2]}"
#
# Why this exists (v1.27.0 F-018/F-019): stop-guard.sh previously made
# 41 separate `read_state` calls per Stop event, and prompt-intent-
# router.sh made 15+ per UserPromptSubmit. Each call forks `jq` and
# does an independent file read. Bulk-reading 30+ keys in one jq
# invocation cuts dominant-path subprocess overhead by ~30 jq forks
# per turn (~100ms of cumulative wallclock on macOS bash 3.2). The
# fallback-to-individual-file path that read_state has for backwards
# compat is intentionally NOT replicated here; bulk reads are JSON-
# state-only by design. If a key is in a sidecar file, use read_state
# directly.
read_state_keys() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  if [[ ! -f "${state_file}" ]]; then
    # Emit empty lines for each requested key — preserves positional
    # indexing in the caller's mapfile.
    local _i
    for ((_i = 0; _i < $#; _i++)); do
      printf '\n'
    done
    return 0
  fi
  # Note on argument order: jq's `--args` flag consumes ALL trailing
  # positional arguments AFTER the filter as $ARGS.positional. If we
  # passed the JSON file as a positional too, jq would treat it as a
  # key name and read JSON from stdin (which would be empty). Pipe the
  # file in via stdin redirect so the filename never lands on argv.
  jq -r --args '$ARGS.positional[] as $k | .[$k] // ""' "$@" < "${state_file}" 2>/dev/null \
    || {
      # On jq failure (corrupt state, etc), emit empty lines so the
      # caller's mapfile stays positionally aligned.
      local _i
      for ((_i = 0; _i < $#; _i++)); do
        printf '\n'
      done
    }
}

# --- Portable state lock (mkdir primitive, BSD/GNU stat compat) ---
#
# Wraps a function call with a mutex held against the session's state
# directory. Uses mkdir as the atomic lock primitive (portable across
# macOS and Linux — flock is non-standard on BSD). A stale-lock timeout
# prevents a crashed hook from holding the lock forever: if the lockdir
# is older than OMC_STATE_LOCK_STALE_SECS (default 5), force-release it.
#
# Usage: with_state_lock my_function arg1 arg2 ...
#
# Returns the wrapped function's exit status, or 1 if the lock cannot
# be acquired within OMC_STATE_LOCK_MAX_ATTEMPTS polls (default 200).

OMC_STATE_LOCK_STALE_SECS="${OMC_STATE_LOCK_STALE_SECS:-5}"
# v1.31.0 Wave 2 (sre-lens F-5): cap tightened from 200×50ms (10s) to
# 60×50ms (3s) — practical lock-hold time under heavy fan-out is well
# under 1s; 3s is comfortable headroom and prevents hot-path stalls
# from blowing past the 1000ms stop-guard budget. The PID-based stale
# recovery at OMC_STATE_LOCK_STALE_SECS=5 already kicks in at 5s, so
# the cap rarely fires in practice — the only path that hits it is
# pathological contention (bash 5+ kernel-serialized appender storm
# across 5+ peers) where the right answer is "report and skip" not
# "wait 10 more seconds."
OMC_STATE_LOCK_MAX_ATTEMPTS="${OMC_STATE_LOCK_MAX_ATTEMPTS:-60}"
# Long-wait threshold (in attempts) for soft telemetry. When a lock
# is held past this many attempts but hasn't yet exhausted the cap,
# emit a `lock-long-wait` anomaly so /ulw-report can surface
# contention patterns BEFORE the cap fires. Default 30 = ~1.5s of
# polling — picked to fire on real contention but not on every busy
# council Phase 8 turn.
OMC_STATE_LOCK_LONG_WAIT_ATTEMPTS="${OMC_STATE_LOCK_LONG_WAIT_ATTEMPTS:-30}"

_lock_mtime() {
  # Echoes mtime epoch of $1, or 0 on error. Tries BSD stat -f, then GNU stat -c.
  local target="$1"
  local ts
  ts="$(stat -f %m "${target}" 2>/dev/null)" || ts=""
  if [[ -z "${ts}" ]]; then
    ts="$(stat -c %Y "${target}" 2>/dev/null)" || ts="0"
  fi
  printf '%s' "${ts:-0}"
}

# _with_lockdir <lockdir> <tag> <cmd> [args...]
#
# Run `<cmd> args...` while holding an mkdir-mutex on <lockdir>.
# Centralizes the locking primitive used by every with_*_lock helper in
# the harness: with_state_lock, with_metrics_lock, with_defect_lock,
# with_resume_lock, with_skips_lock, with_cross_session_log_lock,
# with_scope_lock. Public helpers stay one-line wrappers preserving
# their names + signatures so call sites and tests are unchanged.
#
# Behavior:
#   - mkdir-as-mutex with PID-based stale recovery (v1.29.0 metis F-6
#     pattern, generalized in v1.30.0). Records holder PID into
#     <lockdir>/holder.pid; on stale-mtime, force-releases ONLY when
#     the recorded PID is dead (or pidfile is absent — legacy / synthetic
#     stale locks). Defeats the false-recovery race where a slow-but-live
#     writer (jq parsing 100KB+ state under heavy IO) would otherwise
#     lose its lock to a peer that timed out on mtime alone.
#   - Caps acquisition at OMC_STATE_LOCK_MAX_ATTEMPTS polls; stale window
#     is OMC_STATE_LOCK_STALE_SECS (default 5s).
#   - On exhaustion: log_anomaly "${tag}" "lock not acquired after N
#     attempts" then return 1. The tag is the caller-provided name
#     (with_metrics_lock, etc.) so log audit retains per-helper attribution.
#     Naturally fixes the v1.29.0 sre-lens F-5 finding (with_skips_lock
#     used to silent-fail on exhaustion; routing through this helper
#     adds the anomaly emit for free).
#   - Cleans up pidfile + lockdir even when the wrapped command fails.
#   - Creates lockdir's parent best-effort (idempotent) so cross-session
#     lock paths under ~/.claude/quality-pack/ work even on first install.
#
# Returns the wrapped command's exit status, or 1 on lock-acquisition
# failure.
_with_lockdir() {
  local lockdir="$1"
  local tag="$2"
  shift 2
  local pidfile="${lockdir}/holder.pid"
  local lock_parent
  lock_parent="$(dirname "${lockdir}")"
  mkdir -p "${lock_parent}" 2>/dev/null || true
  local attempts=0
  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      printf '%s\n' "$$" > "${pidfile}" 2>/dev/null || true
      break
    fi
    attempts=$((attempts + 1))
    if [[ -d "${lockdir}" ]]; then
      local now held_since
      now="$(date +%s)"
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        local holder_pid=""
        if [[ -f "${pidfile}" ]]; then
          holder_pid="$(tr -d '[:space:]' < "${pidfile}" 2>/dev/null || true)"
        fi
        if [[ -z "${holder_pid}" ]] || ! kill -0 "${holder_pid}" 2>/dev/null; then
          rm -f "${pidfile}" 2>/dev/null || true
          rmdir "${lockdir}" 2>/dev/null || true
          continue
        fi
      fi
    fi
    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      log_anomaly "${tag}" "lock not acquired after ${OMC_STATE_LOCK_MAX_ATTEMPTS} attempts"
      return 1
    fi
    # v1.31.0 Wave 2 (sre-lens F-5): emit a one-shot soft anomaly at the
    # long-wait threshold so /ulw-report can surface contention BEFORE
    # the hard cap fires. The `-eq` exact-equality predicate against
    # the monotonically-incrementing `attempts` counter inherently fires
    # ONCE per acquisition (no separate guard variable needed; the
    # increment-and-compare semantics keep the log row count bounded).
    if [[ "${attempts}" -eq "${OMC_STATE_LOCK_LONG_WAIT_ATTEMPTS}" ]]; then
      log_anomaly "${tag}" "lock long-wait at ${attempts} attempts"
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  local rc=0
  "$@" || rc=$?
  rm -f "${pidfile}" 2>/dev/null || true
  rmdir "${lockdir}" 2>/dev/null || true
  return "${rc}"
}

with_state_lock() {
  # ── Re-entrancy contract (v1.31.3 quality-reviewer F-3 followup) ───
  #
  # Marker:    _OMC_STATE_LOCK_HELD (env)
  # Set when:  the OUTERMOST with_state_lock call enters; cleared on exit
  # Read by:   nested calls — they skip lockdir acquire and run body inline
  # Why:       v1.31.2 added with_state_lock around append_limited_state's
  #            read-modify-write. Outer callers (record-pending-agent.sh,
  #            record-serendipity.sh, mark-deferred.sh, etc.) already wrap
  #            their work bodies in with_state_lock. Without re-entrancy
  #            detection, the inner mkdir-based lockdir acquire collides
  #            with the outer's held lockdir, the inner _with_lockdir
  #            returns non-zero, and the body silently drops.
  #
  # External callers that wrap with_state_lock around bodies that
  # transitively call append_limited_state / write_state / write_state_batch:
  #   bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh
  #   bundle/dot-claude/skills/autowork/scripts/record-serendipity.sh
  #   bundle/dot-claude/skills/autowork/scripts/mark-deferred.sh
  #   bundle/dot-claude/skills/autowork/scripts/record-finding-list.sh
  #   bundle/dot-claude/skills/autowork/scripts/record-scope-checklist.sh
  #
  # If you add a new caller that nests with_state_lock around a body
  # that touches state, you do NOT need to do anything — the marker
  # handles it. If you add a new state-touching helper that should
  # acquire its own lock when called standalone (like append_limited_state)
  # you DO need with_state_lock; the marker makes it composition-safe.
  #
  # Tested by tests/test-state-io.sh:T18 (CI-pinned in v1.32.0).
  if [[ -n "${_OMC_STATE_LOCK_HELD:-}" ]]; then
    "$@"
    return $?
  fi
  local lockdir
  lockdir="$(session_file ".state.lock")"
  # Set the marker for the duration of the locked body so nested
  # callers detect re-entrancy and skip re-acquisition. Unset on
  # return regardless of body success/failure.
  local _outer_held="${_OMC_STATE_LOCK_HELD:-}"
  _OMC_STATE_LOCK_HELD=1
  local _rc=0
  _with_lockdir "${lockdir}" "with_state_lock" "$@" || _rc=$?
  _OMC_STATE_LOCK_HELD="${_outer_held}"
  return "${_rc}"
}

# Convenience wrapper: atomic write_state_batch inside with_state_lock.
# Usage: with_state_lock_batch k1 v1 k2 v2 ...
with_state_lock_batch() {
  with_state_lock write_state_batch "$@"
}
