#!/usr/bin/env bash

set -euo pipefail

# Verification freshness is causal, not completion-time based. Record the
# aggregate/code/plan generation before verification-capable tools start so record-verification.sh can
# prove which bytes a result actually inspected. This deliberately does not
# depend on time_tracking: disabling timing must never disable a quality gate.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
omc_arm_failopen_err_trap "record-tool-start-revision" \
  "(verification start revision was not recorded; the matching result will not be credited)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
tool_name="$(json_get '.tool_name')"
tool_use_id="$(json_get '.tool_use_id')"

[[ -n "${SESSION_ID}" ]] || exit 0
ensure_session_dir
is_ultrawork_mode || exit 0
capture_ulw_enforcement_interval || exit 0

case "${tool_name}" in
  Bash|Read|Grep|mcp__*) ;;
  *) exit 0 ;;
esac

# Claude Code normally supplies tool_use_id. Without it, concurrent identical
# calls cannot be paired safely; record-verification.sh therefore rejects the
# result instead of guessing from command text or completion order.
if [[ -z "${tool_use_id}" ]]; then
  log_anomaly "record-tool-start-revision" \
    "missing tool_use_id for ${tool_name}; verification result will fail closed"
  exit 0
fi

_verification_start_path() {
  local _id="$1" _digest=""
  _digest="$(_omc_token_digest "${_id}" 2>/dev/null || true)"
  [[ -n "${_digest}" ]] || return 1
  printf '%s/%s/.verification-starts/%s.json\n' \
    "${STATE_ROOT}" "${SESSION_ID}" "${_digest}"
}

_record_tool_start_revision_locked() {
  local _path="" _dir="" _tmp="" _code_revision="" _edit_revision=""
  local _plan_revision="" _contract_id="" _contract_revision=0 _contract=""
  local _review_cycle_id=0
  local _input_json="" _input_digest=""

  # Recheck addressed-session authority under the lock so a PreToolUse hook
  # already waiting cannot recreate a verification start after release/off.
  is_ultrawork_mode || return 0

  _path="$(_verification_start_path "${tool_use_id}")" || return 1
  _dir="${_path%/*}"
  mkdir -p "${_dir}"
  chmod 700 "${_dir}" 2>/dev/null || true

  _code_revision="$(read_state "last_code_edit_revision")"
  [[ "${_code_revision}" =~ ^[0-9]+$ ]] || _code_revision="0"
  _edit_revision="$(read_state "edit_revision")"
  [[ "${_edit_revision}" =~ ^[0-9]+$ ]] || _edit_revision="0"
  _plan_revision="$(read_state "plan_revision")"
  [[ "${_plan_revision}" =~ ^[0-9]+$ ]] || _plan_revision="0"
  _review_cycle_id="$(read_state "review_cycle_id")"
  [[ "${_review_cycle_id}" =~ ^[0-9]+$ ]] || _review_cycle_id="0"
  _input_json="$(jq -cS '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"
  _input_digest="$(_omc_token_digest "${_input_json}" 2>/dev/null || true)"
  [[ -n "${_input_digest}" ]] || return 1
  if [[ "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]] \
      && _omc_load_quality_contract 2>/dev/null \
      && _contract="$(quality_contract_validate_current 2>/dev/null)"; then
    _contract_id="$(jq -r '.contract_id' <<<"${_contract}")"
    _contract_revision="$(jq -r '.contract_revision' <<<"${_contract}")"
  fi

  _tmp="$(mktemp "${_path}.XXXXXX")" || return 1
  if jq -nc \
      --arg tool_use_id "${tool_use_id}" \
      --arg tool_name "${tool_name}" \
      --arg input_digest "${_input_digest}" \
      --argjson code_revision "${_code_revision}" \
      --argjson edit_revision "${_edit_revision}" \
      --argjson plan_revision "${_plan_revision}" \
      --argjson review_cycle_id "${_review_cycle_id}" \
      --arg quality_contract_id "${_contract_id}" \
      --argjson quality_contract_revision "${_contract_revision}" \
      --argjson started_at "$(now_epoch)" \
      '{tool_use_id:$tool_use_id,tool_name:$tool_name,
        input_digest:$input_digest,code_revision:$code_revision,
        edit_revision:$edit_revision,plan_revision:$plan_revision,
        review_cycle_id:$review_cycle_id,
        quality_contract_id:$quality_contract_id,
        quality_contract_revision:$quality_contract_revision,
        started_at:$started_at}' >"${_tmp}"; then
    mv "${_tmp}" "${_path}"
  else
    rm -f "${_tmp}"
    return 1
  fi

  # Failed/denied tools may never produce a PostToolUse result. Session
  # retention is authoritative; this best-effort sweep prevents abandoned
  # snapshots from accumulating within a long-lived session.
  find "${_dir}" -type f -mtime +1 -delete >/dev/null 2>&1 || true
}

with_state_lock _record_tool_start_revision_locked

exit 0
