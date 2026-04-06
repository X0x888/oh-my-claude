#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${AGENT_TYPE}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

append_limited_state \
  "subagent_summaries.jsonl" \
  "$(jq -nc --arg ts "$(now_epoch)" --arg agent_type "${AGENT_TYPE}" --arg message "${LAST_ASSISTANT_MESSAGE}" '{ts:$ts,agent_type:$agent_type,message:$message}')" \
  "16"
