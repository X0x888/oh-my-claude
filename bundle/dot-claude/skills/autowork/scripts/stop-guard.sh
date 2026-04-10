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
        jq -nc --arg reason "[Advisory gate \u00b7 1/1] Autowork guard: this is an advisory task over a codebase, but no code inspection or build/test verification was detected. Before finalizing your response, read or search the actual codebase to ground your recommendations in evidence. If you have already inspected code via other means, briefly list the files inspected and restate your key recommendation at the end." '{"decision":"block","reason":$reason}'
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
    jq -nc --arg reason "[Session-handoff gate \u00b7 $((session_handoff_blocks + 1))/2] Autowork guard: your last response explicitly deferred remaining work to a future session. In ultrawork mode, do not stop with 'next wave', 'next phase', or 'ready for a new session' language unless the user explicitly asked for a checkpoint. Continue the remaining work now. If you genuinely must pause, explain the hard blocker or ask the user whether they want a checkpoint." '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

if [[ -z "${last_edit_ts}" ]]; then
  exit 0
fi

last_review_ts="$(read_state "last_review_ts")"
last_doc_review_ts="$(read_state "last_doc_review_ts")"
last_verify_ts="$(read_state "last_verify_ts")"
last_code_edit_ts="$(read_state "last_code_edit_ts")"
last_doc_edit_ts="$(read_state "last_doc_edit_ts")"
task_domain="$(task_domain)"
task_domain="${task_domain:-general}"
guard_blocks="$(read_state "stop_guard_blocks")"
guard_blocks="${guard_blocks:-0}"

missing_review=0
missing_verify=0

# --- missing_review computation ---
#
# Two independent clocks:
#   last_code_edit_ts / last_review_ts      → quality-reviewer path
#   last_doc_edit_ts  / last_doc_review_ts  → editor-critic path
#
# If neither clock is populated (resumed session from pre-fix state),
# fall back to the legacy last_edit_ts comparison so older sessions
# continue to gate correctly.

need_code_review=0
need_doc_review=0

if [[ -z "${last_code_edit_ts}" && -z "${last_doc_edit_ts}" ]]; then
  # Legacy fallback — treat last_edit_ts as generic code edit for the review gate.
  if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_edit_ts}" ]]; then
    missing_review=1
    need_code_review=1
  fi
else
  if [[ -n "${last_code_edit_ts}" ]]; then
    if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_code_edit_ts}" ]]; then
      need_code_review=1
    fi
  fi
  if [[ -n "${last_doc_edit_ts}" ]]; then
    if [[ -z "${last_doc_review_ts}" || "${last_doc_review_ts}" -lt "${last_doc_edit_ts}" ]]; then
      need_doc_review=1
    fi
  fi
  if [[ "${need_code_review}" -eq 1 || "${need_doc_review}" -eq 1 ]]; then
    missing_review=1
  fi
fi

# --- missing_verify computation ---
#
# Verification only applies to code edits. A doc-only edit (CHANGELOG,
# README) must not re-trigger `npm test`. Key off last_code_edit_ts
# when available; fall back to last_edit_ts for legacy sessions.

verify_clock="${last_code_edit_ts:-${last_edit_ts}}"

case "${task_domain}" in
  coding|mixed)
    # Only require verification if there were code edits at some point.
    # Pure-doc sessions in coding domain (touching only CHANGELOG) skip verify.
    if [[ -n "${last_code_edit_ts}" ]] || [[ -z "${last_doc_edit_ts}" ]]; then
      if [[ -z "${last_verify_ts}" || "${last_verify_ts}" -lt "${verify_clock}" ]]; then
        missing_verify=1
      fi
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

# Check if review ran but findings were not addressed (no edits after review).
# Use the effective edit clock — last_code_edit_ts (preferred) falling back
# to last_edit_ts so legacy sessions keep behaving correctly.
review_unremediated=0
if [[ "${missing_review}" -eq 0 ]]; then
  review_had_findings="$(read_state "review_had_findings")"
  effective_edit_ts="${last_code_edit_ts:-${last_edit_ts}}"
  if [[ "${review_had_findings}" == "true" && -n "${last_review_ts}" && "${effective_edit_ts}" -lt "${last_review_ts}" ]]; then
    review_unremediated=1
  fi
fi

if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
  reason="[Quality gate \u00b7 $((guard_blocks + 1))/3] Autowork guard: the deliverable changed but the final quality loop is incomplete."
else
  reason="[Quality gate \u00b7 $((guard_blocks + 1))/3] Autowork guard: edits were made but the final quality loop is incomplete."
fi

if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
  # --- Dimension gate (Check 4) ---
  #
  # Standard gates passed. For complex tasks (unique edit count above
  # the dimension-gate threshold), require the prescribed reviewer
  # sequence: quality-reviewer → metis → excellence-reviewer → (editor-critic
  # if docs were touched) → briefing-analyst (if very complex). Each
  # dimension is ticked by its specific reviewer; the gate blocks with
  # a message naming the specific next reviewer to run, removing the
  # "which reviewer do I dispatch next" guessing game.
  #
  # Resumed sessions from pre-fix state get one free pass: if
  # resume_source_session_id is set and no dimensions are ticked yet,
  # allow the first stop. This prevents a session resumed mid-way from
  # being force-marched through the full sequence.

  required_dims="$(get_required_dimensions)"
  if [[ -n "${required_dims}" ]]; then
    missing_dims="$(missing_dimensions "${required_dims}")"

    if [[ -n "${missing_dims}" ]]; then
      # Resumed-session first-stop grace: skip the dimension gate once
      # when no dimensions have been ticked yet in this resumed session.
      resume_src="$(read_state "resume_source_session_id")"
      dim_grace_used="$(read_state "dimension_resume_grace_used")"
      any_dim_ticked=0
      for _tok in ${required_dims//,/ }; do
        tick_ts_val="$(read_state "$(_dim_key "${_tok}")")"
        if [[ -n "${tick_ts_val}" ]]; then
          any_dim_ticked=1
          break
        fi
      done

      if [[ -n "${resume_src}" && "${any_dim_ticked}" -eq 0 && "${dim_grace_used}" != "1" ]]; then
        write_state "dimension_resume_grace_used" "1"
        log_hook "stop-guard" "dimension gate: resumed-session grace granted"
      else
        dim_blocks="$(read_state "dimension_guard_blocks")"
        dim_blocks="${dim_blocks:-0}"

        if [[ "${dim_blocks}" -lt 3 ]]; then
          write_state "dimension_guard_blocks" "$((dim_blocks + 1))"
          next_dim="${missing_dims%%,*}"
          next_reviewer="$(reviewer_for_dimension "${next_dim}")"
          next_description="$(describe_dimension "${next_dim}")"
          dim_reason="[Dimension gate \u00b7 $((dim_blocks + 1))/3] Autowork guard: complex task requires prescribed review coverage. Missing dimensions: ${missing_dims}. Next step: run \`${next_reviewer}\` to cover ${next_description}. Each reviewer owns a distinct dimension — do not substitute or reorder. After the reviewer returns, address any findings, then retry stop. After completing this, restate your key deliverable summary at the end of your response."
          if [[ "${dim_blocks}" -ge 2 ]]; then
            dim_reason="${dim_reason} NOTE: this is the final dimension-gate block — the next stop attempt will bypass this check."
          fi
          jq -nc --arg reason "${dim_reason}" '{"decision":"block","reason":$reason}'
          exit 0
        else
          # Exhaustion: allow stop but record why for diagnostics.
          write_state_batch \
            "guard_exhausted" "$(now_epoch)" \
            "guard_exhausted_detail" "dimensions_missing=${missing_dims}"
          log_hook "stop-guard" "dimension gate exhausted after 3 blocks: missing=${missing_dims}"
        fi
      fi
    fi
  fi

  # --- Excellence gate (Check 5) ---
  #
  # Legacy excellence gate is retained for backward compatibility and
  # operates on the legacy last_edit_ts comparison. On complex tasks
  # that already satisfied the dimension gate (which ticks completeness
  # via excellence-reviewer), this check is a no-op because
  # last_excellence_review_ts will be current.
  edited_files_log="$(session_file "edited_files.log")"
  unique_edited_count=0
  if [[ -f "${edited_files_log}" ]]; then
    unique_edited_count="$(sort -u "${edited_files_log}" | wc -l | tr -d '[:space:]')"
  fi

  last_excellence_review_ts="$(read_state "last_excellence_review_ts")"
  excellence_guard_triggered="$(read_state "excellence_guard_triggered")"

  if [[ "${unique_edited_count}" -ge "${OMC_EXCELLENCE_FILE_COUNT}" ]] \
    && [[ -z "${last_excellence_review_ts}" || "${last_excellence_review_ts}" -lt "${last_edit_ts}" ]] \
    && [[ "${excellence_guard_triggered}" != "1" ]]; then
    write_state "excellence_guard_triggered" "1"
    jq -nc --arg reason "[Excellence gate \u00b7 1/1] Autowork guard: standard review and verification passed, but this is a complex task (${unique_edited_count} files edited). Before finalizing, run excellence-reviewer for a fresh-eyes holistic evaluation — completeness against the original objective, unknown unknowns, and what a veteran would add. If you have already done a thorough self-assessment and are confident the deliverable is complete and excellent, explain your reasoning and stop. After the excellence review, restate your key deliverable summary at the end of your response." '{"decision":"block","reason":$reason}'
    exit 0
  fi

  # Remove fast-path sentinel; workflow_mode in session_state.json is
  # intentionally preserved so the prompt-intent-router's sticky gate
  # continues injecting specialist routing for the rest of this session.
  rm -f "${STATE_ROOT}/.ulw_active"
  log_hook "stop-guard" "pass: all gates satisfied"
  exit 0
fi

if [[ "${guard_blocks}" -ge 3 ]]; then
  rm -f "${STATE_ROOT}/.ulw_active"
  write_state_batch \
    "guard_exhausted" "$(now_epoch)" \
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify},verify_failed=${verify_failed},unremediated=${review_unremediated}"
  log_hook "stop-guard" "exhausted after 3 blocks: review=${missing_review} verify=${missing_verify} failed=${verify_failed} unremediated=${review_unremediated}"
  exit 0
fi

write_state "stop_guard_blocks" "$((guard_blocks + 1))"

# --- Block-message construction ---
#
# Block 1 emits the full verbose "FIRST self-assess" text — this is the
# one pass every complex task goes through and the self-assessment prompt
# demonstrably helps agents catch completeness gaps on the first round.
#
# Blocks 2–3 switch to a concise form that names only the missing items
# and the next action, reducing the summary-inflation pressure that long
# repeat-message boilerplate produced in pre-fix sessions. The concise
# form still contains the literal tokens `validation` and
# `quality-reviewer` / `editor-critic` so downstream tests and agent
# routing keep working.

# Route the "quality reviewer" label based on whether the edits were
# code (quality-reviewer) or doc-only (editor-critic).
if [[ "${need_doc_review}" -eq 1 && "${need_code_review}" -eq 0 ]]; then
  review_target_label="editor-critic"
  review_domain_verbose="writing"
else
  review_target_label="quality-reviewer"
  review_domain_verbose="coding"
fi

verify_action=""
review_action=""

if [[ "${missing_verify}" -eq 1 ]]; then
  verify_action="run the smallest meaningful validation available"
elif [[ "${verify_failed}" -eq 1 ]]; then
  verify_action="the last verification command failed — fix the underlying issues and re-run verification"
fi

if [[ "${guard_blocks}" -eq 0 ]]; then
  # Block 1: full verbose text. Preserve the existing wording exactly so
  # existing test assertions (seq-D "validation", "quality-reviewer") and
  # agent routing keep working.
  if [[ "${missing_review}" -eq 1 ]]; then
    if [[ "${task_domain}" == "writing" || "${task_domain}" == "research" || "${task_domain}" == "operations" || "${task_domain}" == "general" ]]; then
      review_action="FIRST self-assess: enumerate every component of the original request and mark each as delivered, partial, or missing — continue implementing anything not fully delivered. THEN delegate to editor-critic or another relevant reviewer and address any high-signal findings — the reviewer must evaluate not just quality issues but completeness: does this deliver everything the user asked for?"
    else
      review_action="FIRST self-assess: enumerate every component of the original request and mark each as delivered, partial, or missing — continue implementing anything not fully delivered. THEN delegate to ${review_target_label} and address its highest-signal findings — the reviewer must evaluate not just bugs but completeness: does the implementation cover the full scope of the original task?"
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

  reason="${reason} After completing these steps, restate your key deliverable summary at the end of your response."
else
  # Blocks 2+: concise form. Lists what's still missing and the single
  # next action, without the summary-reinflating self-assess boilerplate.
  missing_items=""
  if [[ "${missing_review}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }review (${review_target_label})"
  fi
  if [[ "${review_unremediated}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }unremediated findings"
  fi
  if [[ "${missing_verify}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }validation"
  fi
  if [[ "${verify_failed}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }failed validation (fix and re-run)"
  fi

  next_action=""
  if [[ "${missing_verify}" -eq 1 ]]; then
    next_action="run the smallest meaningful validation, then delegate ${review_target_label}"
  elif [[ "${verify_failed}" -eq 1 ]]; then
    next_action="fix the failing tests and re-run validation"
  elif [[ "${missing_review}" -eq 1 ]]; then
    next_action="delegate ${review_target_label}"
  elif [[ "${review_unremediated}" -eq 1 ]]; then
    next_action="address the flagged findings or explain why they do not apply"
  fi

  reason="${reason} Still missing: ${missing_items}. Next: ${next_action}."

  if [[ "${guard_blocks}" -ge 2 ]]; then
    reason="${reason} NOTE: this is the final guard block — the next stop attempt will be allowed regardless of quality gate status."
  fi
fi

jq -nc --arg reason "${reason}" '{"decision":"block","reason":$reason}'
