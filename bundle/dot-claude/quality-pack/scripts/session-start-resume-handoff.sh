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
  && validate_session_id "${resume_source_id}" \
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

  # JSONL, log, and plan files remain separate — always copy
  copy_state_if_present "${resume_state_dir}" "subagent_summaries.jsonl"
  copy_state_if_present "${resume_state_dir}" "recent_prompts.jsonl"
  copy_state_if_present "${resume_state_dir}" "edited_files.log"
  copy_state_if_present "${resume_state_dir}" "current_plan.md"
  # The next three files preserve council Phase 8 mid-wave state across a
  # `--resume` round-trip so a rate-limit kill does not silently lose
  # shipped/pending/deferred ledgers and gate-event history. The resumed
  # session continues appending to the copied files; the original
  # session is dormant from this point forward (single-writer ownership
  # transfers atomically at copy time). Without this carry-over a Phase
  # 8 wave plan would silently restart and the discovered-scope gate
  # would dis-block falsely.
  copy_state_if_present "${resume_state_dir}" "findings.json"
  copy_state_if_present "${resume_state_dir}" "gate_events.jsonl"
  copy_state_if_present "${resume_state_dir}" "discovered_scope.jsonl"

  # Defense-in-depth for the SessionStart resume-hint hook: clear any
  # `resume_hint_emitted*` flags carried over from the source session.
  # The hint hook uses per-artifact keys (`resume_hint_emitted_<sid>`)
  # in the new world, but a stale legacy `resume_hint_emitted` key from
  # a pre-Wave-1 source session would otherwise short-circuit the hook
  # in the new session. The clear is cheap and keeps the hint hook's
  # single-source-of-truth idempotency contract intact.
  if jq -e 'has("resume_hint_emitted") or
            (to_entries | map(select(.key | startswith("resume_hint_emitted_"))) | length > 0)' \
       "$(session_file "${STATE_JSON}")" >/dev/null 2>&1; then
    state_file="$(session_file "${STATE_JSON}")"
    tmp="${state_file}.tmp.$$"
    if jq 'with_entries(select(.key | startswith("resume_hint_emitted") | not))' \
        "${state_file}" >"${tmp}" 2>/dev/null; then
      mv -f "${tmp}" "${state_file}"
    else
      rm -f "${tmp}" 2>/dev/null || true
    fi
  fi

  write_state "resume_source_session_id" "${resume_source_id}"

  # Wave 3 chain-depth propagation: when the resumed session is itself
  # killed by a rate-limit StopFailure, the new resume_request.json
  # needs to carry forward origin_session_id (the FIRST session in the
  # chain) + origin_chain_depth (incremented by 1) so the watchdog's
  # 3-attempt cap can refuse a runaway resume loop. Without this, every
  # rate-limited link in the chain writes resume_attempts:0 and the cap
  # resets indefinitely.
  source_resume_artifact="${resume_state_dir}/resume_request.json"
  if [[ -f "${source_resume_artifact}" ]] && jq -e . "${source_resume_artifact}" >/dev/null 2>&1; then
    parent_origin_sid="$(jq -r '(.origin_session_id // .session_id // "")' "${source_resume_artifact}" 2>/dev/null || true)"
    parent_chain_depth="$(jq -r '((.origin_chain_depth // 0) | tonumber? // 0)' "${source_resume_artifact}" 2>/dev/null || echo 0)"
    parent_chain_depth="${parent_chain_depth%%.*}"
    parent_chain_depth="${parent_chain_depth//[!0-9]/}"
    parent_chain_depth="${parent_chain_depth:-0}"
    if [[ -n "${parent_origin_sid}" ]]; then
      write_state "origin_session_id" "${parent_origin_sid}"
    fi
    write_state "origin_chain_depth" "$(( parent_chain_depth + 1 ))"
  fi
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
    jq -r 'select(.agent_type and .message) |
      "- \(.agent_type): \(.message | gsub("[\\r\\n]+"; " ") | .[:220])"
    ' <<<"${line}" 2>/dev/null || true
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

plan_file="$(session_file "current_plan.md")"
if [[ -f "${plan_file}" ]]; then
  plan_summary="$(head -c 2000 "${plan_file}")"
  if [[ -n "${plan_summary}" ]]; then
    context_parts+=("Preserved plan from prior session:\n${plan_summary}")
  fi
fi

if [[ "${workflow_mode_value}" == "ultrawork" ]]; then
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
