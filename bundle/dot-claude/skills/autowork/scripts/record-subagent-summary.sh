#!/usr/bin/env bash

set -euo pipefail

# v1.27.0 (F-020 / F-021): SubagentStop hook uses extract_discovered_findings
# (awk-only) and is_design_contract_emitter (regex-only) — no classifier or
# timing-lib dependency. Opt out of both eager sources.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
# v1.47 (sre-lens R-1): observable fail-open — a silent abort drops this
# subagent's summary + discovered-scope capture.
omc_arm_failopen_err_trap "record-subagent-summary" "(subagent summary / discovered-scope capture lost for this agent)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
_summary_native_agent_id_raw="$(json_get '.agent_id')"
_summary_native_agent_id=""
_summary_native_agent_id_present=0
_summary_native_agent_id_invalid=0
if [[ -n "${_summary_native_agent_id_raw}" ]]; then
  _summary_native_agent_id_present=1
  if [[ "${_summary_native_agent_id_raw}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    _summary_native_agent_id="${_summary_native_agent_id_raw}"
  else
    _summary_native_agent_id_invalid=1
  fi
fi
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${AGENT_TYPE}" ]]; then
  exit 0
fi

ensure_session_dir

# Direct non-ULW Agent use keeps its historical summary behavior. Once a
# session has entered OMC, however, all authoritative completion effects are
# bound to the exact enforcement generation that dispatched the agent.
if [[ "$(workflow_mode)" == "ultrawork" \
    || -n "$(read_state "ulw_enforcement_generation" 2>/dev/null || true)" ]]; then
  is_ultrawork_mode || exit 0
  capture_ulw_enforcement_interval || exit 0
fi

# A stale frozen-batch retry may carry an explicit dispatch binding. Trust it
# only when the exact bounded ID line immediately precedes the final universal
# VERDICT. Without that tail contract, cleanup deliberately removes only an
# unbound (normally abandoned) row and leaves the newer bound retry intact.
_summary_review_dispatch_id=""
_summary_tail="$(printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" \
  | tr -d '\r' \
  | awk 'NF { previous = current; current = $0 }
         END { print previous; print current }')"
_summary_id_line="$(printf '%s\n' "${_summary_tail}" | sed -n '1p')"
_summary_final_line="$(printf '%s\n' "${_summary_tail}" | sed -n '2p')"
_summary_terminal_verdict=""
_summary_informative_verdict=0
_summary_valid_universal_verdict=0
_summary_enforced_contract_kind="$(omc_enforced_terminal_contract_kind \
  "${AGENT_TYPE}" 2>/dev/null || true)"
# The prior empty-message no-op remains intact for informational/custom agents
# and untracked migration sessions. Only a current tracked state-changing
# contract needs to inspect an empty callback so it can keep that call alive.
if [[ -z "${LAST_ASSISTANT_MESSAGE}" ]] \
    && { [[ -z "${_summary_enforced_contract_kind}" ]] \
      || { [[ "$(read_state "subagent_dispatch_tracking_version")" != "1" ]] \
        && [[ "$(read_state "native_agent_id_tracking_version")" != "1" ]]; }; }; then
  exit 0
fi
_summary_valid_enforced_contract=0
if [[ -n "${_summary_enforced_contract_kind}" ]] \
    && omc_enforced_terminal_verdict_valid \
      "${AGENT_TYPE}" "${_summary_final_line}"; then
  _summary_valid_enforced_contract=1
fi
if printf '%s\n' "${_summary_final_line}" | grep -Eq \
    '^VERDICT:[[:space:]]*(CLEAN|SHIP|PLAN_READY|NEEDS_CLARIFICATION|BLOCKED|REPORT_READY|INSUFFICIENT_SOURCES|RESOLVED|HYPOTHESIS|NEEDS_EVIDENCE|NEEDS_PROBLEM_STATEMENT|INSUFFICIENT_OPTIONS|DELIVERED|NEEDS_INPUT|NEEDS_RESEARCH|INCOMPLETE|FINDINGS[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)|BLOCK[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)|FRAMINGS_READY[[:space:]]*\([[:space:]]*[3-5][[:space:]]*\))[[:space:]]*$'; then
  _summary_valid_universal_verdict=1
  _summary_terminal_verdict="$(printf '%s' "${_summary_final_line}" \
    | sed -E 's/^VERDICT:[[:space:]]*([A-Z_]+).*/\1/')"
  # Findings/blocking reviews and an oracle hypothesis still provide the
  # reasoning artifact an implementer can act on. Input/evidence shortages and
  # incomplete/blocked execution do not satisfy uncertainty deliberation.
  case "${_summary_terminal_verdict}" in
    CLEAN|SHIP|FINDINGS|BLOCK|PLAN_READY|REPORT_READY|RESOLVED|HYPOTHESIS|FRAMINGS_READY|DELIVERED)
      _summary_informative_verdict=1
      ;;
  esac
fi
if [[ "${_summary_id_line}" =~ ^REVIEW_DISPATCH_ID:[[:space:]]*([A-Za-z0-9][A-Za-z0-9._-]{0,63})[[:space:]]*$ ]] \
    && [[ "${_summary_valid_universal_verdict}" -eq 1 ]]; then
  _summary_review_dispatch_id="${_summary_id_line#REVIEW_DISPATCH_ID:}"
  _summary_review_dispatch_id="$(printf '%s' "${_summary_review_dispatch_id}" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# Return the current mutation generation for roles whose dedicated reviewer
# hook can reject an in-flight result after a relevant edit. The universal
# summary hook runs independently of record-reviewer.sh, so it must enforce the
# same frozen-generation boundary before persisting summaries, findings, or an
# accepted completion outcome. Planner roles are intentionally excluded: a
# successful record-plan.sh completion advances plan_revision itself, so their
# cross-hook decision needs different causality semantics.
_summary_reviewer_current_revision() {
  local revision=""
  case "${1##*:}" in
    quality-reviewer|code-reviewer)
      revision="$(dimension_freshness_revision "code_quality")" ;;
    editor-critic)
      revision="$(dimension_freshness_revision "prose")" ;;
    excellence-reviewer)
      revision="$(dimension_freshness_revision "completeness")" ;;
    release-reviewer)
      revision="$(read_state "edit_revision")" ;;
    metis)
      revision="$(dimension_freshness_revision "stress_test")" ;;
    briefing-analyst)
      revision="$(dimension_freshness_revision "traceability")" ;;
    design-reviewer)
      revision="$(dimension_freshness_revision "design_quality")" ;;
    *)
      return 1 ;;
  esac
  [[ "${revision}" =~ ^[0-9]+$ ]] || revision=0
  printf '%s' "${revision}"
}

# Atomically claim this completion's exact pending row before interpreting any
# content. The durable claim stays in pending_agents.jsonl through every side
# effect, so an explicit rebind under the same session lock cannot abandon the
# result between validation and commit. Finalization marks effects complete and
# consumes the row; reviewer rows remain claimed until their reviewer-only start
# is consumed too. Abandoned/mismatched/duplicate returns remain non-authoritative.
_claim_summary_pending_unlocked() {
  local pending_file ledger current_ts current_revision line this_type row_id row_native_id
  local existing_claim claim_ts claim_id temp_file updated selected="" replaced=0
  local contract_retry_count=0 contract_retry_cap=3
  local pending_objective_ts current_objective_ts
  local pending_cycle_id current_cycle_id
  local reviewer_current_revision reviewer_start_revision row_version
  pending_file="$(session_file "pending_agents.jsonl")"
  ledger="$(session_file "council_coverage.json")"
  _summary_pending_json=""
  _summary_same_agent_pending=0
  _summary_dispatch_suppressed=1
  _summary_dispatch_suppression_reason="completion-claim-transition-failed"
  _summary_completion_claim_id=""
  _summary_claim_owned=0
  _summary_cleanup_allowed=0
  _summary_contract_retry_required=0
  _summary_contract_retry_exhausted=0
  _current_council_pending_json=""

  # A prior cleanup-only completion may have committed its exact outcome
  # journal before this replay acquired the lock. Converge that transaction
  # first; the replay must never claim or publish a second result for a row
  # whose durable intent is retirement.
  if ! omc_reconcile_all_ignored_completion_cleanups_unlocked; then
    _summary_cleanup_reconcile_failed=1
    return 1
  fi

  if [[ -n "${_OMC_ULW_CAPTURED_GENERATION+x}" ]] \
      && ! is_ultrawork_mode; then
    _summary_dispatch_suppression_reason="enforcement-interval-closed"
    return 0
  fi

  local native_tracking_version bindings_file
  native_tracking_version="$(read_state "native_agent_id_tracking_version")"
  _summary_use_native_agent_id=0
  _summary_native_binding_committed=0
  if [[ "${_summary_native_agent_id_present}" -eq 1 \
      && "${_summary_native_agent_id_invalid}" -eq 1 ]]; then
    _summary_dispatch_suppression_reason="invalid-native-agent-id"
    return 0
  fi
  if [[ "${_summary_native_agent_id_present}" -eq 1 \
      && "${_summary_native_agent_id_invalid}" -eq 0 ]]; then
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && jq -Rse --arg id "${_summary_native_agent_id}" \
          --arg type "${AGENT_TYPE}" '
            [split("\n")[] | select(length > 0)
                | (try fromjson catch {})
                | select((.native_agent_id // "") == $id
                  and (.agent_type // "") == $type)] | length > 0
          ' "${bindings_file}" >/dev/null 2>&1; then
      _summary_native_binding_committed=1
    fi
  fi
  if [[ "${native_tracking_version}" == "1" ]]; then
    if [[ "${_summary_native_agent_id_present}" -eq 0 ]]; then
      _summary_dispatch_suppression_reason="missing-native-agent-id"
      return 0
    elif [[ "${_summary_native_agent_id_invalid}" -eq 1 ]]; then
      _summary_dispatch_suppression_reason="invalid-native-agent-id"
      return 0
    elif [[ "${_summary_native_binding_committed}" -ne 1 ]]; then
      _summary_dispatch_suppression_reason="native-agent-binding-uncommitted"
      return 0
    fi
    _summary_use_native_agent_id=1
  elif [[ "${_summary_native_binding_committed}" -eq 1 ]]; then
    # A committed bind is sufficient even if a migrated state file lost the
    # marker; the registry remains the crash-safe source of truth.
    _summary_use_native_agent_id=1
  fi

  if [[ -f "${pending_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      [[ "${this_type}" == "${AGENT_TYPE}" ]] || continue
      _summary_same_agent_pending=1
      row_id="$(jq -r '.review_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      row_native_id="$(jq -r '.native_agent_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      if { [[ "${_summary_use_native_agent_id}" -eq 1 ]] \
            && [[ "${row_native_id}" == "${_summary_native_agent_id}" ]]; } \
          || { [[ "${_summary_use_native_agent_id}" -eq 0 ]] \
            && [[ -n "${_summary_review_dispatch_id}" ]] \
            && [[ "${row_id}" == "${_summary_review_dispatch_id}" ]] \
            && [[ -z "${row_native_id}" ]]; } \
          || { [[ "${_summary_use_native_agent_id}" -eq 0 ]] \
               && [[ -z "${_summary_review_dispatch_id}" ]] \
               && [[ -z "${row_id}" && -z "${row_native_id}" ]]; }; then
        selected="${line}"
        break
      fi
    done <"${pending_file}"
  fi

  if [[ -n "${selected}" ]] \
      && ! omc_row_enforcement_generation_current "${selected}"; then
    _summary_pending_json="${selected}"
    _summary_dispatch_suppression_reason="enforcement-interval-closed"
    _summary_cleanup_allowed=1
    return 0
  elif [[ -n "${selected}" ]] \
      && [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${selected}" 2>/dev/null || true)" == "true" ]]; then
    _summary_pending_json="${selected}"
    _summary_dispatch_suppression_reason="abandoned-dispatch-completion"
    _summary_cleanup_allowed=1
    return 0
  elif [[ -z "${selected}" && "${_summary_use_native_agent_id}" -eq 1 ]]; then
    _summary_dispatch_suppression_reason="native-agent-id-mismatch"
    return 0
  elif [[ -z "${selected}" \
      && "${_summary_same_agent_pending}" -eq 1 ]]; then
    _summary_dispatch_suppression_reason="dispatch-id-mismatch"
    return 0
  fi

  # Monotonic review_cycle_id is the stable objective identity. Raw prompt
  # revision can advance on a continuation; the timestamp remains a migration
  # fallback and diagnostic coordinate.
  # A late prior-objective specialist may be cleaned up, but it cannot create a
  # summary, satisfy agent-first, persist design state, or add discovered scope
  # to the new objective.
  if [[ -n "${selected}" ]]; then
    pending_objective_ts="$(jq -r '.objective_prompt_ts // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    current_objective_ts="$(read_state "review_cycle_prompt_ts")"
    if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
      current_objective_ts="$(read_state "last_user_prompt_ts")"
    fi
    if [[ "${pending_objective_ts}" =~ ^[0-9]+$ \
        && "${current_objective_ts}" =~ ^[0-9]+$ \
        && "${pending_objective_ts}" != "${current_objective_ts}" ]]; then
      _summary_pending_json="${selected}"
      _summary_dispatch_suppression_reason="prior-objective-completion"
      _summary_cleanup_allowed=1
      return 0
    fi
    pending_cycle_id="$(jq -r '.objective_cycle_id // 0' \
      <<<"${selected}" 2>/dev/null || true)"
    current_cycle_id="$(read_state "review_cycle_id")"
    [[ "${pending_cycle_id}" =~ ^[0-9]+$ ]] || pending_cycle_id=0
    [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
    if (( current_cycle_id > 0 && pending_cycle_id != current_cycle_id )); then
      _summary_pending_json="${selected}"
      _summary_dispatch_suppression_reason="prior-objective-completion"
      _summary_cleanup_allowed=1
      return 0
    fi

    # A role-specific reviewer hook rejects a result when its dispatch-time
    # mutation generation no longer matches the current surface. Enforce that
    # decision here while the same lock protects the selected pending row. This
    # closes both hook orders: if summary runs first it sees the frozen row; if
    # reviewer runs first, pending_agents still retains that row until summary
    # performs its own decision. A rejected result therefore cannot create a
    # universal summary, discovered-scope obligation, Council evidence, or an
    # accepted PostToolUse capsule before record-reviewer.sh rejects it.
    reviewer_current_revision=""
    if reviewer_current_revision="$(_summary_reviewer_current_revision \
        "${AGENT_TYPE}" 2>/dev/null)"; then
      row_version="$(jq -r '.review_dispatch_causality_version // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      reviewer_start_revision="$(jq -r '.review_revision // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      if [[ "${row_version}" != "1" \
          || "$(read_state "review_dispatch_tracking_version")" != "1" \
          || ! "${reviewer_start_revision}" =~ ^[0-9]+$ \
          || ! "${reviewer_current_revision}" =~ ^[0-9]+$ \
          || ! "${pending_objective_ts}" =~ ^[0-9]+$ \
          || ! "$(jq -r '.objective_prompt_revision // empty' \
            <<<"${selected}" 2>/dev/null || true)" =~ ^[0-9]+$ \
          || ! "${pending_cycle_id}" =~ ^[0-9]+$ ]]; then
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="invalid-review-start-snapshot"
        _summary_cleanup_allowed=1
        return 0
      elif (( reviewer_start_revision != reviewer_current_revision )); then
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="review-generation-changed"
        _summary_cleanup_allowed=1
        return 0
      fi
    fi
  fi

  # An invalid planner contract has not advanced plan_revision, so its frozen
  # generation can be checked without the valid-plan hook-order ambiguity
  # (record-plan may publish and increment before summary sees a valid return).
  # Never revive a partial planner whose plan generation already changed.
  if [[ -n "${selected}" \
      && "${_summary_enforced_contract_kind}" == "planner" \
      && "${_summary_valid_enforced_contract}" -ne 1 ]] \
      && ! omc_pending_stateful_generation_current "${selected}"; then
    _summary_pending_json="${selected}"
    _summary_dispatch_suppression_reason="plan-generation-changed"
    _summary_cleanup_allowed=1
    return 0
  fi

  # Current OMC reviewer/planner calls do not terminate on narration such as
  # "Tests pass. Let me typecheck…". Preserve both causal ledgers and ask
  # Claude Code's SubagentStop continuation channel to keep this exact native
  # call running. The check belongs after identity/objective/generation
  # validation and before the completion claim, so stale or abandoned work is
  # never revived and neither parallel completion hook can publish partial
  # evidence.
  if [[ -n "${selected}" \
      && -n "${_summary_enforced_contract_kind}" \
      && "${_summary_valid_enforced_contract}" -ne 1 ]] \
      && { [[ "$(read_state "subagent_dispatch_tracking_version")" == "1" ]] \
        || [[ "$(read_state "native_agent_id_tracking_version")" == "1" ]] \
        || [[ "$(jq -r '.review_dispatch_causality_version // 0' \
          <<<"${selected}" 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]]; }; then
    contract_retry_count="$(jq -r '.terminal_contract_retry_count // 0' \
      <<<"${selected}" 2>/dev/null || true)"
    [[ "${contract_retry_count}" =~ ^[0-9]+$ ]] || contract_retry_count=0
    contract_retry_count=$((contract_retry_count + 1))
    updated="$(jq -c --argjson count "${contract_retry_count}" '
      .terminal_contract_retry_count = $count
    ' <<<"${selected}" 2>/dev/null || true)"
    [[ -n "${updated}" ]] || return 1
    temp_file="$(mktemp "${pending_file}.XXXXXX")" || return 1
    replaced=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if [[ "${replaced}" -eq 0 && "${line}" == "${selected}" ]]; then
        printf '%s\n' "${updated}" >>"${temp_file}" || {
          rm -f "${temp_file}"
          return 1
        }
        replaced=1
      else
        printf '%s\n' "${line}" >>"${temp_file}" || {
          rm -f "${temp_file}"
          return 1
        }
      fi
    done <"${pending_file}"
    [[ "${replaced}" -eq 1 ]] || {
      rm -f "${temp_file}"
      return 1
    }
    mv -f "${temp_file}" "${pending_file}" || return 1
    _summary_pending_json="${updated}"
    if (( contract_retry_count < contract_retry_cap )); then
      _summary_contract_retry_required=1
      _summary_dispatch_suppression_reason="incomplete-terminal-contract"
    else
      _summary_contract_retry_exhausted=1
      _summary_dispatch_suppression_reason="terminal-contract-retry-exhausted"
      # The exact call has now ignored two in-agent continuations and returned
      # malformed a third time. Let it reach the parent once, retire both
      # causal rows in the cleanup-only finalizer, and require a fresh dispatch
      # rather than creating an unbounded SendMessage loop on the same call.
      _summary_cleanup_allowed=1
    fi
    return 0
  fi

  if [[ -n "${selected}" ]]; then
    existing_claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    if [[ -n "${existing_claim}" ]]; then
      _summary_dispatch_suppression_reason="completion-already-claimed"
      return 0
    fi

    claim_ts="$(now_epoch)"
    [[ "${claim_ts}" =~ ^[0-9]+$ ]] || claim_ts=0
    claim_id="completion-${claim_ts}-$$"
    updated="$(jq -c \
      --arg claim_id "${claim_id}" \
      --argjson claim_ts "${claim_ts}" '
        . + {
          completion_claim_id:$claim_id,
          completion_claim_ts:$claim_ts,
          completion_claim_effects_complete:false
        }
      ' <<<"${selected}")"
    temp_file="$(mktemp "${pending_file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      if [[ "${replaced}" -eq 0 && "${line}" == "${selected}" ]]; then
        printf '%s\n' "${updated}" >>"${temp_file}"
        replaced=1
      else
        printf '%s\n' "${line}" >>"${temp_file}"
      fi
    done <"${pending_file}"
    if [[ "${replaced}" -ne 1 ]]; then
      rm -f "${temp_file}"
      return 1
    fi
    mv "${temp_file}" "${pending_file}"
    _summary_pending_json="${updated}"
    _summary_completion_claim_id="${claim_id}"
    _summary_claim_owned=1
    _summary_cleanup_allowed=1
  fi

  # Once a current dispatcher has armed tracking, a missing bounded row is an
  # eviction/deactivation signal, never an untracked trusted completion. Only
  # pre-marker migration sessions retain the explicit legacy path.
  if [[ -z "${selected}" && "${_summary_same_agent_pending}" -eq 0 \
      && "$(read_state "subagent_dispatch_tracking_version")" == "1" ]]; then
    _summary_dispatch_suppression_reason="missing-pending-dispatch"
    return 0
  fi

  # No same-agent pending row in a pre-marker session is the explicit legacy
  # path. A claimed active row and that migration path may proceed; both
  # decisions were made while the lock excluded rebind.
  _summary_dispatch_suppressed=0
  _summary_dispatch_suppression_reason=""

  # Council provenance is valid only for the already-bound active row and the
  # current objective generation. A stale/manual completion with the same
  # short name cannot inherit Council's structured-output contract.
  [[ -n "${_summary_pending_json}" && -f "${ledger}" ]] || return 0

  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0
  current_cycle_id="$(read_state "review_cycle_id")"
  [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
  if ! jq -e \
      --argjson objective_ts "${current_ts}" \
      --argjson prompt_revision "${current_revision}" \
      --argjson cycle_id "${current_cycle_id}" '
        (.objective_prompt_ts // -1) == $objective_ts
        and (.objective_prompt_revision // -1) == $prompt_revision
        and ($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
      ' "${ledger}" >/dev/null 2>&1; then
    return 0
  fi

  if jq -e \
      --argjson objective_ts "${current_ts}" \
      --argjson prompt_revision "${current_revision}" \
      --argjson cycle_id "${current_cycle_id}" '
          (.purpose // "") == "council"
          and ((.council_phase // "")
               | IN("primary", "gap-fill", "verification"))
          and (.council_objective_prompt_ts // -1) == $objective_ts
          and (.council_objective_prompt_revision // -1) == $prompt_revision
          and ($cycle_id == 0 or (.objective_cycle_id // -1) == $cycle_id)
          and ((.council_selection_agent // "") | length) > 0
        ' <<<"${_summary_pending_json}" >/dev/null 2>&1; then
    _current_council_pending_json="${_summary_pending_json}"
  fi
}

_current_council_pending_json=""
_summary_pending_json=""
_summary_same_agent_pending=0
_summary_dispatch_suppressed=1
_summary_dispatch_suppression_reason="completion-claim-transition-failed"
_summary_completion_claim_id=""
_summary_claim_owned=0
_summary_cleanup_allowed=0
_summary_contract_retry_required=0
_summary_contract_retry_exhausted=0
_summary_cleanup_reconcile_failed=0
with_state_lock _claim_summary_pending_unlocked || true

if [[ "${_summary_cleanup_reconcile_failed}" -eq 1 ]]; then
  record_gate_event "subagent-summary" "cleanup-journal-reconcile-failed" \
    "agent=${AGENT_TYPE}" \
    "native_agent_id=${_summary_native_agent_id:-none}" 2>/dev/null || true
  log_anomaly "record-subagent-summary" \
    "cleanup journal could not reconcile before completion claim for ${AGENT_TYPE}"
  # Leave the unresolved journal first in FIFO and publish no generic outcome:
  # foreground PostTool/background notification recovery owns the explicit
  # degraded directive and must not lose this WAL to seven-day outcome pruning.
  exit 0
fi

if [[ "${_summary_contract_retry_required}" -eq 1 ]]; then
  _summary_contract_hint="$(omc_enforced_terminal_contract_hint \
    "${AGENT_TYPE}")"
  _summary_retry_context="Your response ended at an intermediate checkpoint without the required final ${_summary_enforced_contract_kind} verdict. Continue from the retained context now, finish every outstanding check, and return the complete self-contained ${_summary_enforced_contract_kind} result—not only the missing verdict. Do not stop at another future-tense progress update. Reserve the final turn for exactly one role-valid line: ${_summary_contract_hint}."
  record_gate_event "subagent-summary" "terminal-contract-retry" \
    "agent=${AGENT_TYPE}" \
    "native_agent_id=${_summary_native_agent_id:-none}" 2>/dev/null || true
  jq -nc --arg ctx "$(truncate_chars 1200 "${_summary_retry_context}")" \
    '{hookSpecificOutput:{hookEventName:"SubagentStop",additionalContext:$ctx}}'
  exit 0
fi

if [[ "${_summary_contract_retry_exhausted}" -eq 1 ]]; then
  record_gate_event "subagent-summary" "terminal-contract-retry-exhausted" \
    "agent=${AGENT_TYPE}" \
    "native_agent_id=${_summary_native_agent_id:-none}" 2>/dev/null || true
fi

# A selected Council primary/gap result without an exact final universal
# verdict is not a return. Release its claim but retain the live pending/audit
# attempt so an unbound retry is denied and an explicitly ID-bound replacement
# can supersede it immediately. The stable per-attempt flag makes hook replay
# idempotent; the paid malformed result never creates summaries or coverage.
_summary_invalid_contract_replay=0
_release_invalid_council_claim_unlocked() {
  local pending_file temp line claim_id updated replaced=0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 1
  claim_id="${_summary_completion_claim_id}"
  [[ -n "${claim_id}" ]] || return 1
  temp="$(mktemp "${pending_file}.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if [[ "${replaced}" -eq 0 ]] \
        && [[ "$(jq -r '.completion_claim_id // empty' \
          <<<"${line}" 2>/dev/null || true)" == "${claim_id}" ]]; then
      [[ "$(jq -r '.completion_contract_invalid // false' \
        <<<"${line}" 2>/dev/null || true)" == "true" ]] \
        && _summary_invalid_contract_replay=1
      updated="$(jq -c '
        del(.completion_claim_id,.completion_claim_ts,
            .completion_claim_effects_complete)
        | .completion_contract_invalid = true
      ' <<<"${line}" 2>/dev/null || true)"
      [[ -n "${updated}" ]] || {
        rm -f "${temp}"
        return 1
      }
      line="${updated}"
      replaced=1
    fi
    printf '%s\n' "${line}" >>"${temp}" || {
      rm -f "${temp}"
      return 1
    }
  done <"${pending_file}"
  [[ "${replaced}" -eq 1 ]] || {
    rm -f "${temp}"
    return 1
  }
  mv -f "${temp}" "${pending_file}"
}

if [[ -n "${_current_council_pending_json}" \
    && "${_summary_valid_universal_verdict}" -ne 1 ]]; then
  _summary_council_phase="$(jq -r '.council_phase // empty' \
    <<<"${_current_council_pending_json}" 2>/dev/null || true)"
  if [[ "${_summary_council_phase}" == "primary" \
      || "${_summary_council_phase}" == "gap-fill" \
      || "${_summary_council_phase}" == "verification" ]]; then
    if ! with_state_lock _release_invalid_council_claim_unlocked; then
      exit 1
    fi
    _summary_dispatch_suppressed=1
    _summary_dispatch_suppression_reason="invalid-council-final-verdict"
    _summary_claim_owned=0
    _summary_cleanup_allowed=0

    # This malformed completion is deliberately not a Council return. The
    # still-live pending selection is the durable blocker and recovery handle;
    # creating discovered-scope debt here would outlive a successful rebound
    # and could leak into later objectives.
  fi
fi

if [[ "${_summary_dispatch_suppressed}" -eq 1 ]]; then
  record_gate_event "subagent-summary" "stale-result-ignored" \
    "agent=${AGENT_TYPE}" \
    "reason=${_summary_dispatch_suppression_reason}" 2>/dev/null || true
fi

_summary_deferred_outcome_row=""
_record_completion_outcome() {
  local status="$1" reason="$2" message="$3" mode="${4:-commit}"
  local row verdict="UNREPORTED"
  local findings_count=0 finding_ids="" finding_index=0 finding_row finding_claim finding_id
  local outcome_native_agent_id="" outcome_dispatch_id=""
  local outcome_objective_cycle_id=0 outcome_objective_prompt_ts=0
  local outcome_review_revision=0
  local outcome_enforcement_generation="${_OMC_ULW_CAPTURED_GENERATION:-migration}"
  local cleanup_pending_fingerprint=""
  local cleanup_lifecycle_dispatch_id=""
  local cleanup_journal_version=0
  [[ "${_summary_use_native_agent_id:-0}" -eq 1 ]] \
    && outcome_native_agent_id="${_summary_native_agent_id}"
  # Correlation coordinates come from the row selected under the session lock,
  # never from model-authored tail text. In particular, a late abandoned native
  # call cannot forge the replacement's echoed ID and poison its PostToolUse
  # capsule. Only a genuinely untracked pre-marker accepted migration result
  # may retain the text ID for old-client compatibility.
  if [[ -n "${_summary_pending_json:-}" ]]; then
    outcome_dispatch_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
    outcome_objective_cycle_id="$(jq -r '.objective_cycle_id // 0' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
    outcome_objective_prompt_ts="$(jq -r '.objective_prompt_ts // 0' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
    outcome_review_revision="$(jq -r '.review_revision // 0' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
    outcome_enforcement_generation="$(jq -r \
      '.ulw_enforcement_generation // "migration"' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
  elif [[ "${status}" == "accepted" \
      && "$(read_state "subagent_dispatch_tracking_version")" != "1" \
      && "$(read_state "native_agent_id_tracking_version")" != "1" ]]; then
    outcome_dispatch_id="${_summary_review_dispatch_id}"
  fi
  [[ "${outcome_objective_cycle_id}" =~ ^[0-9]+$ ]] \
    || outcome_objective_cycle_id=0
  [[ "${outcome_objective_prompt_ts}" =~ ^[0-9]+$ ]] \
    || outcome_objective_prompt_ts=0
  [[ "${outcome_review_revision}" =~ ^[0-9]+$ ]] \
    || outcome_review_revision=0
  if [[ "${mode}" == "defer" && -n "${_summary_pending_json:-}" ]]; then
    cleanup_pending_fingerprint="$(_omc_token_digest \
      "${_summary_pending_json}" 2>/dev/null || true)"
    cleanup_lifecycle_dispatch_id="$(jq -r \
      '.lifecycle_dispatch_id // empty' \
      <<<"${_summary_pending_json}" 2>/dev/null || true)"
    if [[ "${cleanup_lifecycle_dispatch_id}" \
        =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]]; then
      cleanup_journal_version=2
    else
      cleanup_lifecycle_dispatch_id=""
      cleanup_journal_version=1
    fi
  fi
  # Every cleanup journal needs the exact selected bytes. Current dispatches
  # also carry a harness-generated immutable lifecycle ID so later abandonment
  # metadata rewrites cannot make the committed row unrecognizable.
  if [[ "${mode}" == "defer" \
      && -z "${cleanup_pending_fingerprint}" ]]; then
    return 1
  fi
  if [[ "${status}" == "accepted" && "${_summary_valid_universal_verdict}" -eq 1 ]]; then
    verdict="$(printf '%s' "${_summary_final_line}" \
      | sed -E 's/^VERDICT:[[:space:]]*//;s/[[:space:]]*$//')"
    findings_count="$(count_findings_json "${message}" 2>/dev/null || true)"
    [[ "${findings_count}" =~ ^[0-9]+$ ]] || findings_count=0
    while IFS= read -r finding_row; do
      [[ -n "${finding_row}" ]] || continue
      finding_claim="$(jq -r '.claim // empty' <<<"${finding_row}" 2>/dev/null || true)"
      [[ -n "${finding_claim}" ]] || continue
      finding_id="$(_finding_id "${AGENT_TYPE}" "${finding_claim}")"
      finding_ids="${finding_ids:+${finding_ids},}${finding_id}"
      finding_index=$((finding_index + 1))
      (( finding_index >= 5 )) && break
    done < <(extract_findings_json "${message}" 2>/dev/null || true)
    if [[ -z "${finding_ids}" ]] \
        && [[ "${verdict}" =~ ^(FINDINGS|BLOCK|INCOMPLETE|NEEDS_) ]]; then
      finding_ids="unstructured"
    fi
  fi
  if [[ "${mode}" == "defer" \
      && "${OMC_TEST_SUMMARY_FAIL_OUTCOME_BUILD:-0}" == "1" ]]; then
    return 1
  fi
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg agent_type "${AGENT_TYPE}" \
    --arg status "${status}" \
    --arg reason "$(truncate_chars 120 "${reason}")" \
    --arg verdict "${verdict}" \
    --argjson findings_count "${findings_count}" \
    --arg finding_ids "${finding_ids:-none}" \
    --arg review_dispatch_id "${outcome_dispatch_id}" \
    --arg native_agent_id "${outcome_native_agent_id}" \
    --argjson objective_cycle_id "${outcome_objective_cycle_id}" \
    --argjson objective_prompt_ts "${outcome_objective_prompt_ts}" \
    --argjson review_revision "${outcome_review_revision}" \
    --arg enforcement_generation "${outcome_enforcement_generation}" \
    --arg cleanup_pending_fingerprint "${cleanup_pending_fingerprint}" \
    --arg cleanup_lifecycle_dispatch_id \
      "${cleanup_lifecycle_dispatch_id}" \
    --argjson cleanup_journal_version "${cleanup_journal_version}" \
    '{ts:$ts,agent_type:$agent_type,status:$status,reason:$reason,
      verdict:$verdict,findings_count:$findings_count,
      finding_ids:$finding_ids,
      objective_cycle_id:$objective_cycle_id,
      objective_prompt_ts:$objective_prompt_ts,
      review_revision:$review_revision,
      ulw_enforcement_generation:$enforcement_generation}
     + if $review_dispatch_id == "" then {} else {
         review_dispatch_id:$review_dispatch_id
       } end
     + if $native_agent_id == "" then {} else {
         native_agent_id:$native_agent_id
       } end
     + if $cleanup_pending_fingerprint == "" then {} else {
         cleanup_journal_version:$cleanup_journal_version,
         cleanup_pending_fingerprint:$cleanup_pending_fingerprint
       } end
     + if $cleanup_lifecycle_dispatch_id == "" then {} else {
         cleanup_lifecycle_dispatch_id:$cleanup_lifecycle_dispatch_id
       } end')"
  if [[ -z "${row}" ]] \
      || ! jq -e 'type == "object"' <<<"${row}" >/dev/null 2>&1; then
    return 1
  fi
  _append_completion_outcome_unlocked() {
    local entry="$1" outcomes_file source temp cutoff
    outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
    [[ ! -L "${outcomes_file}" ]] \
      && { [[ ! -e "${outcomes_file}" ]] || [[ -f "${outcomes_file}" ]]; } \
      || return 1
    source="${outcomes_file}"
    [[ -f "${source}" ]] || source="/dev/null"
    temp="$(mktemp "${outcomes_file}.XXXXXX")" || return 1
    cutoff="$(( $(now_epoch) - 604800 ))"
    # Outcomes are one-shot correlation records, not history. Keep ordinary
    # unconsumed rows for seven days so high fan-out cannot make a late
    # PostToolUse event fall back to history; keep every versioned cleanup WAL
    # until its consumer converges it. Parse once and publish only after the
    # complete staged file exists.
    if ! jq -Rsr \
        --arg entry "${entry}" \
        --argjson cutoff "${cutoff}" '
          [split("\n")[]
            | select(length > 0)
            | . as $raw
            | (try fromjson catch null) as $row
            | select(($row | type) == "object")
            | select(($row | has("cleanup_journal_version"))
                     or (($row.ts | type) == "number"
                         and $row.ts >= $cutoff))
            | $raw]
          + [$entry]
          | .[]
        ' "${source}" >"${temp}"; then
      rm -f "${temp}"
      return 1
    fi
    if ! mv -f "${temp}" "${outcomes_file}"; then
      rm -f "${temp}"
      return 1
    fi
  }
  if [[ "${mode}" == "defer" ]]; then
    _summary_deferred_outcome_row="${row}"
    return 0
  fi
  with_state_lock _append_completion_outcome_unlocked "${row}"
}

if [[ "${_summary_dispatch_suppressed}" -eq 1 \
    && "${_summary_invalid_contract_replay}" -ne 1 ]]; then
  # A one-shot ignored outcome prevents PostToolUse from reaching backward to
  # a historical same-agent summary and presenting it as this completion. Any
  # cleanup-only suppression must publish that outcome in the same locked
  # transaction that retires pending/start rows: otherwise a failed cleanup
  # can tell the parent to dispatch a replacement while the surviving row still
  # blocks it. On any outcome construction/publication failure, retain both
  # causal rows so foreground/background recovery can resume the exact call.
  if [[ "${_summary_cleanup_allowed}" -eq 1 ]]; then
    if ! _record_completion_outcome "ignored" \
        "${_summary_dispatch_suppression_reason}" "" "defer"; then
      _summary_deferred_outcome_row=""
      _summary_cleanup_allowed=0
    fi
  else
    _record_completion_outcome \
      "ignored" "${_summary_dispatch_suppression_reason}" "" || true
  fi
fi

# Deterministic test-only barrier for the adversarial interleaving regression:
# the claim is already durable, but no authoritative side effect has run yet.
if [[ "${_summary_claim_owned}" -eq 1 \
    && -n "${OMC_TEST_SUMMARY_CLAIM_READY_FILE:-}" \
    && -n "${OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE:-}" ]]; then
  printf 'ready\n' >"${OMC_TEST_SUMMARY_CLAIM_READY_FILE}"
  _claim_wait_count=0
  while [[ ! -f "${OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE}" \
      && "${_claim_wait_count}" -lt 200 ]]; do
    sleep 0.05
    _claim_wait_count=$((_claim_wait_count + 1))
  done
fi

# Revalidate the exact generation and durable claim after the test/real-world
# scheduling gap, before any summary, design, scope, Council, or uncertainty
# side effect. `/ulw-off` refuses a live claim under this same state lock.
_summary_claim_still_authorized_unlocked() {
  local pending_file claim_id
  [[ "${_summary_claim_owned}" -eq 1 ]] || return 1
  if [[ -n "${_OMC_ULW_CAPTURED_GENERATION+x}" ]] \
      && ! is_ultrawork_mode; then
    return 1
  fi
  pending_file="$(session_file "pending_agents.jsonl")"
  claim_id="${_summary_completion_claim_id}"
  [[ -n "${claim_id}" && -s "${pending_file}" ]] || return 1
  jq -Rse --arg claim "${claim_id}" '
    any(split("\n")[] | select(length > 0);
      (try fromjson catch {})
      | (.completion_claim_id // "") == $claim)
  ' "${pending_file}" >/dev/null 2>&1
}
if [[ "${_summary_dispatch_suppressed}" -ne 1 \
    && "${_summary_claim_owned}" -eq 1 ]] \
    && ! with_state_lock _summary_claim_still_authorized_unlocked; then
  log_hook "record-subagent-summary" \
    "discarded ${AGENT_TYPE} result reason=enforcement-interval-closed-or-claim-lost"
  exit 0
fi

if [[ "${_summary_dispatch_suppressed}" -ne 1 ]]; then
SUMMARY_MESSAGE_SAFE="$(printf '%s' "${LAST_ASSISTANT_MESSAGE}" | omc_redact_secrets | tr -d '\000')"
append_limited_state \
  "subagent_summaries.jsonl" \
  "$(jq -nc --argjson ts "$(now_epoch)" --arg agent_type "${AGENT_TYPE}" --arg message "${SUMMARY_MESSAGE_SAFE}" '{ts:$ts,agent_type:$agent_type,message:$message}')" \
  "16"

# Agent-first invariant: under /ulw execution the main thread should not
# implement first and use specialists only as after-the-fact cleanup. Record
# the first fresh-context specialist that can legitimately shape the work
# before mutation. Post-hoc verifier/reviewer agents are intentionally
# excluded; they remain required by their own gates but do not satisfy this
# pre-implementation cognition floor.
agent_first_specialist_agent() {
  local agent_short="$1"
  case "${agent_short}" in
    quality-reviewer|excellence-reviewer|editor-critic|design-reviewer|release-reviewer|rigor-reviewer)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

_agent_first_task_intent="$(read_state "task_intent")"
if is_ultrawork_mode && { [[ "${_agent_first_task_intent}" == "execution" ]] || [[ "${_agent_first_task_intent}" == "continuation" ]]; }; then
  _agent_short="${AGENT_TYPE##*:}"
  if agent_first_specialist_agent "${_agent_short}"; then
    _record_agent_first_specialist() {
      local existing
      existing="$(read_state "agent_first_specialist_ts")"
      if [[ -z "${existing}" ]]; then
        write_state_batch \
          "agent_first_specialist_ts" "$(now_epoch)" \
          "agent_first_specialist_type" "${_agent_short}"
      fi
    }
    with_state_lock _record_agent_first_specialist || true
  fi
fi

# Inline design-contract capture: when a UI specialist emits its 9-section
# Design Contract block inline, persist it to <session>/design_contract.md
# so design-reviewer / visual-craft-lens can read it and grade drift even
# when no project-root DESIGN.md exists. Closes the v1.14.x / v1.15.0
# deferred "drift lens for inline contracts" gap. Failure is non-fatal
# (extractor returns empty when no block is present, write is best-effort).
#
# Same hook also feeds cross-session archetype memory: every named
# archetype prior in the contract gets logged so the next session in
# this project can warn the agent against repeating the same anchor.
if is_design_contract_emitter "${AGENT_TYPE}"; then
  _contract_block="$(extract_inline_design_contract "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null || true)"
  if [[ -n "${_contract_block}" ]]; then
    _emitter_short="${AGENT_TYPE##*:}"
    write_session_design_contract "${_emitter_short}" "${_contract_block}" 2>/dev/null || true

    # Archetype memory: each known archetype mentioned in the contract
    # is recorded as a prior for the current project. Background to
    # avoid blocking the SubagentStop return; failure is non-fatal.
    _archetypes="$(extract_design_archetype "${_contract_block}" 2>/dev/null || true)"
    if [[ -n "${_archetypes}" ]]; then
      _platform_state="$(read_state "ui_platform" 2>/dev/null || true)"
      _domain_state="$(read_state "ui_domain" 2>/dev/null || true)"
      _arche_payload="$(printf '%s\n' "${_archetypes}" \
        | jq -Rc --arg plat "${_platform_state}" --arg dom "${_domain_state}" --arg ag "${_emitter_short}" \
            'select(length > 0) | {archetype: ., platform: $plat, domain: $dom, agent: $ag}' \
        2>/dev/null || true)"
      if [[ -n "${_arche_payload}" ]]; then
        printf '%s\n' "${_arche_payload}" \
          | "${SCRIPT_DIR}/record-archetype.sh" >/dev/null 2>&1 &
      fi
    fi
  fi
fi

# Discovered-scope capture has two trust levels:
#   1. Any selected/custom agent may opt into deterministic capture by emitting
#      a valid FINDINGS_JSON contract. This keeps Council's full-roster promise
#      real instead of silently dropping findings from non-prefixed agents.
#   2. Prose heuristics remain restricted to the advisory allowlist because
#      implementation reports and arbitrary custom prose produce noisy lists.
# Dedicated dimension reviewers stay excluded from the generic structured path;
# their findings are enforced by their stricter-verdict dimensions.
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] && is_ultrawork_mode; then
  _agent_short="${AGENT_TYPE##*:}"
  _scope_heuristic_allowed=0
  while IFS= read -r _tgt; do
    if [[ "${AGENT_TYPE}" == "${_tgt}" ]] || [[ "${_agent_short}" == "${_tgt}" ]]; then
      _scope_heuristic_allowed=1
      break
    fi
  done < <(discovered_scope_capture_targets)

  _scope_structured_allowed=1
  case "${_agent_short}" in
    quality-reviewer|excellence-reviewer|release-reviewer|design-reviewer)
      _scope_structured_allowed=0 ;;
  esac
  _scope_structured_rows=""
  # Parse once even for dimension reviewers. Their valid rows are consumed by
  # reviewer-specific hooks rather than duplicated into generic discovered
  # scope, but Council still needs to distinguish a valid contract from a
  # structurally incomplete payload such as `[{}]`.
  _scope_contract_rows="$(extract_findings_json "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null || true)"
  if [[ "${_scope_structured_allowed}" -eq 1 ]]; then
    _scope_structured_rows="${_scope_contract_rows}"
  fi

  # The malformed-contract placeholder is Council-specific: only agents that
  # were dispatched with an explicit Council phase marker were promised this
  # output contract. Valid structured findings remain accepted globally, but
  # an unrelated plugin/manual agent must not be blocked for using its native
  # verdict format.
  _scope_council_contract_expected=0
  if [[ -n "${_current_council_pending_json}" ]]; then
    _scope_pending_phase="$(jq -r '.council_phase // empty' \
      <<<"${_current_council_pending_json}" 2>/dev/null || true)"
    # Primary/gap selections carry the finding-emitter contract. Optional
    # verification is provenance-tracked too, but its job is to confirm or
    # demote an existing claim rather than originate a structured finding set.
    if [[ "${_scope_pending_phase}" == "primary" \
        || "${_scope_pending_phase}" == "gap-fill" ]]; then
      _scope_council_contract_expected=1
    fi
  fi

  # Universal agent verdict contract: find the LAST authoritative verdict
  # outside fenced examples, across every role vocabulary. A selected Council
  # agent that reports any unsuccessful terminal state must provide at least
  # one valid, actionable FINDINGS_JSON row; otherwise its problem cannot
  # silently disappear from the discovered-scope ledger.
  _scope_last_verdict=""
  if [[ "${_summary_valid_universal_verdict}" -eq 1 ]]; then
    _scope_last_verdict="${_summary_final_line}"
  fi
  _scope_unsuccessful_verdict=0
  if printf '%s' "${_scope_last_verdict}" | grep -Eq \
      '^VERDICT:[[:space:]]*(BLOCK|BLOCKED|NEEDS_CLARIFICATION|INSUFFICIENT_SOURCES|HYPOTHESIS|NEEDS_EVIDENCE|NEEDS_PROBLEM_STATEMENT|INSUFFICIENT_OPTIONS|NEEDS_INPUT|NEEDS_RESEARCH|INCOMPLETE)([[:space:]]|$)'; then
    _scope_unsuccessful_verdict=1
  elif printf '%s' "${_scope_last_verdict}" \
      | grep -Eq '^VERDICT:[[:space:]]*FINDINGS([[:space:]]|$)' \
      && ! printf '%s' "${_scope_last_verdict}" \
        | grep -Eiq '^VERDICT:[[:space:]]*FINDINGS[[:space:]]*\((0|none)\)[[:space:]]*$'; then
    _scope_unsuccessful_verdict=1
  fi
  if [[ "${_scope_council_contract_expected}" -eq 1 \
      && "${_summary_valid_universal_verdict}" -ne 1 ]]; then
    _scope_unsuccessful_verdict=1
  fi

  _scope_rows=""
  if [[ -n "${_scope_structured_rows}" || "${_scope_heuristic_allowed}" -eq 1 ]]; then
    _scope_rows="$(extract_discovered_findings "${_agent_short}" "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null || true)"
  fi
  if [[ -n "${_scope_rows}" ]]; then
    append_discovered_scope "${_agent_short}" "${_scope_rows}" &
  elif [[ "${_scope_heuristic_allowed}" -eq 1 ]]; then
    # Silent-disarm telemetry: a substantial allowlisted advisory response
    # that extracts zero findings is suspicious. A CLEAN/SHIP verdict is the
    # legitimate no-findings case and does not emit this diagnostic.
    if [[ "${#LAST_ASSISTANT_MESSAGE}" -gt 500 ]] \
      && ! _omc_last_verdict_is_clean "${LAST_ASSISTANT_MESSAGE}"; then
      log_anomaly "discovered_scope_capture" "${_agent_short} returned ${#LAST_ASSISTANT_MESSAGE} chars but extractor caught zero findings"
      record_gate_event "discovered-scope" "zero_capture" \
        "agent=${_agent_short}" \
        "msg_len=${#LAST_ASSISTANT_MESSAGE}" || true
    fi
  fi

  if [[ "${_scope_council_contract_expected}" -eq 1 \
      && "${_scope_unsuccessful_verdict}" -eq 1 \
      && -z "${_scope_contract_rows}" ]]; then
      # Missing, empty, and structurally invalid payloads all produce zero
      # accepted rows. Record one actionable placeholder; arbitrary prose is
      # still not treated as a substitute for the machine-readable contract.
      _scope_contract_summary="${_agent_short} returned an unsuccessful verdict but omitted the required FINDINGS_JSON payload: a valid non-empty FINDINGS_JSON array is required; re-run it or record the findings explicitly"
      # Every malformed return is a distinct enforcement event. A stable ID
      # per agent would let a later malformed return disappear after the first
      # placeholder had already been resolved. Allocate a monotonic sequence
      # under the state lock, then include it in the finding identity.
      _next_scope_contract_violation_seq() {
        local _seq
        _seq="$(read_state "scope_contract_violation_seq")"
        [[ "${_seq}" =~ ^[0-9]+$ ]] || _seq=0
        _seq=$((_seq + 1))
        write_state "scope_contract_violation_seq" "${_seq}"
        _scope_contract_seq="${_seq}"
      }
      _scope_contract_seq=0
      with_state_lock _next_scope_contract_violation_seq || true
      _scope_contract_id="$(_finding_id "${_agent_short}" "${_scope_contract_summary}|event=${_scope_contract_seq}")"
      _scope_contract_row="$(jq -nc \
        --arg id "${_scope_contract_id}" \
        --arg src "${_agent_short}" \
        --arg sum "${_scope_contract_summary}" \
        --argjson ts "$(now_epoch)" \
        '{id:$id,source:$src,summary:$sum,severity:"medium",status:"pending",reason:"",ts:$ts}')"
      append_discovered_scope "${_agent_short}" "${_scope_contract_row}" &
      record_gate_event "discovered-scope" "zero_capture" \
        "agent=${_agent_short}" \
        "expected=FINDINGS_JSON" \
        "verdict=${_scope_last_verdict}" || true
  fi
fi
fi # accepted or genuinely untracked completion

# Wait for the two intentionally backgrounded writes before declaring the
# durable completion claim effects-complete. A rebind remains denied while the
# claim row exists, including through these final gate-relevant writes.
wait 2>/dev/null || true

_claimed_reviewer_start_exists_unlocked() {
  local row="$1" starts_file line this_type row_id wanted_id
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  [[ -s "${starts_file}" ]] || return 1
  wanted_id="$(jq -r '.review_dispatch_id // empty' <<<"${row}" 2>/dev/null || true)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${this_type}" != "${AGENT_TYPE}" ]]; then
      continue
    fi
    row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
    if { [[ -n "${wanted_id}" && "${row_id}" == "${wanted_id}" ]]; } \
        || { [[ -z "${wanted_id}" && -z "${row_id}" ]]; }; then
      [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${line}" 2>/dev/null || true)" != "true" ]] && return 0
    fi
  done <"${starts_file}"
  return 1
}

_append_current_council_return_unlocked() {
  local entry="$1" objective_ts="$2" prompt_revision="$3" cycle_id="$4"
  local ledger source output
  ledger="$(session_file "council_returns.jsonl")"
  [[ ! -L "${ledger}" ]] \
    && { [[ ! -e "${ledger}" ]] || [[ -f "${ledger}" ]]; } || return 1
  source="${ledger}"
  [[ -f "${source}" ]] || source="/dev/null"
  output="$(mktemp "${ledger}.XXXXXX")" || return 1
  if ! jq -Rsr \
      --arg entry "${entry}" \
      --argjson objective_ts "${objective_ts}" \
      --argjson prompt_revision "${prompt_revision}" \
      --argjson cycle_id "${cycle_id}" '
        def historical($raw):
          (try ($raw | fromjson) catch null) as $row
          | (($row | type) != "object")
            or (($row.objective_prompt_ts // -1) != $objective_ts)
            or (($row.objective_prompt_revision // -1) != $prompt_revision)
            or ($cycle_id > 0 and ($row.objective_cycle_id // -1) != $cycle_id);
        (split("\n") | map(select(length > 0)) + [$entry]) as $lines
        | [$lines | to_entries[]
            | select(historical(.value)) | .key] as $history
        | (($history | length) - 32) as $excess
        | ($history[0:(if $excess > 0 then $excess else 0 end)]) as $drop
        | $lines | to_entries[] | . as $item
        | select(($drop | index($item.key)) == null)
        | $item.value
      ' "${source}" >"${output}"; then
    rm -f "${output}"
    return 1
  fi
  if ! mv -f "${output}" "${ledger}"; then
    rm -f "${output}"
    return 1
  fi
}

# Commit claim-scoped uncertainty/Council provenance and consume the exact row
# under one lock. Reviewer claims stay as effects-complete tombstones only while
# their reviewer-only causal start still exists; whichever of the summary and
# role-specific SubagentStop hooks finishes second removes the final row.
# Abandoned returns take the separate
# cleanup-only path and never execute authoritative side effects.
_finalize_summary_completion_unlocked() {
  local pending_file matched_pending_json="" keep_claim=0
  local cleanup_starts_backup="" cleanup_starts_changed=0
  local cleanup_starts_committed=0 cleanup_pending_fingerprint=""
  local cleanup_start_fingerprint=""
  local cleanup_lifecycle_dispatch_id="" cleanup_journal_version=1
  local starts_file="" starts_temp=""
  local outcomes_file="" outcomes_source="" outcomes_temp=""
  local outcomes_changed=0
  pending_file="$(session_file "pending_agents.jsonl")"
  if [[ "${_summary_claim_owned}" -eq 1 ]]; then
    if [[ -n "${_OMC_ULW_CAPTURED_GENERATION+x}" ]] \
        && ! is_ultrawork_mode; then
      return 1
    fi
    [[ -s "${pending_file}" ]] || return 1
  else
    [[ -f "${pending_file}" ]] || return 0
    [[ -s "${pending_file}" ]] || return 0
  fi

  [[ "${_summary_cleanup_allowed}" -eq 1 ]] || return 0

  local temp_file
  temp_file="$(mktemp "${pending_file}.XXXXXX")" || return 1

  local skipped=0 matched_this_line=0 line line_claim updated
  while IFS= read -r line || [[ -n "${line}" ]]; do
    matched_this_line=0
    if [[ -z "${line}" ]]; then
      continue
    fi
    if [[ "${skipped}" -eq 0 ]]; then
      if [[ "${_summary_claim_owned}" -eq 1 ]]; then
        line_claim="$(jq -r '.completion_claim_id // empty' \
          <<<"${line}" 2>/dev/null || true)"
        if [[ "${line_claim}" == "${_summary_completion_claim_id}" ]]; then
          matched_pending_json="${line}"
          skipped=1
          matched_this_line=1
        fi
      else
        # Cleanup-only rows are unclaimed between classification and this
        # finalizer. Match the exact frozen bytes selected under the prior lock;
        # a concurrent rebind/tombstone mutation must win rather than letting
        # this late callback retire a different same-role row.
        if [[ -n "${_summary_pending_json:-}" \
            && "${line}" == "${_summary_pending_json}" ]]; then
          matched_pending_json="${line}"
          skipped=1
          matched_this_line=1
        fi
      fi
    fi
    if [[ "${matched_this_line}" -eq 1 ]]; then
      continue
    fi
    printf '%s\n' "${line}" >>"${temp_file}"
  done <"${pending_file}"

  if [[ "${skipped}" -ne 1 ]]; then
    rm -f "${temp_file}"
    [[ "${_summary_claim_owned}" -eq 1 ]] && return 1
    return 0
  fi

  if [[ "${_summary_claim_owned}" -ne 1 ]]; then
    cleanup_pending_fingerprint="$(_omc_token_digest \
      "${matched_pending_json}" 2>/dev/null || true)"
    [[ -n "${cleanup_pending_fingerprint}" ]] || {
      rm -f "${temp_file}"
      return 1
    }
    cleanup_lifecycle_dispatch_id="$(jq -r \
      '.lifecycle_dispatch_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    if [[ "${cleanup_lifecycle_dispatch_id}" \
        =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]]; then
      cleanup_journal_version=2
    else
      cleanup_lifecycle_dispatch_id=""
      cleanup_journal_version=1
    fi
    _summary_deferred_outcome_row="$(jq -c \
      --arg fingerprint "${cleanup_pending_fingerprint}" \
      --arg lifecycle_id "${cleanup_lifecycle_dispatch_id}" \
      --argjson version "${cleanup_journal_version}" '
        .cleanup_journal_version = $version
        | .cleanup_pending_fingerprint = $fingerprint
        | if $lifecycle_id == "" then
            del(.cleanup_lifecycle_dispatch_id)
          else .cleanup_lifecycle_dispatch_id = $lifecycle_id end
      ' <<<"${_summary_deferred_outcome_row}" 2>/dev/null || true)"
    [[ -n "${_summary_deferred_outcome_row}" ]] || {
      rm -f "${temp_file}"
      return 1
    }
  fi

  # Cleanup-only stale/abandoned returns must release both halves of the
  # causal pair. The role-specific hook now deliberately leaves an invalid
  # terminal contract untouched so the universal hook can decide whether it
  # is a current retry or a stale completion. Once this hook has classified it
  # stale, retaining the native-bound start would block the mandatory fresh
  # reviewer/planner for up to the abandonment TTL. Stage the exact start now;
  # its content fingerprint joins the cleanup journal before either causal row
  # is published as removed.
  if [[ "${_summary_claim_owned}" -ne 1 && -n "${matched_pending_json}" ]]; then
    local start_line start_type start_native_id start_dispatch_id
    local wanted_type wanted_native_id wanted_dispatch_id start_removed=0
    local start_match_count=0
    starts_file="$(session_file "agent_dispatch_starts.jsonl")"
    wanted_type="$(jq -r '.agent_type // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    wanted_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    wanted_dispatch_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    if [[ -s "${starts_file}" && ! -L "${starts_file}" ]]; then
      cleanup_starts_backup="$(mktemp "${starts_file}.rollback.XXXXXX")" || {
        rm -f "${temp_file}"
        return 1
      }
      if ! cp "${starts_file}" "${cleanup_starts_backup}"; then
        rm -f "${cleanup_starts_backup}" "${temp_file}"
        return 1
      fi
      starts_temp="$(mktemp "${starts_file}.XXXXXX")" || {
        rm -f "${cleanup_starts_backup}" "${temp_file}"
        return 1
      }
      while IFS= read -r start_line || [[ -n "${start_line}" ]]; do
        [[ -n "${start_line}" ]] || continue
        start_type="$(jq -r '.agent_type // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_dispatch_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        if [[ "${start_type}" == "${wanted_type}" ]] \
            && jq -e --argjson target "${matched_pending_json}" '
              def frozen:
                {ts:(.ts // -1),agent_type:(.agent_type // ""),
                 description:(.description // ""),
                 lifecycle_dispatch_id:(.lifecycle_dispatch_id // ""),
                 review_dispatch_id:(.review_dispatch_id // ""),
                 native_agent_id:(.native_agent_id // ""),
                 edit_revision:(.edit_revision // 0),
                 code_revision:(.code_revision // 0),
                 doc_revision:(.doc_revision // 0),
                 bash_revision:(.bash_revision // 0),
                 ui_revision:(.ui_revision // 0),
                 plan_revision:(.plan_revision // 0),
                 review_revision:(.review_revision // 0),
                 objective_prompt_ts:(.objective_prompt_ts // 0),
                 objective_prompt_revision:(.objective_prompt_revision // 0),
                 objective_cycle_id:(.objective_cycle_id // 0),
                 ulw_enforcement_generation:
                   (.ulw_enforcement_generation // "migration")};
              frozen == ($target | frozen)
            ' <<<"${start_line}" >/dev/null 2>&1; then
          start_match_count=$((start_match_count + 1))
          cleanup_start_fingerprint="$(_omc_token_digest \
            "${start_line}" 2>/dev/null || true)"
          [[ -n "${cleanup_start_fingerprint}" ]] || {
            rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
            return 1
          }
          start_removed=1
          continue
        fi
        printf '%s\n' "${start_line}" >>"${starts_temp}" || {
          rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
          return 1
        }
      done <"${starts_file}"
      if (( start_match_count > 1 )); then
        rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
        return 1
      fi
      if [[ "${start_removed}" -eq 1 ]]; then
        _summary_deferred_outcome_row="$(jq -c \
          --arg fingerprint "${cleanup_start_fingerprint}" \
          '. + {cleanup_start_fingerprint:$fingerprint}' \
          <<<"${_summary_deferred_outcome_row}" 2>/dev/null || true)"
        [[ -n "${_summary_deferred_outcome_row}" ]] || {
          rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
          return 1
        }
        cleanup_starts_changed=1
      else
        rm -f "${starts_temp}" "${cleanup_starts_backup}"
        starts_temp=""
        cleanup_starts_backup=""
      fi
    fi
  fi

  if [[ "${_summary_claim_owned}" -eq 1 ]]; then
    # Explicit reasoning uncertainty buys one current-objective deliberation
    # before fixed-model implementation. Bind evidence to the claimed row.
    if [[ "${_summary_informative_verdict}" -eq 1 ]] \
        && [[ "$(omc_agent_declared_model "${AGENT_TYPE}")" == "inherit" ]] \
        && [[ "$(read_state "model_routing_uncertainty")" == "1" ]]; then
      local current_objective_ts pending_objective_ts deliberator_ts
      local current_cycle_id pending_cycle_id
      current_objective_ts="$(read_state "review_cycle_prompt_ts")"
      if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
        current_objective_ts="$(read_state "last_user_prompt_ts")"
      fi
      pending_objective_ts="$(jq -r '.objective_prompt_ts // empty' \
        <<<"${matched_pending_json}" 2>/dev/null || true)"
      current_cycle_id="$(read_state "review_cycle_id")"
      pending_cycle_id="$(jq -r '.objective_cycle_id // 0' \
        <<<"${matched_pending_json}" 2>/dev/null || true)"
      [[ "${current_cycle_id}" =~ ^[0-9]+$ ]] || current_cycle_id=0
      [[ "${pending_cycle_id}" =~ ^[0-9]+$ ]] || pending_cycle_id=0
      if [[ "${current_objective_ts}" =~ ^[0-9]+$ ]] \
          && (( current_objective_ts > 0 )) \
          && [[ "${pending_objective_ts}" == "${current_objective_ts}" ]] \
          && (( current_cycle_id == 0 || pending_cycle_id == current_cycle_id )); then
        deliberator_ts="$(now_epoch)"
        _write_state_batch_unlocked \
          "model_uncertainty_deliberator_ts" "${deliberator_ts}" \
          "model_uncertainty_deliberator_type" "${AGENT_TYPE}" \
          "model_uncertainty_deliberator_objective_ts" "${current_objective_ts}" \
          "model_uncertainty_deliberator_cycle_id" "${current_cycle_id}"
      fi
    fi

    if [[ -n "${_current_council_pending_json}" ]]; then
      local return_row council_contract_valid=false return_native_agent_id=""
      [[ "${_summary_valid_universal_verdict}" -eq 1 ]] \
        && council_contract_valid=true
      [[ "${_summary_use_native_agent_id:-0}" -eq 1 ]] \
        && return_native_agent_id="${_summary_native_agent_id}"
      return_row="$(jq -c \
        --arg actual_agent "${AGENT_TYPE}" \
        --arg native_agent_id "${return_native_agent_id}" \
        --argjson returned_ts "$(now_epoch)" \
        --argjson contract_valid "${council_contract_valid}" '
          {
            ts:$returned_ts,
            actual_agent:$actual_agent,
            selection_agent:.council_selection_agent,
            council_phase:.council_phase,
            objective_prompt_ts:.council_objective_prompt_ts,
            objective_prompt_revision:.council_objective_prompt_revision,
            objective_cycle_id:(.objective_cycle_id // 0),
            ledger_generation:.council_ledger_generation,
            contract_valid:$contract_valid,
            outcome:(if $contract_valid then "returned"
                     else "invalid-contract" end)
          }
          + if $native_agent_id == "" then {} else {
              native_agent_id:$native_agent_id
            } end
        ' <<<"${_current_council_pending_json}" 2>/dev/null || true)"
      if [[ -n "${return_row}" ]]; then
        local return_objective_ts return_prompt_revision return_cycle_id
        return_objective_ts="$(jq -r '.objective_prompt_ts // 0' \
          <<<"${return_row}" 2>/dev/null || true)"
        return_prompt_revision="$(jq -r '.objective_prompt_revision // 0' \
          <<<"${return_row}" 2>/dev/null || true)"
        return_cycle_id="$(jq -r '.objective_cycle_id // 0' \
          <<<"${return_row}" 2>/dev/null || true)"
        [[ "${return_objective_ts}" =~ ^[0-9]+$ ]] || return_objective_ts=0
        [[ "${return_prompt_revision}" =~ ^[0-9]+$ ]] || return_prompt_revision=0
        [[ "${return_cycle_id}" =~ ^[0-9]+$ ]] || return_cycle_id=0
        if ! _append_current_council_return_unlocked "${return_row}" \
            "${return_objective_ts}" "${return_prompt_revision}" \
            "${return_cycle_id}"; then
          rm -f "${temp_file}"
          return 1
        fi
      fi
    fi

    if [[ "$(jq -r '.review_dispatch_causality_version // 0' \
        <<<"${matched_pending_json}" 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]] \
        && _claimed_reviewer_start_exists_unlocked "${matched_pending_json}"; then
      keep_claim=1
    fi
    if [[ "${keep_claim}" -eq 1 ]]; then
      updated="$(jq -c '.completion_claim_effects_complete = true' \
        <<<"${matched_pending_json}")"
      printf '%s\n' "${updated}" >>"${temp_file}"
    fi
  fi

  # A rejected cleanup-only return is one causal publication: the parent
  # recovery outcome and retirement of both pending/start rows must become
  # visible together.
  # Publish the outcome first: it is the durable roll-forward journal and the
  # cleanup transaction's commit point. Before this rename both causal rows are
  # intact. After it, no failure path removes the outcome or restores only one
  # row; foreground/background/admission consumers converge exact fingerprints.
  if [[ -n "${_summary_deferred_outcome_row}" ]]; then
    outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
    if [[ -L "${outcomes_file}" ]] \
        || { [[ -e "${outcomes_file}" ]] \
          && [[ ! -f "${outcomes_file}" ]]; }; then
      rm -f "${starts_temp}" "${cleanup_starts_backup}" \
        "${temp_file}" 2>/dev/null || true
      return 1
    fi
    outcomes_source="${outcomes_file}"
    [[ -f "${outcomes_source}" ]] || outcomes_source="/dev/null"
    outcomes_temp="$(mktemp "${outcomes_file}.XXXXXX")" || {
      rm -f "${starts_temp}" "${cleanup_starts_backup}" \
        "${temp_file}" 2>/dev/null || true
      return 1
    }
    if ! jq -Rsr --arg entry "${_summary_deferred_outcome_row}" \
        --argjson cutoff "$(( $(now_epoch) - 604800 ))" '
          [split("\n")[] | select(length > 0)
           | . as $raw
           | (try fromjson catch null) as $row
           | select(($row | type) == "object")
          | select(($row | has("cleanup_journal_version"))
                   or (($row.ts | type) == "number"
                       and $row.ts >= $cutoff))
           | $raw]
          + [$entry] | .[]
        ' "${outcomes_source}" >"${outcomes_temp}" \
        || ! mv -f "${outcomes_temp}" "${outcomes_file}"; then
      rm -f "${outcomes_temp}" "${starts_temp}" \
        "${cleanup_starts_backup}" "${temp_file}" \
        2>/dev/null || true
      return 1
    fi
    outcomes_changed=1
  fi

  if [[ "${OMC_TEST_SUMMARY_KILL_AFTER_OUTCOME_STAGE:-0}" == "1" \
      && "${outcomes_changed}" -eq 1 ]]; then
    kill -9 "$$"
  fi
  if [[ "${OMC_TEST_SUMMARY_FAIL_AFTER_OUTCOME_STAGE:-0}" == "1" \
      && "${outcomes_changed}" -eq 1 ]]; then
    rm -f "${starts_temp}" "${cleanup_starts_backup}" \
      "${temp_file}" 2>/dev/null || true
    return 1
  fi

  if [[ "${cleanup_starts_changed}" -eq 1 ]]; then
    if ! mv -f "${starts_temp}" "${starts_file}"; then
      rm -f "${starts_temp}" "${cleanup_starts_backup}" \
        "${temp_file}" 2>/dev/null || true
      return 1
    fi
    starts_temp=""
    cleanup_starts_committed=1
  fi
  if [[ "${OMC_TEST_SUMMARY_KILL_AFTER_START_CLEANUP:-0}" == "1" \
      && "${cleanup_starts_committed}" -eq 1 ]]; then
    kill -9 "$$"
  fi

  if ! mv "${temp_file}" "${pending_file}"; then
    rm -f "${temp_file}" "${cleanup_starts_backup}" 2>/dev/null || true
    return 1
  fi
  if [[ "${OMC_TEST_SUMMARY_KILL_AFTER_PENDING_CLEANUP:-0}" == "1" \
      && "${outcomes_changed}" -eq 1 ]]; then
    kill -9 "$$"
  fi
  rm -f "${cleanup_starts_backup}" 2>/dev/null || true
}
_summary_finalize_rc=0
with_state_lock _finalize_summary_completion_unlocked \
  || _summary_finalize_rc=$?
if [[ "${_summary_dispatch_suppressed}" -ne 1 ]]; then
  if [[ "${_summary_finalize_rc}" -eq 0 ]]; then
    _record_completion_outcome "accepted" "" "${LAST_ASSISTANT_MESSAGE}" || true
  else
    record_gate_event "subagent-summary" "completion-finalize-failed" \
      "agent=${AGENT_TYPE}" "rc=${_summary_finalize_rc}" 2>/dev/null || true
    _record_completion_outcome \
      "ignored" "completion-finalize-failed" "" || true
  fi
fi
