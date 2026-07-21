#!/usr/bin/env bash

set -euo pipefail

_OMC_HOOK_CALLER_PATH="${PATH:-}"
# v1.27.0 (F-020 / F-021): SubagentStop hook uses extract_discovered_findings
# (awk-only) and is_design_contract_emitter (regex-only) — no classifier or
# timing-lib dependency. Opt out of both eager sources.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
_summary_recovery_requested="${OMC_PUBLICATION_RECOVERY_INTERNAL:-}"
unset OMC_PUBLICATION_RECOVERY_INTERNAL
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
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 1

ensure_session_dir

_summary_recovery_admitted=0
_summary_recovery_claim="${OMC_PUBLICATION_RECOVERY_CLAIM_ID:-}"
_summary_recovery_mode=0
_summary_recovery_contract_kind="$(omc_enforced_terminal_contract_kind \
  "${AGENT_TYPE}" 2>/dev/null || true)"
if [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" == "1" \
    || "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
    || "${OMC_GENERIC_SUMMARY_REPLAY:-0}" == "1" \
    || "${OMC_ORPHANED_DEDICATED_CLAIM_RETIRE:-0}" == "1" ]]; then
  _summary_recovery_mode=1
fi
if [[ "${_summary_recovery_requested}" == "1" \
    && "${_summary_recovery_mode}" -eq 1 ]]; then
  # Receipt-bound waiter replay can begin before the universal hook has written
  # a completion claim.  The internal marker is only a recursion fence: the
  # ordinary claim path below still validates the exact waiter, receipt, native
  # binding, and pending row before publishing any effect.  Once a claim does
  # exist, however, bind the replay to that exact live claim so an ambient or
  # stale recovery token cannot suppress sibling-transaction reconciliation.
  if [[ -z "${_summary_recovery_claim}" ]]; then
    # A claimless replay is valid only for one dedicated contract kind. Generic
    # and orphan recovery always carry an exact existing claim. Keeping these
    # modes disjoint prevents an ambient replay flag from granting the one-use
    # state-lock transition to an unrelated ordinary completion.
    if [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" == "1" \
        && "${_summary_recovery_contract_kind}" == "planner" \
        && "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" != "1" \
        && "${OMC_GENERIC_SUMMARY_REPLAY:-0}" != "1" \
        && "${OMC_ORPHANED_DEDICATED_CLAIM_RETIRE:-0}" != "1" ]]; then
      _summary_recovery_admitted=1
    elif [[ "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
        && "${_summary_recovery_contract_kind}" == "reviewer" \
        && "${OMC_PLAN_SUMMARY_REPLAY:-0}" != "1" \
        && "${OMC_GENERIC_SUMMARY_REPLAY:-0}" != "1" \
        && "${OMC_ORPHANED_DEDICATED_CLAIM_RETIRE:-0}" != "1" ]]; then
      _summary_recovery_admitted=1
    fi
  elif [[ "${_summary_recovery_claim}" \
        =~ ^completion-[A-Za-z0-9._:-]{8,160}$ \
      && -f "$(session_file "pending_agents.jsonl")" \
      && ! -L "$(session_file "pending_agents.jsonl")" ]] \
      && jq -Rse --arg claim "${_summary_recovery_claim}" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {})
          | (.completion_claim_id // "") == $claim
          and (.review_dispatch_abandoned // false) != true)
      ' "$(session_file "pending_agents.jsonl")" >/dev/null 2>&1; then
    _summary_recovery_admitted=1
  fi
fi

# Reconcile sibling publisher state before verdict/Definition/generation reads.
# Receipt-bound replay children carry the narrow internal marker because they
# are themselves the convergence action and must not recursively invoke it.
if [[ "${_summary_recovery_admitted}" -ne 1 ]] \
    && ! omc_recover_active_publication_transactions "${SESSION_ID}"; then
  log_anomaly "record-subagent-summary" \
    "publication recovery barrier failed before completion validation"
  exit 1
fi

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
_summary_structured_contract_error=""
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

# A role-valid VERDICT is necessary but no longer sufficient for the two
# Definition-of-Excellent authorities. Validate the structural semantic
# envelope before either parallel SubagentStop hook may claim the causal row.
# Invalid returns therefore use the existing bounded native continuation path
# and cannot publish a summary, plan, reviewer dimension, or proof side effect.
if [[ "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]]; then
  if [[ "${_summary_enforced_contract_kind}" == "planner" \
      && "${_summary_terminal_verdict}" == "PLAN_READY" ]]; then
    _summary_quality_payload=""
    if ! _omc_load_quality_contract 2>/dev/null \
      || ! _summary_quality_payload="$(quality_contract_extract_json \
        "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null)"; then
      _summary_valid_enforced_contract=0
      _summary_structured_contract_error="PLAN_READY is missing a valid structural QUALITY_CONTRACT_JSON immediately before the dispatch ID/verdict."
    elif [[ "$(read_state "quality_constitution_status" 2>/dev/null || true)" == "invalid" ]]; then
      _summary_valid_enforced_contract=0
      _summary_structured_contract_error="The user-owned Quality Constitution is invalid; repair/audit it before proposing an authoritative contract."
    else
      _summary_required_profile_ids="$(read_state "quality_constitution_blocking_ids" 2>/dev/null || true)"
      if [[ -n "${_summary_required_profile_ids}" ]] \
        && ! jq -e --arg ids "${_summary_required_profile_ids}" '
          ($ids | split(",") | map(select(length > 0)) | sort) as $required
          | ([.standards[]? | .profile_entry_id? // empty] | unique | sort) as $present
          | all($required[]; . as $id | ($present | index($id)) != null)
        ' <<<"${_summary_quality_payload}" >/dev/null 2>&1; then
        _summary_valid_enforced_contract=0
        _summary_structured_contract_error="QUALITY_CONTRACT_JSON omits one or more explicit blocking Quality Constitution IDs."
      fi
      if [[ "${_summary_valid_enforced_contract}" -eq 1 \
          && -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
        _summary_old_contract_file="$(session_file "quality_contract.json")"
        if [[ -f "${_summary_old_contract_file}" \
            && ! -L "${_summary_old_contract_file}" ]]; then
          _summary_old_contract="$(jq -ce . "${_summary_old_contract_file}" 2>/dev/null || true)"
          if [[ -z "${_summary_old_contract}" ]] \
            || ! quality_contract_validate_envelope \
              "${_summary_old_contract}" 2>/dev/null \
            || ! quality_contract_revision_preserves_floor \
              "${_summary_quality_payload}" "${_summary_old_contract}" 2>/dev/null; then
            _summary_valid_enforced_contract=0
            _summary_structured_contract_error="The proposed post-mutation contract deletes or weakens the frozen mandatory criterion/anti-goal/user-standard floor. Preserve it exactly and make only additive strengthening changes."
          fi
        else
          _summary_valid_enforced_contract=0
          _summary_structured_contract_error="Implementation already started without a frozen Definition. A late first contract cannot certify prior work; restart the objective or use the user's explicit /ulw-skip escape."
        fi
      fi
    fi
  elif [[ "${AGENT_TYPE}" == "excellence-reviewer" \
      && "${_summary_terminal_verdict}" =~ ^(CLEAN|SHIP|FINDINGS|BLOCK)$ ]]; then
    _summary_quality_review=""
    _summary_quality_contract=""
    if ! _omc_load_quality_contract 2>/dev/null \
      || ! _summary_quality_contract="$(quality_contract_validate_current 2>/dev/null)" \
      || ! _summary_quality_review="$(quality_review_extract_json \
        "${LAST_ASSISTANT_MESSAGE}" 2>/dev/null)" \
      || ! quality_review_validate_against_contract \
        "${_summary_quality_review}" "${_summary_quality_contract}" \
        "${_summary_final_line}" 2>/dev/null; then
      _summary_valid_enforced_contract=0
      _summary_structured_contract_error="The excellence return lacks a current, contract-complete QUALITY_REVIEW_JSON or its criteria/frontier contradict the terminal verdict."
    fi
  fi
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
  case "$1" in
    quality-reviewer|superpowers:code-reviewer|feature-dev:code-reviewer)
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

_summary_safe_completion_message() {
  printf '%s' "${LAST_ASSISTANT_MESSAGE}" \
    | omc_redact_secrets \
    | tr -d '\000'
}

_summary_reviewer_completion_digest() {
  local safe_message
  safe_message="$(_summary_safe_completion_message)" || return 1
  _omc_token_digest "${safe_message}"
}

# Resolve the dedicated reviewer hook's last-publication receipt. A structural
# VERDICT is not universal authority: only this lifecycle+message digest proves
# the role-specific hook accepted (or deterministically rejected) the exact
# completion after all reviewer state/evidence writes landed.
_summary_reviewer_publication_decision_unlocked() {
  local selected="$1" receipts_file receipts lifecycle native completion_digest
  local start_revision match_count
  receipts_file="$(session_file "reviewer_publication_outcomes.jsonl")"
  _summary_reviewer_publication_status=""
  _summary_reviewer_publication_reason=""
  [[ ! -L "${receipts_file}" ]] \
    && { [[ ! -e "${receipts_file}" ]] || [[ -f "${receipts_file}" ]]; } \
    || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  start_revision="$(jq -r '.review_revision // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  completion_digest="$(_summary_reviewer_completion_digest)" || return 1
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native}" =~ ^[A-Za-z0-9._:-]{0,128}$ \
      && "${start_revision}" =~ ^[0-9]+$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]] || return 1
  [[ -s "${receipts_file}" ]] || return 2
  receipts="$(jq -cs . "${receipts_file}" 2>/dev/null)" || return 1
  jq -e '
    all(.[];
      type == "object" and .schema_version == 1
      and (.decided_at | type == "number" and . >= 0)
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.agent_type | type == "string" and length > 0 and length <= 128)
      and (.reviewer_type | type == "string" and length > 0 and length <= 64)
      and (.native_agent_id | type == "string" and length <= 128
        and test("^[A-Za-z0-9._:-]*$"))
      and (.completion_digest | type == "string"
        and test("^[A-Fa-f0-9]{16,128}$"))
      and (.status | IN("accepted","rejected"))
      and (.reason | type == "string" and length <= 256)
      and (.verdict | type == "string" and length <= 32
        and test("^[A-Z_]*$"))
      and (.start_review_revision | type == "number" and . >= 0 and floor == .)
      and (.result_review_revision | type == "number" and . >= 0 and floor == .))
  ' <<<"${receipts}" >/dev/null 2>&1 || return 1
  match_count="$(jq -r --arg lifecycle "${lifecycle}" '
    [.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length
  ' <<<"${receipts}")" || return 1
  [[ "${match_count}" == "1" ]] || {
    [[ "${match_count}" == "0" ]] && return 2
    return 1
  }
  _summary_reviewer_receipt="$(jq -c --arg lifecycle "${lifecycle}" '
    [.[] | select(.lifecycle_dispatch_id == $lifecycle)][0]
  ' <<<"${receipts}")" || return 1
  jq -e \
    --arg agent "${AGENT_TYPE}" --arg native "${native}" \
    --arg digest "${completion_digest}" \
    --arg verdict "${_summary_terminal_verdict}" \
    --argjson start "${start_revision}" '
      .agent_type == $agent
      and .native_agent_id == $native
      and .completion_digest == $digest
      and .verdict == $verdict
      and .start_review_revision == $start
      and (if .status == "accepted"
        then .result_review_revision == $start else true end)
    ' <<<"${_summary_reviewer_receipt}" >/dev/null 2>&1 || return 1
  _summary_reviewer_publication_status="$(jq -r '.status' \
    <<<"${_summary_reviewer_receipt}")"
  _summary_reviewer_publication_reason="$(jq -r '.reason' \
    <<<"${_summary_reviewer_receipt}")"
}

_register_reviewer_summary_waiter_unlocked() {
  local selected="$1" waiters_file pending_file source temp waiter existing_count
  local lifecycle native completion_digest safe_message live_ids
  waiters_file="$(session_file "reviewer_summary_waiters.jsonl")"
  [[ ! -L "${waiters_file}" ]] \
    && { [[ ! -e "${waiters_file}" ]] || [[ -f "${waiters_file}" ]]; } \
    || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  safe_message="$(_summary_safe_completion_message)" || return 1
  completion_digest="$(_omc_token_digest "${safe_message}")" || return 1
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native}" =~ ^[A-Za-z0-9._:-]{0,128}$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && -n "${safe_message}" && "${#safe_message}" -le 131072 ]] || return 1
  waiter="$(jq -nc \
    --argjson schema_version 1 --argjson created_at "$(now_epoch)" \
    --arg lifecycle_dispatch_id "${lifecycle}" --arg agent_type "${AGENT_TYPE}" \
    --arg native_agent_id "${native}" --arg completion_digest "${completion_digest}" \
    --arg message "${safe_message}" '
      {schema_version:$schema_version,created_at:$created_at,
       lifecycle_dispatch_id:$lifecycle_dispatch_id,agent_type:$agent_type,
       native_agent_id:$native_agent_id,completion_digest:$completion_digest,
       message:$message}
    ')" || return 1
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ ! -L "${pending_file}" && -f "${pending_file}" ]] || return 1
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  live_ids="$(jq -Rsc '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")
      | .lifecycle_dispatch_id
      | select(type == "string" and length > 0)] | unique
  ' "${pending_file}")" || return 1
  source="${waiters_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  existing_count="$(jq -Rsr --arg lifecycle "${lifecycle}" '
    [split("\n")[] | select(length > 0) | fromjson
      | select(.lifecycle_dispatch_id == $lifecycle)] | length
  ' "${source}" 2>/dev/null)" || return 1
  [[ "${existing_count}" == "0" || "${existing_count}" == "1" ]] || return 1
  temp="$(mktemp "${waiters_file}.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || { rm -f "${temp}"; return 1; }
  if ! jq -Rsr --argjson waiter "${waiter}" --argjson live "${live_ids}" '
      def valid:
        type == "object" and .schema_version == 1
        and (.created_at | type == "number" and . >= 0)
        and (.lifecycle_dispatch_id | type == "string"
          and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
        and (.agent_type | type == "string" and length > 0 and length <= 128)
        and (.native_agent_id | type == "string" and length <= 128
          and test("^[A-Za-z0-9._:-]*$"))
        and (.completion_digest | type == "string"
          and test("^[A-Fa-f0-9]{16,128}$"))
        and (.message | type == "string" and length > 0 and length <= 131072);
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null)] as $rows
      | if all($rows[]; valid) | not then error("invalid waiter ledger")
        else ([$rows[]
          | select(.lifecycle_dispatch_id != $waiter.lifecycle_dispatch_id)
          | select(.lifecycle_dispatch_id as $id | ($live | index($id)) != null)]
          + [$waiter]) as $kept
        | if ($kept | length) > 128 then error("waiter cap")
          else $kept[] | @json end
        end
    ' "${source}" >"${temp}" || ! mv -f "${temp}" "${waiters_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
}

# Validate enough of the dedicated reviewer's fixed WAL to distinguish a
# recoverable interrupted publication from a corrupt node that must remain
# fail-closed. record-reviewer.sh repeats its stricter full validation before
# replay; this check grants only one continuation request, never publication.
_summary_reviewer_active_wal_valid_unlocked() {
  local wal manifest descriptor name after_sha staged
  wal="$(session_file ".reviewer-transaction.wal")"
  [[ -d "${wal}" && ! -L "${wal}" ]] || return 1
  manifest="${wal}/manifest.json"
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  [[ "$(wc -c <"${manifest}" 2>/dev/null || printf 0)" -le 262144 ]] \
    || return 1
  jq -e '
    . as $manifest
    | type == "object"
    and (keys | sort == ["_v","agent_type","artifacts","frontier_event",
      "history_line","lifecycle_dispatch_id","native_agent_id","outcome",
      "pending_line","rejection","reviewer_type","start_line",
      "state_after","state_before"])
    and ._v == 1
    and (.lifecycle_dispatch_id | type == "string"
      and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.agent_type | type == "string" and length > 0 and length <= 128)
    and (.reviewer_type | type == "string" and length > 0 and length <= 64)
    and (.native_agent_id | type == "string" and length <= 128)
    and (.outcome == "accepted" or .outcome == "rejected")
    and (.start_line | type == "string" and length > 1 and length <= 131072)
    and (.pending_line | type == "string" and length <= 131072)
    and (.state_after | type == "object")
    and (.state_before | type == "object")
    and ((.state_after | keys | sort) == (.state_before | keys | sort))
    and all(.state_after[]; type == "string")
    and (.artifacts | type == "array" and length >= 1 and length <= 4)
    and (([.artifacts[].name] | unique | length) == (.artifacts | length))
    and ([.artifacts[].name | select(. == "reviewer_publication_outcomes.jsonl")]
      | length == 1)
    and all(.artifacts[];
      type == "object"
      and (keys | sort == ["after_sha","before_kind","before_sha","name"])
      and (.name | IN("quality_evidence.jsonl","quality_frontier.json",
        "quality_frontier_history.jsonl","reviewer_publication_outcomes.jsonl"))
      and (.after_sha | type == "string" and test("^[0-9a-f]{64}$")))
    and ((.start_line | fromjson | .lifecycle_dispatch_id // "")
      == $manifest.lifecycle_dispatch_id)
  ' "${manifest}" >/dev/null 2>&1 || return 1
  while IFS= read -r descriptor; do
    [[ -n "${descriptor}" ]] || continue
    name="$(jq -r '.name' <<<"${descriptor}")" || return 1
    after_sha="$(jq -r '.after_sha' <<<"${descriptor}")" || return 1
    staged="${wal}/after-${name}"
    [[ -f "${staged}" && ! -L "${staged}" ]] || return 1
    [[ "$(_omc_digest_file "${staged}")" == "${after_sha}" ]] || return 1
  done < <(jq -c '.artifacts[]' "${manifest}")
}

# Retry counters live inside fixed publication WALs and therefore participate
# in that WAL's continuation authority. Import exactly one bounded canonical
# line before shell arithmetic; missing is the sole representation of zero.
_summary_read_recovery_retry_count() {
  local count_file="$1" count=""
  [[ ! -L "${count_file}" ]] || return 1
  if [[ ! -e "${count_file}" ]]; then
    printf '0'
    return 0
  fi
  count="$(_omc_read_canonical_metadata_line \
    "${count_file}" 32 2>/dev/null)" || return 1
  _omc_canonical_uint_in_range \
    "${count}" 0 999999999999999 || return 1
  printf '%s' "${count}"
}

# A valid persistent reviewer WAL normally means the parallel dedicated hook
# died after making its journal durable. Ask the exact retained native call to
# return once more so record-reviewer.sh executes roll-forward recovery. The
# sidecar bounds this to one continuation; it is not part of publication
# authority and is deleted with the WAL after successful recovery.
_mark_reviewer_recovery_retry_unlocked() {
  local wal manifest count_file count=0 temp sibling_plan_wal
  _summary_reviewer_recovery_retry_required=0
  _summary_reviewer_recovery_retry_exhausted=0
  sibling_plan_wal="$(session_file ".plan-txn.active")"
  [[ ! -e "${sibling_plan_wal}" && ! -L "${sibling_plan_wal}" ]] \
    || return 1
  _summary_reviewer_active_wal_valid_unlocked || return 1
  wal="$(session_file ".reviewer-transaction.wal")"
  manifest="${wal}/manifest.json"
  # The continuation channel belongs to one platform-native call. A parallel
  # reviewer must neither spend this WAL owner's single retry nor be told to
  # replay somebody else's completion; generic router/PreTool recovery remains
  # available to roll forward an unrelated valid journal.
  [[ -n "${_summary_native_agent_id:-}" ]] || return 1
  jq -e --arg agent "${AGENT_TYPE}" \
    --arg native "${_summary_native_agent_id}" '
      .agent_type == $agent and .native_agent_id == $native
  ' "${manifest}" >/dev/null 2>&1 || return 1
  count_file="${wal}/.summary-retry-count"
  count="$(_summary_read_recovery_retry_count \
    "${count_file}")" || return 1
  if (( count >= 1 )); then
    _summary_reviewer_recovery_retry_exhausted=1
    return 0
  fi
  temp="$(mktemp "${wal}/.summary-retry-count.XXXXXX")" || return 1
  if ! printf '1\n' >"${temp}" || ! mv -f "${temp}" "${count_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
  _summary_reviewer_recovery_retry_required=1
}

# The planner's rollback WAL contains the complete pre-publication generation.
# Validate its fixed manifest plus the exact retained pending/start authority
# before asking a native planner to return again. This grants only a recovery
# continuation; record-plan.sh remains the sole publisher and repeats the full
# WAL validation before restoring or committing anything.
_summary_plan_active_wal_valid_unlocked() {
  local wal ready artifact file_marker absent_marker marker_count
  local pending_snapshot start_snapshot pending_lifecycle start_lifecycle
  local owner owner_lifecycle completion_digest _summary_plan_snapshot
  local _summary_plan_allow_noise
  wal="$(session_file ".plan-txn.active")"
  [[ -d "${wal}" && ! -L "${wal}" ]] || return 1
  ready="${wal}/.ready"
  [[ -f "${ready}" && ! -L "${ready}" ]] || return 1
  [[ "$(wc -c <"${ready}" 2>/dev/null || printf 0)" -le 8192 ]] \
    || return 1
  jq -e '
    type == "object"
    and .schema_version == 1
    and .status == "prepared"
    and (.transaction_id | type == "string"
      and test("^plan-txn-[A-Fa-f0-9]{16,128}$"))
    and (.owner | type == "object"
      and (keys | sort == ["agent_type","completion_digest",
        "lifecycle_dispatch_id","native_agent_id","tracked"])
      and .tracked == true
      and (.lifecycle_dispatch_id
        | test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.agent_type | type == "string" and length > 0 and length <= 128)
      and (.native_agent_id | test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.completion_digest | test("^[A-Fa-f0-9]{16,128}$")))
    and .artifacts == [
      "session_state.json",
      "pending_agents.jsonl",
      "agent_dispatch_starts.jsonl",
      "current_plan.md",
      "quality_contract.json",
      "quality_contract_history.jsonl",
      "quality_evidence.jsonl",
      "quality_frontier.json",
      "quality_frontier_history.jsonl",
      "plan_publication_outcomes.jsonl",
      "plan_recovery_notices.jsonl"
    ]
  ' "${ready}" >/dev/null 2>&1 || return 1
  while IFS= read -r artifact; do
    file_marker="${wal}/${artifact}.file"
    absent_marker="${wal}/${artifact}.absent"
    marker_count=0
    if [[ -e "${file_marker}" || -L "${file_marker}" ]]; then
      [[ -f "${file_marker}" && ! -L "${file_marker}" ]] || return 1
      marker_count=$((marker_count + 1))
    fi
    if [[ -e "${absent_marker}" || -L "${absent_marker}" ]]; then
      [[ -f "${absent_marker}" && ! -L "${absent_marker}" ]] || return 1
      marker_count=$((marker_count + 1))
    fi
    [[ "${marker_count}" -eq 1 ]] || return 1
  done < <(jq -r '.artifacts[]' "${ready}")

  # A self-healing callback must be bound to this exact tracked native planner,
  # not merely to some active transaction in the same session.
  [[ -n "${_summary_native_agent_id}" ]] || return 1
  owner="$(jq -c '.owner' "${ready}")" || return 1
  owner_lifecycle="$(jq -r '.lifecycle_dispatch_id' <<<"${owner}")" \
    || return 1
  completion_digest="$(_summary_plan_completion_digest)" || return 1
  jq -e --arg agent "${AGENT_TYPE}" \
      --arg native "${_summary_native_agent_id}" \
      --arg digest "${completion_digest}" '
    .tracked == true
    and .agent_type == $agent
    and .native_agent_id == $native
    and .completion_digest == $digest
  ' <<<"${owner}" >/dev/null 2>&1 || return 1
  pending_snapshot="${wal}/pending_agents.jsonl.file"
  start_snapshot="${wal}/agent_dispatch_starts.jsonl.file"
  for _summary_plan_snapshot in "${pending_snapshot}" "${start_snapshot}"; do
    [[ -f "${_summary_plan_snapshot}" \
        && ! -L "${_summary_plan_snapshot}" ]] || return 1
    omc_dispatch_authority_ledger_shell_safe \
      "${_summary_plan_snapshot}" || return 1
    _summary_plan_allow_noise=0
    [[ "${_summary_plan_snapshot}" == "${pending_snapshot}" ]] \
      && _summary_plan_allow_noise=1
    jq -Rse \
      --arg native "${_summary_native_agent_id}" \
      --arg agent "${AGENT_TYPE}" \
      --argjson allow_noise "${_summary_plan_allow_noise}" \
      --argjson owner "${owner}" '
        def planner_name($name):
          $name == "quality-planner" or $name == "prometheus";
        [split("\n")[] | select(length > 0)
          | (try fromjson catch null)] as $rows
        | ($allow_noise == 1 or all($rows[]; type == "object"))
        and ([$rows[] | select(
          type == "object"
          and
          (.native_agent_id // "") == $native
          and planner_name(.agent_type // "")
          and planner_name($agent)
          and (.lifecycle_dispatch_id // "") == $owner.lifecycle_dispatch_id
          and (.agent_type // "") == $owner.agent_type
          and (.lifecycle_dispatch_id // ""
            | test("^dispatch-[A-Za-z0-9._:-]{8,120}$"))
          and ((.review_dispatch_abandoned // false) != true)
        )] | length == 1)
      ' "${_summary_plan_snapshot}" >/dev/null 2>&1 || return 1
  done
  pending_lifecycle="$(jq -Rsr \
    --arg native "${_summary_native_agent_id}" \
    --arg agent "${AGENT_TYPE}" \
    --arg lifecycle "${owner_lifecycle}" '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null) | select(type == "object")
        | select((.native_agent_id // "") == $native
          and (.agent_type // "") == $agent
          and (.lifecycle_dispatch_id // "") == $lifecycle)]
      | .[0].lifecycle_dispatch_id // ""
    ' "${pending_snapshot}")" || return 1
  start_lifecycle="$(jq -Rsr \
    --arg native "${_summary_native_agent_id}" \
    --arg agent "${AGENT_TYPE}" \
    --arg lifecycle "${owner_lifecycle}" '
      [split("\n")[] | select(length > 0) | fromjson
        | select((.native_agent_id // "") == $native
          and (.agent_type // "") == $agent
          and (.lifecycle_dispatch_id // "") == $lifecycle)]
      | .[0].lifecycle_dispatch_id // ""
    ' "${start_snapshot}")" || return 1
  [[ -n "${pending_lifecycle}" \
      && "${pending_lifecycle}" == "${start_lifecycle}" ]] || return 1
}

# One persistent valid planner WAL receives one native continuation. The count
# lives inside the WAL, so it follows the exact recovery authority and is
# removed when record-plan retires that journal. Corrupt or repeatedly stuck
# transactions remain silent/fail-closed instead of creating a continuation
# loop.
_mark_plan_recovery_retry_unlocked() {
  local wal count_file count=0 temp
  _summary_plan_recovery_retry_required=0
  _summary_plan_recovery_retry_exhausted=0
  _summary_plan_active_wal_valid_unlocked || return 1
  wal="$(session_file ".plan-txn.active")"
  count_file="${wal}/.summary-retry-count"
  count="$(_summary_read_recovery_retry_count \
    "${count_file}")" || return 1
  if (( count >= 1 )); then
    _summary_plan_recovery_retry_exhausted=1
    return 0
  fi
  temp="$(mktemp "${wal}/.summary-retry-count.XXXXXX")" || return 1
  if ! printf '1\n' >"${temp}" || ! mv -f "${temp}" "${count_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
  _summary_plan_recovery_retry_required=1
}

_summary_plan_completion_digest() {
  local safe_message
  safe_message="$(_summary_safe_completion_message)" || return 1
  _omc_token_digest "${safe_message}"
}

# Consume at most one continuation grant from an exact-owner rollback notice.
# Fixed-WAL presence/absence is not identity: a foreign planner may have
# committed normally while this summary waited for the session lock. Recovery
# publishes this notice before retiring the WAL, so even a different planner's
# hook can perform rollback without losing the interrupted owner's handoff.
_claim_plan_recovery_notice_unlocked() {
  local selected="$1" notices_file source rows lifecycle native agent digest
  local matches temp
  notices_file="$(session_file "plan_recovery_notices.jsonl")"
  [[ ! -L "${notices_file}" ]] \
    && { [[ ! -e "${notices_file}" ]] || [[ -f "${notices_file}" ]]; } \
    || return 1
  [[ -s "${notices_file}" ]] || return 0
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${selected}")"
  native="$(jq -r '.native_agent_id // empty' <<<"${selected}")"
  agent="$(jq -r '.agent_type // empty' <<<"${selected}")"
  digest="$(_summary_plan_completion_digest)" || return 1
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      && -n "${agent}" \
      && "${digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]] || return 1
  rows="$(jq -Rsc '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null)]
    | if all(.[];
        type == "object"
        and .schema_version == 1
        and (.transaction_id | type == "string"
          and test("^plan-txn-[A-Fa-f0-9]{16,128}$"))
        and (.recovered_at | type == "number" and . >= 0)
        and (.retry_issued | type == "boolean")
        and (.owner | type == "object"
          and .tracked == true
          and (.lifecycle_dispatch_id | type == "string")
          and (.agent_type | type == "string")
          and (.native_agent_id | type == "string")
          and (.completion_digest | type == "string")))
      then . else error("invalid planner recovery notice ledger") end
  ' "${notices_file}")" || return 1
  matches="$(jq -r \
    --arg lifecycle "${lifecycle}" --arg native "${native}" \
    --arg agent "${agent}" --arg digest "${digest}" '
      [.[] | select(.retry_issued == false
        and .owner.lifecycle_dispatch_id == $lifecycle
        and .owner.native_agent_id == $native
        and .owner.agent_type == $agent
        and .owner.completion_digest == $digest)] | length
    ' <<<"${rows}")" || return 1
  [[ "${matches}" =~ ^[0-9]+$ ]] || return 1
  (( matches > 0 )) || return 0
  temp="$(mktemp "${notices_file}.XXXXXX")" || return 1
  source="${notices_file}"
  if ! jq -cn --argjson rows "${rows}" \
      --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg agent "${agent}" --arg digest "${digest}" '
      $rows[]
      | if .retry_issued == false
          and .owner.lifecycle_dispatch_id == $lifecycle
          and .owner.native_agent_id == $native
          and .owner.agent_type == $agent
          and .owner.completion_digest == $digest
        then .retry_issued = true else . end
    ' >"${temp}" || ! mv -f "${temp}" "${notices_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
  _summary_plan_recovery_retry_required=1
}

_summary_plan_parent_outcome_already_committed_unlocked() {
  local outcomes_file outcomes digest
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  [[ -f "${outcomes_file}" && ! -L "${outcomes_file}" \
      && -s "${outcomes_file}" ]] || return 1
  digest="$(_summary_plan_completion_digest)" || return 1
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" --arg agent "${AGENT_TYPE}" \
      --arg native "${_summary_native_agent_id}" \
      --arg digest "${digest}" '
    ([$outcomes[] | select(
      (.agent_type // "") == $agent
      and (.native_agent_id // "") == $native
      and (.completion_digest // "") == $digest
      and (.status // "") == "accepted")] | length) == 1
  ' >/dev/null 2>&1
}

# Resolve the dedicated planner hook's lifecycle-bound publication decision.
# Return 0 for one valid receipt, 2 when the plan hook has not published yet,
# and 1 for malformed/ambiguous/mismatched authority. The caller preserves the
# causal row on 1 or 2; neither state is permission to publish summary effects.
_summary_plan_publication_decision_unlocked() {
  local selected="$1" receipts_file receipts lifecycle_dispatch_id
  local native_agent_id completion_digest start_plan_revision match_count
  receipts_file="$(session_file "plan_publication_outcomes.jsonl")"
  _summary_plan_publication_status=""
  _summary_plan_publication_reason=""
  [[ ! -L "${receipts_file}" ]] \
    && { [[ ! -e "${receipts_file}" ]] || [[ -f "${receipts_file}" ]]; } \
    || return 1
  lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  native_agent_id="$(jq -r '.native_agent_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  start_plan_revision="$(jq -r '.plan_revision // .review_revision // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  completion_digest="$(_summary_plan_completion_digest)" || return 1
  [[ "${lifecycle_dispatch_id}" \
      =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      && "${start_plan_revision}" =~ ^[0-9]+$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]] \
    || return 1
  [[ -s "${receipts_file}" ]] || return 2
  receipts="$(jq -cs . "${receipts_file}" 2>/dev/null)" || return 1
  jq -e '
    all(.[];
      type == "object"
      and .schema_version == 1
      and (.decided_at | type == "number" and . >= 0)
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.agent_type | type == "string" and length > 0)
      and (.native_agent_id | type == "string"
        and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.completion_digest | type == "string"
        and test("^[A-Fa-f0-9]{16,128}$"))
      and (.status | IN("accepted", "rejected"))
      and (.reason | type == "string")
      and (.verdict | IN("PLAN_READY", "NEEDS_CLARIFICATION", "BLOCKED"))
      and (.start_plan_revision | type == "number" and . >= 0
        and floor == .)
      and (.result_plan_revision | type == "number" and . >= 0
        and floor == .))
  ' <<<"${receipts}" >/dev/null 2>&1 || return 1
  match_count="$(jq -r \
    --arg lifecycle "${lifecycle_dispatch_id}" '
      [.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length
    ' <<<"${receipts}")" || return 1
  [[ "${match_count}" == "1" ]] || {
    [[ "${match_count}" == "0" ]] && return 2
    return 1
  }
  _summary_plan_receipt="$(jq -c \
    --arg lifecycle "${lifecycle_dispatch_id}" '
      [.[] | select(.lifecycle_dispatch_id == $lifecycle)][0]
    ' <<<"${receipts}")" || return 1
  jq -e \
    --arg agent "${AGENT_TYPE}" \
    --arg native "${native_agent_id}" \
    --arg digest "${completion_digest}" \
    --arg verdict "${_summary_terminal_verdict}" \
    --argjson start "${start_plan_revision}" '
      .agent_type == $agent
      and .native_agent_id == $native
      and .completion_digest == $digest
      and .verdict == $verdict
      and .start_plan_revision == $start
      and (if .status == "rejected" then true
        elif .verdict == "PLAN_READY"
          then .result_plan_revision == ($start + 1)
        else .result_plan_revision == $start end)
    ' <<<"${_summary_plan_receipt}" >/dev/null 2>&1 || return 1
  _summary_plan_publication_status="$(jq -r '.status' \
    <<<"${_summary_plan_receipt}")"
  _summary_plan_publication_reason="$(jq -r '.reason' \
    <<<"${_summary_plan_receipt}")"
}

_register_plan_summary_waiter_unlocked() {
  local selected="$1" waiters_file pending_file source temp waiter existing_count
  local lifecycle_dispatch_id native_agent_id completion_digest safe_message
  local live_ids
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  [[ ! -L "${waiters_file}" ]] \
    && { [[ ! -e "${waiters_file}" ]] || [[ -f "${waiters_file}" ]]; } \
    || return 1
  lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  native_agent_id="$(jq -r '.native_agent_id // empty' \
    <<<"${selected}" 2>/dev/null || true)"
  safe_message="$(_summary_safe_completion_message)" || return 1
  completion_digest="$(_omc_token_digest "${safe_message}")" || return 1
  [[ "${lifecycle_dispatch_id}" \
      =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && -n "${safe_message}" \
      && "${#safe_message}" -le 131072 ]] || return 1
  waiter="$(jq -nc \
    --argjson schema_version 1 \
    --argjson created_at "$(now_epoch)" \
    --arg lifecycle_dispatch_id "${lifecycle_dispatch_id}" \
    --arg agent_type "${AGENT_TYPE}" \
    --arg native_agent_id "${native_agent_id}" \
    --arg completion_digest "${completion_digest}" \
    --arg message "${safe_message}" '
      {
        schema_version:$schema_version,
        created_at:$created_at,
        lifecycle_dispatch_id:$lifecycle_dispatch_id,
        agent_type:$agent_type,
        native_agent_id:$native_agent_id,
        completion_digest:$completion_digest,
        message:$message
      }
    ')" || return 1
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ ! -L "${pending_file}" && -f "${pending_file}" ]] || return 1
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  live_ids="$(jq -Rsc '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")
      | .lifecycle_dispatch_id
      | select(type == "string" and length > 0)] | unique
  ' "${pending_file}")" || return 1
  source="${waiters_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  existing_count="$(jq -Rsr \
    --arg lifecycle "${lifecycle_dispatch_id}" '
      [split("\n")[] | select(length > 0) | fromjson
        | select(.lifecycle_dispatch_id == $lifecycle)] | length
    ' "${source}" 2>/dev/null)" || return 1
  if [[ "${existing_count}" == "1" ]]; then
    jq -Rse --argjson waiter "${waiter}" '
      ([split("\n")[] | select(length > 0) | fromjson
        | select(.lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id)][0]
        | del(.created_at)) == ($waiter | del(.created_at))
    ' "${source}" >/dev/null 2>&1 && return 0
    return 1
  fi
  [[ "${existing_count}" == "0" ]] || return 1
  temp="$(mktemp "${waiters_file}.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || {
    rm -f "${temp}"
    return 1
  }
  if ! jq -Rsr --argjson waiter "${waiter}" --argjson live "${live_ids}" '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null)] as $rows
      | if all($rows[];
          type == "object"
          and .schema_version == 1
          and (.created_at | type == "number" and . >= 0)
          and (.lifecycle_dispatch_id | type == "string"
            and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
          and (.agent_type | type == "string" and length > 0)
          and (.native_agent_id | type == "string"
            and test("^[A-Za-z0-9._:-]{1,128}$"))
          and (.completion_digest | type == "string"
            and test("^[A-Fa-f0-9]{16,128}$"))
          and (.message | type == "string" and length > 0
            and length <= 131072)) | not
        then error("invalid waiter ledger")
        else ([$rows[] | select(.lifecycle_dispatch_id as $id
                 | ($live | index($id)) != null)] + [$waiter]) as $kept
          | if ($kept | length) > 128 then error("waiter cap")
            else $kept[] | @json end
        end
    ' "${source}" >"${temp}" \
      || ! mv -f "${temp}" "${waiters_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
}

# Atomically claim this completion's exact pending row before interpreting any
# content. The durable claim stays in pending_agents.jsonl through every side
# effect, so an explicit rebind under the same session lock cannot abandon the
# result between validation and commit. Finalization marks effects complete and
# consumes the row; reviewer rows remain claimed until their reviewer-only start
# is consumed too. Abandoned/mismatched/duplicate returns remain non-authoritative.
_claim_summary_pending_unlocked() {
  local pending_file ledger current_ts current_revision line this_type row_id row_native_id
  local existing_claim existing_claim_ts claim_ts claim_id claim_digest
  local claim_message temp_file updated selected="" replaced=0
  local outcomes_file duplicate_digest duplicate_count duplicate_outcomes
  local claim_fault="${OMC_TEST_SUMMARY_CLAIM_FAULT:-}"
  local contract_retry_count=0 contract_retry_cap=3
  local pending_objective_ts current_objective_ts
  local pending_cycle_id current_cycle_id
  local reviewer_current_revision reviewer_start_revision row_version
  local binding_json="" binding_kind="" binding_lifecycle=""
  local binding_review_id="" binding_cycle=0 row_lifecycle candidate=0
  local selected_count=0
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
  _summary_suppress_outcome=0
  _summary_plan_wal_active=0
  _summary_plan_wal_recoverable=0
  _summary_reviewer_wal_active=0
  _summary_reviewer_wal_recoverable=0
  _summary_generic_effects_outcome_recovery_required=0
  _current_council_pending_json=""

  # The internal replay capability bypasses the shared publication fence only
  # for this one claim transition. It must not cross a different publisher's
  # fixed WAL: the matching dedicated kind below can rendezvous with its own WAL,
  # while every sibling kind remains fail-closed until ordinary recovery settles
  # that journal.
  if [[ "${_summary_recovery_admitted:-0}" -eq 1 ]]; then
    local sibling_plan_wal sibling_reviewer_wal
    sibling_plan_wal="$(session_file ".plan-txn.active")"
    sibling_reviewer_wal="$(session_file ".reviewer-transaction.wal")"
    if { [[ "${_summary_enforced_contract_kind}" != "planner" ]] \
          && [[ -e "${sibling_plan_wal}" || -L "${sibling_plan_wal}" ]]; } \
        || { [[ "${_summary_enforced_contract_kind}" != "reviewer" ]] \
          && [[ -e "${sibling_reviewer_wal}" \
            || -L "${sibling_reviewer_wal}" ]]; }; then
      _summary_dispatch_suppression_reason="sibling-publication-transaction-active"
      _summary_suppress_outcome=1
      return 0
    fi
  fi

  # The planner WAL's fixed active name means no plan decision is committed
  # yet. Check before pending-row selection because a killed transaction may
  # already have removed pending/start while its receipt remains provisional.
  # Any presence (directory, symlink, or malformed node) fails closed; a
  # regular live transaction gets a bounded outside-lock retry below.
  if [[ "${_summary_enforced_contract_kind}" == "planner" ]]; then
    local active_plan_wal
    active_plan_wal="$(session_file ".plan-txn.active")"
    if [[ -e "${active_plan_wal}" || -L "${active_plan_wal}" ]]; then
      _summary_dispatch_suppression_reason="plan-publication-transaction-active"
      _summary_suppress_outcome=1
      _summary_plan_wal_active=1
      if _summary_plan_active_wal_valid_unlocked; then
        _summary_plan_wal_recoverable=1
      fi
      return 0
    fi
  fi

  # Reviewer state/evidence has one fixed active WAL as well. Its receipt is
  # deliberately the final publication, so summary effects must wait for the
  # dedicated hook to retire the WAL. A brief outside-lock retry handles normal
  # parallel hook ordering; a persistent valid journal gets one continuation
  # request below so the same native reviewer callback can roll it forward.
  if _summary_reviewer_current_revision "${AGENT_TYPE}" >/dev/null 2>&1; then
    local active_reviewer_wal
    active_reviewer_wal="$(session_file ".reviewer-transaction.wal")"
    if [[ -e "${active_reviewer_wal}" || -L "${active_reviewer_wal}" ]]; then
      _summary_dispatch_suppression_reason="reviewer-publication-transaction-active"
      _summary_suppress_outcome=1
      _summary_reviewer_wal_active=1
      if _summary_reviewer_active_wal_valid_unlocked; then
        _summary_reviewer_wal_recoverable=1
      fi
      return 0
    fi
  fi

  # Cleanup reconciliation itself can rewrite the pending/start pair. Validate
  # both complete ledgers under this lock before entering that shared replay,
  # then validate pending again after replay before this function projects it.
  # The second check also detects any non-cooperative same-user replacement
  # performed while reconciliation staged its generation.
  if ! omc_dispatch_authority_ledger_shell_safe "${pending_file}" \
      || ! omc_dispatch_authority_ledger_shell_safe \
        "$(session_file "agent_dispatch_starts.jsonl")"; then
    _summary_dispatch_suppression_reason="invalid-dispatch-authority-ledger"
    _summary_suppress_outcome=1
    return 0
  fi

  # A prior cleanup-only completion may have committed its exact outcome
  # journal before this replay acquired the lock. Converge that transaction
  # first; the replay must never claim or publish a second result for a row
  # whose durable intent is retirement.
  if ! omc_reconcile_all_ignored_completion_cleanups_unlocked; then
    _summary_cleanup_reconcile_failed=1
    return 1
  fi

  # No authority-bearing ledger may cross into Bash projection until its
  # complete bytes and decoded scalar fields have been validated under this
  # same state lock. Unrelated non-JSON migration noise remains tolerated, but
  # raw/decoded NUL and malformed authority rows preserve every causal record.
  if ! omc_dispatch_authority_ledger_shell_safe "${pending_file}"; then
    _summary_dispatch_suppression_reason="invalid-pending-dispatch-ledger"
    _summary_suppress_outcome=1
    return 0
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
  _summary_native_binding_json=""
  if [[ "${_summary_native_agent_id_present}" -eq 1 \
      && "${_summary_native_agent_id_invalid}" -eq 1 ]]; then
    _summary_dispatch_suppression_reason="invalid-native-agent-id"
    _summary_suppress_outcome=1
    return 0
  fi
  if [[ "${_summary_native_agent_id_present}" -eq 1 \
      && "${_summary_native_agent_id_invalid}" -eq 0 ]]; then
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if ! omc_dispatch_authority_ledger_shell_safe "${bindings_file}"; then
      _summary_dispatch_suppression_reason="invalid-native-binding-ledger"
      _summary_suppress_outcome=1
      return 0
    fi
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && binding_json="$(jq -Rsc --arg id "${_summary_native_agent_id}" \
          --arg type "${AGENT_TYPE}" --arg current "${native_tracking_version}" '
            def base_valid:
              type == "object"
              and (.native_agent_id | type == "string"
                and test("^[A-Za-z0-9._:-]{1,128}$"))
              and (.agent_type | type == "string"
                and test("^[A-Za-z0-9._:-]{1,128}$"));
            def current_valid:
              base_valid
              and (.lifecycle_dispatch_id | type == "string"
                and test("^dispatch-[A-Za-z0-9._:-]{8,120}$"))
              and (.review_dispatch_id | type == "string"
                and test("^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
              and (.objective_cycle_id | type == "number"
                and floor == . and . >= 0)
              and (.ts | type == "number" and floor == . and . >= 0);
            def legacy_valid:
              base_valid and (has("lifecycle_dispatch_id") | not)
              and ((has("review_dispatch_id") | not)
                or (.review_dispatch_id | type == "string"
                  and test("^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
              and ((has("objective_cycle_id") | not)
                or (.objective_cycle_id | type == "number"
                  and floor == . and . >= 0))
              and ((has("ts") | not)
                or (.ts | type == "number" and floor == . and . >= 0));
            [split("\n")[] | select(length > 0)
              | (try fromjson catch null)] as $rows
            | if any($rows[]; . == null or type != "object") then
                error("malformed native binding registry")
              elif any($rows[];
                  (((. | current_valid) or (. | legacy_valid)) | not)) then
                error("invalid native binding registry row")
              else
                [$rows[] | select((.native_agent_id // "") == $id)] as $matches
                | if ($matches | length) != 1 then
                    error("native binding is missing or duplicated")
                  else $matches[0] as $binding
                    | (($binding.native_agent_id == $id
                        and $binding.agent_type == $type)
                      and ($binding | current_valid)) as $current_ok
                    | (($binding.native_agent_id == $id
                        and $binding.agent_type == $type)
                      and ($binding | legacy_valid)) as $legacy_ok
                    | if ($current == "1" and ($current_ok | not))
                        or (($current_ok or $legacy_ok) | not) then
                        error("native binding has an invalid schema")
                      elif $current_ok then
                        if ([$rows[] | select(
                              (.native_agent_id // "") == $id
                              or (.lifecycle_dispatch_id // "")
                                == $binding.lifecycle_dispatch_id
                              or (($binding.review_dispatch_id // "") != ""
                                and (.agent_type // "") == $type
                                and (.review_dispatch_id // "")
                                  == $binding.review_dispatch_id))] | length) != 1
                        then error("native binding authority is duplicated")
                        else $binding + {binding_kind:"current"}
                        end
                      else $binding + {binding_kind:"legacy"}
                      end
                  end
              end
          ' "${bindings_file}" 2>/dev/null)"; then
      _summary_native_binding_committed=1
      _summary_native_binding_json="${binding_json}"
    fi
  fi
  if [[ "${native_tracking_version}" == "1" ]]; then
    if [[ "${_summary_native_agent_id_present}" -eq 0 ]]; then
      _summary_dispatch_suppression_reason="missing-native-agent-id"
      _summary_suppress_outcome=1
      return 0
    elif [[ "${_summary_native_agent_id_invalid}" -eq 1 ]]; then
      _summary_dispatch_suppression_reason="invalid-native-agent-id"
      _summary_suppress_outcome=1
      return 0
    elif [[ "${_summary_native_binding_committed}" -ne 1 ]]; then
      _summary_dispatch_suppression_reason="native-agent-binding-uncommitted"
      _summary_suppress_outcome=1
      return 0
    fi
    _summary_use_native_agent_id=1
  elif [[ "${_summary_native_binding_committed}" -eq 1 ]]; then
    # A committed bind is sufficient even if a migrated state file lost the
    # marker; the registry remains the crash-safe source of truth.
    _summary_use_native_agent_id=1
  fi

  if [[ "${_summary_use_native_agent_id}" -eq 1 ]]; then
    binding_kind="$(jq -r '.binding_kind' \
      <<<"${_summary_native_binding_json}")" || return 1
    if [[ "${binding_kind}" == "current" ]]; then
      binding_lifecycle="$(jq -r '.lifecycle_dispatch_id' \
        <<<"${_summary_native_binding_json}")" || return 1
      binding_review_id="$(jq -r '.review_dispatch_id // ""' \
        <<<"${_summary_native_binding_json}")" || return 1
      binding_cycle="$(jq -r '.objective_cycle_id' \
        <<<"${_summary_native_binding_json}")" || return 1
    fi
  fi

  if [[ -L "${pending_file}" ]]; then
    _summary_dispatch_suppression_reason="invalid-pending-dispatch-ledger"
    _summary_suppress_outcome=1
    return 0
  elif [[ -f "${pending_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
      row_id="$(jq -r '.review_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      row_native_id="$(jq -r '.native_agent_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
        if [[ "${binding_kind}" == "current" ]] \
            && { [[ "${line}" == *"${_summary_native_agent_id}"* ]] \
              || [[ "${line}" == *"${binding_lifecycle}"* ]] \
              || { [[ -n "${binding_review_id}" ]] \
                && [[ "${line}" == *"${binding_review_id}"* ]]; }; }; then
          _summary_dispatch_suppression_reason="invalid-native-causal-row"
          _summary_suppress_outcome=1
          return 0
        fi
        continue
      fi
      if [[ "${this_type}" == "${AGENT_TYPE}" ]]; then
        _summary_same_agent_pending=1
      fi
      candidate=0
      if [[ "${_summary_use_native_agent_id}" -eq 1 \
          && "${binding_kind}" == "current" ]] \
          && { [[ "${row_native_id}" == "${_summary_native_agent_id}" ]] \
            || [[ "${row_lifecycle}" == "${binding_lifecycle}" ]] \
            || { [[ -n "${binding_review_id}" ]] \
              && [[ "${row_id}" == "${binding_review_id}" ]] \
              && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; }; then
        candidate=1
        if ! jq -e --arg native "${_summary_native_agent_id}" \
            --arg type "${AGENT_TYPE}" \
            --arg lifecycle "${binding_lifecycle}" \
            --arg review "${binding_review_id}" \
            --argjson cycle "${binding_cycle}" '
              type == "object"
              and (.native_agent_id // "") == $native
              and (.agent_type // "") == $type
              and (.lifecycle_dispatch_id // "") == $lifecycle
              and (.review_dispatch_id // "") == $review
              and (.objective_cycle_id // -1) == $cycle
            ' <<<"${line}" >/dev/null 2>&1; then
          _summary_dispatch_suppression_reason="invalid-native-causal-row"
          _summary_suppress_outcome=1
          return 0
        fi
      elif [[ "${_summary_use_native_agent_id}" -eq 1 \
          && "${binding_kind}" == "legacy" \
          && "${row_native_id}" == "${_summary_native_agent_id}" ]]; then
        candidate=1
        if ! jq -e --arg native "${_summary_native_agent_id}" \
            --arg type "${AGENT_TYPE}" '
              type == "object"
              and (.native_agent_id // "") == $native
              and (.agent_type // "") == $type
              and (has("lifecycle_dispatch_id") | not)
            ' <<<"${line}" >/dev/null 2>&1; then
          _summary_dispatch_suppression_reason="invalid-legacy-causal-row"
          _summary_suppress_outcome=1
          return 0
        fi
      elif { [[ "${_summary_use_native_agent_id}" -eq 0 ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]] \
            && [[ -n "${_summary_review_dispatch_id}" ]] \
            && [[ "${row_id}" == "${_summary_review_dispatch_id}" ]] \
            && [[ -z "${row_native_id}" ]]; } \
          || { [[ "${_summary_use_native_agent_id}" -eq 0 ]] \
               && [[ "${this_type}" == "${AGENT_TYPE}" ]] \
               && [[ -z "${_summary_review_dispatch_id}" ]] \
               && [[ -z "${row_id}" && -z "${row_native_id}" ]]; }; then
        candidate=1
      fi
      if [[ "${candidate}" -eq 1 ]]; then
        selected_count=$((selected_count + 1))
        selected="${line}"
      fi
    done <"${pending_file}"
  fi
  if [[ "${selected_count}" -gt 1 ]]; then
    _summary_dispatch_suppression_reason="ambiguous-pending-dispatch"
    # Ambiguous authority is ledger corruption, not an attributable ignored
    # completion. Preserve every causal row and mint no parent-facing outcome;
    # lifecycle recovery or explicit repair must resolve the ambiguity first.
    _summary_suppress_outcome=1
    return 0
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
  elif [[ -z "${selected}" \
      && "${_summary_enforced_contract_kind}" == "planner" \
      && "${_summary_use_native_agent_id}" -eq 1 ]] \
      && _summary_plan_parent_outcome_already_committed_unlocked; then
    _summary_dispatch_suppression_reason="completion-outcome-already-committed"
    _summary_suppress_outcome=1
    return 0
  elif [[ -z "${selected}" && "${_summary_use_native_agent_id}" -eq 1 ]]; then
    # The platform may redeliver an already accepted immutable completion
    # after its pending row settled. Recognize the exact native/role/digest
    # before classifying the now-absent pending identity as a mismatch.
    outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
    duplicate_digest="$(_summary_plan_completion_digest 2>/dev/null || true)"
    duplicate_count=0
    if [[ -f "${outcomes_file}" && ! -L "${outcomes_file}" \
        && "${duplicate_digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]]; then
      duplicate_outcomes="$(omc_causal_completion_outcomes_json_unlocked \
        "${outcomes_file}" 2>/dev/null || true)"
      duplicate_count="$(jq -r \
        --arg agent "${AGENT_TYPE}" \
        --arg native "${_summary_native_agent_id}" \
        --arg digest "${duplicate_digest}" '
          [.[] | select(.agent_type == $agent
              and (.native_agent_id // "") == $native
              and (.completion_digest // "") == $digest
              and .status == "accepted")] | length
        ' <<<"${duplicate_outcomes}" 2>/dev/null || true)"
    fi
    if [[ "${duplicate_count}" == "1" ]]; then
      _summary_dispatch_suppression_reason="duplicate-completion-already-accepted"
      _summary_suppress_outcome=1
      return 0
    elif [[ "${duplicate_count}" != "0" ]]; then
      _summary_dispatch_suppression_reason="ambiguous-accepted-completion"
      _summary_suppress_outcome=1
      return 0
    fi
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
      fi
      if [[ "${reviewer_start_revision}" != "${reviewer_current_revision}" ]]; then
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="review-generation-changed"
        _summary_cleanup_allowed=1
        return 0
      fi
    fi
  fi

  # A stateful callback can die after the universal hook has durably claimed
  # its row but before either dedicated publisher leaves a WAL or receipt. Once
  # that exact digest-bound lease has expired, there is no authoritative plan
  # or review decision to replay. The recovery barrier invokes this narrow
  # cleanup-only mode to journal an ignored outcome and retire the exact
  # pending/start pair; it never publishes summary, Council, scope, dimension,
  # or plan effects. Re-check every authority bit under this same state lock so
  # a concurrently committed dedicated receipt wins instead of being erased.
  if [[ "${OMC_ORPHANED_DEDICATED_CLAIM_RETIRE:-0}" == "1" ]]; then
    local orphan_claim orphan_claim_ts orphan_now orphan_message orphan_digest
    local orphan_actual_digest orphan_lifecycle orphan_receipts orphan_matches
    [[ -n "${selected}" \
        && "${_summary_enforced_contract_kind}" \
          =~ ^(planner|reviewer)$ ]] || return 1
    orphan_claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    orphan_claim_ts="$(jq -r '.completion_claim_ts // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    orphan_message="$(jq -r '.completion_claim_message // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    orphan_digest="$(jq -r '.completion_claim_digest // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    orphan_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    orphan_now="$(now_epoch)"
    orphan_actual_digest="$(_omc_token_digest \
      "${orphan_message}" 2>/dev/null || true)"
    _omc_canonical_uint_in_range \
      "${orphan_claim_ts}" 1 999999999999999999 || return 1
    _omc_canonical_uint_in_range \
      "${orphan_now}" 1 999999999999999999 || return 1
    [[ "${orphan_claim}" == \
          "${OMC_PUBLICATION_RECOVERY_CLAIM_ID:-}" \
        && "${orphan_claim}" \
          =~ ^completion-[A-Za-z0-9._:-]{8,160}$ \
        && $((orphan_now - orphan_claim_ts)) -gt 120 \
        && -n "${orphan_message}" \
        && "${#orphan_message}" -le 131072 \
        && "${orphan_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
        && "${orphan_actual_digest}" == "${orphan_digest}" \
        && "${LAST_ASSISTANT_MESSAGE}" == "${orphan_message}" \
        && "${orphan_lifecycle}" \
          =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
    case "${_summary_enforced_contract_kind}" in
      planner)
        [[ ! -e "$(session_file ".plan-txn.active")" \
            && ! -L "$(session_file ".plan-txn.active")" ]] || return 1
        orphan_receipts="$(session_file "plan_publication_outcomes.jsonl")"
        ;;
      reviewer)
        [[ ! -e "$(session_file ".reviewer-transaction.wal")" \
            && ! -L "$(session_file ".reviewer-transaction.wal")" ]] \
          || return 1
        orphan_receipts="$(session_file "reviewer_publication_outcomes.jsonl")"
        ;;
    esac
    [[ ! -L "${orphan_receipts}" ]] \
      && { [[ ! -e "${orphan_receipts}" ]] \
        || [[ -f "${orphan_receipts}" ]]; } || return 1
    orphan_matches=0
    if [[ -s "${orphan_receipts}" ]]; then
      orphan_matches="$(jq -Rsr \
        --arg lifecycle "${orphan_lifecycle}" \
        --arg agent "${AGENT_TYPE}" \
        --arg native "${_summary_native_agent_id}" \
        --arg digest "${orphan_digest}" '
          [split("\n")[] | select(length > 0) | fromjson
            | select((.lifecycle_dispatch_id // "") == $lifecycle
              and (.agent_type // "") == $agent
              and (.native_agent_id // "") == $native
              and (.completion_digest // "") == $digest)] | length
        ' "${orphan_receipts}" 2>/dev/null)" || return 1
    fi
    [[ "${orphan_matches}" == "0" ]] || return 1
    _summary_pending_json="${selected}"
    _summary_dispatch_suppression_reason="orphaned-dedicated-publication"
    _summary_cleanup_allowed=1
    _summary_suppress_outcome=0
    return 0
  fi

  # Match the excellence return to the exact contract revision bound into its
  # pending row. This repeats the role-specific hook's decision under the
  # universal claim lock so either SubagentStop hook order rejects a stale bar
  # before summaries, scope, or Council effects can land.
  if [[ -n "${selected}" \
      && "${AGENT_TYPE}" == "excellence-reviewer" \
      && "$(read_state "quality_contract_required" 2>/dev/null || true)" == "1" ]]; then
    local_quality_contract=""
    if ! _omc_load_quality_contract 2>/dev/null \
        || ! local_quality_contract="$(quality_contract_validate_current 2>/dev/null)" \
        || [[ "$(jq -r '.quality_contract_id // empty' <<<"${selected}" 2>/dev/null || true)" \
          != "$(jq -r '.contract_id' <<<"${local_quality_contract}" 2>/dev/null || true)" ]] \
        || [[ "$(jq -r '.quality_contract_revision // empty' <<<"${selected}" 2>/dev/null || true)" \
          != "$(jq -r '.contract_revision' <<<"${local_quality_contract}" 2>/dev/null || true)" ]] \
        || ! quality_review_validate_against_contract \
          "${_summary_quality_review:-}" "${local_quality_contract}" \
          "${_summary_final_line}" 2>/dev/null; then
      _summary_valid_enforced_contract=0
      _summary_structured_contract_error="The excellence return is not bound to the current frozen Definition revision. Continue or redispatch the reviewer against the current contract."
    else
      _summary_quality_contract="${local_quality_contract}"
    fi
  fi

  # Reviewer publication is also a two-hook decision. Generation/contract
  # shape above are necessary preconditions, but only the dedicated reviewer's
  # lifecycle+completion-digest receipt proves its verdict/evidence commit.
  # Summary-first order records a redacted waiter and publishes zero effects;
  # record-reviewer replays it after its receipt (the last WAL write) lands.
  if [[ -n "${selected}" && -n "${reviewer_current_revision:-}" ]] \
      && { [[ "${_summary_enforced_contract_kind}" != "reviewer" ]] \
        || [[ "${_summary_valid_enforced_contract}" -eq 1 ]]; }; then
    local reviewer_decision_rc=0
    _summary_reviewer_publication_decision_unlocked "${selected}" \
      || reviewer_decision_rc=$?
    case "${reviewer_decision_rc}" in
      0)
        if [[ "${_summary_reviewer_publication_status}" == "rejected" ]]; then
          _summary_pending_json="${selected}"
          _summary_dispatch_suppression_reason="reviewer-publication-rejected${_summary_reviewer_publication_reason:+:${_summary_reviewer_publication_reason}}"
          _summary_cleanup_allowed=1
          return 0
        fi
        [[ "${_summary_reviewer_publication_status}" == "accepted" ]] || {
          _summary_pending_json="${selected}"
          _summary_dispatch_suppression_reason="reviewer-publication-authority-invalid"
          _summary_suppress_outcome=1
          return 0
        }
        # Reviewer-first order needs the same durable replay handle as
        # summary-first order. If this process dies after claiming but before
        # universal effects/outcome settle, receipt + waiter + pending carries
        # the exact redacted message/digest needed for lease-bound takeover.
        _register_reviewer_summary_waiter_unlocked "${selected}" || return 1
        ;;
      2)
        _register_reviewer_summary_waiter_unlocked "${selected}" || return 1
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="reviewer-publication-pending"
        _summary_suppress_outcome=1
        return 0
        ;;
      *)
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="reviewer-publication-authority-invalid"
        _summary_suppress_outcome=1
        return 0
        ;;
    esac
  fi

  # Planner publication is a two-hook decision. The universal hook may arrive
  # first, but a valid-looking PLAN_READY is not authoritative until the
  # dedicated plan hook has committed an exact lifecycle/digest receipt. Leave
  # a redacted waiter for summary-first order; record-plan replays it after the
  # receipt commit. A rejected receipt retires the exact pending row without
  # any accepted side effect. Missing or corrupt authority preserves the row
  # and publishes no misleading ignored/accepted parent outcome.
  if [[ -n "${selected}" \
      && "${_summary_enforced_contract_kind}" == "planner" \
      && "${_summary_valid_enforced_contract}" -eq 1 ]]; then
    local plan_decision_rc=0
    _summary_plan_publication_decision_unlocked "${selected}" \
      || plan_decision_rc=$?
    case "${plan_decision_rc}" in
      0)
        if [[ "${_summary_plan_publication_status}" == "rejected" ]]; then
          _summary_pending_json="${selected}"
          _summary_dispatch_suppression_reason="plan-publication-rejected${_summary_plan_publication_reason:+:${_summary_plan_publication_reason}}"
          _summary_cleanup_allowed=1
          return 0
        fi
        [[ "${_summary_plan_publication_status}" == "accepted" ]] || {
          _summary_pending_json="${selected}"
          _summary_dispatch_suppression_reason="plan-publication-authority-invalid"
          _summary_suppress_outcome=1
          return 0
        }
        # Keep one exact redacted completion waiter even when the dedicated
        # planner won the hook race.  The accepted parent outcome is published
        # after summary effects, so without this durable message/digest handle
        # process death in that gap leaves receipt + effects with nothing a
        # later recovery process can safely replay.  Registration is
        # lifecycle-idempotent and therefore also validates an existing
        # summary-first waiter.
        _register_plan_summary_waiter_unlocked "${selected}" || return 1
        ;;
      2)
        _register_plan_summary_waiter_unlocked "${selected}" || return 1
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="plan-publication-pending"
        _summary_suppress_outcome=1
        _claim_plan_recovery_notice_unlocked "${selected}" || return 1
        return 0
        ;;
      *)
        _summary_pending_json="${selected}"
        _summary_dispatch_suppression_reason="plan-publication-authority-invalid"
        _summary_suppress_outcome=1
        return 0
        ;;
    esac
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
      if [[ "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
          && -n "${reviewer_current_revision:-}" \
          && "${_summary_reviewer_publication_status:-}" == "accepted" \
          && "$(jq -r '.completion_claim_effects_complete // false' \
            <<<"${selected}" 2>/dev/null || true)" == "true" ]]; then
        # Reviewer replay committed universal effects and retained the exact
        # pending row, but the process died before its accepted parent outcome
        # landed. Only the exact receipt/digest-bound replay may repair that
        # split; do not run summaries/scope/Council effects twice.
        _summary_pending_json="${selected}"
        _summary_reviewer_effects_outcome_recovery_required=1
        _summary_dispatch_suppression_reason="reviewer-summary-outcome-recovery"
        _summary_suppress_outcome=1
        return 0
      fi
      if [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" == "1" \
          && "${_summary_enforced_contract_kind}" == "planner" \
          && "${_summary_plan_publication_status:-}" == "accepted" \
          && "$(jq -r '.completion_claim_effects_complete // false' \
            <<<"${selected}" 2>/dev/null || true)" == "true" ]]; then
        # Summary effects committed before the dedicated planner consumed its
        # start, but the process died before the accepted parent outcome landed.
        # An exact receipt-bound waiter replay may repair only that missing
        # outcome; it must not re-run summaries/scope/Council side effects.
        _summary_pending_json="${selected}"
        _summary_plan_effects_outcome_recovery_required=1
        _summary_dispatch_suppression_reason="plan-summary-outcome-recovery"
        _summary_suppress_outcome=1
        return 0
      fi
      if [[ "$(jq -r '.completion_claim_effects_complete // false' \
          <<<"${selected}" 2>/dev/null || true)" == "true" ]]; then
        claim_digest="$(_summary_plan_completion_digest 2>/dev/null || true)"
        if [[ "${claim_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
            && "$(jq -r '.completion_claim_digest // empty' \
              <<<"${selected}" 2>/dev/null || true)" \
              == "${claim_digest}" ]]; then
          # Any exact duplicate native callback can roll forward the narrow
          # split where effects committed but the parent outcome did not. It
          # publishes no summary/scope/Council effect again.
          _summary_pending_json="${selected}"
          _summary_generic_effects_outcome_recovery_required=1
          _summary_dispatch_suppression_reason="summary-effects-outcome-recovery"
          _summary_suppress_outcome=1
          return 0
        fi
      fi
      # A receipt-bound replay may take over an incomplete claim only after
      # its recoverable lease expires. Until then the original summary process
      # is the sole effects publisher and the universal state-lock barrier
      # freezes prompt/objective transitions. Replay uses the same lifecycle,
      # native ID, completion digest, and message; lifecycle-idempotent effect
      # recorders below make a crash at any prior effect boundary safe.
      existing_claim_ts="$(jq -r '.completion_claim_ts // 0' \
        <<<"${selected}" 2>/dev/null || true)"
      claim_ts="$(now_epoch)"
      [[ "${existing_claim_ts}" =~ ^[0-9]+$ ]] || existing_claim_ts=0
      [[ "${claim_ts}" =~ ^[0-9]+$ ]] || claim_ts=0
      if { [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" == "1" \
              && "${_summary_enforced_contract_kind}" == "planner" \
              && "${_summary_plan_publication_status:-}" == "accepted" ]] \
          || [[ "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
              && -n "${reviewer_current_revision:-}" \
              && "${_summary_reviewer_publication_status:-}" == "accepted" ]] \
          || [[ "${OMC_GENERIC_SUMMARY_REPLAY:-0}" == "1" \
              && "${_summary_enforced_contract_kind}" != "planner" \
              && -z "${reviewer_current_revision:-}" ]]; } \
          && [[ "$(jq -r '.completion_claim_effects_complete // false' \
            <<<"${selected}" 2>/dev/null || true)" != "true" ]] \
          && (( claim_ts - existing_claim_ts > 120 )); then
        claim_id="completion-recovery-${claim_ts}-$$"
        claim_message="$(_summary_safe_completion_message)" || return 1
        [[ -n "${claim_message}" && "${#claim_message}" -le 131072 ]] \
          || return 1
        claim_digest="$(_omc_token_digest "${claim_message}")" || return 1
        [[ "$(jq -r '.completion_claim_digest // empty' \
            <<<"${selected}" 2>/dev/null || true)" == "${claim_digest}" \
            && "$(jq -r '.completion_claim_message // empty' \
              <<<"${selected}" 2>/dev/null || true)" == "${claim_message}" ]] \
          || return 1
        updated="$(jq -c \
          --arg claim_id "${claim_id}" \
          --arg prior_claim_id "${existing_claim}" \
          --arg claim_digest "${claim_digest}" \
          --arg claim_message "${claim_message}" \
          --argjson claim_ts "${claim_ts}" '
            .completion_claim_id = $claim_id
            | .completion_claim_ts = $claim_ts
            | .completion_claim_effects_complete = false
            | .completion_claim_recovered_from = $prior_claim_id
            | .completion_claim_digest = $claim_digest
            | .completion_claim_message = $claim_message
          ' <<<"${selected}")" || return 1
        rewrite_jsonl_line_atomic "${pending_file}" "${selected}" \
          "${updated}" || return 1
        _summary_pending_json="${updated}"
        _summary_completion_claim_id="${claim_id}"
        _summary_claim_owned=1
        _summary_cleanup_allowed=1
      else
        _summary_dispatch_suppression_reason="completion-already-claimed"
        # A receipt-bound recovery probe may race the still-live exact owner.
        # It is neither an ignored completion nor cleanup authority; publishing
        # an ignored lifecycle outcome here would later conflict with the
        # owner's accepted outcome.
        if [[ "${OMC_PLAN_SUMMARY_REPLAY:-0}" == "1" \
            || "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
            || "${OMC_GENERIC_SUMMARY_REPLAY:-0}" == "1" ]]; then
          _summary_suppress_outcome=1
        fi
        return 0
      fi
    else
      claim_ts="$(now_epoch)"
      [[ "${claim_ts}" =~ ^[0-9]+$ ]] || claim_ts=0
      claim_id="completion-${claim_ts}-$$"
      claim_message="$(_summary_safe_completion_message)" || return 1
      [[ -n "${claim_message}" && "${#claim_message}" -le 131072 ]] \
        || return 1
      claim_digest="$(_omc_token_digest "${claim_message}")" || return 1
      updated="$(jq -c \
        --arg claim_id "${claim_id}" \
        --arg claim_digest "${claim_digest}" \
        --arg claim_message "${claim_message}" \
        --argjson claim_ts "${claim_ts}" '
          . + {
            completion_claim_id:$claim_id,
            completion_claim_ts:$claim_ts,
            completion_claim_effects_complete:false,
            completion_claim_digest:$claim_digest,
            completion_claim_message:$claim_message
          }
        ' <<<"${selected}")" || return 1
      rewrite_jsonl_line_atomic "${pending_file}" "${selected}" "${updated}" \
        "${claim_fault}" || return 1
      _summary_pending_json="${updated}"
      _summary_completion_claim_id="${claim_id}"
      _summary_claim_owned=1
      _summary_cleanup_allowed=1
    fi
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
_summary_suppress_outcome=0
_summary_plan_wal_active=0
_summary_plan_wal_recoverable=0
_summary_plan_recovery_retry_required=0
_summary_plan_recovery_retry_exhausted=0
_summary_reviewer_wal_active=0
_summary_reviewer_wal_recoverable=0
_summary_reviewer_recovery_retry_required=0
_summary_reviewer_recovery_retry_exhausted=0
_summary_plan_effects_outcome_recovery_required=0
_summary_reviewer_effects_outcome_recovery_required=0
_summary_generic_effects_outcome_recovery_required=0
_summary_claim_lock_rc=0
_with_summary_claim_lock() {
  if [[ "${_summary_recovery_admitted:-0}" -eq 1 ]]; then
    with_state_lock_publication_recovery _claim_summary_pending_unlocked
  else
    with_state_lock _claim_summary_pending_unlocked
  fi
}
_with_summary_claim_lock || _summary_claim_lock_rc=$?

# In the normal parallel-hook order, record-plan may hold the lock with its
# active WAL for only a short publication window. Never wait while holding the
# shared lock: retry the complete claim decision after releasing it. A killed
# or malformed transaction remains fail-closed after this bounded window and
# requires the exact planner callback/recovery path to converge the WAL.
_summary_plan_wal_wait_attempts="${OMC_SUMMARY_PLAN_WAL_WAIT_ATTEMPTS:-120}"
if [[ ! "${_summary_plan_wal_wait_attempts}" =~ ^[1-9][0-9]*$ \
    || "${_summary_plan_wal_wait_attempts}" -gt 400 ]]; then
  _summary_plan_wal_wait_attempts=120
fi
_summary_plan_wal_wait_count=0
while { [[ "${_summary_plan_wal_active:-0}" -eq 1 ]] \
    || [[ "${_summary_claim_lock_rc}" -ne 0 \
      && "${_summary_enforced_contract_kind}" == "planner" ]]; } \
    && (( _summary_plan_wal_wait_count < _summary_plan_wal_wait_attempts )); do
  sleep 0.05
  _summary_plan_wal_wait_count=$((_summary_plan_wal_wait_count + 1))
  _summary_plan_wal_active=0
  _summary_plan_wal_recoverable=0
  _summary_claim_lock_rc=0
  _with_summary_claim_lock \
    || _summary_claim_lock_rc=$?
done
# Narrow process-local publication capability. The universal state-lock fence
# still blocks every other hook while this receipt-bound claim is incomplete;
# only the process that wrote the exact claim ID may publish its own effects,
# accepted outcome, and cleanup. It is deliberately not exported.
if [[ "${_summary_claim_owned:-0}" -eq 1 \
    && -n "${_summary_completion_claim_id:-}" ]]; then
  OMC_PUBLICATION_RECOVERY_CLAIM_ID="${_summary_completion_claim_id}"
fi
if [[ "${_summary_enforced_contract_kind}" == "planner" \
    && "${_summary_claim_lock_rc}" -ne 0 ]]; then
  _summary_dispatch_suppressed=1
  _summary_dispatch_suppression_reason="plan-publication-lock-unavailable"
  _summary_suppress_outcome=1
elif [[ "${_summary_plan_wal_active:-0}" -eq 1 ]]; then
  # The active WAL already proves the dedicated hook died after its rollback
  # snapshot became durable. Validate that it belongs to this exact native
  # planner above, then recover immediately while no summary claim is held.
  # Waiting for a second planner return to perform rollback left a window where
  # prompt/session hooks could write newer state that the delayed rollback would
  # erase. The continuation below now asks only for authoritative re-publication
  # after the old complete generation has been restored.
  if [[ "${_summary_plan_wal_recoverable:-0}" -eq 1 ]] \
      && bash "${SCRIPT_DIR}/record-plan.sh" \
        --recover-active "${SESSION_ID}" </dev/null >/dev/null 2>&1 \
      && [[ ! -e "$(session_file ".plan-txn.active")" \
        && ! -L "$(session_file ".plan-txn.active")" ]]; then
    _summary_plan_recovery_retry_required=1
  else
    _summary_plan_recovery_retry_exhausted=1
  fi
fi

# Do the same bounded outside-lock rendezvous for a dedicated reviewer WAL.
# Test callers may reduce the attempts; production caps the wait at 20 seconds.
_summary_reviewer_wal_wait_attempts="${OMC_SUMMARY_REVIEWER_WAL_WAIT_ATTEMPTS:-120}"
if [[ ! "${_summary_reviewer_wal_wait_attempts}" =~ ^[1-9][0-9]*$ \
    || "${_summary_reviewer_wal_wait_attempts}" -gt 400 ]]; then
  _summary_reviewer_wal_wait_attempts=120
fi
_summary_reviewer_wal_wait_count=0
_summary_has_dedicated_reviewer=0
if _summary_reviewer_current_revision "${AGENT_TYPE}" >/dev/null 2>&1; then
  _summary_has_dedicated_reviewer=1
fi
while { [[ "${_summary_reviewer_wal_active:-0}" -eq 1 ]] \
    || [[ "${_summary_claim_lock_rc}" -ne 0 \
      && "${_summary_has_dedicated_reviewer}" -eq 1 ]]; } \
    && (( _summary_reviewer_wal_wait_count \
      < _summary_reviewer_wal_wait_attempts )); do
  sleep 0.05
  _summary_reviewer_wal_wait_count=$((_summary_reviewer_wal_wait_count + 1))
  _summary_reviewer_wal_active=0
  _summary_reviewer_wal_recoverable=0
  _summary_claim_lock_rc=0
  _with_summary_claim_lock \
    || _summary_claim_lock_rc=$?
done
if [[ "${_summary_has_dedicated_reviewer}" -eq 1 \
    && "${_summary_claim_lock_rc}" -ne 0 ]]; then
  _summary_dispatch_suppressed=1
  _summary_dispatch_suppression_reason="reviewer-publication-lock-unavailable"
  _summary_suppress_outcome=1
elif [[ "${_summary_reviewer_wal_active:-0}" -eq 1 ]]; then
  _summary_reviewer_retry_lock_rc=1
  if [[ "${_summary_reviewer_wal_recoverable:-0}" -eq 1 ]]; then
    if [[ "${_summary_recovery_admitted:-0}" -eq 1 ]]; then
      with_state_lock_publication_recovery \
        _mark_reviewer_recovery_retry_unlocked \
        && _summary_reviewer_retry_lock_rc=0
    elif with_state_lock _mark_reviewer_recovery_retry_unlocked; then
      _summary_reviewer_retry_lock_rc=0
    fi
  fi
  if [[ "${_summary_reviewer_retry_lock_rc}" -eq 0 ]]; then
    :
  else
    _summary_reviewer_recovery_retry_exhausted=1
  fi
fi

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

if [[ "${_summary_plan_recovery_retry_required}" -eq 1 ]]; then
  _summary_plan_recovery_context="The dedicated planner publication transaction was interrupted after this exact native plan return. oh-my-claude has already restored the complete pre-publication generation and retained this exact causal planner call. Return the same complete self-contained plan once more now, with the same terminal VERDICT, so the dedicated planner hook can commit one authoritative plan generation before universal summary effects are accepted."
  # Rollback promises a byte-exact pre-publication state generation. The
  # recovery notice already durably records this transition; allocating a gate
  # event here would re-mutate session_state via gate_event_seq immediately
  # after restore and violate that atomicity contract.
  jq -nc \
    --arg ctx "$(truncate_chars 1200 "${_summary_plan_recovery_context}")" \
    '{hookSpecificOutput:{hookEventName:"SubagentStop",additionalContext:$ctx}}'
  exit 0
fi

if [[ "${_summary_plan_recovery_retry_exhausted}" -eq 1 ]]; then
  # A repeated persistent return or malformed WAL is not authority for another
  # native continuation. Preserve every causal artifact and publish no generic
  # completion outcome; /ulw-off remains the explicit reset for corrupt state.
  # A gate event itself acquires the ordinary state lock, whose recovery fence
  # would consume the WAL we are deliberately preserving. Keep this diagnostic
  # in the append-only anomaly log instead.
  log_anomaly "record-subagent-summary" \
    "planner publication WAL remained active or invalid for ${AGENT_TYPE}"
  exit 0
fi

if [[ "${_summary_reviewer_recovery_retry_required}" -eq 1 ]]; then
  _summary_reviewer_recovery_context="The dedicated reviewer publication transaction was interrupted after this exact native review return. The causal reviewer call and its durable recovery journal are retained. Return the same complete self-contained review result once more now, with the same terminal VERDICT, so the dedicated reviewer hook can finish recovery before universal summary effects are accepted."
  # As above, the dedicated recovery journal is the durable audit artifact.
  # Do not advance gate_event_seq after restoring the old reviewer generation.
  jq -nc \
    --arg ctx "$(truncate_chars 1200 "${_summary_reviewer_recovery_context}")" \
    '{hookSpecificOutput:{hookEventName:"SubagentStop",additionalContext:$ctx}}'
  exit 0
fi

if [[ "${_summary_reviewer_recovery_retry_exhausted}" -eq 1 ]]; then
  # A second persistent return, malformed WAL, symlink, or hash mismatch is
  # not safe authority for another continuation loop. Preserve every causal
  # artifact and emit no summary/outcome; /ulw-off remains the explicit reset.
  # Do not call the state-backed gate recorder here: its ordinary lock would
  # run recovery and erase the malformed retry authority on this fail-closed
  # path. The anomaly log is intentionally outside that transaction.
  log_anomaly "record-subagent-summary" \
    "reviewer publication WAL remained active or invalid for ${AGENT_TYPE}"
  exit 0
fi

if [[ "${_summary_contract_retry_required}" -eq 1 ]]; then
  _summary_contract_hint="$(omc_enforced_terminal_contract_hint \
    "${AGENT_TYPE}")"
  if [[ -n "${_summary_structured_contract_error}" ]]; then
    _summary_retry_context="Your response ended at an intermediate checkpoint without the complete required ${_summary_enforced_contract_kind} contract. ${_summary_structured_contract_error} Continue from the retained context now, finish every outstanding check, and return the complete self-contained ${_summary_enforced_contract_kind} result—not only the missing line. Do not stop at another future-tense progress update. Reserve the final turn for the required structural JSON line, optional dispatch ID, then exactly one role-valid line: ${_summary_contract_hint}."
  else
    _summary_retry_context="Your response ended at an intermediate checkpoint without the required final ${_summary_enforced_contract_kind} verdict. Continue from the retained context now, finish every outstanding check, and return the complete self-contained ${_summary_enforced_contract_kind} result—not only the missing verdict. Do not stop at another future-tense progress update. Reserve the final turn for exactly one role-valid line: ${_summary_contract_hint}."
  fi
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
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
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
            .completion_claim_effects_complete,.completion_claim_digest,
            .completion_claim_message,.completion_claim_recovered_from)
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
  if [[ "${_summary_recovery_admitted:-0}" -eq 1 ]]; then
    # An internal receipt-bound replay is itself the publication barrier's
    # convergence action. Before it commits an ignored/accepted outcome, any
    # state-backed diagnostic would enter the ordinary fence and recursively
    # launch the same replay. Valid cleanup leaves its receipt + parent journal
    # as the durable audit trail; invalid authority remains byte-exact for the
    # caller's one-shot recovery error.
    :
  else
    record_gate_event "subagent-summary" "stale-result-ignored" \
      "agent=${AGENT_TYPE}" \
      "reason=${_summary_dispatch_suppression_reason}" 2>/dev/null || true
  fi
fi

_summary_deferred_outcome_row=""
_record_completion_outcome() {
  local status="$1" reason="$2" message="$3" mode="${4:-commit}"
  local row verdict="UNREPORTED"
  local findings_count=0 finding_ids="" finding_index=0 finding_row finding_claim finding_id
  local outcome_native_agent_id="" outcome_dispatch_id=""
  local outcome_objective_cycle_id=0 outcome_objective_prompt_ts=0
  local outcome_review_revision=0
  local outcome_lifecycle_dispatch_id=""
  local outcome_completion_digest=""
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
    outcome_lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
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
  [[ "${outcome_lifecycle_dispatch_id}" \
      =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]] \
    || outcome_lifecycle_dispatch_id=""
  if [[ -n "${message}" ]]; then
    outcome_completion_digest="$(_omc_token_digest \
      "$(_summary_safe_completion_message)" 2>/dev/null || true)"
    [[ "${outcome_completion_digest}" \
        =~ ^[A-Fa-f0-9]{16,128}$ ]] || outcome_completion_digest=""
  fi
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
    --arg lifecycle_dispatch_id "${outcome_lifecycle_dispatch_id}" \
    --arg completion_digest "${outcome_completion_digest}" \
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
     + if $lifecycle_dispatch_id == "" then {} else {
         lifecycle_dispatch_id:$lifecycle_dispatch_id
       } end
     + if $completion_digest == "" then {} else {
         completion_digest:$completion_digest
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
    local entry="$1" outcomes_file source temp cutoff protected_receipt_ids
    outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
    [[ ! -L "${outcomes_file}" ]] \
      && { [[ ! -e "${outcomes_file}" ]] || [[ -f "${outcomes_file}" ]]; } \
      || return 1
    omc_causal_completion_outcomes_json_unlocked \
      "${outcomes_file}" >/dev/null || return 1
    source="${outcomes_file}"
    [[ -f "${source}" ]] || source="/dev/null"
    temp="$(mktemp "${outcomes_file}.XXXXXX")" || return 1
    cutoff="$(( $(now_epoch) - 604800 ))"
    protected_receipt_ids="$(
      omc_completion_receipt_protected_lifecycle_ids_unlocked
    )" || {
      rm -f "${temp}" 2>/dev/null || true
      return 1
    }
    # Outcomes are one-shot correlation records, not history. Keep ordinary
    # unconsumed rows for seven days so high fan-out cannot make a late
    # PostToolUse event fall back to history; keep every versioned cleanup WAL
    # until its consumer converges it. Parse once and publish only after the
    # complete staged file exists.
    if ! jq -Rsr \
        --arg entry "${entry}" \
        --argjson protected "${protected_receipt_ids}" \
        --argjson cutoff "${cutoff}" '
          [split("\n")[] | select(length > 0)
            | {raw:.,row:(try fromjson catch null)}] as $parsed
          | (if all($parsed[]; (.row | type) == "object") | not
             then error("invalid completion outcome ledger")
             else [$parsed[]
               | select((.row | has("cleanup_journal_version"))
                        or ((.row.lifecycle_dispatch_id // "") as $id
                          | $id != ""
                            and (($protected | index($id)) != null))
                        or ((.row.ts | type) == "number"
                            and .row.ts >= $cutoff))
               | .raw] end) as $kept
          | ($entry | fromjson) as $new
          | ([$kept[] | fromjson
              | select(($new.lifecycle_dispatch_id // "") != ""
                and (.lifecycle_dispatch_id // "")
                  == ($new.lifecycle_dispatch_id // ""))]) as $same
          | if ($same | length) == 0 then ($kept + [$entry])[]
            # A lifecycle ID is immutable transaction authority. Only its
            # observation clock may differ on replay; silently accepting a
            # different reason, objective generation, findings identity, or
            # cleanup fingerprint would launder a conflicting outcome.
            elif all($same[]; del(.ts) == ($new | del(.ts)))
            then $kept[]
            else error("conflicting lifecycle completion outcome") end
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

# Finish the one narrow split transaction where universal summary effects were
# already committed (effects_complete=true), then the dedicated plan committed
# its exact receipt/start consumption, but the accepted parent outcome had not
# yet been appended. The outcome is published first as the roll-forward journal;
# this locked cleanup only consumes the exact effects-complete row and waiter.
_settle_recovered_plan_parent_outcome_unlocked() {
  local pending_file starts_file waiters_file outcomes_file active_wal
  local lifecycle native agent digest pending_line waiter_line matches outcomes
  active_wal="$(session_file ".plan-txn.active")"
  [[ ! -e "${active_wal}" && ! -L "${active_wal}" ]] || return 1
  pending_file="$(session_file "pending_agents.jsonl")"
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  for _summary_recovery_file in "${pending_file}" "${starts_file}" \
      "${waiters_file}" "${outcomes_file}"; do
    [[ ! -L "${_summary_recovery_file}" ]] \
      && { [[ ! -e "${_summary_recovery_file}" ]] \
        || [[ -f "${_summary_recovery_file}" ]]; } || return 1
  done
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 1
  pending_line="${_summary_pending_json}"
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  agent="$(jq -r '.agent_type // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  digest="$(_summary_plan_completion_digest 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && -n "${agent}" \
      && "${digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && "$(jq -r '.completion_claim_effects_complete // false' \
        <<<"${pending_line}" 2>/dev/null || true)" == "true" ]] || return 1
  if [[ ! "${native}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    [[ -z "${native}" \
        && "$(read_state "native_agent_id_tracking_version" \
          2>/dev/null || true)" != "1" ]] || return 1
  fi
  [[ -s "${pending_file}" && -s "${waiters_file}" \
      && -s "${outcomes_file}" ]] || return 1
  matches="$(jq -Rsr --argjson target "${pending_line}" '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")
      | select(. == $target)] | length
  ' "${pending_file}" 2>/dev/null)" || return 1
  [[ "${matches}" == "1" ]] || return 1
  if [[ -s "${starts_file}" ]]; then
    jq -Rse --arg lifecycle "${lifecycle}" '
      all(split("\n")[] | select(length > 0);
        (fromjson | .lifecycle_dispatch_id // "") != $lifecycle)
    ' "${starts_file}" >/dev/null 2>&1 || return 1
  fi
  waiter_line="$(jq -Rsr \
    --arg lifecycle "${lifecycle}" --arg native "${native}" \
    --arg agent "${agent}" --arg digest "${digest}" '
      [split("\n")[] | select(length > 0) | . as $raw
        | (fromjson) as $row | select(
          $row.lifecycle_dispatch_id == $lifecycle
          and ($row.native_agent_id // "") == $native
          and $row.agent_type == $agent
          and $row.completion_digest == $digest) | $raw] as $matches
      | if ($matches | length) == 1 then $matches[0] else error("waiter") end
    ' "${waiters_file}" 2>/dev/null)" || return 1
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg agent "${agent}" '
    ([$outcomes[] | select(.lifecycle_dispatch_id == $lifecycle
        and (.native_agent_id // "") == $native
        and .agent_type == $agent
        and .status == "accepted")] | length) == 1
  ' >/dev/null 2>&1 || return 1
  _summary_plan_publication_decision_unlocked "${pending_line}" || return 1
  [[ "${_summary_plan_publication_status}" == "accepted" ]] || return 1

  rewrite_jsonl_line_atomic "${pending_file}" "${pending_line}" "" \
    || return 1
  if [[ "${OMC_TEST_PLAN_OUTCOME_RECOVERY_KILL_AFTER_PENDING:-0}" == "1" ]]; then
    kill -9 "$$"
  fi
  rewrite_jsonl_line_atomic "${waiters_file}" "${waiter_line}" "" \
    || return 1
}

# Reviewer summary-first replay uses the accepted parent outcome as a
# roll-forward commit marker. Once that exact lifecycle/digest outcome is
# durable, consume the effects-complete pending row first and its waiter last.
# If death lands between them, receipt+outcome+waiter is sufficient for the
# reviewer recovery entrypoint to finish the cleanup without repeating effects.
_settle_recovered_reviewer_parent_outcome_unlocked() {
  local pending_file starts_file waiters_file outcomes_file active_wal
  local lifecycle native agent digest pending_line waiter_line matches outcomes
  active_wal="$(session_file ".reviewer-transaction.wal")"
  [[ ! -e "${active_wal}" && ! -L "${active_wal}" ]] || return 1
  pending_file="$(session_file "pending_agents.jsonl")"
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  waiters_file="$(session_file "reviewer_summary_waiters.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  for _summary_recovery_file in "${pending_file}" "${starts_file}" \
      "${waiters_file}" "${outcomes_file}"; do
    [[ ! -L "${_summary_recovery_file}" ]] \
      && { [[ ! -e "${_summary_recovery_file}" ]] \
        || [[ -f "${_summary_recovery_file}" ]]; } || return 1
  done
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
  agent="$(jq -r '.agent_type // empty' \
    <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
  digest="$(_summary_reviewer_completion_digest 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && -n "${agent}" \
      && "${digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && -s "${pending_file}" && -s "${waiters_file}" \
      && -s "${outcomes_file}" ]] || return 1
  if [[ ! "${native}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    [[ -z "${native}" \
        && "$(read_state "native_agent_id_tracking_version" \
          2>/dev/null || true)" != "1" ]] || return 1
  fi
  pending_line="$(jq -Rsr \
    --arg lifecycle "${lifecycle}" --arg native "${native}" \
    --arg agent "${agent}" '
      [split("\n")[] | select(length > 0) | . as $raw
        | (try fromjson catch null) as $row
        | select(($row | type) == "object") | select(
          $row.lifecycle_dispatch_id == $lifecycle
          and ($row.native_agent_id // "") == $native
          and $row.agent_type == $agent
          and ($row.completion_claim_effects_complete // false) == true)
        | $raw] as $matches
      | if ($matches | length) == 1 then $matches[0]
        else error("pending") end
    ' "${pending_file}" 2>/dev/null)" || return 1
  if [[ -s "${starts_file}" ]]; then
    jq -Rse --arg lifecycle "${lifecycle}" '
      all(split("\n")[] | select(length > 0);
        (fromjson | .lifecycle_dispatch_id // "") != $lifecycle)
    ' "${starts_file}" >/dev/null 2>&1 || return 1
  fi
  waiter_line="$(jq -Rsr \
    --arg lifecycle "${lifecycle}" --arg native "${native}" \
    --arg agent "${agent}" --arg digest "${digest}" '
      [split("\n")[] | select(length > 0) | . as $raw
        | (fromjson) as $row | select(
          $row.lifecycle_dispatch_id == $lifecycle
          and ($row.native_agent_id // "") == $native
          and $row.agent_type == $agent
          and $row.completion_digest == $digest) | $raw] as $matches
      | if ($matches | length) == 1 then $matches[0]
        else error("waiter") end
    ' "${waiters_file}" 2>/dev/null)" || return 1
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg agent "${agent}" '
    ([$outcomes[] | select(.lifecycle_dispatch_id == $lifecycle
        and (.native_agent_id // "") == $native
        and .agent_type == $agent
        and .status == "accepted")] | length) == 1
  ' >/dev/null 2>&1 || return 1
  _summary_reviewer_publication_decision_unlocked "${pending_line}" || return 1
  [[ "${_summary_reviewer_publication_status}" == "accepted" ]] || return 1

  rewrite_jsonl_line_atomic "${pending_file}" "${pending_line}" "" \
    || return 1
  if [[ "${OMC_TEST_REVIEWER_OUTCOME_RECOVERY_KILL_AFTER_PENDING:-0}" == "1" ]]; then
    kill -9 "$$"
  fi
  rewrite_jsonl_line_atomic "${waiters_file}" "${waiter_line}" "" \
    || return 1
}

_claimed_reviewer_start_exists_unlocked() {
  local row="$1" starts_file line this_type row_id wanted_id
  local row_lifecycle wanted_lifecycle row_native wanted_native matches=0
  local row_cycle wanted_cycle binding_kind="" binding_lifecycle=""
  local binding_review_id="" binding_cycle="" candidate=0
  local row_abandoned wanted_abandoned
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  [[ ! -L "${starts_file}" ]] \
    && { [[ ! -e "${starts_file}" ]] || [[ -f "${starts_file}" ]]; } \
    || return 2
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 2
  [[ -s "${starts_file}" ]] || return 1
  wanted_id="$(jq -r '.review_dispatch_id // empty' <<<"${row}" 2>/dev/null || true)"
  wanted_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${row}" 2>/dev/null || true)"
  wanted_native="$(jq -r '.native_agent_id // empty' \
    <<<"${row}" 2>/dev/null || true)"
  wanted_cycle="$(jq -r '.objective_cycle_id // empty' \
    <<<"${row}" 2>/dev/null || true)"
  wanted_abandoned="$(jq -r '.review_dispatch_abandoned // false' \
    <<<"${row}" 2>/dev/null || true)"
  if [[ "$(read_state "native_agent_id_tracking_version" \
      2>/dev/null || true)" == "1" ]]; then
    [[ -n "${_summary_native_binding_json:-}" ]] || return 2
    binding_kind="$(jq -r '.binding_kind // empty' \
      <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
    [[ "${binding_kind}" == "current" ]] || return 2
    binding_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
    binding_review_id="$(jq -r '.review_dispatch_id // ""' \
      <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
    binding_cycle="$(jq -r '.objective_cycle_id // empty' \
      <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
    [[ "${wanted_native}" == "${_summary_native_agent_id}" \
        && "${wanted_lifecycle}" == "${binding_lifecycle}" \
        && "${wanted_id}" == "${binding_review_id}" \
        && "${wanted_cycle}" == "${binding_cycle}" ]] || return 2
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    row_id="$(jq -r '.review_dispatch_id // empty' <<<"${line}" 2>/dev/null || true)"
    row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_native="$(jq -r '.native_agent_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_cycle="$(jq -r '.objective_cycle_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_abandoned="$(jq -r '.review_dispatch_abandoned // false' \
      <<<"${line}" 2>/dev/null || true)"
    if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
      if [[ -n "${binding_lifecycle}" ]] \
          && { [[ "${line}" == *"${wanted_native}"* ]] \
            || [[ "${line}" == *"${wanted_lifecycle}"* ]] \
            || { [[ -n "${wanted_id}" ]] \
              && [[ "${line}" == *"${wanted_id}"* ]]; }; }; then
        return 2
      fi
      continue
    fi
    candidate=0
    if [[ -n "${binding_lifecycle}" ]] \
        && { [[ "${row_native}" == "${wanted_native}" ]] \
          || [[ "${row_lifecycle}" == "${wanted_lifecycle}" ]] \
          || { [[ -n "${wanted_id}" ]] \
            && [[ "${row_id}" == "${wanted_id}" ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; }; then
      candidate=1
      [[ "${this_type}" == "${AGENT_TYPE}" \
          && "${row_native}" == "${wanted_native}" \
          && "${row_lifecycle}" == "${wanted_lifecycle}" \
          && "${row_id}" == "${wanted_id}" \
          && "${row_cycle}" == "${wanted_cycle}" \
          && "${row_abandoned}" == "${wanted_abandoned}" ]] || return 2
    elif [[ "${row_abandoned}" == "true" ]]; then
      continue
    elif [[ -n "${wanted_lifecycle}" ]]; then
      [[ "${this_type}" == "${AGENT_TYPE}" \
          && "${row_lifecycle}" == "${wanted_lifecycle}" ]] || continue
      [[ -z "${wanted_native}" \
          || "${row_native}" == "${wanted_native}" ]] || continue
      candidate=1
    elif [[ -n "${wanted_id}" ]]; then
      [[ "${row_id}" == "${wanted_id}" \
          && -z "${row_native}" \
          && "${this_type}" == "${AGENT_TYPE}" ]] || continue
      candidate=1
    else
      # Explicit migration path: neither side has lifecycle/native/model ID.
      [[ -z "${row_lifecycle}" && -z "${row_native}" \
          && -z "${row_id}" \
          && "${this_type}" == "${AGENT_TYPE}" ]] || continue
      candidate=1
    fi
    [[ "${candidate}" -eq 0 ]] || matches=$((matches + 1))
  done <"${starts_file}"
  if [[ "${matches}" -eq 1 ]]; then
    return 0
  elif [[ "${matches}" -eq 0 ]]; then
    return 1
  fi
  return 2
}

_settle_accepted_completion_claim_unlocked() {
  local pending_file outcomes_file pending_line lifecycle native agent digest
  local matches starts_file outcomes _summary_claim_file
  if ! { { [[ "${_summary_claim_owned:-0}" -eq 1 ]] \
          || [[ "${_summary_generic_effects_outcome_recovery_required:-0}" -eq 1 ]]; } \
        && [[ -n "${_summary_pending_json:-}" ]]; }; then
    return 0
  fi
  pending_line="${_summary_pending_json}"
  [[ "$(jq -r '.completion_claim_effects_complete // false' \
    <<<"${pending_line}" 2>/dev/null || true)" == "true" ]] || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  agent="$(jq -r '.agent_type // empty' \
    <<<"${pending_line}" 2>/dev/null || true)"
  digest="$(_summary_plan_completion_digest 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && -n "${agent}" \
      && "${digest}" =~ ^[A-Fa-f0-9]{16,128}$ ]] || return 1
  if [[ ! "${native}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    [[ -z "${native}" \
        && "$(read_state "native_agent_id_tracking_version" \
          2>/dev/null || true)" != "1" ]] || return 1
  fi
  pending_file="$(session_file "pending_agents.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  for _summary_claim_file in "${pending_file}" "${outcomes_file}" \
      "${starts_file}"; do
    [[ ! -L "${_summary_claim_file}" ]] \
      && { [[ ! -e "${_summary_claim_file}" ]] \
        || [[ -f "${_summary_claim_file}" ]]; } || return 1
  done
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 1
  [[ -s "${pending_file}" && -s "${outcomes_file}" ]] || return 1
  matches="$(jq -Rsr --argjson target "${pending_line}" '
    [split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")
      | select(. == $target)] | length
  ' "${pending_file}" 2>/dev/null)" || return 1
  [[ "${matches}" == "1" ]] || return 1
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg agent "${agent}" --arg digest "${digest}" '
    ([$outcomes[] | select(.lifecycle_dispatch_id == $lifecycle
        and (.native_agent_id // "") == $native
        and .agent_type == $agent
        and .completion_digest == $digest
        and .status == "accepted")] | length) == 1
  ' >/dev/null 2>&1 || return 1
  # A stateful dedicated hook that has not consumed its exact start still owns
  # the final causal cleanup. Ordinary roles never have a start row.
  local claimed_start_rc=0
  _claimed_reviewer_start_exists_unlocked "${pending_line}" \
    || claimed_start_rc=$?
  if [[ "${claimed_start_rc}" -eq 0 ]]; then
    return 0
  elif [[ "${claimed_start_rc}" -ne 1 ]]; then
    return 1
  fi
  rewrite_jsonl_line_atomic "${pending_file}" "${pending_line}" ""
}

if [[ "${_summary_generic_effects_outcome_recovery_required:-0}" -eq 1 ]]; then
  if ! _record_completion_outcome \
      "accepted" "" "${LAST_ASSISTANT_MESSAGE}" \
      || ! with_state_lock _settle_accepted_completion_claim_unlocked; then
    log_anomaly "record-subagent-summary" \
      "exact duplicate parent outcome recovery failed" \
      2>/dev/null || true
    exit 0
  fi
  exit 0
fi

if [[ "${_summary_plan_effects_outcome_recovery_required:-0}" -eq 1 ]]; then
  if ! _record_completion_outcome \
      "accepted" "" "${LAST_ASSISTANT_MESSAGE}" \
      || ! with_state_lock _settle_recovered_plan_parent_outcome_unlocked; then
    log_anomaly "record-subagent-summary" \
      "receipt-bound planner parent outcome recovery failed" \
      2>/dev/null || true
    exit 0
  fi
  exit 0
fi

if [[ "${_summary_reviewer_effects_outcome_recovery_required:-0}" -eq 1 ]]; then
  if ! _record_completion_outcome \
      "accepted" "" "${LAST_ASSISTANT_MESSAGE}" \
      || ! with_state_lock \
        _settle_recovered_reviewer_parent_outcome_unlocked; then
    log_anomaly "record-subagent-summary" \
      "receipt-bound reviewer parent outcome recovery failed" \
      2>/dev/null || true
    exit 0
  fi
  exit 0
fi

if [[ "${_summary_dispatch_suppressed}" -eq 1 \
    && "${_summary_invalid_contract_replay}" -ne 1 \
    && "${_summary_suppress_outcome:-0}" -ne 1 ]]; then
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
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
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

# Deterministic crash points for proving that an expired ordinary completion
# claim replays each universal effect idempotently. Production leaves the
# selector unset. The durable claim remains the recovery authority.
_summary_test_effect_boundary() {
  local boundary="$1"
  if [[ "${OMC_TEST_SUMMARY_KILL_AFTER_EFFECT:-}" == "${boundary}" ]]; then
    kill -9 "$$"
  fi
}

if [[ "${_summary_dispatch_suppressed}" -ne 1 ]]; then
SUMMARY_MESSAGE_SAFE="$(printf '%s' "${LAST_ASSISTANT_MESSAGE}" | omc_redact_secrets | tr -d '\000')"
_summary_effect_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
  <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
_summary_effect_native="$(jq -r '.native_agent_id // empty' \
  <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
_summary_effect_digest="$(_omc_token_digest "${SUMMARY_MESSAGE_SAFE}")"
_summary_effect_row="$(jq -nc \
  --argjson ts "$(now_epoch)" \
  --arg agent_type "${AGENT_TYPE}" \
  --arg message "${SUMMARY_MESSAGE_SAFE}" \
  --arg lifecycle_dispatch_id "${_summary_effect_lifecycle}" \
  --arg native_agent_id "${_summary_effect_native}" \
  --arg completion_digest "${_summary_effect_digest}" '
    {ts:$ts,agent_type:$agent_type,message:$message}
    + if $lifecycle_dispatch_id == "" then {} else {
        lifecycle_dispatch_id:$lifecycle_dispatch_id,
        native_agent_id:$native_agent_id,
        completion_digest:$completion_digest
      } end
  ')"
_append_subagent_summary_effect_unlocked() {
  local entry="$1" summaries_file source temp lifecycle existing
  summaries_file="$(session_file "subagent_summaries.jsonl")"
  [[ ! -L "${summaries_file}" ]] \
    && { [[ ! -e "${summaries_file}" ]] || [[ -f "${summaries_file}" ]]; } \
    || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' <<<"${entry}")"
  source="${summaries_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  if [[ -n "${lifecycle}" ]]; then
    existing="$(jq -Rsc --arg lifecycle "${lifecycle}" '
      [split("\n")[] | select(length > 0) | fromjson
        | select((.lifecycle_dispatch_id // "") == $lifecycle)]
    ' "${source}" 2>/dev/null)" || return 1
    case "$(jq -r 'length' <<<"${existing}")" in
      0) ;;
      1)
        jq -e --argjson entry "${entry}" '
          (.[0] | del(.ts)) == ($entry | del(.ts))
        ' <<<"${existing}" >/dev/null 2>&1
        return $?
        ;;
      *) return 1 ;;
    esac
  fi
  temp="$(mktemp "${summaries_file}.XXXXXX")" || return 1
  if ! jq -Rsr --arg entry "${entry}" '
      (split("\n") | map(select(length > 0)) + [$entry])[-16:][]
    ' "${source}" >"${temp}" \
      || ! mv -f "${temp}" "${summaries_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
}
with_state_lock _append_subagent_summary_effect_unlocked \
  "${_summary_effect_row}" || exit 1
_summary_test_effect_boundary "summary"

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
_summary_test_effect_boundary "agent-first"

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
_summary_test_effect_boundary "design"

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
    append_discovered_scope "${_agent_short}" "${_scope_rows}" || exit 1
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
      # Current tracked returns use their immutable lifecycle identity. This
      # keeps an expired-claim replay idempotent while preserving distinct
      # placeholders for genuinely separate malformed Council calls. Legacy
      # untracked returns retain the monotonic sequence fallback.
      _scope_contract_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
        <<<"${_summary_pending_json:-}" 2>/dev/null || true)"
      if [[ "${_scope_contract_lifecycle}" \
          =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]]; then
        _scope_contract_event="lifecycle=${_scope_contract_lifecycle}"
      else
        _next_scope_contract_violation_seq() {
          local _seq
          _seq="$(read_state "scope_contract_violation_seq")"
          if [[ -z "${_seq}" ]]; then
            _seq=0
          else
            _omc_canonical_uint_in_range \
              "${_seq}" 0 999999999999998 || return 1
          fi
          _seq=$((_seq + 1))
          _write_state_unlocked \
            "scope_contract_violation_seq" "${_seq}" || return 1
          _scope_contract_seq="${_seq}"
        }
        _scope_contract_seq=0
        if ! with_state_lock _next_scope_contract_violation_seq; then
          log_anomaly "record-subagent-summary" \
            "invalid scope-contract violation sequence authority"
          exit 1
        fi
        _scope_contract_event="event=${_scope_contract_seq}"
      fi
      _scope_contract_id="$(_finding_id "${_agent_short}" \
        "${_scope_contract_summary}|${_scope_contract_event}")"
      _scope_contract_row="$(jq -nc \
        --arg id "${_scope_contract_id}" \
        --arg src "${_agent_short}" \
        --arg sum "${_scope_contract_summary}" \
        --argjson ts "$(now_epoch)" \
        '{id:$id,source:$src,summary:$sum,severity:"medium",status:"pending",reason:"",ts:$ts}')"
      append_discovered_scope \
        "${_agent_short}" "${_scope_contract_row}" || exit 1
      record_gate_event "discovered-scope" "zero_capture" \
        "agent=${_agent_short}" \
        "expected=FINDINGS_JSON" \
        "verdict=${_scope_last_verdict}" || true
  fi
fi
_summary_test_effect_boundary "scope"
fi # accepted or genuinely untracked completion

# Wait for the optional cross-session archetype telemetry before declaring the
# durable completion claim effects-complete. Discovered-scope writes above are
# synchronous and fail closed because they feed a Stop gate; archetype memory
# remains best-effort and is not completion authority.
wait 2>/dev/null || true
_summary_test_effect_boundary "background-waits"

_append_current_council_return_unlocked() {
  local entry="$1" objective_ts="$2" prompt_revision="$3" cycle_id="$4"
  local ledger source output lifecycle existing
  ledger="$(session_file "council_returns.jsonl")"
  [[ ! -L "${ledger}" ]] \
    && { [[ ! -e "${ledger}" ]] || [[ -f "${ledger}" ]]; } || return 1
  source="${ledger}"
  [[ -f "${source}" ]] || source="/dev/null"
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${entry}" 2>/dev/null || true)"
  if [[ -n "${lifecycle}" ]]; then
    existing="$(jq -Rsc --arg lifecycle "${lifecycle}" '
      [split("\n")[] | select(length > 0) | fromjson
        | select((.lifecycle_dispatch_id // "") == $lifecycle)]
    ' "${source}" 2>/dev/null)" || return 1
    case "$(jq -r 'length' <<<"${existing}")" in
      0) ;;
      1)
        # `ts` is the observation clock. Recovery of the same lifecycle may
        # run later, so compare only immutable Council provenance.
        jq -e --argjson entry "${entry}" '
          (.[0] | del(.ts)) == ($entry | del(.ts))
        ' <<<"${existing}" >/dev/null 2>&1
        return $?
        ;;
      *) return 1 ;;
    esac
  fi
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
  local completion_native_id="" native_tracking_version=""
  local completion_identity_valid=0
  local cleanup_starts_backup="" cleanup_starts_changed=0
  local cleanup_starts_committed=0 cleanup_pending_fingerprint=""
  local cleanup_start_fingerprint=""
  local cleanup_lifecycle_dispatch_id="" cleanup_journal_version=1
  local starts_file="" starts_temp=""
  local cleanup_binding_lifecycle="" cleanup_binding_review_id=""
  local outcomes_file="" outcomes_source="" outcomes_temp=""
  local outcomes_changed=0 protected_receipt_ids='[]'
  pending_file="$(session_file "pending_agents.jsonl")"
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
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
    local start_lifecycle_id start_candidate=0
    local wanted_type wanted_native_id wanted_dispatch_id start_removed=0
    local start_match_count=0
    starts_file="$(session_file "agent_dispatch_starts.jsonl")"
    omc_dispatch_authority_ledger_shell_safe "${starts_file}" || {
      rm -f "${temp_file}"
      return 1
    }
    wanted_type="$(jq -r '.agent_type // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    wanted_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    wanted_dispatch_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    if [[ "$(read_state "native_agent_id_tracking_version" \
        2>/dev/null || true)" == "1" ]]; then
      [[ "$(jq -r '.binding_kind // empty' \
        <<<"${_summary_native_binding_json:-}" 2>/dev/null || true)" \
          == "current" ]] || {
        rm -f "${temp_file}"
        return 1
      }
      cleanup_binding_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
        <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
      cleanup_binding_review_id="$(jq -r '.review_dispatch_id // ""' \
        <<<"${_summary_native_binding_json}" 2>/dev/null || true)"
      [[ "${cleanup_binding_lifecycle}" == \
          "${cleanup_lifecycle_dispatch_id}" \
          && "${cleanup_binding_review_id}" == "${wanted_dispatch_id}" ]] || {
        rm -f "${temp_file}"
        return 1
      }
    fi
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
        if ! jq -e 'type == "object"' \
            <<<"${start_line}" >/dev/null 2>&1; then
          if [[ -n "${cleanup_binding_lifecycle}" ]] \
              && { [[ "${start_line}" == *"${wanted_native_id}"* ]] \
                || [[ "${start_line}" == \
                      *"${cleanup_binding_lifecycle}"* ]] \
                || { [[ -n "${cleanup_binding_review_id}" ]] \
                  && [[ "${start_line}" == \
                        *"${cleanup_binding_review_id}"* ]]; }; }; then
            rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
            return 1
          fi
          printf '%s\n' "${start_line}" >>"${starts_temp}" || {
            rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
            return 1
          }
          continue
        fi
        start_type="$(jq -r '.agent_type // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_dispatch_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_lifecycle_id="$(jq -r '.lifecycle_dispatch_id // empty' \
          <<<"${start_line}" 2>/dev/null || true)"
        start_candidate=0
        if [[ -n "${cleanup_binding_lifecycle}" ]] \
            && { [[ "${start_native_id}" == "${wanted_native_id}" ]] \
              || [[ "${start_lifecycle_id}" == \
                    "${cleanup_binding_lifecycle}" ]] \
              || { [[ -n "${cleanup_binding_review_id}" ]] \
                && [[ "${start_dispatch_id}" == \
                      "${cleanup_binding_review_id}" ]] \
                && [[ "${start_type}" == "${wanted_type}" ]]; }; }; then
          start_candidate=1
        elif [[ -z "${cleanup_binding_lifecycle}" \
            && "${start_type}" == "${wanted_type}" ]]; then
          start_candidate=1
        fi
        if [[ "${start_candidate}" -eq 1 ]]; then
          if ! jq -e --argjson target "${matched_pending_json}" '
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
            rm -f "${starts_temp}" "${cleanup_starts_backup}" "${temp_file}"
            return 1
          fi
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
          "model_uncertainty_deliberator_cycle_id" "${current_cycle_id}" \
          || return 1
        _summary_test_effect_boundary "uncertainty"
      fi
    fi

    if [[ -n "${_current_council_pending_json}" ]]; then
      local return_row return_lifecycle return_ts
      local council_contract_valid=false return_native_agent_id=""
      [[ "${_summary_valid_universal_verdict}" -eq 1 ]] \
        && council_contract_valid=true
      [[ "${_summary_use_native_agent_id:-0}" -eq 1 ]] \
        && return_native_agent_id="${_summary_native_agent_id}"
      return_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
        <<<"${_current_council_pending_json}")" || {
        rm -f "${temp_file}"
        return 1
      }
      return_ts="$(now_epoch)" || {
        rm -f "${temp_file}"
        return 1
      }
      [[ "${return_ts}" =~ ^[0-9]+$ ]] || {
        rm -f "${temp_file}"
        return 1
      }
      return_row="$(jq -c \
        --arg actual_agent "${AGENT_TYPE}" \
        --arg native_agent_id "${return_native_agent_id}" \
        --arg lifecycle_dispatch_id "${return_lifecycle}" \
        --argjson returned_ts "${return_ts}" \
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
          + if $lifecycle_dispatch_id == "" then {} else {
              lifecycle_dispatch_id:$lifecycle_dispatch_id
            } end
          + if $native_agent_id == "" then {} else {
              native_agent_id:$native_agent_id
            } end
        ' <<<"${_current_council_pending_json}")" || {
        rm -f "${temp_file}"
        return 1
      }
      local return_objective_ts return_prompt_revision return_cycle_id
      return_objective_ts="$(jq -r '.objective_prompt_ts // 0' \
        <<<"${return_row}")" || {
        rm -f "${temp_file}"
        return 1
      }
      return_prompt_revision="$(jq -r '.objective_prompt_revision // 0' \
        <<<"${return_row}")" || {
        rm -f "${temp_file}"
        return 1
      }
      return_cycle_id="$(jq -r '.objective_cycle_id // 0' \
        <<<"${return_row}")" || {
        rm -f "${temp_file}"
        return 1
      }
      [[ "${return_objective_ts}" =~ ^[0-9]+$ \
          && "${return_prompt_revision}" =~ ^[0-9]+$ \
          && "${return_cycle_id}" =~ ^[0-9]+$ ]] || {
        rm -f "${temp_file}"
        return 1
      }
      if ! _append_current_council_return_unlocked "${return_row}" \
          "${return_objective_ts}" "${return_prompt_revision}" \
          "${return_cycle_id}"; then
        rm -f "${temp_file}"
        return 1
      fi
      _summary_test_effect_boundary "council"
    fi

    if [[ "$(jq -r '.review_dispatch_causality_version // 0' \
        <<<"${matched_pending_json}" 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]]; then
      local claimed_start_rc=0
      _claimed_reviewer_start_exists_unlocked "${matched_pending_json}" \
        || claimed_start_rc=$?
      if [[ "${claimed_start_rc}" -eq 0 ]]; then
        keep_claim=1
      elif [[ "${claimed_start_rc}" -ne 1 ]]; then
        rm -f "${temp_file}"
        return 1
      fi
    fi
    # Every accepted tracked completion keeps its exact claim until the
    # accepted parent outcome is durable. Besides closing the owner-validity
    # gap for ordinary specialists, this makes the outcome the roll-forward
    # marker if the process dies after any summary effect. Stateful roles with
    # a still-live dedicated start remain retained until that hook converges.
    completion_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${matched_pending_json}" 2>/dev/null || true)"
    native_tracking_version="$(read_state \
      "native_agent_id_tracking_version" 2>/dev/null || true)"
    if [[ "${completion_native_id}" \
          =~ ^[A-Za-z0-9._:-]{1,128}$ ]] \
        || { [[ -z "${completion_native_id}" ]] \
          && [[ "${native_tracking_version}" != "1" ]]; }; then
      completion_identity_valid=1
    fi
    if [[ "${_summary_claim_owned:-0}" -eq 1 \
        && "${_summary_dispatch_suppressed:-1}" -ne 1 \
        && "$(jq -r '.lifecycle_dispatch_id // empty' \
          <<<"${matched_pending_json}" 2>/dev/null || true)" \
          =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
        && "${completion_identity_valid}" -eq 1 ]]; then
      keep_claim=1
    fi
    # Both reviewer hook orders now retain an exact waiter. Once the dedicated
    # reviewer has consumed its start, retain an effects-complete pending row
    # across the separate accepted-outcome publication so a crash has a
    # durable, receipt-bound repair handle rather than orphaning the waiter.
    if [[ "${_summary_has_dedicated_reviewer:-0}" -eq 1 \
        && "${_summary_reviewer_publication_status:-}" == "accepted" ]]; then
      keep_claim=1
    fi
    # Planner completion uses the same outcome-last split as reviewer
    # completion.  Every accepted planner decision now has an exact waiter,
    # so retain the claimed row as effects-complete until the accepted parent
    # outcome is durable; receipt + waiter + pending is then sufficient to
    # repair either natural hook order without repeating summary side effects.
    if [[ "${_summary_enforced_contract_kind:-}" == "planner" \
        && "${_summary_plan_publication_status:-}" == "accepted" ]]; then
      keep_claim=1
    fi
    if [[ "${keep_claim}" -eq 1 ]]; then
      if [[ "${OMC_TEST_SUMMARY_FAIL_BEFORE_EFFECTS_COMPLETE:-0}" == "1" ]]; then
        rm -f "${temp_file}"
        return 1
      fi
      updated="$(jq -c '.completion_claim_effects_complete = true' \
        <<<"${matched_pending_json}")" || return 1
      printf '%s\n' "${updated}" >>"${temp_file}" || return 1
      # The outcome/settlement phase runs after this locked finalizer. Keep its
      # exact in-process handle synchronized with the durable effects-complete
      # row; otherwise summary-first replay compares the old `false` claim to
      # the newly written row and can never consume its waiter or pending row.
      _summary_pending_json="${updated}"
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
    if ! omc_causal_completion_outcomes_json_unlocked \
        "${outcomes_file}" >/dev/null; then
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
    protected_receipt_ids="$(
      omc_completion_receipt_protected_lifecycle_ids_unlocked
    )" || {
      rm -f "${outcomes_temp}" "${starts_temp}" \
        "${cleanup_starts_backup}" "${temp_file}" 2>/dev/null || true
      return 1
    }
    if ! jq -Rsr --arg entry "${_summary_deferred_outcome_row}" \
        --argjson protected "${protected_receipt_ids}" \
        --argjson cutoff "$(( $(now_epoch) - 604800 ))" '
          [split("\n")[] | select(length > 0)
            | {raw:.,row:(try fromjson catch null)}] as $parsed
          | if all($parsed[]; (.row | type) == "object") | not
            then error("invalid completion outcome ledger")
            else ([$parsed[]
              | select((.row | has("cleanup_journal_version"))
                       or ((.row.lifecycle_dispatch_id // "") as $id
                         | $id != ""
                           and (($protected | index($id)) != null))
                       or ((.row.ts | type) == "number"
                           and .row.ts >= $cutoff))
              | .raw] + [$entry])[] end
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

_expire_failed_summary_claim_unlocked() {
  local pending_file line claim matches=0 selected="" updated now
  [[ "${_summary_claim_owned:-0}" -eq 1 \
      && -n "${_summary_completion_claim_id:-}" ]] || return 0
  pending_file="$(session_file "pending_agents.jsonl")"
  [[ -f "${pending_file}" && ! -L "${pending_file}" ]] || return 1
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    if [[ "${claim}" == "${_summary_completion_claim_id}" ]]; then
      matches=$((matches + 1))
      selected="${line}"
    fi
  done <"${pending_file}"
  [[ "${matches}" -eq 1 ]] || return 1
  [[ "$(jq -r '.completion_claim_effects_complete // false' \
    <<<"${selected}" 2>/dev/null || true)" != "true" ]] || return 1
  now="$(now_epoch)" || return 1
  [[ "${now}" =~ ^[0-9]+$ ]] || return 1
  # The current publisher has returned from its failed finalizer, so its
  # 120-second live-owner lease no longer reflects reality. Expire only this
  # exact claim and retain its redacted digest/message; the next publication
  # barrier can immediately replay the lifecycle without duplicating effects.
  updated="$(jq -c --argjson failed_at "${now}" '
      .completion_claim_ts = 0
      | .completion_finalize_failed_at = $failed_at
    ' <<<"${selected}")" || return 1
  rewrite_jsonl_line_atomic "${pending_file}" "${selected}" "${updated}" \
    || return 1
  _summary_pending_json="${updated}"
}

_settle_plan_summary_waiter_unlocked() {
  local lifecycle_dispatch_id waiters_file pending_file outcomes_file
  local waiter matches outcomes
  [[ "${_summary_enforced_contract_kind}" == "planner" \
      && -n "${_summary_pending_json:-}" ]] || return 0
  lifecycle_dispatch_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_summary_pending_json}" 2>/dev/null || true)"
  [[ "${lifecycle_dispatch_id}" \
      =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]] || return 0
  waiters_file="$(session_file "plan_summary_waiters.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  [[ ! -L "${waiters_file}" && -f "${waiters_file}" ]] || return 0
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  if [[ -s "${pending_file}" ]] \
      && jq -Rse --arg lifecycle "${lifecycle_dispatch_id}" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {})
          | (.lifecycle_dispatch_id // "") == $lifecycle)
      ' "${pending_file}" >/dev/null 2>&1; then
    return 0
  fi
  [[ -s "${outcomes_file}" ]] || return 0
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle_dispatch_id}" '
    any($outcomes[];
      (.lifecycle_dispatch_id // "") == $lifecycle
      and ((.status // "") | IN("accepted", "ignored")))
  ' >/dev/null 2>&1 || return 0
  matches="$(jq -Rsr --arg lifecycle "${lifecycle_dispatch_id}" '
    [split("\n")[] | select(length > 0)
      | . as $raw | (try fromjson catch {}) as $row
      | select(($row.lifecycle_dispatch_id // "") == $lifecycle)
      | $raw] | length
  ' "${waiters_file}" 2>/dev/null)" || return 1
  [[ "${matches}" == "0" ]] && return 0
  [[ "${matches}" == "1" ]] || return 1
  waiter="$(jq -Rsr --arg lifecycle "${lifecycle_dispatch_id}" '
    [split("\n")[] | select(length > 0)
      | . as $raw | (try fromjson catch {}) as $row
      | select(($row.lifecycle_dispatch_id // "") == $lifecycle)
      | $raw][0]
  ' "${waiters_file}")" || return 1
  [[ -n "${waiter}" ]] || return 1
  rewrite_jsonl_line_atomic "${waiters_file}" "${waiter}" "" || return 1
}

_settle_reviewer_summary_waiter_unlocked() {
  local lifecycle waiters_file pending_file outcomes_file waiter matches outcomes
  [[ -n "${_summary_pending_json:-}" ]] || return 0
  if ! _summary_reviewer_current_revision "${AGENT_TYPE}" >/dev/null 2>&1; then
    return 0
  fi
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_summary_pending_json}" 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ ]] || return 0
  waiters_file="$(session_file "reviewer_summary_waiters.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  [[ ! -L "${waiters_file}" && -f "${waiters_file}" ]] || return 0
  omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
  if [[ -s "${pending_file}" ]] \
      && jq -Rse --arg lifecycle "${lifecycle}" '
        any(split("\n")[] | select(length > 0);
          (try fromjson catch {})
          | (.lifecycle_dispatch_id // "") == $lifecycle)
      ' "${pending_file}" >/dev/null 2>&1; then
    return 0
  fi
  [[ -s "${outcomes_file}" ]] || return 0
  outcomes="$(omc_causal_completion_outcomes_json_unlocked \
    "${outcomes_file}")" || return 1
  jq -e -n --argjson outcomes "${outcomes}" \
      --arg lifecycle "${lifecycle}" '
    any($outcomes[];
      (.lifecycle_dispatch_id // "") == $lifecycle
      and ((.status // "") | IN("accepted","ignored")))
  ' >/dev/null 2>&1 || return 0
  matches="$(jq -Rsr --arg lifecycle "${lifecycle}" '
    [split("\n")[] | select(length > 0)
      | . as $raw | (try fromjson catch {}) as $row
      | select(($row.lifecycle_dispatch_id // "") == $lifecycle)
      | $raw] | length
  ' "${waiters_file}" 2>/dev/null)" || return 1
  [[ "${matches}" == "0" ]] && return 0
  [[ "${matches}" == "1" ]] || return 1
  waiter="$(jq -Rsr --arg lifecycle "${lifecycle}" '
    [split("\n")[] | select(length > 0)
      | . as $raw | (try fromjson catch {}) as $row
      | select(($row.lifecycle_dispatch_id // "") == $lifecycle)
      | $raw][0]
  ' "${waiters_file}")" || return 1
  [[ -n "${waiter}" ]] || return 1
  rewrite_jsonl_line_atomic "${waiters_file}" "${waiter}" "" || return 1
}
_summary_finalize_rc=0
_with_summary_finalize_lock() {
  if [[ "${_summary_dispatch_suppressed:-1}" -eq 1 \
      && "${_summary_cleanup_allowed:-0}" -ne 1 \
      && "${_summary_claim_owned:-0}" -ne 1 ]]; then
    # No cleanup/effects are authorized, so the finalizer is a no-op. Do not
    # acquire the ordinary lock merely to return: an invalid replay pair is
    # intentionally still fenced and would otherwise redispatch itself.
    return 0
  elif [[ "${_summary_recovery_admitted:-0}" -eq 1 \
      && "${_summary_dispatch_suppressed:-1}" -eq 1 \
      && "${_summary_cleanup_allowed:-0}" -eq 1 \
      && "${_summary_claim_owned:-0}" -ne 1 ]]; then
    with_state_lock_publication_recovery \
      _finalize_summary_completion_unlocked
  else
    with_state_lock _finalize_summary_completion_unlocked
  fi
}
_with_summary_waiter_settlement_lock() {
  local callback="${1:-}"
  if [[ "${_summary_recovery_admitted:-0}" -eq 1 \
      && "${_summary_dispatch_suppressed:-1}" -eq 1 \
      && "${_summary_cleanup_allowed:-0}" -eq 1 ]]; then
    with_state_lock_publication_recovery "${callback}"
  else
    with_state_lock "${callback}"
  fi
}
_with_summary_finalize_lock \
  || _summary_finalize_rc=$?
if [[ "${_summary_finalize_rc}" -eq 0 \
    && "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" == "1" \
    && "${_summary_reviewer_publication_status:-}" == "accepted" \
    && "${OMC_TEST_REVIEWER_SUMMARY_KILL_AFTER_FINALIZE:-0}" == "1" ]]; then
  kill -9 "$$"
fi
if [[ "${_summary_finalize_rc}" -eq 0 \
    && "${_summary_enforced_contract_kind:-}" == "planner" \
    && "${_summary_plan_publication_status:-}" == "accepted" \
    && "${OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE:-0}" == "1" ]]; then
  kill -9 "$$"
fi
if [[ "${_summary_finalize_rc}" -eq 0 \
    && "${_summary_claim_owned:-0}" -eq 1 \
    && "${OMC_TEST_SUMMARY_KILL_AFTER_FINALIZE:-0}" == "1" ]]; then
  kill -9 "$$"
fi
_summary_accepted_outcome_rc=0
if [[ "${_summary_dispatch_suppressed}" -ne 1 ]]; then
  if [[ "${_summary_finalize_rc}" -eq 0 ]]; then
    _record_completion_outcome "accepted" "" "${LAST_ASSISTANT_MESSAGE}" \
      || _summary_accepted_outcome_rc=$?
  else
    record_gate_event "subagent-summary" "completion-finalize-failed" \
      "agent=${AGENT_TYPE}" "rc=${_summary_finalize_rc}" 2>/dev/null || true
    # A failed accepted-finalizer is recoverable publication work, not a
    # terminal ignored completion. Publishing an ignored lifecycle outcome
    # here poisons the later exact replay because accepted and ignored are
    # conflicting immutable decisions. Retain the claim, expire its owner
    # lease now that this publisher is returning, and let the next barrier
    # replay the stored exact message/digest immediately.
    with_state_lock _expire_failed_summary_claim_unlocked \
      || record_gate_event "subagent-summary" \
        "completion-finalize-expiry-failed" \
        "agent=${AGENT_TYPE}" 2>/dev/null || true
  fi
fi
if [[ "${_summary_finalize_rc}" -eq 0 \
    && "${_summary_dispatch_suppressed}" -eq 1 \
    && "${_summary_cleanup_allowed:-0}" -eq 1 ]]; then
  # Cleanup-only replay has no accepted claim to settle. Retire only the exact
  # waiter after its ignored parent outcome and causal-row cleanup committed.
  # The same one-use recovery capability avoids recursively redispatching this
  # replay while the now-settled receipt pair is still present.
  _with_summary_waiter_settlement_lock \
    _settle_plan_summary_waiter_unlocked || true
  _with_summary_waiter_settlement_lock \
    _settle_reviewer_summary_waiter_unlocked || true
elif [[ "${_summary_finalize_rc}" -eq 0 \
    && "${_summary_dispatch_suppressed}" -ne 1 ]]; then
  if [[ "${_summary_enforced_contract_kind:-}" == "planner" \
      && "${_summary_plan_publication_status:-}" == "accepted" \
      && "${_summary_accepted_outcome_rc}" -eq 0 ]]; then
    with_state_lock _settle_recovered_plan_parent_outcome_unlocked \
      || true
  elif [[ "${_summary_has_dedicated_reviewer:-0}" -eq 1 \
      && "${_summary_reviewer_publication_status:-}" == "accepted" \
      && "${_summary_accepted_outcome_rc}" -eq 0 ]]; then
    # Reviewer settlement below consumes pending + waiter in that exact order.
    # Generic settlement here would remove pending first, destroying the
    # receipt-bound handle the reviewer waiter cleanup requires.
    :
  else
    with_state_lock _settle_accepted_completion_claim_unlocked || true
    with_state_lock _settle_plan_summary_waiter_unlocked || true
  fi
  if [[ "${_summary_has_dedicated_reviewer:-0}" -eq 1 \
      && "${_summary_reviewer_publication_status:-}" == "accepted" \
      && "${_summary_accepted_outcome_rc}" -eq 0 ]]; then
    with_state_lock _settle_recovered_reviewer_parent_outcome_unlocked \
      || true
  else
    with_state_lock _settle_accepted_completion_claim_unlocked || true
    with_state_lock _settle_reviewer_summary_waiter_unlocked || true
  fi
fi
