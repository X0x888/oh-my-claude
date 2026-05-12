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
  # shellcheck disable=SC2010
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1 || true)"
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
  --arg ts "${ts}" \
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
  --arg ts "${ts}" \
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

# Apply the correction to active session state when values parsed.
applied_parts=()
if [[ -n "${corrected_intent}" ]] && [[ "${corrected_intent}" != "${prior_intent}" ]]; then
  write_state "task_intent" "${corrected_intent}"
  applied_parts+=("intent ${prior_intent:-?} → ${corrected_intent}")
fi
if [[ -n "${corrected_domain}" ]] && [[ "${corrected_domain}" != "${prior_domain}" ]]; then
  write_state "task_domain" "${corrected_domain}"
  applied_parts+=("domain ${prior_domain:-?} → ${corrected_domain}")
fi

if [[ "${#applied_parts[@]}" -gt 0 ]]; then
  printf 'corrected: %s\n' "$(IFS='; '; printf '%s' "${applied_parts[*]}")"
else
  printf 'recorded as misfire (no intent= or domain= parseable from reason)\n'
fi
