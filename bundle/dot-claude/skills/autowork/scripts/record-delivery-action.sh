#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# Delivery-action recording is a cheap Bash PostToolUse hook. It needs only
# state helpers and command redaction; skip classifier/timing parse overhead.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

tool_name="$(json_get '.tool_name' 2>/dev/null || true)"
if [[ "${tool_name}" != "Bash" && -n "${tool_name}" ]]; then
  exit 0
fi

command_text="$(json_get '.tool_input.command' 2>/dev/null || true)"
[[ -n "${command_text}" ]] || exit 0

tool_output="$(json_get '.tool_response' 2>/dev/null || true)"
if [[ -z "${tool_output}" ]]; then
  tool_output="$(json_get '.tool_result' 2>/dev/null || true)"
fi

# PostToolUse can still carry failed shell output depending on Claude Code
# version. Failed commit/push attempts must not satisfy the delivery contract.
if omc_delivery_command_failed "${tool_output}"; then
  exit 0
fi

action_kinds="$(omc_delivery_action_kinds "${command_text}")"
[[ -n "${action_kinds}" ]] || exit 0

now="$(now_epoch)"
command_safe="$(printf '%s' "${command_text}" | omc_redact_secrets | tr -d '\000')"
command_safe="$(truncate_chars 500 "${command_safe}")"

_record_delivery_actions_locked() {
  local kind count
  while IFS= read -r kind || [[ -n "${kind}" ]]; do
    case "${kind}" in
      commit)
        count="$(read_state "commit_action_count")"
        count="${count:-0}"
        [[ "${count}" =~ ^[0-9]+$ ]] || count=0
        write_state_batch \
          "last_delivery_action_ts" "${now}" \
          "last_commit_action_ts" "${now}" \
          "last_commit_action_cmd" "${command_safe}" \
          "commit_action_count" "$((count + 1))"
        ;;
      publish)
        count="$(read_state "publish_action_count")"
        count="${count:-0}"
        [[ "${count}" =~ ^[0-9]+$ ]] || count=0
        write_state_batch \
          "last_delivery_action_ts" "${now}" \
          "last_publish_action_ts" "${now}" \
          "last_publish_action_cmd" "${command_safe}" \
          "publish_action_count" "$((count + 1))"
        ;;
    esac
  done <<<"${action_kinds}"
}

if ! with_state_lock _record_delivery_actions_locked; then
  exit 0
fi

log_hook "record-delivery-action" "kinds=$(printf '%s' "${action_kinds}" | tr '\n' ',' | sed 's/,$//') cmd=$(truncate_chars 80 "${command_text}")"
