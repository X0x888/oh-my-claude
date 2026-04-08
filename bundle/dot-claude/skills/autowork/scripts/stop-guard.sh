#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

last_assistant_message="$(json_get '.last_assistant_message')"
if [[ -n "${last_assistant_message}" ]]; then
  write_state_batch \
    "last_assistant_message" "${last_assistant_message}" \
    "last_assistant_message_ts" "$(now_epoch)"
fi

if ! is_ultrawork_mode; then
  # Clean up sentinel when a non-ULW session ends
  rm -f "${STATE_ROOT}/.ulw_active"
  exit 0
fi

stop_hook_active="$(json_get '.stop_hook_active')"
if [[ "${stop_hook_active}" == "true" ]]; then
  exit 0
fi

current_objective="$(read_state "current_objective")"
task_intent="$(read_state "task_intent")"
last_user_prompt_ts="$(read_state "last_user_prompt_ts")"
session_handoff_blocks="$(read_state "session_handoff_blocks")"
session_handoff_blocks="${session_handoff_blocks:-0}"
last_edit_ts="$(read_state "last_edit_ts")"

if ! is_execution_intent_value "${task_intent}"; then
  # Advisory quality check: for advisory tasks over codebases, verify that
  # actual code inspection happened before allowing the response to finalize.
  if [[ "${task_intent}" == "advisory" ]]; then
    task_domain_val="$(task_domain)"
    task_domain_val="${task_domain_val:-general}"
    if [[ "${task_domain_val}" == "coding" || "${task_domain_val}" == "mixed" ]]; then
      advisory_verify_ts="$(read_state "last_advisory_verify_ts")"
      verify_ts="$(read_state "last_verify_ts")"
      advisory_guard_blocks="$(read_state "advisory_guard_blocks")"
      advisory_guard_blocks="${advisory_guard_blocks:-0}"

      if [[ -z "${advisory_verify_ts}" && -z "${verify_ts}" ]] && [[ "${advisory_guard_blocks}" -lt 1 ]]; then
        write_state "advisory_guard_blocks" "$((advisory_guard_blocks + 1))"
        jq -nc --arg reason "Autowork guard: this is an advisory task over a codebase, but no code inspection or build/test verification was detected. Before finalizing your response, read or search the actual codebase to ground your recommendations in evidence. If you have already inspected code via other means, explain the verification you performed." '{"decision":"block","reason":$reason}'
        exit 0
      fi
    fi
  fi

  if [[ -z "${last_edit_ts}" || -z "${last_user_prompt_ts}" || "${last_edit_ts}" -lt "${last_user_prompt_ts}" ]]; then
    exit 0
  fi
fi

if [[ -n "${last_assistant_message}" ]] \
  && has_unfinished_session_handoff "${last_assistant_message}" \
  && ! is_checkpoint_request "${current_objective}"; then
  if [[ "${session_handoff_blocks}" -lt 2 ]]; then
    write_state "session_handoff_blocks" "$((session_handoff_blocks + 1))"
    jq -nc --arg reason "Autowork guard: your last response explicitly deferred remaining work to a future session. In ultrawork mode, do not stop with 'next wave', 'next phase', or 'ready for a new session' language unless the user explicitly asked for a checkpoint. Continue the remaining work now. If you genuinely must pause, explain the hard blocker or ask the user whether they want a checkpoint." '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

if [[ -z "${last_edit_ts}" ]]; then
  exit 0
fi

last_review_ts="$(read_state "last_review_ts")"
last_verify_ts="$(read_state "last_verify_ts")"
task_domain="$(task_domain)"
task_domain="${task_domain:-general}"
guard_blocks="$(read_state "stop_guard_blocks")"
guard_blocks="${guard_blocks:-0}"

missing_review=0
missing_verify=0

if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_edit_ts}" ]]; then
  missing_review=1
fi

case "${task_domain}" in
  coding|mixed)
    if [[ -z "${last_verify_ts}" || "${last_verify_ts}" -lt "${last_edit_ts}" ]]; then
      missing_verify=1
    fi
    ;;
  *)
    missing_verify=0
    ;;
esac

# Check if verification ran but the tests actually failed
verify_failed=0
if [[ "${missing_verify}" -eq 0 ]]; then
  case "${task_domain}" in
    coding|mixed)
      verify_outcome="$(read_state "last_verify_outcome")"
      if [[ "${verify_outcome}" == "failed" ]]; then
        verify_failed=1
      fi
      ;;
  esac
fi

# Check if review ran but findings were not addressed (no edits after review)
review_unremediated=0
if [[ "${missing_review}" -eq 0 ]]; then
  review_had_findings="$(read_state "review_had_findings")"
  if [[ "${review_had_findings}" == "true" && -n "${last_review_ts}" && "${last_edit_ts}" -lt "${last_review_ts}" ]]; then
    review_unremediated=1
  fi
fi

if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
  reason="Autowork guard: the deliverable changed but the final quality loop is incomplete."
else
  reason="Autowork guard: edits were made but the final quality loop is incomplete."
fi

if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
  # Remove fast-path sentinel; workflow_mode in session_state.json is
  # intentionally preserved so the prompt-intent-router's sticky gate
  # continues injecting specialist routing for the rest of this session.
  rm -f "${STATE_ROOT}/.ulw_active"
  exit 0
fi

if [[ "${guard_blocks}" -ge 3 ]]; then
  rm -f "${STATE_ROOT}/.ulw_active"
  write_state_batch \
    "guard_exhausted" "$(now_epoch)" \
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify},verify_failed=${verify_failed},unremediated=${review_unremediated}"
  exit 0
fi

write_state "stop_guard_blocks" "$((guard_blocks + 1))"

# Build action messages from individual conditions
verify_action=""
review_action=""

if [[ "${missing_verify}" -eq 1 ]]; then
  verify_action="run the smallest meaningful validation available"
elif [[ "${verify_failed}" -eq 1 ]]; then
  verify_action="the last verification command failed — fix the underlying issues and re-run verification"
fi

if [[ "${missing_review}" -eq 1 ]]; then
  if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
    review_action="delegate to editor-critic or another relevant reviewer and address any high-signal findings — the reviewer must evaluate not just quality issues but completeness: does this deliver everything the user asked for?"
  else
    review_action="delegate to quality-reviewer and address its highest-signal findings — the reviewer must evaluate not just bugs but completeness: does the implementation cover the full scope of the original task? What is missing or only partially implemented?"
  fi
elif [[ "${review_unremediated}" -eq 1 ]]; then
  review_action="the reviewer flagged issues that were not addressed — fix them or explain why they do not apply, then re-evaluate whether the deliverable is complete"
fi

if [[ -n "${verify_action}" && -n "${review_action}" ]]; then
  reason="${reason} Continue working: ${verify_action}, then ${review_action}, and only then stop."
elif [[ -n "${verify_action}" ]]; then
  reason="${reason} Continue working: ${verify_action} before stopping. If reliable automation is impossible, explain the exact blocker and residual risk."
elif [[ -n "${review_action}" ]]; then
  reason="${reason} Continue working: ${review_action}, and only then stop."
fi

# Warn on penultimate block that the guard will exhaust next time
if [[ "${guard_blocks}" -ge 2 ]]; then
  reason="${reason} NOTE: this is the final guard block — the next stop attempt will be allowed regardless of quality gate status."
fi

jq -nc --arg reason "${reason}" '{"decision":"block","reason":$reason}'
