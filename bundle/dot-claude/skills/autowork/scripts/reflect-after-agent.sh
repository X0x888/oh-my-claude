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
requested_agent="$(json_get '.tool_input.subagent_type')"
requested_description="$(json_get '.tool_input.description')"
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
_consume_completion_outcome_unlocked() {
  local outcomes_file bundle temp selected
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  [[ -f "${outcomes_file}" ]] || return 0
  _completion_outcomes_present=1
  [[ -s "${outcomes_file}" ]] || return 0
  bundle="$(jq -sc \
    --arg agent "${requested_agent}" \
    --arg dispatch_id "${requested_dispatch_id}" '
      def literal_agent_match($row):
        if $agent == "" then true
        else (($row.agent_type // "") == $agent) end;
      def alias_agent_match($row):
        $dispatch_id != ""
        and $agent != ""
        and (($agent | contains(":")) | not)
        and (($row.agent_type // "") | endswith(":" + $agent));
      def bound_agent_match($row):
        literal_agent_match($row) or alias_agent_match($row);
      def exact_indexes:
        [range(0; length) as $i
          | select(bound_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == $dispatch_id)
          | $i];
      def literal_no_id_indexes:
        [range(0; length) as $i
          | select(literal_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == "")
          | $i];
      def alias_no_id_indexes:
        [range(0; length) as $i
          | select(alias_agent_match(.[$i]))
          | select((.[$i].review_dispatch_id // "") == "")
          | $i];
      (if $dispatch_id == "" then
         (literal_no_id_indexes[0] // null)
       else
         (exact_indexes[0]
          // literal_no_id_indexes[-1]
          // alias_no_id_indexes[-1]
          // null)
       end) as $idx
      | {
          selected:(if $idx == null then null else .[$idx] end),
          remaining:[range(0; length) as $i | select($i != $idx) | .[$i]]
        }
    ' "${outcomes_file}" 2>/dev/null || true)"
  [[ -n "${bundle}" ]] || return 0
  selected="$(jq -c '.selected // empty' \
    <<<"${bundle}" 2>/dev/null || true)"
  [[ -n "${selected}" ]] || return 0
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
  _completion_outcome_json="${selected}"
}
with_state_lock _consume_completion_outcome_unlocked || true

latest_summary=""
if [[ -n "${_completion_outcome_json}" ]]; then
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
    _ignored_reason="$(jq -r '.reason // "suppressed-completion"' \
      <<<"${_completion_outcome_json}" 2>/dev/null || true)"
    _ignored_reason="$(printf '%s' "${_ignored_reason}" \
      | _omc_strip_render_unsafe | LC_ALL=C tr -cd 'A-Za-z0-9_.:-')"
    _ignored_reason="${_ignored_reason:0:120}"
    agent_return_capsule="agent=${_ignored_agent}; verdict=IGNORED; findings=0; finding_ids=none; reason=${_ignored_reason:-suppressed-completion}"
  fi
fi

summaries_file="$(session_file "subagent_summaries.jsonl")"
if [[ -z "${latest_summary}" \
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

# Plan-complexity nudge (handed off from record-plan.sh because
# SubagentStop does not support additionalContext). One-shot: read
# the pending flag set by record-plan.sh, render the notice, then
# clear the flag so the next agent return doesn't re-emit. Only
# planner-class subagents set the flag, so this fires at most once
# per high-complexity plan. PostToolUse Agent ordering: this hook
# fires AFTER SubagentStop (which sets the flag), so the read is
# already-seeing-the-write.
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
  jq -nc --arg ctx "AGENT RETURN CAPSULE: ${agent_return_capsule}.${plan_complexity_nudge} Use the native Agent result for detail; this capsule intentionally does not duplicate it. Verify load-bearing claims, then check whether other exploration agents are still running. Hold final synthesis until all required returns arrive." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  jq -nc --arg ctx "AGENT RETURN CAPSULE: ${agent_return_capsule}.${plan_complexity_nudge} Use the native Agent result for detail; this capsule intentionally does not duplicate it. Verify load-bearing claims against the actual code, then proceed." '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi
