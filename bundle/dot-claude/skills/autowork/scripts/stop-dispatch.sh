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
    local candidate="" emergency_message
    # The outer trap may run before shared sanitizers were sourced. Never
    # replay terminal-controlled/model text raw merely to preserve a candidate;
    # omit it until the normal, sanitized continuation path is available.
    if declare -F omc_redact_secrets >/dev/null 2>&1 \
        && declare -F _omc_strip_render_unsafe >/dev/null 2>&1; then
      candidate="$(
        jq -r '.last_assistant_message // ""' <<<"${HOOK_JSON:-{}}" 2>/dev/null \
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
HOOK_JSON="$(/bin/cat 2>/dev/null || true)"
if ! command -v jq >/dev/null 2>&1 || ! jq -e . <<<"${HOOK_JSON}" >/dev/null 2>&1; then
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
SESSION_ID="$(jq -r '.session_id // ""' <<<"${HOOK_JSON}" 2>/dev/null || true)"
[[ "${SESSION_ID:-}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] || exit 0
[[ "${SESSION_ID}" != *".."* && ! "${SESSION_ID}" =~ ^\.+$ ]] || exit 0
_dispatch_state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
_dispatch_state_file="${_dispatch_state_root}/${SESSION_ID}/session_state.json"
_dispatch_session_marker="${_dispatch_state_root}/${SESSION_ID}/.ulw_active"
_dispatch_authority="$(jq -r '
  ((.ulw_enforcement_active // "") | tostring) as $active
  | if (.workflow_mode // "") == "ultrawork" then
      if $active == "1" then "on"
      elif $active == "0" then "off"
      elif (.session_outcome // "") == "" then "on"
      else "off"
      end
    elif $active == "0" then "off"
    elif (.workflow_mode // "") == "" and (.session_outcome // "") == "" then "unknown"
    else "off"
    end
' "${_dispatch_state_file}" 2>/dev/null || printf 'unknown')"
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
. "${SCRIPT_DIR}/common.sh"
ensure_session_dir
_ulw_before=1

_run_stop_child() {
  local script="$1"
  shift
  if [[ "${script}" == "stop-guard.sh" ]]; then
    printf '%s' "${HOOK_JSON}" | OMC_LAZY_CLASSIFIER=0 OMC_LAZY_TIMING=0 \
      bash "${SCRIPT_DIR}/${script}" "$@"
  else
    printf '%s' "${HOOK_JSON}" | bash "${SCRIPT_DIR}/${script}" "$@"
  fi
}

_run_accepted_stop_child() {
  local script="$1"
  shift
  printf '%s' "${HOOK_JSON}" | OMC_STOP_ACCEPTED=1 \
    bash "${SCRIPT_DIR}/${script}" "$@"
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

_emit_compact_continuation() {
  local full_reason="$1" compact context continuation_result continuation_count continuation_status continuation_rc=0
  local degraded_candidate exhausted_message current_candidate latest_candidate platform_cap terminal_at expected_generation
  current_candidate="$(json_get '.last_assistant_message')"
  closeout_record_provisional "${current_candidate}" "1" || true
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
  if (( continuation_count >= terminal_at )); then
    latest_candidate="$(_closeout_latest_provisional)"
    [[ -n "${latest_candidate}" ]] || latest_candidate="${current_candidate}"
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
    rm -f "$(session_file ".ulw_active")" 2>/dev/null || true
    printf -v exhausted_message '%s\n%s\n%s' \
      "oh-my-claude · closeout ended explicitly before Claude Code's Stop-continuation ceiling" \
      "Unresolved: $(closeout_compact_gate_feedback "${full_reason}")" \
      "${degraded_candidate:-No completion candidate was available to replay.}"
    emit_stop_message "$(truncate_chars 9800 "${exhausted_message}")"
    return 0
  fi
  compact="$(closeout_compact_gate_feedback "${full_reason}")"
  context="oh-my-claude closeout check: ${compact} Continue working; do NOT emit another completion summary. Run \`bash \"\$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh\" \"${SESSION_ID}\"\` if exact recovery context was not already injected. When it reports READY, write one complete cumulative replacement covering the whole original objective—not a delta from an earlier summary."
  context="$(truncate_chars 900 "${context}")"
  if _stop_modern_feedback_supported; then
    jq -nc --arg ctx "${context}" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}'
  else
    jq -nc --arg reason "${context}" '{decision:"block",reason:$reason}'
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

guard_out=""
guard_rc=0
guard_out="$(_run_stop_child "stop-guard.sh")" || guard_rc=$?

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
  write_state_batch \
    "closeout_last_stop_feedback" "$(truncate_chars 7600 "${full_reason}")" \
    "closeout_last_stop_feedback_ts" "$(now_epoch)" 2>/dev/null || true
  # The guard stamped this exact attempt. stop-time-summary therefore captures
  # token/economics deltas but suppresses prompt_end and the visible card.
  _run_stop_child "stop-time-summary.sh" >/dev/null 2>&1 || true
  _emit_compact_continuation "${full_reason}"
  exit 0
fi

# Empty guard output is a normal clean pass. A non-empty object may carry a
# scorecard/degraded-release systemMessage; preserve it, but never relabel an
# exhausted/skip release as "all gates passed".
outcome="$(read_state "session_outcome" 2>/dev/null || true)"
guard_message=""
if [[ -n "${guard_out}" ]]; then
  guard_message="$(jq -r '.systemMessage // empty' <<<"${guard_out}" 2>/dev/null || true)"
fi
if [[ -n "${outcome}" ]]; then
  rm -f "$(session_file ".ulw_active")" 2>/dev/null || true
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
if [[ "${_ulw_before}" -eq 1 ]] && closeout_claim_finalization 2>/dev/null; then
  finalizer_rc=0
  canary_rc=0
  canary_out="$(_run_accepted_stop_child "canary-claim-audit.sh" 2>/dev/null)" || canary_rc=$?
  if [[ -n "${canary_out}" ]] && jq -e 'type == "object"' <<<"${canary_out}" >/dev/null 2>&1; then
    canary_message="$(jq -r '.systemMessage // empty' <<<"${canary_out}" 2>/dev/null || true)"
  fi
  archive_rc=0
  _run_accepted_stop_child "stop-transcript-archive.sh" >/dev/null 2>&1 || archive_rc=$?
  if [[ "${canary_rc}" -eq 0 && "${archive_rc}" -eq 0 ]]; then
    closeout_complete_finalization 2>/dev/null || finalizer_rc=1
  else
    finalizer_rc=1
  fi
  if [[ "${finalizer_rc}" -ne 0 ]]; then
    closeout_abandon_finalization 2>/dev/null || true
    log_anomaly "stop-dispatch" "accepted-release best-effort finalizer incomplete canary_rc=${canary_rc} archive_rc=${archive_rc}; provisional evidence retained until fresh execution" 2>/dev/null || true
  fi
  if [[ "${outcome}" == "completed" && "${finalizer_rc}" -eq 0 ]]; then
    rm -f "$(session_file "provisional_closeouts.jsonl")" 2>/dev/null || true
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
  emit_stop_message "$(truncate_chars 9800 "${merged}")"
fi
exit 0
