#!/usr/bin/env bash
#
# stop-dispatch.sh — the single managed Stop hook and stdout owner.
#
# Claude Code runs matching hook handlers in parallel, so four independent
# Stop entries never had the ordering their comments assumed. This dispatcher
# captures stdin once and runs guard -> timing -> canary -> archive in a
# deterministic order. A guard continuation checkpoints timing only; accepted
# releases alone receive finalizers and a merged user-visible receipt.

set -Eeuo pipefail

# Claude treats a hook process error as non-blocking. Install a dependency-light
# outer trap before sourcing shared code so a filesystem/source/jq failure can
# never silently fail open and release an uncertified ULW completion. Ordinary
# non-ULW turns fail open so a broken optional harness cannot take Claude down.
_OMC_DISPATCH_ULW=0
_stop_dispatch_fail_closed() {
  local rc="${1:-1}"
  trap - ERR
  if [[ "${_OMC_DISPATCH_ULW:-0}" != "1" ]]; then
    exit 0
  fi
  if declare -F _emit_compact_continuation >/dev/null 2>&1; then
    _emit_compact_continuation "[Stop certification] the Stop dispatcher failed internally (exit ${rc}), so this response is not certified." 2>/dev/null \
      || printf '%s\n' '{"decision":"block","reason":"oh-my-claude Stop dispatcher failed; response not certified."}'
  elif command -v jq >/dev/null 2>&1 && [[ -f "${_dispatch_state_file:-}" ]]; then
    # Shared state/locking failed to load, so mutating session_state.json here
    # would be an unlocked last-writer-wins overwrite. End this turn visibly,
    # preserve the addressed interval as active, and let the next prompt retry.
    local candidate="" emergency_message emergency_hook_json
    # The outer trap may run before shared sanitizers were sourced. Never
    # replay terminal-controlled/model text raw merely to preserve a candidate;
    # omit it until the normal, sanitized continuation path is available.
    if declare -F omc_redact_secrets >/dev/null 2>&1 \
        && declare -F _omc_strip_render_unsafe >/dev/null 2>&1; then
      emergency_hook_json="${HOOK_JSON:-}"
      [[ -n "${emergency_hook_json}" ]] || emergency_hook_json='{}'
      candidate="$(
        jq -r '.last_assistant_message // ""' \
          <<<"${emergency_hook_json}" 2>/dev/null \
          | omc_redact_secrets \
          | _omc_strip_render_unsafe \
          || true
      )"
      candidate="${candidate:0:5000}"
    fi
    if [[ -n "${candidate}" ]]; then
      printf -v emergency_message '%s\n%s\n%s\n%s' \
        "oh-my-claude · closeout paused after an internal dispatcher failure" \
        "Unresolved: Stop dispatcher failed internally (exit ${rc}); the active quality interval was not closed." \
        "UNCERTIFIED CANDIDATE:" \
        "${candidate}"
    else
      printf -v emergency_message '%s\n%s' \
        "oh-my-claude · closeout paused after an internal dispatcher failure" \
        "Unresolved: Stop dispatcher failed internally (exit ${rc}); the active quality interval was not closed. Candidate replay was omitted because the sanitizers were unavailable."
    fi
    jq -nc --arg msg "${emergency_message}" '{systemMessage:$msg}' 2>/dev/null \
      || printf '%s\n' '{"systemMessage":"oh-my-claude closeout paused after an internal dispatcher failure; the active interval was not closed."}'
  else
    printf '%s\n' '{"decision":"block","reason":"oh-my-claude Stop dispatcher failed; response not certified."}'
  fi
  exit 0
}
_stop_dispatch_err_trap() {
  _OMC_DISPATCH_ERR_RC=$?
  _stop_dispatch_fail_closed "${_OMC_DISPATCH_ERR_RC}"
}
trap _stop_dispatch_err_trap ERR

export OMC_LAZY_CLASSIFIER=1

_omc_dispatch_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_dispatch_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_dispatch_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_dispatch_source

# Bootstrap PATH before the first jq/state read. Caller PATH is repository-
# influenced in common development shells; trusting a fake jq here can turn an
# addressed active ULW Stop into an empty successful return before common.sh
# has a chance to pin its observer path. Preserve only immutable Nix-store bins
# (including trusted profile symlink resolutions) in addition to system bins.
_dispatch_observer_path="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
_OMC_HOOK_CALLER_PATH="${PATH:-}"
export _OMC_HOOK_CALLER_PATH
_dispatch_caller_path="${_OMC_HOOK_CALLER_PATH}"
_dispatch_old_ifs="${IFS}"
IFS=':'
for _dispatch_path_entry in ${_dispatch_caller_path}; do
  case "${_dispatch_path_entry}" in
    /run/current-system/sw/bin|/nix/store/*/bin|\
    "${HOME}"/.nix-profile/bin|"${HOME}"/.local/state/nix/profiles/*/bin|\
    /etc/profiles/per-user/*/bin)
      [[ -d "${_dispatch_path_entry}" ]] || continue
      _dispatch_path_canonical="$(
        cd "${_dispatch_path_entry}" 2>/dev/null && pwd -P
      )" || continue
      case "${_dispatch_path_canonical}" in
        /nix/store/*/bin)
          _dispatch_store_object="${_dispatch_path_canonical#/nix/store/}"
          _dispatch_store_object="${_dispatch_store_object%/bin}"
          [[ -n "${_dispatch_store_object}" \
              && "${_dispatch_store_object}" != */* ]] || continue
          case ":${_dispatch_observer_path}:" in
            *":${_dispatch_path_canonical}:"*) ;;
            *) _dispatch_observer_path="${_dispatch_observer_path}:${_dispatch_path_canonical}" ;;
          esac
          ;;
      esac
      ;;
  esac
done
IFS="${_dispatch_old_ifs}"
PATH="${_dispatch_observer_path}"
export PATH
unset _dispatch_caller_path _dispatch_old_ifs _dispatch_path_entry \
  _dispatch_path_canonical _dispatch_store_object

# Imported functions resolve before PATH, and a BASH_ENV-provided alias can do
# the same in shells that enable alias expansion.  Remove both before trusting
# the pinned observer path.  The test-only switch exercises the dependency-
# failure branch on developer machines where a trusted jq is always present;
# forcing this branch can only make an active Stop fail closed.
unset -f jq 2>/dev/null || true
unalias jq 2>/dev/null || true
HOOK_JSON="$(/bin/cat 2>/dev/null || true)"
if [[ "${OMC_TEST_STOP_FORCE_JQ_FAILURE:-0}" == "1" ]] \
    || ! command -v jq >/dev/null 2>&1 \
    || ! jq -e . <<<"${HOOK_JSON}" >/dev/null 2>&1; then
  _dispatch_sid_pattern='"session_id"[[:space:]]*:[[:space:]]*"([a-zA-Z0-9_.-]{1,128})"'
  _dispatch_fallback_sid=""
  if [[ "${HOOK_JSON}" =~ ${_dispatch_sid_pattern} ]]; then
    _dispatch_fallback_sid="${BASH_REMATCH[1]}"
  fi
  _dispatch_state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
  if [[ -n "${_dispatch_fallback_sid}" \
      && "${_dispatch_fallback_sid}" != *".."* \
      && ! "${_dispatch_fallback_sid}" =~ ^\.+$ \
      && -f "${_dispatch_state_root}/${_dispatch_fallback_sid}/.ulw_active" ]]; then
    printf '%s\n' '{"decision":"block","reason":"oh-my-claude Stop certification unavailable because jq is missing or failed; active response not certified."}'
  fi
  exit 0
fi
# A syntactically valid JSON string may still decode to NUL. Reject the whole
# Stop envelope before jq -r/Bash projection so an invalid identity cannot
# address another session and malformed completion prose cannot be certified.
if ! jq -e '
    type == "object"
    and all(.. | strings; index("\u0000") == null)
  ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
  printf '%s\n' \
    '{"decision":"block","reason":"oh-my-claude Stop certification refused a malformed lifecycle payload containing a decoded NUL or non-object envelope; no session or completion authority was trusted."}'
  exit 0
fi
SESSION_ID="$(jq -r '.session_id // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
[[ "${SESSION_ID:-}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || exit 0
[[ "${SESSION_ID}" != *".."* && ! "${SESSION_ID}" =~ ^\.+$ ]] || exit 0
_dispatch_state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
_dispatch_state_file="${_dispatch_state_root}/${SESSION_ID}/session_state.json"
_dispatch_session_marker="${_dispatch_state_root}/${SESSION_ID}/.ulw_active"
_dispatch_snapshot_valid=0
_dispatch_snapshot="$(jq -er '
  if type != "object"
      or (all(.. | strings; index("\u0000") == null) | not) then
    ["invalid", "migration"]
  else
    . as $state
    | (($state.ulw_enforcement_active // "") | tostring) as $active
    | (if ($state.workflow_mode // "") == "ultrawork" then
        if $active == "1" then "on"
        elif $active == "0" then "off"
        elif ($state.session_outcome // "") == "" then "on"
        else "off"
        end
      elif $active == "0" then "off"
      elif ($state.workflow_mode // "") == ""
          and ($state.session_outcome // "") == "" then "unknown"
      else "off"
      end) as $authority
    | (($state.ulw_enforcement_generation // "migration") | tostring) as $generation
    | if ($generation | test("^(migration|0|[1-9][0-9]{0,17})$")) then
        [$authority, $generation]
      else ["invalid", "migration"] end
  end
  | @tsv
' "${_dispatch_state_file}" 2>/dev/null \
  || printf '__OMC_INVALID_STATE__')"
if [[ "${_dispatch_snapshot}" != "__OMC_INVALID_STATE__" ]]; then
  _dispatch_snapshot_valid=1
else
  _dispatch_snapshot=$'unknown\tmigration'
fi
IFS=$'\t' read -r _dispatch_authority _dispatch_initial_generation \
  <<<"${_dispatch_snapshot}"
_dispatch_initial_generation="${_dispatch_initial_generation:-migration}"
if [[ "${_dispatch_authority}" == "invalid" ]]; then
  printf '%s\n' \
    '{"decision":"block","reason":"oh-my-claude Stop certification refused malformed session authority containing decoded NUL data or an invalid enforcement generation; no completion was released."}'
  exit 0
fi
if [[ "${_dispatch_authority}" == "on" \
    || ("${_dispatch_authority}" == "unknown" && -f "${_dispatch_session_marker}") ]]; then
  _OMC_DISPATCH_ULW=1
else
  # The global .ulw_active marker is only a legacy fast-path hint. Never let a
  # different ordinary session erase authority for an active ULW session;
  # enforcement follows the addressed session's workflow_mode instead.
  exit 0
fi

_dispatch_bootstrap_files=(
  "${SCRIPT_DIR}/common.sh"
  "${SCRIPT_DIR}/lib/state-io.sh"
  "${SCRIPT_DIR}/lib/verification.sh"
  "${SCRIPT_DIR}/lib/timing.sh"
)
for _dispatch_bootstrap_file in "${_dispatch_bootstrap_files[@]}"; do
  if [[ ! -f "${_dispatch_bootstrap_file}" \
      || ! -r "${_dispatch_bootstrap_file}" ]]; then
    # Bash can terminate immediately when the `.` special builtin cannot open
    # a file, bypassing ERR even under set -E. Validate every eager source
    # before invoking the builtin so partial installs still fail closed.
    _stop_dispatch_fail_closed 1
  fi
  if ! "${BASH}" -n "${_dispatch_bootstrap_file}" >/dev/null 2>&1; then
    # A syntax error in a sourced file has the same fatal-special-builtin shape
    # and likewise bypasses ERR. Parse each file independently (extra arguments
    # to `bash -n script` are script argv, not additional scripts).
    _stop_dispatch_fail_closed 2
  fi
done
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
# Any retained Agent-admission transaction intent predates every Stop-side
# write; `.ready` says only that its rollback snapshot finished copying.
# Check it before `ensure_session_dir`: even state repair or a verified WAIT
# marker update would advance authority around an admission whose pending/start
# ledgers may be only partially committed. This response is deliberately
# mutation-free; the exact /ulw-off lifecycle is the sole convergence path.
if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
  log_anomaly "stop-dispatch" \
    "interrupted Agent admission journal blocks Stop dispatcher" \
    2>/dev/null || true
  jq -nc \
    --arg reason "oh-my-claude Stop certification is paused because a prior Agent authorization was interrupted mid-transaction. No wait, continuation, provisional-closeout, or release state was committed. Run the exact /ulw-off reset, reactivate /ulw, and dispatch only the still-required role with a fresh identity." \
    --arg message "oh-my-claude paused closeout while interrupted Agent admission remains unresolved." '
      {decision:"block",reason:$reason,systemMessage:$message}
    '
  exit 0
fi
ensure_session_dir
if [[ "${OMC_TEST_STOP_FAIL_AFTER_COMMON:-0}" == "1" ]]; then
  false
fi
if [[ "${_dispatch_authority}" == "unknown" ]]; then
  # The exact per-session marker authorizes fail-closed recovery, but a
  # missing/corrupt/recovered metadata object is not authority to bind this old
  # Stop payload to whichever interval may exist now. Preserve the candidate
  # for audit and stop visibly without touching continuation/gate state.
  _ensure_valid_state
  _dispatch_unknown_candidate="$(json_get '.last_assistant_message')"
  closeout_record_provisional "${_dispatch_unknown_candidate}" "1" \
    2>/dev/null || true
  jq -nc \
    --arg reason "oh-my-claude Stop certification is unavailable because the addressed session authority is missing or recovered; this response is not certified. Continue in the same session after authority recovery." \
    --arg message "oh-my-claude paused closeout because its addressed session authority needs recovery." \
    '{decision:"block",reason:$reason,systemMessage:$message}'
  exit 0
fi
if [[ "${_dispatch_snapshot_valid}" -eq 1 ]]; then
  _OMC_ULW_CAPTURED_GENERATION="${_dispatch_initial_generation}"
  is_ultrawork_mode || exit 0
else
  # A malformed/missing addressed state with an exact session marker enters
  # the existing fail-closed recovery path. Shared state I/O may reconstruct a
  # safe active object while sourcing; freeze that recovered interval rather
  # than comparing it to the pre-recovery synthetic `migration` placeholder.
  capture_ulw_enforcement_interval || _stop_dispatch_fail_closed 1
fi
_ulw_before=1

# Deterministic test-only barrier for a queued old Stop callback crossing a
# release/reactivation boundary after it froze authority but before guard work.
if [[ -n "${OMC_TEST_STOP_CAPTURE_READY_FILE:-}" \
    && -n "${OMC_TEST_STOP_CAPTURE_RELEASE_FILE:-}" ]]; then
  printf 'ready\n' >"${OMC_TEST_STOP_CAPTURE_READY_FILE}"
  _dispatch_test_wait=0
  while [[ ! -f "${OMC_TEST_STOP_CAPTURE_RELEASE_FILE}" \
      && "${_dispatch_test_wait}" -lt 200 ]]; do
    sleep 0.05
    _dispatch_test_wait=$((_dispatch_test_wait + 1))
  done
fi

_run_stop_child() {
  local script="$1"
  shift
  if [[ "${script}" == "stop-guard.sh" ]]; then
    printf '%s' "${HOOK_JSON}" \
      | _OMC_ULW_CAPTURED_GENERATION="${_OMC_ULW_CAPTURED_GENERATION}" \
        OMC_LAZY_CLASSIFIER=0 OMC_LAZY_TIMING=0 \
      bash "${SCRIPT_DIR}/${script}" "$@"
  else
    printf '%s' "${HOOK_JSON}" \
      | _OMC_ULW_CAPTURED_GENERATION="${_OMC_ULW_CAPTURED_GENERATION}" \
        bash "${SCRIPT_DIR}/${script}" "$@"
  fi
}

_run_accepted_stop_child() {
  local script="$1" claim_id="$2"
  shift 2
  printf '%s' "${HOOK_JSON}" \
    | _OMC_ULW_CAPTURED_GENERATION="${_OMC_ULW_CAPTURED_GENERATION}" \
      OMC_STOP_ACCEPTED=1 \
      OMC_CLOSEOUT_FINALIZATION_CLAIM_ID="${claim_id}" \
    bash "${SCRIPT_DIR}/${script}" "$@"
}

_dispatch_write_stop_feedback_unlocked() {
  local feedback="$1"
  omc_enforcement_generation_matches_capture || return 1
  _write_state_batch_unlocked \
    "closeout_last_stop_feedback" "$(truncate_chars 7600 "${feedback}")" \
    "closeout_last_stop_feedback_ts" "$(now_epoch)"
}

_dispatch_remove_session_marker_unlocked() {
  omc_enforcement_generation_matches_capture || return 1
  rm -f "$(session_file ".ulw_active")" 2>/dev/null || true
}

_dispatch_remove_provisional_unlocked() {
  omc_enforcement_generation_matches_capture || return 1
  rm -f "$(session_file "provisional_closeouts.jsonl")" \
    2>/dev/null || true
}

# Stop payloads can remain queued while a prior ULW interval closes and a new
# interval starts in the same session.  Every wait-path state mutation must
# therefore compare the frozen interval again *after* acquiring the session
# lock.  An unlocked `is_ultrawork_mode` check followed by `write_state` leaves
# a check/use gap where an old Stop can clear the new interval's marker.
_dispatch_clear_background_marker_unlocked() {
  omc_enforcement_generation_matches_capture || return 1
  _write_state_batch_unlocked "bg_work_dispatched_ts" ""
}

_stop_modern_feedback_supported() {
  case "${OMC_STOP_FEEDBACK_MODE:-auto}" in
    modern) return 0 ;;
    legacy) return 1 ;;
  esac
  local raw version major minor patch
  command -v claude >/dev/null 2>&1 || return 1
  raw="$(claude --version 2>/dev/null || true)"
  version="$(printf '%s' "${raw}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -n "${version}" ]] || return 1
  IFS=. read -r major minor patch <<<"${version}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]] || return 1
  (( major > 2 )) && return 0
  (( major < 2 )) && return 1
  (( minor > 1 )) && return 0
  (( minor < 1 )) && return 1
  # Stop/SubagentStop additionalContext arrived in 2.1.163 (MessageDisplay was
  # already present in 2.1.152). Older/unparseable clients use the explicit
  # decision:block compatibility path.
  (( patch >= 163 ))
}

_emit_compact_continuation_unlocked() {
  local full_reason="$1" candidate_policy="${2:-preserve}" context_override="${3:-}" user_message="${4:-}"
  local compact context continuation_result continuation_count continuation_status continuation_rc=0
  local degraded_candidate exhausted_message current_candidate latest_candidate platform_cap terminal_at expected_generation
  # The complete continuation decision, including provisional capture and
  # stdout publication, runs while the session lock excludes prompt rotation.
  # Recheck the frozen interval at entry for re-entrant/error-path callers.
  omc_enforcement_generation_matches_capture || return 0
  current_candidate=""
  if [[ "${candidate_policy}" == "preserve" ]]; then
    current_candidate="$(json_get '.last_assistant_message')"
    closeout_record_provisional "${current_candidate}" "1" || true
  fi
  # Deterministic regression barrier after the first mutation-capable helper.
  # A test may rotate the state file directly while paused; production prompt
  # transitions cannot acquire this function's outer lock.
  if [[ -n "${OMC_TEST_STOP_CONTINUATION_MUTATION_READY_FILE:-}" \
      && -n "${OMC_TEST_STOP_CONTINUATION_MUTATION_RELEASE_FILE:-}" ]]; then
    printf 'ready\n' >"${OMC_TEST_STOP_CONTINUATION_MUTATION_READY_FILE}"
    _dispatch_continuation_mutation_test_count=0
    while [[ ! -f "${OMC_TEST_STOP_CONTINUATION_MUTATION_RELEASE_FILE}" \
        && "${_dispatch_continuation_mutation_test_count}" -lt 200 ]]; do
      sleep 0.05
      _dispatch_continuation_mutation_test_count=$((_dispatch_continuation_mutation_test_count + 1))
    done
  fi
  omc_enforcement_generation_matches_capture || return 0
  expected_generation="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  platform_cap="${CLAUDE_CODE_STOP_HOOK_BLOCK_CAP:-8}"
  if [[ "${platform_cap}" =~ ^[0-9]+$ ]]; then
    platform_cap=$((10#${platform_cap}))
  else
    platform_cap=8
  fi
  (( platform_cap > 0 )) || platform_cap=8
  terminal_at=$((platform_cap - 1))
  (( terminal_at >= 1 )) || terminal_at=1
  continuation_result="$(with_state_lock _closeout_increment_dispatch_continuations_unlocked "${terminal_at}" "${platform_cap}" "${expected_generation}" 2>/dev/null)" || continuation_rc=$?
  if [[ "${continuation_rc}" -ne 0 ]]; then
    log_anomaly "stop-dispatch" "continuation counter could not commit rc=${continuation_rc}; ending explicitly before platform cap" 2>/dev/null || true
    degraded_candidate="$(_closeout_degraded_candidate_block "${current_candidate}")"
    printf -v exhausted_message '%s\n%s\n%s' \
      "oh-my-claude · closeout paused because continuation accounting failed" \
      "Unresolved: $(closeout_compact_gate_feedback "${full_reason}")" \
      "The active quality interval was not closed. ${degraded_candidate:-No completion candidate was available to replay.}"
    emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
    return 0
  fi
  IFS='|' read -r continuation_count continuation_status <<<"${continuation_result}"
  [[ "${continuation_count}" =~ ^[0-9]+$ ]] || continuation_count=1
  if [[ "${continuation_status}" == "interval-changed" ]]; then
    return 0
  fi
  if (( continuation_count >= terminal_at )); then
    latest_candidate=""
    if [[ "${candidate_policy}" == "preserve" ]]; then
      latest_candidate="$(_closeout_latest_provisional)"
      [[ -n "${latest_candidate}" ]] || latest_candidate="${current_candidate}"
    fi
    degraded_candidate="$(_closeout_degraded_candidate_block "${latest_candidate}")"
    if [[ "${continuation_status}" == "completion-busy" ]]; then
      printf -v exhausted_message '%s\n%s\n%s' \
        "oh-my-claude · closeout paused before Claude Code's Stop-continuation ceiling" \
        "Unresolved: a subagent completion is still publishing evidence; the active quality interval was not closed." \
        "${degraded_candidate:-No completion candidate was available to replay.}"
      emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
      return 0
    fi
    if [[ "${continuation_status}" == "generation-changed" ]]; then
      printf -v exhausted_message '%s\n%s\n%s' \
        "oh-my-claude · closeout paused before Claude Code's Stop-continuation ceiling" \
        "Unresolved: work/evidence changed after the guard returned; the active quality interval was not closed." \
        "${degraded_candidate:-No completion candidate was available to replay.}"
      emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
      return 0
    fi
    if [[ "${continuation_status}" != "exhausted" ]]; then
      printf -v exhausted_message '%s\n%s\n%s' \
        "oh-my-claude · closeout paused because terminal accounting was inconclusive" \
        "Unresolved: the active quality interval was not closed." \
        "${degraded_candidate:-No completion candidate was available to replay.}"
      emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
      return 0
    fi
    with_state_lock _dispatch_remove_session_marker_unlocked \
      >/dev/null 2>&1 || return 0
    printf -v exhausted_message '%s\n%s\n%s' \
      "oh-my-claude · closeout ended explicitly before Claude Code's Stop-continuation ceiling" \
      "Unresolved: $(closeout_compact_gate_feedback "${full_reason}")" \
      "${degraded_candidate:-No completion candidate was available to replay.}"
    emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
    return 0
  fi
  compact="$(closeout_compact_gate_feedback "${full_reason}")"
  if [[ -n "${context_override}" ]]; then
    context="${context_override}"
  else
    context="oh-my-claude closeout check: ${compact} Continue working; do NOT emit another completion summary. Run \`bash \"\$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh\" \"${SESSION_ID}\"\` if exact recovery context was not already injected. When it reports READY, write one complete cumulative replacement covering the whole original objective—not a delta from an earlier summary."
  fi
  context="$(truncate_chars 900 "${context}")"
  if _stop_modern_feedback_supported; then
    jq -nc --arg ctx "${context}" --arg msg "${user_message}" '
      {hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}
      + if $msg == "" then {} else {systemMessage:$msg} end
    '
  else
    jq -nc --arg reason "${context}" --arg msg "${user_message}" '
      {decision:"block",reason:$reason}
      + if $msg == "" then {} else {systemMessage:$msg} end
    '
  fi
}

_emit_compact_continuation() {
  local rc=0 full_reason="${1:-Closeout is not ready.}"
  local candidate_policy="${2:-preserve}" current_candidate="" degraded_candidate
  local exhausted_message
  # Holding the state lock through the tiny stdout emission is intentional:
  # otherwise G2 can begin after the last check but before Claude Code receives
  # a stale G1 continuation. Re-entrant callers are handled by with_state_lock.
  with_state_lock _emit_compact_continuation_unlocked "$@" || rc=$?
  [[ "${rc}" -ne 0 ]] || return 0
  omc_enforcement_generation_matches_capture || return 0
  is_ultrawork_mode || return 0
  if omc_publication_recovery_needed "${SESSION_ID}"; then
    _emit_publication_recovery_pending
    return 0
  fi
  # The mutex itself was unavailable, so continuation/provisional accounting
  # cannot be committed. Preserve the current candidate in a mutation-free
  # degraded receipt instead of losing it to the outer ERR fallback.
  if [[ "${candidate_policy}" == "preserve" ]]; then
    current_candidate="$(json_get '.last_assistant_message')"
  fi
  degraded_candidate="$(_closeout_degraded_candidate_block \
    "${current_candidate}")"
  printf -v exhausted_message '%s\n%s\n%s' \
    "oh-my-claude · closeout paused because continuation accounting failed" \
    "Unresolved: $(closeout_compact_gate_feedback "${full_reason}")" \
    "The active quality interval was not closed. ${degraded_candidate:-No completion candidate was available to replay.}"
  emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
}

# A corrupt or otherwise unrecoverable publication journal must remain the
# authority for its overlapping state.  The ordinary continuation helper
# cannot be used in that case because it intentionally mutates provisional and
# continuation accounting under the same publication fence.  Emit a small,
# mutation-free Stop response so the active interval remains visibly closed
# while the next lifecycle hook retries journal recovery.
_emit_publication_recovery_pending() {
  local context user_message
  context="oh-my-claude closeout is paused because a subagent completion is still publishing evidence or its publication transaction still requires recovery. No wait recovery or continuation state was committed. Retry after the publication journal is repaired; do not abandon, rebind, or treat the pending evidence as accepted."
  user_message="oh-my-claude paused closeout while subagent publication recovery remains pending."
  if _stop_modern_feedback_supported; then
    jq -nc --arg ctx "${context}" --arg msg "${user_message}" '
      {hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx},
       systemMessage:$msg}
    '
  else
    jq -nc --arg reason "${context}" --arg msg "${user_message}" '
      {decision:"block",reason:$reason,systemMessage:$msg}
    '
  fi
}

# Claude Code terminates a turn after a bounded run of consecutive Stop
# continuations. End one attempt earlier with an explicit, visible degraded
# receipt so a display-suppressed candidate can never disappear behind the
# platform cap. Fresh execution routing resets this counter.
_closeout_increment_dispatch_continuations_unlocked() {
  local terminal_at="${1:-7}" platform_cap="${2:-8}" expected_generation="${3:-}"
  local count pending_file cutoff current_generation
  if [[ "${terminal_at}" =~ ^[0-9]+$ ]]; then terminal_at=$((10#${terminal_at})); else terminal_at=7; fi
  if [[ "${platform_cap}" =~ ^[0-9]+$ ]]; then platform_cap=$((10#${platform_cap})); else platform_cap=8; fi
  (( terminal_at > 0 )) || terminal_at=7
  (( platform_cap > 0 )) || platform_cap=8
  if ! omc_enforcement_generation_matches_capture; then
    printf '0|interval-changed'
    return 0
  fi
  if ! is_ultrawork_mode; then
    printf '0|interval-changed'
    return 0
  fi
  count="$(read_state "closeout_dispatch_continuations" 2>/dev/null || true)"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  current_generation="$(closeout_readiness_fingerprint 2>/dev/null || true)"
  if [[ -z "${expected_generation}" || -z "${current_generation}" \
      || "${current_generation}" != "${expected_generation}" ]]; then
    _write_state_batch_unlocked "closeout_dispatch_continuations" "${count}" || return 1
    printf '%s|generation-changed' "${count}"
    return 0
  fi
  if (( count >= terminal_at )); then
    pending_file="$(session_file "pending_agents.jsonl")"
    cutoff="$(( $(now_epoch) - 120 ))"
    if [[ -s "${pending_file}" ]] && jq -Rse --argjson cutoff "${cutoff}" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {}) as $row
          | (($row.completion_claim_id // "") | length) > 0
          and (($row.completion_claim_effects_complete // false) != true)
          and (($row.completion_claim_ts // 0) >= $cutoff))
      ' "${pending_file}" >/dev/null 2>&1; then
      _write_state_batch_unlocked "closeout_dispatch_continuations" "${count}" || return 1
      printf '%s|completion-busy' "${count}"
      return 0
    fi
    _write_state_batch_unlocked \
      "closeout_dispatch_continuations" "${count}" \
      "guard_exhausted" "$(now_epoch)" \
      "guard_exhausted_detail" "platform_stop_continuation_pre_cap=${terminal_at};configured_cap=${platform_cap}" \
      "session_outcome" "exhausted" \
      "ulw_enforcement_active" "0" || return 1
    printf '%s|exhausted' "${count}"
    return 0
  fi
  _write_state_batch_unlocked "closeout_dispatch_continuations" "${count}" || return 1
  printf '%s|continue' "${count}"
}

_closeout_latest_provisional() {
  local file cycle
  file="$(session_file "provisional_closeouts.jsonl")"
  cycle="$(read_state "review_cycle_id" 2>/dev/null || true)"
  [[ -s "${file}" ]] || return 0
  jq -rs --arg cycle "${cycle}" '
    [ .[] | select(($cycle == "") or ((.review_cycle_id // "") == $cycle))
      | (.message // "") | select(length > 0) ]
    | sort_by(length) | reverse | .[0] // ""
  ' "${file}" 2>/dev/null || true
}

_closeout_degraded_candidate_block() {
  local candidate="${1:-}"
  [[ -n "${candidate}" ]] || return 0
  candidate="$(
    closeout_preserve_ends "${candidate}" 5200 \
      | omc_redact_secrets \
      | _omc_strip_render_unsafe
  )"
  printf 'UNCERTIFIED CUMULATIVE CANDIDATE (preserved for audit; quality gaps remain):\n%s' "${candidate}"
}

_stop_wait_final_line() {
  printf '%s\n' "$1" \
    | tr -d '\r' \
    | awk 'NF { current = $0 } END { print current }' \
    | _omc_strip_render_unsafe
}

_false_wait_recovery_context() {
  local wait_kind="$1" wait_message="${2:-}" pending_file pending_row="" agent_type="" native_id=""
  local claim_id="" claim_ts=0 claim_effects_complete=false now label="the required worker"
  local current_cycle_id current_objective_ts
  # Called under the session lock. The payload's captured interval, not merely
  # the currently active mode, owns pending-row interpretation and guidance.
  omc_enforcement_generation_matches_capture || return 1
  is_ultrawork_mode || return 1
  if [[ "${wait_kind}" == "scheduled" ]]; then
    printf 'Claude Code reports no scheduled wake matching the promised check, so this session will not resume on that schedule. Continue now by running the check or registering the intended wake. Do not wait, poll, resume an unrelated agent, or ask the user to intervene.'
    return 0
  fi
  wait_message="$(printf '%s' "${wait_message}" \
    | _omc_strip_render_unsafe | tr '[:upper:]' '[:lower:]')"
  wait_message="$(truncate_chars 1600 "${wait_message}")"
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
  current_objective_ts="$(read_state "review_cycle_prompt_ts")"
  if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
    current_objective_ts="$(read_state "last_user_prompt_ts")"
  fi
  [[ "${current_objective_ts}" =~ ^[0-9]+$ ]] || current_objective_ts=0
  pending_file="$(session_file "pending_agents.jsonl")"
  if [[ -s "${pending_file}" && ! -L "${pending_file}" ]]; then
    pending_row="$(jq -Rsc --arg wait "${wait_message}" \
      --argjson cycle "${current_cycle_id}" \
      --argjson objective_ts "${current_objective_ts}" '
      ([split("\n")[] | select(length > 0)
        | (try fromjson catch {})
        | select((.review_dispatch_abandoned // false) != true)
        | select($cycle == 0 or (.objective_cycle_id // -1) == $cycle)
        | select($objective_ts == 0 or (.objective_prompt_ts // -1) == $objective_ts)]
       | sort_by(.ts // 0)) as $rows
      | ([$rows[]
          | ((.agent_type // "") | split(":") | last | ascii_downcase) as $short
          | ($short | gsub("-"; " ")) as $spaced
          | select(($short | length) > 0
              and (($wait | contains($short)) or ($wait | contains($spaced))))]
         | last) // {}
    ' "${pending_file}" 2>/dev/null || true)"
  fi
  if [[ -n "${pending_row}" && "${pending_row}" != "{}" ]] \
      && ! omc_pending_stateful_generation_current "${pending_row}"; then
    pending_row=""
  fi
  if [[ -n "${pending_row}" && "${pending_row}" != "{}" ]]; then
    agent_type="$(jq -r '.agent_type // empty' <<<"${pending_row}" 2>/dev/null || true)"
    native_id="$(jq -r '.native_agent_id // empty' <<<"${pending_row}" 2>/dev/null || true)"
    agent_type="$(printf '%s' "${agent_type}" | _omc_strip_render_unsafe | tr '\r\n' '  ')"
    native_id="$(printf '%s' "${native_id}" | _omc_strip_render_unsafe | tr '\r\n' '  ')"
    agent_type="$(truncate_chars 80 "${agent_type}")"
    native_id="$(truncate_chars 128 "${native_id}")"
    [[ "${agent_type}" =~ ^[A-Za-z0-9._:-]{1,80}$ ]] || agent_type=""
    [[ "${native_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || native_id=""
    if [[ -n "${agent_type}" && -n "${native_id}" ]]; then
      label="the pending ${agent_type} (native agent ${native_id})"
    elif [[ -n "${agent_type}" ]]; then
      label="the pending ${agent_type}"
    fi
    claim_id="$(jq -r '.completion_claim_id // empty' \
      <<<"${pending_row}" 2>/dev/null || true)"
    claim_ts="$(jq -r '.completion_claim_ts // 0' \
      <<<"${pending_row}" 2>/dev/null || true)"
    claim_effects_complete="$(jq -r '.completion_claim_effects_complete // false' \
      <<<"${pending_row}" 2>/dev/null || true)"
  fi
  [[ "${claim_ts}" =~ ^[0-9]+$ ]] || claim_ts=0
  now="$(now_epoch)"
  if [[ -n "${claim_id}" && "${claim_effects_complete}" != "true" \
      && "${claim_ts}" -gt 0 \
      && "${now}" -ge "${claim_ts}" && $((now - claim_ts)) -le 120 ]]; then
    printf 'Claude Code reports no live %s wake source matching the promised worker, but %s is still publishing its SubagentStop evidence. Continue now without abandoning or rebinding that call; re-evaluate its reviewer/plan state after hook settlement. Do not repeat the auto-resume promise, poll, or ask the user to intervene.' \
      "${wait_kind}" "${label}"
  elif [[ -n "${claim_id}" && "${claim_effects_complete}" == "true" ]]; then
    printf 'Claude Code reports no live %s wake source matching the promised worker, but %s has already published its claim-scoped effects. Do not resume, rebind, or dispatch from this stale wait. Re-evaluate the committed reviewer/plan state and continue from the current gate.' \
      "${wait_kind}" "${label}"
  elif [[ -n "${claim_id}" ]]; then
    printf 'Claude Code reports no live %s wake source matching the promised worker, and %s retains an expired incomplete completion claim. Do not resume that call. Continue through the explicit rebind path and dispatch a fresh equivalent only if the current gate still requires the role.' \
      "${wait_kind}" "${label}"
  elif [[ -n "${native_id}" ]]; then
    printf 'Claude Code reports no live %s wake source matching the promised worker, so no relevant notification will arrive. Continue now: resume %s with SendMessage using the retained native ID; if that transcript cannot resume, explicitly rebind and dispatch a fresh equivalent. Do not wait, poll, repeat the auto-resume promise, or ask the user to intervene.' \
      "${wait_kind}" "${label}"
  else
    printf 'Claude Code reports no live %s wake source matching the promised worker, so no relevant notification will arrive. Continue now by dispatching the fresh reviewer or worker required by the current gate. Do not wait, poll, repeat the auto-resume promise, or ask the user to intervene.' \
      "${wait_kind}"
  fi
}

_wait_expected_pending_identity() {
  local wait_message="$1" pending_file row agent_type native_id
  local current_cycle_id current_objective_ts
  is_ultrawork_mode || return 1
  wait_message="$(printf '%s' "${wait_message}" \
    | _omc_strip_render_unsafe | tr '[:upper:]' '[:lower:]')"
  wait_message="$(truncate_chars 1600 "${wait_message}")"
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
  current_objective_ts="$(read_state "review_cycle_prompt_ts")"
  if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
    current_objective_ts="$(read_state "last_user_prompt_ts")"
  fi
  [[ "${current_objective_ts}" =~ ^[0-9]+$ ]] || current_objective_ts=0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" && ! -L "${pending_file}" ]] || return 1
  row="$(jq -Rsc --arg wait "${wait_message}" \
    --argjson cycle "${current_cycle_id}" \
    --argjson objective_ts "${current_objective_ts}" '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch {})
      | select((.review_dispatch_abandoned // false) != true)
      | select($cycle == 0 or (.objective_cycle_id // -1) == $cycle)
      | select($objective_ts == 0 or (.objective_prompt_ts // -1) == $objective_ts)
      | ((.agent_type // "") | split(":") | last | ascii_downcase) as $short
      | ($short | gsub("-"; " ")) as $spaced
      | select(($short | length) > 0
          and (($wait | contains($short)) or ($wait | contains($spaced))))]
    | sort_by(.ts // 0) | last // {}
  ' "${pending_file}" 2>/dev/null || true)"
  [[ -n "${row}" && "${row}" != "{}" ]] || return 1
  omc_pending_stateful_generation_current "${row}" || return 1
  agent_type="$(jq -r '.agent_type // empty | split(":") | last' \
    <<<"${row}" 2>/dev/null || true)"
  native_id="$(jq -r '.native_agent_id // empty' \
    <<<"${row}" 2>/dev/null || true)"
  [[ "${agent_type}" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || return 1
  [[ -z "${native_id}" || "${native_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] \
    || return 1
  printf '%s|%s' "${agent_type}" "${native_id}"
}

_wait_named_omc_agent() {
  local message="$1" lower agent spaced
  lower="$(printf '%s' "${message}" \
    | _omc_strip_render_unsafe | tr '[:upper:]' '[:lower:]')"
  lower="$(truncate_chars 1600 "${lower}")"
  for agent in quality-reviewer editor-critic excellence-reviewer \
      release-reviewer metis briefing-analyst design-reviewer \
      abstraction-critic rigor-reviewer quality-planner prometheus \
      code-reviewer; do
    spaced="${agent//-/ }"
    if [[ "${lower}" == *"${agent}"* || "${lower}" == *"${spaced}"* ]]; then
      printf '%s' "${agent}"
      return 0
    fi
  done
  return 1
}

_scheduled_wait_has_matching_cron() {
  local message="$1" lower
  lower="$(printf '%s' "${message}" \
    | _omc_strip_render_unsafe | tr '[:upper:]' '[:lower:]')"
  lower="$(truncate_chars 1600 "${lower}")"
  jq -e --arg wait "${lower}" '
    def significant_words:
      [scan("[a-z0-9][a-z0-9_-]{4,}")
       | select(IN("scheduled","waiting","session","check","every",
                   "please") | not)];
    ($wait | [scan("[a-z0-9][a-z0-9_-]{4,}")]) as $wait_words
    | any(.session_crons[];
      ((.id // "") | ascii_downcase) as $id
      | ((.prompt // "") | ascii_downcase | significant_words) as $words
      | (($id | length) > 0 and ($wait | contains($id)))
        or (($words | length) > 0
          and all($words[]; . as $word | ($wait_words | index($word)) != null)))
  ' <<<"${HOOK_JSON}" >/dev/null 2>&1
}

_background_wait_has_matching_task() {
  local message="$1" lower
  lower="$(printf '%s' "${message}" \
    | _omc_strip_render_unsafe | tr '[:upper:]' '[:lower:]')"
  lower="$(truncate_chars 1600 "${lower}")"
  jq -e --arg wait "${lower}" '
    def terminal:
      ((.status // "") | ascii_downcase)
      | IN("completed","complete","done","failed","error","killed",
           "stopped","cancelled","canceled","idle");
    def significant_words:
      [scan("[a-z0-9][a-z0-9_-]{3,}")
       | select(IN("waiting","resume","automatically","nothing","action",
                   "running","background","finish","finishes","when",
                   "will","work","task","needed","please","user",
                   "done","wave") | not)];
    ($wait | significant_words) as $words
    | ($words | length) > 0
      and any(.background_tasks[];
        (terminal | not)
        and ([.id // "", .task_id // "", .description // "",
              .command // "", .agent_type // ""]
             | join(" ") | ascii_downcase
             | [scan("[a-z0-9][a-z0-9_-]{3,}")]) as $corpus_words
        | all($words[]; . as $word | ($corpus_words | index($word)) != null))
  ' <<<"${HOOK_JSON}" >/dev/null 2>&1
}

# A waiting sentence is nonterminal only when the same Stop payload proves a
# real future wake. Present-empty registries are authoritative: pending ledger
# rows preserve recovery identity, but cannot promise a notification from an
# idle task. Omitted fields retain the old-client guard path.
_wait_claim_line="$(_stop_wait_final_line \
  "$(json_get '.last_assistant_message')")"
_wait_claim_line="$(truncate_chars 1600 "${_wait_claim_line}")"
_wait_claim_kind="$(omc_stop_wait_claim_kind \
  "${_wait_claim_line}" 2>/dev/null || true)"
if [[ -n "${_wait_claim_kind}" ]]; then
  _background_state="$(omc_stop_runtime_array_state \
    "${HOOK_JSON}" "background_tasks")"
  _cron_state="$(omc_stop_runtime_array_state "${HOOK_JSON}" "session_crons")"
  [[ "${_background_state}" != "malformed" ]] || \
    log_anomaly "stop-dispatch" "malformed Stop background_tasks registry" 2>/dev/null || true
  [[ "${_cron_state}" != "malformed" ]] || \
    log_anomaly "stop-dispatch" "malformed Stop session_crons registry" 2>/dev/null || true

  _wait_runtime_state="${_background_state}"
  [[ "${_wait_claim_kind}" != "scheduled" ]] \
    || _wait_runtime_state="${_cron_state}"
  if [[ "${_wait_claim_kind}" == "scheduled" \
      && "${_wait_runtime_state}" == "live" ]] \
      && ! _scheduled_wait_has_matching_cron \
        "${_wait_claim_line}"; then
    _wait_runtime_state="empty"
    log_anomaly "stop-dispatch" \
      "scheduled wait claim did not match any registered cron" \
      2>/dev/null || true
  fi
  if [[ "${_wait_claim_kind}" == "background" \
      && "${_wait_runtime_state}" == "live" ]]; then
    _wait_named_agent="$(_wait_named_omc_agent \
      "${_wait_claim_line}" 2>/dev/null || true)"
    _wait_expected_identity="$(with_state_lock \
      _wait_expected_pending_identity \
      "${_wait_claim_line}" 2>/dev/null || true)"
    if [[ -n "${_wait_named_agent}" \
        && -z "${_wait_expected_identity}" ]]; then
      _wait_runtime_state="empty"
      log_anomaly "stop-dispatch" \
        "named OMC wait had no current causal pending identity" \
        2>/dev/null || true
    elif [[ -n "${_wait_expected_identity}" ]]; then
      IFS='|' read -r _wait_expected_type _wait_expected_native_id \
        <<<"${_wait_expected_identity}"
      if ! jq -e --arg type "${_wait_expected_type}" \
          --arg id "${_wait_expected_native_id}" '
          any(.background_tasks[];
            ((((.status // "") | ascii_downcase)
              | IN("completed","complete","done","failed","error","killed",
                   "stopped","cancelled","canceled","idle")) | not)
            and (if $id != "" then
                   ((.id // .task_id // "") as $runtime_id
                    | if $runtime_id != "" then $runtime_id == $id
                      else (((.agent_type // "") | split(":") | last)
                            == $type)
                      end)
                 else
                   (((.agent_type // "") | split(":") | last) == $type)
                 end))
        ' <<<"${HOOK_JSON}" >/dev/null 2>&1; then
        _wait_runtime_state="empty"
        log_anomaly "stop-dispatch" \
          "wait claim named ${_wait_expected_type}, but only unrelated background tasks were live" \
          2>/dev/null || true
      fi
    elif ! _background_wait_has_matching_task "${_wait_claim_line}"; then
      _wait_runtime_state="empty"
      log_anomaly "stop-dispatch" \
        "background wait claim did not match any live task" \
        2>/dev/null || true
    fi
  fi
  # The Stop payload may have queued across release/reactivation. Recheck the
  # captured enforcement interval after correlation and before any wait-state
  # mutation; a stale callback is inert in the newer interval.
  is_ultrawork_mode || exit 0
  if [[ "${_wait_runtime_state}" == "live" ]]; then
    # Deterministic regression barrier: the old callback has completed its
    # unlocked correlation/check, but has not acquired the mutation lock yet.
    if [[ -n "${OMC_TEST_STOP_WAIT_MUTATION_READY_FILE:-}" \
        && -n "${OMC_TEST_STOP_WAIT_MUTATION_RELEASE_FILE:-}" ]]; then
      printf 'ready\n' >"${OMC_TEST_STOP_WAIT_MUTATION_READY_FILE}"
      _dispatch_wait_mutation_test_count=0
      while [[ ! -f "${OMC_TEST_STOP_WAIT_MUTATION_RELEASE_FILE}" \
          && "${_dispatch_wait_mutation_test_count}" -lt 200 ]]; do
        sleep 0.05
        _dispatch_wait_mutation_test_count=$((_dispatch_wait_mutation_test_count + 1))
      done
    fi
    if ! with_state_lock _dispatch_clear_background_marker_unlocked \
        >/dev/null 2>&1; then
      omc_enforcement_generation_matches_capture || exit 0
    fi
    record_gate_event "stop-wait" "verified-live" \
      "kind=${_wait_claim_kind}" 2>/dev/null || true
    # First-class WAIT: no quality gates, prompt-end accounting, continuation
    # slot, finalizer, provisional closeout, or terminal outcome runs here.
    exit 0
  elif [[ "${_wait_runtime_state}" == "empty" ]]; then
    if ! with_state_lock _dispatch_clear_background_marker_unlocked \
        >/dev/null 2>&1; then
      omc_enforcement_generation_matches_capture || exit 0
    fi
    if [[ -n "${OMC_TEST_STOP_FALSE_WAIT_CONTEXT_READY_FILE:-}" \
        && -n "${OMC_TEST_STOP_FALSE_WAIT_CONTEXT_RELEASE_FILE:-}" ]]; then
      printf 'ready\n' >"${OMC_TEST_STOP_FALSE_WAIT_CONTEXT_READY_FILE}"
      _dispatch_false_wait_test_count=0
      while [[ ! -f "${OMC_TEST_STOP_FALSE_WAIT_CONTEXT_RELEASE_FILE}" \
          && "${_dispatch_false_wait_test_count}" -lt 200 ]]; do
        sleep 0.05
        _dispatch_false_wait_test_count=$((_dispatch_false_wait_test_count + 1))
      done
    fi
    if ! _false_wait_context="$(OMC_PUBLICATION_STOP_WAIT_INTERNAL=1 \
        with_state_lock \
        _false_wait_recovery_context \
        "${_wait_claim_kind}" "${_wait_claim_line}")"; then
      omc_enforcement_generation_matches_capture || exit 0
      is_ultrawork_mode || exit 0
      _false_wait_context="Claude Code reports no matching live wake, but oh-my-claude could not acquire the session-state lock to resolve the retained worker safely. Do not wait, poll, integrate an unverified result, or ask the user to intervene. Re-evaluate the current gate after the lock clears."
    fi
    if [[ "${_wait_claim_kind}" == "scheduled" ]]; then
      _false_wait_system_message="oh-my-claude noticed the scheduled check was not registered and is recovering automatically."
    else
      _false_wait_system_message="oh-my-claude could not find live background work matching this wait and is recovering automatically."
    fi
    record_gate_event "stop-wait" "dead-wait-recovered" \
      "kind=${_wait_claim_kind}" 2>/dev/null || true
    if ! OMC_PUBLICATION_STOP_WAIT_INTERNAL=1 _emit_compact_continuation \
        "[Dead wait] no live ${_wait_claim_kind} wake source exists." \
        "discard" "${_false_wait_context}" \
        "${_false_wait_system_message}"; then
      omc_enforcement_generation_matches_capture || exit 0
      is_ultrawork_mode || exit 0
      _emit_publication_recovery_pending
    fi
    exit 0
  fi
fi

guard_out=""
guard_rc=0
guard_out="$(_run_stop_child "stop-guard.sh")" || guard_rc=$?

# The child inherits the frozen generation, and the parent verifies it again
# after the child returns. A G1 Stop callback that queued across release→G2 is
# therefore inert even when the old guard returned an empty/no-op response.
omc_enforcement_generation_matches_capture || exit 0

if [[ "${guard_rc}" -ne 0 ]]; then
  log_anomaly "stop-dispatch" "stop-guard crashed rc=${guard_rc}; release refused" 2>/dev/null || true
  _emit_compact_continuation "[Stop certification] the quality guard crashed (exit ${guard_rc}), so this response is not certified."
  exit 0
fi

guard_is_block=0
if [[ -n "${guard_out}" ]]; then
  if ! jq -s -e 'length == 1 and (.[0] | type == "object")' <<<"${guard_out}" >/dev/null 2>&1; then
    log_anomaly "stop-dispatch" "stop-guard emitted invalid/multiple JSON; release refused" 2>/dev/null || true
    _emit_compact_continuation "[Stop certification] the quality guard returned an invalid response, so this response is not certified."
    exit 0
  fi
  guard_out="$(jq -sc '.[0]' <<<"${guard_out}")"
  if jq -e '.decision == "block" or ((.hookSpecificOutput.additionalContext // "") != "")' <<<"${guard_out}" >/dev/null 2>&1; then
    guard_is_block=1
  fi
fi

if [[ "${guard_is_block}" -eq 1 ]]; then
  full_reason="$(jq -r '.reason // .hookSpecificOutput.additionalContext // "Closeout is not ready."' <<<"${guard_out}" 2>/dev/null || printf 'Closeout is not ready.')"
  if ! with_state_lock _dispatch_write_stop_feedback_unlocked \
      "${full_reason}" 2>/dev/null; then
    omc_enforcement_generation_matches_capture || exit 0
    _emit_compact_continuation \
      "[Stop certification] the guard result could not be recorded safely, so this response is not certified."
    exit 0
  fi
  # The guard stamped this exact attempt. stop-time-summary therefore captures
  # token/economics deltas but suppresses prompt_end and the visible card.
  _run_stop_child "stop-time-summary.sh" >/dev/null 2>&1 || true
  _emit_compact_continuation "${full_reason}"
  exit 0
fi

# Empty guard output is a normal clean pass. A non-empty object may carry a
# scorecard/degraded-release systemMessage; preserve it, but never relabel an
# exhausted/skip release as "all gates passed".
omc_enforcement_generation_matches_capture || exit 0
outcome="$(read_state "session_outcome" 2>/dev/null || true)"

# The guard accepted this Stop. Unused durable-taste authority belongs only to
# the turn that just ended; a later wake/resume needs a fresh user command.
_dispatch_clear_quality_constitution_authorization_unlocked() {
  omc_enforcement_generation_matches_capture || return 1
  omc_clear_quality_constitution_authorization_unlocked
}
# Deterministic regression barrier for the guard-pass/check-to-lock window.
# The test changes interval authority and issues a new grant while the old Stop
# is paused here; the under-lock generation check must preserve that grant.
if [[ -n "${OMC_TEST_STOP_AUTH_CLEAR_READY_FILE:-}" \
    && -n "${OMC_TEST_STOP_AUTH_CLEAR_RELEASE_FILE:-}" ]]; then
  printf 'ready\n' >"${OMC_TEST_STOP_AUTH_CLEAR_READY_FILE}"
  _dispatch_auth_clear_test_count=0
  while [[ ! -f "${OMC_TEST_STOP_AUTH_CLEAR_RELEASE_FILE}" \
      && "${_dispatch_auth_clear_test_count}" -lt 200 ]]; do
    sleep 0.05
    _dispatch_auth_clear_test_count=$((_dispatch_auth_clear_test_count + 1))
  done
fi
if ! with_state_lock _dispatch_clear_quality_constitution_authorization_unlocked \
    >/dev/null 2>&1; then
  omc_enforcement_generation_matches_capture || exit 0
  log_anomaly "stop-dispatch" \
    "accepted Stop authorization invalidation failed; finalization refused" \
    2>/dev/null || true
  _emit_compact_continuation \
    "[Quality Constitution authority] the unused one-turn authorization could not be invalidated safely, so accepted-Stop finalization was refused. Resolve the session-state lock or unsafe authorization node, then re-run the closeout check; do not reuse the old apply-authorized command."
  exit 0
fi

guard_message=""
if [[ -n "${guard_out}" ]]; then
  guard_message="$(jq -r '.systemMessage // empty' <<<"${guard_out}" 2>/dev/null || true)"
fi
if [[ -n "${outcome}" ]]; then
  with_state_lock _dispatch_remove_session_marker_unlocked \
    >/dev/null 2>&1 || exit 0
fi

# MessageDisplay intentionally withholds unsealed completion prose. If a
# configured gate-cap path accepts an exhausted/scorecard release without a
# READY seal, replay the richest bounded candidate in the Stop receipt so the
# user's shipped-detail summary is never lost at the terminal boundary.
degraded_candidate=""
if [[ "${outcome}" == "exhausted" ]]; then
  current_candidate="$(json_get '.last_assistant_message')"
  closeout_record_provisional "${current_candidate}" "1" || true
  latest_candidate="$(_closeout_latest_provisional)"
  [[ -n "${latest_candidate}" ]] || latest_candidate="${current_candidate}"
  degraded_candidate="$(_closeout_degraded_candidate_block "${latest_candidate}")"
fi

if [[ "${_ulw_before}" -eq 1 && -z "${outcome}" && -z "${guard_message}" ]]; then
  log_anomaly "stop-dispatch" "ULW guard returned without block, release message, or terminal outcome" 2>/dev/null || true
  _emit_compact_continuation "[Stop certification] the quality guard returned no terminal outcome, so this response is not certified."
  exit 0
fi

time_out="$(_run_stop_child "stop-time-summary.sh" 2>/dev/null || true)"
time_message=""
if [[ -n "${time_out}" ]] && jq -e 'type == "object"' <<<"${time_out}" >/dev/null 2>&1; then
  time_message="$(jq -r '.systemMessage // empty' <<<"${time_out}" 2>/dev/null || true)"
fi

receipt=""
canary_message=""
if [[ "${_ulw_before}" -eq 1 ]]; then
  if [[ "${outcome}" == "completed" ]]; then
    receipt="✓ oh-my-claude · quality checks passed"
  elif [[ "${outcome}" == "exhausted" ]]; then
    receipt="oh-my-claude · closeout released with unresolved gate gaps"
  fi
fi
finalizer_claim_id=""
if [[ "${_ulw_before}" -eq 1 ]]; then
  finalizer_claim_id="$(closeout_claim_finalization 2>/dev/null)" \
    || finalizer_claim_id=""
fi
if [[ -n "${finalizer_claim_id}" ]]; then
  finalizer_rc=0
  canary_rc=0
  canary_out="$(_run_accepted_stop_child "canary-claim-audit.sh" \
    "${finalizer_claim_id}" 2>/dev/null)" || canary_rc=$?
  if [[ -n "${canary_out}" ]] && jq -e 'type == "object"' <<<"${canary_out}" >/dev/null 2>&1; then
    canary_message="$(jq -r '.systemMessage // empty' <<<"${canary_out}" 2>/dev/null || true)"
  fi
  archive_rc=0
  _run_accepted_stop_child "stop-transcript-archive.sh" \
    "${finalizer_claim_id}" >/dev/null 2>&1 || archive_rc=$?
  if [[ "${canary_rc}" -eq 0 && "${archive_rc}" -eq 0 ]]; then
    closeout_complete_finalization "${finalizer_claim_id}" \
      2>/dev/null || finalizer_rc=1
  else
    finalizer_rc=1
  fi
  if [[ "${finalizer_rc}" -ne 0 ]]; then
    closeout_abandon_finalization "${finalizer_claim_id}" \
      2>/dev/null || true
    log_anomaly "stop-dispatch" "accepted-release finalizer publication incomplete canary_rc=${canary_rc} archive_rc=${archive_rc}; exact claim abandoned and provisional evidence retained until fresh execution" 2>/dev/null || true
  fi
  if [[ "${outcome}" == "completed" && "${finalizer_rc}" -eq 0 ]]; then
    with_state_lock _dispatch_remove_provisional_unlocked \
      >/dev/null 2>&1 || true
  fi
fi

merged=""
for fragment in "${receipt}" "${degraded_candidate}" "${guard_message}" "${time_message}" "${canary_message}"; do
  [[ -n "${fragment}" ]] || continue
  if [[ -n "${merged}" ]]; then
    merged="${merged}"$'\n'"${fragment}"
  else
    merged="${fragment}"
  fi
done

if [[ -n "${merged}" ]]; then
  omc_enforcement_generation_matches_capture || exit 0
  emit_stop_message "$(truncate_chars 9800 "${merged}")"
fi
exit 0
