#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or timing-lib
# dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi
capture_ulw_enforcement_interval || exit 0

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Agent" ]]; then
  exit 0
fi

# P4: Halve stall counter on agent delegation rather than full reset.
# Full reset allowed Claude to cycle Read-Agent-Read-Agent indefinitely
# without triggering stall detection. Halving credits the agent dispatch
# as partial progress while still allowing the counter to accumulate if
# the agent calls are not productive.
# Wrapped in state lock to prevent concurrent agent returns from racing.
_halve_stall_counter() {
  local stall_counter
  is_ultrawork_mode || return 0
  stall_counter="$(read_state "stall_counter")"
  stall_counter="${stall_counter:-0}"
  write_state "stall_counter" "$(( stall_counter / 2 ))"
}
with_state_lock _halve_stall_counter

# P3: emit a structured completion capsule, not a second copy of the native
# Agent result. PostToolUse already exposes the result to the parent context;
# copying its first 1000 characters here paid twice and could amplify hostile
# tool text quoted by the subagent. The capsule retains the routing coordinates
# the next action actually needs: identity, verdict, count, and stable IDs.
# Every dynamic field is control-stripped and bounded. In particular, a
# VERDICT-looking prefix is not trusted: only an exact final non-empty line in
# the universal agent vocabulary is admitted, so attacker-authored suffix text
# cannot hitch a ride into additionalContext.
agent_return_capsule="agent=unknown; verdict=UNREPORTED; findings=0; finding_ids=none"
agent_return_recovery=""
requested_agent="$(json_get '.tool_input.subagent_type')"
requested_description="$(json_get '.tool_input.description')"
agent_return_is_background_launch=0
[[ "$(json_get '.tool_input.run_in_background')" != "true" ]] \
  || agent_return_is_background_launch=1
[[ "$(json_get '.tool_response.status')" != "async_launched" ]] \
  || agent_return_is_background_launch=1
[[ "$(json_get '.tool_response.isAsync')" != "true" ]] \
  || agent_return_is_background_launch=1
requested_native_agent_id="$(json_get '.tool_response.agentId')"
[[ -n "${requested_native_agent_id}" ]] \
  || requested_native_agent_id="$(json_get '.tool_response.agent_id')"
if [[ ! "${requested_native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
  requested_native_agent_id=""
fi
requested_dispatch_id=""
if [[ "${requested_description}" =~ (^|[[:space:]])\[review-rebind:([A-Za-z0-9][A-Za-z0-9._-]{0,63})\]([[:space:]]|$) ]]; then
  requested_dispatch_id="${BASH_REMATCH[2]}"
fi

# SubagentStop records one causal outcome for every completion, including
# ignored abandoned/missing-identity returns. Consume that one-shot row here
# instead of selecting a historical same-agent summary. For an older in-flight
# client, a requested echoed ID may fall back first to the newest literal
# exact-agent no-ID outcome, then to a safely namespaced alias.
_completion_outcome_json=""
_completion_outcomes_present=0
_completion_outcome_rejected_reason=""
_completion_cleanup_reconcile_failed=0
_consume_completion_outcome_unlocked() {
  local outcomes_file bundle temp selected changed
  local selected_generation selected_cycle selected_objective_ts
  local current_cycle current_objective_ts selected_agent selected_status
  local selected_verdict selected_revision current_plan_revision
  local selected_revision_raw selected_is_tracked=0
  is_ultrawork_mode || return 0
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  [[ -f "${outcomes_file}" ]] || return 0
  _completion_outcomes_present=1
  [[ -s "${outcomes_file}" ]] || return 0
  bundle="$(jq -sc \
    --arg agent "${requested_agent}" \
    --arg dispatch_id "${requested_dispatch_id}" \
    --arg native_id "${requested_native_agent_id}" \
    --arg generation "${_OMC_ULW_CAPTURED_GENERATION:-migration}" '
      def causal_outcome($row):
        (($row.notification_receipt // false) != true);
      def literal_agent_match($row):
        if $agent == "" then true
        else (($row.agent_type // "") == $agent) end;
      def alias_agent_match($row):
        $dispatch_id != ""
        and $agent != ""
        and (($agent | contains(":")) | not)
        and (($row.agent_type // "") | endswith(":" + $agent));
      def native_agent_match($row):
        $native_id == "" or (($row.native_agent_id // "") == $native_id);
      def bound_agent_match($row):
        (literal_agent_match($row) or alias_agent_match($row))
        and native_agent_match($row);
      def exact_indexes:
        [range(0; length) as $i
          | select(causal_outcome(.[$i]))
          | select(bound_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == $dispatch_id)
          | $i];
      def literal_no_id_indexes:
        [range(0; length) as $i
          | select(causal_outcome(.[$i]))
          | select(literal_agent_match(.[$i]))
          | select(native_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == "")
          | $i];
      def alias_no_id_indexes:
        [range(0; length) as $i
          | select(causal_outcome(.[$i]))
          | select(alias_agent_match(.[$i]))
          | select(native_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == "")
          | $i];
      (if $dispatch_id == "" then
         (literal_no_id_indexes) as $indexes
         | {idx:(if $native_id != "" then ($indexes[0] // null)
                   elif ($indexes | length) == 1 then $indexes[0]
                   else null end),
            retire:(if $native_id == "" and ($indexes | length) > 1
                    then $indexes else [] end)}
       else
         {idx:(exact_indexes[0]
               // literal_no_id_indexes[-1]
               // alias_no_id_indexes[-1]
               // null),
          retire:[]}
       end) as $choice
      | ($choice.idx) as $idx
      | {
          selected:(if $idx == null then null else .[$idx] end),
          changed:($idx != null or (($choice.retire | length) > 0)),
          retired:[range(0; length) as $i
                   | select(($choice.retire | index($i)) != null)
                   | .[$i]],
          remaining:[range(0; length) as $i
                     | select($i != $idx
                         and (($choice.retire | index($i)) == null))
                     | .[$i]]
        }
    ' "${outcomes_file}" 2>/dev/null || true)"
  [[ -n "${bundle}" ]] || return 0
  selected="$(jq -c '.selected // empty' \
    <<<"${bundle}" 2>/dev/null || true)"
  changed="$(jq -r '.changed // false' \
    <<<"${bundle}" 2>/dev/null || true)"
  [[ -n "${selected}" || "${changed}" == "true" ]] || return 0
  # An ignored cleanup outcome doubles as the crash-recovery journal for its
  # exact pending/start pair. Roll that retirement forward before consuming
  # the outcome, including ambiguous legacy no-ID rows that are discarded
  # without attribution. If reconciliation fails, leave every outcome intact
  # so the next callback can retry instead of advertising a blocked replacement.
  if [[ -n "${selected}" ]]; then
    if ! omc_reconcile_ignored_completion_cleanup_unlocked "${selected}"; then
      _completion_cleanup_reconcile_failed=1
      return 1
    fi
  fi
  while IFS= read -r retired_outcome; do
    [[ -n "${retired_outcome}" ]] || continue
    if ! omc_reconcile_ignored_completion_cleanup_unlocked \
        "${retired_outcome}"; then
      _completion_cleanup_reconcile_failed=1
      return 1
    fi
  done < <(jq -c '.retired[]?' <<<"${bundle}" 2>/dev/null || true)
  temp="$(mktemp "${outcomes_file}.XXXXXX")" || return 1
  if ! jq -cr '.remaining[]' <<<"${bundle}" >"${temp}"; then
    rm -f "${temp}"
    return 1
  fi
  if ! mv -f "${temp}" "${outcomes_file}"; then
    rm -f "${temp}"
    return 1
  fi
  # Publish the selected capsule only after its one-shot row was durably
  # removed. A failed rewrite therefore cannot replay the same completion on a
  # later, unrelated PostToolUse event.
  if [[ -n "${selected}" ]]; then
    selected_generation="$(jq -r \
      '.ulw_enforcement_generation // "migration"' \
      <<<"${selected}" 2>/dev/null || true)"
    if [[ "${selected_generation}" != \
        "${_OMC_ULW_CAPTURED_GENERATION:-migration}" ]]; then
      _completion_outcome_rejected_reason="enforcement-interval-changed"
    fi
    selected_cycle="$(jq -r '.objective_cycle_id // 0' \
      <<<"${selected}" 2>/dev/null || true)"
    selected_objective_ts="$(jq -r '.objective_prompt_ts // 0' \
      <<<"${selected}" 2>/dev/null || true)"
    current_cycle="$(read_state "review_cycle_id")"
    current_objective_ts="$(read_state "review_cycle_prompt_ts")"
    if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
      current_objective_ts="$(read_state "last_user_prompt_ts")"
    fi
    [[ "${selected_cycle}" =~ ^[0-9]+$ ]] || selected_cycle=0
    [[ "${selected_objective_ts}" =~ ^[0-9]+$ ]] \
      || selected_objective_ts=0
    [[ "${current_cycle}" =~ ^[0-9]+$ ]] || current_cycle=0
    [[ "${current_objective_ts}" =~ ^[0-9]+$ ]] \
      || current_objective_ts=0
    if [[ -z "${_completion_outcome_rejected_reason}" ]] \
        && { { (( selected_cycle > 0 && current_cycle > 0 \
                    && selected_cycle != current_cycle )); } \
          || { (( selected_objective_ts > 0 && current_objective_ts > 0 \
                    && selected_objective_ts != current_objective_ts )); }; }; then
      _completion_outcome_rejected_reason="prior-objective-completion"
    fi
    if [[ -z "${_completion_outcome_rejected_reason}" ]]; then
      selected_agent="$(jq -r '.agent_type // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      selected_status="$(jq -r '.status // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      selected_verdict="$(jq -r '.verdict // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      selected_revision_raw="$(jq -r '.review_revision // empty' \
        <<<"${selected}" 2>/dev/null || true)"
      if [[ "${selected_revision_raw}" =~ ^[0-9]+$ \
          || "$(read_state "subagent_dispatch_tracking_version")" == "1" \
          || "$(read_state "native_agent_id_tracking_version")" == "1" ]]; then
        selected_is_tracked=1
      fi
      if [[ "${selected_status}" == "accepted" \
          && "$(omc_enforced_terminal_contract_kind \
            "${selected_agent}" 2>/dev/null || true)" == "planner" ]]; then
        if [[ "${selected_is_tracked}" -ne 1 ]]; then
          : # Explicit pre-causality migration outcome.
        else
        selected_revision="$(jq -r '.review_revision // -1' \
          <<<"${selected}" 2>/dev/null || true)"
        current_plan_revision="$(read_state "plan_revision")"
        [[ "${selected_revision}" =~ ^[0-9]+$ ]] || selected_revision=-1
        [[ "${current_plan_revision}" =~ ^[0-9]+$ ]] \
          || current_plan_revision=0
        case "${selected_verdict}" in
          PLAN_READY)
            if (( selected_revision < 0 \
                  || current_plan_revision != selected_revision + 1 )) \
                || [[ "$(read_state "has_plan")" != "true" \
                  || "$(read_state "plan_verdict")" != "PLAN_READY" \
                  || "$(read_state "plan_agent")" != \
                    "${selected_agent}" ]]; then
              _completion_outcome_rejected_reason="plan-generation-changed"
            fi
            ;;
          NEEDS_CLARIFICATION|BLOCKED)
            if (( selected_revision < 0 \
                  || current_plan_revision != selected_revision )) \
                || [[ "$(read_state "has_plan")" != "false" \
                  || "$(read_state "plan_verdict")" != \
                    "${selected_verdict}" \
                  || "$(read_state "plan_agent")" != \
                    "${selected_agent}" ]]; then
              _completion_outcome_rejected_reason="plan-generation-changed"
            fi
            ;;
          *)
            _completion_outcome_rejected_reason="plan-generation-changed"
            ;;
        esac
        fi
      elif [[ "${selected_is_tracked}" -eq 1 ]] \
          && ! omc_pending_stateful_generation_current "${selected}"; then
        case "$(omc_enforced_terminal_contract_kind \
          "${selected_agent}" 2>/dev/null || true)" in
          planner) _completion_outcome_rejected_reason="plan-generation-changed" ;;
          *) _completion_outcome_rejected_reason="review-generation-changed" ;;
        esac
      fi
    fi
    _completion_outcome_json="${selected}"
  fi
}
if [[ "${agent_return_is_background_launch}" -ne 1 ]]; then
  if ! with_state_lock _consume_completion_outcome_unlocked; then
    _completion_cleanup_reconcile_failed=1
  fi
fi

# Hard agent limits can terminate a native call before SubagentStop feedback is
# honored. PostToolUse:Agent is the parent-side convergence point: if an OMC
# reviewer/planner returned, produced no causal completion outcome, and still
# owns one exact current native pending row, recover that same transcript now
# instead of letting the parent announce a notification that cannot arrive.
_retained_contract_pending_json=""
_retained_contract_retry_exhausted=0
_retained_contract_rebind_id=""
_retained_contract_recovery_kind=""
_find_retained_contract_pending_unlocked() {
  local pending_file line row_type row_native row_cycle row_objective_ts
  local current_cycle current_objective_ts candidate="" candidate_original
  local retry_count updated temp_file claim_id claim_ts claim_effects now
  is_ultrawork_mode || return 0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -s "${pending_file}" && ! -L "${pending_file}" ]] || return 0
  current_cycle="$(read_state "review_cycle_id")"
  [[ "${current_cycle}" =~ ^[0-9]+$ ]] || current_cycle=0
  current_objective_ts="$(read_state "review_cycle_prompt_ts")"
  if [[ ! "${current_objective_ts}" =~ ^[0-9]+$ ]]; then
    current_objective_ts="$(read_state "last_user_prompt_ts")"
  fi
  [[ "${current_objective_ts}" =~ ^[0-9]+$ ]] || current_objective_ts=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    row_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${row_type}" == "${requested_agent}" ]] || continue
    row_native="$(jq -r '.native_agent_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    [[ -z "${requested_native_agent_id}" \
        || "${row_native}" == "${requested_native_agent_id}" ]] || continue
    [[ "$(jq -r '.review_dispatch_abandoned // false' \
      <<<"${line}" 2>/dev/null || true)" != "true" ]] || continue
    row_cycle="$(jq -r '.objective_cycle_id // 0' \
      <<<"${line}" 2>/dev/null || true)"
    row_objective_ts="$(jq -r '.objective_prompt_ts // 0' \
      <<<"${line}" 2>/dev/null || true)"
    [[ "${row_cycle}" =~ ^[0-9]+$ ]] || row_cycle=0
    [[ "${row_objective_ts}" =~ ^[0-9]+$ ]] || row_objective_ts=0
    (( current_cycle == 0 || row_cycle == current_cycle )) || continue
    (( current_objective_ts == 0 || row_objective_ts == current_objective_ts )) \
      || continue
    omc_pending_stateful_generation_current "${line}" || continue
    [[ -z "${candidate}" ]] || return 0
    candidate="${line}"
  done <"${pending_file}"
  [[ -n "${candidate}" ]] || return 0
  candidate_original="${candidate}"
  claim_id="$(jq -r '.completion_claim_id // empty' \
    <<<"${candidate}" 2>/dev/null || true)"
  claim_ts="$(jq -r '.completion_claim_ts // 0' \
    <<<"${candidate}" 2>/dev/null || true)"
  claim_effects="$(jq -r '.completion_claim_effects_complete // false' \
    <<<"${candidate}" 2>/dev/null || true)"
  [[ "${claim_ts}" =~ ^[0-9]+$ ]] || claim_ts=0
  now="$(now_epoch)"
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  if [[ -n "${claim_id}" && "${claim_effects}" == "true" ]]; then
    _retained_contract_pending_json="${candidate}"
    _retained_contract_recovery_kind="effects-complete"
    return 0
  elif [[ -n "${claim_id}" && "${claim_ts}" -gt 0 \
      && "${now}" -ge "${claim_ts}" \
      && $((now - claim_ts)) -le 120 ]]; then
    _retained_contract_pending_json="${candidate}"
    _retained_contract_recovery_kind="claim-settling"
    return 0
  elif [[ -n "${claim_id}" ]]; then
    updated="$(jq -c --argjson abandoned_ts "${now}" '
        .review_dispatch_abandoned = true
        | .review_dispatch_abandonment_reason =
            "expired-completion-claim"
        | .review_dispatch_abandoned_ts = $abandoned_ts
      ' <<<"${candidate}" 2>/dev/null || true)"
    _retained_contract_retry_exhausted=1
    _retained_contract_recovery_kind="expired-claim"
  else
    retry_count="$(jq -r '.terminal_contract_retry_count // 0' \
      <<<"${candidate}" 2>/dev/null || true)"
    [[ "${retry_count}" =~ ^[0-9]+$ ]] || retry_count=0
    retry_count=$((retry_count + 1))
    if (( retry_count >= 3 )); then
    updated="$(jq -c --argjson count "${retry_count}" \
      --argjson abandoned_ts "${now}" '
        .terminal_contract_retry_count = $count
        | .review_dispatch_abandoned = true
        | .review_dispatch_abandonment_reason =
            "terminal-contract-parent-retry-exhausted"
        | .review_dispatch_abandoned_ts = $abandoned_ts
      ' <<<"${candidate}" 2>/dev/null || true)"
    _retained_contract_retry_exhausted=1
    else
      updated="$(jq -c --argjson count "${retry_count}" \
        '.terminal_contract_retry_count = $count' \
        <<<"${candidate}" 2>/dev/null || true)"
    fi
  fi
  [[ -n "${updated}" ]] || return 1
  temp_file="$(mktemp "${pending_file}.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if [[ "${line}" == "${candidate_original}" ]]; then
      printf '%s\n' "${updated}" >>"${temp_file}" || {
        rm -f "${temp_file}"
        return 1
      }
    else
      printf '%s\n' "${line}" >>"${temp_file}" || {
        rm -f "${temp_file}"
        return 1
      }
    fi
  done <"${pending_file}"
  mv -f "${temp_file}" "${pending_file}" || {
    rm -f "${temp_file}"
    return 1
  }
  _retained_contract_pending_json="${updated}"
  if [[ "${_retained_contract_retry_exhausted}" -eq 1 ]]; then
    _retained_contract_rebind_id="hard-limit-$(_omc_token_digest \
      "${requested_native_agent_id}|$(now_epoch)" 2>/dev/null \
      | cut -c1-16)"
  fi
}
if [[ "${agent_return_is_background_launch}" -ne 1 \
    && -z "${_completion_outcome_json}" \
    && "${_completion_cleanup_reconcile_failed}" -ne 1 ]] \
    && [[ -n "$(omc_enforced_terminal_contract_kind \
      "${requested_agent}" 2>/dev/null || true)" ]]; then
  with_state_lock _find_retained_contract_pending_unlocked || true
  if [[ -n "${_retained_contract_pending_json}" ]]; then
    _retained_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${_retained_contract_pending_json}" 2>/dev/null || true)"
    _retained_native_id="$(printf '%s' "${_retained_native_id}" \
      | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
    _retained_native_id="${_retained_native_id:0:128}"
    if [[ "${_retained_contract_recovery_kind}" == "claim-settling" ]]; then
      agent_return_recovery=" COMPLETION SETTLING: ${requested_agent} has already returned and its current SubagentStop claim is still publishing evidence. Do not resume, rebind, dispatch a duplicate, or wait for another notification. Re-evaluate the reviewer/plan state after hook settlement."
    elif [[ "${_retained_contract_recovery_kind}" == \
        "effects-complete" ]]; then
      agent_return_recovery=" COMPLETION ALREADY RECORDED: ${requested_agent} has already published its claim-scoped effects. Do not resume, rebind, or dispatch from this PostTool replay. Re-evaluate the committed reviewer/plan state."
    elif [[ "${_retained_contract_recovery_kind}" == "expired-claim" ]]; then
      agent_return_recovery=" TERMINAL CONTRACT RECOVERY: ${requested_agent} retained an expired incomplete completion claim, so that unusable row was retired. Do not resume the old call. If the current gate still needs the role, dispatch a fresh equivalent with description token [review-rebind:${_retained_contract_rebind_id}]."
    elif [[ "${_retained_contract_retry_exhausted}" -eq 1 ]]; then
      agent_return_recovery=" TERMINAL CONTRACT RECOVERY: ${requested_agent} repeatedly returned without a valid causal completion, so the bounded parent-recovery budget is exhausted and the old call was retired. Do not wait for a notification or resume that call. Dispatch a fresh equivalent now with description token [review-rebind:${_retained_contract_rebind_id}]; the partial result is not accepted evidence."
    elif [[ -n "${_retained_native_id}" ]]; then
      agent_return_recovery=" TERMINAL CONTRACT RECOVERY: ${requested_agent} returned without a valid causal completion, but its current transcript is retained (native ID ${_retained_native_id}). Do not wait for a notification. Resume that exact call now using Agent resume or SendMessage; if it cannot resume, explicitly rebind and dispatch a fresh equivalent."
    fi
  fi
fi

if [[ "${_completion_cleanup_reconcile_failed}" -eq 1 ]]; then
  agent_return_recovery=" LIFECYCLE RECOVERY DEGRADED: the durable cleanup journal could not safely reconcile its exact pending/start artifacts, so it was left unconsumed. Do not integrate the raw result, wait for another notification, resume or rebind that call, or dispatch a duplicate. Re-evaluate the current lifecycle state and retry journal convergence; if it still fails, surface the concrete hook/state error instead of promising automatic resume."
fi

latest_summary=""
if [[ -n "${_completion_outcome_json}" ]]; then
  if [[ -n "${_completion_outcome_rejected_reason}" ]]; then
    _rejected_agent="$(jq -r '.agent_type // "unknown"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    _rejected_agent="$(printf '%s' "${_rejected_agent}" \
      | _omc_strip_render_unsafe | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
    _rejected_agent="${_rejected_agent:0:96}"
    [[ -n "${_rejected_agent}" ]] || _rejected_agent="unknown"
    agent_return_capsule="agent=${_rejected_agent}; verdict=IGNORED; findings=0; finding_ids=none; reason=${_completion_outcome_rejected_reason}"
    agent_return_recovery=" STALE AGENT RETURN REJECTED: this ${_rejected_agent} result does not belong to the current objective/review-plan/enforcement generation (${_completion_outcome_rejected_reason}). Do not integrate the parent-visible raw Agent result, resume that old call, or treat it as gate evidence. Re-evaluate only the current pending role."
  else
    _completion_status="$(jq -r '.status // empty' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    if [[ "${_completion_status}" == "accepted" ]]; then
    _accepted_agent="$(jq -r '.agent_type // "unknown"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    _accepted_agent="$(printf '%s' "${_accepted_agent}" \
      | _omc_strip_render_unsafe | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
    _accepted_agent="${_accepted_agent:0:96}"
    [[ -n "${_accepted_agent}" ]] || _accepted_agent="unknown"
    _accepted_verdict="$(jq -r '.verdict // "UNREPORTED"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    if ! printf '%s\n' "${_accepted_verdict}" | grep -Eq \
        '^(CLEAN|SHIP|PLAN_READY|NEEDS_CLARIFICATION|BLOCKED|REPORT_READY|INSUFFICIENT_SOURCES|RESOLVED|HYPOTHESIS|NEEDS_EVIDENCE|NEEDS_PROBLEM_STATEMENT|INSUFFICIENT_OPTIONS|DELIVERED|NEEDS_INPUT|NEEDS_RESEARCH|INCOMPLETE|FINDINGS[[:space:]]+\([0-9]+\)|BLOCK[[:space:]]+\([0-9]+\)|FRAMINGS_READY[[:space:]]+\([3-5]\)|UNREPORTED)$'; then
      _accepted_verdict="UNREPORTED"
    fi
    _accepted_count="$(jq -r '.findings_count // "0"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    [[ "${_accepted_count}" =~ ^[0-9]+$ ]] || _accepted_count=0
    _accepted_count="$(printf '%s' "${_accepted_count}" | sed -E 's/^0+//')"
    _accepted_count="${_accepted_count:-0}"
    (( ${#_accepted_count} <= 4 )) || _accepted_count="9999+"
    _accepted_ids="$(jq -r '.finding_ids // "none"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    if [[ "${_accepted_ids}" != "unstructured" \
        && "${_accepted_ids}" != "none" ]]; then
      _accepted_ids="$(printf '%s' "${_accepted_ids}" \
        | LC_ALL=C tr -cd 'A-Fa-f0-9,')"
      [[ -n "${_accepted_ids}" ]] || _accepted_ids="none"
    fi
    _accepted_ids="${_accepted_ids:0:80}"
    agent_return_capsule="agent=${_accepted_agent}; verdict=${_accepted_verdict}; findings=${_accepted_count}; finding_ids=${_accepted_ids}"
    else
      _ignored_agent="$(jq -r '.agent_type // "unknown"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
      _ignored_agent="$(printf '%s' "${_ignored_agent}" \
      | _omc_strip_render_unsafe | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
      _ignored_agent="${_ignored_agent:0:96}"
      [[ -n "${_ignored_agent}" ]] || _ignored_agent="unknown"
      _ignored_reason_raw="$(jq -r '.reason // "suppressed-completion"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
      _ignored_reason="$(printf '%s' "${_ignored_reason_raw}" \
      | _omc_strip_render_unsafe | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
      _ignored_reason="${_ignored_reason:0:120}"
      agent_return_capsule="agent=${_ignored_agent}; verdict=IGNORED; findings=0; finding_ids=none; reason=${_ignored_reason:-suppressed-completion}"
      if [[ "${_ignored_reason_raw}" == "terminal-contract-retry-exhausted" ]]; then
        _ignored_native_id="$(jq -r '.native_agent_id // empty' \
        <<<"${_completion_outcome_json}" 2>/dev/null || true)"
        _ignored_native_id="$(printf '%s' "${_ignored_native_id}" \
        | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
        _ignored_native_id="${_ignored_native_id:0:128}"
        agent_return_recovery=" TERMINAL CONTRACT RECOVERY: ${_ignored_agent} repeatedly ended without its required final verdict, so the exhausted call${_ignored_native_id:+ (native ID ${_ignored_native_id})} was retired. Do not wait for another notification or resume that call. Re-evaluate current pending work first. If a replacement is already tracked, do not dispatch another. Otherwise: Dispatch a fresh equivalent now. The old partial result is not accepted evidence."
      fi
    fi
  fi
fi

summaries_file="$(session_file "subagent_summaries.jsonl")"
if [[ "${agent_return_is_background_launch}" -ne 1 \
    && -z "${latest_summary}" \
    && "${_completion_cleanup_reconcile_failed}" -ne 1 \
    && "${_completion_outcomes_present}" -eq 0 \
    && -f "${summaries_file}" ]]; then
  # Compatibility only for pre-outcome sessions. Once the causal ledger exists,
  # absence is UNREPORTED rather than permission to reach into history.
  if [[ -n "${requested_agent}" ]]; then
    latest_summary="$(jq -sc --arg agent "${requested_agent}" '
      reverse
      | map(select((.agent_type // "") == $agent
                   or ((.agent_type // "") | endswith(":" + $agent))))
      | .[0] // empty
    ' "${summaries_file}" 2>/dev/null || true)"
  else
    latest_summary="$(tail -n 1 "${summaries_file}")"
  fi
fi
if [[ -n "${latest_summary}" ]]; then
    agent_type_raw="$(jq -r '.agent_type // empty' <<<"${latest_summary}")"
    message_raw="$(jq -r '.message // empty' <<<"${latest_summary}")"
    if [[ -n "${agent_type_raw}" && -n "${message_raw}" ]]; then
      # Agent identities are routing labels, not prose. Keep the namespaced
      # identifier alphabet and cap it before placing it in model context.
      agent_type="$(printf '%s' "${agent_type_raw}" \
        | _omc_strip_render_unsafe \
        | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
      agent_type="${agent_type:0:96}"
      [[ -n "${agent_type}" ]] || agent_type="unknown"

      message="$(printf '%s' "${message_raw}" | _omc_strip_render_unsafe)"
      verdict_line="$(printf '%s\n' "${message}" | awk 'NF { last = $0 } END { print last }')"
      verdict="UNREPORTED"
      if printf '%s\n' "${verdict_line}" | grep -Eq \
          '^VERDICT:[[:space:]]*(CLEAN|SHIP|PLAN_READY|NEEDS_CLARIFICATION|BLOCKED|REPORT_READY|INSUFFICIENT_SOURCES|RESOLVED|HYPOTHESIS|NEEDS_EVIDENCE|NEEDS_PROBLEM_STATEMENT|INSUFFICIENT_OPTIONS|DELIVERED|NEEDS_INPUT|NEEDS_RESEARCH|INCOMPLETE|FINDINGS[[:space:]]+\([1-9][0-9]*\)|BLOCK[[:space:]]+\([1-9][0-9]*\)|FRAMINGS_READY[[:space:]]+\([3-5]\))[[:space:]]*$'; then
        verdict="$(printf '%s' "${verdict_line}" \
          | sed -E 's/^VERDICT:[[:space:]]*//; s/[[:space:]]*$//')"
      fi

      findings_count="$(count_findings_json "${message}" 2>/dev/null || true)"
      [[ "${findings_count}" =~ ^[0-9]+$ ]] || findings_count=0
      # Avoid shell arithmetic on attacker-sized integers. Four digits are
      # ample for a capsule; larger valid arrays are represented as a bound.
      findings_count="$(printf '%s' "${findings_count}" | sed -E 's/^0+//')"
      findings_count="${findings_count:-0}"
      if (( ${#findings_count} > 4 )); then
        findings_count="9999+"
      fi
      finding_ids=""
      finding_index=0
      while IFS= read -r finding_row; do
        [[ -n "${finding_row}" ]] || continue
        finding_claim="$(jq -r '.claim // empty' <<<"${finding_row}" 2>/dev/null || true)"
        [[ -n "${finding_claim}" ]] || continue
        finding_id="$(_finding_id "${agent_type}" "${finding_claim}")"
        finding_ids="${finding_ids:+${finding_ids},}${finding_id}"
        finding_index=$((finding_index + 1))
        (( finding_index >= 5 )) && break
      done < <(extract_findings_json "${message}" 2>/dev/null || true)
      if [[ -z "${finding_ids}" ]] \
        && [[ "${verdict}" =~ ^(FINDINGS|BLOCK|INCOMPLETE|NEEDS_) ]]; then
        finding_ids="unstructured"
      fi
      if [[ "${finding_ids}" != "unstructured" ]]; then
        finding_ids="$(printf '%s' "${finding_ids}" \
          | LC_ALL=C tr -cd 'A-Fa-f0-9,')"
      fi
      finding_ids="${finding_ids:0:80}"
      agent_return_capsule="agent=${agent_type}; verdict=${verdict}; findings=${findings_count}; finding_ids=${finding_ids:-none}"
    fi
fi

# Plan-complexity nudge remains a PostToolUse handoff so it sits beside the
# native Agent return and supports sessions created before modern SubagentStop
# continuation feedback. One-shot: read the pending flag set by record-plan.sh,
# render the notice, then clear it so the next agent return does not re-emit.
plan_complexity_nudge=""
nudge_flag="$(read_state "plan_complexity_nudge_pending")"
if [[ "${nudge_flag}" == "1" ]]; then
  signals="$(read_state "plan_complexity_signals")"
  signals="$(printf '%s' "${signals}" \
    | _omc_strip_render_unsafe \
    | tr '\n\r\t' '   ' \
    | LC_ALL=C tr -cd 'A-Za-z0-9_=.,:+/ -')"
  signals="${signals:0:160}"
  plan_complexity_nudge=" PLAN COMPLEXITY NOTICE: the plan just returned trips the high-complexity threshold (signals: ${signals:-unspecified}). Consider running metis to pressure-test it for hidden assumptions, missing constraints, and weak validation before committing to execution. Apply the anti-anchoring rule: tell metis to treat every planner-stated invariant ('we already have X', 'the contract is Y') as a claim to verify against current code, not a premise to accept."
  with_state_lock_batch "plan_complexity_nudge_pending" ""
fi

task_intent="$(read_state "task_intent")"
if [[ "${task_intent}" == "advisory" ]]; then
  jq -nc --arg ctx "AGENT RETURN CAPSULE: ${agent_return_capsule}.${agent_return_recovery}${plan_complexity_nudge} Use the native Agent result for detail; this capsule intentionally does not duplicate it. Verify load-bearing claims, then check whether other exploration agents are still running. Hold final synthesis until all required returns arrive." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  jq -nc --arg ctx "AGENT RETURN CAPSULE: ${agent_return_capsule}.${agent_return_recovery}${plan_complexity_nudge} Use the native Agent result for detail; this capsule intentionally does not duplicate it. Verify load-bearing claims against the actual code, then proceed." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi
