#!/usr/bin/env bash

set -euo pipefail

# Verification freshness is causal, not completion-time based. Record the
# aggregate/code/plan generation before verification-capable tools start so record-verification.sh can
# prove which bytes a result actually inspected. This deliberately does not
# depend on time_tracking: disabling timing must never disable a quality gate.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

_OMC_HOOK_CALLER_PATH="${PATH:-}"
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
omc_arm_failopen_err_trap "record-tool-start-revision" \
  "(verification start revision was not recorded; the matching result will not be credited)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
tool_name="$(json_get '.tool_name')"
tool_use_id="$(json_get '.tool_use_id')"

[[ -n "${SESSION_ID}" ]] || exit 0
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 0
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
  _digest="$(_omc_authority_digest "${_id}" 2>/dev/null || true)"
  [[ -n "${_digest}" ]] || return 1
  printf '%s/%s/.verification-starts/%s.json\n' \
    "${STATE_ROOT}" "${SESSION_ID}" "${_digest}"
}

_record_tool_start_revision_locked() {
  local _path="" _dir="" _tmp="" _code_revision="" _edit_revision=""
  local _plan_revision="" _contract_id="" _contract_revision=0 _contract=""
  local _review_cycle_id=0
  local _input_json="" _input_digest=""
  local _bash_command="" _launcher_path="" _launcher_digest=""
  local _launcher_identity="" _tool_cwd="" _tool_cwd_raw="" _subject_path=""
  local _subject_digest="" _subject_identity=""

  # Recheck addressed-session authority under the lock so a PreToolUse hook
  # already waiting cannot recreate a verification start after release/off.
  omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && return 0
  is_ultrawork_mode || return 0

  _path="$(_verification_start_path "${tool_use_id}")" || return 1
  _dir="${_path%/*}"
  # This directory is an authority boundary, not an ordinary cache path.
  # `mkdir -p` would accept a symlink and write the snapshot into its foreign
  # referent. Create the one missing leaf with a private umask, and validate
  # both pre-existing and freshly created nodes without following symlinks.
  if [[ -e "${_dir}" || -L "${_dir}" ]]; then
    [[ ! -L "${_dir}" && -d "${_dir}" ]] || return 1
  else
    (umask 077; mkdir "${_dir}") || return 1
  fi
  [[ ! -L "${_dir}" && -d "${_dir}" ]] || return 1

  _code_revision="$(read_state "last_code_edit_revision")"
  [[ "${_code_revision}" =~ ^[0-9]+$ ]] || _code_revision="0"
  _edit_revision="$(read_state "edit_revision")"
  [[ "${_edit_revision}" =~ ^[0-9]+$ ]] || _edit_revision="0"
  _plan_revision="$(read_state "plan_revision")"
  [[ "${_plan_revision}" =~ ^[0-9]+$ ]] || _plan_revision="0"
  _review_cycle_id="$(read_state "review_cycle_id")"
  [[ "${_review_cycle_id}" =~ ^[0-9]+$ ]] || _review_cycle_id="0"
  _input_json="$(jq -cS '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"
  _input_digest="$(_omc_authority_digest "${_input_json}" 2>/dev/null || true)"
  [[ -n "${_input_digest}" ]] || return 1
  _tool_cwd_raw="$(jq -r '.cwd // empty' <<<"${HOOK_JSON}" \
    2>/dev/null || true)"
  _tool_cwd_raw="${_tool_cwd_raw:-${PWD}}"
  _tool_cwd="$(_verification_normalize_proof_path \
    "${_tool_cwd_raw}" 0 content 2>/dev/null || true)"
  if [[ "${tool_name}" == "Bash" ]]; then
    _bash_command="$(jq -r '.command // empty' \
      <<<"${_input_json}" 2>/dev/null || true)"
    _launcher_path="$(verification_command_launcher_path \
      "${_bash_command}" 2>/dev/null || true)"
    if [[ -n "${_launcher_path}" ]]; then
      _launcher_digest="$(_verification_sha256_file \
        "${_launcher_path}" 2>/dev/null || true)"
      _launcher_identity="$(_verification_file_identity \
        "${_launcher_path}" 2>/dev/null || true)"
      [[ "${_launcher_digest}" =~ ^[0-9a-f]{64}$ \
          && -n "${_launcher_identity}" ]] \
        || { _launcher_path=""; _launcher_digest=""; _launcher_identity=""; }
    fi
    _subject_path="$(verification_command_subject_path \
      "${_bash_command}" "${_tool_cwd_raw}" 2>/dev/null || true)"
  elif [[ "${tool_name}" == "Read" || "${tool_name}" == "Grep" ]]; then
    _subject_path="$(verification_read_subject_path \
      "${_input_json}" "${_tool_cwd_raw}" 2>/dev/null || true)"
  fi
  if [[ -n "${_subject_path}" ]]; then
    _subject_digest="$(_verification_sha256_file \
      "${_subject_path}" 2>/dev/null || true)"
    _subject_identity="$(_verification_file_identity \
      "${_subject_path}" "${_tool_cwd}" 2>/dev/null || true)"
    [[ "${_subject_digest}" =~ ^[0-9a-f]{64}$ \
        && -n "${_subject_identity}" ]] \
      || { _subject_path=""; _subject_digest=""; _subject_identity=""; }
  fi
  if [[ "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]] \
      && _omc_load_quality_contract 2>/dev/null \
      && _contract="$(quality_contract_validate_current 2>/dev/null)"; then
    _contract_id="$(jq -r '.contract_id' <<<"${_contract}")"
    _contract_revision="$(jq -r '.contract_revision' <<<"${_contract}")"
  fi

  # Revalidate after all potentially slow proof-target observation and again
  # around publication. This is cooperative same-user integrity rather than an
  # openat(2) sandbox, but no hook operation knowingly follows a replaced leaf.
  [[ ! -L "${_dir}" && -d "${_dir}" ]] || return 1
  _tmp="$(umask 077; mktemp "${_path}.XXXXXX")" || return 1
  if [[ -L "${_dir}" || ! -d "${_dir}" \
      || -L "${_tmp}" || ! -f "${_tmp}" ]]; then
    [[ -L "${_tmp}" || -f "${_tmp}" ]] && rm -f "${_tmp}" 2>/dev/null || true
    return 1
  fi
  if jq -nc \
      --arg tool_use_id "${tool_use_id}" \
      --arg tool_name "${tool_name}" \
      --arg input_digest "${_input_digest}" \
      --arg launcher_path "${_launcher_path}" \
      --arg launcher_digest "${_launcher_digest}" \
      --arg launcher_identity "${_launcher_identity}" \
      --arg subject_path "${_subject_path}" \
      --arg subject_digest "${_subject_digest}" \
      --arg subject_identity "${_subject_identity}" \
      --arg tool_cwd "${_tool_cwd}" \
      --argjson code_revision "${_code_revision}" \
      --argjson edit_revision "${_edit_revision}" \
      --argjson plan_revision "${_plan_revision}" \
      --argjson review_cycle_id "${_review_cycle_id}" \
      --arg quality_contract_id "${_contract_id}" \
      --argjson quality_contract_revision "${_contract_revision}" \
      --argjson started_at "$(now_epoch)" \
      '{tool_use_id:$tool_use_id,tool_name:$tool_name,
        input_digest:$input_digest,launcher_path:$launcher_path,
        launcher_digest:$launcher_digest,launcher_identity:$launcher_identity,
        subject_path:$subject_path,subject_digest:$subject_digest,
        subject_identity:$subject_identity,tool_cwd:$tool_cwd,
        code_revision:$code_revision,
        edit_revision:$edit_revision,plan_revision:$plan_revision,
        review_cycle_id:$review_cycle_id,
        quality_contract_id:$quality_contract_id,
        quality_contract_revision:$quality_contract_revision,
        started_at:$started_at}' >"${_tmp}"; then
    if [[ -L "${_dir}" || ! -d "${_dir}" \
        || -L "${_tmp}" || ! -f "${_tmp}" \
        || -e "${_path}" || -L "${_path}" ]] \
        || ! mv -f "${_tmp}" "${_path}"; then
      [[ -L "${_tmp}" || -f "${_tmp}" ]] \
        && rm -f "${_tmp}" 2>/dev/null || true
      return 1
    fi
  else
    rm -f "${_tmp}"
    return 1
  fi

  [[ ! -L "${_dir}" && -d "${_dir}" \
      && ! -L "${_path}" && -f "${_path}" ]] || return 1

  # Failed/denied tools may never produce a PostToolUse result. Session
  # retention is authoritative; this best-effort sweep prevents abandoned
  # snapshots from accumulating within a long-lived session.
  find "${_dir}" -type f -mtime +1 -delete >/dev/null 2>&1 || true
}

if [[ -n "${OMC_TEST_VERIFICATION_START_LOCK_READY_FILE:-}" \
    && -n "${OMC_TEST_VERIFICATION_START_LOCK_RELEASE_FILE:-}" ]]; then
  printf 'ready\n' >"${OMC_TEST_VERIFICATION_START_LOCK_READY_FILE}"
  _verification_start_test_wait=0
  while [[ ! -f "${OMC_TEST_VERIFICATION_START_LOCK_RELEASE_FILE}" \
      && "${_verification_start_test_wait}" -lt 500 ]]; do
    sleep 0.02
    _verification_start_test_wait=$((_verification_start_test_wait + 1))
  done
  [[ -f "${OMC_TEST_VERIFICATION_START_LOCK_RELEASE_FILE}" ]] || exit 1
fi

with_state_lock _record_tool_start_revision_locked

exit 0
