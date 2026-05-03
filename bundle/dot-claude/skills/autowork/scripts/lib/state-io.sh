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

  if ! jq empty "${state_file}" 2>/dev/null; then
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

append_limited_state() {
  local key="$1"
  local value="$2"
  local max_lines="${3:-20}"
  local target
  local temp

  target="$(session_file "${key}")"
  temp="$(mktemp "${target}.XXXXXX")"

  printf '%s\n' "${value}" >>"${target}"
  tail -n "${max_lines}" "${target}" >"${temp}" 2>/dev/null || cp "${target}" "${temp}"
  mv "${temp}" "${target}"
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
OMC_STATE_LOCK_MAX_ATTEMPTS="${OMC_STATE_LOCK_MAX_ATTEMPTS:-200}"

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

with_state_lock() {
  local lockdir
  lockdir="$(session_file ".state.lock")"
  local pidfile="${lockdir}/holder.pid"
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      # Record holder PID so stale recovery can verify the holder is
      # actually dead before force-releasing. Soft-failure: a missing
      # pidfile falls through to mtime-only recovery (legacy behavior),
      # so the new path is purely additive.
      printf '%s\n' "$$" > "${pidfile}" 2>/dev/null || true
      break
    fi
    attempts=$((attempts + 1))

    # Stale-lock recovery (v1.29.0 metis F-6 fix): if the dir has been
    # held too long AND the recorded holder PID is dead, force-release.
    # PID-check defeats the false-recovery race where a slow-but-live
    # writer (jq parsing 100KB+ state under heavy IO) would otherwise
    # lose its lock to a peer that timed out on mtime alone. Falls
    # through to mtime-only when the pidfile is missing (legacy locks
    # from before this change OR a Test-9-style synthetic stale lock
    # — both treat absence-of-pidfile as "force-release allowed").
    if [[ -d "${lockdir}" ]]; then
      local now
      now="$(date +%s)"
      local held_since
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
      # Mirror the anomaly-on-exhaustion shape used by every other lock
      # primitive in the harness (with_metrics_lock, with_defect_lock,
      # with_resume_lock, with_cross_session_log_lock, with_scope_lock).
      # Without this, lost dimension/review/handoff writes from
      # SubagentStop bursts disappear silently — no /ulw-report signal,
      # no hooks.log entry, just gates that quietly mis-fire next turn.
      log_anomaly "with_state_lock" "lock not acquired after ${OMC_STATE_LOCK_MAX_ATTEMPTS} attempts"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rm -f "${pidfile}" 2>/dev/null || true
  rmdir "${lockdir}" 2>/dev/null || true
  return "${rc}"
}

# Convenience wrapper: atomic write_state_batch inside with_state_lock.
# Usage: with_state_lock_batch k1 v1 k2 v2 ...
with_state_lock_batch() {
  with_state_lock write_state_batch "$@"
}
