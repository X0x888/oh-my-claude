#!/usr/bin/env bash

set -euo pipefail

# Verification freshness is causal, not completion-time based. Record the
# code generation before Bash/MCP tools start so record-verification.sh can
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
  Bash|mcp__*) ;;
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
  local _path="" _dir="" _tmp="" _revision=""

  # Recheck addressed-session authority under the lock so a PreToolUse hook
  # already waiting cannot recreate a verification start after release/off.
  is_ultrawork_mode || return 0

  _path="$(_verification_start_path "${tool_use_id}")" || return 1
  _dir="${_path%/*}"
  mkdir -p "${_dir}"
  chmod 700 "${_dir}" 2>/dev/null || true

  _revision="$(read_state "last_code_edit_revision")"
  [[ "${_revision}" =~ ^[0-9]+$ ]] || _revision="0"

  _tmp="$(mktemp "${_path}.XXXXXX")" || return 1
  if jq -nc \
      --arg tool_use_id "${tool_use_id}" \
      --arg tool_name "${tool_name}" \
      --arg code_revision "${_revision}" \
      --arg started_at "$(now_epoch)" \
      '{tool_use_id:$tool_use_id,tool_name:$tool_name,
        code_revision:$code_revision,started_at:$started_at}' >"${_tmp}"; then
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
