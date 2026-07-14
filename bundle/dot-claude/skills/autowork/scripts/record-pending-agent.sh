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

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Agent" ]]; then
  exit 0
fi

ensure_session_dir

subagent_type="$(json_get '.tool_input.subagent_type')"
if [[ -z "${subagent_type}" ]]; then
  subagent_type="general-purpose"
fi

description="$(json_get '.tool_input.description')"
description="$(truncate_chars 260 "${description}")"

# Council dispatches carry an explicit, machine-readable description marker.
# This lets outcome/eval consumers recognize a genuinely selected adaptive
# specialist without guessing from a `*-lens` prefix or counting panel size.
council_phase=""
case "${description}" in
  \[council:primary\]*) council_phase="primary" ;;
  \[council:gap-fill\]*) council_phase="gap-fill" ;;
  \[council:verification\]*) council_phase="verification" ;;
esac

# Append under lock so a concurrent SubagentStop cleanup does not race the write.
# Also increment the subagent dispatch counter for cost/budget visibility.
#
# v1.42.x stop-guard bypass closure (Bypass-Surface F-008):
# Separately track advisory-specialist dispatches. The
# advisory-no-findings stop-guard gate uses this counter to detect
# the "specialists dispatched but no findings recorded" pattern that
# forensics observed (10 sessions in 30d, 37 zero_capture events).
# The advisory set mirrors discovered_scope_capture_targets in
# common.sh — kept in lockstep there.
_is_advisory_specialist() {
  local _type="$1"
  case "${_type##*:}" in
    metis|briefing-analyst|oracle|abstraction-critic|editor-critic|rigor-reviewer) return 0 ;;
    security-lens|data-lens|product-lens|growth-lens|sre-lens|design-lens|visual-craft-lens) return 0 ;;
    *) return 1 ;;
  esac
}

_is_gate_reviewer() {
  local _type="${1##*:}"
  case "${_type}" in
    quality-reviewer|code-reviewer|editor-critic|excellence-reviewer|release-reviewer|metis|briefing-analyst|design-reviewer) return 0 ;;
    *) return 1 ;;
  esac
}

# Versioned reviewer-start rows let record-reviewer distinguish a current
# dispatch from an unversioned, pre-causality session. Keep this local to the
# two producer/consumer hooks: it is a persisted state/row contract, not a
# user-facing configuration surface.
REVIEW_DISPATCH_CAUSALITY_VERSION=1

_gate_reviewer_start_revision() {
  local _type="${1##*:}" _revision=""
  case "${_type}" in
    quality-reviewer|code-reviewer)
      _revision="$(dimension_freshness_revision "code_quality")"
      ;;
    editor-critic)
      _revision="$(dimension_freshness_revision "prose")"
      ;;
    excellence-reviewer)
      _revision="$(dimension_freshness_revision "completeness")"
      ;;
    release-reviewer)
      _revision="$(read_state "edit_revision")"
      ;;
    metis)
      _revision="$(dimension_freshness_revision "stress_test")"
      ;;
    briefing-analyst)
      _revision="$(dimension_freshness_revision "traceability")"
      ;;
    design-reviewer)
      # This helper owns the canonical UI -> code migration fallback. Reading
      # last_ui_edit_revision directly and coercing absence to zero makes a
      # design review dispatched at code revision N look stale immediately.
      _revision="$(dimension_freshness_revision "design_quality")"
      ;;
  esac
  [[ "${_revision}" =~ ^[0-9]+$ ]] || _revision=0
  printf '%s' "${_revision}"
}

# Resolve one Council selection while holding the session lock. Namespaced
# ledger identities are exact: `alpha:auditor` can never authorize
# `beta:auditor`. A legacy/installed unnamespaced selection may bind to a
# namespaced runtime identity once; `resolved_agent` makes that binding
# durable so another namespace with the same short name cannot reuse it.
_authorize_council_dispatch_unlocked() {
  local ledger current_ts current_revision selection selection_agent resolved
  local generation lifecycle tmp dispatches_file verification_count duplicate_verifier
  ledger="$(session_file "council_coverage.json")"
  current_ts="$(read_state "last_user_prompt_ts")"
  [[ "${current_ts}" =~ ^[0-9]+$ ]] || current_ts=0
  current_revision="$(read_state "prompt_revision")"
  [[ "${current_revision}" =~ ^[0-9]+$ ]] || current_revision=0

  if [[ ! -f "${ledger}" ]] || ! jq -e \
      --argjson objective_ts "${current_ts}" \
      --argjson prompt_revision "${current_revision}" '
        (.objective_prompt_ts // -1) == $objective_ts
        and (.objective_prompt_revision // -1) == $prompt_revision
      ' "${ledger}" >/dev/null 2>&1; then
    _council_coverage_denied=1
    _council_coverage_reason="missing-or-stale-ledger"
    return 0
  fi

  generation="$(jq -r '.generation // 0' "${ledger}" 2>/dev/null || true)"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
  lifecycle="$(jq -r '.lifecycle // empty' "${ledger}" 2>/dev/null || true)"
  if [[ "${council_phase}" == "verification" ]]; then
    # Verification is optional, but when used it is a post-reconciliation
    # round. Bind every verifier to the current finalized ledger generation;
    # do not let an ad-hoc tag create provenance before primary/gap work has
    # been reconciled or after the assessment has already been completed.
    if (( generation < 2 )) \
        || [[ "${lifecycle}" != "primary-complete" \
          && "${lifecycle}" != "gap-fill-complete" ]] \
        || ! jq -e \
          --arg lifecycle "${lifecycle}" '
            (.reconciliation.status // "") == $lifecycle
            and (has("completion") | not)
          ' "${ledger}" >/dev/null 2>&1; then
      _council_coverage_denied=1
      _council_coverage_reason="verification-before-final-reconciliation"
      return 0
    fi

    # The protocol permits up to three independent, load-bearing checks. The
    # durable dispatch log is used instead of the pending queue so a completed
    # verifier still consumes its slot and cannot be dispatched twice under
    # the same exact runtime identity.
    dispatches_file="$(session_file "council_dispatches.jsonl")"
    verification_count=0
    duplicate_verifier="false"
    if [[ -s "${dispatches_file}" ]]; then
      if ! verification_count="$(jq -s -r \
          --argjson objective_ts "${current_ts}" \
          --argjson prompt_revision "${current_revision}" '
            [ .[]
              | select((.purpose // "") == "council")
              | select((.council_phase // "") == "verification")
              | select((.council_objective_prompt_ts // -1) == $objective_ts)
              | select((.council_objective_prompt_revision // -1) == $prompt_revision)
            ] | length
          ' "${dispatches_file}" 2>/dev/null)"; then
        _council_coverage_denied=1
        _council_coverage_reason="invalid-dispatch-provenance"
        return 0
      fi
      if ! duplicate_verifier="$(jq -s -r \
          --arg full "${subagent_type}" \
          --argjson objective_ts "${current_ts}" \
          --argjson prompt_revision "${current_revision}" '
            any(.[]?;
              (.purpose // "") == "council"
              and (.council_phase // "") == "verification"
              and (.agent_type // "") == $full
              and (.council_objective_prompt_ts // -1) == $objective_ts
              and (.council_objective_prompt_revision // -1) == $prompt_revision
            )
          ' "${dispatches_file}" 2>/dev/null)"; then
        _council_coverage_denied=1
        _council_coverage_reason="invalid-dispatch-provenance"
        return 0
      fi
    fi
    [[ "${verification_count}" =~ ^[0-9]+$ ]] || verification_count=0
    if [[ "${duplicate_verifier}" == "true" ]]; then
      _council_coverage_denied=1
      _council_coverage_reason="duplicate-verifier-identity"
      return 0
    fi
    if (( verification_count >= 3 )); then
      _council_coverage_denied=1
      _council_coverage_reason="verification-cap-reached"
      return 0
    fi

    council_selection_agent="${subagent_type}"
    council_objective_ts="${current_ts}"
    council_prompt_revision="${current_revision}"
    council_ledger_generation="${generation}"
    return 0
  elif [[ "${council_phase}" == "primary" ]]; then
    if (( generation != 1 )) || [[ "${lifecycle}" != "primary" ]]; then
      _council_coverage_denied=1
      _council_coverage_reason="primary-round-closed"
      return 0
    fi
  elif (( generation < 2 )) || [[ "${lifecycle}" != "gap-fill-required" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="gap-fill-before-reconciliation"
    return 0
  fi

  selection="$(jq -c \
    --arg full "${subagent_type}" \
    --arg short "${subagent_type##*:}" \
    --arg phase "${council_phase}" '
      [.selections[]?
        | select((.phase // "") == $phase and (.agent // "") == $full)] as $exact
      | if ($exact | length) == 1 then $exact[0]
        elif ($exact | length) > 1 then null
        else
          [.selections[]?
            | select((.phase // "") == $phase)
            | select(((.agent // "") | contains(":") | not))
            | select((.agent // "") == $short)] as $legacy
          | if ($legacy | length) == 1 then $legacy[0] else null end
        end
    ' "${ledger}" 2>/dev/null || true)"
  if [[ -z "${selection}" || "${selection}" == "null" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="unlisted-exact-agent"
    return 0
  fi

  selection_agent="$(jq -r '.agent // empty' <<<"${selection}" 2>/dev/null || true)"
  resolved="$(jq -r '.resolved_agent // empty' <<<"${selection}" 2>/dev/null || true)"
  if [[ -n "${resolved}" && "${resolved}" != "${subagent_type}" ]]; then
    _council_coverage_denied=1
    _council_coverage_reason="selection-bound-to-${resolved}"
    return 0
  fi

  if [[ -z "${resolved}" ]]; then
    tmp="${ledger}.tmp.$$"
    if ! jq \
        --arg selected "${selection_agent}" \
        --arg phase "${council_phase}" \
        --arg resolved "${subagent_type}" '
          .selections |= map(
            if .agent == $selected and .phase == $phase
            then .resolved_agent = $resolved
            else . end
          )
        ' "${ledger}" >"${tmp}"; then
      rm -f "${tmp}"
      _council_coverage_denied=1
      _council_coverage_reason="ledger-bind-failed"
      return 0
    fi
    mv -f "${tmp}" "${ledger}"
  fi

  council_selection_agent="${selection_agent}"
  council_objective_ts="${current_ts}"
  council_prompt_revision="${current_revision}"
  council_ledger_generation="${generation}"
}

_pending_identity_is_ambiguous_unlocked() {
  local pending_file new_is_council
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" ]] || return 1
  new_is_council=0
  [[ -n "${council_phase}" ]] && new_is_council=1

  # A Council completion has no tool-use id. Do not allow a same-identity
  # manual dispatch to race it (or vice versa), because whichever SubagentStop
  # arrived first would inherit the Council provenance incorrectly.
  jq -s -e \
    --arg full "${subagent_type}" \
    --argjson new_is_council "${new_is_council}" '
      any(.[]?;
        (.agent_type // "") == $full
        and ($new_is_council == 1 or (.purpose // "") == "council")
      )
    ' "${pending_file}" >/dev/null 2>&1
}

_append_pending() {
  local _edit_rev _code_rev _doc_rev _bash_rev _ui_rev _plan_rev pending_entry
  local _is_reviewer=0 _review_revision=0

  # The sentinel is cleared before /ulw-off takes the state lock. Recheck it
  # inside that lock so a PreToolUse hook that was already waiting cannot
  # recreate a transient dispatch row after deactivation cleaned the session.
  if [[ ! -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] \
      || ! is_ultrawork_mode; then
    return 0
  fi
  if [[ -n "${council_phase}" ]]; then
    _authorize_council_dispatch_unlocked
    if [[ "${_council_coverage_denied}" -eq 1 ]]; then
      return 0
    fi
  fi

  if _pending_identity_is_ambiguous_unlocked; then
    _dispatch_identity_denied=1
    return 0
  fi

  # SubagentStop does not expose the Agent tool_use_id. Consequently two
  # in-flight instances of the same gate reviewer cannot be matched to their
  # start generations when they finish out of order. Reject that ambiguous
  # shape up front; distinct reviewer roles remain fully parallel.
  if _is_gate_reviewer "${subagent_type}"; then
    local _pending_file
    _pending_file="$(session_file "agent_dispatch_starts.jsonl")"
    if [[ -f "${_pending_file}" ]] && jq -se \
        --arg full "${subagent_type}" --arg short "${subagent_type##*:}" '
          any(.[]?;
            ((.agent_type // "") == $full)
            or (((.agent_type // "") | split(":") | last) == $short)
          )
        ' "${_pending_file}" >/dev/null 2>&1; then
      _duplicate_gate_reviewer=1
      return 0
    fi
  fi

  _edit_rev="$(read_state "edit_revision")"; [[ "${_edit_rev}" =~ ^[0-9]+$ ]] || _edit_rev=0
  _code_rev="$(read_state "last_code_edit_revision")"; [[ "${_code_rev}" =~ ^[0-9]+$ ]] || _code_rev=0
  _doc_rev="$(read_state "last_doc_edit_revision")"; [[ "${_doc_rev}" =~ ^[0-9]+$ ]] || _doc_rev=0
  _bash_rev="$(read_state "last_bash_edit_revision")"; [[ "${_bash_rev}" =~ ^[0-9]+$ ]] || _bash_rev=0
  _ui_rev="$(dimension_freshness_revision "design_quality")"; [[ "${_ui_rev}" =~ ^[0-9]+$ ]] || _ui_rev=0
  _plan_rev="$(read_state "plan_revision")"; [[ "${_plan_rev}" =~ ^[0-9]+$ ]] || _plan_rev=0
  if _is_gate_reviewer "${subagent_type}"; then
    _is_reviewer=1
    _review_revision="$(_gate_reviewer_start_revision "${subagent_type}")"
  fi
  pending_entry="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg agent_type "${subagent_type}" \
    --arg description "${description}" \
    --arg council_phase "${council_phase}" \
    --arg council_selection_agent "${council_selection_agent}" \
    --argjson council_objective_prompt_ts "${council_objective_ts}" \
    --argjson council_objective_prompt_revision "${council_prompt_revision}" \
    --argjson council_ledger_generation "${council_ledger_generation}" \
    --argjson edit_revision "${_edit_rev}" \
    --argjson code_revision "${_code_rev}" \
    --argjson doc_revision "${_doc_rev}" \
    --argjson bash_revision "${_bash_rev}" \
    --argjson ui_revision "${_ui_rev}" \
    --argjson plan_revision "${_plan_rev}" \
    --argjson is_reviewer "${_is_reviewer}" \
    --argjson review_dispatch_causality_version "${REVIEW_DISPATCH_CAUSALITY_VERSION}" \
    --argjson review_revision "${_review_revision}" \
    '{ts:$ts,agent_type:$agent_type,description:$description,
      edit_revision:$edit_revision,code_revision:$code_revision,
      doc_revision:$doc_revision,bash_revision:$bash_revision,
      ui_revision:$ui_revision,plan_revision:$plan_revision}
     + if $is_reviewer == 1 then {
         review_dispatch_causality_version:$review_dispatch_causality_version,
         review_revision:$review_revision
       } else {} end
     + if $council_phase == "" then {} else {
         purpose:"council",
         council_phase:$council_phase,
         council_selection_agent:$council_selection_agent,
         council_objective_prompt_ts:$council_objective_prompt_ts,
         council_objective_prompt_revision:$council_objective_prompt_revision,
         council_ledger_generation:$council_ledger_generation
       } end')"
  append_limited_state "pending_agents.jsonl" "${pending_entry}" "32"
  # Durable FIFO consumed only by gate-reviewer hooks. Subagent-summary cleanup
  # removes pending entries independently, so reviewer start-generation
  # evidence needs its own bounded ledger to survive hook ordering. Do not put
  # ordinary specialists/builders here: their rows have no consumer and could
  # evict a still-running review's causal snapshot during large fan-out.
  if _is_gate_reviewer "${subagent_type}"; then
    if ! append_limited_state \
        "agent_dispatch_starts.jsonl" "${pending_entry}" "64"; then
      return 1
    fi
    # Once a session emits a versioned start, every later reviewer completion
    # in that session must prove its row. The marker deliberately survives
    # /ulw-off so a late pre-deactivation completion cannot be mistaken for a
    # legacy untracked result after reactivation.
    if ! _write_state_batch_unlocked \
        "review_dispatch_tracking_version" \
        "${REVIEW_DISPATCH_CAUSALITY_VERSION}"; then
      return 1
    fi
  fi
  if [[ -n "${council_phase}" ]]; then
    # Completion removes pending_agents entries, so keep a small durable
    # dispatch ledger for real-work scoring and auditability.
    append_limited_state "council_dispatches.jsonl" "${pending_entry}" "32"
  fi
  local _count
  _count="$(read_state "subagent_dispatch_count")"
  _count="${_count:-0}"
  write_state "subagent_dispatch_count" "$((_count + 1))"

  if _is_advisory_specialist "${subagent_type}"; then
    local _adv_count
    _adv_count="$(read_state "advisory_specialist_dispatch_count")"
    _adv_count="${_adv_count:-0}"
    write_state "advisory_specialist_dispatch_count" "$((_adv_count + 1))"
  fi
}
_duplicate_gate_reviewer=0
_council_coverage_denied=0
_council_coverage_reason=""
_dispatch_identity_denied=0
council_selection_agent=""
council_objective_ts=0
council_prompt_revision=0
council_ledger_generation=0
_dispatch_state_rc=0
with_state_lock _append_pending || _dispatch_state_rc=$?

if [[ "${_dispatch_state_rc}" -ne 0 ]]; then
  if _is_gate_reviewer "${subagent_type}"; then
    record_gate_event "reviewer-dispatch-causality" "block" \
      "agent=${subagent_type}" "reason=start-snapshot-write-failed" \
      "rc=${_dispatch_state_rc}" 2>/dev/null || true
    jq -nc --arg reason "[Reviewer causality gate] The start generation for ${subagent_type} could not be recorded safely. Do not launch an untracked review; retry this dispatch after the active state write finishes." '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  fi
  exit 0
fi

if [[ "${_council_coverage_denied}" -eq 1 ]]; then
  record_gate_event "council-coverage" "block" \
    "agent=${subagent_type}" "phase=${council_phase}" "reason=${_council_coverage_reason}"
  jq -nc --arg reason "[Council coverage gate] ${subagent_type} is tagged ${council_phase}, but the current lifecycle does not authorize that exact dispatch (${_council_coverage_reason}). Primary agents require the current generation-1 selection; gap-fill agents require the reconciled gap selection; verification requires a current final-reconciled ledger, a unique verifier identity, and one of at most three verification slots." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_dispatch_identity_denied}" -eq 1 ]]; then
  record_gate_event "council-provenance" "block" \
    "agent=${subagent_type}" "reason=ambiguous-in-flight-identity"
  jq -nc --arg reason "[Council provenance gate] ${subagent_type} already has an in-flight dispatch whose completion would be ambiguous with this Council identity. Wait for it to return before dispatching the same exact agent identity again; other specialists may remain parallel." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

if [[ "${_duplicate_gate_reviewer}" -eq 1 ]]; then
  record_gate_event "reviewer-dispatch-causality" "block" \
    "agent=${subagent_type}" "reason=duplicate-in-flight-role"
  jq -nc --arg reason "[Reviewer causality gate] ${subagent_type} is already in flight. Claude Code's SubagentStop event has no dispatch ID, so a duplicate same-role review could finish out of order and attach stale evidence to the newer generation. Wait for the active review to finish, then dispatch this role again if another pass is needed. Different reviewer roles may still run in parallel." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

log_hook "record-pending-agent" "dispatched=${subagent_type}"
