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

emit_scorecard_stop_context() {
  local header="$1"
  local footer="$2"
  local scorecard="$3"

  rm -f "${STATE_ROOT}/.ulw_active"
  jq -nc --arg sc "${header}\n${scorecard}\n${footer}" '{
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: $sc
    }
  }'
}

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

# --- Gate skip check (/ulw-skip) ---
# If the user registered a gate skip, honor it if the edit clock has not
# advanced since registration (new edits invalidate the skip). This prevents
# a user from registering a skip, making more edits, and bypassing gates
# on the new work.
gate_skip_reason="$(read_state "gate_skip_reason")"
if [[ -n "${gate_skip_reason}" ]]; then
  gate_skip_edit_ts="$(read_state "gate_skip_edit_ts")"
  current_edit_ts_for_skip="$(read_state "last_edit_ts")"
  gate_skip_edit_ts="${gate_skip_edit_ts:-0}"
  current_edit_ts_for_skip="${current_edit_ts_for_skip:-0}"

  # Clear the skip flag regardless (single-use)
  with_state_lock_batch "gate_skip_reason" "" "gate_skip_ts" "" "gate_skip_edit_ts" ""

  if [[ "${current_edit_ts_for_skip}" -le "${gate_skip_edit_ts}" ]]; then
    # Edit clock unchanged — skip is valid
    record_gate_skip "${gate_skip_reason}" &
    log_hook "stop-guard" "gate skip honored: ${gate_skip_reason}"
    rm -f "${STATE_ROOT}/.ulw_active"
    exit 0
  else
    log_hook "stop-guard" "gate skip invalidated: edits occurred after registration (skip_edit_ts=${gate_skip_edit_ts}, current=${current_edit_ts_for_skip})"
    # Fall through to normal gate logic
  fi
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

# Low-confidence verification: if verification ran but confidence is below
# threshold, treat it as insufficient. A `bash -n file.sh` (confidence ~30)
# should not satisfy the same gate as `npm test` (confidence 70+).
verify_low_confidence=0
if [[ "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 ]]; then
  case "${task_domain}" in
    coding|mixed)
      last_verify_confidence="$(read_state "last_verify_confidence")"
      if [[ -n "${last_verify_confidence}" && "${last_verify_confidence}" =~ ^[0-9]+$ && "${last_verify_confidence}" -lt "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]]; then
        verify_low_confidence=1
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

if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${verify_low_confidence}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
  # --- Review coverage gate (Check 4, formerly "Dimension gate") ---
  #
  # Standard gates passed. For complex tasks (unique edit count above
  # the dimension-gate threshold), require the prescribed reviewer
  # sequence. Each reviewer owns a distinct review dimension; the gate
  # blocks with a message naming the specific next reviewer to run.
  #
  # Only active when gate_level=full. basic and standard skip this gate.

  if [[ "${OMC_GATE_LEVEL}" == "full" ]]; then
  required_dims="$(get_required_dimensions)"
  if [[ -n "${required_dims}" ]]; then
    missing_dims="$(missing_dimensions "${required_dims}")"

    # Reorder missing dims by risk priority
    if [[ -n "${missing_dims}" ]]; then
      _profile="$(get_project_profile 2>/dev/null || true)"
      missing_dims="$(order_dimensions_by_risk "${missing_dims}" "${_profile}")"
    fi

    if [[ -n "${missing_dims}" ]]; then
      # Build human-readable descriptions for the missing reviews
      _missing_descriptions=""
      for _md in ${missing_dims//,/ }; do
        _desc="$(describe_dimension "${_md}")"
        _missing_descriptions="${_missing_descriptions:+${_missing_descriptions}, }${_desc}"
      done

      # Resumed-session first-stop grace: skip the review coverage gate
      # once when no dimensions have been ticked yet in this resumed session.
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
        log_hook "stop-guard" "review coverage gate: resumed-session grace granted"
      else
        dim_blocks="$(read_state "dimension_guard_blocks")"
        dim_blocks="${dim_blocks:-0}"

        if [[ "${dim_blocks}" -lt 3 ]]; then
          write_state "dimension_guard_blocks" "$((dim_blocks + 1))"
          next_dim="${missing_dims%%,*}"
          next_reviewer="$(reviewer_for_dimension "${next_dim}")"
          next_description="$(describe_dimension "${next_dim}")"
          dim_reason="[Review coverage \u00b7 $((dim_blocks + 1))/3] Autowork guard: complex task requires prescribed review coverage. Missing reviews: ${_missing_descriptions}. Next step: run \`${next_reviewer}\` to cover ${next_description}. Each reviewer owns a distinct review area — do not substitute or reorder. After the reviewer returns, address any findings, then retry stop. After completing this, restate your key deliverable summary at the end of your response."
          if [[ "${dim_blocks}" -ge 2 ]]; then
            dim_reason="${dim_reason} NOTE: this is the final review-coverage block — the next stop attempt will bypass this check."
          fi
          jq -nc --arg reason "${dim_reason}" '{"decision":"block","reason":$reason}'
          exit 0
        else
          # Review coverage gate exhaustion: handle based on mode
          with_state_lock_batch \
            "guard_exhausted" "$(now_epoch)" \
            "guard_exhausted_detail" "dimensions_missing=${missing_dims}"
          log_hook "stop-guard" "review coverage gate exhausted after 3 blocks: missing=${missing_dims}"
          scorecard="$(build_quality_scorecard)"

          case "${OMC_GUARD_EXHAUSTION_MODE}" in
            block)
              dim_reason="[Review coverage · BLOCK MODE] Guard exhaustion reached but block mode prevents release. QUALITY SCORECARD:\n${scorecard}\nMissing: ${_missing_descriptions}. Address the remaining reviews or switch to guard_exhaustion_mode=scorecard."
              jq -nc --arg reason "${dim_reason}" '{"decision":"block","reason":$reason}'
              exit 0
              ;;
            scorecard)
              log_hook "stop-guard" "review coverage gate exhausted (scorecard mode): emitting scorecard"
              emit_scorecard_stop_context \
                "QUALITY SCORECARD (review coverage gate exhausted after 3 blocks):" \
                "The review coverage gate released without full completion. Review the scorecard above and note the remaining coverage gaps in your final summary." \
                "${scorecard}"
              exit 0
              ;;
            *)
              rm -f "${STATE_ROOT}/.ulw_active"
              exit 0
              ;;
          esac
        fi
      fi
    fi
  fi
  fi # end gate_level=full (review coverage gate)

  # --- Excellence gate (Check 5) ---
  #
  # Active when gate_level is full or standard. Requires excellence-reviewer
  # for complex tasks (3+ files edited). On tasks that already satisfied
  # the review coverage gate (which ticks completeness via excellence-reviewer),
  # this check is a no-op because last_excellence_review_ts will be current.

  if [[ "${OMC_GATE_LEVEL}" == "full" || "${OMC_GATE_LEVEL}" == "standard" ]]; then
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
  fi # end gate_level full|standard (excellence gate)

  # Remove fast-path sentinel; workflow_mode in session_state.json is
  # intentionally preserved so the prompt-intent-router's sticky gate
  # continues injecting specialist routing for the rest of this session.
  rm -f "${STATE_ROOT}/.ulw_active"
  log_hook "stop-guard" "pass: all gates satisfied"
  exit 0
fi

if [[ "${guard_blocks}" -ge 3 ]]; then
  scorecard="$(build_quality_scorecard)"
  with_state_lock_batch \
    "guard_exhausted" "$(now_epoch)" \
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify},verify_failed=${verify_failed},unremediated=${review_unremediated},low_confidence=${verify_low_confidence}"
  log_hook "stop-guard" "exhausted after 3 blocks: review=${missing_review} verify=${missing_verify} failed=${verify_failed} unremediated=${review_unremediated} low_conf=${verify_low_confidence}"

  case "${OMC_GUARD_EXHAUSTION_MODE}" in
    block)
      # Never release — keep blocking with scorecard
      jq -nc --arg reason "[Quality gate · BLOCK MODE] Guard exhaustion reached but block mode prevents release. QUALITY SCORECARD:\n${scorecard}\nAddress the remaining items or switch to guard_exhaustion_mode=scorecard in oh-my-claude.conf." '{"decision":"block","reason":$reason}'
      exit 0
      ;;
    scorecard)
      # Release but inject scorecard as context
      emit_scorecard_stop_context \
        "QUALITY SCORECARD (guard exhausted after 3 blocks):" \
        "The quality gate released without full completion. Review the scorecard above and note any gaps in your final summary." \
        "${scorecard}"
      exit 0
      ;;
    *)
      # silent (default legacy behavior) — silent release
      rm -f "${STATE_ROOT}/.ulw_active"
      exit 0
      ;;
  esac
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

# If we know the project test command, name it in the verification action.
project_test_cmd="$(read_state "project_test_cmd")"

if [[ "${missing_verify}" -eq 1 ]]; then
  if [[ -n "${project_test_cmd}" ]]; then
    verify_action="run \`${project_test_cmd}\` (detected project test command) to validate"
  else
    verify_action="run the smallest meaningful validation available"
  fi
elif [[ "${verify_failed}" -eq 1 ]]; then
  last_verify_cmd="$(read_state "last_verify_cmd")"
  if [[ -n "${last_verify_cmd}" ]]; then
    verify_action="the last verification (\`${last_verify_cmd}\`) failed — fix the underlying issues and re-run"
  else
    verify_action="the last verification command failed — fix the underlying issues and re-run verification"
  fi
elif [[ "${verify_low_confidence}" -eq 1 ]]; then
  last_verify_cmd="$(read_state "last_verify_cmd")"
  if [[ -n "${project_test_cmd}" ]]; then
    verify_action="the last verification (\`${last_verify_cmd:-unknown}\`) had low confidence (${last_verify_confidence}/100, threshold: ${OMC_VERIFY_CONFIDENCE_THRESHOLD}) — run the project test suite (\`${project_test_cmd}\`) for proper validation"
  else
    verify_action="the last verification had low confidence (${last_verify_confidence}/100) — run a more comprehensive test command (e.g., the project's test suite) instead of a single-file check"
  fi
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
  if [[ "${verify_low_confidence}" -eq 1 ]]; then
    missing_items="${missing_items:+${missing_items}, }low-confidence validation (run project test suite)"
  fi

  next_action=""
  if [[ "${missing_verify}" -eq 1 ]]; then
    next_action="run the smallest meaningful validation, then delegate ${review_target_label}"
  elif [[ "${verify_failed}" -eq 1 ]]; then
    next_action="fix the failing tests and re-run validation"
  elif [[ "${verify_low_confidence}" -eq 1 ]]; then
    next_action="run the project's test suite for proper validation (current confidence: ${last_verify_confidence}/100)"
  elif [[ "${missing_review}" -eq 1 ]]; then
    next_action="delegate ${review_target_label}"
  elif [[ "${review_unremediated}" -eq 1 ]]; then
    next_action="address the flagged findings or explain why they do not apply"
  fi

  reason="${reason} Still missing: ${missing_items}. Next: ${next_action}."

  if [[ "${guard_blocks}" -ge 2 ]]; then
    # Penultimate block: add progress scorecard for visibility
    progress_score="$(compute_progress_score)"
    reason="${reason} NOTE: this is the final guard block — the next stop attempt will be allowed regardless of quality gate status. Progress score: ${progress_score}/100."
  fi
fi

jq -nc --arg reason "${reason}" '{"decision":"block","reason":$reason}'
