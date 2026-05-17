#!/usr/bin/env bash

set -euo pipefail

# v1.27.0 (F-020 / F-021): SubagentStop hook uses extract_discovered_findings
# (awk-only) and is_design_contract_emitter (regex-only) — no classifier or
# timing-lib dependency. Opt out of both eager sources.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
LAST_ASSISTANT_MESSAGE="$(json_get '.last_assistant_message')"

if [[ -z "${SESSION_ID}" || -z "${AGENT_TYPE}" || -z "${LAST_ASSISTANT_MESSAGE}" ]]; then
  exit 0
fi

ensure_session_dir

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
    quality-reviewer|excellence-reviewer|editor-critic|design-reviewer|release-reviewer)
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

# Discovered-scope capture: when a whitelisted advisory specialist returns,
# extract its findings to discovered_scope.jsonl so stop-guard can detect
# silent skips. Only fires in ULW mode + when feature flag is on. Failure
# in extraction is non-fatal (extractor returns empty on weird output).
if [[ "${OMC_DISCOVERED_SCOPE}" == "on" ]] && is_ultrawork_mode; then
  _agent_short="${AGENT_TYPE##*:}"
  while IFS= read -r _tgt; do
    if [[ "${AGENT_TYPE}" == "${_tgt}" ]] || [[ "${_agent_short}" == "${_tgt}" ]]; then
      _scope_rows="$(extract_discovered_findings "${_agent_short}" "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null || true)"
      if [[ -n "${_scope_rows}" ]]; then
        append_discovered_scope "${_agent_short}" "${_scope_rows}" &
      else
        # Silent-disarm telemetry: a substantial advisory response that
        # extracts zero findings is suspicious — the specialist may have
        # changed prose style (dropped a `### Findings` heading, switched
        # to prose-only output, etc.) in a way that silently disables the
        # gate. v1.27.0 (F-007) lowered the threshold from 800 → 500
        # chars so shorter prose-only specialist responses also surface,
        # AND emits a `gate=discovered-scope event=zero_capture` row so
        # /ulw-report can aggregate the rate per agent. The anomaly log
        # is preserved for backward compatibility with existing tooling.
        if [[ "${#LAST_ASSISTANT_MESSAGE}" -gt 500 ]]; then
          log_anomaly "discovered_scope_capture" "${_agent_short} returned ${#LAST_ASSISTANT_MESSAGE} chars but extractor caught zero findings"
          record_gate_event "discovered-scope" "zero_capture" \
            "agent=${_agent_short}" \
            "msg_len=${#LAST_ASSISTANT_MESSAGE}" || true
        fi
      fi
      break
    fi
  done < <(discovered_scope_capture_targets)
fi

# Clear the matching pending-agent entry so the pre-compact snapshot does not
# show completed dispatches as still in flight. We remove the FIFO-oldest
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
_clear_pending_match() {
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
  else
    # Nothing matched — preserve the original file, discard the temp copy.
    # (We still rewrote a byte-equivalent copy; mv would be safe too, but
    # avoiding the mv reduces filesystem churn when SubagentStop fires for
    # agents not tracked in pending_agents.jsonl.)
    rm -f "${temp_file}"
  fi
}
with_state_lock _clear_pending_match || true
