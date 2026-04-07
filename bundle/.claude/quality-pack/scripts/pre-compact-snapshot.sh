#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
TRIGGER="$(json_get '.trigger')"
CUSTOM_INSTRUCTIONS="$(json_get '.custom_instructions')"
SESSION_CWD="$(json_get '.cwd')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

snapshot_file="$(session_file "precompact_snapshot.md")"
workflow_mode_value="$(workflow_mode)"
task_domain_value="$(task_domain)"
task_intent_value="$(read_state "task_intent")"
current_objective_value="$(read_state "current_objective")"
last_meta_request_value="$(read_state "last_meta_request")"
last_user_prompt_value="$(read_state "last_user_prompt")"
last_assistant_message_value="$(read_state "last_assistant_message")"
last_verify_cmd_value="$(read_state "last_verify_cmd")"
last_edit_ts="$(read_state "last_edit_ts")"
last_review_ts="$(read_state "last_review_ts")"
last_verify_ts="$(read_state "last_verify_ts")"

if [[ -z "${current_objective_value}" ]]; then
  current_objective_value="$(normalize_task_prompt "${last_user_prompt_value}")"
  if [[ -z "${current_objective_value}" ]]; then
    current_objective_value="${last_user_prompt_value}"
  fi
fi

render_review_status() {
  if [[ -z "${last_edit_ts}" ]]; then
    printf '%s\n' "No file edits recorded in this session."
    return
  fi

  if [[ -n "${last_review_ts}" && "${last_review_ts}" -ge "${last_edit_ts}" ]]; then
    printf '%s\n' "Review loop completed after the latest edits."
  else
    printf '%s\n' "Review loop still pending after the latest edits."
  fi
}

render_verification_status() {
  if [[ -z "${last_edit_ts}" ]]; then
    printf '%s\n' "No verification requirement inferred because no file edits were recorded."
    return
  fi

  if [[ -n "${last_verify_ts}" && "${last_verify_ts}" -ge "${last_edit_ts}" ]]; then
    if [[ -n "${last_verify_cmd_value}" ]]; then
      printf 'Verified after the latest edits with `%s`.\n' "${last_verify_cmd_value}"
    else
      printf '%s\n' "Verification completed after the latest edits."
    fi
  else
    printf '%s\n' "Verification is still pending or not yet recorded after the latest edits."
  fi
}

render_recent_prompts() {
  local prompts_file
  prompts_file="$(session_file "recent_prompts.jsonl")"

  if [[ ! -f "${prompts_file}" ]]; then
    return
  fi

  tail -n 3 "${prompts_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local text
    text="$(jq -r '.text | gsub("[\\r\\n]+"; " ")' <<<"${line}" 2>/dev/null || true)"
    [[ -z "${text}" ]] && continue
    printf -- '- %s\n' "$(truncate_chars 260 "${text}")"
  done
}

render_edited_files() {
  local edited_files_file
  edited_files_file="$(session_file "edited_files.log")"

  if [[ ! -f "${edited_files_file}" ]]; then
    return
  fi

  tail -n 30 "${edited_files_file}" | awk '!seen[$0]++' | tail -n 8 | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf -- '- %s\n' "${line}"
  done
}

render_subagent_summaries() {
  local summaries_file
  summaries_file="$(session_file "subagent_summaries.jsonl")"

  if [[ ! -f "${summaries_file}" ]]; then
    return
  fi

  tail -n 6 "${summaries_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    jq -r 'select(.agent_type and .message) |
      "- \(.agent_type): \(.message | gsub("[\\r\\n]+"; " ") | .[:260])"
    ' <<<"${line}" 2>/dev/null || true
  done
}

{
  printf '# Compact Continuity Snapshot\n\n'
  printf -- '- Session ID: `%s`\n' "${SESSION_ID}"
  printf -- '- Working directory: `%s`\n' "${SESSION_CWD}"
  printf -- '- Compact trigger: `%s`\n' "${TRIGGER:-unknown}"
  if [[ -n "${workflow_mode_value}" ]]; then
    printf -- '- Workflow mode: `%s`\n' "${workflow_mode_value}"
  fi
  if [[ -n "${task_domain_value}" ]]; then
    printf -- '- Detected task domain: `%s`\n' "${task_domain_value}"
  fi
  if [[ -n "${task_intent_value}" ]]; then
    printf -- '- Detected prompt intent: `%s`\n' "${task_intent_value}"
  fi

  if [[ -n "${current_objective_value}" ]]; then
    printf '\n## Current Objective\n%s\n' "${current_objective_value}"
  fi

  if [[ -n "${last_meta_request_value}" ]]; then
    printf '\n## Last Advisory Or Meta Request\n%s\n' "${last_meta_request_value}"
  fi

  if [[ -n "${CUSTOM_INSTRUCTIONS}" ]]; then
    printf '\n## Manual Compact Instructions\n%s\n' "${CUSTOM_INSTRUCTIONS}"
  fi

  if [[ -n "${last_assistant_message_value}" ]]; then
    printf '\n## Last Assistant State Before Compact\n%s\n' "$(truncate_chars 2000 "${last_assistant_message_value}")"
  fi

  recent_prompts_rendered="$(render_recent_prompts)"
  if [[ -n "${recent_prompts_rendered}" ]]; then
    printf '\n## Recent User Prompts\n%s\n' "${recent_prompts_rendered}"
  fi

  subagent_rendered="$(render_subagent_summaries)"
  if [[ -n "${subagent_rendered}" ]]; then
    printf '\n## Recent Specialist Conclusions\n%s\n' "${subagent_rendered}"
  fi

  plan_file="$(session_file "current_plan.md")"
  if [[ -f "${plan_file}" ]]; then
    plan_content="$(head -c 3000 "${plan_file}")"
    if [[ -n "${plan_content}" ]]; then
      printf '\n## Active Plan\n%s\n' "${plan_content}"
    fi
  fi

  edited_files_rendered="$(render_edited_files)"
  if [[ -n "${edited_files_rendered}" ]]; then
    printf '\n## Edited Files\n%s\n' "${edited_files_rendered}"
  fi

  printf '\n## Completion State\n'
  printf -- '- %s\n' "$(render_review_status)"
  printf -- '- %s\n' "$(render_verification_status)"
} >"${snapshot_file}"

write_state "last_compact_trigger" "${TRIGGER:-unknown}"
write_state "last_compact_request_ts" "$(now_epoch)"

if [[ -n "${CUSTOM_INSTRUCTIONS}" ]]; then
  write_state "last_compact_custom_instructions" "${CUSTOM_INSTRUCTIONS}"
fi
