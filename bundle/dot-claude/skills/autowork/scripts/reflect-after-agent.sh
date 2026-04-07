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

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Agent" ]]; then
  exit 0
fi

# P4: reset stall counter on agent delegation (progress action)
write_state "stall_counter" "0"

# P3: extract latest subagent findings for specific context injection
finding_context=""
summaries_file="$(session_file "subagent_summaries.jsonl")"
if [[ -f "${summaries_file}" ]]; then
  latest_summary="$(tail -n 1 "${summaries_file}")"
  if [[ -n "${latest_summary}" ]]; then
    agent_type="$(jq -r '.agent_type // empty' <<<"${latest_summary}")"
    message="$(jq -r '.message // empty | gsub("[\\r\\n]+"; " ")' <<<"${latest_summary}")"
    if [[ -n "${agent_type}" && -n "${message}" ]]; then
      finding_context=" The ${agent_type} agent reported: $(truncate_chars 400 "${message}")."
    fi
  fi
fi

task_intent="$(read_state "task_intent")"
if [[ "${task_intent}" == "advisory" ]]; then
  jq -nc --arg ctx "REFLECT: An agent just returned results.${finding_context} Before your next action: (1) verify the most impactful claims against actual code before relying on them, (2) check whether other exploration agents are still running — do NOT deliver the final structured report until all agents have returned. Deliver status updates if needed, but hold the synthesis." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  jq -nc --arg ctx "REFLECT: An agent just returned results.${finding_context} Before your next action: verify the most impactful claims against the actual code before relying on them. Then proceed." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi
