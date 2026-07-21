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
#   rewrite_jsonl_line_atomic      — replace/delete exactly one JSONL row atomically
#   with_state_lock <fn> [args]   — run <fn> under the session mutex
#   with_state_lock_batch ...     — atomic write_state_batch under lock
#
# Private:
#   _state_validated              — per-process flag: state-file validated?

# common.sh uses a short-lived bootstrap resolver and intentionally removes it
# after loading the libraries. State-I/O authorization checks run much later,
# so keep their own private resolver rather than depending on that retired
# helper. This also makes the library's runtime dependency explicit.
_omc_state_io_resolve_path() {
  local path="${1:-}" target="" parent="" base="" hops=0
  [[ -n "${path}" ]] || return 1
  while (( hops < 16 )); do
    # Canonicalize the containing directory on every hop. Installations and
    # tests commonly symlink the whole ~/.claude/skills directory rather than
    # each script, so checking only the final path component leaves `$0` at
    # the alias while BASH_SOURCE resolves to the bundle and falsely rejects a
    # legitimate scoped caller capability.
    case "${path}" in
      */*)
        parent="${path%/*}"
        base="${path##*/}"
        [[ -n "${parent}" ]] || parent="/"
        ;;
      *)
        parent="."
        base="${path}"
        ;;
    esac
    parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 1
    path="${parent%/}/${base}"
    [[ -L "${path}" ]] || {
      printf '%s\n' "${path}"
      return 0
    }
    target="$(readlink "${path}")" || return 1
    case "${target}" in
      /*) path="${target}" ;;
      *) path="${parent%/}/${target}" ;;
    esac
    hops=$((hops + 1))
  done
  return 1
}
#   _ensure_valid_state           — recover from corrupt session_state.json
#   _lock_mtime                   — BSD/GNU stat compat for lock-staleness

# --- Path helpers ---

ensure_session_dir() {
  if ! validate_session_id "${SESSION_ID}"; then
    log_anomaly "common" "invalid session_id format, skipping: ${SESSION_ID:0:40}"
    exit 0
  fi
  # v1.40.x security-lens F-004: harden parent dir perms for defense-in-
  # depth on multi-user hosts. STATE_ROOT and its ~/.claude/quality-pack
  # parent are created via `mkdir -p` elsewhere without explicit chmod —
  # if they were created by an earlier-loaded tool with default 0755,
  # sibling users can traverse and enumerate session IDs even though the
  # SESSION_ID dir itself is 700. chmod is idempotent and cheap; always
  # applying matches the per-session-dir treatment below.
  local _qp_root="${STATE_ROOT%/state}"
  [[ -d "${_qp_root}" ]] && chmod 700 "${_qp_root}" 2>/dev/null || true
  [[ -d "${STATE_ROOT}" ]] && chmod 700 "${STATE_ROOT}" 2>/dev/null || true
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
_state_validated_lock_session=""
_state_validated_lock_owner_token=""

_ensure_valid_state() {
  if [[ "${_state_validated}" -eq 1 ]]; then
    # The publication fence may already have validated this exact generation
    # after acquiring the canonical mutex. Trust that proof only while the
    # same owner token is still live; an inherited/stale process cache never
    # gets this shortcut.
    if [[ "${_state_validated_lock_session:-}" \
          == "${_OMC_STATE_LOCK_HELD_SESSION:-}" \
        && -n "${_state_validated_lock_session:-}" \
        && "${_state_validated_lock_owner_token:-}" \
          == "${_OMC_STATE_LOCK_HELD_OWNER_TOKEN:-}" \
        && -n "${_state_validated_lock_owner_token:-}" ]] \
        && declare -F _omc_state_lock_reentry_valid >/dev/null 2>&1 \
        && _omc_state_lock_reentry_valid; then
      return
    fi
    # The cache covers this process's own jq-mediated writes, not an external
    # byte rewrite that happened after the first validation. Recheck the full
    # object envelope before trusting the cache: a NUL-free syntax error or
    # non-object rewrite is just as corrupt as a raw-NUL rewrite.
    local cached_state_file
    cached_state_file="$(session_file "${STATE_JSON}")"
    if _omc_regular_file_has_no_raw_nul "${cached_state_file}" \
        && jq -e 'type == "object"' \
          "${cached_state_file}" >/dev/null 2>&1; then
      return
    fi
    _state_validated=0
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
  # hold, false-y otherwise. Decoded NUL is also structural corruption for a
  # Bash-backed state API: command substitution cannot represent it and would
  # silently join the surrounding bytes into different authority. Catches the
  # full malformation matrix exercised by tests/test-state-io.sh plus the
  # JSON-to-shell normalization boundary in tests/test-state-io.sh.
  local needs_recovery=0
  if [[ ! -s "${state_file}" ]]; then
    needs_recovery=1
  elif ! _omc_regular_file_has_no_raw_nul "${state_file}"; then
    needs_recovery=1
  elif ! jq -e '
      type == "object"
      and all(.. | strings; index("\u0000") == null)
    ' "${state_file}" >/dev/null 2>&1; then
    needs_recovery=1
  fi

  if [[ "${needs_recovery}" -eq 1 ]]; then
    local archive recovered_ts recovery_count_file recovery_count
    local recovery_count_valid=1
    recovered_ts="$(date +%s)"
    archive="$(session_file "${STATE_JSON}.corrupt.${recovered_ts}")"
    mv "${state_file}" "${archive}" 2>/dev/null || true

    # Per-session recovery counter. Lives in a sidecar file so it
    # survives the JSON-state archive itself. The Bug B post-mortem
    # surfaced "attractive resilience": the recovery directive
    # looked like the harness working when in fact it was the
    # harness mis-reading itself, firing every multi-line prompt
    # for five releases. The user — not the harness — was the
    # oracle that noticed the per-turn frequency. The counter
    # converts that signal into a deterministic alarm: when
    # recovery fires twice within a session, the user-facing
    # directive escalates from "the harness recovered, audit recent
    # commits" to "recovery is firing repeatedly; THIS IS ALMOST
    # ALWAYS A BUG IN THE RECOVERY ITSELF — investigate before
    # trusting any further session output". The escalation is the
    # point: a recovery that fires repeatedly cannot be silently
    # masked any more.
    recovery_count_file="$(session_file ".recovery_count")"
    if [[ -e "${recovery_count_file}" || -L "${recovery_count_file}" ]]; then
      recovery_count="$(_omc_read_canonical_metadata_line \
        "${recovery_count_file}" 32 2>/dev/null || true)"
      if ! _omc_canonical_uint_in_range \
          "${recovery_count}" 0 999999999999999; then
        # Preserve malformed evidence rather than laundering it into a fresh
        # low count. Conservatively surface the repeat-recovery alarm until an
        # operator repairs/removes the sidecar.
        recovery_count=2
        recovery_count_valid=0
      fi
    else
      recovery_count=0
    fi
    if [[ "${recovery_count_valid}" -eq 1 ]]; then
      recovery_count=$((recovery_count + 1))
      printf '%s\n' "${recovery_count}" \
        >"${recovery_count_file}" 2>/dev/null || true
    fi

    # Persist a sticky recovery marker on the rebuilt state. Without it,
    # subsequent `read_state task_intent` (etc.) returns empty for the
    # rest of the session, the stop-guard's intent gate evaluates to
    # false, and ALL quality gates silently disarm — the user keeps
    # shipping work with no review/verify/excellence enforcement and
    # nothing in the user-facing transcript signals the gates went away.
    # Both `recovered_from_corrupt_ts` and `recovered_from_corrupt_archive`
    # are read by prompt-intent-router on the next UserPromptSubmit so
    # a systemMessage warning surfaces to the user; the recovery
    # counter is read separately from the sidecar so it survives even
    # the rebuilt state's archive.
    printf '{"recovered_from_corrupt_ts":%s,"recovered_from_corrupt_archive":"%s"}\n' \
      "${recovered_ts}" "${archive//\"/\\\"}" >"${state_file}"
    log_anomaly "common" "corrupt state detected and archived (count=${recovery_count}): ${archive}"
    if [[ "${recovery_count_valid}" -ne 1 ]]; then
      log_anomaly "common" \
        "malformed recovery counter preserved; repeat-recovery alarm forced"
    fi
  fi

  _state_validated=1
  if declare -F _omc_state_lock_reentry_valid >/dev/null 2>&1 \
      && _omc_state_lock_reentry_valid; then
    _state_validated_lock_session="${_OMC_STATE_LOCK_HELD_SESSION:-}"
    _state_validated_lock_owner_token="${_OMC_STATE_LOCK_HELD_OWNER_TOKEN:-}"
  else
    _state_validated_lock_session=""
    _state_validated_lock_owner_token=""
  fi
}

_write_state_unlocked() {
  local key="$1"
  local value="$2"
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  # Guard mktemp (mirror _append_limited_state_locked at the locked-append path):
  # on failure (e.g. transient FS pressure) the unguarded form left temp_file
  # empty and the subsequent `jq >""` produced an ambiguous-redirect error that
  # still returned 1 but via a noisier path. Returning early is the clean
  # equivalent. (oracle finding — the write-failure source behind goal.sh's
  # silent pause/resume state-drop, now loud at both ends.)
  # v1.47 (sre-lens R-3): record the write-failure SOURCE, not just lock
  # contention — an FS-full/transient-jq failure was doubly invisible (it
  # aborts the calling hook under set -e AND left no trace; the only
  # anomaly fired on lock exhaustion). Defensive command -v: state-io is
  # sourced by common.sh before log_anomaly's definition point, but these
  # bodies only RUN at call time when the full source has completed.
  if ! temp_file="$(mktemp "${state_file}.XXXXXX")"; then
    command -v log_anomaly >/dev/null 2>&1 \
      && log_anomaly "write_state" "mktemp failed for key ${key} (FS pressure?)" 2>/dev/null || true
    return 1
  fi

  _ensure_valid_state

  if jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" >"${temp_file}"; then
    mv "${temp_file}" "${state_file}"
  else
    rm -f "${temp_file}"
    command -v log_anomaly >/dev/null 2>&1 \
      && log_anomaly "write_state" "jq write failed for key ${key} (corrupt state json?)" 2>/dev/null || true
    return 1
  fi
}

write_state() {
  # Public state writes lock by default. Older call sites wrapped
  # write_state in with_state_lock only where authors remembered the
  # read-modify-write race; the default must be safe because hooks fan
  # out concurrently. with_state_lock is re-entrant, so existing locked
  # callers run the unlocked body inline under the outer lock.
  if _omc_state_lock_reentry_valid \
      || [[ -z "${SESSION_ID:-}" ]]; then
    _write_state_unlocked "$@"
  else
    with_state_lock _write_state_unlocked "$@"
  fi
}

_write_state_batch_unlocked() {
  if [[ $(( $# % 2 )) -ne 0 ]]; then
    printf 'write_state_batch: odd number of arguments (%d)\n' "$#" >&2
    return 1
  fi
  if declare -F omc_enforcement_generation_matches_capture \
      >/dev/null 2>&1 \
      && ! omc_enforcement_generation_matches_capture; then
    return 1
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  # Guard mktemp (same fix as _write_state_unlocked at line 153): an unguarded
  # failure under FS pressure leaves temp_file empty → `jq >""` ambiguous
  # redirect. with_state_lock_batch (goal.sh set/clear/done, the router's
  # objective-cycle stamps) routes through here, so it needs the same guard.
  # v1.47 (sre-lens R-3): same write-failure observability as
  # _write_state_unlocked above.
  if ! temp_file="$(mktemp "${state_file}.XXXXXX")"; then
    command -v log_anomaly >/dev/null 2>&1 \
      && log_anomaly "write_state_batch" "mktemp failed (first key: ${1:-?}; FS pressure?)" 2>/dev/null || true
    return 1
  fi

  _ensure_valid_state

  local jq_filter="."
  local args=()
  local idx=0
  local _first_key="${1:-?}"

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
    command -v log_anomaly >/dev/null 2>&1 \
      && log_anomaly "write_state_batch" "jq write failed (first key: ${_first_key}; corrupt state json?)" 2>/dev/null || true
    return 1
  fi
}

write_state_batch() {
  # See write_state: batch writes are also lock-protected by default so
  # concurrent hooks cannot lose updates via parallel temp-file moves.
  if _omc_state_lock_reentry_valid \
      || [[ -z "${SESSION_ID:-}" ]]; then
    _write_state_batch_unlocked "$@"
  else
    with_state_lock _write_state_batch_unlocked "$@"
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
  local temp keep_lines
  [[ "${max_lines}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ ! -L "${target}" ]] || return 1
  [[ ! -e "${target}" || -f "${target}" ]] || return 1
  temp="$(mktemp "${target}.XXXXXX")" || return 1
  keep_lines=$((max_lines - 1))
  if [[ -s "${target}" && "${keep_lines}" -gt 0 ]] \
      && ! tail -n "${keep_lines}" "${target}" >"${temp}" 2>/dev/null; then
    rm -f -- "${temp}"
    return 1
  fi
  if ! printf '%s\n' "${value}" >>"${temp}"; then
    rm -f -- "${temp}"
    return 1
  fi
  if ! mv -f -- "${temp}" "${target}"; then
    rm -f -- "${temp}"
    return 1
  fi
}

# Replace one byte-exact JSONL row while preserving every unrelated row. The
# caller owns the session lock; this helper makes the file publication itself
# fail-closed even when a surrounding `... || true` disables Bash errexit.
# The optional fault selector is test-only (`mktemp`, `write`, or `publish`).
rewrite_jsonl_line_atomic() {
  local target="${1:-}" selected="${2:-}" replacement="${3:-}"
  local fault="${4:-}" temp="" snapshot="" roundtrip=""
  [[ -n "${target}" && -n "${selected}" ]] || return 1
  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  [[ "${selected}" != *$'\n'* && "${selected}" != *$'\r'* \
      && "${replacement}" != *$'\n'* && "${replacement}" != *$'\r'* ]] || return 1
  jq -e 'type == "object"' <<<"${selected}" >/dev/null 2>&1 || return 1
  if [[ -n "${replacement}" ]]; then
    jq -e 'type == "object"' <<<"${replacement}" >/dev/null 2>&1 || return 1
  fi
  [[ "${fault}" != "mktemp" ]] || return 1
  snapshot="$(mktemp "${target}.rewrite-source.XXXXXX")" || return 1
  roundtrip="$(mktemp "${target}.rewrite-roundtrip.XXXXXX")" || {
    rm -f -- "${snapshot}"
    return 1
  }
  temp="$(mktemp "${target}.rewrite.XXXXXX")" || {
    rm -f -- "${snapshot}" "${roundtrip}"
    return 1
  }
  if ! cp "${target}" "${snapshot}" \
      || [[ ! -f "${target}" || -L "${target}" ]] \
      || ! cmp -s "${target}" "${snapshot}" \
      || ! jq -Rrjs '
        if index("\u0000") == null then .
        else error("raw NUL in JSONL source") end
      ' "${snapshot}" >"${roundtrip}" \
      || ! cmp -s "${snapshot}" "${roundtrip}"; then
    rm -f -- "${temp}" "${snapshot}" "${roundtrip}"
    return 1
  fi
  # Transform the frozen raw string inside jq rather than feeding it through
  # Bash read. split/join preserves blank rows and the source's final-newline
  # state; the round-trip comparison above rejects any byte sequence jq would
  # normalize. A second source comparison immediately before publication
  # prevents an interleaving writer from being overwritten by this snapshot.
  if [[ "${fault}" == "write" ]] \
      || ! jq -Rrjs --arg selected "${selected}" \
        --arg replacement "${replacement}" '
          reduce (split("\n")[]) as $line
            ({matches:0,lines:[]};
              if $line == $selected then
                .matches += 1
                | if $replacement == "" then .
                  else .lines += [$replacement] end
              else .lines += [$line] end)
          | if .matches == 1 then (.lines | join("\n"))
            else error("selected row is missing or duplicated") end
        ' "${snapshot}" >"${temp}" \
      || [[ "${fault}" == "publish" ]] \
      || [[ ! -f "${target}" || -L "${target}" ]] \
      || ! cmp -s "${target}" "${snapshot}"; then
    rm -f -- "${temp}" "${snapshot}" "${roundtrip}"
    return 1
  fi
  if ! mv -f -- "${temp}" "${target}"; then
    rm -f -- "${temp}" "${snapshot}" "${roundtrip}"
    return 1
  fi
  rm -f -- "${snapshot}" "${roundtrip}"
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
  # serializes the cycle; the atomic-owner lock is short-lived and the
  # contention window is bounded by the per-session gate-event cap
  # (default 500). When SESSION_ID is unset (test rigs, /omc-config
  # without a session), fall through to the unlocked path so callers
  # outside an active session continue to work.
  if [[ -n "${SESSION_ID:-}" ]]; then
    # v1.31.2 quality-reviewer F-3: do NOT fall through to the unlocked
    # path on LOCK-ACQUISITION FAILURE. Pre-Wave-1.31.2 behavior used
    # `with_state_lock ... || _append_limited_state_locked ...` which
    # silently retried unlocked when the lock cap fired (currently 100
    # attempts ~ 5s) — re-introducing the row-tearing race the lock
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

# Emit an exact, stable snapshot of one legacy text sidecar only after jq has
# rejected decoded NUL before any bytes reach Bash.  The temporary snapshot is
# compared with the source, so invalid UTF replacement or a concurrent source
# rewrite cannot turn one persisted value into another shell-visible value.
_omc_emit_nul_free_legacy_state_snapshot() {
  local path="${1:-}" snapshot="" byte_count="" rc=1
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  byte_count="$(LC_ALL=C wc -c <"${path}" 2>/dev/null)" || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]+$ \
      && "${byte_count}" -le 1048576 ]] || return 1
  snapshot="$(mktemp "${path}.read.XXXXXX")" || return 1
  if jq -Rrjs '
      if index("\u0000") == null then .
      else error("NUL-bearing legacy state") end
    ' "${path}" >"${snapshot}" 2>/dev/null \
      && cmp -s "${snapshot}" "${path}" 2>/dev/null \
      && cat "${snapshot}"; then
    rc=0
  fi
  rm -f "${snapshot}" 2>/dev/null || rc=1
  return "${rc}"
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
    if ! _omc_regular_file_has_no_raw_nul "${state_file}"; then
      result="__OMC_STATE_INVALID__"
    else
      result="$(jq -r --arg k "${key}" '
      def nul_free:
        all(.. | strings; index("\u0000") == null);
      if type != "object" then
        "__OMC_STATE_INVALID__"
      elif has($k) then
        (.[$k] // "") as $value
        | if ($value | nul_free) then $value
          else "__OMC_STATE_VALUE_INVALID__" end
      else
        "__OMC_KEY_ABSENT__"
      end
      ' "${state_file}" 2>/dev/null || printf '__OMC_STATE_INVALID__')"
    fi

    if [[ "${result}" == "__OMC_STATE_INVALID__" \
        || "${result}" == "__OMC_STATE_VALUE_INVALID__" ]]; then
      # Never revive a legacy sidecar or expose normalized authority when the
      # JSON value cannot round-trip through Bash. A later locked write will
      # run _ensure_valid_state and archive the corrupt object visibly.
      _state_validated=0
      command -v log_anomaly >/dev/null 2>&1 \
        && log_anomaly "read_state" \
          "invalid NUL-bearing or non-object state value rejected (${key})" \
          2>/dev/null || true
      return
    fi

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
  _omc_emit_nul_free_legacy_state_snapshot \
    "$(session_file "${key}")" 2>/dev/null || true
}

# read_state_keys k1 k2 k3 ...
#
# Bulk-read N keys from session_state.json in a single jq invocation.
# Emits values delimited by ASCII RS (byte 0x1e), one record per
# requested key, in the order given. Missing keys emit an empty
# record (just the trailing RS) — preserving
# positional alignment so the caller can index records by argument
# position. **Callers must use `read -r -d $'\\x1e'`** to
# consume the records; line-delimited reads will mis-align whenever a
# stored value contains a newline.
#
# Usage (canonical):
#   while IFS= read -r -d $'\\x1e' _v; do
#     case "${_idx}" in 0) intent="${_v}" ;; 1) domain="${_v}" ;; esac
#     _idx=$((_idx + 1))
#   done < <(read_state_keys task_intent task_domain)
#
# ──────────────────────────────────────────────────────────────────
# Consumer contract (v1.34.x — derived from Bug B post-mortem)
# ──────────────────────────────────────────────────────────────────
#
# Producers (callers passing values through write_state / write_state_batch
# that will later be read via this function) and consumers (the
# `read -r -d $'\x1e'` loop after the call site) MUST agree on:
#
#   • DELIMITER: ASCII RS (byte 0x1e). Each record terminates in one
#     RS; the consumer reads with `read -d $'\x1e'`.
#
#   • POSITIONAL ALIGNMENT: argv length === record count, even when
#     keys are missing or values are empty. A 7-key call always emits
#     7 records. The case-statement reading those records MUST cover
#     0..(N-1); a missed branch silently drops a positional slot.
#
#   • VALUE SANITIZATION: ANY embedded RS byte (0x1e) inside a value
#     is STRIPPED before the value is joined into the record stream.
#     This is the contract that defends against the Bug B class for
#     adversarial inputs: a single embedded RS would otherwise split
#     the value into two records and shift every subsequent positional
#     slot by one — re-introducing the consequence-by-position failure
#     mode that v1.34.0's RS-delimited switchover was meant to close.
#     Plain `read_state` does NOT strip RS — single-value reads have
#     no delimiter to defend. If a caller needs byte-exact round-trip
#     on values that may contain embedded control bytes, use
#     `read_state` and accept the per-key jq fork cost.
#     The strip is lossy by design: ASCII RS is a C0 control byte
#     never present in legitimate textual content (multi-line prompts,
#     code, JSON, Markdown). Real workloads never trip the strip.
#
#   • EMPTY VALUES: `write_state(key, "")` and "key never written"
#     are byte-identical via this function (both emit a bare RS). Use
#     `read_state` if the caller needs to distinguish them.
#
#   • CHARACTER SET: a requested value containing decoded NUL (0x00) emits an
#     empty record. It is rejected while still JSON, before jq/Bash can erase
#     the byte and join its neighbors into false authority. Other control bytes
#     (TAB, BEL, BS, ESC, multi-byte UTF-8) pass through intact except RS,
#     which is stripped as the framing delimiter above.
#
#   • REGRESSION NETS:
#       - tests/test-state-io.sh:T20 (positional-alignment under all
#         12 adversarial value shapes from tests/lib/value-shapes.sh)
#       - the historical state-fuzz matrix (multi-line value Bug B
#         regression, the original failing case)
#
# v1.34.0 — switched from `\n`-delimited to RS-delimited (byte 0x1e)
# fix the positional-misalignment defect that fired the false STATE
# RECOVERY directive every time a stored value (e.g. multi-line
# `current_objective`, `last_assistant_message`, or task-notification
# bodies) contained a newline. The newline-delimited contract was
# introduced in v1.27.0 (F-018/F-019) and became user-visible in
# v1.29.0 when keys 5-6 became the `recovered_from_corrupt_*`
# markers — overflow lines from key 0 silently populated keys 5-6,
# tripping the recovery directive on every multi-line prompt.
# NUL was rejected as the separator because `jq -j` silently strips
# NUL bytes from output; RS is the next-cleanest separator that jq
# preserves and is essentially never present in textual content.
# v1.34.x (Bug B post-mortem hardening) — the
# fixture-realism rule (CONTRIBUTING.md "Fixture realism rule") added
# a 12-shape adversarial fixture set; class-3 (embedded RS) revealed
# that the v1.34.0 fix relied on probabilistic absence of RS in
# values rather than a deterministic invariant. The gsub strip in the
# jq filter below converts "essentially never present" into
# "deterministically not present at the consumer", honoring the
# contract above.
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
    # Emit empty RS-delimited records for each requested key — preserves
    # positional alignment in the caller's read loop.
    local _i
    for ((_i = 0; _i < $#; _i++)); do
      printf '\036'
    done
    return 0
  fi
  if ! _omc_regular_file_has_no_raw_nul "${state_file}"; then
    local _i
    for ((_i = 0; _i < $#; _i++)); do
      printf '\036'
    done
    return 0
  fi
  # Note on argument order: jq's `--args` flag consumes ALL trailing
  # positional arguments AFTER the filter as $ARGS.positional. If we
  # passed the JSON file as a positional too, jq would treat it as a
  # key name and read JSON from stdin (which would be empty). Pipe the
  # file in via stdin redirect so the filename never lands on argv.
  #
  # `jq -j` joins outputs with no separator (no implicit newline). We
  # append ASCII RS (byte 0x1e via the jq escape \\u001e) to each
  # value so the caller can use `read -d $'\\x1e'` for safe delimited
  # consumption — newlines inside values pass through unchanged.
  # NUL cannot be the delimiter because Bash variables cannot represent it.
  #
  # The `gsub("\u001e"; "")` BEFORE the trailing-RS join enforces
  # the value-sanitization clause of the Consumer contract above —
  # any embedded RS in a stored value is stripped so it cannot
  # collide with the delimiter and shift positional alignment. Without
  # it, an adversarial value at position 0 carrying a single 0x1e byte
  # splits into two records, overflowing into position 1 and cascading
  # the same Bug B failure mode the v1.34.0 RS switchover was supposed
  # to close. The strip is lossy by design — RS is a C0 control byte
  # never present in legitimate textual content. Caught by
  # tests/test-state-io.sh:T20 and tests/lib/value-shapes.sh class 3
  # once the fixture-realism rule converted the implicit "essentially
  # never" assumption into a deterministic test invariant.
  jq -j --args '
    def nul_free:
      all(.. | strings; index("\u0000") == null);
    if type != "object" then error("invalid state root") else . end
    | $ARGS.positional[] as $k
    | (.[$k] // "") as $value
    | (if ($value | nul_free) then
         ($value | tostring | gsub("\u001e"; ""))
       else "" end) + "\u001e"
  ' "$@" < "${state_file}" 2>/dev/null \
    || {
      # On jq failure (corrupt state, etc), emit empty RS-records so
      # the caller's read loop stays positionally aligned.
      local _i
      for ((_i = 0; _i < $#; _i++)); do
        printf '\036'
      done
    }
}

# --- Portable state lock (atomic owner + mkdir compatibility) ---
#
# Wraps a function call with a mutex held against the session's state
# directory. A populated owner sentinel is hard-linked into place before the
# compatibility lock directory is created, so ownership appears atomically on
# both macOS and Linux without flock. New owner records bind the PID to a
# portable process-birth identity, so PID reuse cannot make a dead owner look
# live. Legacy PID-only records remain compatible; pidless pre-sentinel locks
# wait for the stale timeout.
#
# Usage: with_state_lock my_function arg1 arg2 ...
#
# Returns the wrapped function's exit status, or 1 if the lock cannot
# be acquired within OMC_STATE_LOCK_MAX_ATTEMPTS polls (default 100).

OMC_STATE_LOCK_STALE_SECS="${OMC_STATE_LOCK_STALE_SECS:-5}"
# v1.31.0 Wave 2 (sre-lens F-5) tightened the original 10-second cap.
# Hardened state validation now makes the 3-second setting lossy under a
# legitimate 20-writer fan-out, so the default aligns with the 5-second stale
# recovery window. Pathological contention still reports and skips instead of
# waiting the former 10 seconds.
OMC_STATE_LOCK_MAX_ATTEMPTS="${OMC_STATE_LOCK_MAX_ATTEMPTS:-${OMC_LOCK_CAP:-100}}"
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

# Print a stable birth identity for one live process. Linux combines the
# kernel boot ID with /proc starttime; BSD/macOS use ps(1)'s locale-pinned
# process start timestamp. Observation failure is deliberately non-fatal:
# callers then preserve legacy PID-only liveness rather than risk reaping a
# legitimate lock. The explicit TSV seam makes PID-reuse regressions
# deterministic without process-table interposition.
_omc_process_birth_identity() {
  local pid="${1:-}" seam_file="${OMC_TEST_PROCESS_BIRTH_IDENTITY_FILE:-}"
  local seam_pid="" seam_identity="" seam_extra=""
  local proc_stat="" proc_rest="" boot_id="" starttime=""
  local ps_bin="" ps_start="" ps_token=""
  local proc_fields=()
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1

  if [[ -n "${seam_file}" ]]; then
    [[ -f "${seam_file}" && ! -L "${seam_file}" ]] || return 1
    while IFS=$'\t' read -r seam_pid seam_identity seam_extra; do
      [[ "${seam_pid}" == "${pid}" ]] || continue
      [[ -z "${seam_extra}" ]] || return 1
      [[ "${seam_identity}" != "unavailable" ]] || return 1
      [[ "${seam_identity}" =~ ^[A-Za-z0-9._-]{1,160}$ ]] || return 1
      printf '%s' "${seam_identity}"
      return 0
    done <"${seam_file}"
    return 1
  fi

  if [[ -r "/proc/${pid}/stat" ]]; then
    IFS= read -r proc_stat <"/proc/${pid}/stat" 2>/dev/null \
      || proc_stat=""
    if [[ "${proc_stat}" == *") "* ]]; then
      proc_rest="${proc_stat##*) }"
      read -r -a proc_fields <<<"${proc_rest}"
      starttime="${proc_fields[19]:-}"
      if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        IFS= read -r boot_id </proc/sys/kernel/random/boot_id \
          || boot_id=""
      fi
      boot_id="${boot_id//-/}"
      if [[ "${starttime}" =~ ^[0-9]+$ \
          && "${boot_id}" =~ ^[A-Fa-f0-9]{16,64}$ ]]; then
        printf 'linux.%s.%s' "${boot_id}" "${starttime}"
        return 0
      fi
    fi
  fi

  if [[ -x /bin/ps ]]; then
    ps_bin=/bin/ps
  elif [[ -x /usr/bin/ps ]]; then
    ps_bin=/usr/bin/ps
  else
    return 1
  fi
  ps_start="$(LC_ALL=C "${ps_bin}" -o lstart= -p "${pid}" \
    2>/dev/null || true)"
  ps_start="${ps_start#"${ps_start%%[![:space:]]*}"}"
  ps_start="${ps_start%"${ps_start##*[![:space:]]}"}"
  [[ -n "${ps_start}" ]] || return 1
  ps_token="$(printf '%s' "${ps_start}" \
    | LC_ALL=C tr -cs '[:alnum:]._-' '_' )"
  [[ "${ps_token}" =~ ^[A-Za-z0-9._-]{1,150}$ ]] || return 1
  printf 'bsd.%s' "${ps_token}"
}

_omc_owner_record_birth_identity() {
  local record="${1:-}" record_pid="" record_claim="" record_nonce=""
  local record_birth="" record_extra=""
  IFS=: read -r record_pid record_claim record_nonce record_birth record_extra \
    <<<"${record}"
  [[ -z "${record_extra}" \
      && "${record_birth}" != "legacy" \
      && "${record_birth}" =~ ^[A-Za-z0-9._-]{1,160}$ ]] || return 1
  printf '%s' "${record_birth}"
}

# Return success only while the recorded owner is still live. A mismatched
# observable birth identity is a stale, reused PID. Missing legacy identity or
# unavailable current observation fails safe as live.
_omc_lock_owner_is_live() {
  local pid="${1:-}" record="${2:-}" recorded_birth="" current_birth=""
  kill -0 "${pid}" 2>/dev/null || return 1
  recorded_birth="$(_omc_owner_record_birth_identity "${record}" \
    2>/dev/null || true)"
  [[ -n "${recorded_birth}" ]] || return 0
  current_birth="$(_omc_process_birth_identity "${pid}" \
    2>/dev/null || true)"
  [[ -n "${current_birth}" ]] || return 0
  [[ "${current_birth}" == "${recorded_birth}" ]]
}

# Resume authorization is stricter than ordinary stale-lock recovery. Lock
# reaping must preserve a possibly-live owner when a rolling-upgrade token has
# no birth coordinate or the platform cannot currently observe one. Neither
# ambiguity is acceptable as a process-local capability: require a four-field
# owner record, a live process, and an independently observed exact birth
# match. Keep this separate from `_omc_lock_owner_is_live` so its fail-safe
# compatibility semantics remain unchanged.
_omc_lock_owner_has_exact_birth_identity() {
  local pid="${1:-}" record="${2:-}" record_pid=""
  local recorded_birth="" current_birth=""
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  record_pid="${record%%:*}"
  [[ "${record_pid}" == "${pid}" ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  recorded_birth="$(_omc_owner_record_birth_identity "${record}" \
    2>/dev/null)" || return 1
  current_birth="$(_omc_process_birth_identity "${pid}" \
    2>/dev/null)" || return 1
  [[ "${current_birth}" == "${recorded_birth}" ]]
}

# Import one bounded metadata record only when the complete file is exactly one
# NUL/CR-free line terminated by one newline.  jq performs the byte-hostile
# checks before any value reaches Bash; the final reconstruction comparison
# also rejects invalid-UTF replacement, extra blank lines, and concurrent
# replacement between validation and import.  Lock owner, claim, reap, and
# compatibility-PID files are authority records, so ambiguity must preserve
# the lock rather than normalize into a matching token.
_omc_read_canonical_metadata_line() {
  local path="${1:-}" max_bytes="${2:-512}" record="" byte_count=""
  [[ -f "${path}" && ! -L "${path}" \
      && "${max_bytes}" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  byte_count="$(LC_ALL=C wc -c <"${path}" 2>/dev/null)" || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]+$ \
      && "${byte_count}" -ge 2 \
      && "${byte_count}" -le "${max_bytes}" ]] || return 1
  record="$(jq -Rrse '
    if (type == "string"
        and endswith("\n")
        and (.[0:length - 1]
          | index("\n") == null
          and index("\r") == null
          and index("\u0000") == null))
    then .[0:length - 1]
    else error("non-canonical metadata record")
    end
  ' "${path}" 2>/dev/null)" || return 1
  [[ -n "${record}" ]] || return 1
  printf '%s\n' "${record}" | cmp -s - "${path}" 2>/dev/null || return 1
  printf '%s' "${record}"
}

_omc_read_canonical_pid_file() {
  local path="${1:-}" pid=""
  pid="$(_omc_read_canonical_metadata_line "${path}" 32 \
    2>/dev/null)" || return 1
  [[ "${pid}" =~ ^[1-9][0-9]{0,19}$ ]] || return 1
  printf '%s' "${pid}"
}

# Best-effort garbage collection for crash residue that is no longer part of
# an ownership/reaper chain. Every contender needs a unique claim before it
# can publish the canonical owner, so SIGKILL while waiting can strand that
# file. A reaper killed after canonical unlink can likewise strand its reap
# hard-link. Reclaim only dead, structurally self-identifying artifacts that
# are neither the current canonical token nor referenced by a live recovery
# edge; ambiguity always fails closed.
_cleanup_orphan_lock_claims() {
  local ownerfile="$1"
  local lock_parent canonical_record candidate candidate_name candidate_record
  local candidate_pid candidate_record_claim referenced reap reaper_claim_name
  local reaper_claim reaper_record reaper_pid reaper_record_claim current_record
  local prepare prepare_mtime prepare_mtime_recheck now_epoch
  local scanned=0
  lock_parent="$(dirname "${ownerfile}")"
  canonical_record=""
  if [[ -e "${ownerfile}" || -L "${ownerfile}" ]]; then
    canonical_record="$(_omc_read_canonical_metadata_line \
      "${ownerfile}" 512 2>/dev/null)" || return 0
  fi

  # Preparation files are deliberately outside the ownership namespace: no
  # waiter ever trusts them, and the creator must hard-link a complete token
  # into `.claim.*` before it can compete. A SIGKILL between mktemp and that
  # publication can therefore leave only inert residue. Reap it after the
  # ordinary stale window; a delayed live creator will simply recreate its
  # unique path when redirecting the token and remains unable to publish
  # partial authority.
  now_epoch="$(date +%s 2>/dev/null || true)"
  if [[ "${now_epoch}" =~ ^[0-9]+$ ]]; then
    scanned=0
    for prepare in "${ownerfile}.prepare."*; do
      [[ -f "${prepare}" && ! -L "${prepare}" ]] || continue
      scanned=$((scanned + 1))
      [[ "${scanned}" -le 256 ]] || break
      prepare_mtime="$(_lock_mtime "${prepare}")"
      [[ "${prepare_mtime}" =~ ^[0-9]+$ \
          && "${prepare_mtime}" -gt 0 \
          && $((now_epoch - prepare_mtime)) \
            -gt "${OMC_STATE_LOCK_STALE_SECS}" ]] || continue
      prepare_mtime_recheck="$(_lock_mtime "${prepare}")"
      [[ "${prepare_mtime_recheck}" == "${prepare_mtime}" ]] || continue
      rm -f "${prepare}" 2>/dev/null || true
    done
  fi

  # Reap artifacts first. Once their exact owner token is no longer
  # canonical, only a live elected reaper can still be using them.
  for reap in "${ownerfile}.claim."*.reap.*; do
    [[ -f "${reap}" && ! -L "${reap}" ]] || continue
    scanned=$((scanned + 1))
    [[ "${scanned}" -le 256 ]] || break
    candidate_record=""
    candidate_record="$(_omc_read_canonical_metadata_line \
      "${reap}" 512 2>/dev/null)" || continue
    [[ -n "${candidate_record}" && "${candidate_record}" != "${canonical_record}" ]] \
      || continue
    reaper_claim_name="${reap##*.reap.}"
    [[ "${reaper_claim_name}" == "${ownerfile##*/}.claim."* \
        && "${reaper_claim_name}" != */* ]] || continue
    reaper_claim="${lock_parent}/${reaper_claim_name}"
    reaper_record=""
    if [[ -e "${reaper_claim}" || -L "${reaper_claim}" ]]; then
      reaper_record="$(_omc_read_canonical_metadata_line \
        "${reaper_claim}" 512 2>/dev/null)" || continue
    fi
    reaper_pid="${reaper_record%%:*}"
    reaper_record_claim="${reaper_record#*:}"
    reaper_record_claim="${reaper_record_claim%%:*}"
    if [[ -n "${reaper_record}" ]]; then
      [[ "${reaper_pid}" =~ ^[1-9][0-9]*$ \
          && "${reaper_record_claim}" == "${reaper_claim_name}" ]] || continue
      _omc_lock_owner_is_live "${reaper_pid}" "${reaper_record}" \
        && continue
    fi
    current_record=""
    if [[ -e "${ownerfile}" || -L "${ownerfile}" ]]; then
      current_record="$(_omc_read_canonical_metadata_line \
        "${ownerfile}" 512 2>/dev/null)" || return 0
    fi
    [[ "${current_record}" != "${candidate_record}" ]] || continue
    current_record=""
    current_record="$(_omc_read_canonical_metadata_line \
      "${reap}" 512 2>/dev/null)" || return 0
    [[ "${current_record}" == "${candidate_record}" ]] || continue
    rm -f "${reap}" 2>/dev/null || true
  done

  # Direct claims are removable only when their recorded process is dead and
  # no canonical owner or elected-reaper artifact still names them.
  scanned=0
  for candidate in "${ownerfile}.claim."*; do
    [[ -f "${candidate}" && ! -L "${candidate}" ]] || continue
    candidate_name="${candidate##*/}"
    [[ "${candidate_name}" != *.reap.* ]] || continue
    scanned=$((scanned + 1))
    [[ "${scanned}" -le 256 ]] || break
    candidate_record=""
    candidate_record="$(_omc_read_canonical_metadata_line \
      "${candidate}" 512 2>/dev/null)" || continue
    candidate_pid="${candidate_record%%:*}"
    candidate_record_claim="${candidate_record#*:}"
    candidate_record_claim="${candidate_record_claim%%:*}"
    [[ "${candidate_pid}" =~ ^[1-9][0-9]*$ \
        && "${candidate_record_claim}" == "${candidate_name}" ]] || continue
    _omc_lock_owner_is_live "${candidate_pid}" "${candidate_record}" \
      && continue
    [[ "${candidate_record}" != "${canonical_record}" ]] || continue
    referenced=0
    for reap in "${ownerfile}.claim."*.reap."${candidate_name}"; do
      if [[ -e "${reap}" || -L "${reap}" ]]; then
        referenced=1
        break
      fi
    done
    [[ "${referenced}" -eq 0 ]] || continue
    current_record=""
    if [[ -e "${ownerfile}" || -L "${ownerfile}" ]]; then
      current_record="$(_omc_read_canonical_metadata_line \
        "${ownerfile}" 512 2>/dev/null)" || return 0
    fi
    [[ "${current_record}" != "${candidate_record}" ]] || continue
    current_record=""
    current_record="$(_omc_read_canonical_metadata_line \
      "${candidate}" 512 2>/dev/null)" || return 0
    [[ "${current_record}" == "${candidate_record}" ]] || continue
    rm -f "${candidate}" 2>/dev/null || true
  done
}

# Release one atomically-owned lock by its exact canonical token. This is the
# shared release half of `_with_lockdir`, and is also used when a lock owner
# `exec`s a fresh Bash process while preserving its PID/birth identity. The
# canonical owner disappears before its unique election claim; a crash at any
# earlier boundary therefore remains recoverable by the normal exact reaper.
omc_release_lockdir_owner_exact() {
  local lockdir="${1:-}" owner_token="${2:-}" tag="${3:-lock-release}"
  local ownerfile="${lockdir}.owner" pidfile="${lockdir}/holder.pid"
  local lock_parent owner_pid claim_name nonce birth extra claimfile
  local cleanup_ok=1 current_owner="" claim_record=""
  local test_fail_lockdir="${OMC_TEST_LOCK_RELEASE_FAIL_LOCKDIR:-}"
  local test_fail_stage="${OMC_TEST_LOCK_RELEASE_FAIL_STAGE:-}"
  [[ "${lockdir}" == /* ]] || return 1
  if [[ -n "${test_fail_lockdir}" || -n "${test_fail_stage}" ]]; then
    [[ "${test_fail_lockdir}" == /* \
        && "${test_fail_stage}" == "after-lockdir" ]] || return 1
  fi
  lock_parent="$(dirname "${lockdir}")"
  IFS=: read -r owner_pid claim_name nonce birth extra <<<"${owner_token}"
  [[ "${owner_pid}" =~ ^[1-9][0-9]*$ \
      && "${claim_name}" == "${ownerfile##*/}.claim."* \
      && "${claim_name}" != */* \
      && "${nonce}" =~ ^[0-9]+$ \
      && -z "${extra}" ]] || return 1
  [[ -z "${birth}" \
      || "${birth}" =~ ^[A-Za-z0-9._-]{1,160}$ ]] || return 1
  claimfile="${lock_parent}/${claim_name}"
  [[ -f "${ownerfile}" && ! -L "${ownerfile}" \
      && -f "${claimfile}" && ! -L "${claimfile}" ]] || return 1
  current_owner="$(_omc_read_canonical_metadata_line \
    "${ownerfile}" 512 2>/dev/null || true)"
  claim_record="$(_omc_read_canonical_metadata_line \
    "${claimfile}" 512 2>/dev/null || true)"
  [[ "${current_owner}" == "${owner_token}" \
      && "${claim_record}" == "${owner_token}" ]] || return 1

  _cleanup_orphan_lock_claims "${ownerfile}"
  if [[ -e "${lockdir}" || -L "${lockdir}" ]]; then
    if [[ -d "${lockdir}" && ! -L "${lockdir}" ]]; then
      rm -f "${pidfile}" 2>/dev/null || cleanup_ok=0
      rmdir "${lockdir}" 2>/dev/null || cleanup_ok=0
    else
      cleanup_ok=0
    fi
  fi
  # Deterministic crash-boundary regression seam. At this point the
  # compatibility directory is gone but the canonical owner and its unique
  # hard-link claim still form a complete, reapable authority record.
  if [[ "${cleanup_ok}" -eq 1 \
      && "${test_fail_lockdir}" == "${lockdir}" \
      && "${test_fail_stage}" == "after-lockdir" ]]; then
    cleanup_ok=0
  fi
  if [[ "${cleanup_ok}" -eq 1 ]]; then
    current_owner="$(_omc_read_canonical_metadata_line \
      "${ownerfile}" 512 2>/dev/null || true)"
    [[ "${current_owner}" == "${owner_token}" ]] \
      && rm -f "${ownerfile}" 2>/dev/null || cleanup_ok=0
  fi
  if [[ "${cleanup_ok}" -eq 1 ]]; then
    claim_record="$(_omc_read_canonical_metadata_line \
      "${claimfile}" 512 2>/dev/null || true)"
    [[ "${claim_record}" == "${owner_token}" ]] \
      && rm -f "${claimfile}" 2>/dev/null || cleanup_ok=0
  fi
  if [[ "${cleanup_ok}" -ne 1 ]]; then
    log_anomaly "${tag}" "lock release cleanup failed" 2>/dev/null || true
    return 1
  fi
  return 0
}

# _with_lockdir <lockdir> <tag> <cmd> [args...]
#
# Run `<cmd> args...` while holding the atomic owner for <lockdir>.
# Centralizes the locking primitive used by every with_*_lock helper in
# the harness: with_state_lock, with_metrics_lock, with_defect_lock,
# with_resume_lock, with_skips_lock, with_cross_session_log_lock,
# with_scope_lock. Public helpers stay one-line wrappers preserving
# their names + signatures so call sites and tests are unchanged.
#
# Behavior:
#   - PID + process-birth stale recovery (v1.29.0 metis F-6 pattern,
#     generalized in v1.30.0). A unique, fully populated temp file is
#     hard-linked atomically to <lockdir>.owner; only that owner then creates
#     <lockdir>/holder.pid for compatibility and observability. Waiters trust
#     the sentinel first and never stale-recover a live owner merely because
#     the scheduler paused it between filesystem operations. Dead sentinel
#     owners and reused-PID records are reclaimed immediately. Existing
#     three-field records remain PID-only. A lock directory without a
#     sentinel is a pre-sentinel legacy/crash shape and retains mtime recovery.
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
  local ownerfile="${lockdir}.owner"
  local lock_parent
  lock_parent="$(dirname "${lockdir}")"
  mkdir -p "${lock_parent}" 2>/dev/null || true
  local owner_pid="" owner_birth="" claimfile="" claim_name="" owner_token=""
  local claim_stage="" claim_suffix=""
  local owner_record="" holder_pid="" legacy_pid=""
  local _lock_held_since="" _lock_now=""
  local observed_claim="" observed_claim_name="" reap_claim="" cleanup_ok=0
  local reap_record="" canonical_recheck=""
  local prior_reap="" prior_reap_record="" prior_reaper_claim_name=""
  local prior_reaper_claim="" prior_reaper_record="" prior_reaper_pid=""
  local prior_reaper_record_claim="" elected_reaper=0
  local test_deny_attempts="${OMC_TEST_STATE_LOCK_DENY_ATTEMPTS:-}"
  local test_attempt_file="${OMC_TEST_STATE_LOCK_ATTEMPT_FILE:-}"
  local test_claim_attempts=0 test_claim_denied=0
  local test_sentinel_lockdir="${OMC_TEST_LOCK_SENTINEL_PAUSE_LOCKDIR:-}"
  local test_sentinel_ready="${OMC_TEST_LOCK_SENTINEL_READY_FILE:-}"
  local test_sentinel_release="${OMC_TEST_LOCK_SENTINEL_RELEASE_FILE:-}"
  if [[ -n "${test_deny_attempts}" || -n "${test_attempt_file}" ]]; then
    # Deterministic lock-budget seam.  Trusted-PATH pinning intentionally
    # prevents tests from interposing `ln`; an explicit test-only counter keeps
    # the acquisition algorithm observable without weakening that boundary.
    [[ "${test_deny_attempts}" =~ ^(0|[1-9][0-9]{0,2})$ \
        && "${test_deny_attempts}" -le 100 \
        && -n "${test_attempt_file}" ]] || return 1
  fi
  if [[ -n "${test_sentinel_lockdir}" || -n "${test_sentinel_ready}" \
      || -n "${test_sentinel_release}" ]]; then
    [[ -n "${test_sentinel_lockdir}" \
        && -n "${test_sentinel_ready}" \
        && -n "${test_sentinel_release}" \
        && "${test_sentinel_lockdir}" == /* \
        && "${test_sentinel_ready}" == /* \
        && "${test_sentinel_release}" == /* ]] || return 1
  fi
  claim_stage="$(mktemp "${ownerfile}.prepare.XXXXXX")" || {
    log_anomaly "${tag}" "lock owner staging failed"
    return 1
  }
  claim_suffix="${claim_stage##*.prepare.}"
  [[ -n "${claim_suffix}" && "${claim_suffix}" != */* ]] || {
    rm -f "${claim_stage}" 2>/dev/null || true
    return 1
  }
  claim_name="${ownerfile##*/}.claim.${claim_suffix}"
  claimfile="${lock_parent}/${claim_name}"
  # Bash 3.2 keeps `$$` equal to the parent shell inside `( ... ) &`, and does
  # not expose BASHPID. Linux exposes the actual current process as field one
  # of /proc/self/stat, readable with a builtin (no fork per contender).
  # Top-level macOS hooks can use $$ directly. Only a macOS Bash-3 subshell
  # needs a direct child to write its PPID; avoid command substitution there,
  # since that would record a short-lived intermediary.
  if [[ -r /proc/self/stat ]] \
      && IFS=' ' read -r owner_pid _ </proc/self/stat \
      && [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    :
  elif [[ "${BASH_SUBSHELL:-0}" -eq 0 && "$$" =~ ^[1-9][0-9]*$ ]]; then
    owner_pid="$$"
  elif /bin/sh -c 'printf "%s\n" "$PPID" >"$1"' sh "${claim_stage}"; then
    owner_pid="$(_omc_read_canonical_pid_file \
      "${claim_stage}" 2>/dev/null || true)"
  else
    owner_pid=""
  fi
  if [[ ! "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "${claim_stage}" 2>/dev/null || true
    log_anomaly "${tag}" "lock owner PID capture failed"
    return 1
  fi
  owner_birth="$(_omc_process_birth_identity "${owner_pid}" \
    2>/dev/null || true)"
  owner_birth="${owner_birth:-legacy}"
  owner_token="${owner_pid}:${claim_name}:${RANDOM:-0}:${owner_birth}"
  # Publish only a fully populated claim. `mktemp` under the final claim
  # namespace exposed an empty/PID-only file that SIGKILL could strand before
  # the token rewrite; garbage collection could not safely distinguish that
  # partial file from a live initializer. Stage under a disjoint name, then
  # hard-link the complete regular generation into its final unique name.
  if ! printf '%s\n' "${owner_token}" >"${claim_stage}" \
      || ! chmod 600 "${claim_stage}" 2>/dev/null \
      || ! ln "${claim_stage}" "${claimfile}" 2>/dev/null \
      || ! rm -f "${claim_stage}" 2>/dev/null; then
    rm -f "${claimfile}" "${claim_stage}" 2>/dev/null || true
    log_anomaly "${tag}" "lock owner staging failed"
    return 1
  fi
  claim_stage=""

  local attempts=0 acquired=0
  while true; do
    test_claim_denied=0
    if [[ -n "${test_attempt_file}" ]]; then
      test_claim_attempts=$((test_claim_attempts + 1))
      if ! printf '%s\n' "${test_claim_attempts}" >"${test_attempt_file}"; then
        rm -f "${claimfile}" 2>/dev/null || true
        return 1
      fi
      if (( test_claim_attempts <= test_deny_attempts )); then
        test_claim_denied=1
      fi
    fi
    # `ln` publishes already-populated ownership atomically. A regular-file
    # destination makes this an O_EXCL-like claim on both BSD and GNU. The
    # content check also rejects the odd existing-directory `ln src dir`
    # behavior without mistaking the nested link for ownership.
    if [[ "${test_claim_denied}" -eq 0 ]] \
        && ln "${claimfile}" "${ownerfile}" 2>/dev/null; then
      owner_record="$(_omc_read_canonical_metadata_line \
        "${ownerfile}" 512 2>/dev/null || true)"
      if [[ "${owner_record}" == "${owner_token}" ]]; then
        if [[ "${test_sentinel_lockdir}" == "${lockdir}" ]]; then
          [[ ! -L "${test_sentinel_ready}" \
              && ( ! -e "${test_sentinel_ready}" \
                || -f "${test_sentinel_ready}" ) ]] || {
            rm -f "${ownerfile}" "${claimfile}" 2>/dev/null || true
            return 1
          }
          : >"${test_sentinel_ready}" || {
            rm -f "${ownerfile}" "${claimfile}" 2>/dev/null || true
            return 1
          }
          while [[ ! -e "${test_sentinel_release}" ]]; do
            sleep 0.01
          done
          owner_record="$(_omc_read_canonical_metadata_line \
            "${ownerfile}" 512 2>/dev/null || true)"
          if [[ "${owner_record}" != "${owner_token}" ]]; then
            rm -f "${claimfile}" 2>/dev/null || true
            return 1
          fi
        fi
        if mkdir "${lockdir}" 2>/dev/null; then
          printf '%s\n' "${owner_pid}" >"${pidfile}" 2>/dev/null || true
          acquired=1
          break
        fi
        # A pre-sentinel/older process owns the directory. Release only our
        # exact sentinel and fall through to legacy-holder inspection.
        owner_record="$(_omc_read_canonical_metadata_line \
          "${ownerfile}" 512 2>/dev/null || true)"
        if [[ "${owner_record}" == "${owner_token}" ]]; then
          rm -f "${ownerfile}" 2>/dev/null || true
        fi
      else
        rm -f "${ownerfile}/${claim_name}" 2>/dev/null || true
      fi
    fi
    attempts=$((attempts + 1))
    owner_record=""
    if [[ -f "${ownerfile}" && ! -L "${ownerfile}" ]]; then
      owner_record="$(_omc_read_canonical_metadata_line \
        "${ownerfile}" 512 2>/dev/null || true)"
      holder_pid="${owner_record%%:*}"
      observed_claim_name="${owner_record#*:}"
      observed_claim_name="${observed_claim_name%%:*}"
      if [[ "${holder_pid}" =~ ^[1-9][0-9]*$ \
          && "${observed_claim_name}" == "${ownerfile##*/}.claim."* \
          && "${observed_claim_name}" != */* \
          && "${owner_record}" == "${holder_pid}:${observed_claim_name}:"* ]]; then
        if ! _omc_lock_owner_is_live "${holder_pid}" "${owner_record}"; then
          # The owner's unique claim hard-link lives for the full critical
          # section. Atomically renaming it elects exactly one dead-owner
          # reaper. A stale observer that slept across normal release cannot
          # touch a successor: it can elect only the prior owner's uniquely
          # named claim, then must still match that prior canonical token
          # before removing any shared artifact.
          observed_claim="${lock_parent}/${observed_claim_name}"
          reap_claim="${observed_claim}.reap.${claim_name}"
          elected_reaper=0
          if mv "${observed_claim}" "${reap_claim}" 2>/dev/null; then
            elected_reaper=1
          else
            # If an elected reaper itself was killed, its retained unique
            # claim names its real PID. A later waiter atomically takes over
            # the reap artifact only after that PID is dead, so recovery never
            # becomes permanently wedged at the election boundary.
            for prior_reap in "${observed_claim}.reap."*; do
              [[ -f "${prior_reap}" && ! -L "${prior_reap}" ]] || continue
              prior_reap_record="$(_omc_read_canonical_metadata_line \
                "${prior_reap}" 512 2>/dev/null || true)"
              [[ "${prior_reap_record}" == "${owner_record}" ]] || continue
              prior_reaper_claim_name="${prior_reap#"${observed_claim}".reap.}"
              prior_reaper_claim="${lock_parent}/${prior_reaper_claim_name}"
              prior_reaper_record="$(_omc_read_canonical_metadata_line \
                "${prior_reaper_claim}" 512 2>/dev/null || true)"
              prior_reaper_pid="${prior_reaper_record%%:*}"
              prior_reaper_record_claim="${prior_reaper_record#*:}"
              prior_reaper_record_claim="${prior_reaper_record_claim%%:*}"
              if [[ "${prior_reaper_pid}" =~ ^[1-9][0-9]*$ \
                  && "${prior_reaper_claim_name}" == "${ownerfile##*/}.claim."* \
                  && "${prior_reaper_record_claim}" == "${prior_reaper_claim_name}" ]] \
                  && ! _omc_lock_owner_is_live \
                    "${prior_reaper_pid}" "${prior_reaper_record}" \
                  && mv "${prior_reap}" "${reap_claim}" 2>/dev/null; then
                rm -f "${prior_reaper_claim}" 2>/dev/null || true
                elected_reaper=1
                break
              fi
            done
          fi
          if [[ "${elected_reaper}" -eq 1 ]]; then
            cleanup_ok=1
            reap_record="$(_omc_read_canonical_metadata_line \
              "${reap_claim}" 512 2>/dev/null || true)"
            canonical_recheck="$(_omc_read_canonical_metadata_line \
              "${ownerfile}" 512 2>/dev/null || true)"
            if [[ "${reap_record}" != "${owner_record}" \
                || "${canonical_recheck}" != "${owner_record}" ]]; then
              cleanup_ok=0
            fi
            if [[ "${cleanup_ok}" -eq 1 && -d "${lockdir}" ]]; then
              if [[ -e "${pidfile}" || -L "${pidfile}" ]]; then
                legacy_pid="$(_omc_read_canonical_pid_file \
                  "${pidfile}" 2>/dev/null || true)"
                [[ -n "${legacy_pid}" ]] || cleanup_ok=0
              else
                legacy_pid=""
              fi
              if [[ "${cleanup_ok}" -eq 1 \
                  && "${legacy_pid}" == "${holder_pid}" ]]; then
                rm -f "${pidfile}" 2>/dev/null || true
                rmdir "${lockdir}" 2>/dev/null || cleanup_ok=0
              fi
            fi
            canonical_recheck="$(_omc_read_canonical_metadata_line \
              "${ownerfile}" 512 2>/dev/null || true)"
            if [[ "${cleanup_ok}" -eq 1 \
                && "${canonical_recheck}" == "${owner_record}" ]] \
                && rm -f "${ownerfile}" 2>/dev/null; then
              rm -f "${reap_claim}" 2>/dev/null || true
              continue
            fi
            # Preserve a recoverable owner shape if an unexpected artifact or
            # external mutation prevented the elected reaper from finishing.
            if [[ -f "${reap_claim}" && ! -e "${observed_claim}" ]]; then
              mv "${reap_claim}" "${observed_claim}" 2>/dev/null || true
            fi
          fi
        fi
        # A live atomic owner is authoritative regardless of mtime. In
        # particular, never reclaim the directory during the scheduler gap
        # before that owner gets to publish holder.pid.
      fi
    elif [[ ! -e "${ownerfile}" && ! -L "${ownerfile}" \
        && -d "${lockdir}" ]]; then
      # Compatibility recovery for a lock created before atomic sentinels (or
      # a crash that predates sentinel publication). New acquisitions never
      # produce this pidless interval.
      _lock_now="$(date +%s)"
      _lock_held_since="$(_lock_mtime "${lockdir}")"
      if [[ -e "${pidfile}" || -L "${pidfile}" ]]; then
        holder_pid="$(_omc_read_canonical_pid_file \
          "${pidfile}" 2>/dev/null || true)"
        [[ -n "${holder_pid}" ]] || holder_pid="invalid"
      else
        holder_pid=""
      fi
      if [[ "${holder_pid}" =~ ^[1-9][0-9]{0,19}$ ]] \
          && ! kill -0 "${holder_pid}" 2>/dev/null; then
        rm -f "${pidfile}" 2>/dev/null || true
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
      if [[ "${_lock_held_since}" -gt 0 ]] \
          && [[ $(( _lock_now - _lock_held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]] \
          && [[ -z "${holder_pid}" ]]; then
          rm -f "${pidfile}" 2>/dev/null || true
          rmdir "${lockdir}" 2>/dev/null || true
          continue
      fi
    fi
    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      rm -f "${claimfile}" 2>/dev/null || true
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
  if [[ "${acquired}" -eq 1 ]]; then
    omc_release_lockdir_owner_exact \
      "${lockdir}" "${owner_token}" "${tag}" || {
        # A partial release may deliberately leave the exact canonical owner
        # plus its unique claim so a successor can elect one dead-owner
        # reaper. Never orphan that canonical token by deleting its claim.
        # The claim is disposable only after ownership is provably gone or
        # belongs to a different generation.
        owner_record=""
        if [[ -f "${ownerfile}" && ! -L "${ownerfile}" ]]; then
          owner_record="$(_omc_read_canonical_metadata_line \
            "${ownerfile}" 512 2>/dev/null || true)"
        fi
        if [[ "${owner_record}" != "${owner_token}" ]]; then
          rm -f "${claimfile}" 2>/dev/null || true
        fi
        rc=1
      }
  else
    rm -f "${claimfile}" 2>/dev/null || true
    log_anomaly "${tag}" "lock ownership changed before release"
    rc=1
  fi
  return "${rc}"
}

_omc_current_reset_transaction_fingerprint() {
  local sid="${1:-}" session_dir node name marker marker_value kind
  local manifest="" count=0
  validate_session_id "${sid}" 2>/dev/null || return 1
  session_dir="${STATE_ROOT}/${sid}"
  for node in "${session_dir}"/.deactivate-txn.*; do
    [[ -e "${node}" || -L "${node}" ]] || continue
    name="${node##*/}"
    count=$((count + 1))
    if [[ -d "${node}" && ! -L "${node}" ]]; then
      marker="${node}/.enforcement-generation"
      if [[ -f "${marker}" && ! -L "${marker}" ]]; then
        marker_value="$(_omc_read_canonical_metadata_line \
          "${marker}" 32 2>/dev/null || true)"
        [[ -n "${marker_value}" ]] || marker_value="invalid"
        [[ "${marker_value}" \
            =~ ^(0|[1-9][0-9]{0,17}|migration)$ ]] \
          || marker_value="invalid"
      else
        marker_value="missing"
      fi
      kind="dir:${marker_value}"
    elif [[ -L "${node}" ]]; then
      kind="symlink"
    else
      kind="other"
    fi
    manifest="${manifest}${#name}:${name}:${#kind}:${kind};"
  done
  printf '%s:%s' "${count}" "${manifest}"
}

_omc_current_state_generation() {
  local generation
  generation="$(read_state "ulw_enforcement_generation" \
    2>/dev/null || true)"
  [[ "${generation}" =~ ^(0|[1-9][0-9]{0,17}|migration)$ ]] \
    || generation="migration"
  printf '%s' "${generation}"
}

_omc_visible_variable_is_nonexported() {
  local variable="${1:-}" declaration
  [[ "${variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  declaration="$(declare -p "${1:-}" 2>/dev/null || true)"
  # Capability locals are plain scalars. Accept only Bash's exact `declare --`
  # shape; any combined attribute token (especially `x`) is ambient/exported
  # authority and must fail closed.
  [[ "${declaration}" == "declare -- ${variable}="* ]]
}

_omc_state_lock_authority_valid() {
  local callback="${1:-}" current_generation current_fingerprint=""
  local authority_var
  for authority_var in _OMC_STATE_LOCK_AUTH_KIND \
      _OMC_STATE_LOCK_AUTH_SESSION _OMC_STATE_LOCK_AUTH_GENERATION \
      _OMC_STATE_LOCK_AUTH_TRANSACTION _OMC_STATE_LOCK_AUTH_CALLBACK \
      _OMC_STATE_LOCK_AUTH_CONSUMED; do
    _omc_visible_variable_is_nonexported "${authority_var}" || return 1
  done
  [[ "${_OMC_STATE_LOCK_AUTH_CONSUMED:-1}" -eq 0 \
      && "${_OMC_STATE_LOCK_AUTH_SESSION:-}" == "${SESSION_ID:-}" \
      && "${_OMC_STATE_LOCK_AUTH_GENERATION:-}" \
        =~ ^(0|[1-9][0-9]{0,17}|migration)$ \
      && "${callback}" == "${_OMC_STATE_LOCK_AUTH_CALLBACK:-}" ]] \
    || return 1
  current_generation="$(_omc_current_state_generation)"
  [[ "${current_generation}" \
      == "${_OMC_STATE_LOCK_AUTH_GENERATION}" ]] || return 1
  case "${_OMC_STATE_LOCK_AUTH_KIND:-}" in
    ulw-deactivate)
      [[ "${callback}" == "_deactivate_session_unlocked" ]] || return 1
      current_fingerprint="$(_omc_current_reset_transaction_fingerprint \
        "${SESSION_ID}")" || return 1
      [[ "${current_fingerprint}" \
          == "${_OMC_STATE_LOCK_AUTH_TRANSACTION:-}" ]] || return 1
      ;;
    dispatch-denial-retire)
      [[ "${callback}" == "_retire_emitted_dispatch_denial_unlocked" \
          && "${_OMC_STATE_LOCK_AUTH_TRANSACTION%/*}" \
            == "${STATE_ROOT}/${SESSION_ID}" \
          && "${_OMC_STATE_LOCK_AUTH_TRANSACTION##*/}" \
            == .dispatch-txn.* ]] \
        || return 1
      [[ -d "${_OMC_STATE_LOCK_AUTH_TRANSACTION}" \
          && ! -L "${_OMC_STATE_LOCK_AUTH_TRANSACTION}" ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

_omc_state_lock_caller_is() {
  local expected="${1:-}" actual="${0:-}" expected_resolved actual_resolved
  [[ "${expected}" == /* && -n "${actual}" ]] || return 1
  expected_resolved="$(_omc_state_io_resolve_path \
    "${expected}" 2>/dev/null || true)"
  actual_resolved="$(_omc_state_io_resolve_path \
    "${actual}" 2>/dev/null || true)"
  [[ -n "${expected_resolved}" \
      && "${actual_resolved}" == "${expected_resolved}" ]]
}

_omc_publication_transaction_fingerprint() {
  local sid="${1:-}" session_dir path kind manifest="" identity="" digest=""
  validate_session_id "${sid}" 2>/dev/null || return 1
  session_dir="${STATE_ROOT}/${sid}"
  for path in "${session_dir}/.plan-txn.active" \
      "${session_dir}/.reviewer-transaction.wal"; do
    if [[ -d "${path}" && ! -L "${path}" ]]; then
      case "${path##*/}" in
        .plan-txn.active) identity="${path}/.ready" ;;
        .reviewer-transaction.wal) identity="${path}/manifest.json" ;;
        *) return 1 ;;
      esac
      if [[ -f "${identity}" && ! -L "${identity}" ]]; then
        digest="$(_omc_digest_file "${identity}" 2>/dev/null || true)"
        [[ -n "${digest}" ]] || return 1
        kind="dir:$(_lock_mtime "${path}"):file:${digest}"
      elif [[ -L "${identity}" ]]; then
        kind="dir:$(_lock_mtime "${path}"):identity-symlink"
      elif [[ -e "${identity}" ]]; then
        kind="dir:$(_lock_mtime "${path}"):identity-other"
      else
        kind="dir:$(_lock_mtime "${path}"):identity-missing"
      fi
    elif [[ -L "${path}" ]]; then
      kind="symlink"
    elif [[ -e "${path}" ]]; then
      kind="other"
    else
      kind="absent"
    fi
    manifest="${manifest}${path##*/}:${kind};"
  done
  printf '%s' "${manifest}"
}

_omc_state_io_trusted_scripts_dir() {
  local state_io_source=""
  state_io_source="$(_omc_state_io_resolve_path "${BASH_SOURCE[0]}" \
    2>/dev/null || true)"
  [[ "${state_io_source}" == */lib/state-io.sh ]] || return 1
  printf '%s' "${state_io_source%/lib/state-io.sh}"
}

_omc_publication_recovery_caller_allowed() {
  local actual="${1:-}" resolved="" base="" expected=""
  local trusted_scripts_dir="" quality_scripts_dir=""
  resolved="$(_omc_state_io_resolve_path \
    "${actual}" 2>/dev/null || true)"
  # Derive the allowlist root from this loaded library, not from the mutable
  # `_OMC_AUTOWORK_SCRIPTS_DIR` convenience variable. Otherwise an unrelated
  # `/tmp/record-plan.sh` could source common.sh, replace that variable, and
  # make its own basename appear canonical. Resolving the library path first
  # preserves installed/test-HOME symlink support while pinning every caller
  # to the exact scripts shipped beside this state-io implementation.
  trusted_scripts_dir="$(_omc_state_io_trusted_scripts_dir)" || return 1
  base="${resolved##*/}"
  case "${base}" in
    record-plan.sh|record-reviewer.sh|record-subagent-summary.sh)
      expected="$(_omc_state_io_resolve_path \
        "${trusted_scripts_dir}/${base}" 2>/dev/null || true)"
      ;;
    session-start-compact-handoff.sh|pre-compact-snapshot.sh|\
    post-compact-summary.sh|session-start-resume-handoff.sh)
      quality_scripts_dir="$(
        cd "${trusted_scripts_dir}/../../../quality-pack/scripts" \
          2>/dev/null && pwd -P
      )" || return 1
      expected="${quality_scripts_dir}/${base}"
      ;;
    *) return 1 ;;
  esac
  [[ -n "${expected}" && "${resolved}" == "${expected}" \
      && -f "${resolved}" && ! -L "${resolved}" ]]
}

_omc_publication_recovery_pair_allowed() {
  local caller="${1:-}" callback="${2:-}" base=""
  _omc_publication_recovery_caller_allowed "${caller}" || return 1
  base="${caller##*/}"
  case "${base}:${callback}" in
    record-plan.sh:_recover_cold_plan_publication_unlocked|\
    record-plan.sh:_recover_active_plan_publication_unlocked|\
    record-plan.sh:_settle_orphaned_plan_waiter_from_outcome_unlocked|\
    record-reviewer.sh:_recover_active_reviewer_unlocked|\
    record-subagent-summary.sh:_claim_summary_pending_unlocked|\
    record-subagent-summary.sh:_mark_reviewer_recovery_retry_unlocked|\
    record-subagent-summary.sh:_finalize_summary_completion_unlocked|\
    record-subagent-summary.sh:_settle_plan_summary_waiter_unlocked|\
    record-subagent-summary.sh:_settle_reviewer_summary_waiter_unlocked)
      return 0
      ;;
    *) return 1 ;;
  esac
}

_omc_publication_recovery_capability_valid() {
  local cap_var current_fingerprint
  for cap_var in _OMC_PUBLICATION_RECOVERY_CAP_SESSION \
      _OMC_PUBLICATION_RECOVERY_CAP_CALLBACK \
      _OMC_PUBLICATION_RECOVERY_CAP_CALLER \
      _OMC_PUBLICATION_RECOVERY_CAP_FINGERPRINT \
      _OMC_PUBLICATION_RECOVERY_CAP_CONSUMED; do
    _omc_visible_variable_is_nonexported "${cap_var}" || return 1
  done
  [[ "${_OMC_PUBLICATION_RECOVERY_CAP_CONSUMED:-1}" -eq 0 \
      && "${_OMC_PUBLICATION_RECOVERY_CAP_SESSION:-}" == "${SESSION_ID:-}" \
      && "${1:-}" == "${_OMC_PUBLICATION_RECOVERY_CAP_CALLBACK:-}" ]] \
    || return 1
  _omc_state_lock_caller_is "${_OMC_PUBLICATION_RECOVERY_CAP_CALLER:-}" \
    || return 1
  _omc_publication_recovery_pair_allowed \
    "${_OMC_PUBLICATION_RECOVERY_CAP_CALLER:-}" \
    "${_OMC_PUBLICATION_RECOVERY_CAP_CALLBACK:-}" || return 1
  current_fingerprint="$(_omc_publication_transaction_fingerprint \
    "${SESSION_ID}")" || return 1
  [[ "${current_fingerprint}" \
      == "${_OMC_PUBLICATION_RECOVERY_CAP_FINGERPRINT:-}" ]]
}

with_state_lock_publication_recovery() {
  [[ "$#" -ge 1 && -n "${SESSION_ID:-}" ]] || return 1
  _omc_publication_recovery_pair_allowed "${0:-}" "${1:-}" || return 1
  local _OMC_PUBLICATION_RECOVERY_CAP_SESSION="${SESSION_ID}"
  local _OMC_PUBLICATION_RECOVERY_CAP_CALLBACK="${1}"
  local _OMC_PUBLICATION_RECOVERY_CAP_CALLER
  local _OMC_PUBLICATION_RECOVERY_CAP_FINGERPRINT
  local _OMC_PUBLICATION_RECOVERY_CAP_CONSUMED=0
  _OMC_PUBLICATION_RECOVERY_CAP_CALLER="$(_omc_state_io_resolve_path "${0}" \
    2>/dev/null || true)"
  _OMC_PUBLICATION_RECOVERY_CAP_FINGERPRINT="$(_omc_publication_transaction_fingerprint \
    "${SESSION_ID}")" || return 1
  export -n _OMC_PUBLICATION_RECOVERY_CAP_SESSION \
    _OMC_PUBLICATION_RECOVERY_CAP_CALLBACK \
    _OMC_PUBLICATION_RECOVERY_CAP_CALLER \
    _OMC_PUBLICATION_RECOVERY_CAP_FINGERPRINT \
    _OMC_PUBLICATION_RECOVERY_CAP_CONSUMED
  with_state_lock "$@"
}

_omc_current_process_matches_pid() {
  local expected_pid="${1:-}" current_pid=""
  [[ "${expected_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -r /proc/self/stat ]] \
      && IFS=' ' read -r current_pid _ </proc/self/stat \
      && [[ "${current_pid}" =~ ^[1-9][0-9]*$ ]]; then
    [[ "${current_pid}" == "${expected_pid}" ]] && return 0
    return 1
  fi
  if [[ "${BASH_SUBSHELL:-0}" -eq 0 && "$$" =~ ^[1-9][0-9]*$ ]]; then
    [[ "$$" == "${expected_pid}" ]] && return 0
    return 1
  fi
  # macOS Bash 3 keeps `$$` equal to the parent inside `( ... )`. A direct
  # child observes the real current shell as PPID; do not use command
  # substitution, which would compare against a short-lived intermediary.
  /bin/sh -c 'test "$PPID" = "$1"' sh "${expected_pid}"
}

_omc_resume_target_capability_valid() {
  local cap_var lockdir ownerfile observed="" token_pid
  for cap_var in _OMC_RESUME_TARGET_CAP_TXN_ID \
      _OMC_RESUME_TARGET_CAP_SOURCE_ID _OMC_RESUME_TARGET_CAP_LOCKDIR \
      _OMC_RESUME_TARGET_CAP_OWNER_TOKEN; do
    _omc_visible_variable_is_nonexported "${cap_var}" || return 1
  done
  [[ "${_OMC_RESUME_TARGET_CAP_TXN_ID:-}" \
        =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{15,159}$ \
      && "${_OMC_RESUME_TARGET_CAP_SOURCE_ID:-}" \
        =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || return 1
  validate_session_id "${_OMC_RESUME_TARGET_CAP_SOURCE_ID}" \
    2>/dev/null || return 1
  lockdir="${_OMC_RESUME_TARGET_CAP_LOCKDIR:-}"
  [[ "${lockdir}" \
      == "${STATE_ROOT}.resume-init-locks/${SESSION_ID}.lock" ]] || return 1
  ownerfile="${lockdir}.owner"
  [[ -f "${ownerfile}" && ! -L "${ownerfile}" ]] || return 1
  observed="$(_omc_read_canonical_metadata_line \
    "${ownerfile}" 512 2>/dev/null || true)"
  [[ -n "${observed}" \
      && "${observed}" == "${_OMC_RESUME_TARGET_CAP_OWNER_TOKEN:-}" ]] \
    || return 1
  token_pid="${observed%%:*}"
  _omc_current_process_matches_pid "${token_pid}" \
    && _omc_lock_owner_has_exact_birth_identity \
      "${token_pid}" "${observed}"
}

_omc_state_lock_reentry_valid() {
  local marker_var observed="" token_pid
  for marker_var in _OMC_STATE_LOCK_HELD _OMC_STATE_LOCK_HELD_SESSION \
      _OMC_STATE_LOCK_HELD_LOCKDIR _OMC_STATE_LOCK_HELD_OWNER_TOKEN; do
    _omc_visible_variable_is_nonexported "${marker_var}" || return 1
  done
  [[ "${_OMC_STATE_LOCK_HELD:-}" == "1" \
      && "${_OMC_STATE_LOCK_HELD_SESSION:-}" == "${SESSION_ID:-}" \
      && "${_OMC_STATE_LOCK_HELD_LOCKDIR:-}" \
        == "${STATE_ROOT}/${SESSION_ID}/.state.lock" ]] || return 1
  [[ -f "${_OMC_STATE_LOCK_HELD_LOCKDIR}.owner" \
      && ! -L "${_OMC_STATE_LOCK_HELD_LOCKDIR}.owner" ]] || return 1
  observed="$(_omc_read_canonical_metadata_line \
    "${_OMC_STATE_LOCK_HELD_LOCKDIR}.owner" 512 2>/dev/null || true)"
  [[ -n "${observed}" \
      && "${observed}" == "${_OMC_STATE_LOCK_HELD_OWNER_TOKEN:-}" ]] \
    || return 1
  token_pid="${observed%%:*}"
  _omc_current_process_matches_pid "${token_pid}"
}

# Narrow, one-invocation state-lock capabilities. These locals are dynamically
# visible only to the immediately nested `with_state_lock`; they are not
# exported and cannot be inherited by a child process. The under-lock body
# revalidates session, generation, exact callback, and current transaction,
# then consumes the capability before bypassing any lifecycle fence.
with_state_lock_ulw_deactivate() {
  local trusted_scripts_dir=""
  [[ "$#" -eq 1 \
      && "${1:-}" == "_deactivate_session_unlocked" ]] || return 1
  trusted_scripts_dir="$(_omc_state_io_trusted_scripts_dir)" || return 1
  _omc_state_lock_caller_is \
    "${trusted_scripts_dir}/ulw-deactivate.sh" || return 1
  local _OMC_STATE_LOCK_AUTH_KIND="ulw-deactivate"
  local _OMC_STATE_LOCK_AUTH_SESSION="${SESSION_ID:-}"
  local _OMC_STATE_LOCK_AUTH_GENERATION
  local _OMC_STATE_LOCK_AUTH_TRANSACTION
  local _OMC_STATE_LOCK_AUTH_CALLBACK="_deactivate_session_unlocked"
  local _OMC_STATE_LOCK_AUTH_CONSUMED=0
  export -n _OMC_STATE_LOCK_AUTH_KIND _OMC_STATE_LOCK_AUTH_SESSION \
    _OMC_STATE_LOCK_AUTH_GENERATION _OMC_STATE_LOCK_AUTH_TRANSACTION \
    _OMC_STATE_LOCK_AUTH_CALLBACK _OMC_STATE_LOCK_AUTH_CONSUMED
  validate_session_id "${_OMC_STATE_LOCK_AUTH_SESSION}" 2>/dev/null \
    || return 1
  _OMC_STATE_LOCK_AUTH_GENERATION="$(_omc_current_state_generation)"
  _OMC_STATE_LOCK_AUTH_TRANSACTION="$(_omc_current_reset_transaction_fingerprint \
    "${_OMC_STATE_LOCK_AUTH_SESSION}")" || return 1
  with_state_lock "$@"
}

with_state_lock_dispatch_denial_retire() {
  local snapshot="${1:-}"
  local trusted_scripts_dir=""
  shift || true
  [[ "$#" -eq 1 \
      && "${1:-}" == "_retire_emitted_dispatch_denial_unlocked" ]] \
    || return 1
  trusted_scripts_dir="$(_omc_state_io_trusted_scripts_dir)" || return 1
  _omc_state_lock_caller_is \
    "${trusted_scripts_dir}/record-pending-agent.sh" || return 1
  local _OMC_STATE_LOCK_AUTH_KIND="dispatch-denial-retire"
  local _OMC_STATE_LOCK_AUTH_SESSION="${SESSION_ID:-}"
  local _OMC_STATE_LOCK_AUTH_GENERATION
  local _OMC_STATE_LOCK_AUTH_TRANSACTION="${snapshot}"
  local _OMC_STATE_LOCK_AUTH_CALLBACK="_retire_emitted_dispatch_denial_unlocked"
  local _OMC_STATE_LOCK_AUTH_CONSUMED=0
  export -n _OMC_STATE_LOCK_AUTH_KIND _OMC_STATE_LOCK_AUTH_SESSION \
    _OMC_STATE_LOCK_AUTH_GENERATION _OMC_STATE_LOCK_AUTH_TRANSACTION \
    _OMC_STATE_LOCK_AUTH_CALLBACK _OMC_STATE_LOCK_AUTH_CONSUMED
  validate_session_id "${_OMC_STATE_LOCK_AUTH_SESSION}" 2>/dev/null \
    || return 1
  _OMC_STATE_LOCK_AUTH_GENERATION="$(_omc_current_state_generation)"
  _omc_state_lock_authority_valid "${1}" || return 1
  with_state_lock "$@"
}

_omc_state_lock_publication_fenced_body() {
  local expected_generation current_mode current_active current_generation
  local reset_authorized=0 dispatch_retire_authorized=0
  local publication_recovery_authorized=0
  local expected_resume_txn="" expected_resume_source=""
  local resume_capability_valid=0
  local resume_state_file
  # Mint the ordinary re-entry marker as soon as canonical ownership exists,
  # not only immediately before the user callback. The publication scan below
  # can then prove it is running under this exact mutex generation and omit
  # its optimistic before/after portfolio snapshots. All semantic validation
  # still runs; foreign/unlocked callers retain the full TOCTOU guard.
  local _OMC_STATE_LOCK_HELD=1
  local _OMC_STATE_LOCK_HELD_SESSION="${SESSION_ID:-}"
  local _OMC_STATE_LOCK_HELD_LOCKDIR="${lockdir:-}"
  local _OMC_STATE_LOCK_HELD_OWNER_TOKEN="${owner_token:-}"
  export -n _OMC_STATE_LOCK_HELD _OMC_STATE_LOCK_HELD_SESSION \
    _OMC_STATE_LOCK_HELD_LOCKDIR _OMC_STATE_LOCK_HELD_OWNER_TOKEN
  if _omc_resume_target_capability_valid; then
    resume_capability_valid=1
    expected_resume_txn="${_OMC_RESUME_TARGET_CAP_TXN_ID}"
    expected_resume_source="${_OMC_RESUME_TARGET_CAP_SOURCE_ID}"
  fi
  if _omc_state_lock_authority_valid "${1:-}"; then
    case "${_OMC_STATE_LOCK_AUTH_KIND}" in
      ulw-deactivate) reset_authorized=1 ;;
      dispatch-denial-retire) dispatch_retire_authorized=1 ;;
    esac
    _OMC_STATE_LOCK_AUTH_CONSUMED=1
  fi
  if _omc_publication_recovery_capability_valid "${1:-}"; then
    publication_recovery_authorized=1
    _OMC_PUBLICATION_RECOVERY_CAP_CONSUMED=1
  fi
  # A committed resume handoff leaves the source directory byte-stable for
  # idempotent replay and reporting only. Reject every ordinary mutation while
  # holding its mutex; the exact managed reset retains convergence authority.
  if [[ "${reset_authorized}" -ne 1 ]] \
      && declare -F omc_resume_transfer_owner >/dev/null 2>&1 \
      && omc_resume_transfer_owner "${SESSION_ID:-}" >/dev/null 2>&1; then
    return 78
  fi
  # A callback may have passed its script-local recovery check and then waited
  # behind Agent admission. Recheck after mutex acquisition so no PostTool,
  # SubagentStop, compact, prompt, or closeout mutation can cross a retained
  # dispatch/reset quarantine. Only the exact reset owner may converge it.
  if [[ "${reset_authorized}" -ne 1 \
      && "${dispatch_retire_authorized}" -ne 1 ]] \
      && declare -F omc_interrupted_dispatch_transaction_present \
        >/dev/null 2>&1 \
      && omc_interrupted_dispatch_transaction_present \
        "${SESSION_ID:-}"; then
    return 76
  fi
  # Long-running UserPromptSubmit routing activates one exact ULW generation,
  # then performs many separately locked writes while it assembles context.
  # Exact /ulw-off may linearize between those writes. Once the router binds
  # this expectation, every later outer state callback must still observe the
  # same active interval; otherwise it is a stale pre-reset callback and may
  # neither republish state/markers nor emit an ULW-on frame.
  expected_generation="${OMC_EXPECTED_ACTIVE_ULW_GENERATION:-}"
  if [[ -n "${expected_generation}" ]]; then
    [[ "${expected_generation}" =~ ^(0|[1-9][0-9]{0,17}|migration)$ ]] \
      || return 77
    current_mode="$(read_state "workflow_mode" 2>/dev/null || true)"
    current_active="$(read_state \
      "ulw_enforcement_active" 2>/dev/null || true)"
    current_generation="$(read_state \
      "ulw_enforcement_generation" 2>/dev/null || true)"
    [[ "${current_mode}" == "ultrawork" \
        && "${current_active}" == "1" \
        && "${current_generation}" == "${expected_generation}" ]] \
      || return 77
  fi
  # Resume target initialization is an optimistic generation transaction.
  # Every target-side state/artifact mutation takes this mutex and proves that
  # the exact transaction still owns an untransferred target. A concurrent
  # T→U source commit therefore wins atomically or is rejected; a stale S→T
  # callback can never overwrite U's downstream ownership marker.
  if [[ "${reset_authorized}" -ne 1 ]]; then
    resume_state_file="$(session_file "${STATE_JSON}")"
    if [[ -e "${resume_state_file}" || -L "${resume_state_file}" ]]; then
      [[ -f "${resume_state_file}" && ! -L "${resume_state_file}" ]] \
        || return 79
      # Validate lifecycle authority while it is still JSON. Bash command
      # substitution discards NUL bytes, so importing first could turn an
      # invalid transaction/source pair or downstream owner into an empty (or
      # matching) shell value and silently bypass this generation fence. The
      # happy path performs one complete jq pass: the slower recovery/type
      # discriminator runs only after validation fails, which keeps concurrent
      # state writers inside the mutex's bounded acquisition budget.
      if _omc_regular_file_has_no_raw_nul "${resume_state_file}" \
          && current_mode="$(jq -er '
        def absent_or_string($key):
          (has($key) | not) or (.[$key] | type) == "string";
        def valid_session_id:
          type == "string"
          and (length >= 1 and length <= 128)
          and test("^[A-Za-z0-9_.-]+$")
          and . != "." and . != ".."
          and (contains("..") | not)
          and (test("^\\.+$") | not);
        def valid_resume_txn:
          type == "string"
          and (length >= 16 and length <= 160)
          and test("^[A-Za-z0-9][A-Za-z0-9._:-]+$");
        select(
          type == "object"
          and all(.. | strings; index("\u0000") == null)
          and all(.. | objects | keys[]; index("\u0000") == null)
          and absent_or_string("resume_initialization_txn_id")
          and absent_or_string("resume_initialization_source_id")
          and absent_or_string("resume_transferred_to")
          and (
            (has("resume_initialization_txn_id")
              and has("resume_initialization_source_id"))
            or
            ((has("resume_initialization_txn_id") | not)
              and (has("resume_initialization_source_id") | not))
          )
          and (((.resume_initialization_txn_id // "") == "")
            == ((.resume_initialization_source_id // "") == ""))
        )
        | (.resume_initialization_txn_id // "") as $txn
        | (.resume_initialization_source_id // "") as $source
        | (.resume_transferred_to // "") as $owner
        | select(($txn == "" or ($txn | valid_resume_txn))
          and ($source == "" or ($source | valid_session_id))
          and ($owner == "" or ($owner | valid_session_id)))
        | [$txn, $source, $owner]
        | @tsv
      ' "${resume_state_file}" 2>/dev/null)"; then
        _state_validated=1
        _state_validated_lock_session="${SESSION_ID:-}"
        _state_validated_lock_owner_token="${owner_token:-}"
      else
        # Preserve the long-standing corrupt-state recovery contract for an
        # invalid/non-object envelope or unrelated corruption. Once any resume
        # lifecycle coordinate is present in a parseable object, however, its
        # malformed authority is never normalized into a fresh writable state.
        if jq -e '
          type == "object"
          and (has("resume_initialization_txn_id")
            or has("resume_initialization_source_id")
            or has("resume_transferred_to"))
        ' "${resume_state_file}" >/dev/null 2>&1; then
          return 79
        fi
        _state_validated=0
        _state_validated_lock_session=""
        _state_validated_lock_owner_token=""
        _ensure_valid_state || return 79
        [[ -f "${resume_state_file}" && ! -L "${resume_state_file}" ]] \
          || return 79
        current_mode=$'\t\t'
        _state_validated_lock_session="${SESSION_ID:-}"
        _state_validated_lock_owner_token="${owner_token:-}"
      fi
      IFS=$'\t' read -r current_generation current_active current_mode \
        <<<"${current_mode}"
      if [[ -n "${current_generation}" || -n "${current_active}" \
          || "${resume_capability_valid}" -eq 1 ]]; then
        [[ "${resume_capability_valid}" -eq 1 \
            && "${expected_resume_txn}" \
              =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{15,159}$ \
            && "${expected_resume_source}" \
              =~ ^[A-Za-z0-9_.-]{1,128}$ \
            && "${current_generation}" == "${expected_resume_txn}" \
            && "${current_active}" == "${expected_resume_source}" \
            && -z "${current_mode}" ]] || return 79
      fi
    elif [[ -n "${expected_resume_txn}" \
        || -n "${expected_resume_source}" ]]; then
      return 79
    fi
  fi
  # This callback runs only after the session mutex is owned. A publisher may
  # have created/died with its fixed WAL after our pre-acquisition check but
  # before this acquisition. Signal the outer wrapper to release first; it must
  # never spawn recovery recursively while holding the same lock.
  if [[ "${publication_recovery_authorized}" -ne 1 \
      && "${reset_authorized}" -ne 1 ]] \
      && declare -F omc_publication_recovery_needed >/dev/null 2>&1 \
      && omc_publication_recovery_needed "${SESSION_ID:-}"; then
    _OMC_PUBLICATION_FENCE_RETRY=1
    return 75
  fi
  "$@"
}

with_state_lock() {
  # ── Re-entrancy contract (v1.31.3 quality-reviewer F-3 followup) ───
  #
  # Marker:    _OMC_STATE_LOCK_HELD plus exact session/lock/owner capability
  # Set when:  the OUTERMOST with_state_lock body owns the canonical mutex
  # Read by:   nested calls — they revalidate same-process ownership, then run
  #            inline without reacquiring the non-reentrant lockdir
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
  # that touches state, you do NOT need to do anything — the scoped marker
  # handles it. If you add a new state-touching helper that should
  # acquire its own lock when called standalone (like append_limited_state)
  # you DO need with_state_lock; the marker makes it composition-safe.
  #
  # Tested by tests/test-state-io.sh:T18 (CI-pinned in v1.32.0).
  if _omc_state_lock_reentry_valid; then
    "$@"
    return $?
  fi
  local lockdir
  lockdir="$(session_file ".state.lock")"
  # The fenced under-lock body mints the marker only after canonical ownership
  # is established. Nested callers must revalidate its exact owner token.
  local _rc=0 _publication_retries=0
  local _reset_authorized=0 _dispatch_retire_authorized=0
  local _test_preacquire_ready="${OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE:-}"
  local _test_preacquire_release="${OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE:-}"
  local _test_preacquire_target="${OMC_TEST_STATE_LOCK_PREACQUIRE_TARGET:-}"
  local _test_preacquire_count_file="${OMC_TEST_STATE_LOCK_PREACQUIRE_COUNT_FILE:-}"
  local _test_preacquire_count=0 _test_preacquire_pause=0
  if [[ -n "${_test_preacquire_target}" \
      || -n "${_test_preacquire_count_file}" ]]; then
    # Trusted-PATH hooks cannot be tested by interposing the lock primitive.
    # Let regression fixtures target one semantic state-lock acquisition
    # instead. The ordinal seam is active only when all four explicit paths /
    # values are present and valid; production callers leave them unset.
    [[ "${_test_preacquire_target}" =~ ^[1-9][0-9]{0,2}$ \
        && "${_test_preacquire_target}" -le 100 \
        && -n "${_test_preacquire_count_file}" \
        && -n "${_test_preacquire_ready}" \
        && -n "${_test_preacquire_release}" ]] || return 1
  fi
  while true; do
    _reset_authorized=0
    _dispatch_retire_authorized=0
    if _omc_state_lock_authority_valid "${1:-}"; then
      case "${_OMC_STATE_LOCK_AUTH_KIND}" in
        ulw-deactivate) _reset_authorized=1 ;;
        dispatch-denial-retire) _dispatch_retire_authorized=1 ;;
      esac
    fi
    # Fast transferred-source fence. The under-lock callback closes a handoff
    # that commits between this check and acquisition.
    if [[ "${_reset_authorized}" -ne 1 ]] \
        && declare -F omc_resume_transfer_owner >/dev/null 2>&1 \
        && omc_resume_transfer_owner "${SESSION_ID:-}" >/dev/null 2>&1; then
      return 78
    fi
    # Fast pre-check for the non-replayable dispatch/reset journal. The
    # post-acquisition callback closes the check/acquire race below.
    if [[ "${_reset_authorized}" -ne 1 \
        && "${_dispatch_retire_authorized}" -ne 1 ]] \
        && declare -F omc_interrupted_dispatch_transaction_present \
          >/dev/null 2>&1 \
        && omc_interrupted_dispatch_transaction_present \
          "${SESSION_ID:-}"; then
      return 76
    fi
    # Publication recovery is decided once after mutex acquisition below.
    # The former optimistic pre-check performed the same multi-ledger,
    # content-bound portfolio scan both before and after every state lock. It
    # could never authorize mutation—the under-lock check still had to close
    # the race—so it doubled hot-path work without strengthening the fence.
    # A retained WAL/claim now returns 75 from the fenced body, releases the
    # mutex, performs recovery, and retries exactly as before.

    # Deterministic regression barrier for check/acquire and optimistic-CAS
    # races. With no target ordinal it pauses this acquisition exactly as
    # before. A target + counter file pauses only that numbered outer state-lock
    # acquisition, so trusted-PATH tests never need to shadow `ln`.
    _test_preacquire_pause=0
    if [[ -n "${_test_preacquire_ready}" \
        && -n "${_test_preacquire_release}" ]]; then
      _test_preacquire_pause=1
      if [[ -n "${_test_preacquire_target}" ]]; then
        [[ ! -L "${_test_preacquire_count_file}" \
            && ( ! -e "${_test_preacquire_count_file}" \
              || -f "${_test_preacquire_count_file}" ) ]] || return 1
        _test_preacquire_count=0
        if [[ -f "${_test_preacquire_count_file}" ]]; then
          _test_preacquire_count="$(<"${_test_preacquire_count_file}")"
          [[ "${_test_preacquire_count}" =~ ^(0|[1-9][0-9]{0,2})$ \
              && "${_test_preacquire_count}" -le 100 ]] || return 1
        fi
        _test_preacquire_count=$((_test_preacquire_count + 1))
        printf '%s\n' "${_test_preacquire_count}" \
          >"${_test_preacquire_count_file}" || return 1
        if [[ "${_test_preacquire_count}" -ne "${_test_preacquire_target}" ]]; then
          _test_preacquire_pause=0
        fi
      fi
    fi
    if [[ "${_test_preacquire_pause}" -eq 1 ]]; then
      : >"${_test_preacquire_ready}" || return 1
      while [[ ! -e "${_test_preacquire_release}" ]]; do
        sleep 0.01
      done
    fi

    _OMC_PUBLICATION_FENCE_RETRY=0
    _rc=0
    _with_lockdir "${lockdir}" "with_state_lock" \
      _omc_state_lock_publication_fenced_body "$@" || _rc=$?
    if [[ "${_OMC_PUBLICATION_FENCE_RETRY}" -ne 1 ]]; then
      return "${_rc}"
    fi

    _publication_retries=$((_publication_retries + 1))
    if (( _publication_retries > 3 )); then
      log_anomaly "with_state_lock" \
        "publication recovery fence did not converge after 3 retries" \
        2>/dev/null || true
      return 1
    fi
    declare -F omc_recover_active_publication_transactions >/dev/null 2>&1 \
      || return 1
    omc_recover_active_publication_transactions "${SESSION_ID:-}" \
      || return 1
  done
}

# Convenience wrapper: atomic write_state_batch inside with_state_lock.
# Usage: with_state_lock_batch k1 v1 k2 v2 ...
with_state_lock_batch() {
  with_state_lock _write_state_batch_unlocked "$@"
}
