#!/usr/bin/env bash

set -euo pipefail

# v1.40.x product-lens F-011: record a user-supplied classification
# correction. Writes a misfire row to both per-session and cross-
# session telemetry, parses optional intent= / domain= directives
# from the reason, and updates the active session's task_intent /
# task_domain state when the parsed values are valid.
#
# Usage: bash ulw-correct-record.sh "<reason text>"

REASON="${1:-}"
if [[ -z "${REASON}" ]]; then
  printf 'No correction reason provided. Usage: /ulw-correct <reason>\n' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # Pick the newest session DIRECTORY — the `*/` glob is load-bearing;
  # state-root files (hooks.log, gate_events.jsonl) out-sort session
  # dirs under bare `ls -t` (same family as the ulw-skip-register.sh
  # crash observed 2026-07-05).
  # shellcheck disable=SC2012
  latest_session="$(cd "${STATE_ROOT}" 2>/dev/null && ls -td -- */ 2>/dev/null | head -1 || true)"
  latest_session="${latest_session%/}"
fi
if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n' >&2
  exit 0
fi

SESSION_ID="${latest_session}"
ensure_session_dir

if ! is_ultrawork_mode; then
  printf 'ULW mode is not active. Correction not recorded.\n' >&2
  exit 0
fi

prior_intent="$(read_state "task_intent")"
prior_domain="$(read_state "task_domain")"
prior_prompt="$(read_state "last_user_prompt")"

# Parse optional intent= / domain= tokens from the reason. The user can
# write free-form text; if they include the tokens we extract them.
corrected_intent=""
corrected_domain=""
case "${REASON}" in
  *intent=execution*)          corrected_intent="execution" ;;
  *intent=continuation*)       corrected_intent="continuation" ;;
  *intent=advisory*)           corrected_intent="advisory" ;;
  *intent=session_management*) corrected_intent="session_management" ;;
  *intent=session-management*) corrected_intent="session_management" ;;
  *intent=checkpoint*)         corrected_intent="checkpoint" ;;
esac
case "${REASON}" in
  *domain=coding*)     corrected_domain="coding" ;;
  *domain=writing*)    corrected_domain="writing" ;;
  *domain=research*)   corrected_domain="research" ;;
  *domain=operations*) corrected_domain="operations" ;;
  *domain=mixed*)      corrected_domain="mixed" ;;
  *domain=general*)    corrected_domain="general" ;;
esac

# Fallback: bare keyword in reason maps to intent if no explicit
# `intent=` was present. Conservative — only a small set of unambiguous
# tokens. Lets `/ulw-correct this is advisory not execution` work.
if [[ -z "${corrected_intent}" ]]; then
  case " ${REASON} " in
    *' advisory '*)          corrected_intent="advisory" ;;
    *' execution '*)         corrected_intent="execution" ;;
    *' continuation '*)      corrected_intent="continuation" ;;
    *' checkpoint '*)        corrected_intent="checkpoint" ;;
    *' session_management '*|*' session-management '*) corrected_intent="session_management" ;;
  esac
fi

ts="$(now_epoch)"
reason_safe="$(printf '%s' "${REASON}" | omc_redact_secrets | tr -d '\000')"
prompt_safe="$(printf '%s' "${prior_prompt}" | omc_redact_secrets | tr -d '\000')"

# Per-session row.
session_row="$(jq -nc \
  --argjson ts "${ts}" \
  --arg prior_intent "${prior_intent}" \
  --arg prior_domain "${prior_domain}" \
  --arg corrected_intent "${corrected_intent}" \
  --arg corrected_domain "${corrected_domain}" \
  --arg reason "${reason_safe}" \
  --arg prompt_preview "${prompt_safe:0:240}" \
  '{
    _v: 1,
    ts: $ts,
    misfire: true,
    corrected_by_user: true,
    prior_intent: $prior_intent,
    prior_domain: $prior_domain,
    corrected_intent: $corrected_intent,
    corrected_domain: $corrected_domain,
    reason: $reason,
    prompt_preview: $prompt_preview
  }')"
append_state "classifier_telemetry.jsonl" "${session_row}"

# Cross-session ledger — same row schema, plus session_id for traceability.
cross_file="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"
mkdir -p "$(dirname "${cross_file}")" 2>/dev/null || true
cross_row="$(jq -nc \
  --argjson ts "${ts}" \
  --arg sid "${SESSION_ID}" \
  --arg prior_intent "${prior_intent}" \
  --arg prior_domain "${prior_domain}" \
  --arg corrected_intent "${corrected_intent}" \
  --arg corrected_domain "${corrected_domain}" \
  --arg reason "${reason_safe}" \
  --arg prompt_preview "${prompt_safe:0:240}" \
  '{
    _v: 1,
    ts: $ts,
    session_id: $sid,
    misfire: true,
    corrected_by_user: true,
    prior_intent: $prior_intent,
    prior_domain: $prior_domain,
    corrected_intent: $corrected_intent,
    corrected_domain: $corrected_domain,
    reason: $reason,
    prompt_preview: $prompt_preview
  }')"
printf '%s\n' "${cross_row}" >> "${cross_file}" 2>/dev/null || true

# v1.43 data-lens F-002: auto-write a classifier-fixture candidate when
# the correction is parseable AND the prompt is non-empty. The candidate
# file is the mechanical bridge between user corrections and the
# regression fixture set under tools/classifier-fixtures/regression.jsonl
# — without this, the misfire signal accumulates in cross-session
# telemetry but a maintainer has to manually re-derive the prompt+label
# pair to extend the fixture. Now /ulw-report can surface "N fixture
# candidates ready to promote" and a maintainer extraction script can
# vet+promote them in bulk.
#
# Schema matches tools/classifier-fixtures/regression.jsonl exactly
# (prompt_preview / intent / domain / note) so promotion is jq-cat with
# vetting, not field-renaming. Falls back to prior_* when only one of
# {intent, domain} was corrected — the fixture captures the COMPLETE
# desired classification, not just the changed dimension.
#
# Skip conditions: empty prompt (nothing to learn from), no parseable
# correction (a misfire row without label ground truth is not useful as
# a fixture).
fixture_candidates_file="${HOME}/.claude/quality-pack/classifier_fixture_candidates.jsonl"
if [[ -n "${prompt_safe}" ]] \
  && { [[ -n "${corrected_intent}" ]] || [[ -n "${corrected_domain}" ]]; }; then
  fixture_intent="${corrected_intent:-${prior_intent}}"
  fixture_domain="${corrected_domain:-${prior_domain}}"
  # Only write when both intent AND domain are non-empty (a fixture row
  # without both labels is unpromotable). A misfire with neither prior
  # nor corrected value (very rare — race during state-init) falls out
  # here naturally.
  if [[ -n "${fixture_intent}" ]] && [[ -n "${fixture_domain}" ]]; then
    fixture_note="user-correction via /ulw-correct"
    [[ -n "${prior_intent}" ]] && [[ -n "${corrected_intent}" ]] && [[ "${prior_intent}" != "${corrected_intent}" ]] \
      && fixture_note="${fixture_note}; intent ${prior_intent}→${corrected_intent}"
    [[ -n "${prior_domain}" ]] && [[ -n "${corrected_domain}" ]] && [[ "${prior_domain}" != "${corrected_domain}" ]] \
      && fixture_note="${fixture_note}; domain ${prior_domain}→${corrected_domain}"
    fixture_row="$(jq -nc \
      --arg prompt_preview "${prompt_safe:0:240}" \
      --arg intent "${fixture_intent}" \
      --arg domain "${fixture_domain}" \
      --arg note "${fixture_note}" \
      --arg sid "${SESSION_ID}" \
      --argjson ts "${ts}" \
      '{
        prompt_preview: $prompt_preview,
        intent: $intent,
        domain: $domain,
        note: $note,
        _source: "ulw-correct",
        _session_id: $sid,
        _ts: $ts
      }' 2>/dev/null || true)"
    if [[ -n "${fixture_row}" ]]; then
      mkdir -p "$(dirname "${fixture_candidates_file}")" 2>/dev/null || true
      printf '%s\n' "${fixture_row}" >> "${fixture_candidates_file}" 2>/dev/null || true
    fi
  fi
fi

# Apply the correction to active session state when values parsed.
applied_parts=()
blocked_parts=()

# v1.42.x stop-guard bypass closure (Bypass-Surface F-005 / SEV-4):
# Refuse mid-turn execution-intent downgrades. The legitimate user-correction
# path fires `/ulw-correct` at the START of a turn (router just wrote
# `last_user_prompt_ts`; no edits have happened yet). An agent self-issued
# downgrade fires LATE in a turn after edits have happened — the only
# observable signal is `last_edit_ts > last_user_prompt_ts`. We refuse the
# downgrade in that case AND record a `intent-downgrade-blocked` gate event
# so cross-session telemetry surfaces the attempt pattern.
#
# Why refuse instead of just logging: the downgrade FROM `execution` collapses
# every execution-gated stop-guard check (no-defer, shortcut-ratio,
# discovered-scope, wave-shape, agent-first, dimension, excellence,
# metis-on-plan, delivery-contract). A single mid-turn write would bypass
# every gate; a forensic log fired post-stop is too late to keep the work
# honest. The override allowed via `OMC_ULW_CORRECT_FORCE=1` exists for
# tests and for the user's explicit "yes I really mean it" recovery.
_intent_downgrade_blocked=0
if [[ -n "${corrected_intent}" ]] \
  && [[ "${corrected_intent}" != "${prior_intent}" ]] \
  && [[ "${prior_intent}" == "execution" ]] \
  && [[ "${corrected_intent}" != "execution" ]] \
  && [[ "${corrected_intent}" != "continuation" ]]; then
  _last_edit_ts="$(read_state "last_edit_ts" 2>/dev/null || true)"
  _last_user_prompt_ts="$(read_state "last_user_prompt_ts" 2>/dev/null || true)"
  _last_edit_ts="${_last_edit_ts:-0}"
  _last_user_prompt_ts="${_last_user_prompt_ts:-0}"
  [[ "${_last_edit_ts}" =~ ^[0-9]+$ ]] || _last_edit_ts=0
  [[ "${_last_user_prompt_ts}" =~ ^[0-9]+$ ]] || _last_user_prompt_ts=0

  if [[ "${_last_edit_ts}" -gt "${_last_user_prompt_ts}" ]]; then
    if [[ "${OMC_ULW_CORRECT_FORCE:-}" != "1" ]]; then
      _intent_downgrade_blocked=1
      blocked_parts+=("intent execution → ${corrected_intent} (mid-turn refused)")
      record_gate_event "intent-downgrade-blocked" "block" \
        "prior=execution" \
        "attempted=${corrected_intent}" \
        "last_edit_ts=${_last_edit_ts}" \
        "last_user_prompt_ts=${_last_user_prompt_ts}" || true
    else
      # v1.42.x audit symmetry: the validator would have blocked this
      # mid-turn downgrade, but OMC_ULW_CORRECT_FORCE=1 flipped the
      # outcome to a pass. Emit a distinct force-bypass event AND
      # increment a per-session counter so /ulw-status surfaces whether
      # the escape valve is being used routinely. Mirrors the ulw-skip
      # and ulw-pause force-bypass logging.
      record_gate_event "intent-downgrade-blocked" "force-bypass" \
        "prior=execution" \
        "attempted=${corrected_intent}" \
        "last_edit_ts=${_last_edit_ts}" \
        "last_user_prompt_ts=${_last_user_prompt_ts}" || true
      _correct_force_count="$(read_state "ulw_correct_force_count" 2>/dev/null || true)"
      _correct_force_count="${_correct_force_count:-0}"
      [[ "${_correct_force_count}" =~ ^[0-9]+$ ]] || _correct_force_count=0
      write_state "ulw_correct_force_count" "$((_correct_force_count + 1))" 2>/dev/null || true
    fi
  fi
fi

if [[ -n "${corrected_intent}" ]] && [[ "${corrected_intent}" != "${prior_intent}" ]] && [[ "${_intent_downgrade_blocked}" -eq 0 ]]; then
  write_state "task_intent" "${corrected_intent}"
  applied_parts+=("intent ${prior_intent:-?} → ${corrected_intent}")
fi
if [[ -n "${corrected_domain}" ]] && [[ "${corrected_domain}" != "${prior_domain}" ]]; then
  write_state "task_domain" "${corrected_domain}"
  applied_parts+=("domain ${prior_domain:-?} → ${corrected_domain}")
fi

if [[ "${#blocked_parts[@]}" -gt 0 ]]; then
  printf 'BLOCKED: %s\n' "$(IFS='; '; printf '%s' "${blocked_parts[*]}")" >&2
  printf '  Reason: an edit has occurred this turn (last_edit_ts=%s > last_user_prompt_ts=%s).\n' "${_last_edit_ts}" "${_last_user_prompt_ts}" >&2
  printf '  Mid-turn execution-intent downgrades collapse every execution-only gate; that is the failure mode this guard catches.\n' >&2
  printf '  If you genuinely need to reclassify a misfire AFTER work has started:\n' >&2
  printf '    1. Submit a NEW user prompt with the correction (the router rewrites task_intent at prompt time without this restriction).\n' >&2
  printf '    2. For a real operational blocker, use /ulw-pause <reason> instead.\n' >&2
  printf '    3. Last-resort, run /ulw-skip <reason> to bypass the gate once (audited).\n' >&2
  printf '  The misfire row WAS recorded for cross-session learning regardless.\n' >&2
fi

if [[ "${#applied_parts[@]}" -gt 0 ]]; then
  printf 'corrected: %s\n' "$(IFS='; '; printf '%s' "${applied_parts[*]}")"
elif [[ "${#blocked_parts[@]}" -eq 0 ]]; then
  printf 'recorded as misfire (no intent= or domain= parseable from reason)\n'
fi

# Exit 4 for blocked downgrade so callers / tests can distinguish from
# clean apply (0) and bad-invocation (2). Non-blocked corrections still
# exit 0 even when no parseable intent/domain was present — same legacy
# behavior.
if [[ "${_intent_downgrade_blocked}" -eq 1 ]]; then
  exit 4
fi
