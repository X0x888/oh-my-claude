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
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${AGENT_TYPE}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

# Bind Council provenance to one exact in-flight identity and to the current
# objective generation before interpreting this completion. A stale pending
# row from an earlier prompt, or a later manual completion with the same short
# name, must never inherit Council's structured-output contract.
_find_current_council_pending_unlocked() {
  local pending_file ledger current_ts current_revision line this_type
  pending_file="$(session_file "pending_agents.jsonl")"
  ledger="$(session_file "council_coverage.json")"
  _current_council_pending_json=""
  [[ -f "${pending_file}" && -f "${ledger}" ]] || return 0

  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0
  if ! jq -e \
      --argjson objective_ts "${current_ts}" \
      --argjson prompt_revision "${current_revision}" '
        (.objective_prompt_ts // -1) == $objective_ts
        and (.objective_prompt_revision // -1) == $prompt_revision
      ' "${ledger}" >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    [[ "${this_type}" == "${AGENT_TYPE}" ]] || continue
    if jq -e \
        --argjson objective_ts "${current_ts}" \
        --argjson prompt_revision "${current_revision}" '
          (.purpose // "") == "council"
          and ((.council_phase // "")
               | IN("primary", "gap-fill", "verification"))
          and (.council_objective_prompt_ts // -1) == $objective_ts
          and (.council_objective_prompt_revision // -1) == $prompt_revision
          and ((.council_selection_agent // "") | length) > 0
        ' <<<"${line}" >/dev/null 2>&1; then
      _current_council_pending_json="${line}"
      return 0
    fi
  done <"${pending_file}"
}

_current_council_pending_json=""
with_state_lock _find_current_council_pending_unlocked || true

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
  _scope_last_verdict="$(printf '%s\n' "${LAST_ASSISTANT_MESSAGE}" | awk '
    /^(```|~~~)/ { in_code = !in_code; next }
    !in_code && /^VERDICT:[[:space:]]*(CLEAN|SHIP|FINDINGS|BLOCK|PLAN_READY|NEEDS_CLARIFICATION|BLOCKED|REPORT_READY|INSUFFICIENT_SOURCES|RESOLVED|HYPOTHESIS|NEEDS_EVIDENCE|FRAMINGS_READY|NEEDS_PROBLEM_STATEMENT|INSUFFICIENT_OPTIONS|DELIVERED|NEEDS_INPUT|NEEDS_RESEARCH|INCOMPLETE)([[:space:]]|$)/ { last = $0 }
    END { if (last != "") print last }
  ')"
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

# Record a current-objective Council return, then clear the matching pending
# entry so the pre-compact snapshot does not show completed dispatches as
# still in flight. We remove the FIFO-oldest
# match by subagent_type: SubagentStop does not carry a per-dispatch id, so
# exact tracking across same-type concurrent dispatches is not possible. For
# counting purposes (the only thing the snapshot needs), FIFO removal
# preserves the correct pending count.
#
# Robustness: the filter runs line-by-line instead of `jq --slurp`. A single
# malformed JSONL line would abort `--slurp` entirely and freeze the pending
# queue silently. Per-line parsing means one bad line is printed through
# unchanged (preserving as much queue state as possible) while still matching
# and removing the first valid entry with the target agent_type.
_record_return_and_clear_pending_match() {
  local pending_file
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 0
  [[ -s "${pending_file}" ]] || return 0

  local temp_file
  temp_file="$(mktemp "${pending_file}.XXXXXX")"

  local skipped=0
  local line this_type
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" ]]; then
      continue
    fi
    if [[ "${skipped}" -eq 0 ]]; then
      # Parse the line's agent_type field. On parse failure, preserve the
      # line and keep searching — never silently drop data.
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || printf '')"
      if [[ "${this_type}" == "${AGENT_TYPE}" ]]; then
        skipped=1
        continue
      fi
    fi
    printf '%s\n' "${line}"
  done <"${pending_file}" >"${temp_file}"

  if [[ "${skipped}" -eq 1 ]]; then
    mv "${temp_file}" "${pending_file}"
    if [[ -n "${_current_council_pending_json}" ]]; then
      local return_row
      return_row="$(jq -c \
        --arg actual_agent "${AGENT_TYPE}" \
        --argjson returned_ts "$(now_epoch)" '
          {
            ts:$returned_ts,
            actual_agent:$actual_agent,
            selection_agent:.council_selection_agent,
            council_phase:.council_phase,
            objective_prompt_ts:.council_objective_prompt_ts,
            objective_prompt_revision:.council_objective_prompt_revision,
            ledger_generation:.council_ledger_generation
          }
        ' <<<"${_current_council_pending_json}" 2>/dev/null || true)"
      if [[ -n "${return_row}" ]]; then
        append_limited_state "council_returns.jsonl" "${return_row}" "32"
      fi
    fi
  else
    # Nothing matched — preserve the original file, discard the temp copy.
    # (We still rewrote a byte-equivalent copy; mv would be safe too, but
    # avoiding the mv reduces filesystem churn when SubagentStop fires for
    # agents not tracked in pending_agents.jsonl.)
    rm -f "${temp_file}"
  fi
}
with_state_lock _record_return_and_clear_pending_match || true

# v1.42.x SRE F-001: wait for fire-and-forget telemetry children
# (record-archetype subshell at line 95, append_discovered_scope
# at line 111) before the SubagentStop hook returns. Without an
# explicit barrier, Claude Code reaps the process group when this
# parent script exits — backgrounded children writing to the
# archetype log AND discovered_scope.jsonl can be SIGHUPed
# mid-atomic-mv, leaking .XXXXXX files and dropping the gate-
# critical scope rows. discovered_scope.jsonl is read by the
# advisory_no_findings gate, so a dropped row silently disables
# the gate for that SubagentStop. Cheap insurance: both children
# are jq-bound and complete well under the hook timeout budget.
wait 2>/dev/null || true
