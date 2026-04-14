#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Agent" ]]; then
  exit 0
fi

ensure_session_dir

subagent_type="$(json_get '.tool_input.subagent_type')"
if [[ -z "${subagent_type}" ]]; then
  subagent_type="general-purpose"
fi

description="$(json_get '.tool_input.description')"
description="$(truncate_chars 260 "${description}")"

pending_entry="$(jq -nc \
  --arg ts "$(now_epoch)" \
  --arg agent_type "${subagent_type}" \
  --arg description "${description}" \
  '{ts:$ts,agent_type:$agent_type,description:$description}')"

# Append under lock so a concurrent SubagentStop cleanup does not race the write.
# Also increment the subagent dispatch counter for cost/budget visibility.
_append_pending() {
  append_limited_state "pending_agents.jsonl" "${pending_entry}" "32"
  local _count
  _count="$(read_state "subagent_dispatch_count")"
  _count="${_count:-0}"
  write_state "subagent_dispatch_count" "$((_count + 1))"
}
with_state_lock _append_pending || exit 0

log_hook "record-pending-agent" "dispatched=${subagent_type}"
