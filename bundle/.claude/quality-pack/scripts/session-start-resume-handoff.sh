#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
SOURCE="$(json_get '.source')"
TRANSCRIPT_PATH="$(json_get '.transcript_path')"

if [[ -z "${SESSION_ID}" || "${SOURCE}" != "resume" ]]; then
  exit 0
fi

ensure_session_dir

resume_source_id=""
resume_state_dir=""

if [[ -n "${TRANSCRIPT_PATH}" ]]; then
  resume_source_id="$(basename "${TRANSCRIPT_PATH}" .jsonl)"
fi

if [[ -n "${resume_source_id}" ]] \
  && [[ "${resume_source_id}" != "${SESSION_ID}" ]] \
  && [[ -d "${STATE_ROOT}/${resume_source_id}" ]]; then
  resume_state_dir="${STATE_ROOT}/${resume_source_id}"
fi

copy_state_if_present() {
  local source_dir="$1"
  local key="$2"

  if [[ -f "${source_dir}/${key}" ]]; then
    cp "${source_dir}/${key}" "$(session_file "${key}")"
  fi
}

if [[ -n "${resume_state_dir}" ]]; then
  # Copy consolidated JSON state (new format)
  if [[ -f "${resume_state_dir}/${STATE_JSON}" ]]; then
    cp "${resume_state_dir}/${STATE_JSON}" "$(session_file "${STATE_JSON}")"
  else
    # Backwards compat: migrate individual files from pre-JSON sessions
    for key in workflow_mode task_domain task_intent current_objective last_meta_request last_assistant_message last_verify_cmd; do
      if [[ -f "${resume_state_dir}/${key}" ]]; then
        write_state "${key}" "$(cat "${resume_state_dir}/${key}")"
      fi
    done
  fi

  # JSONL and log files remain separate — always copy
  copy_state_if_present "${resume_state_dir}" "subagent_summaries.jsonl"
  copy_state_if_present "${resume_state_dir}" "recent_prompts.jsonl"
  copy_state_if_present "${resume_state_dir}" "edited_files.log"

  write_state "resume_source_session_id" "${resume_source_id}"
fi

current_objective_value="$(read_state "current_objective")"
task_domain_value="$(task_domain)"
workflow_mode_value="$(workflow_mode)"
task_intent_value="$(read_state "task_intent")"
last_meta_request_value="$(read_state "last_meta_request")"
last_assistant_message_value="$(read_state "last_assistant_message")"

render_subagent_summaries() {
  local summaries_file
  summaries_file="$(session_file "subagent_summaries.jsonl")"

  if [[ ! -f "${summaries_file}" ]]; then
    return
  fi

  tail -n 6 "${summaries_file}" | while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    agent_type="$(jq -r '.agent_type // empty' <<<"${line}")"
    message="$(jq -r '.message // empty | gsub("[\\r\\n]+"; " ")' <<<"${line}")"
    [[ -z "${agent_type}" || -z "${message}" ]] && continue
    printf -- '- %s: %s\n' "${agent_type}" "$(truncate_chars 220 "${message}")"
  done
}

context_parts=()
context_parts+=("This is a resumed Claude Code session. Continue the prior task instead of restarting from scratch. Reuse completed work, treat previous specialist results as still valid unless contradicted, and only re-dispatch branches that were interrupted or are still missing.")

if [[ -n "${workflow_mode_value}" ]]; then
  context_parts+=("Preserved workflow mode: ${workflow_mode_value}. If the user says 'continue' or 'resume', do not treat that literal word as a new task.")
fi

if [[ -n "${task_domain_value}" ]]; then
  context_parts+=("Preserved task domain: ${task_domain_value}.")
fi

if [[ -n "${task_intent_value}" ]]; then
  context_parts+=("Preserved last prompt intent: ${task_intent_value}.")
fi

if [[ -n "${current_objective_value}" ]]; then
  context_parts+=("Preserved objective: ${current_objective_value}")
fi

if [[ -n "${last_meta_request_value}" ]]; then
  context_parts+=("Last advisory or meta request in the prior session: ${last_meta_request_value}")
fi

if [[ -n "${last_assistant_message_value}" ]]; then
  context_parts+=("Last recorded assistant state before the interruption: $(truncate_chars 700 "${last_assistant_message_value}")")
fi

specialist_context="$(render_subagent_summaries)"
if [[ -n "${specialist_context}" ]]; then
  context_parts+=("Recent specialist conclusions:\n${specialist_context}")
fi

if [[ "${workflow_mode_value}" == "ultrawork" ]]; then
  context_parts+=("THINKING DIRECTIVE: Plan before each significant action and reflect after each result — proportional to the task's complexity. Do not chain tool calls without interleaved reasoning — mechanical sequences produce shallow work. Before acting: reason about what you expect and why. After results: reflect on whether the outcome matched expectations. When stuck: think harder, not faster — hypothesize, gather evidence, then act. Track progress with tasks on non-trivial work. Prioritize technical accuracy over validating beliefs.")
  case "${task_domain_value}" in
    coding)
      context_parts+=("Active task domain: coding. Make changes incrementally — one logical change, verify it, then proceed. Test rigorously after edits. Run quality-reviewer before stopping.")
      ;;
    writing)
      context_parts+=("Active task domain: writing. Use editor-critic before finalizing. Do not invent facts or citations.")
      ;;
    research)
      context_parts+=("Active task domain: research. Prioritize source quality, separate evidence from inference, make uncertainty explicit.")
      ;;
    operations)
      context_parts+=("Active task domain: operations. Use chief-of-staff for structure, draft-writer and editor-critic for prose.")
      ;;
    mixed)
      context_parts+=("Active task domain: mixed. Use appropriate specialists for each stream.")
      ;;
    *)
      context_parts+=("Active task domain: general. Classify the task yourself before proceeding — determine whether the deliverable is code, prose, a decision, a plan, or something else, then choose the specialist path that fits.")
      ;;
  esac
fi

context_text="$(printf '%s\n' "${context_parts[@]}")"

jq -nc --arg context "${context_text}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
