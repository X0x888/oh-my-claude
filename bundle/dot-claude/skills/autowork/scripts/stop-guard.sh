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
        record_gate_event "advisory" "block" "block_count=1" "block_cap=1"
        advisory_recovery="$(format_gate_recovery_line "read or search the affected code (Read/Grep/Glob), then re-issue your summary citing files inspected. To bypass once with reason, run /ulw-skip.")"
        jq -nc --arg reason "[Advisory gate \u00b7 1/1] this is an advisory task over a codebase, but no code inspection or build/test verification was detected. Before finalizing your response, read or search the actual codebase to ground your recommendations in evidence. If you have already inspected code via other means, briefly list the files inspected and restate your key recommendation at the end.${advisory_recovery}" '{"decision":"block","reason":$reason}'
        exit 0
      fi
    fi
  fi

  if [[ -z "${last_edit_ts}" || -z "${last_user_prompt_ts}" || "${last_edit_ts}" -lt "${last_user_prompt_ts}" ]]; then
    exit 0
  fi
fi

# /ulw-pause carve-out: when the assistant declared a legitimate user-
# decision pause this turn (taste, policy, credible-approach split),
# the session-handoff gate must NOT fire. The pause flag is set by
# bundle/dot-claude/skills/autowork/scripts/ulw-pause.sh and cleared
# automatically at the next user prompt by prompt-intent-router.sh.
# This is the only structured "I'm legitimately paused, not stalling"
# signal in the harness \u2014 see /ulw-pause SKILL.md for usage.
ulw_pause_active="$(read_state "ulw_pause_active" 2>/dev/null || true)"
if [[ "${ulw_pause_active}" != "1" ]] \
  && [[ -n "${last_assistant_message}" ]] \
  && has_unfinished_session_handoff "${last_assistant_message}" \
  && ! is_checkpoint_request "${current_objective}"; then
  if [[ "${session_handoff_blocks}" -lt 2 ]]; then
    write_state "session_handoff_blocks" "$((session_handoff_blocks + 1))"
    record_gate_event "session-handoff" "block" \
      "block_count=$((session_handoff_blocks + 1))" "block_cap=2"
    handoff_recovery="$(format_gate_recovery_line "continue the deferred work now in this session, OR ask the user explicitly whether they want a checkpoint. If you are pausing because the user must decide something you cannot decide autonomously, run /ulw-pause <reason> instead \u2014 that signals a legitimate pause without tripping this gate. To bypass once with reason, run /ulw-skip.")"
    jq -nc --arg reason "[Session-handoff gate \u00b7 $((session_handoff_blocks + 1))/2] your last response explicitly deferred remaining work to a future session. In ultrawork mode, do not stop with 'next wave', 'next phase', or 'ready for a new session' language unless the user explicitly asked for a checkpoint. Continue the remaining work now. If you genuinely must pause for user input, explain the hard blocker or run /ulw-pause <reason>; if you want to checkpoint, ask the user whether they want a checkpoint.${handoff_recovery}" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# Wave-shape gate (F-013): block once when the active wave plan is
# under-segmented per the canonical Phase 8 rule (avg <3 findings/wave
# on a master list of \u22655 findings AND \u22652 waves planned). This catches
# the over-segmentation pattern that produced the v1.21.0 5\u00d71-wave UX
# regression where the model atomized findings into single-finding waves
# and stopped after a polish-grade quality cycle on each one.
#
# Cap = 1. The model gets one chance to reconcile the plan: either
# re-issue assign-wave with merged surfaces, or explicitly accept the
# plan with /ulw-skip <reason> if a single-finding wave is genuinely
# load-bearing for that surface. Fires AFTER session-handoff (already
# checked above) but BEFORE discovered-scope so the structural plan
# error is surfaced before the model races through fixes.
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] \
  && is_execution_intent_value "${task_intent}" \
  && is_wave_plan_under_segmented; then
  wave_shape_blocks="$(read_state "wave_shape_blocks")"
  wave_shape_blocks="${wave_shape_blocks:-0}"
  if [[ "${wave_shape_blocks}" -lt 1 ]]; then
    write_state "wave_shape_blocks" "$((wave_shape_blocks + 1))"
    _ws_total="$(read_total_findings_count)"
    _ws_waves="$(read_active_wave_total)"
    _ws_avg=$((_ws_total / _ws_waves))
    record_gate_event "wave-shape" "block" \
      "block_count=1" "block_cap=1" \
      "total_findings=${_ws_total}" \
      "wave_total=${_ws_waves}" \
      "avg_per_wave=${_ws_avg}"
    wave_shape_recovery="$(format_gate_recovery_line "merge adjacent wave surfaces so the plan reaches avg \u22653 findings/wave (5-10/wave is the canonical target; 3 is the minimum). Re-issue \`record-finding-list.sh assign-wave\` with the merged plan \u2014 note that re-issuing assign-wave alone won't re-arm this gate, so reconcile in one pass. To bypass once with reason \u2014 e.g., 'each finding owns a genuinely separate critical surface' \u2014 run /ulw-skip.")"
    jq -nc --arg reason "[Wave-shape gate \u00b7 1/1] the active wave plan is under-segmented: ${_ws_total} findings across ${_ws_waves} waves (avg ${_ws_avg}/wave; the canonical Phase 8 rule in council/SKILL.md Step 8 is 5-10 findings/wave with \u22653 as the hard floor). Single-finding waves are acceptable only when (a) the master list itself has <5 findings, or (b) one finding is critical enough to own its own wave (rare \u2014 name the reason). Reconcile the plan before proceeding through the wave cycle.${wave_shape_recovery}" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# Discovered-scope gate: when advisory specialists (council lenses, metis,
# briefing-analyst) emit findings during this session, the model must
# explicitly account for each one before stopping \u2014 either ship the fix,
# defer with a stated reason, or call it out as known follow-up risk.
# Silent skipping is the failure mode this gate catches.
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] \
  && is_execution_intent_value "${task_intent}"; then
  scope_file="$(session_file "discovered_scope.jsonl")"
  if [[ -f "${scope_file}" ]]; then
    pending_count="$(read_pending_scope_count)"
    discovered_scope_blocks="$(read_state "discovered_scope_blocks")"
    discovered_scope_blocks="${discovered_scope_blocks:-0}"
    # Cap normally fixed at 2 (block twice, then release with scorecard).
    # When a SUBSTANTIVE wave plan is active (Phase 8 of /council recorded
    # findings.json with N waves AND the plan is NOT under-segmented),
    # raise the cap to N+1 so the gate stays useful across multiple
    # legitimate wave-by-wave commits instead of silently releasing after
    # wave 2 with 20+ findings still pending.
    #
    # F-014 polarity fix: under-segmented plans (avg <3 findings/wave on
    # a master list of >=5 findings) do NOT raise the cap. Closes the
    # bug where 5x1-finding wave plans got cap=6 and released after the
    # 5th narrow wave even though the canonical bar wasn't met. The
    # wave-shape gate above is the front-line defense; the cap polarity
    # is the backstop for plans that bypass it via /ulw-skip.
    wave_total="$(read_active_wave_total)"
    if [[ "${wave_total}" -gt 0 ]] && ! is_wave_plan_under_segmented; then
      scope_block_cap=$((wave_total + 1))
    else
      scope_block_cap=2
    fi
    if [[ "${pending_count}" -gt 0 && "${discovered_scope_blocks}" -lt "${scope_block_cap}" ]]; then
      write_state "discovered_scope_blocks" "$((discovered_scope_blocks + 1))"
      scorecard="$(build_discovered_scope_scorecard 8 || true)"
      wave_progress=""
      if [[ "${wave_total}" -gt 0 ]]; then
        # Counts waves with status="completed", not in-progress — see common.sh.
        waves_completed="$(read_active_waves_completed)"
        wave_progress=" Wave plan: ${waves_completed}/${wave_total} waves completed."
      fi
      record_gate_event "discovered-scope" "block" \
        "block_count=$((discovered_scope_blocks + 1))" \
        "block_cap=${scope_block_cap}" \
        "pending_count=${pending_count}" \
        "wave_total=${wave_total}" \
        "waves_completed=${waves_completed:-0}"
      scope_recovery="$(format_gate_recovery_line "ship/defer/call-out each pending finding individually in your summary, OR run /mark-deferred <reason> to bulk-defer all pending. If you fixed a verified adjacent defect on the same code path during this work, log it via ~/.claude/skills/autowork/scripts/record-serendipity.sh per the Serendipity Rule (core.md). To bypass once with reason, run /ulw-skip.")"
      jq -nc \
        --arg reason "[Discovered-scope gate \u00b7 $((discovered_scope_blocks + 1))/${scope_block_cap}] ${pending_count} finding(s) from advisory specialists were captured this session but not addressed in your final summary.${wave_progress} Top pending findings (severity-ranked):
${scorecard}

For each pending item, do one of: (a) **ship the fix** and reference the file/line in your summary (preferred when the finding is on a surface you are already loaded into — most discovered findings qualify); (b) **append to the active wave plan** via \`record-finding-list.sh add-finding\` + \`assign-wave\` when a wave plan exists and the finding is same-surface or naturally extends the next wave (the harness already has wave-append infrastructure for this); (c) **explicitly defer with a named WHY** via /mark-deferred — the reason must name what the deferral is *waiting on*: 'requires database migration outside this session’s surface', 'blocked by F-042 fix shipping first', 'awaiting stakeholder pricing decision', or 'duplicate'/'obsolete'/'superseded' (self-explanatory single tokens). Bare 'out of scope' / 'not in scope' / 'follow-up' / 'separate task' are rejected by the validator as silent-skip patterns; (d) call it out as a known follow-up risk in your summary when no commitment is being made. Silent skipping is the anti-pattern this gate exists to catch.${scope_recovery}" \
        '{"decision":"block","reason":$reason}'
      exit 0
    fi
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
  reason="[Quality gate \u00b7 $((guard_blocks + 1))/3] the deliverable changed but the final quality loop is incomplete."
else
  reason="[Quality gate \u00b7 $((guard_blocks + 1))/3] edits were made but the final quality loop is incomplete."
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

          # Build a progress checklist so the block message shows where
          # the session stands, not just what is missing. This transforms
          # "you are blocked again" into visible progress.
          _total_dims=0
          _done_dims=0
          _checklist=""
          for _rd in ${required_dims//,/ }; do
            _total_dims=$((_total_dims + 1))
            _rd_desc="$(describe_dimension "${_rd}")"
            _rd_reviewer="$(reviewer_for_dimension "${_rd}")"
            if is_dimension_valid "${_rd}"; then
              _done_dims=$((_done_dims + 1))
              _checklist="${_checklist}\n  [done] ${_rd_desc}"
            elif [[ "${_rd}" == "${next_dim}" ]]; then
              _checklist="${_checklist}\n  [NEXT] ${_rd_desc} -> run \`${_rd_reviewer}\`"
            else
              _checklist="${_checklist}\n  [    ] ${_rd_desc}"
            fi
          done

          dim_reason="[Review coverage \u00b7 $((dim_blocks + 1))/3 \u00b7 ${_done_dims}/${_total_dims} dimensions] complex task requires prescribed review coverage. Progress:${_checklist}\nNext step: run \`${next_reviewer}\` to cover ${next_description}. Each reviewer owns a distinct review area \u2014 do not substitute or reorder. After the reviewer returns, address any findings, then retry stop. After completing this, restate your key deliverable summary at the end of your response."
          if [[ "${dim_blocks}" -ge 2 ]]; then
            dim_reason="${dim_reason} NOTE: this is the final review-coverage block — the next stop attempt will bypass this check."
          fi
          record_gate_event "review-coverage" "block" \
            "block_count=$((dim_blocks + 1))" "block_cap=3" \
            "missing_dims=${missing_dims}" \
            "next_reviewer=${next_reviewer}" \
            "done_dims=${_done_dims}" "total_dims=${_total_dims}"
          jq -nc --arg reason "${dim_reason}" '{"decision":"block","reason":$reason}'
          exit 0
        else
          # Review coverage gate exhaustion: handle based on mode
          with_state_lock_batch \
            "guard_exhausted" "$(now_epoch)" \
            "guard_exhausted_detail" "dimensions_missing=${missing_dims}" \
            "session_outcome" "exhausted"
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
    record_gate_event "excellence" "block" "block_count=1" "block_cap=1" \
      "edited_count=${unique_edited_count}"
    excellence_recovery="$(format_gate_recovery_line "dispatch the excellence-reviewer agent on the wave diff, then restate your deliverable summary. To bypass once with reason (e.g., already self-audited), run /ulw-skip.")"
    jq -nc --arg reason "[Excellence gate \u00b7 1/1] standard review and verification passed, but this is a complex task (${unique_edited_count} files edited). Before finalizing, run excellence-reviewer for a fresh-eyes holistic evaluation — completeness against the original objective, unknown unknowns, and what a veteran would add. If you have already done a thorough self-assessment and are confident the deliverable is complete and excellent, explain your reasoning and stop. After the excellence review, restate your key deliverable summary at the end of your response.${excellence_recovery}" '{"decision":"block","reason":$reason}'
    exit 0
  fi
  fi # end gate_level full|standard (excellence gate)

  # --- Metis-on-plan gate (Check 6, v1.19.0) ---
  #
  # Active when OMC_METIS_ON_PLAN_GATE=on AND record-plan.sh marked the
  # last plan as complex (plan_complexity_high=1). Blocks Stop until
  # metis has run a stress-test review on the current plan, catching
  # the bias-blindness case where the main thread proceeds confidently
  # from a complex plan that no second-opinion agent has audited.
  #
  # Independent of OMC_GATE_LEVEL — opt-in users get this gate even on
  # basic level, since the whole point is to catch a class of error the
  # standard gates miss. record-plan.sh resets metis_gate_blocks on
  # every fresh plan, so the cap=1 semantic is "block once per plan
  # cycle", not "block once per session".
  if [[ "${OMC_METIS_ON_PLAN_GATE}" == "on" ]]; then
    plan_complexity_high="$(read_state "plan_complexity_high")"
    has_plan="$(read_state "has_plan")"
    plan_ts="$(read_state "plan_ts")"
    last_metis_review_ts="$(read_state "last_metis_review_ts")"
    metis_gate_blocks="$(read_state "metis_gate_blocks")"
    metis_gate_blocks="${metis_gate_blocks:-0}"

    # Treat equality as stale (`<=`, not `<`): if both timestamps fall
    # in the same second, the metis review either preceded the plan or
    # was racing it — neither qualifies as a real stress-test of the
    # current plan. Strictly fresh metis runs land at plan_ts + N where
    # N >= 1s (a real review takes much longer than that).
    metis_stale_or_missing=0
    if [[ -z "${last_metis_review_ts}" ]]; then
      metis_stale_or_missing=1
    elif [[ -n "${plan_ts}" ]] && (( last_metis_review_ts <= plan_ts )); then
      metis_stale_or_missing=1
    fi

    if [[ "${plan_complexity_high}" == "1" ]] \
        && [[ "${has_plan}" == "true" ]] \
        && [[ "${metis_stale_or_missing}" -eq 1 ]] \
        && (( metis_gate_blocks < 1 )); then
      plan_complexity_signals="$(read_state "plan_complexity_signals")"
      write_state "metis_gate_blocks" "$((metis_gate_blocks + 1))"
      record_gate_event "metis-on-plan" "block" \
        "block_count=1" "block_cap=1" \
        "complexity_signals=${plan_complexity_signals}"
      metis_recovery="$(format_gate_recovery_line "dispatch the metis agent on the current plan to stress-test for hidden assumptions, missing constraints, and weak validation. To bypass once with reason (e.g., simple greenfield plan), run /ulw-skip.")"
      jq -nc --arg reason "[Metis-on-plan gate · 1/1] the current plan was flagged high-complexity (${plan_complexity_signals}) but no metis stress-test review has run since the plan was recorded. The bias-defense layer requires a fresh-eyes pressure test before execution to catch wrong-abstraction or missing-constraint risks the main thread may have committed to. After metis returns, restate your deliverable summary at the end of your response.${metis_recovery}" '{"decision":"block","reason":$reason}'
      exit 0
    fi
  fi

  # Record session outcome for cross-session analytics. "completed" means
  # all quality gates were satisfied — the harness's strongest signal.
  # Uses locked write for consistency with the exhaustion paths.
  with_state_lock write_state "session_outcome" "completed"
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
    "guard_exhausted_detail" "review=${missing_review},verify=${missing_verify},verify_failed=${verify_failed},unremediated=${review_unremediated},low_confidence=${verify_low_confidence}" \
    "session_outcome" "exhausted"
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
# Fall back to on-demand detection when state is empty — this happens on
# the first missing_verify block, before any verification has run to
# populate `project_test_cmd` in record-verification.sh.
project_test_cmd="$(read_state "project_test_cmd")"
if [[ -z "${project_test_cmd}" ]]; then
  project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  if [[ -n "${project_test_cmd}" ]]; then
    write_state "project_test_cmd" "${project_test_cmd}"
  fi
fi

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
  #
  # UX win (#3): name the detected project_test_cmd in concise messages
  # too, not just in the verbose block-1 path. Without this, a user who
  # ignored the block-1 hint sees increasingly vague prompts — the
  # opposite of what they need. The exact-command hint is the one
  # concrete action that unblocks them, so we repeat it every block.
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
    if [[ -n "${project_test_cmd}" ]]; then
      missing_items="${missing_items:+${missing_items}, }low-confidence validation (run \`${project_test_cmd}\`)"
    else
      missing_items="${missing_items:+${missing_items}, }low-confidence validation (run project test suite)"
    fi
  fi

  next_action=""
  if [[ "${missing_verify}" -eq 1 ]]; then
    if [[ -n "${project_test_cmd}" ]]; then
      next_action="run \`${project_test_cmd}\` (detected project test command), then delegate ${review_target_label}"
    else
      next_action="run the smallest meaningful validation, then delegate ${review_target_label}"
    fi
  elif [[ "${verify_failed}" -eq 1 ]]; then
    next_action="fix the failing tests and re-run validation"
  elif [[ "${verify_low_confidence}" -eq 1 ]]; then
    if [[ -n "${project_test_cmd}" ]]; then
      next_action="run \`${project_test_cmd}\` (detected project test command) for proper validation (current confidence: ${last_verify_confidence}/100)"
    else
      next_action="run the project's test suite for proper validation (current confidence: ${last_verify_confidence}/100)"
    fi
  elif [[ "${missing_review}" -eq 1 ]]; then
    next_action="delegate ${review_target_label}"
  elif [[ "${review_unremediated}" -eq 1 ]]; then
    next_action="address the flagged findings or explain why they do not apply"
  fi

  reason="${reason} Still missing: ${missing_items}.$(format_gate_recovery_line "${next_action}")"

  if [[ "${guard_blocks}" -ge 2 ]]; then
    # Penultimate block: add progress scorecard for visibility
    progress_score="$(compute_progress_score)"
    reason="${reason} NOTE: this is the final guard block — the next stop attempt will be allowed regardless of quality gate status. Progress score: ${progress_score}/100."
  fi
fi

record_gate_event "quality" "block" \
  "block_count=$((guard_blocks + 1))" "block_cap=3" \
  "missing_review=${missing_review}" \
  "missing_verify=${missing_verify}" \
  "verify_failed=${verify_failed}" \
  "verify_low_confidence=${verify_low_confidence}" \
  "review_unremediated=${review_unremediated}"
jq -nc --arg reason "${reason}" '{"decision":"block","reason":$reason}'
