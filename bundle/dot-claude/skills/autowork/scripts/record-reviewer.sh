#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

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
REVIEWER_TYPE="${1:-standard}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

review_message="$(json_get '.last_assistant_message')"

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
if [[ -n "${review_message}" ]]; then
  verdict_line="$(printf '%s\n' "${review_message}" \
    | grep -E '^VERDICT:[[:space:]]*(CLEAN|SHIP|FINDINGS|BLOCK)\b' \
    | tail -n 1 || true)"
  if [[ -n "${verdict_line}" ]]; then
    verdict_token="$(printf '%s' "${verdict_line}" \
      | grep -Eio '(CLEAN|SHIP|FINDINGS|BLOCK)' \
      | head -n 1 \
      | tr '[:lower:]' '[:upper:]' || true)"
    # Handle the `FINDINGS (0)` edge case as clean.
    if [[ "${verdict_token}" == "FINDINGS" ]] \
        && printf '%s' "${verdict_line}" | grep -Eq '\(\s*0\s*\)|\(\s*none\s*\)'; then
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

if [[ -z "${has_findings}" ]]; then
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

# --- State writes and dimension ticking ---

now_ts="$(now_epoch)"

if [[ "${REVIEWER_TYPE}" == "excellence" ]]; then
  # Excellence reviews update last_review_ts and their own timestamp, but must
  # not overwrite review_had_findings from the standard review — the excellence
  # gate is independent of the remediation gate.
  with_state_lock_batch \
    "last_review_ts" "${now_ts}" \
    "last_excellence_review_ts" "${now_ts}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "dimension_guard_blocks" "0"
  if [[ "${has_findings}" == "false" ]]; then
    tick_dimensions_with_verdict "CLEAN" "${now_ts}" "completeness"
  else
    set_dimension_verdicts "FINDINGS" "completeness"
  fi
else
  batch_args=(
    "last_review_ts" "${now_ts}"
    "review_had_findings" "${has_findings}"
    "stop_guard_blocks" "0"
    "session_handoff_blocks" "0"
    "dimension_guard_blocks" "0"
  )
  if [[ "${REVIEWER_TYPE}" == "prose" ]]; then
    batch_args+=("last_doc_review_ts" "${now_ts}")
  fi
  with_state_lock_batch \
    "${batch_args[@]}"

  if [[ "${REVIEWER_TYPE}" == "prose" ]]; then
    # Editor-critic ticks prose only. Also record a doc-review timestamp so
    # stop-guard can tell whether the doc side of the session is satisfied
    # independently of the code side.
    if [[ "${has_findings}" == "false" ]]; then
      tick_dimensions_with_verdict "CLEAN" "${now_ts}" "prose"
    else
      set_dimension_verdicts "FINDINGS" "prose"
    fi
  elif [[ "${has_findings}" == "false" ]]; then
    case "${REVIEWER_TYPE}" in
      stress_test)
        tick_dimensions_with_verdict "CLEAN" "${now_ts}" "stress_test" ;;
      traceability)
        tick_dimensions_with_verdict "CLEAN" "${now_ts}" "traceability" ;;
      design_quality)
        tick_dimensions_with_verdict "CLEAN" "${now_ts}" "design_quality" ;;
      standard|*)
        tick_dimensions_with_verdict "CLEAN" "${now_ts}" "bug_hunt" "code_quality" ;;
    esac
  else
    case "${REVIEWER_TYPE}" in
      stress_test)
        set_dimension_verdicts "FINDINGS" "stress_test" ;;
      traceability)
        set_dimension_verdicts "FINDINGS" "traceability" ;;
      design_quality)
        set_dimension_verdicts "FINDINGS" "design_quality" ;;
      standard|*)
        set_dimension_verdicts "FINDINGS" "bug_hunt" "code_quality" ;;
    esac
  fi
fi

# --- Agent performance metric recording ---
metric_verdict="findings"
metric_confidence=60
if [[ "${has_findings}" == "false" ]]; then
  metric_verdict="clean"
  metric_confidence=80
fi
record_agent_metric "${REVIEWER_TYPE}" "${metric_verdict}" "${metric_confidence}" &

# --- Cross-session defect pattern recording ---
# When findings are detected, extract a summary line and classify the defect.
if [[ "${has_findings}" == "true" && -n "${review_message}" ]]; then
  # Try to extract the first finding line after VERDICT or a numbered finding
  finding_sample="$(printf '%s\n' "${review_message}" \
    | grep -Eim 1 '^\s*(1[\.\):]|[-*]\s+(bug|issue|finding|problem|concern|defect|risk|error|missing))' \
    | head -c 200 || true)"
  # Fallback: use the first substantial line before VERDICT
  if [[ -z "${finding_sample}" ]]; then
    finding_sample="$(printf '%s\n' "${review_message}" \
      | grep -Eiv '^(VERDICT:|$|\s*#)' \
      | head -n 3 \
      | tr '\n' ' ' \
      | head -c 200 || true)"
  fi
  if [[ -n "${finding_sample}" ]]; then
    defect_cat="$(classify_finding_category "${finding_sample}")"
    record_defect_pattern "${defect_cat}" "${finding_sample}" &
  fi
fi
