#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): no classifier or timing-lib dependency — opt out
# of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

# REVIEWER_TYPE controls which dimension (if any) this reviewer ticks.
# Values:
#   standard       — quality-reviewer, superpowers/feature-dev code-reviewer
#                    → ticks bug_hunt, code_quality on clean reviews
#   excellence     — excellence-reviewer
#                    → ticks completeness (bug_hunt stays owned by quality-reviewer)
#                    → also sets last_excellence_review_ts
#                    → does NOT overwrite review_had_findings (independent gate)
#   prose          — editor-critic
#                    → ticks prose, sets last_doc_review_ts
#   stress_test    — metis
#                    → ticks stress_test
#   traceability   — briefing-analyst
#                    → ticks traceability
#   design_quality — design-reviewer
#                    → ticks design_quality
#   release        — release-reviewer
#                    → records release-specific state only; does NOT tick
#                      normal review dimensions or reset quality gates
REVIEWER_TYPE="${1:-standard}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
AGENT_TYPE="$(json_get '.agent_type')"
_review_native_agent_id_raw="$(json_get '.agent_id')"
_review_native_agent_id=""
_review_native_agent_id_present=0
_review_native_agent_id_invalid=0
if [[ -n "${_review_native_agent_id_raw}" ]]; then
  _review_native_agent_id_present=1
  if [[ "${_review_native_agent_id_raw}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    _review_native_agent_id="${_review_native_agent_id_raw}"
  else
    _review_native_agent_id_invalid=1
  fi
fi

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi
capture_ulw_enforcement_interval || exit 0

review_message="$(json_get '.last_assistant_message')"

if [[ -z "${AGENT_TYPE}" ]]; then
  case "${REVIEWER_TYPE}" in
    excellence) AGENT_TYPE="excellence-reviewer" ;;
    prose) AGENT_TYPE="editor-critic" ;;
    stress_test) AGENT_TYPE="metis" ;;
    traceability) AGENT_TYPE="briefing-analyst" ;;
    design_quality) AGENT_TYPE="design-reviewer" ;;
    release) AGENT_TYPE="release-reviewer" ;;
    *) AGENT_TYPE="quality-reviewer" ;;
  esac
fi

# Native agent_id is authoritative on current Claude Code. The echoed binding
# below is retained only for unversioned/older clients and is accepted at the
# trusted structural tail immediately before the final reviewer VERDICT.
_review_dispatch_id=""
if [[ -n "${review_message}" ]]; then
  _review_tail="$(printf '%s\n' "${review_message}" \
    | tr -d '\r' \
    | awk 'NF { previous = current; current = $0 }
           END { print previous; print current }')"
  _review_id_line="$(printf '%s\n' "${_review_tail}" | sed -n '1p')"
  _review_final_line="$(printf '%s\n' "${_review_tail}" | sed -n '2p')"
  if [[ "${_review_id_line}" =~ ^REVIEW_DISPATCH_ID:[[:space:]]*([A-Za-z0-9][A-Za-z0-9._-]{0,63})[[:space:]]*$ ]] \
      && [[ "${_review_final_line}" =~ ^VERDICT:[[:space:]]*(CLEAN|SHIP|FINDINGS([[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\))?|BLOCK([[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\))?)[[:space:]]*$ ]]; then
    _review_dispatch_id="${BASH_REMATCH[1]}"
    # The second regex overwrites BASH_REMATCH, so recover the ID from its
    # already-validated line rather than relying on capture state.
    _review_dispatch_id="${_review_id_line#REVIEW_DISPATCH_ID:}"
    _review_dispatch_id="$(printf '%s' "${_review_dispatch_id}" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
fi

# --- VERDICT parsing (structured contract with regex fallback) ---
#
# Reviewers emit a final line of the form `VERDICT: CLEAN|SHIP|FINDINGS|BLOCK`
# (with a count on FINDINGS/BLOCK). When present, the VERDICT line is
# authoritative. Only untracked migration sessions may fall through to the
# legacy phrase-based regex; current tracked calls are continued by the
# universal SubagentStop hook and must leave both causal ledgers untouched.
#
# The VERDICT line must be the LAST `VERDICT:` line in the message and must
# not be a quoted excerpt (leading `>` or whitespace indentation rules it out,
# matching the convention that agents emit it as their final unindented line).
# `VERDICT: FINDINGS (0)` is treated as CLEAN — zero findings is clean work.

verdict_token=""
verdict_line=""
_review_any_verdict=0
if [[ -n "${review_message}" ]]; then
  printf '%s\n' "${review_message}" | grep -Eq '^VERDICT:' \
    && _review_any_verdict=1
  if [[ "${_review_final_line:-}" =~ ^VERDICT:[[:space:]]*(CLEAN|SHIP|FINDINGS([[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\))?|BLOCK([[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\))?)[[:space:]]*$ ]]; then
    verdict_line="${_review_final_line}"
    verdict_token="$(printf '%s' "${verdict_line}" \
      | sed -E 's/^VERDICT:[[:space:]]*([A-Z]+).*/\1/')"
    # Handle the `FINDINGS (0)` edge case as clean.
    if [[ "${verdict_token}" == "FINDINGS" ]] \
        && printf '%s' "${verdict_line}" | grep -Eq '\([[:space:]]*0[[:space:]]*\)'; then
      verdict_token="CLEAN"
    fi
  fi
fi

# Matching SubagentStop hooks run in parallel. In current tracked sessions the
# universal hook owns the continuation response, while this role-specific hook
# must remain silent and, critically, must not consume its start snapshot or
# stamp a partial review as findings. A later valid return from the same native
# call will traverse the normal commit path below. Pre-tracking sessions retain
# the explicit phrase-fallback migration behavior. Third-party code-reviewer
# integrations keep their own output contracts and therefore also retain the
# phrase parser under causal identity/generation checks.
_review_enforced_contract_kind="$(omc_enforced_terminal_contract_kind \
  "${AGENT_TYPE}" 2>/dev/null || true)"
if [[ -n "${_review_enforced_contract_kind}" ]] \
    && ! omc_enforced_terminal_verdict_valid \
    "${AGENT_TYPE}" "${_review_final_line:-}" \
    && { [[ "$(read_state "review_dispatch_tracking_version")" == "1" ]] \
      || [[ "$(read_state "native_agent_id_tracking_version")" == "1" ]]; }; then
  exit 0
fi

# Excellence is the independent evidence authority for an armed Definition of
# Excellent. Validate its complete structural review against the current
# frozen contract before consuming any causal row. The universal SubagentStop
# hook supplies bounded continuation feedback in either hook order.
_review_quality_required="$(read_state "quality_contract_required" 2>/dev/null || true)"
_review_quality_payload=""
_review_quality_contract=""
_quality_review_receipt_failure=""
_quality_review_frontier_event=""
_quality_review_frontier_contract_id=""
_quality_review_frontier_contract_revision=""
_quality_review_frontier_cycle=""
_quality_review_frontier_status=""
_quality_review_frontier_materiality=""
if [[ "${REVIEWER_TYPE}" == "excellence" \
    && "${_review_quality_required}" == "1" ]]; then
  if ! _omc_load_quality_contract 2>/dev/null \
    || ! _review_quality_contract="$(quality_contract_validate_current 2>/dev/null)" \
    || ! _review_quality_payload="$(quality_review_extract_json \
      "${review_message}" 2>/dev/null)" \
    || ! quality_review_validate_against_contract \
      "${_review_quality_payload}" "${_review_quality_contract}" \
      "${_review_final_line:-}" 2>/dev/null; then
    record_gate_event "definition-of-excellent/review" "invalid-review" \
      "agent=${AGENT_TYPE}" "reason=missing-stale-or-contradictory-envelope" 2>/dev/null || true
    exit 0
  fi
fi

has_findings=""
case "${verdict_token}" in
  CLEAN|SHIP)
    has_findings="false" ;;
  FINDINGS|BLOCK)
    has_findings="true" ;;
  *)
    has_findings="" ;;  # no VERDICT line → fall through to legacy regex
esac

if [[ -z "${has_findings}" && "${_review_any_verdict}" -eq 1 ]]; then
  # A malformed/non-final structured token is not legacy prose. Fail closed
  # instead of letting a preceding "looks clean" phrase authenticate a suffix.
  has_findings="true"
elif [[ -z "${has_findings}" ]]; then
  # Legacy phrase-based detection. Conservative: assume findings unless the
  # summary explicitly says clean. Preserves the exact behavior tested by
  # tests/test-quality-gates.sh §"Review findings detection".
  has_findings="true"
  if [[ -n "${review_message}" ]]; then
    if printf '%s' "${review_message}" \
      | grep -Eiq '\b(no (significant |major |critical |high.severity )?issues|looks (good|clean|solid)|well[- ]implemented|no findings|no defects|passes review|code is correct)\b'; then
      if printf '%s' "${review_message}" \
        | grep -Eiq '\b(but|however|though|although)\b.*\b(issue|concern|finding|problem|bug|regression|defect|risk)\b'; then
        has_findings="true"
      else
        has_findings="false"
      fi
    fi
  fi
fi

review_format_issue=""
if [[ "${_review_any_verdict}" -eq 1 && -z "${verdict_token}" ]]; then
  review_format_issue="invalid_verdict_position"
elif [[ -z "${verdict_token}" ]]; then
  review_format_issue="missing_verdict"
fi
if [[ "${REVIEWER_TYPE}" != "prose" && "${has_findings}" == "true" && -n "${review_message}" ]]; then
  review_json_probe="$(extract_findings_json "${review_message}" 2>/dev/null | head -n 1 || true)"
  if [[ -z "${review_json_probe}" ]]; then
    if [[ -n "${review_format_issue}" ]]; then
      review_format_issue="${review_format_issue},missing_findings_json"
    else
      review_format_issue="missing_findings_json"
    fi
  fi
fi

# In zero-steering / high-risk work, structured reviewer format failures are
# themselves actionable. The legacy prose fallback remains available for
# balanced low-risk work, but strict autonomous shipping should not mark a
# dimension clean from an ambiguous reviewer transcript.
if [[ -n "${review_format_issue}" ]]; then
  # v1.39.0 W2: session-derived risk (was prompt-time-only). A reviewer
  # that returned high-severity findings escalates the work to high
  # regardless of opening-sentence keywords.
  if is_zero_steering_policy_enabled || is_high_session_risk; then
    has_findings="true"
  fi
fi

# --- State writes and dimension ticking ---

now_ts="$(now_epoch)"

# Consume the dispatch-generation snapshot for this reviewer. Current
# SubagentStop payloads carry the platform-issued agent_id bound atomically by
# SubagentStart; that native identity is authoritative. Duplicate in-flight
# instances of the same gate-reviewer role remain denied before launch. An
# explicit review-rebind ID is retained for confirmed-interruption recovery and
# pre-native compatibility, while a late native return stays bound to its exact
# abandoned row. Distinct roles may still run in parallel, and this separate
# reviewer-only ledger survives record-subagent-summary removing pending_agents
# in parallel.
REVIEW_DISPATCH_CAUSALITY_VERSION=1

_consume_reviewer_dispatch_start_unlocked() {
  local starts_file tmp line this_type row_id row_native_id selected=""
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  _review_dispatch_start_json=""
  _review_use_native_agent_id=0
  _review_native_binding_committed=0
  _review_native_tracking_version="$(read_state "native_agent_id_tracking_version")"
  [[ "${_review_native_agent_id_invalid}" -eq 0 ]] || return 0
  if [[ "${_review_native_agent_id_present}" -eq 1 \
      && "${_review_native_agent_id_invalid}" -eq 0 ]]; then
    local bindings_file
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && jq -Rse --arg id "${_review_native_agent_id}" \
          --arg type "${AGENT_TYPE}" '
            [split("\n")[] | select(length > 0)
                | (try fromjson catch {})
                | select((.native_agent_id // "") == $id
                  and (.agent_type // "") == $type)] | length > 0
          ' "${bindings_file}" >/dev/null 2>&1; then
      _review_native_binding_committed=1
    fi
  fi
  if [[ "${_review_native_tracking_version}" == "1" ]]; then
    [[ "${_review_native_agent_id_present}" -eq 1 \
        && "${_review_native_agent_id_invalid}" -eq 0 \
        && "${_review_native_binding_committed}" -eq 1 ]] || return 0
    _review_use_native_agent_id=1
  elif [[ "${_review_native_binding_committed}" -eq 1 ]]; then
    _review_use_native_agent_id=1
  fi
  [[ -f "${starts_file}" ]] || return 0
  tmp="$(mktemp "${starts_file}.XXXXXX")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ -z "${selected}" ]]; then
      row_id="$(jq -r '.review_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      row_native_id="$(jq -r '.native_agent_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      if { [[ "${_review_use_native_agent_id}" -eq 1 ]] \
            && [[ "${row_native_id}" == "${_review_native_agent_id}" ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]]; } \
          || { [[ "${_review_use_native_agent_id}" -eq 0 ]] \
            && [[ -n "${_review_dispatch_id}" ]] \
            && [[ "${row_id}" == "${_review_dispatch_id}" ]] \
            && [[ -z "${row_native_id}" ]] \
            && { [[ "${this_type}" == "${AGENT_TYPE}" ]] \
              || [[ "${this_type##*:}" == "${AGENT_TYPE##*:}" ]]; }; } \
          || { [[ "${_review_use_native_agent_id}" -eq 0 ]] \
               && [[ -z "${_review_dispatch_id}" ]] \
               && [[ -z "${row_id}" ]] \
               && [[ -z "${row_native_id}" ]] \
               && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; then
        selected="${line}"
        continue
      fi
    fi
    printf '%s\n' "${line}" >>"${tmp}"
  done <"${starts_file}"
  if [[ -n "${selected}" ]]; then
    mv "${tmp}" "${starts_file}"
    _review_dispatch_start_json="${selected}"
    # If record-subagent-summary finished its side effects first, it retained an
    # effects-complete claimed pending row until this reviewer-only causal start
    # was consumed. Remove that exact claim now. If summary is still running it
    # leaves effects_complete=false, and summary removes the row after noticing
    # that this start is gone.
    local pending_file pending_tmp pending_line pending_type pending_id pending_native_id
    local wanted_id wanted_native_id wanted_agent removed_claim=0
    pending_file="$(session_file "pending_agents.jsonl")"
    wanted_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_agent="$(jq -r '.agent_type // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    if [[ -s "${pending_file}" ]]; then
      pending_tmp="$(mktemp "${pending_file}.XXXXXX")"
      while IFS= read -r pending_line || [[ -n "${pending_line}" ]]; do
        [[ -n "${pending_line}" ]] || continue
        pending_type="$(jq -r '.agent_type // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        if [[ "${removed_claim}" -eq 0 ]] \
            && [[ "${pending_type}" == "${wanted_agent}" ]] \
            && { { [[ -n "${wanted_native_id}" ]] \
                   && [[ "${pending_native_id}" == "${wanted_native_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -n "${wanted_id}" ]] \
                   && [[ "${pending_id}" == "${wanted_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -z "${wanted_id}" ]] \
                      && [[ -z "${pending_native_id}" \
                            && -z "${pending_id}" ]]; }; } \
            && [[ "$(jq -r '.completion_claim_effects_complete // false' \
              <<<"${pending_line}" 2>/dev/null || true)" == "true" ]]; then
          removed_claim=1
          continue
        fi
        printf '%s\n' "${pending_line}" >>"${pending_tmp}"
      done <"${pending_file}"
      mv "${pending_tmp}" "${pending_file}"
    fi
  else
    rm -f "${tmp}"
  fi
}

_review_start_revision() {
  local row="$1" a b
  case "${REVIEWER_TYPE}" in
    standard) jq -r '.code_revision // empty' <<<"${row}" ;;
    design_quality) jq -r '.ui_revision // .code_revision // empty' <<<"${row}" ;;
    prose)
      a="$(jq -r '.doc_revision // 0' <<<"${row}")"
      b="$(jq -r '.bash_revision // 0' <<<"${row}")"
      (( b > a )) && a="${b}"
      printf '%s' "${a}"
      ;;
    stress_test) jq -r '.plan_revision // empty' <<<"${row}" ;;
    excellence|traceability|release) jq -r '.edit_revision // empty' <<<"${row}" ;;
    *) jq -r '.code_revision // empty' <<<"${row}" ;;
  esac
}

_review_versioned_start_revision() {
  local row="$1"
  jq -r '.review_revision // empty' <<<"${row}" 2>/dev/null || true
}

_review_current_revision() {
  case "${REVIEWER_TYPE}" in
    standard) dimension_freshness_revision "code_quality" ;;
    design_quality) dimension_freshness_revision "design_quality" ;;
    prose) dimension_freshness_revision "prose" ;;
    stress_test) dimension_freshness_revision "stress_test" ;;
    excellence) dimension_freshness_revision "completeness" ;;
    traceability) dimension_freshness_revision "traceability" ;;
    release) read_state "edit_revision" ;;
    *) dimension_freshness_revision "code_quality" ;;
  esac
}

# Publish one current, artifact-grounded evidence row per reviewer reference
# and a translated frontier receipt. This runs only after causal reviewer
# validation, under the session lock. The surrounding transaction snapshots
# all touched files so a later state-write failure rolls the whole publication
# back instead of leaving proof without an accepted reviewer dimension.
_publish_quality_review_unlocked() {
  local current_revision="$1" contract_id contract_revision cycle plan_revision
  local evidence_file frontier_file history_file evidence_tmp frontier_tmp history_tmp
  local receipts_file receipts receipt used_receipts='[]' used_proofs='[]' threshold
  local assessment criterion_id criterion axis criterion_class status result kind basis
  local ref ref_index evidence_id receipt_id proof_identity matching_criterion_ids
  local receipt_outcome receipt_tool observation_bearing
  local evidence_row all_evidence_ids='[]'
  local review_open material bar materiality weakest_axis required_count current_count
  local frontier_json reviewed_at lifecycle_id prior_frontier_status=""
  local _history_frontier_status=""
  local _staged_evidence="" _weak_id=""
  local prior_frontier="" prior_frontier_source="" prior_evidence=""
  local prior_history="" prior_history_row="" prior_open_ids='[]'
  local prior_review_receipt_ids='[]' prior_criterion_receipts='{}'
  local prior_receipt_ids='[]' prior_receipt_id="" prior_receipt=""
  local prior_proof_identity="" new_receipt_id="" new_receipt=""
  local new_proof_identity="" prior_receipt_index=-1 new_receipt_index=-1

  [[ "${REVIEWER_TYPE}" == "excellence" \
      && "${_review_quality_required}" == "1" ]] || {
    _quality_review_state_args=()
    return 0
  }
  [[ -n "${_review_quality_payload}" && -n "${_review_quality_contract}" ]] || return 1

  contract_id="$(jq -r '.contract_id' <<<"${_review_quality_contract}")"
  contract_revision="$(jq -r '.contract_revision' <<<"${_review_quality_contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${_review_quality_contract}")"
  plan_revision="$(jq -r '.plan_revision' <<<"${_review_quality_contract}")"
  reviewed_at="${now_ts}"
  lifecycle_id="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${current_revision}" =~ ^[0-9]+$ \
      && "${contract_revision}" =~ ^[0-9]+$ \
      && "${cycle}" =~ ^[0-9]+$ \
      && "${plan_revision}" =~ ^[0-9]+$ ]] || return 1

  evidence_file="$(session_file "quality_evidence.jsonl")"
  frontier_file="$(session_file "quality_frontier.json")"
  history_file="$(session_file "quality_frontier_history.jsonl")"
  for _quality_target in "${evidence_file}" "${frontier_file}" "${history_file}"; do
    [[ ! -L "${_quality_target}" ]] || return 1
    [[ ! -e "${_quality_target}" || -f "${_quality_target}" ]] || return 1
  done
  receipts_file="$(session_file "verification_receipts.jsonl")"
  receipts="$(_quality_contract_read_jsonl_array "${receipts_file}" 524288 512)" || {
    _quality_review_receipt_failure="receipt-ledger-missing-or-invalid"; return 1;
  }
  _quality_contract_receipts_schema_valid "${receipts}" || {
    _quality_review_receipt_failure="receipt-ledger-schema-invalid"; return 1;
  }
  threshold="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
  [[ "${threshold}" =~ ^[0-9]+$ && "${threshold}" -le 100 ]] || threshold=40
  evidence_tmp="$(mktemp "${evidence_file}.tmp.XXXXXX")" || return 1
  frontier_tmp="$(mktemp "${frontier_file}.tmp.XXXXXX")" || {
    rm -f "${evidence_tmp}"; return 1;
  }
  history_tmp="$(mktemp "${history_file}.tmp.XXXXXX")" || {
    rm -f "${evidence_tmp}" "${frontier_tmp}"; return 1;
  }
  chmod 600 "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}" 2>/dev/null || true

  while IFS= read -r assessment; do
    [[ -n "${assessment}" ]] || continue
    criterion_id="$(jq -r '.id' <<<"${assessment}")"
    criterion="$(jq -c --arg id "${criterion_id}" \
      '.definition.criteria[] | select(.id == $id)' \
      <<<"${_review_quality_contract}")"
    [[ -n "${criterion}" ]] || {
      rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
    }
    axis="$(jq -r '.axis' <<<"${criterion}")"
    criterion_class="$(jq -r '.class' <<<"${criterion}")"
    status="$(jq -r '.status' <<<"${assessment}")"
    kind="$(jq -r '.evidence_kind' <<<"${assessment}")"
    basis="$(jq -r '.basis' <<<"${assessment}")"
    result="failed"
    [[ "${status}" == "met" ]] && result="passed"
    ref_index=0
    while IFS= read -r ref; do
      [[ -n "${ref}" ]] || continue
      ref_index=$((ref_index + 1))
      receipt="$(jq -c --arg id "${ref}" \
        '[.[] | select(.receipt_id == $id)]
         | if length == 1 then .[0] else empty end' \
        <<<"${receipts}" 2>/dev/null || true)"
      [[ -n "${receipt}" ]] || {
        _quality_review_receipt_failure="receipt-not-found:${ref}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      if jq -e --arg id "${ref}" 'index($id) != null' \
          <<<"${used_receipts}" >/dev/null 2>&1; then
        _quality_review_receipt_failure="receipt-reused:${ref}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1
      fi
      used_receipts="$(jq -c --arg id "${ref}" '. + [$id]' \
        <<<"${used_receipts}")" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      proof_identity="$(jq -r '.proof_identity // empty' \
        <<<"${receipt}" 2>/dev/null || true)"
      [[ -n "${proof_identity}" && "${proof_identity}" != "null" ]] || {
        _quality_review_receipt_failure="receipt-proof-identity-invalid:${ref}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      if jq -e --arg id "${proof_identity}" 'index($id) != null' \
          <<<"${used_proofs}" >/dev/null 2>&1; then
        # Re-running one semantic proof under a fresh tool ID does not create
        # independent evidence for another criterion (or another minimum).
        _quality_review_receipt_failure="receipt-proof-reused:${proof_identity}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1
      fi
      used_proofs="$(jq -c --arg id "${proof_identity}" '. + [$id]' \
        <<<"${used_proofs}")" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      [[ "$(jq -r '.quality_contract_id' <<<"${receipt}")" == "${contract_id}" \
          && "$(jq -r '.quality_contract_revision' <<<"${receipt}")" == "${contract_revision}" \
          && "$(jq -r '.review_cycle_id' <<<"${receipt}")" == "${cycle}" \
          && "$(jq -r '.edit_revision' <<<"${receipt}")" == "${current_revision}" \
          && "$(jq -r '.plan_revision' <<<"${receipt}")" == "${plan_revision}" \
          && "$(jq -r '.evidence_kind' <<<"${receipt}")" == "${kind}" \
          && "$(jq -r '.confidence' <<<"${receipt}")" -ge "${threshold}" ]] || {
        _quality_review_receipt_failure="receipt-stale-or-below-threshold:${ref}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      matching_criterion_ids="$(quality_contract_receipt_matching_criterion_ids \
        "${receipt}" "${_review_quality_contract}" 2>/dev/null || true)"
      if [[ "$(jq -r 'length' <<<"${matching_criterion_ids:-[]}" 2>/dev/null || true)" != "1" \
          || "$(jq -r '.[0] // empty' <<<"${matching_criterion_ids:-[]}" 2>/dev/null || true)" \
            != "${criterion_id}" ]]; then
        _quality_review_receipt_failure="receipt-criterion-ambiguous:${ref}:${criterion_id}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1
      fi
      quality_contract_receipt_matches_criterion "${receipt}" "${criterion}" || {
        _quality_review_receipt_failure="receipt-does-not-match-criterion:${ref}:${criterion_id}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      receipt_id="${ref}"
      receipt_outcome="$(jq -r '.outcome' <<<"${receipt}")"
      receipt_tool="$(jq -r '.tool_name' <<<"${receipt}")"
      observation_bearing=0
      case "${kind}:${receipt_tool}" in
        source:*) observation_bearing=1 ;;
        inspection:Read|inspection:Grep|inspection:mcp__*) observation_bearing=1 ;;
        render:mcp__*) observation_bearing=1 ;;
      esac

      # A receipt proves that the named observation happened; for Read/Grep
      # and observational MCP inspection/render calls, a successful tool
      # outcome does not assert that the criterion itself is met. The
      # independent reviewer may therefore use a successful observation to
      # report an honest semantic `unmet`. A failed observation establishes
      # neither `met` nor `unmet` and cannot support a fresh assessment.
      # Assertion-bearing test/benchmark/comparison receipts
      # (and Bash render/inspection checks) retain strict outcome congruence.
      result="failed"
      [[ "${status}" == "met" ]] && result="passed"
      if [[ "${observation_bearing}" -eq 1 ]]; then
        if [[ "${receipt_outcome}" != "passed" ]]; then
          _quality_review_receipt_failure="receipt-outcome-contradicts-review:${ref}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1
        fi
      elif ! { { [[ "${status}" == "met" && "${receipt_outcome}" == "passed" ]]; } \
          || { [[ "${status}" == "unmet" && "${receipt_outcome}" == "failed" ]]; }; }; then
        _quality_review_receipt_failure="receipt-outcome-contradicts-review:${ref}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      fi
      evidence_id="qe-$(_quality_contract_digest \
        "${receipt_id}|${current_revision}|${plan_revision}|${lifecycle_id}|${ref_index}")"
      evidence_row="$(jq -cnS \
        --arg contract_id "${contract_id}" \
        --argjson contract_revision "${contract_revision}" \
        --argjson review_cycle_id "${cycle}" \
        --arg criterion_id "${criterion_id}" \
        --arg axis "${axis}" --arg class "${criterion_class}" \
        --arg evidence_id "${evidence_id}" --arg receipt_id "${receipt_id}" \
        --arg result "${result}" --arg evidence_kind "${kind}" \
        --arg claim "${basis}" --arg reference "${ref}" \
        --argjson edit_revision "${current_revision}" \
        --argjson plan_revision "${plan_revision}" \
        --argjson reviewed_at "${reviewed_at}" \
        --arg reviewer "${AGENT_TYPE}" \
        --arg native_agent_id "${_review_native_agent_id}" \
        --arg lifecycle_dispatch_id "${lifecycle_id}" \
        '{_v:1,contract_id:$contract_id,contract_revision:$contract_revision,
          review_cycle_id:$review_cycle_id,criterion_id:$criterion_id,axis:$axis,
          class:$class,evidence_id:$evidence_id,receipt_id:$receipt_id,
          result:$result,evidence_kind:$evidence_kind,claim:$claim,reference:$reference,
          edit_revision:$edit_revision,plan_revision:$plan_revision,
          reviewed_at:$reviewed_at,reviewer:$reviewer,
          native_agent_id:$native_agent_id,lifecycle_dispatch_id:$lifecycle_dispatch_id}')" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      printf '%s\n' "${evidence_row}" >>"${evidence_tmp}" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      all_evidence_ids="$(jq -c --arg id "${evidence_id}" '. + [$id]' \
        <<<"${all_evidence_ids}")"
    done < <(jq -r '.refs[]' <<<"${assessment}")
  done < <(jq -c '.criteria[]' <<<"${_review_quality_payload}")

  material="$(jq -r '.frontier.material' <<<"${_review_quality_payload}")"
  bar="$(jq -r '.frontier.bar_quality' <<<"${_review_quality_payload}")"
  review_open=false
  if [[ "${material}" == "true" || "${bar}" == "weak" ]] \
    || jq -e --argjson contract "${_review_quality_contract}" '
      [.criteria[] | select(.status == "unmet") | .id] as $unmet
      | any($contract.definition.criteria[]; . as $criterion
          | $criterion.class == "must"
            and ($unmet | index($criterion.id)) != null)
    ' <<<"${_review_quality_payload}" >/dev/null 2>&1; then
    review_open=true
  fi
  materiality="none"
  if [[ "${review_open}" == "true" ]]; then
    materiality="medium"
    [[ "${material}" == "true" && "${bar}" == "weak" ]] && materiality="high"
  fi
  if [[ "${review_open}" == "true" ]]; then
    weakest_axis="none"
    _weak_id="$(jq -r '[.criteria[] | select(.status == "unmet")][0].id // .frontier.criterion_ids[0] // empty' \
      <<<"${_review_quality_payload}")"
    if [[ -n "${_weak_id}" ]]; then
      weakest_axis="$(jq -r --arg id "${_weak_id}" \
        '.definition.criteria[] | select(.id == $id) | .axis' \
        <<<"${_review_quality_contract}")"
    fi
  else
    # A clear review still has a weakest tested axis. Derive it from the
    # harness-stamped receipt confidences rather than reviewer prose. The stable
    # axis order makes equal-confidence portfolios deterministic across jq/Bash
    # versions and gives closeout/status a truthful non-"none" result.
    weakest_axis="$(jq -nr \
      --argjson review "${_review_quality_payload}" \
      --argjson contract "${_review_quality_contract}" \
      --argjson receipts "${receipts}" '
        ["deliberate","distinctive","coherent","visionary","complete"] as $axis_order
        | [ $review.criteria[] as $assessment
            | ($contract.definition.criteria[]
                | select(.id == $assessment.id)) as $criterion
            | $assessment.refs[] as $receipt_id
            | ($receipts[]
                | select(.receipt_id == $receipt_id)) as $receipt
            | {axis:$criterion.axis, confidence:$receipt.confidence,
               axis_rank:($axis_order | index($criterion.axis))} ]
        | sort_by(.confidence, .axis_rank)
        | .[0].axis // "none"
      ' 2>/dev/null)" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
        return 1
      }
    case "${weakest_axis}" in
      deliberate|distinctive|coherent|visionary|complete) ;;
      *)
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
        return 1
        ;;
    esac
  fi
  required_count="$(jq -r '[.definition.criteria[] | select(.class == "must")] | length' \
    <<<"${_review_quality_contract}")"
  current_count="$(jq -r --argjson c "${_review_quality_contract}" '
    [.criteria[] | select(.status == "met") | .id] as $met
    | [$c.definition.criteria[] | . as $criterion
        | select(.class == "must" and ($met | index($criterion.id)) != null)] | length
  ' <<<"${_review_quality_payload}")"
  frontier_json="$(jq -cnS \
    --arg contract_id "${contract_id}" \
    --argjson contract_revision "${contract_revision}" \
    --argjson review_cycle_id "${cycle}" \
    --argjson edit_revision "${current_revision}" \
    --argjson plan_revision "${plan_revision}" \
    --arg status "$([[ "${review_open}" == "true" ]] && printf open || printf clear)" \
    --arg materiality "${materiality}" \
    --argjson dominates_current "${review_open}" \
    --argjson evidence_ids "${all_evidence_ids}" \
    --argjson receipt_ids "${used_receipts}" \
    --argjson review "${_review_quality_payload}" \
    --argjson reviewed_at "${reviewed_at}" \
    --arg reviewer "${AGENT_TYPE}" \
    --arg native_agent_id "${_review_native_agent_id}" \
    --arg lifecycle_dispatch_id "${lifecycle_id}" \
    '{_v:1,contract_id:$contract_id,contract_revision:$contract_revision,
      review_cycle_id:$review_cycle_id,edit_revision:$edit_revision,
      plan_revision:$plan_revision,status:$status,materiality:$materiality,
      dominates_current:$dominates_current,
      criterion_ids:$review.frontier.criterion_ids,evidence_ids:$evidence_ids,
      title:$review.frontier.title,why:$review.frontier.why,
      recommended_move:$review.frontier.recommended_move,
      experiment:$review.frontier.experiment,evidence:$receipt_ids,
      alternatives_searched:$review.alternatives_searched,limits:$review.limits,
      reviewed_at:$reviewed_at,reviewer:$reviewer,
      native_agent_id:$native_agent_id,lifecycle_dispatch_id:$lifecycle_dispatch_id}')" || {
    rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
  }
  printf '%s\n' "${frontier_json}" >"${frontier_tmp}" || {
    rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
  }
  _staged_evidence="$(jq -sc . "${evidence_tmp}" 2>/dev/null || true)"
  if [[ -z "${_staged_evidence}" ]] \
      || ! _quality_contract_evidence_schema_valid "${_staged_evidence}" \
      || ! _quality_contract_frontier_schema_valid "${frontier_json}"; then
    rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
    return 1
  fi

  # An accepted material frontier is durable authority, not a reviewer opinion
  # that a second reviewer may erase by re-citing the same proof. When the last
  # authoritative row in this objective cycle is open, every criterion named by
  # that frontier must receive a later ledger receipt with a different
  # proof_identity before a clear publication can replace it. The current
  # frontier/evidence pair is preferred; after an additive re-contract removes
  # those current files, the bounded history row plus its normalized receipt
  # portfolio provides the same causal predecessor.
  if [[ "${review_open}" != "true" ]]; then
    if [[ -f "${frontier_file}" ]]; then
      prior_frontier="$(_quality_contract_read_json_file \
        "${frontier_file}" 65536 2>/dev/null || true)"
      if [[ -n "${prior_frontier}" ]] \
          && _quality_contract_frontier_schema_valid "${prior_frontier}" \
          && [[ "$(jq -r '.review_cycle_id' <<<"${prior_frontier}")" == "${cycle}" ]] \
          && [[ "$(jq -r '.status' <<<"${prior_frontier}")" == "open" ]]; then
        prior_frontier_source="current"
        prior_evidence="$(_quality_contract_read_jsonl_array \
          "${evidence_file}" 2>/dev/null || true)"
        if [[ -z "${prior_evidence}" ]] \
            || ! _quality_contract_evidence_schema_valid "${prior_evidence}" \
            || ! jq -e --argjson frontier "${prior_frontier}" '
              all(.[];
                .contract_id == $frontier.contract_id
                and .contract_revision == $frontier.contract_revision
                and .review_cycle_id == $frontier.review_cycle_id
                and .edit_revision == $frontier.edit_revision
                and .plan_revision == $frontier.plan_revision
                and .reviewed_at == $frontier.reviewed_at
                and .reviewer == $frontier.reviewer
                and .native_agent_id == $frontier.native_agent_id
                and .lifecycle_dispatch_id == $frontier.lifecycle_dispatch_id)
            ' <<<"${prior_evidence}" >/dev/null 2>&1; then
          _quality_review_receipt_failure="open-frontier-evidence-invalid"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
        prior_review_receipt_ids="$(jq -c \
          '[.[].receipt_id] | unique' <<<"${prior_evidence}")" || {
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        }
      else
        prior_frontier=""
      fi
    fi

    if [[ -z "${prior_frontier}" && -f "${history_file}" ]]; then
      prior_history="$(_quality_frontier_history_parse \
        "${history_file}" 2>/dev/null || true)"
      if [[ -n "${prior_history}" ]]; then
        prior_history_row="$(jq -c --argjson cycle "${cycle}" '
          [.rows[] | select(.review_cycle_id == $cycle)]
          | if length > 0 then .[-1] else empty end
        ' <<<"${prior_history}" 2>/dev/null || true)"
        if [[ -n "${prior_history_row}" \
            && "$(jq -r '.status' <<<"${prior_history_row}")" == "open" ]]; then
          prior_frontier="${prior_history_row}"
          prior_frontier_source="history"
          prior_review_receipt_ids="$(jq -c '.evidence | unique' \
            <<<"${prior_frontier}")" || {
            rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
            return 1
          }
        else
          prior_frontier=""
        fi
      fi
    fi

    if [[ -n "${prior_frontier}" ]]; then
      prior_frontier_status="open"
      prior_open_ids="$(jq -c '.criterion_ids | unique' \
        <<<"${prior_frontier}")" || {
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
        return 1
      }
      if [[ "$(jq -r 'length' <<<"${prior_open_ids}")" -lt 1 \
          || "$(jq -r 'length' <<<"${prior_review_receipt_ids}")" -lt 1 ]]; then
        _quality_review_receipt_failure="open-frontier-causal-proof-missing"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
        return 1
      fi

      while IFS= read -r prior_receipt_id; do
        [[ -n "${prior_receipt_id}" ]] || continue
        prior_receipt_index="$(jq -r --arg id "${prior_receipt_id}" '
          map(.receipt_id) | index($id) // -1
        ' <<<"${receipts}" 2>/dev/null || printf '%s' -1)"
        if [[ ! "${prior_receipt_index}" =~ ^[0-9]+$ ]]; then
          _quality_review_receipt_failure="open-frontier-receipt-missing:${prior_receipt_id}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
      done < <(jq -r '.[]' <<<"${prior_review_receipt_ids}")

      while IFS= read -r criterion_id; do
        [[ -n "${criterion_id}" ]] || continue
        if [[ "${prior_frontier_source}" == "current" ]]; then
          prior_receipt_ids="$(jq -c --arg id "${criterion_id}" '
            [.[] | select(.criterion_id == $id) | .receipt_id] | unique
          ' <<<"${prior_evidence}" 2>/dev/null || printf '[]')"
        else
          prior_receipt_ids='[]'
          while IFS= read -r prior_receipt_id; do
            [[ -n "${prior_receipt_id}" ]] || continue
            prior_receipt="$(jq -c --arg id "${prior_receipt_id}" '
              [.[] | select(.receipt_id == $id)]
              | if length == 1 then .[0] else empty end
            ' <<<"${receipts}" 2>/dev/null || true)"
            [[ -n "${prior_receipt}" ]] || continue
            matching_criterion_ids="$(quality_contract_receipt_matching_criterion_ids \
              "${prior_receipt}" "${_review_quality_contract}" 2>/dev/null || true)"
            if [[ "$(jq -r --arg id "${criterion_id}" \
                'index($id) != null' <<<"${matching_criterion_ids:-[]}" \
                2>/dev/null || true)" == "true" ]]; then
              prior_receipt_ids="$(jq -c --arg id "${prior_receipt_id}" \
                '. + [$id] | unique' <<<"${prior_receipt_ids}")" || {
                rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
                return 1
              }
            fi
          done < <(jq -r '.[]' <<<"${prior_review_receipt_ids}")
        fi

        if [[ "$(jq -r 'length' <<<"${prior_receipt_ids}" 2>/dev/null || true)" != "1" ]]; then
          _quality_review_receipt_failure="open-frontier-criterion-proof-missing:${criterion_id}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
        prior_receipt_id="$(jq -r '.[0]' <<<"${prior_receipt_ids}")"
        prior_criterion_receipts="$(jq -c \
          --arg criterion "${criterion_id}" --arg receipt "${prior_receipt_id}" \
          '. + {($criterion):$receipt}' <<<"${prior_criterion_receipts}")" || {
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        }
      done < <(jq -r '.[]' <<<"${prior_open_ids}")

      while IFS= read -r criterion_id; do
        [[ -n "${criterion_id}" ]] || continue
        prior_receipt_id="$(jq -r --arg id "${criterion_id}" \
          '.[$id] // empty' <<<"${prior_criterion_receipts}")"
        new_receipt_id="$(jq -r --arg id "${criterion_id}" '
          [.[] | select(.criterion_id == $id) | .receipt_id]
          | if length == 1 then .[0] else empty end
        ' <<<"${_staged_evidence}" 2>/dev/null || true)"
        prior_receipt="$(jq -c --arg id "${prior_receipt_id}" '
          [.[] | select(.receipt_id == $id)]
          | if length == 1 then .[0] else empty end
        ' <<<"${receipts}" 2>/dev/null || true)"
        new_receipt="$(jq -c --arg id "${new_receipt_id}" '
          [.[] | select(.receipt_id == $id)]
          | if length == 1 then .[0] else empty end
        ' <<<"${receipts}" 2>/dev/null || true)"
        if [[ -z "${prior_receipt}" || -z "${new_receipt}" ]]; then
          _quality_review_receipt_failure="open-frontier-counterproof-missing:${criterion_id}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
        prior_receipt_index="$(jq -r --arg id "${prior_receipt_id}" \
          'map(.receipt_id) | index($id) // -1' <<<"${receipts}")"
        new_receipt_index="$(jq -r --arg id "${new_receipt_id}" \
          'map(.receipt_id) | index($id) // -1' <<<"${receipts}")"
        prior_proof_identity="$(jq -r '.proof_identity // empty' \
          <<<"${prior_receipt}")"
        new_proof_identity="$(jq -r '.proof_identity // empty' \
          <<<"${new_receipt}")"
        if [[ ! "${prior_receipt_index}" =~ ^[0-9]+$ \
            || ! "${new_receipt_index}" =~ ^[0-9]+$ \
            || "${new_receipt_index}" -le "${prior_receipt_index}" \
            || -z "${prior_proof_identity}" \
            || -z "${new_proof_identity}" \
            || "${new_proof_identity}" == "${prior_proof_identity}" ]]; then
          _quality_review_receipt_failure="open-frontier-counterproof-not-new:${criterion_id}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
      done < <(jq -r '.[]' <<<"${prior_open_ids}")
    fi
  fi

  if [[ -f "${history_file}" ]]; then
    _history_frontier_status="$(quality_frontier_history_last_status_for_cycle \
      "${history_file}" "${cycle}" 2>/dev/null || true)"
    [[ -n "${_history_frontier_status}" ]] \
      && prior_frontier_status="${_history_frontier_status}"
    tail -n 63 "${history_file}" >"${history_tmp}" 2>/dev/null || true
  fi
  printf '%s\n' "${frontier_json}" >>"${history_tmp}" || {
    rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
  }
  mv -f "${evidence_tmp}" "${evidence_file}" \
    && mv -f "${frontier_tmp}" "${frontier_file}" \
    && mv -f "${history_tmp}" "${history_file}" || {
      rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
    }

  # Release-visible taxonomy: classify the accepted frontier transition only
  # after every authoritative artifact landed. The caller emits the event
  # after the encompassing state transaction succeeds, so a rollback cannot
  # advertise a discovery/remediation that was never committed.
  if [[ "${review_open}" == "true" ]]; then
    if [[ "${prior_frontier_status}" == "open" ]]; then
      _quality_review_frontier_event="material-frontier-confirmed"
    else
      _quality_review_frontier_event="material-frontier-discovered"
    fi
  elif [[ "${prior_frontier_status}" == "open" ]]; then
    _quality_review_frontier_event="material-frontier-remediated"
  else
    _quality_review_frontier_event="frontier-clear"
  fi
  _quality_review_frontier_contract_id="${contract_id}"
  _quality_review_frontier_contract_revision="${contract_revision}"
  _quality_review_frontier_cycle="${cycle}"
  _quality_review_frontier_status="$([[ "${review_open}" == "true" ]] && printf open || printf clear)"
  _quality_review_frontier_materiality="${materiality}"

  _quality_review_state_args=(
    "quality_contract_status" "$([[ "${review_open}" == "true" ]] && printf review-findings || printf proved)"
    "quality_evidence_required_count" "${required_count}"
    "quality_evidence_current_count" "${current_count}"
    "quality_evidence_blocks" "0"
    "quality_frontier_status" "$([[ "${review_open}" == "true" ]] && printf open || printf clear)"
    "quality_frontier_revision" "${current_revision}"
    "quality_frontier_plan_revision" "${plan_revision}"
    "quality_frontier_blocks" "0"
    "quality_weakest_axis" "${weakest_axis}"
    "quality_last_review_ts" "${reviewed_at}"
  )
}

# Commit reviewer metadata and dimension verdicts under one state lock. The
# dispatch-start generation must still equal the completion generation. If an
# edit/plan landed while the reviewer was running, preserve the prior verdict
# and force a new review rather than stamping old evidence as current. Metadata
# and dimension state are assembled and written in ONE atomic state batch.
_commit_reviewer_result() {
  local dimension_verdict="$1" dimensions_csv="$2"
  shift 2

  # A SubagentStop callback can outlive the interval that dispatched it.
  # Recheck authority under the same lock as causal consumption + verdict
  # publication so a completed/off session cannot gain late review evidence.
  if ! is_ultrawork_mode; then
    _review_rejection_reason="enforcement_interval_closed"
    return 0
  fi
  _review_commit_accepted=0
  _review_rejection_reason=""
  _review_rejection_start=""
  _review_rejection_current=""
  _consume_reviewer_dispatch_start_unlocked
  local _current_revision _start_revision="" _tracking_version=""
  local _row_version="" _strict_tracking=0 _rejection_reason=""
  local _current_objective_ts="" _start_objective_ts=""
  local _start_objective_revision=""
  local _current_cycle_id=0 _start_cycle_id=0
  local _stale_count=""
  _current_revision="$(_review_current_revision)"
  _tracking_version="$(read_state "review_dispatch_tracking_version")"
  local _native_tracking_version=""
  _native_tracking_version="${_review_native_tracking_version:-$(read_state "native_agent_id_tracking_version")}"

  if [[ -n "${_tracking_version}" || "${_native_tracking_version}" == "1" \
      || "${_review_use_native_agent_id:-0}" -eq 1 \
      || "${_review_native_agent_id_invalid}" -eq 1 ]]; then
    _strict_tracking=1
  fi
  if [[ -n "${_review_dispatch_start_json}" ]]; then
    _row_version="$(jq -r '.review_dispatch_causality_version // empty' \
      <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
    [[ -n "${_row_version}" ]] && _strict_tracking=1
  fi

  if [[ "${_strict_tracking}" -eq 1 ]]; then
    # Current sessions fail closed. A missing row means the PreTool snapshot
    # was lost (or replayed); a malformed/unknown version cannot safely prove
    # which mutation generation the reviewer inspected. Empty canonical
    # revisions normalize to generation zero for pre-revision state that is
    # upgraded by a current dispatcher.
    [[ "${_current_revision}" =~ ^[0-9]+$ ]] || _current_revision=0
    if [[ "${_review_native_agent_id_invalid}" -eq 1 ]]; then
      _rejection_reason="invalid_native_agent_id"
    elif [[ "${_native_tracking_version}" == "1" \
        && "${_review_native_agent_id_present}" -eq 0 ]]; then
      _rejection_reason="missing_native_agent_id"
    elif [[ "${_native_tracking_version}" == "1" \
        && "${_review_native_binding_committed:-0}" -ne 1 ]]; then
      _rejection_reason="native_agent_binding_uncommitted"
    elif [[ -z "${_review_dispatch_start_json}" \
        && "${_review_use_native_agent_id:-0}" -eq 1 ]]; then
      _rejection_reason="native_agent_id_mismatch"
    elif [[ -z "${_review_dispatch_start_json}" ]]; then
      _rejection_reason="missing_start_snapshot"
    elif ! omc_row_enforcement_generation_current \
        "${_review_dispatch_start_json}"; then
      _rejection_reason="enforcement_interval_closed"
    elif [[ "$(jq -r '.review_dispatch_abandoned // false' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)" == "true" ]]; then
      _start_revision="$(_review_versioned_start_revision \
        "${_review_dispatch_start_json}")"
      _rejection_reason="abandoned_dispatch_completion"
    elif [[ "${_tracking_version}" != "${REVIEW_DISPATCH_CAUSALITY_VERSION}" ]] \
        || [[ "${_row_version}" != "${REVIEW_DISPATCH_CAUSALITY_VERSION}" ]]; then
      _rejection_reason="invalid_start_snapshot"
    else
      _start_revision="$(_review_versioned_start_revision "${_review_dispatch_start_json}")"
      _start_objective_ts="$(jq -r '.objective_prompt_ts // empty' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
      _start_objective_revision="$(jq -r '.objective_prompt_revision // empty' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
      _start_cycle_id="$(jq -r '.objective_cycle_id // 0' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
      _current_objective_ts="$(read_state "review_cycle_prompt_ts")"
      if [[ ! "${_current_objective_ts}" =~ ^[0-9]+$ ]]; then
        _current_objective_ts="$(read_state "last_user_prompt_ts")"
      fi
      [[ "${_current_objective_ts}" =~ ^[0-9]+$ ]] || _current_objective_ts=0
      _current_cycle_id="$(read_state "review_cycle_id")"
      [[ "${_current_cycle_id}" =~ ^[0-9]+$ ]] || _current_cycle_id=0
      [[ "${_start_cycle_id}" =~ ^[0-9]+$ ]] || _start_cycle_id=0
      if [[ ! "${_start_revision}" =~ ^[0-9]+$ \
          || ! "${_start_objective_ts}" =~ ^[0-9]+$ \
          || ! "${_start_objective_revision}" =~ ^[0-9]+$ ]]; then
        _rejection_reason="invalid_start_snapshot"
      elif (( _start_objective_ts != _current_objective_ts )); then
        # review_cycle_prompt_ts is the stable objective identity. Raw
        # prompt_revision may advance on a true continuation and is retained in
        # history for audit, but must not invalidate same-objective evidence.
        _rejection_reason="review_objective_changed"
      elif (( _current_cycle_id > 0 && _start_cycle_id != _current_cycle_id )); then
        _rejection_reason="review_objective_changed"
      elif (( _start_revision != _current_revision )); then
        _rejection_reason="review_generation_changed"
      fi
    fi
  elif [[ -n "${_review_dispatch_start_json}" ]]; then
    # Explicit legacy migration path: unversioned sessions may consume their
    # old per-surface row. Missing/malformed legacy snapshots retain the
    # historical completion-time behavior; the first current dispatch writes
    # the marker above and permanently closes this path for the session.
    _start_revision="$(_review_start_revision "${_review_dispatch_start_json}")"
    if [[ "${_start_revision}" =~ ^[0-9]+$ ]] \
        && [[ "${_current_revision}" =~ ^[0-9]+$ ]] \
        && (( _start_revision != _current_revision )); then
      _rejection_reason="review_generation_changed"
    fi
  fi

  # Re-resolve the Definition under the commit lock and require the exact
  # contract identity frozen into the dispatch row. The earlier parse is only a
  # cheap continuation filter; it cannot authorize publication because a
  # planner revision may land while the reviewer is running.
  if [[ -z "${_rejection_reason}" \
      && "${REVIEWER_TYPE}" == "excellence" \
      && "${_review_quality_required}" == "1" ]]; then
    local _commit_contract="" _start_contract_id="" _start_contract_revision=""
    if ! _commit_contract="$(quality_contract_validate_current 2>/dev/null)"; then
      _rejection_reason="quality_contract_stale"
    else
      _start_contract_id="$(jq -r '.quality_contract_id // empty' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
      _start_contract_revision="$(jq -r '.quality_contract_revision // empty' \
        <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
      if [[ -z "${_start_contract_id}" \
          || ! "${_start_contract_revision}" =~ ^[1-9][0-9]*$ ]]; then
        _rejection_reason="quality_contract_dispatch_unbound"
      elif [[ "${_start_contract_id}" != "$(jq -r '.contract_id' <<<"${_commit_contract}")" \
          || "${_start_contract_revision}" != "$(jq -r '.contract_revision' <<<"${_commit_contract}")" ]]; then
        _rejection_reason="quality_contract_changed"
      elif ! quality_review_validate_against_contract \
          "${_review_quality_payload}" "${_commit_contract}" \
          "${_review_final_line:-}" 2>/dev/null; then
        _rejection_reason="quality_review_contract_mismatch"
      else
        _review_quality_contract="${_commit_contract}"
      fi
    fi
  fi

  if [[ -n "${_rejection_reason}" ]]; then
    _stale_count="$(read_state "stale_reviewer_count")"
    [[ "${_stale_count}" =~ ^[0-9]+$ ]] || _stale_count=0
    _write_state_batch_unlocked \
      "last_stale_reviewer_type" "${REVIEWER_TYPE}" \
      "last_stale_reviewer_ts" "${now_ts}" \
      "last_stale_reviewer_reason" "${_rejection_reason}" \
      "last_stale_reviewer_start_revision" "${_start_revision}" \
      "last_stale_reviewer_current_revision" "${_current_revision}" \
      "stale_reviewer_count" "$((_stale_count + 1))"
    _review_rejection_reason="${_rejection_reason}"
    _review_rejection_start="${_start_revision}"
    _review_rejection_current="${_current_revision}"
    return 0
  fi

  local _metadata_args=("$@")
  # Legacy stop-time gates consume these role-specific review generations.
  # Store them in the same atomic batch as the verdict/dimension state so a
  # concurrent Stop can never observe a new timestamp with an old revision.
  case "${REVIEWER_TYPE}" in
    standard)
      _metadata_args+=("review_code_revision" "${_current_revision}")
      ;;
    prose)
      _metadata_args+=("review_doc_revision" "${_current_revision}")
      ;;
  esac
  if [[ -n "${dimensions_csv}" ]]; then
    local _saved_ifs="${IFS}"
    local _dimensions=()
    IFS=',' read -r -a _dimensions <<<"${dimensions_csv}"
    IFS="${_saved_ifs}"
    _prepare_stricter_dim_state_args_unlocked \
      "${dimension_verdict}" "${now_ts}" "${_dimensions[@]}"
  else
    _OMC_DIM_STATE_ARGS=()
  fi
  _quality_review_state_args=()
  _publish_quality_review_unlocked "${_current_revision}" || return 1
  # macOS still ships Bash 3.2, where expanding an empty array under `set -u`
  # raises "unbound variable". Assemble one non-empty metadata array and append
  # optional dimension/quality args only after checking their lengths.
  local _all_state_args=("${_metadata_args[@]}")
  if (( ${#_OMC_DIM_STATE_ARGS[@]} > 0 )); then
    _all_state_args+=("${_OMC_DIM_STATE_ARGS[@]}")
  fi
  if (( ${#_quality_review_state_args[@]} > 0 )); then
    _all_state_args+=("${_quality_review_state_args[@]}")
  fi
  _write_state_batch_unlocked "${_all_state_args[@]}"
  _review_commit_accepted=1
}

_quality_review_transaction_artifacts() {
  printf '%s\n' \
    session_state.json \
    pending_agents.jsonl \
    agent_dispatch_starts.jsonl \
    quality_evidence.jsonl \
    quality_frontier.json \
    quality_frontier_history.jsonl
}

_snapshot_quality_review_transaction_unlocked() {
  local dir="$1" artifact path
  while IFS= read -r artifact; do
    [[ -n "${artifact}" ]] || continue
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]]; then
      : >"${dir}/${artifact}.other" || return 1
    elif [[ -f "${path}" ]]; then
      cp "${path}" "${dir}/${artifact}.file" || return 1
    elif [[ ! -e "${path}" ]]; then
      : >"${dir}/${artifact}.absent" || return 1
    else
      : >"${dir}/${artifact}.other" || return 1
    fi
  done < <(_quality_review_transaction_artifacts)
}

_validate_quality_review_transaction_targets_unlocked() {
  local artifact path
  while IFS= read -r artifact; do
    [[ -n "${artifact}" ]] || continue
    path="$(session_file "${artifact}")"
    if [[ -L "${path}" ]] \
      || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
      log_anomaly "record-reviewer" \
        "refusing non-regular Definition transaction artifact at ${path}"
      return 1
    fi
  done < <(_quality_review_transaction_artifacts)
}

_restore_quality_review_transaction_unlocked() {
  local dir="$1" artifact path tmp rc=0
  while IFS= read -r artifact; do
    [[ -n "${artifact}" ]] || continue
    path="$(session_file "${artifact}")"
    if [[ -f "${dir}/${artifact}.file" ]]; then
      if [[ -L "${path}" ]] \
        || { [[ -e "${path}" ]] && [[ ! -f "${path}" ]]; }; then
        rc=1
        continue
      fi
      tmp="$(mktemp "${path}.restore.XXXXXX")" || { rc=1; continue; }
      chmod 600 "${tmp}" 2>/dev/null || true
      if ! cp "${dir}/${artifact}.file" "${tmp}" \
        || ! mv -f "${tmp}" "${path}"; then
        rm -f "${tmp}" 2>/dev/null || true
        rc=1
      fi
    elif [[ -f "${dir}/${artifact}.absent" ]]; then
      if [[ -L "${path}" ]]; then
        rc=1
      elif [[ -f "${path}" ]]; then
        rm -f "${path}" || rc=1
      elif [[ -e "${path}" ]]; then
        rc=1
      fi
    else
      rc=1
    fi
  done < <(_quality_review_transaction_artifacts)
  return "${rc}"
}

_commit_reviewer_transaction_unlocked() {
  # Existing reviewers retain their lean single-file path. Only an armed
  # excellence return owns the multi-artifact Definition transaction.
  if [[ "${REVIEWER_TYPE}" != "excellence" \
      || "${_review_quality_required}" != "1" ]]; then
    _commit_reviewer_result "$@"
    return
  fi
  local snapshot_dir rc=0 restore_rc=0
  _validate_quality_review_transaction_targets_unlocked || return 1
  snapshot_dir="$(mktemp -d "$(session_file ".quality-review-txn.XXXXXX")")" \
    || return 1
  if ! _snapshot_quality_review_transaction_unlocked "${snapshot_dir}"; then
    rm -f "${snapshot_dir}"/* 2>/dev/null || true
    rmdir "${snapshot_dir}" 2>/dev/null || true
    return 1
  fi
  _commit_reviewer_result "$@" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    _restore_quality_review_transaction_unlocked "${snapshot_dir}" || restore_rc=$?
  fi
  rm -f "${snapshot_dir}"/* 2>/dev/null || true
  rmdir "${snapshot_dir}" 2>/dev/null || true
  [[ "${restore_rc}" -eq 0 ]] || return "${restore_rc}"
  return "${rc}"
}

dimension_verdict="FINDINGS"
[[ "${has_findings}" == "false" ]] && dimension_verdict="CLEAN"

if [[ "${REVIEWER_TYPE}" == "release" ]]; then
  # release-reviewer is a cumulative/manual release-prep reviewer. It is
  # intentionally outside the per-wave quality dimensions; treating it as
  # `standard` would let a clean release review satisfy bug_hunt/code_quality
  # and clear stop-guard counters for ordinary implementation work.
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "" \
    "last_release_review_ts" "${now_ts}" \
    "release_review_had_findings" "${has_findings}" \
    "release_review_format_issue" "${review_format_issue}"
elif [[ "${REVIEWER_TYPE}" == "excellence" ]]; then
  # Excellence owns only the completeness clock. It must not satisfy the
  # universal quality-reviewer clock or overwrite its finding/format state.
  # An armed Definition's material frontier has its own earlier, uncapped
  # authority gate. Do not also persist that frontier as generic completeness
  # FINDINGS: a same-artifact empirical counterexample can legitimately clear
  # the frontier without an edit, while generic stricter-verdict-wins is
  # revision-based and would otherwise deadlock forever. Genuine non-Definition
  # completeness findings and every sibling reviewer remain pessimistic.
  _excellence_dimensions="completeness"
  if [[ "${_review_quality_required}" == "1" \
      && "${dimension_verdict}" == "FINDINGS" ]]; then
    _excellence_dimensions=""
  fi
  _quality_review_commit_rc=0
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "${_excellence_dimensions}" \
    "last_excellence_review_ts" "${now_ts}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0" || _quality_review_commit_rc=$?
  if [[ "${_quality_review_commit_rc}" -ne 0 ]]; then
    if [[ -n "${_quality_review_receipt_failure:-}" ]]; then
      record_gate_event "definition-of-excellent/review" \
        "receipt-authority-rejected" \
        "agent=${AGENT_TYPE}" \
        "reason=${_quality_review_receipt_failure}" 2>/dev/null || true
      log_hook "record-reviewer" \
        "retained excellence call after receipt rejection: ${_quality_review_receipt_failure}"
      _quality_review_retry_context="The Definition review could not be accepted because one or more verification receipt references were missing, stale, reused, bound to the wrong criterion, matched more than one criterion, shared the same proof identity, or attempted to clear an open frontier without causally newer distinct proof for every affected criterion. The causal reviewer call is retained. Re-read the current contract, open frontier, and verification receipt ledger; run the frontier experiment/remediation as needed, then cite exactly one distinct current vr-* receipt per criterion that uniquely matches that criterion's tool, target, outcome, and proof anchor before returning the complete QUALITY_REVIEW_JSON and final VERDICT again."
      jq -nc --arg ctx "$(truncate_chars 1200 "${_quality_review_retry_context}")" \
        '{hookSpecificOutput:{hookEventName:"SubagentStop",additionalContext:$ctx}}'
      exit 0
    fi
    exit "${_quality_review_commit_rc}"
  fi
elif [[ "${REVIEWER_TYPE}" == "prose" ]]; then
  # Editor-critic satisfies only the document-review clock. In mixed work it
  # cannot make a still-missing quality-reviewer appear to have run.
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "prose" \
    "last_doc_review_ts" "${now_ts}" \
    "doc_review_had_findings" "${has_findings}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "stress_test" ]]; then
  # last_metis_review_ts is consumed by the plan-phase Metis gate. It is
  # deliberately isolated from implementation-review state.
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "stress_test" \
    "last_metis_review_ts" "${now_ts}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "traceability" ]]; then
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "traceability" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "design_quality" ]]; then
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "design_quality" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
else
  # Only a standard quality review owns the generic code-review state.
  with_state_lock _commit_reviewer_transaction_unlocked "${dimension_verdict}" "bug_hunt,code_quality" \
    "last_review_ts" "${now_ts}" \
    "review_had_findings" "${has_findings}" \
    "review_format_issue" "${review_format_issue}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
fi

if [[ "${_review_commit_accepted:-0}" -ne 1 ]]; then
  log_hook "record-reviewer" \
    "discarded ${REVIEWER_TYPE} result reason=${_review_rejection_reason:-unknown} start_revision=${_review_rejection_start:-missing} current_revision=${_review_rejection_current:-missing}"
  record_gate_event "reviewer" "stale-result-rejected" \
    "type=${REVIEWER_TYPE}" \
    "agent_id=${_review_native_agent_id}" \
    "reason=${_review_rejection_reason:-unknown}" \
    "start_revision=${_review_rejection_start:-}" \
    "current_revision=${_review_rejection_current:-}" \
    2>/dev/null || true
  exit 0
fi

if [[ "${REVIEWER_TYPE}" == "excellence" \
    && -n "${_quality_review_frontier_event:-}" ]]; then
  record_gate_event "definition-of-excellent/frontier" \
    "${_quality_review_frontier_event}" \
    "contract_id=${_quality_review_frontier_contract_id}" \
    "contract_revision=${_quality_review_frontier_contract_revision}" \
    "cycle=${_quality_review_frontier_cycle}" \
    "status=${_quality_review_frontier_status}" \
    "materiality=${_quality_review_frontier_materiality}" \
    2>/dev/null || true
fi

# Keep bounded, structured evidence for reporting and future role-aware
# consumers. quality-reviewer currently has the explicit remediation contract:
# it may read its newest same-role row on re-dispatch, prove each prior finding
# fixed, and focus on the remediation hunks before widening when contracts or
# surfaces changed. Other reviewers (especially prose-native editor-critic) are
# not instructed to consume this sidecar. History never ticks a dimension.
_review_history_findings="[]"
if [[ -n "${review_message}" ]]; then
  _review_history_rows="$(extract_findings_json "${review_message}" 2>/dev/null || true)"
  if [[ -n "${_review_history_rows}" ]]; then
    _review_history_findings="$(printf '%s\n' "${_review_history_rows}" | jq -sc '.')"
  fi
fi
_review_history_revision="$(jq -r \
  '.review_revision // .code_revision // .edit_revision // 0' \
  <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
[[ "${_review_history_revision}" =~ ^[0-9]+$ ]] || _review_history_revision=0
_review_history_objective_ts="$(jq -r '.objective_prompt_ts // 0' \
  <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
[[ "${_review_history_objective_ts}" =~ ^[0-9]+$ ]] || _review_history_objective_ts=0
_review_history_objective_revision="$(jq -r '.objective_prompt_revision // 0' \
  <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
[[ "${_review_history_objective_revision}" =~ ^[0-9]+$ ]] \
  || _review_history_objective_revision=0
_review_history_cycle_id="$(jq -r '.objective_cycle_id // 0' \
  <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
[[ "${_review_history_cycle_id}" =~ ^[0-9]+$ ]] || _review_history_cycle_id=0
_review_history_entry="$(jq -nc \
  --argjson ts "${now_ts}" \
  --argjson objective_prompt_ts "${_review_history_objective_ts}" \
  --argjson objective_prompt_revision "${_review_history_objective_revision}" \
  --argjson objective_cycle_id "${_review_history_cycle_id}" \
  --arg reviewer_type "${REVIEWER_TYPE}" \
  --arg agent_type "${AGENT_TYPE}" \
  --arg verdict "${dimension_verdict}" \
  --argjson revision "${_review_history_revision}" \
  --argjson findings "${_review_history_findings}" \
  '{ts:$ts,objective_prompt_ts:$objective_prompt_ts,
    objective_prompt_revision:$objective_prompt_revision,
    objective_cycle_id:$objective_cycle_id,
    reviewer_type:$reviewer_type,agent_type:$agent_type,
    verdict:$verdict,revision:$revision,findings:$findings}')"
_append_review_history_unlocked() {
  append_limited_state "review_history.jsonl" "${_review_history_entry}" "32"
}
with_state_lock _append_review_history_unlocked || \
  log_hook "record-reviewer" "review history append failed type=${REVIEWER_TYPE}"

# --- Agent performance metric recording ---
# Verdict only (v1.48 W3.5): the old third argument was a fabricated
# confidence (hardcoded 60/80) that made agent-metrics' avg_confidence
# read as measured signal when it never was. Clean-rate is the real data.
metric_verdict="findings"
if [[ "${has_findings}" == "false" ]]; then
  metric_verdict="clean"
fi
record_agent_metric "${REVIEWER_TYPE}" "${metric_verdict}" &

# --- Cross-session defect pattern recording ---
# When findings are detected, extract a *structured* finding bullet and
# classify the defect category. Extraction is strict by design: reviewer
# narration prose (e.g. "I have a clear picture now. Let me compile…") has
# historically polluted the defect tracker by matching on incidental words
# like "test" or "security" that appear in intro sentences. If we cannot
# find a structured finding line we skip classification entirely — the
# verdict-level metric (recorded above) still captures that findings
# happened. Noise-free cross-session signal beats volume.
if [[ "${has_findings}" == "true" && -n "${review_message}" ]]; then
  # v1.32.0 Wave B: prefer the structured FINDINGS_JSON contract — the
  # agent's own category claim is more accurate than re-deriving from
  # prose, and the file field gives us a deterministic surface tag.
  # When an agent doesn't emit FINDINGS_JSON (older agents, prose-only
  # paths) fall back to the legacy structural-marker grep + classifier.
  json_rows="$(extract_findings_json "${review_message}" 2>/dev/null | head -n 10 || true)"

  if [[ -n "${json_rows}" ]]; then
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      # No `local` here — record-reviewer.sh runs as a script, not a function.
      row_file="$(printf '%s' "${row}" | jq -r '.file // ""' 2>/dev/null || echo "")"
      row_cat="$(printf '%s' "${row}" | jq -r '.category // ""' 2>/dev/null || echo "")"
      row_claim="$(printf '%s' "${row}" | jq -r '.claim // ""' 2>/dev/null || echo "")"
      pair="$(classify_finding_pair "${row_file}" "${row_cat}" "${row_claim}")"
      example="${row_claim:-${row_file}}"
      [[ -z "${example}" ]] && example="(no claim provided)"
      record_defect_pattern "${pair}" "${example}" &
    done <<<"${json_rows}"
  else
    # Legacy fallback path. Structural finding markers accepted:
    #   - numbered items: "1.", "1)", "1:", or "**1." with optional bold
    #   - bulleted items whose content starts with a bold label like "- **X**"
    #   - bulleted items keyed on an issue keyword near the marker
    #   - H3/H4 headings that name a finding (e.g. "### Finding 1:" or "#### Bug:").
    #     H2 is excluded: reviewers commonly use "## Findings" as a section divider,
    #     which is narration, not a specific finding. H3/H4 is typically per-item.
    finding_sample="$(printf '%s\n' "${review_message}" \
      | grep -Eim 1 '^[[:space:]]*(\*\*[[:space:]]*)?[0-9]+[[:space:]]*[\.\):]|^[[:space:]]*[-*][[:space:]]+\*\*|^[[:space:]]*[-*][[:space:]]+(bug|issue|finding|problem|concern|defect|risk|error|missing|vulnerab|uncaught|untested|fail|broken|unhandled)|^[[:space:]]*#{3,4}[[:space:]]+(finding|issue|bug|problem|concern|defect|risk)\b' \
      | head -c 200 || true)"
    if [[ -n "${finding_sample}" ]]; then
      # No file context — surface defaults to "other" via empty arg.
      pair="$(classify_finding_pair "" "" "${finding_sample}")"
      record_defect_pattern "${pair}" "${finding_sample}" &
    fi
  fi
fi

# v1.42.x SRE F-001: wait for the fire-and-forget telemetry writers
# (record_agent_metric, record_defect_pattern) to complete before the
# hook returns. record-reviewer.sh runs under PostToolUse / SubagentStop
# and Claude Code reaps the process group when the parent script exits.
# Without an explicit wait, the backgrounded `&` children can be
# SIGHUPed mid-`mv` of their atomic temp file — leaking .XXXXXX files
# and silently dropping cross-session telemetry rows. The metric and
# defect-pattern writers are quick (a single jq + atomic write each);
# `wait` adds only the longest-child latency, not their sum.
wait 2>/dev/null || true
