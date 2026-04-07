#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
PROMPT_TEXT="$(json_get '.prompt')"

if [[ -z "${SESSION_ID}" || -z "${PROMPT_TEXT}" ]]; then
  exit 0
fi

ensure_session_dir
sweep_stale_sessions

previous_objective="$(read_state "current_objective")"
previous_domain="$(read_state "task_domain")"
previous_last_assistant="$(read_state "last_assistant_message")"
TASK_INTENT="$(classify_task_intent "${PROMPT_TEXT}")"

write_state_batch \
  "stop_guard_blocks" "0" \
  "session_handoff_blocks" "0" \
  "advisory_guard_blocks" "0" \
  "last_advisory_verify_ts" "" \
  "task_intent" "${TASK_INTENT}" \
  "last_user_prompt" "${PROMPT_TEXT}" \
  "last_user_prompt_ts" "$(now_epoch)" \
  "stall_counter" "0"
append_limited_state \
  "recent_prompts.jsonl" \
  "$(jq -nc --arg ts "$(now_epoch)" --arg text "${PROMPT_TEXT}" '{ts:$ts,text:$text}')" \
  "12"

if ! is_maintenance_prompt "${PROMPT_TEXT}"; then
  normalized_objective="$(normalize_task_prompt "${PROMPT_TEXT}")"
  if is_continuation_request "${PROMPT_TEXT}" && [[ -n "${previous_objective}" ]]; then
    write_state "current_objective" "${previous_objective}"
  elif [[ "${TASK_INTENT}" == "advisory" || "${TASK_INTENT}" == "session_management" || "${TASK_INTENT}" == "checkpoint" ]] \
    && [[ -n "${previous_objective}" ]]; then
    write_state "current_objective" "${previous_objective}"
  elif [[ -n "${normalized_objective}" ]]; then
    write_state "current_objective" "${normalized_objective}"
  else
    write_state "current_objective" "${PROMPT_TEXT}"
  fi
fi

if [[ "${TASK_INTENT}" == "advisory" || "${TASK_INTENT}" == "session_management" || "${TASK_INTENT}" == "checkpoint" ]]; then
  normalized_meta_request="$(trim_whitespace "$(normalize_task_prompt "${PROMPT_TEXT}")")"
  if [[ -n "${normalized_meta_request}" ]]; then
    write_state "last_meta_request" "${normalized_meta_request}"
  else
    write_state "last_meta_request" "${PROMPT_TEXT}"
  fi
fi

context_parts=()

render_prior_specialist_summaries() {
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

if grep -Eiq '(^|[^[:alnum:]_-])(ultrawork|ulw|autowork|sisyphus)([^[:alnum:]_-]|$)' <<<"${PROMPT_TEXT}"; then
  continuation_prompt=0
  continuation_directive=""
  advisory_prompt=0
  session_management_prompt=0
  checkpoint_prompt=0

  if is_continuation_request "${PROMPT_TEXT}" && [[ -n "${previous_objective}" ]]; then
    continuation_prompt=1
    continuation_directive="$(extract_continuation_directive "${PROMPT_TEXT}")"
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${previous_objective}")}"
    write_state "current_objective" "${previous_objective}"
  elif [[ "${TASK_INTENT}" == "session_management" ]]; then
    session_management_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}")}"
  elif [[ "${TASK_INTENT}" == "advisory" ]]; then
    advisory_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}")}"
  elif [[ "${TASK_INTENT}" == "checkpoint" ]]; then
    checkpoint_prompt=1
    TASK_DOMAIN="${previous_domain:-$(infer_domain "${PROMPT_TEXT}")}"
  else
    TASK_DOMAIN="$(infer_domain "${PROMPT_TEXT}")"
  fi

  write_state "workflow_mode" "ultrawork"
  write_state "task_domain" "${TASK_DOMAIN}"

  # Sentinel for fast-path exit in PostToolUse hooks (zero-cost check)
  touch "${STATE_ROOT}/.ulw_active"

  if [[ "${continuation_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork continuation mode is active for this session. Continue the prior task instead of treating the literal word 'continue' or 'resume' as a new objective. In your first user-facing response, start with the bold phrase **Ultrawork continuation active.** then briefly state what is already done, what remains, and the next concrete action. Reuse finished work, preserve the existing task domain, and only re-dispatch branches that were interrupted or are still missing.")
    context_parts+=("Preserved objective: ${previous_objective}")

    if [[ -n "${previous_last_assistant}" ]]; then
      context_parts+=("Last recorded assistant state before the interruption: $(truncate_chars 700 "${previous_last_assistant}")")
    fi

    specialist_context="$(render_prior_specialist_summaries)"
    if [[ -n "${specialist_context}" ]]; then
      context_parts+=("Recent specialist conclusions:\n${specialist_context}")
    fi

    if [[ -n "${continuation_directive}" ]]; then
      context_parts+=("Additional continuation directive from the user: ${continuation_directive}")
    fi
  elif [[ "${session_management_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as session-management advice, not execution. Answer the user's question directly. Preserve the active objective instead of treating this prompt as a new task. Do not start implementing more work unless the user explicitly asks you to continue now. If you recommend a fresh session, checkpoint, or pause, explain why cleanly and stop without triggering deferral-style execution pressure.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
    if [[ -n "${previous_domain}" ]]; then
      context_parts+=("Underlying active task domain: ${previous_domain}")
    fi
  elif [[ "${advisory_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as advisory or decision support, not direct execution. Answer the question directly, use the current task state as context if relevant, and do not force implementation unless the user explicitly asks for it.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
    if [[ -n "${previous_domain}" ]]; then
      context_parts+=("Underlying active task domain: ${previous_domain}")
    fi
    effective_domain="${TASK_DOMAIN:-${previous_domain:-}}"
    if [[ "${effective_domain}" == "coding" || "${effective_domain}" == "mixed" ]]; then
      context_parts+=("ADVISORY OVER CODE: This is an advisory task that targets a codebase. Build and test the project before forming recommendations. When launching parallel Explore agents, give each a distinct non-overlapping scope. Do NOT deliver the final structured report until all exploration agents have returned — deliver status updates while waiting, but hold the synthesis. Verify the highest-impact claims against actual code. Cover multiple layers: code correctness, user-facing copy/messaging, build/config/deployment, and external dependencies.")
    fi
  elif [[ "${checkpoint_prompt}" -eq 1 ]]; then
    context_parts+=("Ultrawork intent gate classified this prompt as a checkpoint or pause request. Preserve the active objective, provide a sharp checkpoint, state what is done and what remains, and stop cleanly without forcing full completion in this turn.")
    if [[ -n "${previous_objective}" ]]; then
      context_parts+=("Preserved active objective in the background: ${previous_objective}")
    fi
  else
    context_parts+=("Ultrawork mode is active for this session. In your first user-facing response, start with the bold phrase **Ultrawork mode active.** as the opening line for visual distinction, then state the classified domain and first action you will take. Classify the task as coding, writing, research, operations, mixed, or general, then adapt the workflow to that domain. Use the strongest specialist path available, keep momentum high, and do not stop early. Do not segment unfinished work into 'wave 1 done, wave 2 next' or 'ready for a new session' unless the user explicitly asked for a checkpoint.")
  fi

  if [[ "${session_management_prompt}" -eq 0 && "${advisory_prompt}" -eq 0 && "${checkpoint_prompt}" -eq 0 ]]; then
    case "${TASK_DOMAIN}" in
      coding)
        context_parts+=("Detected likely task domain: coding. For non-trivial work use quality-planner or prometheus first, use quality-researcher for local repo wiring, librarian for official docs and reference implementations, metis to pressure-test risky plans, oracle when stuck or debugging deeply, specialist engineering agents when relevant. Make changes incrementally — one logical change, verify it, then proceed. Test rigorously after edits — failing to test is the #1 failure mode. Run quality-reviewer before stopping. Never write placeholder stubs or sycophantic comments.")
        ;;
      writing)
        context_parts+=("Detected likely task domain: writing. Clarify audience, purpose, format, tone, and constraints early. Use writing-architect for structure when needed, librarian for factual support, draft-writer for the draft, editor-critic before finalizing. Do not invent facts, citations, or quotations — mark uncertain details explicitly. Think about the reader's perspective and what they need to take away.")
        ;;
      research)
        context_parts+=("Detected likely task domain: research or analysis. Use librarian for authoritative sources, briefing-analyst to synthesize findings, metis to challenge weak conclusions, editor-critic for prose-heavy deliverables. Prioritize source quality, separate evidence from inference, make uncertainty explicit, and optimize for decision usefulness.")
        ;;
      operations)
        context_parts+=("Detected likely task domain: operations or professional-assistant work. Use chief-of-staff to structure the deliverable, surface missing constraints, and turn the request into a clean plan, message, checklist, or action-oriented output. If substantial writing is required, pair that with draft-writer and editor-critic.")
        ;;
      mixed)
        context_parts+=("Detected likely task domain: mixed. Split the work into coding and non-coding streams. Use the engineering specialists for code work and the writing, research, or operations specialists for the non-code deliverables. Keep the branches coordinated but do not collapse everything into one generic workflow.")
        ;;
      *)
        context_parts+=("Detected likely task domain: general. The task did not match coding, writing, research, or operations keywords — classify it yourself before proceeding. Ask: what is the deliverable? Is it code, prose, a decision, a plan, or something else? Then choose the specialist path that fits. If the task involves a repository, treat it as coding. If it involves producing a document, treat it as writing. If it involves gathering information, treat it as research. Do not default to code-oriented repo exploration unless the task truly requires it.")
        ;;
    esac
  fi
fi

if grep -Eiq '(^|[^[:alnum:]_-])ultrathink([^[:alnum:]_-]|$)' <<<"${PROMPT_TEXT}"; then
  context_parts+=("ULTRATHINK MODE ACTIVE — deeper investigation required. Favor verification over abstraction: check claims against real code, run tests, read actual files rather than reasoning about what they probably contain. Before acting: consider what could go wrong and verify your assumptions are grounded. After results: ask whether you found concrete evidence or just formed an opinion — if the latter, investigate further. When you encounter ambiguity, read the source rather than reason about it. This mode is for hard problems where unverified assumptions produce wrong answers.")
fi

# Guard exhaustion warning from previous response
guard_exhausted="$(read_state "guard_exhausted")"
if [[ -n "${guard_exhausted}" ]]; then
  guard_detail="$(read_state "guard_exhausted_detail")"
  context_parts+=("WARNING — PREVIOUS RESPONSE INCOMPLETE: The stop guard was exhausted after 2 blocks. Missing quality gates: ${guard_detail}. Before starting new work, verify and review the previous changes if they haven't been checked yet. Briefly tell the user about this gap.")
  write_state_batch "guard_exhausted" "" "guard_exhausted_detail" ""
fi

if [[ "${#context_parts[@]}" -eq 0 ]]; then
  exit 0
fi

context_text="$(printf '%s\n' "${context_parts[@]}")"

jq -nc --arg context "${context_text}" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $context
  }
}'
