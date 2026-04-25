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
    local archive
    archive="$(session_file "${STATE_JSON}.corrupt.$(date +%s)")"
    mv "${state_file}" "${archive}" 2>/dev/null || true
    printf '{}\n' >"${state_file}"
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
  local result=""

  if [[ -f "${state_file}" ]]; then
    result="$(jq -r --arg k "${key}" '.[$k] // empty' "${state_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${result}" ]]; then
    printf '%s' "${result}"
    return
  fi

  # Fallback: individual file (backwards compat or JSON key missing)
  cat "$(session_file "${key}")" 2>/dev/null || true
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
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))

    # Stale-lock recovery: if the dir has been held too long, force-release.
    if [[ -d "${lockdir}" ]]; then
      local now
      now="$(date +%s)"
      local held_since
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
    fi

    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null || true
  return "${rc}"
}

# Convenience wrapper: atomic write_state_batch inside with_state_lock.
# Usage: with_state_lock_batch k1 v1 k2 v2 ...
with_state_lock_batch() {
  with_state_lock write_state_batch "$@"
}
