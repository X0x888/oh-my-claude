#!/usr/bin/env bash
# Compact product-readiness view over the retained essential portfolio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

JSON_MODE=0
SKIP_CLASSIFICATION=0
SKIP_QUALITY_GATES=0
SKIP_REALWORK_VALIDATE=0
PAIRWISE_RECEIPTS=()
PAIRWISE_CAMPAIGN_RECEIPT=""
surfaces='[]'
ok_count=0
skip_count=0
fail_count=0

usage() {
  printf '%s\n' \
    'Usage: bash tools/verify-professional-readiness.sh [options]' \
    '' \
    'Runs the retained professional-readiness surfaces:' \
    '  intent classification, quality gates, and real-work schema validation.' \
    '' \
    'Options:' \
    '  --skip-classification' \
    '  --skip-quality-gates' \
    '  --skip-realwork-validate' \
    '  --pairwise-receipt FILE          Optional sealed raw receipt; repeatable' \
    '  --pairwise-campaign-receipt FILE Required with raw receipts' \
    '  --json'
}

append_surface() {
  local name="$1" status="$2" command="$3" output="$4" rc="$5"
  local summary
  summary="$(awk 'NF { line=$0 } END { print line }' <<<"${output}")"
  [[ -n "${summary}" ]] || summary="command exited ${rc} without output"
  surfaces="$(jq -nc --argjson rows "${surfaces}" --arg name "${name}" \
    --arg status "${status}" --arg command "${command}" --arg summary "${summary}" \
    --arg output "${output}" --argjson exit_code "${rc}" \
    '$rows + [{name:$name,status:$status,command:$command,summary:$summary,output:$output,exit_code:$exit_code}]')"
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${status}" "${name}" "${summary}"
    [[ "${status}" != "FAIL" || -z "${output}" ]] || printf '%s\n' "${output}"
  fi
}

run_surface() {
  local name="$1" command="$2" output rc=0
  output="$(cd "${REPO_ROOT}" && bash -lc "${command}" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    ok_count=$((ok_count + 1))
    append_surface "${name}" "OK" "${command}" "${output}" "${rc}"
  else
    fail_count=$((fail_count + 1))
    append_surface "${name}" "FAIL" "${command}" "${output}" "${rc}"
  fi
}

skip_surface() {
  local name="$1"
  skip_count=$((skip_count + 1))
  append_surface "${name}" "SKIP" "" "skipped by caller" 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-classification) SKIP_CLASSIFICATION=1; shift ;;
    --skip-quality-gates) SKIP_QUALITY_GATES=1; shift ;;
    --skip-realwork-validate) SKIP_REALWORK_VALIDATE=1; shift ;;
    --skip-realwork-scoring) shift ;; # retired compatibility no-op
    # Retired surfaces remain accepted as compatibility no-ops.
    --skip-routing|--skip-design-contract|--skip-inline-design-contract|--skip-benchmark|--skip-realwork-producer|--skip-realwork-pairwise) shift ;;
    --pairwise-receipt)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PAIRWISE_RECEIPTS+=("$2")
      shift 2
      ;;
    --pairwise-campaign-receipt)
      [[ $# -ge 2 && -z "${PAIRWISE_CAMPAIGN_RECEIPT}" ]] || { usage >&2; exit 2; }
      PAIRWISE_CAMPAIGN_RECEIPT="$2"
      shift 2
      ;;
    --pairwise-report)
      printf 'verify-professional-readiness: aggregate reports are not claim evidence\n' >&2
      exit 2
      ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'verify-professional-readiness: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 && -z "${PAIRWISE_CAMPAIGN_RECEIPT}" ]]; then
  printf 'verify-professional-readiness: raw receipts require --pairwise-campaign-receipt\n' >&2
  exit 2
fi
if [[ "${#PAIRWISE_RECEIPTS[@]}" -eq 0 && -n "${PAIRWISE_CAMPAIGN_RECEIPT}" ]]; then
  printf 'verify-professional-readiness: campaign receipt requires raw receipts\n' >&2
  exit 2
fi

[[ "${SKIP_CLASSIFICATION}" -eq 1 ]] \
  && skip_surface classification \
  || run_surface classification 'bash tests/test-intent-classification.sh'
[[ "${SKIP_QUALITY_GATES}" -eq 1 ]] \
  && skip_surface quality_gates \
  || run_surface quality_gates 'bash tests/test-quality-gates.sh'
[[ "${SKIP_REALWORK_VALIDATE}" -eq 1 ]] \
  && skip_surface realwork_validate \
  || run_surface realwork_validate 'bash evals/realwork/run.sh validate'
if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 ]]; then
  receipt_args=""
  for receipt in "${PAIRWISE_RECEIPTS[@]}"; do
    [[ -f "${receipt}" ]] || { printf 'missing pairwise receipt: %s\n' "${receipt}" >&2; exit 2; }
    receipt_args+=" $(printf '%q' "${receipt}")"
  done
  [[ -f "${PAIRWISE_CAMPAIGN_RECEIPT}" ]] \
    || { printf 'missing campaign receipt: %s\n' "${PAIRWISE_CAMPAIGN_RECEIPT}" >&2; exit 2; }
  receipt_args+=" --campaign-receipt $(printf '%q' "${PAIRWISE_CAMPAIGN_RECEIPT}")"
  run_surface pairwise_receipt "bash evals/realwork/pairwise.sh claim-check${receipt_args}"
fi

summary_text="verify-professional-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
message="verify-professional-readiness: retained professional surfaces are green"
[[ "${fail_count}" -eq 0 ]] || message="verify-professional-readiness: retained professional surfaces have failures"

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -nc --arg summary_text "${summary_text}" --arg message "${message}" \
    --argjson ok "${ok_count}" --argjson skip "${skip_count}" \
    --argjson fail "${fail_count}" --argjson surfaces "${surfaces}" \
    '{tool:"verify-professional-readiness",result:(if $fail == 0 then "ok" else "fail" end),counts:{ok:$ok,skip:$skip,fail:$fail},summary_text:$summary_text,message:$message,surfaces:$surfaces}'
else
  printf '%s\n%s\n' "${summary_text}" "${message}"
fi

(( fail_count == 0 ))
