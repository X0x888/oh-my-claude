#!/usr/bin/env bash

set -euo pipefail

_OMC_HOOK_CALLER_PATH="${PATH:-}"
# Recovery is an internal lifecycle mode, so parse it before the ordinary
# global ULW sentinel fast-path. A missing/stale sentinel must never turn an
# existing fixed WAL into a false-success recovery.
_reviewer_recover_active_mode=0
_reviewer_recover_active_session=""
if [[ "${1:-}" == "--recover-active" ]]; then
  _reviewer_recover_active_mode=1
  _reviewer_recover_active_session="${2:-}"
  REVIEWER_TYPE="standard"
else
  REVIEWER_TYPE="${1:-standard}"
fi

# Fast-path: ordinary hook delivery is irrelevant if ULW was never activated.
if [[ "${_reviewer_recover_active_mode}" -eq 0 ]]; then
  [[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0
fi

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
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
unset OMC_PUBLICATION_RECOVERY_INTERNAL
if [[ "${_reviewer_recover_active_mode}" -eq 1 ]]; then
  HOOK_JSON='{}'
  SESSION_ID="${_reviewer_recover_active_session}"
  AGENT_TYPE=""
  _review_native_agent_id_raw=""
else
  HOOK_JSON="$(_omc_read_hook_stdin)"
  SESSION_ID="$(json_get '.session_id')"
  AGENT_TYPE="$(json_get '.agent_type')"
  _review_native_agent_id_raw="$(json_get '.agent_id')"
fi
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
  [[ "${_reviewer_recover_active_mode}" -eq 0 ]] || exit 1
  exit 0
fi
if [[ "${_reviewer_recover_active_mode}" -eq 1 ]] \
    && ! validate_session_id "${SESSION_ID}"; then
  exit 1
fi
if omc_interrupted_dispatch_transaction_present "${SESSION_ID}"; then
  [[ "${_reviewer_recover_active_mode}" -eq 0 ]] && exit 0
  exit 1
fi

ensure_session_dir

_reviewer_active_wal="$(session_file ".reviewer-transaction.wal")"

# Admission needs only the WAL owner coordinates, but even that projection
# must be rejected before Bash can normalize decoded NUL. The full transaction
# validator below remains the publication authority; this narrow early check
# exists because ordinary callback admission runs before those function
# definitions are installed by the shell.
_reviewer_admission_manifest_owner_safe() {
  local manifest="${1:-}"
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  [[ "$(wc -c <"${manifest}" 2>/dev/null || printf 0)" -le 262144 ]] \
    || return 1
  jq -e '
    type == "object"
    and all(.. | strings; index("\u0000") == null)
    and (.agent_type | type == "string"
      and test("^[A-Za-z0-9_.:-]{1,128}$"))
    and (.native_agent_id | type == "string"
      and test("^$|^[A-Za-z0-9._:-]{1,128}$"))
  ' "${manifest}" >/dev/null 2>&1
}

if [[ "${_reviewer_recover_active_mode}" -eq 1 ]]; then
  # With no fixed WAL, recovery may still settle a receipt-bound summary
  # waiter left by death after the receipt/WAL retirement boundary. If a WAL
  # does exist, however, inactive authority is not permission to ignore it.
  if { [[ -e "${_reviewer_active_wal}" ]] || [[ -L "${_reviewer_active_wal}" ]]; } \
      && ! is_ultrawork_mode; then
    exit 1
  fi
else
  # In the summary-first hook order the universal publisher may already have
  # committed its effects while retaining the exact pending claim until this
  # dedicated reviewer publishes the authoritative receipt.  Bind the narrow
  # process-local fence token only for one effects-complete row whose role,
  # native ID, and redacted message digest all match this callback.  A stale,
  # ambiguous, incomplete, or foreign claim therefore remains fenced.
  _reviewer_preexisting_claim_id=""
  _reviewer_preexisting_pending="$(session_file "pending_agents.jsonl")"
  _reviewer_preexisting_agent="${AGENT_TYPE}"
  if [[ -z "${_reviewer_preexisting_agent}" ]]; then
    case "${REVIEWER_TYPE}" in
      excellence) _reviewer_preexisting_agent="excellence-reviewer" ;;
      prose) _reviewer_preexisting_agent="editor-critic" ;;
      stress_test) _reviewer_preexisting_agent="metis" ;;
      traceability) _reviewer_preexisting_agent="briefing-analyst" ;;
      design_quality) _reviewer_preexisting_agent="design-reviewer" ;;
      release) _reviewer_preexisting_agent="release-reviewer" ;;
      *) _reviewer_preexisting_agent="quality-reviewer" ;;
    esac
  fi
  _reviewer_preexisting_message="$(json_get '.last_assistant_message')"
  if [[ -n "${_review_native_agent_id}" \
      && -f "${_reviewer_preexisting_pending}" \
      && ! -L "${_reviewer_preexisting_pending}" ]] \
      && omc_dispatch_authority_ledger_shell_safe \
        "${_reviewer_preexisting_pending}"; then
    _reviewer_preexisting_digest="$(_omc_token_digest \
      "$(printf '%s' "${_reviewer_preexisting_message}" \
        | omc_redact_secrets | tr -d '\000')" 2>/dev/null || true)"
    if [[ "${_reviewer_preexisting_digest}" \
        =~ ^[A-Fa-f0-9]{16,128}$ ]]; then
      _reviewer_preexisting_claim_id="$(jq -Rsr \
        --arg agent "${_reviewer_preexisting_agent}" \
        --arg native "${_review_native_agent_id}" \
        --arg digest "${_reviewer_preexisting_digest}" '
          [split("\n")[] | select(length > 0)
            | (try fromjson catch null) | select(type == "object")
            | select(.agent_type == $agent
              and .native_agent_id == $native
              and (.completion_claim_digest // "") == $digest
              and (.completion_claim_effects_complete // false) == true
              and (.review_dispatch_abandoned // false) != true)
            | .completion_claim_id] as $matches
          | if ($matches | length) == 1 then $matches[0] else "" end
        ' "${_reviewer_preexisting_pending}" 2>/dev/null || true)"
      if [[ "${_reviewer_preexisting_claim_id}" \
          =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]]; then
        OMC_PUBLICATION_DEDICATED_CLAIM_ID="${_reviewer_preexisting_claim_id}"
      fi
    fi
  fi

  # Another publisher may have died before this ordinary reviewer callback
  # began. Settle both fixed journals before verdict, Definition, or generation
  # validation reads their covered artifacts. If the recovered reviewer WAL
  # belongs to this exact callback, recovery already completed it and this
  # duplicate delivery must stop; a distinct native sibling may continue only
  # after both fixed names are proven absent.
  _reviewer_admission_had_wal=0
  _reviewer_admission_owner_agent=""
  _reviewer_admission_owner_native=""
  if [[ -e "${_reviewer_active_wal}" || -L "${_reviewer_active_wal}" ]]; then
    _reviewer_admission_had_wal=1
    if [[ -d "${_reviewer_active_wal}" \
        && ! -L "${_reviewer_active_wal}" \
        && -f "${_reviewer_active_wal}/manifest.json" \
        && ! -L "${_reviewer_active_wal}/manifest.json" ]] \
        && _reviewer_admission_manifest_owner_safe \
          "${_reviewer_active_wal}/manifest.json"; then
      _reviewer_admission_owner_agent="$(jq -r '.agent_type // empty' \
        "${_reviewer_active_wal}/manifest.json" 2>/dev/null || true)"
      _reviewer_admission_owner_native="$(jq -r '.native_agent_id // empty' \
        "${_reviewer_active_wal}/manifest.json" 2>/dev/null || true)"
    fi
  fi
  # Internal callers have already crossed this entry recovery barrier. They
  # still fail closed on either fixed WAL below, but must not recursively
  # reinterpret a waiter+receipt pair that appeared after their barrier and
  # before publication-lock acquisition. The receipt stager re-reads that
  # waiter authority under the lock.
  if ! omc_recover_active_publication_transactions "${SESSION_ID}"; then
    log_anomaly "record-reviewer" \
      "publication recovery barrier failed before reviewer validation" \
      2>/dev/null || true
    # Ordinary SubagentStop recorders reject stale, malformed, or otherwise
    # unauthorised returns silently.  Recovery failure grants no publication
    # capability and must preserve that hook contract: a non-zero recorder
    # exit would turn an inert corrupt sibling ledger into a platform-visible
    # subagent failure even though no state was accepted.  The explicit
    # --recover-active entry point remains fail-closed/non-zero above.
    exit 0
  fi
  if [[ -e "${_reviewer_active_wal}" || -L "${_reviewer_active_wal}" \
      || -e "$(session_file ".plan-txn.active")" \
      || -L "$(session_file ".plan-txn.active")" ]]; then
    exit 0
  fi
  if [[ "${_reviewer_admission_had_wal}" -eq 1 ]]; then
    if [[ -z "${_reviewer_admission_owner_native}" ]] \
        || { [[ "${_reviewer_admission_owner_agent}" == "${AGENT_TYPE}" ]] \
          && [[ "${_reviewer_admission_owner_native}" == "${_review_native_agent_id}" ]]; }; then
      exit 0
    fi
  fi
  if ! is_ultrawork_mode; then
    exit 0
  fi
  capture_ulw_enforcement_interval || exit 0
fi

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
if [[ "${_reviewer_recover_active_mode}" -eq 0 \
    && -n "${_review_enforced_contract_kind}" ]] \
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
if [[ "${_reviewer_recover_active_mode}" -eq 0 \
    && "${REVIEWER_TYPE}" == "excellence" \
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

_review_legacy_agent_identity_matches() {
  [[ "$1" == "$2" ]] && return 0
  # Compatibility for a pre-native external code-reviewer start recorded
  # before its provider namespace was available. Do not generalize this to
  # arbitrary matching basenames: custom:quality-reviewer is not a configured
  # publisher and cannot authorize the bundled quality-reviewer hook.
  case "$1:$2" in
    code-reviewer:superpowers:code-reviewer|code-reviewer:feature-dev:code-reviewer|superpowers:code-reviewer:code-reviewer|feature-dev:code-reviewer:code-reviewer)
      return 0 ;;
    *) return 1 ;;
  esac
}

_select_reviewer_dispatch_start_unlocked() {
  local starts_file line this_type row_id row_native_id selected=""
  local row_lifecycle selected_count=0
  local binding_json="" binding_kind="" binding_lifecycle=""
  local binding_review_id="" binding_cycle=0 candidate=0
  starts_file="$(session_file "agent_dispatch_starts.jsonl")"
  _review_dispatch_start_json=""
  _review_dispatch_pending_json=""
  _review_use_native_agent_id=0
  _review_native_binding_committed=0
  _review_native_binding_json=""
  _review_native_tracking_version="$(read_state "native_agent_id_tracking_version")"
  [[ "${_review_native_agent_id_invalid}" -eq 0 ]] || return 0
  if [[ "${_review_native_agent_id_present}" -eq 1 \
      && "${_review_native_agent_id_invalid}" -eq 0 ]]; then
    local bindings_file
    bindings_file="$(session_file "native_agent_bindings.jsonl")"
    if [[ ! -L "${bindings_file}" && -f "${bindings_file}" ]] \
        && binding_json="$(jq -Rsc --arg id "${_review_native_agent_id}" \
          --arg type "${AGENT_TYPE}" \
          --arg current "${_review_native_tracking_version}" '
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
      _review_native_binding_committed=1
      _review_native_binding_json="${binding_json}"
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
  if [[ "${_review_use_native_agent_id}" -eq 1 ]]; then
    binding_kind="$(jq -r '.binding_kind' \
      <<<"${_review_native_binding_json}")" || return 1
    if [[ "${binding_kind}" == "current" ]]; then
      binding_lifecycle="$(jq -r '.lifecycle_dispatch_id' \
        <<<"${_review_native_binding_json}")" || return 1
      binding_review_id="$(jq -r '.review_dispatch_id // ""' \
        <<<"${_review_native_binding_json}")" || return 1
      binding_cycle="$(jq -r '.objective_cycle_id' \
        <<<"${_review_native_binding_json}")" || return 1
    fi
  fi
  [[ ! -L "${starts_file}" ]] \
    && { [[ ! -e "${starts_file}" ]] || [[ -f "${starts_file}" ]]; } \
    || return 1
  [[ -f "${starts_file}" ]] || return 0
  omc_dispatch_authority_ledger_shell_safe "${starts_file}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
      if [[ "${binding_kind}" == "current" ]] \
          && { [[ "${line}" == *"${_review_native_agent_id}"* ]] \
            || [[ "${line}" == *"${binding_lifecycle}"* ]] \
            || { [[ -n "${binding_review_id}" ]] \
              && [[ "${line}" == *"${binding_review_id}"* ]]; }; }; then
        return 1
      fi
      continue
    fi
    this_type="$(jq -r '.agent_type // empty' <<<"${line}" 2>/dev/null || true)"
    row_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    candidate=0
    if [[ "${_review_use_native_agent_id}" -eq 1 \
        && "${binding_kind}" == "current" ]] \
        && { [[ "${row_native_id}" == "${_review_native_agent_id}" ]] \
          || [[ "${row_lifecycle}" == "${binding_lifecycle}" ]] \
          || { [[ -n "${binding_review_id}" ]] \
            && [[ "${row_id}" == "${binding_review_id}" ]] \
            && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; }; then
      candidate=1
      jq -e --arg native "${_review_native_agent_id}" \
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
          ' <<<"${line}" >/dev/null 2>&1 || return 1
    elif [[ "${_review_use_native_agent_id}" -eq 1 \
        && "${binding_kind}" == "legacy" \
        && "${row_native_id}" == "${_review_native_agent_id}" ]]; then
      candidate=1
      jq -e --arg native "${_review_native_agent_id}" \
          --arg type "${AGENT_TYPE}" '
            type == "object"
            and (.native_agent_id // "") == $native
            and (.agent_type // "") == $type
            and (has("lifecycle_dispatch_id") | not)
          ' <<<"${line}" >/dev/null 2>&1 || return 1
    fi
    if [[ "${candidate}" -eq 1 ]] \
        || { [[ "${_review_use_native_agent_id}" -eq 0 ]] \
          && [[ -n "${_review_dispatch_id}" ]] \
          && [[ "${row_id}" == "${_review_dispatch_id}" ]] \
          && [[ -z "${row_native_id}" ]] \
          && _review_legacy_agent_identity_matches \
            "${this_type}" "${AGENT_TYPE}"; } \
        || { [[ "${_review_use_native_agent_id}" -eq 0 ]] \
             && [[ -z "${_review_dispatch_id}" ]] \
             && [[ -z "${row_id}" ]] \
             && [[ -z "${row_native_id}" ]] \
             && [[ "${this_type}" == "${AGENT_TYPE}" ]]; }; then
      selected_count=$((selected_count + 1))
      selected="${line}"
    fi
  done <"${starts_file}"
  # A binding must name one exact lifecycle. First-match consumption would
  # make an ambiguous ledger order-dependent and replayable.
  [[ "${selected_count}" -le 1 ]] || return 1
  if [[ "${selected_count}" -eq 1 ]]; then
    _review_dispatch_start_json="${selected}"
    # Migration compatibility: an in-flight session created before the
    # receipt/waiter rendezvous may have finished universal effects first and
    # retained an effects-complete pending claim. Current summary-first returns
    # have no claim here; they wait for the dedicated receipt and replay later.
    local pending_file pending_line pending_type pending_id pending_native_id
    local pending_lifecycle pending_candidate
    local wanted_id wanted_native_id wanted_agent selected_pending=""
    local selected_pending_count=0
    pending_file="$(session_file "pending_agents.jsonl")"
    [[ ! -L "${pending_file}" ]] \
      && { [[ ! -e "${pending_file}" ]] || [[ -f "${pending_file}" ]]; } \
      || return 1
    omc_dispatch_authority_ledger_shell_safe "${pending_file}" || return 1
    wanted_id="$(jq -r '.review_dispatch_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    wanted_agent="$(jq -r '.agent_type // empty' \
      <<<"${selected}" 2>/dev/null || true)"
    if [[ -s "${pending_file}" ]]; then
      while IFS= read -r pending_line || [[ -n "${pending_line}" ]]; do
        [[ -n "${pending_line}" ]] || continue
        if ! jq -e 'type == "object"' \
            <<<"${pending_line}" >/dev/null 2>&1; then
          if [[ "${binding_kind}" == "current" ]] \
              && { [[ "${pending_line}" == *"${_review_native_agent_id}"* ]] \
                || [[ "${pending_line}" == *"${binding_lifecycle}"* ]] \
                || { [[ -n "${binding_review_id}" ]] \
                  && [[ "${pending_line}" == *"${binding_review_id}"* ]]; }; }; then
            return 1
          fi
          continue
        fi
        pending_type="$(jq -r '.agent_type // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_id="$(jq -r '.review_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_native_id="$(jq -r '.native_agent_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
          <<<"${pending_line}" 2>/dev/null || true)"
        pending_candidate=0
        if [[ "${binding_kind}" == "current" ]] \
            && { [[ "${pending_native_id}" == "${_review_native_agent_id}" ]] \
              || [[ "${pending_lifecycle}" == "${binding_lifecycle}" ]] \
              || { [[ -n "${binding_review_id}" ]] \
                && [[ "${pending_id}" == "${binding_review_id}" ]] \
                && [[ "${pending_type}" == "${AGENT_TYPE}" ]]; }; }; then
          pending_candidate=1
          jq -e --arg native "${_review_native_agent_id}" \
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
              ' <<<"${pending_line}" >/dev/null 2>&1 || return 1
          jq -e --argjson start "${selected}" '
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
                   (.ulw_enforcement_generation // "migration"),
                 review_dispatch_causality_version:
                   (.review_dispatch_causality_version // 0),
                 review_batch_id:(.review_batch_id // ""),
                 quality_contract_id:(.quality_contract_id // ""),
                 quality_contract_revision:
                   (.quality_contract_revision // 0),
                 purpose:(.purpose // ""),
                 council_phase:(.council_phase // ""),
                 council_selection_agent:
                   (.council_selection_agent // ""),
                 council_objective_prompt_ts:
                   (.council_objective_prompt_ts // 0),
                 council_objective_prompt_revision:
                   (.council_objective_prompt_revision // 0),
                 council_ledger_generation:
                   (.council_ledger_generation // 0)};
              frozen == ($start | frozen)
            ' <<<"${pending_line}" >/dev/null 2>&1 || return 1
        elif [[ "${binding_kind}" == "legacy" \
            && "${pending_native_id}" == "${_review_native_agent_id}" ]]; then
          pending_candidate=1
          jq -e --arg native "${_review_native_agent_id}" \
              --arg type "${AGENT_TYPE}" '
                type == "object"
                and (.native_agent_id // "") == $native
                and (.agent_type // "") == $type
                and (has("lifecycle_dispatch_id") | not)
              ' <<<"${pending_line}" >/dev/null 2>&1 || return 1
        elif [[ "${_review_use_native_agent_id}" -eq 0 \
            && "${pending_type}" == "${wanted_agent}" ]] \
            && { { [[ -n "${wanted_id}" ]] \
                   && [[ "${pending_id}" == "${wanted_id}" ]] \
                   && [[ -z "${pending_native_id}" ]]; } \
              || { [[ -z "${wanted_id}" ]] \
                   && [[ -z "${pending_id}" \
                         && -z "${pending_native_id}" ]]; }; }; then
          pending_candidate=1
        fi
        if [[ "${pending_candidate}" -eq 1 ]]; then
          selected_pending_count=$((selected_pending_count + 1))
        fi
        if [[ "${pending_candidate}" -eq 1 ]] \
            && { { [[ -n "${wanted_native_id}" ]] \
                   && [[ "${pending_native_id}" == "${wanted_native_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -n "${wanted_id}" ]] \
                   && [[ "${pending_id}" == "${wanted_id}" ]]; } \
                 || { [[ -z "${wanted_native_id}" && -z "${wanted_id}" ]] \
                      && [[ -z "${pending_native_id}" \
                            && -z "${pending_id}" ]]; }; } \
            && [[ "$(jq -r '.completion_claim_effects_complete // false' \
              <<<"${pending_line}" 2>/dev/null || true)" == "true" ]]; then
          selected_pending="${pending_line}"
        fi
      done <"${pending_file}"
      if [[ "${binding_kind}" == "current" ]]; then
        [[ "${selected_pending_count}" -eq 1 ]] || return 1
      else
        [[ "${selected_pending_count}" -le 1 ]] || return 1
      fi
      _review_dispatch_pending_json="${selected_pending}"
    fi
    if [[ "${binding_kind}" == "current" \
        && "${selected_pending_count}" -ne 1 ]]; then
      return 1
    fi
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

# Reviewer completion is a multi-artifact authority transfer: one exact
# lifecycle start (plus any pre-rendezvous migration claim) is consumed while
# reviewer state and optional Definition evidence are published. A durable
# roll-forward journal makes that transfer idempotent
# across write errors and SIGKILL. The journal is deliberately single-flight
# per session; multiple or malformed journals fail closed instead of guessing
# an order between reviewer lifecycles.
_reviewer_transaction_wal_dir() {
  session_file ".reviewer-transaction.wal"
}

_reviewer_transaction_committed_prefix() {
  session_file ".reviewer-transaction.committed."
}

# Once the fixed WAL has been renamed to this inert prefix, its receipt and
# every preceding publication are committed. Cleanup must tolerate a prior
# process dying after deleting any subset of the known files, while refusing
# to broaden deletion to an unexpected or non-regular entry.
_remove_reviewer_committed_dir_unlocked() {
  local dir="${1:-}" prefix suffix entry name retry_temp
  prefix="$(_reviewer_transaction_committed_prefix)"
  [[ -n "${dir}" && "${dir}" == "${prefix}"* ]] || return 1
  suffix="${dir#"${prefix}"}"
  [[ "${suffix}" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  [[ -d "${dir}" && ! -L "${dir}" ]] || return 1
  for entry in "${dir}"/* "${dir}"/.[!.]* "${dir}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    [[ -f "${entry}" && ! -L "${entry}" ]] || return 1
    name="${entry##*/}"
    case "${name}" in
      manifest.json|after-quality_evidence.jsonl|after-quality_frontier.json|after-quality_frontier_history.jsonl|after-reviewer_publication_outcomes.jsonl|.summary-retry-count) ;;
      .summary-retry-count.*)
        [[ "${name}" =~ ^\.summary-retry-count\.[A-Za-z0-9]{6,64}$ ]] \
          || return 1
        ;;
      *) return 1 ;;
    esac
  done
  for retry_temp in "${dir}"/.summary-retry-count.*; do
    [[ -e "${retry_temp}" || -L "${retry_temp}" ]] || continue
    name="${retry_temp##*/}"
    [[ "${name}" =~ ^\.summary-retry-count\.[A-Za-z0-9]{6,64}$ \
        && -f "${retry_temp}" && ! -L "${retry_temp}" ]] || return 1
    rm -f -- "${retry_temp}" || return 1
  done
  rm -f -- \
    "${dir}/manifest.json" \
    "${dir}/after-quality_evidence.jsonl" \
    "${dir}/after-quality_frontier.json" \
    "${dir}/after-quality_frontier_history.jsonl" \
    "${dir}/after-reviewer_publication_outcomes.jsonl" \
    "${dir}/.summary-retry-count" \
    || return 1
  rmdir "${dir}"
}

_cleanup_reviewer_committed_dirs_unlocked() {
  local prefix committed_dir
  prefix="$(_reviewer_transaction_committed_prefix)"
  for committed_dir in "${prefix}"*; do
    [[ -e "${committed_dir}" || -L "${committed_dir}" ]] || continue
    _remove_reviewer_committed_dir_unlocked "${committed_dir}" || return 1
  done
}

_reviewer_transaction_boundary() {
  local boundary="${1:-}"
  if [[ "${OMC_TEST_REVIEWER_TXN_FAIL_AT:-}" == "${boundary}" ]]; then
    return 1
  fi
  if [[ "${OMC_TEST_REVIEWER_TXN_KILL_AT:-}" == "${boundary}" ]]; then
    kill -KILL "$$"
    return 1
  fi
}

_reviewer_state_patch_from_args() {
  local patch='{}' key value
  [[ $(( $# % 2 )) -eq 0 ]] || return 1
  while [[ $# -ge 2 ]]; do
    key="$1"
    value="$2"
    shift 2
    [[ -n "${key}" ]] || return 1
    patch="$(jq -c --arg key "${key}" --arg value "${value}" \
      '.[$key] = $value' <<<"${patch}")" || return 1
  done
  printf '%s' "${patch}"
}

_reviewer_state_before_patch_unlocked() {
  local patch="${1:-}" state_file
  jq -e 'type == "object"' <<<"${patch}" >/dev/null 2>&1 || return 1
  state_file="$(session_file "${STATE_JSON}")"
  [[ ! -L "${state_file}" ]] || return 1
  _ensure_valid_state
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
  jq -c --argjson patch "${patch}" '
    . as $state
    | reduce ($patch | keys[]) as $key ({};
        .[$key] = if ($state | has($key))
          then {present:true,value:$state[$key]}
          else {present:false}
        end)
  ' "${state_file}"
}

_reviewer_atomic_copy_file() {
  local source="${1:-}" target="${2:-}" temp
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  [[ ! -L "${target}" ]] || return 1
  [[ ! -e "${target}" || -f "${target}" ]] || return 1
  temp="$(mktemp "${target}.reviewer.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || true
  if ! cp "${source}" "${temp}" || ! mv -f "${temp}" "${target}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
}

_reviewer_transaction_manifest_valid() {
  local wal="${1:-}" manifest lifecycle
  [[ -d "${wal}" && ! -L "${wal}" ]] || return 1
  manifest="${wal}/manifest.json"
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
  [[ "$(wc -c <"${manifest}" 2>/dev/null || printf 0)" -le 262144 ]] || return 1
  jq -e '
    . as $manifest
    | type == "object"
    and all(.. | strings; index("\u0000") == null)
    and (keys | sort == ["_v","agent_type","artifacts","frontier_event",
      "history_line","lifecycle_dispatch_id","native_agent_id","outcome",
      "pending_line","rejection","reviewer_type","start_line",
      "state_after","state_before"])
    and ._v == 1
    and (.lifecycle_dispatch_id | type == "string"
      and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.reviewer_type | type == "string"
      and IN("standard","excellence","prose","stress_test",
        "traceability","design_quality","release"))
    and (.agent_type | type == "string"
      and test("^[A-Za-z0-9_.:-]{1,128}$"))
    and (.native_agent_id | type == "string"
      and test("^$|^[A-Za-z0-9._:-]{1,128}$"))
    and (.outcome == "accepted" or .outcome == "rejected")
    and (.start_line | type == "string" and length > 1 and length <= 131072
      and (test("[\u0000-\u001f\u007f]") | not))
    and (.pending_line | type == "string" and length <= 131072
      and (test("[\u0000-\u001f\u007f]") | not))
    and (.state_after | type == "object")
    and (.state_before | type == "object")
    and ((.state_after | keys | sort) == (.state_before | keys | sort))
    and all(.state_after[]; type == "string")
    and all(.state_before[];
      type == "object"
      and ((.present == true and (keys | sort == ["present","value"]))
        or (.present == false and (keys == ["present"]))))
    and (.artifacts | type == "array" and length <= 4)
    and (([.artifacts[].name] | unique | length)
      == ($manifest.artifacts | length))
    and all(.artifacts[];
      type == "object"
      and (keys | sort == ["after_sha","before_kind","before_sha","name"])
      and (.name == "quality_evidence.jsonl"
        or .name == "quality_frontier.json"
        or .name == "quality_frontier_history.jsonl"
        or .name == "reviewer_publication_outcomes.jsonl")
      and (.before_kind == "absent" or .before_kind == "file")
      and (.before_sha | type == "string")
      and (.after_sha | type == "string" and test("^[0-9a-f]{64}$"))
      and (if .before_kind == "file"
        then (.before_sha | test("^[0-9a-f]{64}$"))
        else .before_sha == ""
        end))
    and (.history_line | type == "string" and length <= 131072
      and (test("[\u0000-\u001f\u007f]") | not))
    and (.rejection | type == "object")
    and (.frontier_event | type == "object")
    and ((.start_line | fromjson | type) == "object")
    and ((.start_line | fromjson | .lifecycle_dispatch_id // "")
      == $manifest.lifecycle_dispatch_id)
    and ((.start_line | fromjson | .agent_type // "")
      == $manifest.agent_type)
    and (.pending_line == "" or
      (((.pending_line | fromjson | type) == "object")
       and ((.pending_line | fromjson | .lifecycle_dispatch_id // "")
         == $manifest.lifecycle_dispatch_id)
       and ((.pending_line | fromjson | .completion_claim_effects_complete // false)
         == true)))
    and (if .outcome == "accepted"
      then (.history_line | length > 1)
        and ((.history_line | fromjson | .lifecycle_dispatch_id // "")
          == $manifest.lifecycle_dispatch_id)
      else .history_line == ""
      end)
  ' "${manifest}" >/dev/null 2>&1 || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id' "${manifest}")" || return 1
  [[ -n "${lifecycle}" ]] || return 1
}

_reviewer_transaction_capture_artifact_unlocked() {
  local prepare_dir="${1:-}" name="${2:-}" staged="${3:-}"
  local target before_kind before_sha="" after_sha after_file descriptor
  [[ -d "${prepare_dir}" && ! -L "${prepare_dir}" ]] || return 1
  case "${name}" in
    quality_evidence.jsonl|quality_frontier.json|quality_frontier_history.jsonl|reviewer_publication_outcomes.jsonl) ;;
    *) return 1 ;;
  esac
  [[ -f "${staged}" && ! -L "${staged}" ]] || return 1
  target="$(session_file "${name}")"
  [[ ! -L "${target}" ]] || return 1
  if [[ -f "${target}" ]]; then
    before_kind="file"
    before_sha="$(_omc_digest_file "${target}")" || return 1
  elif [[ ! -e "${target}" ]]; then
    before_kind="absent"
  else
    return 1
  fi
  after_file="${prepare_dir}/after-${name}"
  cp "${staged}" "${after_file}" || return 1
  chmod 600 "${after_file}" 2>/dev/null || true
  after_sha="$(_omc_digest_file "${after_file}")" || return 1
  [[ "${before_sha}" =~ ^[0-9a-f]{64}$ || "${before_kind}" == "absent" ]] || return 1
  [[ "${after_sha}" =~ ^[0-9a-f]{64}$ ]] || return 1
  descriptor="$(jq -cn \
    --arg name "${name}" --arg before_kind "${before_kind}" \
    --arg before_sha "${before_sha}" --arg after_sha "${after_sha}" \
    '{name:$name,before_kind:$before_kind,before_sha:$before_sha,
      after_sha:$after_sha}')" || return 1
  printf '%s' "${descriptor}"
}

_remove_reviewer_prepare_dir_unlocked() {
  local prepare_dir="${1:-}" prefix entry name
  prefix="$(session_file ".reviewer-transaction.prepare.")"
  [[ -n "${prepare_dir}" && "${prepare_dir}" == "${prefix}"* ]] || return 1
  [[ -d "${prepare_dir}" && ! -L "${prepare_dir}" ]] || return 1
  # A prepare directory is not publication authority until its validated
  # manifest is atomically renamed to the fixed WAL name.  Remove only the
  # exact inert files this hook can create; any unexpected entry fails closed
  # instead of broadening cleanup into an unsafe recursive delete.
  for entry in "${prepare_dir}"/*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    [[ -f "${entry}" && ! -L "${entry}" ]] || return 1
    name="${entry##*/}"
    case "${name}" in
      manifest.json|after-quality_evidence.jsonl|after-quality_frontier.json|after-quality_frontier_history.jsonl|after-reviewer_publication_outcomes.jsonl) ;;
      *) return 1 ;;
    esac
  done
  rm -f \
    "${prepare_dir}/manifest.json" \
    "${prepare_dir}/after-quality_evidence.jsonl" \
    "${prepare_dir}/after-quality_frontier.json" \
    "${prepare_dir}/after-quality_frontier_history.jsonl" \
    "${prepare_dir}/after-reviewer_publication_outcomes.jsonl" \
    || return 1
  rmdir "${prepare_dir}"
}

_cleanup_reviewer_prepare_dirs_unlocked() {
  local prefix prepare_dir
  prefix="$(session_file ".reviewer-transaction.prepare.")"
  for prepare_dir in "${prefix}"*; do
    [[ -e "${prepare_dir}" || -L "${prepare_dir}" ]] || continue
    _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" || return 1
  done
}

# Receipt and Definition artifacts are rendered into unique sibling files
# before their bytes are copied into the fixed reviewer WAL. SIGKILL can leave
# those pre-WAL files behind, but they never become publication authority. The
# session mutex proves no live publisher owns an exact candidate here. Validate
# the whole set before unlinking any entry so a forged symlink, directory, or
# malformed internal name fails closed without causing a partial reap.
_cleanup_reviewer_loose_staging_unlocked() {
  local session_dir candidate name candidate_count=0 candidate_index=0
  local -a candidates
  session_dir="$(session_file ".reviewer-transaction.wal")"
  session_dir="${session_dir%/*}"
  for candidate in \
      "$(session_file ".reviewer-publication.stage.")"* \
      "$(session_file "quality_evidence.jsonl.tmp.")"* \
      "$(session_file "quality_frontier.json.tmp.")"* \
      "$(session_file "quality_frontier_history.jsonl.tmp.")"*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    [[ "${candidate%/*}" == "${session_dir}" ]] || return 1
    name="${candidate##*/}"
    case "${name}" in
      .reviewer-publication.stage.*)
        [[ "${name}" \
          =~ ^\.reviewer-publication\.stage\.[A-Za-z0-9]{6}$ ]] \
          || return 1
        ;;
      quality_evidence.jsonl.tmp.*)
        [[ "${name}" \
          =~ ^quality_evidence\.jsonl\.tmp\.[A-Za-z0-9]{6}$ ]] \
          || return 1
        ;;
      quality_frontier.json.tmp.*)
        [[ "${name}" \
          =~ ^quality_frontier\.json\.tmp\.[A-Za-z0-9]{6}$ ]] \
          || return 1
        ;;
      quality_frontier_history.jsonl.tmp.*)
        [[ "${name}" \
          =~ ^quality_frontier_history\.jsonl\.tmp\.[A-Za-z0-9]{6}$ ]] \
          || return 1
        ;;
      *) return 1 ;;
    esac
    [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
    candidates[${candidate_count}]="${candidate}"
    candidate_count=$((candidate_count + 1))
  done
  while (( candidate_index < candidate_count )); do
    rm -f -- "${candidates[${candidate_index}]}" || return 1
    candidate_index=$((candidate_index + 1))
  done
}

_prepare_reviewer_transaction_unlocked() {
  local outcome="${1:-}" state_after="${2:-}" history_line="${3:-}"
  local wal prepare_dir manifest lifecycle state_before artifacts='[]' descriptor
  local frontier_event rejection
  [[ "${outcome}" == "accepted" || "${outcome}" == "rejected" ]] || return 1
  [[ -n "${_review_dispatch_start_json:-}" ]] || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${lifecycle}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  jq -e --arg lifecycle "${lifecycle}" --arg agent "${AGENT_TYPE}" '
    type == "object"
    and (.lifecycle_dispatch_id // "") == $lifecycle
    and (.agent_type // "") == $agent
  ' <<<"${_review_dispatch_start_json}" >/dev/null 2>&1 || return 1
  state_before="$(_reviewer_state_before_patch_unlocked "${state_after}")" || return 1
  wal="$(_reviewer_transaction_wal_dir)"
  [[ ! -e "${wal}" && ! -L "${wal}" ]] || return 1
  prepare_dir="$(mktemp -d "$(session_file ".reviewer-transaction.prepare.XXXXXX")")" \
    || return 1
  chmod 700 "${prepare_dir}" 2>/dev/null || true

  if [[ -n "${_quality_review_staged_evidence:-}" ]]; then
    descriptor="$(_reviewer_transaction_capture_artifact_unlocked \
      "${prepare_dir}" "quality_evidence.jsonl" \
      "${_quality_review_staged_evidence}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    artifacts="$(jq -c --argjson row "${descriptor}" '. + [$row]' \
      <<<"${artifacts}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    descriptor="$(_reviewer_transaction_capture_artifact_unlocked \
      "${prepare_dir}" "quality_frontier.json" \
      "${_quality_review_staged_frontier}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    artifacts="$(jq -c --argjson row "${descriptor}" '. + [$row]' \
      <<<"${artifacts}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    descriptor="$(_reviewer_transaction_capture_artifact_unlocked \
      "${prepare_dir}" "quality_frontier_history.jsonl" \
      "${_quality_review_staged_history}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    artifacts="$(jq -c --argjson row "${descriptor}" '. + [$row]' \
      <<<"${artifacts}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
  fi
  if [[ -n "${_reviewer_receipt_staged:-}" ]]; then
    descriptor="$(_reviewer_transaction_capture_artifact_unlocked \
      "${prepare_dir}" "reviewer_publication_outcomes.jsonl" \
      "${_reviewer_receipt_staged}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
    artifacts="$(jq -c --argjson row "${descriptor}" '. + [$row]' \
      <<<"${artifacts}")" || {
      _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
      return 1
    }
  fi
  frontier_event="$(jq -cn \
    --arg event "${_quality_review_frontier_event:-}" \
    --arg contract_id "${_quality_review_frontier_contract_id:-}" \
    --arg contract_revision "${_quality_review_frontier_contract_revision:-}" \
    --arg cycle "${_quality_review_frontier_cycle:-}" \
    --arg status "${_quality_review_frontier_status:-}" \
    --arg materiality "${_quality_review_frontier_materiality:-}" \
    '{event:$event,contract_id:$contract_id,contract_revision:$contract_revision,
      cycle:$cycle,status:$status,materiality:$materiality}')" || {
    _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
    return 1
  }
  rejection="$(jq -cn \
    --arg reason "${_review_rejection_reason:-}" \
    --arg start "${_review_rejection_start:-}" \
    --arg current "${_review_rejection_current:-}" \
    '{reason:$reason,start:$start,current:$current}')" || {
    _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
    return 1
  }
  manifest="$(jq -cnS \
    --argjson _v 1 \
    --arg lifecycle_dispatch_id "${lifecycle}" \
    --arg reviewer_type "${REVIEWER_TYPE}" --arg agent_type "${AGENT_TYPE}" \
    --arg native_agent_id "${_review_native_agent_id}" --arg outcome "${outcome}" \
    --arg start_line "${_review_dispatch_start_json}" \
    --arg pending_line "${_review_dispatch_pending_json:-}" \
    --argjson state_before "${state_before}" --argjson state_after "${state_after}" \
    --argjson artifacts "${artifacts}" --arg history_line "${history_line}" \
    --argjson rejection "${rejection}" --argjson frontier_event "${frontier_event}" \
    '{_v:$_v,lifecycle_dispatch_id:$lifecycle_dispatch_id,
      reviewer_type:$reviewer_type,agent_type:$agent_type,
      native_agent_id:$native_agent_id,outcome:$outcome,start_line:$start_line,
      pending_line:$pending_line,state_before:$state_before,state_after:$state_after,
      artifacts:$artifacts,history_line:$history_line,rejection:$rejection,
      frontier_event:$frontier_event}')" || {
    _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
    return 1
  }
  if ! printf '%s\n' "${manifest}" >"${prepare_dir}/manifest.json" \
      || ! chmod 600 "${prepare_dir}/manifest.json" 2>/dev/null \
      || ! _reviewer_transaction_manifest_valid "${prepare_dir}" \
      || ! _reviewer_transaction_boundary "prepare_complete" \
      || ! mv "${prepare_dir}" "${wal}"; then
    _remove_reviewer_prepare_dir_unlocked "${prepare_dir}" 2>/dev/null || true
    return 1
  fi
  _reviewer_transaction_boundary "wal_prepared"
}

_reviewer_transaction_row_status_unlocked() {
  local file="${1:-}" selected="${2:-}" lifecycle="${3:-}"
  local line exact=0 lifecycle_count=0 row_lifecycle
  if [[ ! -e "${file}" && ! -L "${file}" ]]; then
    printf absent
    return 0
  fi
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  omc_dispatch_authority_ledger_shell_safe "${file}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${selected}" ]] && exact=$((exact + 1))
    row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${line}" 2>/dev/null || true)"
    [[ "${row_lifecycle}" == "${lifecycle}" ]] \
      && lifecycle_count=$((lifecycle_count + 1))
  done <"${file}"
  if [[ "${exact}" -eq 1 && "${lifecycle_count}" -eq 1 ]]; then
    printf present
  elif [[ "${exact}" -eq 0 && "${lifecycle_count}" -eq 0 ]]; then
    printf absent
  else
    return 1
  fi
}

_reviewer_transaction_apply_artifact_unlocked() {
  local wal="${1:-}" descriptor="${2:-}" name before_kind before_sha after_sha
  local source target current_sha="" current_kind boundary
  name="$(jq -r '.name' <<<"${descriptor}")" || return 1
  before_kind="$(jq -r '.before_kind' <<<"${descriptor}")" || return 1
  before_sha="$(jq -r '.before_sha' <<<"${descriptor}")" || return 1
  after_sha="$(jq -r '.after_sha' <<<"${descriptor}")" || return 1
  source="${wal}/after-${name}"
  target="$(session_file "${name}")"
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  [[ "$(_omc_digest_file "${source}")" == "${after_sha}" ]] || return 1
  [[ ! -L "${target}" ]] || return 1
  if [[ -f "${target}" ]]; then
    current_kind="file"
    current_sha="$(_omc_digest_file "${target}")" || return 1
  elif [[ ! -e "${target}" ]]; then
    current_kind="absent"
  else
    return 1
  fi
  if [[ "${current_kind}" == "file" && "${current_sha}" == "${after_sha}" ]]; then
    :
  elif [[ "${current_kind}" == "${before_kind}" ]] \
      && { [[ "${current_kind}" == "absent" ]] \
        || [[ "${current_sha}" == "${before_sha}" ]]; }; then
    _reviewer_atomic_copy_file "${source}" "${target}" || return 1
  else
    return 1
  fi
  case "${name}" in
    quality_evidence.jsonl) boundary="evidence_published" ;;
    quality_frontier.json) boundary="frontier_published" ;;
    quality_frontier_history.jsonl) boundary="frontier_history_published" ;;
    reviewer_publication_outcomes.jsonl) boundary="receipt_published" ;;
    *) return 1 ;;
  esac
  _reviewer_transaction_boundary "${boundary}"
}

_reviewer_transaction_apply_state_unlocked() {
  local state_before="${1:-}" state_after="${2:-}" state_file temp
  state_file="$(session_file "${STATE_JSON}")"
  [[ ! -L "${state_file}" ]] || return 1
  _ensure_valid_state
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
  jq -e --argjson before "${state_before}" --argjson after "${state_after}" '
    . as $state
    | ($after | keys) as $keys
    | all($keys[];
        . as $key
        |
        (($state | has($key)) and $state[$key] == $after[$key])
        or (($before[$key].present == true)
          and ($state | has($key)) and $state[$key] == $before[$key].value)
        or (($before[$key].present == false) and (($state | has($key)) | not)))
  ' "${state_file}" >/dev/null 2>&1 || return 1
  temp="$(mktemp "${state_file}.reviewer.XXXXXX")" || return 1
  chmod 600 "${temp}" 2>/dev/null || true
  if ! jq --argjson after "${state_after}" '. + $after' \
      "${state_file}" >"${temp}" || ! mv -f "${temp}" "${state_file}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
  _reviewer_transaction_boundary "state_published"
}

_reviewer_transaction_apply_history_unlocked() {
  local history_line="${1:-}" lifecycle="${2:-}" history_file line
  local lifecycle_count=0 exact=0 row_lifecycle
  [[ -n "${history_line}" ]] || return 0
  history_file="$(session_file "review_history.jsonl")"
  [[ ! -L "${history_file}" ]] || return 1
  [[ ! -e "${history_file}" || -f "${history_file}" ]] || return 1
  if [[ -f "${history_file}" ]]; then
    omc_dispatch_authority_ledger_shell_safe "${history_file}" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "${history_line}" ]] && exact=$((exact + 1))
      row_lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
        <<<"${line}" 2>/dev/null || true)"
      [[ "${row_lifecycle}" == "${lifecycle}" ]] \
        && lifecycle_count=$((lifecycle_count + 1))
    done <"${history_file}"
  fi
  if [[ "${exact}" -eq 1 && "${lifecycle_count}" -eq 1 ]]; then
    :
  elif [[ "${exact}" -eq 0 && "${lifecycle_count}" -eq 0 ]]; then
    _append_limited_state_locked "${history_file}" "${history_line}" "32" \
      || return 1
  else
    return 1
  fi
  _reviewer_transaction_boundary "history_published"
}

_apply_reviewer_transaction_unlocked() {
  local wal manifest lifecycle outcome start_line pending_line state_before state_after
  local history_line descriptor status artifact_count=0 receipt_descriptor=""
  local committed_dir
  wal="$(_reviewer_transaction_wal_dir)"
  _reviewer_transaction_manifest_valid "${wal}" || return 1
  manifest="${wal}/manifest.json"
  lifecycle="$(jq -r '.lifecycle_dispatch_id' "${manifest}")" || return 1
  outcome="$(jq -r '.outcome' "${manifest}")" || return 1
  start_line="$(jq -r '.start_line' "${manifest}")" || return 1
  pending_line="$(jq -r '.pending_line' "${manifest}")" || return 1
  state_before="$(jq -c '.state_before' "${manifest}")" || return 1
  state_after="$(jq -c '.state_after' "${manifest}")" || return 1
  history_line="$(jq -r '.history_line' "${manifest}")" || return 1

  # Consume causal rows first. The WAL remains the replay authority until all
  # publications land, so a killed process cannot turn an absent start into an
  # untracked completion. Existing rewrite fault selectors remain supported.
  if [[ -n "${pending_line}" ]]; then
    status="$(_reviewer_transaction_row_status_unlocked \
      "$(session_file "pending_agents.jsonl")" "${pending_line}" "${lifecycle}")" \
      || return 1
    if [[ "${status}" == "present" ]]; then
      rewrite_jsonl_line_atomic "$(session_file "pending_agents.jsonl")" \
        "${pending_line}" "" "${OMC_TEST_REVIEWER_PENDING_REWRITE_FAULT:-}" \
        || return 1
    fi
    _reviewer_transaction_boundary "pending_consumed" || return 1
  fi
  status="$(_reviewer_transaction_row_status_unlocked \
    "$(session_file "agent_dispatch_starts.jsonl")" "${start_line}" "${lifecycle}")" \
    || return 1
  if [[ "${status}" == "present" ]]; then
    rewrite_jsonl_line_atomic "$(session_file "agent_dispatch_starts.jsonl")" \
      "${start_line}" "" "${OMC_TEST_REVIEWER_START_REWRITE_FAULT:-}" \
      || return 1
  fi
  _reviewer_transaction_boundary "start_consumed" || return 1

  while IFS= read -r descriptor; do
    [[ -n "${descriptor}" ]] || continue
    artifact_count=$((artifact_count + 1))
    if [[ "$(jq -r '.name' <<<"${descriptor}")" \
        == "reviewer_publication_outcomes.jsonl" ]]; then
      [[ -z "${receipt_descriptor}" ]] || return 1
      receipt_descriptor="${descriptor}"
      continue
    fi
    _reviewer_transaction_apply_artifact_unlocked "${wal}" "${descriptor}" \
      || return 1
  done < <(jq -c '.artifacts[]' "${manifest}")
  [[ "${artifact_count}" -eq "$(jq -r '.artifacts | length' "${manifest}")" ]] \
    || return 1
  _reviewer_transaction_apply_state_unlocked "${state_before}" "${state_after}" \
    || return 1
  if [[ "${outcome}" == "accepted" ]]; then
    _reviewer_transaction_apply_history_unlocked "${history_line}" "${lifecycle}" \
      || return 1
  fi
  # The receipt is the universal summary hook's rendezvous authority, so it is
  # deliberately the last publication. Observing `accepted` therefore proves
  # that evidence/frontier, reviewer state, and history already landed.
  [[ -n "${receipt_descriptor}" ]] || return 1
  _reviewer_transaction_apply_artifact_unlocked \
    "${wal}" "${receipt_descriptor}" || return 1

  # Export recovered outcome for the current hook before atomically retiring
  # the fixed WAL name. Receipt publication above is the final logical commit;
  # fixed-name absence is the crash-atomic retirement marker that lets summary
  # waiter recovery proceed without mistaking partial cleanup for corruption.
  _reviewer_recovered_lifecycle_id="${lifecycle}"
  _reviewer_recovered_agent_type="$(jq -r '.agent_type' "${manifest}")"
  _reviewer_recovered_reviewer_type="$(jq -r '.reviewer_type' "${manifest}")"
  _reviewer_recovered_native_agent_id="$(jq -r '.native_agent_id' "${manifest}")"
  _reviewer_recovered_outcome="${outcome}"
  _reviewer_recovered_start_line="${start_line}"
  _reviewer_recovered_rejection="$(jq -c '.rejection' "${manifest}")"
  _reviewer_recovered_frontier_event="$(jq -c '.frontier_event' "${manifest}")"
  committed_dir="$(_reviewer_transaction_committed_prefix)$$.${RANDOM}"
  [[ ! -e "${committed_dir}" && ! -L "${committed_dir}" ]] || return 1
  mv "${wal}" "${committed_dir}" || return 1
  _reviewer_transaction_boundary "wal_retired" || return 1
  _remove_reviewer_committed_dir_unlocked "${committed_dir}" \
    2>/dev/null || true
}

_recover_reviewer_transaction_unlocked() {
  local wal current_match=0
  wal="$(_reviewer_transaction_wal_dir)"
  _reviewer_recovery_satisfied_current=0
  _reviewer_recovered_lifecycle_id=""
  # SIGKILL before the atomic prepare-dir rename leaves no publication
  # authority, only inert loose files and staged bytes. Reap those exact
  # validated remnants before interpreting (or creating) the one fixed WAL. A
  # committed directory is likewise inert after the fixed-name rename and may
  # be only partially cleaned after process death.
  _cleanup_reviewer_loose_staging_unlocked || return 1
  _cleanup_reviewer_prepare_dirs_unlocked || return 1
  _cleanup_reviewer_committed_dirs_unlocked || return 1
  [[ ! -L "${wal}" ]] || return 1
  [[ ! -e "${wal}" ]] && return 0
  [[ -d "${wal}" ]] || return 1
  _apply_reviewer_transaction_unlocked || return 1
  if [[ "${_reviewer_recovered_agent_type}" == "${AGENT_TYPE}" \
      && "${_reviewer_recovered_reviewer_type}" == "${REVIEWER_TYPE}" ]]; then
    if [[ -n "${_reviewer_recovered_native_agent_id}" ]]; then
      [[ "${_reviewer_recovered_native_agent_id}" == "${_review_native_agent_id}" ]] \
        && current_match=1
    elif [[ -n "${_review_dispatch_id}" ]] \
        && [[ "$(jq -r '.review_dispatch_id // empty' \
          <<<"${_reviewer_recovered_start_line}")" == "${_review_dispatch_id}" ]]; then
      current_match=1
    elif [[ -z "${_review_dispatch_id}" \
        && -z "$(jq -r '.review_dispatch_id // empty' \
          <<<"${_reviewer_recovered_start_line}")" \
        && -z "$(jq -r '.native_agent_id // empty' \
          <<<"${_reviewer_recovered_start_line}")" ]]; then
      # Pre-native current clients can only have one in-flight gate reviewer of
      # a role; the single WAL plus exact agent/reviewer match is therefore the
      # same compatibility identity used by start selection.
      current_match=1
    fi
  fi
  if [[ "${current_match}" -eq 1 ]]; then
    _reviewer_recovery_satisfied_current=1
    _review_dispatch_start_json="${_reviewer_recovered_start_line}"
    if [[ "${_reviewer_recovered_outcome}" == "accepted" ]]; then
      _review_commit_accepted=1
      _review_rejection_reason=""
    else
      _review_commit_accepted=0
      _review_rejection_reason="$(jq -r '.reason' \
        <<<"${_reviewer_recovered_rejection}")"
      _review_rejection_start="$(jq -r '.start' \
        <<<"${_reviewer_recovered_rejection}")"
      _review_rejection_current="$(jq -r '.current' \
        <<<"${_reviewer_recovered_rejection}")"
    fi
    _quality_review_frontier_event="$(jq -r '.event' \
      <<<"${_reviewer_recovered_frontier_event}")"
    _quality_review_frontier_contract_id="$(jq -r '.contract_id' \
      <<<"${_reviewer_recovered_frontier_event}")"
    _quality_review_frontier_contract_revision="$(jq -r '.contract_revision' \
      <<<"${_reviewer_recovered_frontier_event}")"
    _quality_review_frontier_cycle="$(jq -r '.cycle' \
      <<<"${_reviewer_recovered_frontier_event}")"
    _quality_review_frontier_status="$(jq -r '.status' \
      <<<"${_reviewer_recovered_frontier_event}")"
    _quality_review_frontier_materiality="$(jq -r '.materiality' \
      <<<"${_reviewer_recovered_frontier_event}")"
  fi
}

_collect_reviewer_summary_replays_unlocked() {
  local waiters_file receipts_file pending_file outcomes_file
  local waiters receipts pending outcomes settled_ids temp
  _reviewer_summary_replays='[]'
  waiters_file="$(session_file "reviewer_summary_waiters.jsonl")"
  receipts_file="$(session_file "reviewer_publication_outcomes.jsonl")"
  pending_file="$(session_file "pending_agents.jsonl")"
  outcomes_file="$(session_file "agent_completion_outcomes.jsonl")"
  for _reviewer_rendezvous_file in "${waiters_file}" "${receipts_file}" \
      "${pending_file}" "${outcomes_file}"; do
    [[ ! -L "${_reviewer_rendezvous_file}" ]] || return 1
    [[ ! -e "${_reviewer_rendezvous_file}" \
        || -f "${_reviewer_rendezvous_file}" ]] || return 1
  done
  [[ -s "${waiters_file}" && -s "${receipts_file}" ]] || return 0
  waiters="$(omc_summary_waiter_ledger_json_unlocked \
    reviewer "${waiters_file}")" || return 1
  receipts="$(_omc_strict_jsonl_array_unlocked \
    "${receipts_file}" 4194304 128)" || return 1
  jq -e '
    type == "array"
    and all(.[];
      type == "object" and .schema_version == 1
      and (keys | sort == ["agent_type","completion_digest","decided_at",
        "lifecycle_dispatch_id","native_agent_id","reason",
        "result_review_revision","reviewer_type","schema_version",
        "start_review_revision","status","verdict"])
      and all(.. | strings; index("\u0000") == null)
      and (.decided_at | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .)
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,80}$"))
      and (.agent_type | type == "string" and length > 0
        and length <= 128)
      and (.reviewer_type | type == "string" and length > 0
        and length <= 64)
      and (.native_agent_id | type == "string" and length <= 128
        and test("^[A-Za-z0-9._:-]*$"))
      and (.completion_digest | type == "string"
        and test("^[A-Fa-f0-9]{16,128}$"))
      and (.status | IN("accepted","rejected"))
      and (.reason | type == "string" and length <= 256)
      and (.verdict | type == "string" and length <= 32
        and test("^[A-Z_]*$"))
      and (.start_review_revision | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .)
      and (.result_review_revision | type == "number" and . >= 0
        and . <= 999999999999999 and floor == .))
    and (([.[].lifecycle_dispatch_id] | unique | length) == length)
  ' <<<"${receipts}" >/dev/null 2>&1 || return 1
  if [[ -s "${pending_file}" ]]; then
    _omc_publication_claim_timestamps_valid_unlocked \
      "${pending_file}" || return 1
    pending="$(jq -Rsc '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null) | select(type == "object")]
    ' "${pending_file}" 2>/dev/null)" || return 1
  else
    pending='[]'
  fi
  if [[ -s "${outcomes_file}" ]]; then
    outcomes="$(omc_causal_completion_outcomes_json_unlocked \
      "${outcomes_file}")" || return 1
  else
    outcomes='[]'
  fi

  # If accepted or rejected outcome publication committed and the pending row
  # was consumed before process death, the remaining exact waiter is only
  # cleanup debt. Receipt+outcome is the roll-forward journal; accepted maps to
  # accepted and rejected maps to ignored. Retire only the singular exact
  # identity pair so future admissions cannot wedge on a stale waiter.
  settled_ids="$(jq -cn \
    --argjson waiters "${waiters}" --argjson receipts "${receipts}" \
    --argjson pending "${pending}" --argjson outcomes "${outcomes}" '
      [$waiters[] as $waiter
        | select($waiter.schema_version == 1)
        | select([$waiters[] | select(
            .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id)]
          | length == 1)
        | ([$receipts[] | select(
              .schema_version == 1
              and (.status == "accepted" or .status == "rejected")
              and .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
              and .agent_type == $waiter.agent_type
              and .native_agent_id == $waiter.native_agent_id
              and .completion_digest == $waiter.completion_digest)]
            ) as $matching_receipts
        | select(($matching_receipts | length) == 1)
        | $matching_receipts[0] as $receipt
        | select([$pending[] | select(
            .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id)]
          | length == 0)
        | select([$outcomes[] | select(
            .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
            and .agent_type == $waiter.agent_type
            and .native_agent_id == $waiter.native_agent_id
            and .status == (if $receipt.status == "accepted"
                            then "accepted" else "ignored" end))]
          | length == 1)
        | $waiter.lifecycle_dispatch_id] | unique
    ')" || return 1
  if [[ "$(jq -r 'length' <<<"${settled_ids}")" -gt 0 ]]; then
    temp="$(mktemp "${waiters_file}.XXXXXX")" || return 1
    if ! jq -cn --argjson waiters "${waiters}" \
        --argjson settled "${settled_ids}" '
          $waiters[]
          | select(.lifecycle_dispatch_id as $id
            | ($settled | index($id)) == null)
        ' >"${temp}" || ! mv -f "${temp}" "${waiters_file}"; then
      rm -f "${temp}" 2>/dev/null || true
      return 1
    fi
    waiters="$(omc_summary_waiter_ledger_json_unlocked \
      reviewer "${waiters_file}")" || return 1
  fi
  [[ "$(jq -r 'length' <<<"${waiters}")" -gt 0 \
      && "$(jq -r 'length' <<<"${pending}")" -gt 0 ]] || return 0
  _reviewer_summary_replays="$(jq -cn \
    --argjson waiters "${waiters}" --argjson receipts "${receipts}" \
    --argjson pending "${pending}" '
      [$waiters[] as $waiter
        | select($waiter.schema_version == 1)
        | select([$receipts[] | select(
            .schema_version == 1
            and .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
            and .agent_type == $waiter.agent_type
            and .native_agent_id == $waiter.native_agent_id
            and .completion_digest == $waiter.completion_digest
          )] | length == 1)
        | ([$pending[] | select(
            .lifecycle_dispatch_id == $waiter.lifecycle_dispatch_id
            and .agent_type == $waiter.agent_type
            and (.native_agent_id // "") == $waiter.native_agent_id
            and (.review_dispatch_abandoned // false) != true
          )]) as $matching_pending
        | select(($matching_pending | length) == 1)
        | $matching_pending[0] as $pending_row
        | $waiter
          + if (($pending_row.completion_claim_id // "") | length) > 0
            then {completion_claim_id:$pending_row.completion_claim_id}
            else {} end]
    ')" || return 1
}

_cleanup_quality_review_staging() {
  local staged
  for staged in \
      "${_quality_review_staged_evidence:-}" \
      "${_quality_review_staged_frontier:-}" \
      "${_quality_review_staged_history:-}" \
      "${_reviewer_receipt_staged:-}"; do
    [[ -n "${staged}" ]] || continue
    rm -f -- "${staged}" 2>/dev/null || true
  done
  _quality_review_staged_evidence=""
  _quality_review_staged_frontier=""
  _quality_review_staged_history=""
  _reviewer_receipt_staged=""
}

_quality_frontier_history_appendable() {
  local history_file="$1" raw parsed
  [[ ! -e "${history_file}" && ! -L "${history_file}" ]] && return 0
  [[ -f "${history_file}" && ! -L "${history_file}" \
      && -r "${history_file}" ]] || return 1
  if [[ -s "${history_file}" ]]; then
    cmp -s <(tail -c 1 "${history_file}") <(printf '\n') || return 1
  fi
  raw="$(_quality_contract_read_jsonl_array \
    "${history_file}" 2097152 64)" || return 1
  parsed="$(_quality_frontier_history_parse "${history_file}")" || return 1
  jq -e --argjson raw "${raw}" '
    .invalid_rows == 0 and (.rows | length) == ($raw | length)
  ' <<<"${parsed}" >/dev/null 2>&1
}

_build_reviewer_history_entry() {
  local history_verdict="${1:-}" findings='[]' rows revision objective_ts
  local objective_revision cycle lifecycle
  if [[ -n "${review_message}" ]]; then
    rows="$(extract_findings_json "${review_message}" 2>/dev/null || true)"
    if [[ -n "${rows}" ]]; then
      findings="$(printf '%s\n' "${rows}" | jq -sc '.')" || return 1
    fi
  fi
  revision="$(jq -r '.review_revision // .code_revision // .edit_revision // 0' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${revision}" =~ ^[0-9]+$ ]] || revision=0
  objective_ts="$(jq -r '.objective_prompt_ts // 0' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${objective_ts}" =~ ^[0-9]+$ ]] || objective_ts=0
  objective_revision="$(jq -r '.objective_prompt_revision // 0' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${objective_revision}" =~ ^[0-9]+$ ]] || objective_revision=0
  cycle="$(jq -r '.objective_cycle_id // 0' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  [[ "${cycle}" =~ ^[0-9]+$ ]] || cycle=0
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  _review_history_entry_staged="$(jq -nc \
    --argjson ts "${now_ts}" --argjson objective_prompt_ts "${objective_ts}" \
    --argjson objective_prompt_revision "${objective_revision}" \
    --argjson objective_cycle_id "${cycle}" \
    --arg reviewer_type "${REVIEWER_TYPE}" --arg agent_type "${AGENT_TYPE}" \
    --arg verdict "${history_verdict}" --argjson revision "${revision}" \
    --arg lifecycle_dispatch_id "${lifecycle}" --argjson findings "${findings}" \
    '{ts:$ts,objective_prompt_ts:$objective_prompt_ts,
      objective_prompt_revision:$objective_prompt_revision,
      objective_cycle_id:$objective_cycle_id,reviewer_type:$reviewer_type,
      agent_type:$agent_type,verdict:$verdict,revision:$revision,
      lifecycle_dispatch_id:$lifecycle_dispatch_id,findings:$findings}')" || return 1
}

_reviewer_completion_digest() {
  local safe_message
  safe_message="$(printf '%s' "${review_message}" \
    | omc_redact_secrets | tr -d '\000')" || return 1
  _omc_token_digest "${safe_message}"
}

_stage_reviewer_publication_receipt_unlocked() {
  local status="${1:-}" reason="${2:-}" result_revision="${3:-}"
  local lifecycle native start_revision completion_digest terminal_verdict
  local receipts_file source temp live_ids='[]' ledger entry
  local pending_ledger starts_ledger waiters_ledger waiters waiter_ids
  [[ "${status}" == "accepted" || "${status}" == "rejected" ]] || return 1
  lifecycle="$(jq -r '.lifecycle_dispatch_id // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  native="$(jq -r '.native_agent_id // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  start_revision="$(jq -r '.review_revision // empty' \
    <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  completion_digest="$(_reviewer_completion_digest)" || return 1
  terminal_verdict=""
  if [[ "${_review_final_line:-}" =~ ^VERDICT:[[:space:]]*([A-Z_]+) ]]; then
    terminal_verdict="${BASH_REMATCH[1]}"
  fi
  [[ "${lifecycle}" =~ ^dispatch-[A-Za-z0-9._:-]{8,80}$ \
      && "${native}" =~ ^[A-Za-z0-9._:-]{0,128}$ \
      && "${start_revision}" =~ ^[0-9]+$ \
      && "${result_revision}" =~ ^[0-9]+$ \
      && "${completion_digest}" =~ ^[A-Fa-f0-9]{16,128}$ \
      && "${terminal_verdict}" =~ ^[A-Z_]{0,32}$ ]] || return 1
  receipts_file="$(session_file "reviewer_publication_outcomes.jsonl")"
  [[ ! -L "${receipts_file}" ]] \
    && { [[ ! -e "${receipts_file}" ]] || [[ -f "${receipts_file}" ]]; } \
    || return 1
  pending_ledger="$(session_file "pending_agents.jsonl")"
  starts_ledger="$(session_file "agent_dispatch_starts.jsonl")"
  for ledger in "${pending_ledger}" "${starts_ledger}"; do
    [[ ! -L "${ledger}" ]] || return 1
    if [[ -f "${ledger}" ]]; then
      if [[ "${ledger}" == "${pending_ledger}" ]]; then
        # pending_agents is a compatibility queue, not receipt authority.
        # Preserve unrelated malformed legacy noise while deriving live IDs
        # from exact object rows; the stateful start ledger below remains
        # strict and keeps every reviewer receipt correlation fail-closed.
        live_ids="$(jq -Rsc --argjson prior "${live_ids}" '
          ($prior + [split("\n")[] | select(length > 0)
            | (try fromjson catch null) | select(type == "object")
            | .lifecycle_dispatch_id // empty])
          | map(select(type == "string" and length > 0)) | unique
        ' "${ledger}")" || return 1
      else
        jq -Rse '
          [split("\n")[] | select(length > 0)
            | (try fromjson catch null)] | all(.[]; type == "object")
        ' "${ledger}" >/dev/null 2>&1 || return 1
        live_ids="$(jq -Rsc --argjson prior "${live_ids}" '
          ($prior + [split("\n")[] | select(length > 0)
            | fromjson | .lifecycle_dispatch_id // empty])
          | map(select(type == "string" and length > 0)) | unique
        ' "${ledger}")" || return 1
      fi
    fi
  done
  # Re-check summary-waiter authority under the publication lock. A sibling
  # callback can pass its entry recovery barrier, then lose a race to another
  # process that consumes its causal rows and dies after leaving an exact
  # waiter+receipt pair. That receipt remains roll-forward authority even
  # though it no longer appears in pending/start.
  waiters_ledger="$(session_file "reviewer_summary_waiters.jsonl")"
  [[ ! -L "${waiters_ledger}" ]] \
    && { [[ ! -e "${waiters_ledger}" ]] || [[ -f "${waiters_ledger}" ]]; } \
    || return 1
  if [[ -s "${waiters_ledger}" ]]; then
    waiters="$(omc_summary_waiter_ledger_json_unlocked \
      reviewer "${waiters_ledger}")" || return 1
    waiter_ids="$(jq -c '[.[].lifecycle_dispatch_id] | unique' \
      <<<"${waiters}" 2>/dev/null)" || return 1
    live_ids="$(jq -cn --argjson prior "${live_ids}" \
      --argjson waiters "${waiter_ids}" '
        ($prior + $waiters) | unique
      ')" || return 1
  fi
  entry="$(jq -cnS \
    --argjson schema_version 1 --argjson decided_at "${now_ts}" \
    --arg lifecycle_dispatch_id "${lifecycle}" --arg agent_type "${AGENT_TYPE}" \
    --arg reviewer_type "${REVIEWER_TYPE}" --arg native_agent_id "${native}" \
    --arg completion_digest "${completion_digest}" --arg status "${status}" \
    --arg reason "${reason}" --arg verdict "${terminal_verdict}" \
    --argjson start_review_revision "${start_revision}" \
    --argjson result_review_revision "${result_revision}" '
      {schema_version:$schema_version,decided_at:$decided_at,
       lifecycle_dispatch_id:$lifecycle_dispatch_id,agent_type:$agent_type,
       reviewer_type:$reviewer_type,native_agent_id:$native_agent_id,
       completion_digest:$completion_digest,status:$status,reason:$reason,
       verdict:$verdict,start_review_revision:$start_review_revision,
       result_review_revision:$result_review_revision}
    ')" || return 1
  source="${receipts_file}"
  [[ -f "${source}" ]] || source="/dev/null"
  temp="$(mktemp "$(session_file ".reviewer-publication.stage.XXXXXX")")" \
    || return 1
  chmod 600 "${temp}" 2>/dev/null || {
    rm -f "${temp}" 2>/dev/null || true
    return 1
  }
  if ! jq -Rsr --argjson entry "${entry}" --argjson live "${live_ids}" '
      def valid:
        type == "object" and .schema_version == 1
        and (keys | sort == ["agent_type","completion_digest","decided_at",
          "lifecycle_dispatch_id","native_agent_id","reason",
          "result_review_revision","reviewer_type","schema_version",
          "start_review_revision","status","verdict"])
        and (.decided_at | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .)
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
        and (.start_review_revision | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .)
        and (.result_review_revision | type == "number" and . >= 0
          and . <= 999999999999999 and floor == .);
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null)] as $rows
      | if all($rows[]; valid) | not then error("invalid receipt ledger")
        elif any($rows[];
          .lifecycle_dispatch_id == $entry.lifecycle_dispatch_id) then
          error("duplicate lifecycle receipt")
        else
          ([$rows[] | select(.lifecycle_dispatch_id as $id
              | ($live | index($id)) != null)] + [$entry]) as $kept
          | if ($kept | length) > 128 then error("live receipt cap")
            else $kept[] | @json end
        end
    ' "${source}" >"${temp}"; then
    rm -f "${temp}" 2>/dev/null || true
    return 1
  fi
  _reviewer_receipt_staged="${temp}"
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
  local expected_proof_identity=""
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
  local new_proof_identity=""
  local prior_receipt_index=-1 new_receipt_index=-1

  [[ "${REVIEWER_TYPE}" == "excellence" \
      && "${_review_quality_required}" == "1" ]] || {
    _quality_review_state_args=()
    _quality_review_staged_evidence=""
    _quality_review_staged_frontier=""
    _quality_review_staged_history=""
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
  threshold="$(jq -r '.verification_threshold // 40' \
    <<<"${_review_quality_contract}" 2>/dev/null || printf '40')"
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
      quality_contract_receipt_matches_criterion \
        "${receipt}" "${criterion}" "${threshold}" || {
        _quality_review_receipt_failure="receipt-does-not-match-criterion:${ref}:${criterion_id}"
        rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
      }
      expected_proof_identity="$(_quality_contract_receipt_expected_proof_identity_for_contract \
        "${receipt}" "${_review_quality_contract}" 2>/dev/null || true)"
      [[ -n "${expected_proof_identity}" \
          && "${proof_identity}" == "${expected_proof_identity}" ]] || {
        _quality_review_receipt_failure="receipt-proof-identity-mismatch:${ref}:${criterion_id}"
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
            || -z "${new_proof_identity}" ]] \
            || ! _quality_contract_counterproof_is_distinct \
              "${prior_receipt}" "${new_receipt}"; then
          # A fresh tool ID alone is not counterevidence. A rerun of the
          # frozen semantic surface is eligible only for observation-bearing
          # tools whose content-bearing artifact and full observed result both
          # changed. Assertion-bearing proof must use a genuinely different
          # semantic surface. This preserves canonical proof authority without
          # letting receipt-ID churn or incidental test chatter clear a
          # material frontier.
          _quality_review_receipt_failure="open-frontier-counterproof-not-new:${criterion_id}"
          rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
          return 1
        fi
      done < <(jq -r '.[]' <<<"${prior_open_ids}")
    fi
  fi

  if [[ -f "${history_file}" ]]; then
    # Validate history only at its publication boundary. The current
    # frontier/evidence pair remains primary causal authority after additive
    # re-contracting, so it must first be able to reject same-proof clearance
    # with actionable retained-call feedback even when this redundant audit
    # sidecar is malformed. A valid clearance still fails closed here before
    # any staged artifact can be published.
    if ! _quality_frontier_history_appendable "${history_file}"; then
      rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
      return 1
    fi
    _history_frontier_status="$(quality_frontier_history_last_status_for_cycle \
      "${history_file}" "${cycle}" 2>/dev/null || true)"
    [[ -n "${_history_frontier_status}" ]] \
      && prior_frontier_status="${_history_frontier_status}"
    if [[ "${OMC_TEST_REVIEWER_HISTORY_TAIL_FAULT:-0}" == "1" ]] \
        || ! tail -n 63 "${history_file}" \
          >"${history_tmp}" 2>/dev/null; then
      rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"
      return 1
    fi
  fi
  printf '%s\n' "${frontier_json}" >>"${history_tmp}" || {
    rm -f "${evidence_tmp}" "${frontier_tmp}" "${history_tmp}"; return 1;
  }
  # Do not publish here. The caller first seals these exact bytes into the
  # lifecycle-bound reviewer WAL, then the idempotent roll-forward path lands
  # evidence, frontier, history, state, and causal-ledger consumption. A killed
  # hook can therefore resume without regenerating timestamps or proof IDs.
  _quality_review_staged_evidence="${evidence_tmp}"
  _quality_review_staged_frontier="${frontier_tmp}"
  _quality_review_staged_history="${history_tmp}"

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
  _select_reviewer_dispatch_start_unlocked || return 1
  local _current_revision _start_revision="" _tracking_version=""
  local _row_version="" _strict_tracking=0 _rejection_reason=""
  local _current_objective_ts="" _start_objective_ts=""
  local _start_objective_revision=""
  local _current_cycle_id=0 _start_cycle_id=0
  local _stale_count="" _lifecycle_id=""
  _current_revision="$(_review_current_revision)"
  _tracking_version="$(read_state "review_dispatch_tracking_version")"
  local _native_tracking_version=""
  _native_tracking_version="${_review_native_tracking_version:-$(read_state "native_agent_id_tracking_version")}"
  if [[ -n "${_review_dispatch_start_json}" ]]; then
    _lifecycle_id="$(jq -r '.lifecycle_dispatch_id // empty' \
      <<<"${_review_dispatch_start_json}" 2>/dev/null || true)"
  fi

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
      if [[ ! "${_lifecycle_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ \
          || ! "${_start_revision}" =~ ^[0-9]+$ \
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
    _review_rejection_reason="${_rejection_reason}"
    _review_rejection_start="${_start_revision}"
    _review_rejection_current="${_current_revision}"
    local _rejection_state_args=(
      "last_stale_reviewer_type" "${REVIEWER_TYPE}" \
      "last_stale_reviewer_ts" "${now_ts}" \
      "last_stale_reviewer_reason" "${_rejection_reason}" \
      "last_stale_reviewer_start_revision" "${_start_revision}" \
      "last_stale_reviewer_current_revision" "${_current_revision}" \
      "stale_reviewer_count" "$((_stale_count + 1))"
    )
    if [[ "${_lifecycle_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
      local _rejection_patch
      _stage_reviewer_publication_receipt_unlocked \
        "rejected" "${_rejection_reason}" "${_current_revision}" || return 1
      _rejection_patch="$(_reviewer_state_patch_from_args \
        "${_rejection_state_args[@]}")" || {
        _cleanup_quality_review_staging
        return 1
      }
      if ! _prepare_reviewer_transaction_unlocked \
          "rejected" "${_rejection_patch}" ""; then
        _cleanup_quality_review_staging
        return 1
      fi
      _cleanup_quality_review_staging
      _apply_reviewer_transaction_unlocked || return 1
    else
      _write_state_batch_unlocked "${_rejection_state_args[@]}" || return 1
      # Legacy compatibility rows predate lifecycle IDs. Preserve their old
      # completion semantics, but still make the exact deletion atomic.
      if [[ -n "${_review_dispatch_start_json}" ]]; then
        rewrite_jsonl_line_atomic "$(session_file "agent_dispatch_starts.jsonl")" \
          "${_review_dispatch_start_json}" "" || return 1
      fi
    fi
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
  _build_reviewer_history_entry "${dimension_verdict}" || {
    _cleanup_quality_review_staging
    return 1
  }
  if [[ "${_lifecycle_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    local _accepted_patch
    _stage_reviewer_publication_receipt_unlocked \
      "accepted" "" "${_current_revision}" || {
      _cleanup_quality_review_staging
      return 1
    }
    _accepted_patch="$(_reviewer_state_patch_from_args \
      "${_all_state_args[@]}")" || {
      _cleanup_quality_review_staging
      return 1
    }
    if ! _prepare_reviewer_transaction_unlocked \
        "accepted" "${_accepted_patch}" "${_review_history_entry_staged}"; then
      _cleanup_quality_review_staging
      return 1
    fi
    _cleanup_quality_review_staging
    _apply_reviewer_transaction_unlocked || return 1
  else
    # No tracked start is the explicit legacy migration path. Armed
    # Definition reviews are never allowed here because their evidence must be
    # bound to a real lifecycle_dispatch_id.
    if [[ -n "${_quality_review_staged_evidence:-}" ]]; then
      _cleanup_quality_review_staging
      return 1
    fi
    _write_state_batch_unlocked "${_all_state_args[@]}" || return 1
    _append_limited_state_locked "$(session_file "review_history.jsonl")" \
      "${_review_history_entry_staged}" "32" || return 1
    if [[ -n "${_review_dispatch_start_json}" ]]; then
      rewrite_jsonl_line_atomic "$(session_file "agent_dispatch_starts.jsonl")" \
        "${_review_dispatch_start_json}" "" || return 1
    fi
  fi
  _review_commit_accepted=1
}

_commit_reviewer_transaction_unlocked() {
  # Recover the one durable in-flight lifecycle before admitting another. If
  # this callback is a replay of that same native completion, recovery itself
  # satisfies the callback and must not write a second verdict/history row.
  _recover_reviewer_transaction_unlocked || return 1
  if [[ "${_reviewer_recovery_satisfied_current:-0}" -eq 1 ]]; then
    _collect_reviewer_summary_replays_unlocked || return 1
    return 0
  fi
  _commit_reviewer_result "$@" || return 1
  # Receipt/WAL retirement and universal-summary replay are deliberately two
  # phases. Inject this boundary so process-death tests prove the next
  # lifecycle reconciliation can settle a summary-first waiter even though no
  # active WAL remains to trigger the ordinary recovery guard.
  _reviewer_transaction_boundary "transaction_committed" || return 1
  _collect_reviewer_summary_replays_unlocked
}

if [[ "${_reviewer_recover_active_mode}" -eq 1 ]]; then
  _recover_active_reviewer_unlocked() {
    _recover_reviewer_transaction_unlocked || return 1
    _collect_reviewer_summary_replays_unlocked
  }
  with_state_lock_publication_recovery \
    _recover_active_reviewer_unlocked || exit 1
  # Defense in depth for every lifecycle caller: a successful internal
  # recovery means the fixed publication authority is actually retired.
  [[ ! -e "${_reviewer_active_wal}" \
      && ! -L "${_reviewer_active_wal}" ]] || exit 1
  while IFS= read -r _reviewer_replay_row; do
    [[ -n "${_reviewer_replay_row}" ]] || continue
    _reviewer_replay_agent="$(jq -r '.agent_type // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_message="$(jq -r '.message // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    [[ -n "${_reviewer_replay_agent}" \
        && -n "${_reviewer_replay_message}" ]] || continue
    [[ -z "${_reviewer_replay_claim}" \
        || "${_reviewer_replay_claim}" \
          =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]] || exit 1
    jq -nc \
      --arg sid "${SESSION_ID}" --arg agent "${_reviewer_replay_agent}" \
      --arg native_id "${_reviewer_replay_native_id}" \
      --arg message "${_reviewer_replay_message}" '
        {session_id:$sid,agent_type:$agent,
         last_assistant_message:$message,stop_hook_active:false}
        + if $native_id == "" then {} else {agent_id:$native_id} end
      ' | OMC_REVIEWER_SUMMARY_REPLAY=1 \
        OMC_PUBLICATION_RECOVERY_INTERNAL=1 \
        OMC_PUBLICATION_RECOVERY_CLAIM_ID="${_reviewer_replay_claim}" \
        bash "${SCRIPT_DIR}/record-subagent-summary.sh" \
        >/dev/null 2>&1 || exit 1
  done < <(jq -c '.[]' <<<"${_reviewer_summary_replays}" 2>/dev/null || true)
  exit 0
fi

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

# Summary-first order leaves a redacted lifecycle waiter and no universal side
# effects. Once the dedicated reviewer receipt is the last WAL publication,
# replay only the exact lifecycle/native/message digest. The summary hook's
# durable pending claim makes concurrent platform delivery and replay one-shot.
if [[ "${OMC_REVIEWER_SUMMARY_REPLAY:-0}" != "1" \
    && "${_reviewer_summary_replays:-[]}" != "[]" ]]; then
  while IFS= read -r _reviewer_replay_row; do
    [[ -n "${_reviewer_replay_row}" ]] || continue
    _reviewer_replay_agent="$(jq -r '.agent_type // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_native_id="$(jq -r '.native_agent_id // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_message="$(jq -r '.message // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    _reviewer_replay_claim="$(jq -r '.completion_claim_id // empty' \
      <<<"${_reviewer_replay_row}" 2>/dev/null || true)"
    [[ -n "${_reviewer_replay_agent}" \
        && -n "${_reviewer_replay_message}" ]] || continue
    if [[ -n "${_reviewer_replay_claim}" \
        && ! "${_reviewer_replay_claim}" \
          =~ ^completion-[A-Za-z0-9._:-]{8,160}$ ]]; then
      log_anomaly "record-reviewer" \
        "invalid deferred summary claim agent=${_reviewer_replay_agent}"
      continue
    fi
    jq -nc \
      --arg sid "${SESSION_ID}" --arg agent "${_reviewer_replay_agent}" \
      --arg native_id "${_reviewer_replay_native_id}" \
      --arg message "${_reviewer_replay_message}" '
        {session_id:$sid,agent_type:$agent,
         last_assistant_message:$message,stop_hook_active:false}
        + if $native_id == "" then {} else {agent_id:$native_id} end
      ' | OMC_REVIEWER_SUMMARY_REPLAY=1 \
        OMC_PUBLICATION_RECOVERY_INTERNAL=1 \
        OMC_PUBLICATION_RECOVERY_CLAIM_ID="${_reviewer_replay_claim}" \
        bash "${SCRIPT_DIR}/record-subagent-summary.sh" \
        >/dev/null 2>&1 || log_anomaly "record-reviewer" \
          "deferred reviewer summary replay failed agent=${_reviewer_replay_agent}"
  done < <(jq -c '.[]' <<<"${_reviewer_summary_replays}" 2>/dev/null || true)
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

# The lifecycle-bound transaction has already appended the structured reviewer
# history row (with its lifecycle_dispatch_id) exactly once. Keeping history in
# the same WAL prevents a replay after SIGKILL from duplicating remediation
# evidence or leaving an accepted dimension without its audit row.

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
