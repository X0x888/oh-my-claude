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

review_message="$(json_get '.last_assistant_message')"

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
# (optionally with a trailing count like `FINDINGS (2)`). When present, the
# VERDICT line is authoritative. If absent, fall through to the legacy
# phrase-based regex so older reviewer configurations still work.
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

# Commit reviewer metadata and dimension verdicts under one state lock. The
# dispatch-start generation must still equal the completion generation. If an
# edit/plan landed while the reviewer was running, preserve the prior verdict
# and force a new review rather than stamping old evidence as current. Metadata
# and dimension state are assembled and written in ONE atomic state batch.
_commit_reviewer_result() {
  local dimension_verdict="$1" dimensions_csv="$2"
  shift 2
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
  # macOS still ships Bash 3.2, where expanding an empty array under `set -u`
  # raises "unbound variable". Release reviews intentionally own no quality
  # dimension, so avoid expanding the empty dimension array on that path.
  if (( ${#_OMC_DIM_STATE_ARGS[@]} > 0 )); then
    _write_state_batch_unlocked "${_metadata_args[@]}" "${_OMC_DIM_STATE_ARGS[@]}"
  else
    _write_state_batch_unlocked "${_metadata_args[@]}"
  fi
  _review_commit_accepted=1
}

dimension_verdict="FINDINGS"
[[ "${has_findings}" == "false" ]] && dimension_verdict="CLEAN"

if [[ "${REVIEWER_TYPE}" == "release" ]]; then
  # release-reviewer is a cumulative/manual release-prep reviewer. It is
  # intentionally outside the per-wave quality dimensions; treating it as
  # `standard` would let a clean release review satisfy bug_hunt/code_quality
  # and clear stop-guard counters for ordinary implementation work.
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "" \
    "last_release_review_ts" "${now_ts}" \
    "release_review_had_findings" "${has_findings}" \
    "release_review_format_issue" "${review_format_issue}"
elif [[ "${REVIEWER_TYPE}" == "excellence" ]]; then
  # Excellence owns only the completeness clock. It must not satisfy the
  # universal quality-reviewer clock or overwrite its finding/format state.
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "completeness" \
    "last_excellence_review_ts" "${now_ts}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "prose" ]]; then
  # Editor-critic satisfies only the document-review clock. In mixed work it
  # cannot make a still-missing quality-reviewer appear to have run.
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "prose" \
    "last_doc_review_ts" "${now_ts}" \
    "doc_review_had_findings" "${has_findings}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "stress_test" ]]; then
  # last_metis_review_ts is consumed by the plan-phase Metis gate. It is
  # deliberately isolated from implementation-review state.
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "stress_test" \
    "last_metis_review_ts" "${now_ts}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "traceability" ]]; then
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "traceability" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
elif [[ "${REVIEWER_TYPE}" == "design_quality" ]]; then
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "design_quality" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
else
  # Only a standard quality review owns the generic code-review state.
  with_state_lock _commit_reviewer_result "${dimension_verdict}" "bug_hunt,code_quality" \
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
