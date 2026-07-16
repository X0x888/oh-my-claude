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
    local archive recovered_ts recovery_count_file recovery_count
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
    recovery_count="$(cat "${recovery_count_file}" 2>/dev/null || printf '0')"
    [[ "${recovery_count}" =~ ^[0-9]+$ ]] || recovery_count=0
    recovery_count=$((recovery_count + 1))
    printf '%s\n' "${recovery_count}" > "${recovery_count_file}" 2>/dev/null || true

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
  fi

  _state_validated=1
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
  if [[ -n "${_OMC_STATE_LOCK_HELD:-}" || -z "${SESSION_ID:-}" ]]; then
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
  if [[ -n "${_OMC_STATE_LOCK_HELD:-}" || -z "${SESSION_ID:-}" ]]; then
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
  # serializes the cycle; the atomic-owner lock is short-lived and the
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
#   • CHARACTER SET: jq `-j` strips NUL (0x00) from output; producers
#     storing NUL-bearing data cannot round-trip via this API. Other
#     control bytes (TAB, BEL, BS, ESC, multi-byte UTF-8) pass through
#     intact.
#
#   • REGRESSION NETS:
#       - tests/test-state-io.sh:T20 (positional-alignment under all
#         12 adversarial value shapes from tests/lib/value-shapes.sh)
#       - tests/test-state-fuzz.sh Class 12 (multi-line value Bug B
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
  # NUL would be cleaner but `jq -j` strips NUL bytes from output.
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
  jq -j --args '$ARGS.positional[] as $k | ((.[$k] // "") | gsub("\u001e"; "")) + "\u001e"' "$@" < "${state_file}" 2>/dev/null \
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
# both macOS and Linux without flock. A dead holder PID is reclaimed
# immediately; pidless pre-sentinel legacy locks wait for the stale timeout.
#
# Usage: with_state_lock my_function arg1 arg2 ...
#
# Returns the wrapped function's exit status, or 1 if the lock cannot
# be acquired within OMC_STATE_LOCK_MAX_ATTEMPTS polls (default 60).

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
OMC_STATE_LOCK_MAX_ATTEMPTS="${OMC_STATE_LOCK_MAX_ATTEMPTS:-${OMC_LOCK_CAP:-60}}"
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
  local scanned=0
  lock_parent="$(dirname "${ownerfile}")"
  canonical_record=""
  IFS= read -r canonical_record <"${ownerfile}" 2>/dev/null \
    || canonical_record=""

  # Reap artifacts first. Once their exact owner token is no longer
  # canonical, only a live elected reaper can still be using them.
  for reap in "${ownerfile}.claim."*.reap.*; do
    [[ -f "${reap}" && ! -L "${reap}" ]] || continue
    scanned=$((scanned + 1))
    [[ "${scanned}" -le 256 ]] || break
    candidate_record=""
    IFS= read -r candidate_record <"${reap}" 2>/dev/null \
      || candidate_record=""
    [[ -n "${candidate_record}" && "${candidate_record}" != "${canonical_record}" ]] \
      || continue
    reaper_claim_name="${reap##*.reap.}"
    [[ "${reaper_claim_name}" == "${ownerfile##*/}.claim."* \
        && "${reaper_claim_name}" != */* ]] || continue
    reaper_claim="${lock_parent}/${reaper_claim_name}"
    reaper_record=""
    IFS= read -r reaper_record <"${reaper_claim}" 2>/dev/null \
      || reaper_record=""
    reaper_pid="${reaper_record%%:*}"
    reaper_record_claim="${reaper_record#*:}"
    reaper_record_claim="${reaper_record_claim%%:*}"
    if [[ -n "${reaper_record}" ]]; then
      [[ "${reaper_pid}" =~ ^[1-9][0-9]*$ \
          && "${reaper_record_claim}" == "${reaper_claim_name}" ]] || continue
      kill -0 "${reaper_pid}" 2>/dev/null && continue
    fi
    current_record=""
    IFS= read -r current_record <"${ownerfile}" 2>/dev/null \
      || current_record=""
    [[ "${current_record}" != "${candidate_record}" ]] || continue
    current_record=""
    IFS= read -r current_record <"${reap}" 2>/dev/null \
      || current_record=""
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
    IFS= read -r candidate_record <"${candidate}" 2>/dev/null \
      || candidate_record=""
    candidate_pid="${candidate_record%%:*}"
    candidate_record_claim="${candidate_record#*:}"
    candidate_record_claim="${candidate_record_claim%%:*}"
    [[ "${candidate_pid}" =~ ^[1-9][0-9]*$ \
        && "${candidate_record_claim}" == "${candidate_name}" ]] || continue
    kill -0 "${candidate_pid}" 2>/dev/null && continue
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
    IFS= read -r current_record <"${ownerfile}" 2>/dev/null \
      || current_record=""
    [[ "${current_record}" != "${candidate_record}" ]] || continue
    current_record=""
    IFS= read -r current_record <"${candidate}" 2>/dev/null \
      || current_record=""
    [[ "${current_record}" == "${candidate_record}" ]] || continue
    rm -f "${candidate}" 2>/dev/null || true
  done
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
#   - PID-based stale recovery (v1.29.0 metis F-6 pattern, generalized in
#     v1.30.0). A unique, fully populated temp file is
#     hard-linked atomically to <lockdir>.owner; only that owner then creates
#     <lockdir>/holder.pid for compatibility and observability. Waiters trust
#     the sentinel first and never stale-recover a live owner merely because
#     the scheduler paused it between filesystem operations. Dead sentinel
#     owners are reclaimed immediately. A lock directory without a sentinel
#     is a pre-sentinel legacy/crash shape and retains mtime-based recovery.
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
  local owner_pid="" claimfile="" claim_name="" owner_token=""
  local owner_record="" holder_pid="" legacy_pid=""
  local _lock_held_since="" _lock_now=""
  local observed_claim="" observed_claim_name="" reap_claim="" cleanup_ok=0
  local prior_reap="" prior_reap_record="" prior_reaper_claim_name=""
  local prior_reaper_claim="" prior_reaper_record="" prior_reaper_pid=""
  local prior_reaper_record_claim="" elected_reaper=0
  claimfile="$(mktemp "${ownerfile}.claim.XXXXXX")" || {
    log_anomaly "${tag}" "lock owner staging failed"
    return 1
  }
  claim_name="${claimfile##*/}"
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
  elif /bin/sh -c 'printf "%s\n" "$PPID" >"$1"' sh "${claimfile}"; then
    owner_pid="$(cat "${claimfile}" 2>/dev/null | tr -d '[:space:]' || true)"
  else
    owner_pid=""
  fi
  if [[ ! "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "${claimfile}" 2>/dev/null || true
    log_anomaly "${tag}" "lock owner PID capture failed"
    return 1
  fi
  owner_token="${owner_pid}:${claim_name}:${RANDOM:-0}"
  if ! printf '%s\n' "${owner_token}" >"${claimfile}" \
      || ! chmod 600 "${claimfile}" 2>/dev/null; then
    rm -f "${claimfile}" 2>/dev/null || true
    log_anomaly "${tag}" "lock owner staging failed"
    return 1
  fi

  local attempts=0 acquired=0
  while true; do
    # `ln` publishes already-populated ownership atomically. A regular-file
    # destination makes this an O_EXCL-like claim on both BSD and GNU. The
    # content check also rejects the odd existing-directory `ln src dir`
    # behavior without mistaking the nested link for ownership.
    if ln "${claimfile}" "${ownerfile}" 2>/dev/null; then
      owner_record="$(cat "${ownerfile}" 2>/dev/null || true)"
      if [[ "${owner_record}" == "${owner_token}" ]]; then
        if mkdir "${lockdir}" 2>/dev/null; then
          printf '%s\n' "${owner_pid}" >"${pidfile}" 2>/dev/null || true
          acquired=1
          break
        fi
        # A pre-sentinel/older process owns the directory. Release only our
        # exact sentinel and fall through to legacy-holder inspection.
        owner_record="$(cat "${ownerfile}" 2>/dev/null || true)"
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
      owner_record="$(cat "${ownerfile}" 2>/dev/null || true)"
      holder_pid="${owner_record%%:*}"
      observed_claim_name="${owner_record#*:}"
      observed_claim_name="${observed_claim_name%%:*}"
      if [[ "${holder_pid}" =~ ^[1-9][0-9]*$ \
          && "${observed_claim_name}" == "${ownerfile##*/}.claim."* \
          && "${observed_claim_name}" != */* \
          && "${owner_record}" == "${holder_pid}:${observed_claim_name}:"* ]]; then
        if ! kill -0 "${holder_pid}" 2>/dev/null; then
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
              prior_reap_record="$(cat "${prior_reap}" 2>/dev/null || true)"
              [[ "${prior_reap_record}" == "${owner_record}" ]] || continue
              prior_reaper_claim_name="${prior_reap#"${observed_claim}".reap.}"
              prior_reaper_claim="${lock_parent}/${prior_reaper_claim_name}"
              prior_reaper_record="$(cat "${prior_reaper_claim}" 2>/dev/null || true)"
              prior_reaper_pid="${prior_reaper_record%%:*}"
              prior_reaper_record_claim="${prior_reaper_record#*:}"
              prior_reaper_record_claim="${prior_reaper_record_claim%%:*}"
              if [[ "${prior_reaper_pid}" =~ ^[1-9][0-9]*$ \
                  && "${prior_reaper_claim_name}" == "${ownerfile##*/}.claim."* \
                  && "${prior_reaper_record_claim}" == "${prior_reaper_claim_name}" ]] \
                  && ! kill -0 "${prior_reaper_pid}" 2>/dev/null \
                  && mv "${prior_reap}" "${reap_claim}" 2>/dev/null; then
                rm -f "${prior_reaper_claim}" 2>/dev/null || true
                elected_reaper=1
                break
              fi
            done
          fi
          if [[ "${elected_reaper}" -eq 1 ]]; then
            cleanup_ok=1
            if [[ "$(cat "${reap_claim}" 2>/dev/null || true)" != "${owner_record}" \
                || "$(cat "${ownerfile}" 2>/dev/null || true)" != "${owner_record}" ]]; then
              cleanup_ok=0
            fi
            if [[ "${cleanup_ok}" -eq 1 && -d "${lockdir}" ]]; then
              legacy_pid="$(cat "${pidfile}" 2>/dev/null | tr -d '[:space:]' || true)"
              if [[ "${legacy_pid}" == "${holder_pid}" ]]; then
                rm -f "${pidfile}" 2>/dev/null || true
                rmdir "${lockdir}" 2>/dev/null || cleanup_ok=0
              fi
            fi
            if [[ "${cleanup_ok}" -eq 1 \
                && "$(cat "${ownerfile}" 2>/dev/null || true)" == "${owner_record}" ]] \
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
      holder_pid="$(cat "${pidfile}" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
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
  if [[ "${acquired}" -eq 1 \
      && "$(cat "${ownerfile}" 2>/dev/null || true)" == "${owner_token}" ]]; then
    _cleanup_orphan_lock_claims "${ownerfile}"
    cleanup_ok=1
    if [[ -d "${lockdir}" ]]; then
      rm -f "${pidfile}" 2>/dev/null || true
      rmdir "${lockdir}" 2>/dev/null || cleanup_ok=0
    fi
    # Canonical ownership blocks successors until release is complete. Remove
    # the election claim last: a crash before canonical unlink remains
    # recoverable; a crash after it leaves only an inert orphan claim.
    if [[ "${cleanup_ok}" -eq 1 \
        && "$(cat "${ownerfile}" 2>/dev/null || true)" == "${owner_token}" ]] \
        && rm -f "${ownerfile}" 2>/dev/null; then
      rm -f "${claimfile}" 2>/dev/null || true
    else
      log_anomaly "${tag}" "lock release cleanup failed"
      rc=1
    fi
  else
    rm -f "${claimfile}" 2>/dev/null || true
    log_anomaly "${tag}" "lock ownership changed before release"
    rc=1
  fi
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
  with_state_lock _write_state_batch_unlocked "$@"
}
