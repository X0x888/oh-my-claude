#!/usr/bin/env bash
#
# tools/verify-professional-readiness.sh — top-level product-readiness
# audit across the cross-domain proof surfaces that matter for
# professional users of oh-my-claude.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLASSIFICATION_CMD="${OMC_PRO_READINESS_CLASSIFICATION_CMD:-bash tests/test-intent-classification.sh}"
ROUTING_CMD="${OMC_PRO_READINESS_ROUTING_CMD:-bash tests/test-specialist-routing.sh}"
DESIGN_CONTRACT_CMD="${OMC_PRO_READINESS_DESIGN_CONTRACT_CMD:-bash tests/test-design-contract.sh}"
INLINE_DESIGN_CONTRACT_CMD="${OMC_PRO_READINESS_INLINE_DESIGN_CONTRACT_CMD:-bash tests/test-inline-design-contract.sh}"
BENCHMARK_CMD="${OMC_PRO_READINESS_BENCHMARK_CMD:-bash tests/test-ulw-benchmark-suite.sh}"
REALWORK_VALIDATE_CMD="${OMC_PRO_READINESS_REALWORK_VALIDATE_CMD:-bash evals/realwork/run.sh validate}"
REALWORK_SCORING_CMD="${OMC_PRO_READINESS_REALWORK_SCORING_CMD:-bash tests/test-realwork-eval-suite.sh}"
REALWORK_PRODUCER_CMD="${OMC_PRO_READINESS_REALWORK_PRODUCER_CMD:-bash tests/test-realwork-producer.sh}"
REALWORK_PAIRWISE_CMD="${OMC_PRO_READINESS_REALWORK_PAIRWISE_CMD:-bash tests/test-realwork-pairwise.sh}"
PAIRWISE_RECEIPT_CHECK_CMD="${OMC_PRO_READINESS_PAIRWISE_RECEIPT_CHECK_CMD:-bash evals/realwork/pairwise.sh claim-check}"

SKIP_CLASSIFICATION=0
SKIP_ROUTING=0
SKIP_DESIGN_CONTRACT=0
SKIP_INLINE_DESIGN_CONTRACT=0
SKIP_BENCHMARK=0
SKIP_REALWORK_VALIDATE=0
SKIP_REALWORK_SCORING=0
SKIP_REALWORK_PRODUCER=0
SKIP_REALWORK_PAIRWISE=0
PAIRWISE_RECEIPTS=()
JSON_MODE=0

ok_count=0
skip_count=0
fail_count=0
overall_rc=0
surfaces_json='[]'

usage() {
  cat <<'EOF'
Usage: bash tools/verify-professional-readiness.sh [options]

Runs the canonical product-readiness audit for oh-my-claude across the
proof surfaces that support professional users in coding, design/UI,
native spreadsheet/document/presentation artifact workflows,
quantitative/data-analysis, regulated/high-stakes, writing, research,
scholarly, operations, mixed, advisory, and general flows.

Default surfaces:
  1. intent classification regression net
  2. specialist routing contract
  3. 9-section UI design-contract contract
  4. inline UI contract persistence / extraction contract
  5. canonical ULW benchmark suite
  6. real-work scenario schema validation
  7. real-work scorer contract
  8. real session -> result producer contract
  9. blind pairwise quality-evaluator contract

Optional empirical claim surface:
  --pairwise-receipt FILE      Add one sealed raw pair receipt to the
                               preregistered claim gate. Repeat for every pair;
                               aggregates are deliberately not accepted.

Options:
  --skip-classification       Skip intent-classification coverage.
  --skip-routing              Skip specialist-routing coverage.
  --skip-design-contract      Skip the 9-section UI contract regression net.
  --skip-inline-design-contract
                               Skip the inline design-contract persistence net.
  --skip-benchmark            Skip the canonical ULW benchmark suite.
  --skip-realwork-validate    Skip scenario schema validation.
  --skip-realwork-scoring     Skip the scorer regression net.
  --skip-realwork-producer    Skip the producer regression net.
  --skip-realwork-pairwise    Skip the zero-spend pairwise evaluator net.
  --json                      Emit a machine-readable JSON report.
EOF
}

append_surface_json() {
  local name="$1"
  local status="$2"
  local summary="$3"
  local command="$4"
  local output="$5"
  local exit_code="$6"

  surfaces_json="$(
    jq -nc \
      --argjson arr "${surfaces_json}" \
      --arg name "${name}" \
      --arg status "${status}" \
      --arg summary "${summary}" \
      --arg command "${command}" \
      --arg output "${output}" \
      --argjson exit_code "${exit_code}" \
      '$arr + [{
        name: $name,
        status: $status,
        summary: $summary,
        command: $command,
        output: $output,
        exit_code: $exit_code
      }]'
  )"
}

last_nonempty_line() {
  local text="$1"
  awk 'NF { line=$0 } END { print line }' <<<"${text}"
}

summarize_command_output() {
  local text="$1"
  local last_line=""
  local pass_line=""
  local fail_line=""

  last_line="$(last_nonempty_line "${text}")"
  pass_line="$(awk '/^PASS:[[:space:]]*[0-9]+$/ { line=$0 } END { print line }' <<<"${text}")"
  fail_line="$(awk '/^FAIL:[[:space:]]*[0-9]+$/ { line=$0 } END { print line }' <<<"${text}")"

  if [[ -n "${pass_line}" && -n "${fail_line}" ]]; then
    printf '%s, %s' "${pass_line}" "${fail_line}"
    return 0
  fi

  printf '%s' "${last_line}"
}

record_skip() {
  local name="$1"
  local summary="$2"
  skip_count=$((skip_count + 1))
  append_surface_json "${name}" "SKIP" "${summary}" "" "" 0
  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf 'SKIP\t%s\t%s\n' "${name}" "${summary}"
  fi
}

run_surface() {
  local name="$1"
  local command="$2"
  local output=""
  local summary=""
  local rc=0
  local status="OK"

  if output="$(cd "${REPO_ROOT}" && bash -lc "${command}" 2>&1)"; then
    rc=0
    ok_count=$((ok_count + 1))
  else
    rc=$?
    status="FAIL"
    fail_count=$((fail_count + 1))
    overall_rc=1
  fi

  if [[ "${name}" == "pairwise_receipt" ]] \
      && printf '%s' "${output}" | jq -e '.pass | type == "boolean"' >/dev/null 2>&1; then
    summary="$(printf '%s' "${output}" | jq -r '
      if .pass then "pairwise claim gate: PASS"
      else "pairwise claim gate: FAIL (" + ((.failures // []) | join(", ")) + ")"
      end
    ')"
  else
    summary="$(summarize_command_output "${output}")"
  fi
  if [[ -z "${summary}" ]]; then
    if [[ "${rc}" -eq 0 ]]; then
      summary="command completed without output"
    else
      summary="command exited ${rc} without output"
    fi
  fi

  append_surface_json "${name}" "${status}" "${summary}" "${command}" "${output}" "${rc}"

  if [[ "${JSON_MODE}" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "${status}" "${name}" "${summary}"
    if [[ "${status}" == "FAIL" && -n "${output}" ]]; then
      printf '\n[%s]\n%s\n' "${name}" "${output}"
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-classification)
      SKIP_CLASSIFICATION=1
      shift
      ;;
    --skip-routing)
      SKIP_ROUTING=1
      shift
      ;;
    --skip-design-contract)
      SKIP_DESIGN_CONTRACT=1
      shift
      ;;
    --skip-inline-design-contract)
      SKIP_INLINE_DESIGN_CONTRACT=1
      shift
      ;;
    --skip-benchmark)
      SKIP_BENCHMARK=1
      shift
      ;;
    --skip-realwork-validate)
      SKIP_REALWORK_VALIDATE=1
      shift
      ;;
    --skip-realwork-scoring)
      SKIP_REALWORK_SCORING=1
      shift
      ;;
    --skip-realwork-producer)
      SKIP_REALWORK_PRODUCER=1
      shift
      ;;
    --skip-realwork-pairwise)
      SKIP_REALWORK_PAIRWISE=1
      shift
      ;;
    --pairwise-receipt)
      [[ $# -ge 2 && -n "${2:-}" ]] || {
        printf 'verify-professional-readiness: --pairwise-receipt requires a file\n' >&2
        exit 2
      }
      PAIRWISE_RECEIPTS+=("$2")
      shift 2
      ;;
    --pairwise-report)
      printf 'verify-professional-readiness: aggregate reports are not evidence; pass every raw receipt with --pairwise-receipt\n' >&2
      exit 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'verify-professional-readiness: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf 'verify-professional-readiness: unexpected positional arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 ]]; then
  for pairwise_index in "${!PAIRWISE_RECEIPTS[@]}"; do
    pairwise_receipt="${PAIRWISE_RECEIPTS[$pairwise_index]}"
    [[ -f "${pairwise_receipt}" ]] || {
    printf 'verify-professional-readiness: pairwise receipt not found: %s\n' "${pairwise_receipt}" >&2
    exit 2
    }
    PAIRWISE_RECEIPTS[pairwise_index]="$(cd "$(dirname "${pairwise_receipt}")" && pwd -P)/$(basename "${pairwise_receipt}")"
  done
fi

if [[ "${SKIP_CLASSIFICATION}" -eq 1 ]]; then
  record_skip "classification" "verify-professional-readiness: classification audit skipped by caller"
else
  run_surface "classification" "${CLASSIFICATION_CMD}"
fi

if [[ "${SKIP_ROUTING}" -eq 1 ]]; then
  record_skip "routing" "verify-professional-readiness: routing audit skipped by caller"
else
  run_surface "routing" "${ROUTING_CMD}"
fi

if [[ "${SKIP_DESIGN_CONTRACT}" -eq 1 ]]; then
  record_skip "design_contract" "verify-professional-readiness: design-contract audit skipped by caller"
else
  run_surface "design_contract" "${DESIGN_CONTRACT_CMD}"
fi

if [[ "${SKIP_INLINE_DESIGN_CONTRACT}" -eq 1 ]]; then
  record_skip "inline_design_contract" "verify-professional-readiness: inline design-contract audit skipped by caller"
else
  run_surface "inline_design_contract" "${INLINE_DESIGN_CONTRACT_CMD}"
fi

if [[ "${SKIP_BENCHMARK}" -eq 1 ]]; then
  record_skip "benchmark" "verify-professional-readiness: benchmark audit skipped by caller"
else
  run_surface "benchmark" "${BENCHMARK_CMD}"
fi

if [[ "${SKIP_REALWORK_VALIDATE}" -eq 1 ]]; then
  record_skip "realwork_validate" "verify-professional-readiness: realwork schema validation skipped by caller"
else
  run_surface "realwork_validate" "${REALWORK_VALIDATE_CMD}"
fi

if [[ "${SKIP_REALWORK_SCORING}" -eq 1 ]]; then
  record_skip "realwork_scoring" "verify-professional-readiness: realwork scorer audit skipped by caller"
else
  run_surface "realwork_scoring" "${REALWORK_SCORING_CMD}"
fi

if [[ "${SKIP_REALWORK_PRODUCER}" -eq 1 ]]; then
  record_skip "realwork_producer" "verify-professional-readiness: realwork producer audit skipped by caller"
else
  run_surface "realwork_producer" "${REALWORK_PRODUCER_CMD}"
fi

if [[ "${SKIP_REALWORK_PAIRWISE}" -eq 1 ]]; then
  record_skip "realwork_pairwise" "verify-professional-readiness: realwork pairwise audit skipped by caller"
else
  run_surface "realwork_pairwise" "${REALWORK_PAIRWISE_CMD}"
fi

if [[ "${#PAIRWISE_RECEIPTS[@]}" -gt 0 ]]; then
  pairwise_receipt_args=""
  for pairwise_receipt in "${PAIRWISE_RECEIPTS[@]}"; do
    pairwise_receipt_args+=" $(printf '%q' "${pairwise_receipt}")"
  done
  run_surface "pairwise_receipt" "${PAIRWISE_RECEIPT_CHECK_CMD}${pairwise_receipt_args}"
fi

summary_text="verify-professional-readiness: summary: ${ok_count} OK, ${skip_count} SKIP, ${fail_count} FAIL"
message=""
if [[ "${fail_count}" -eq 0 && "${ok_count}" -gt 0 ]]; then
  message="verify-professional-readiness: professional readiness is green across classification, routing, UI design-contract, benchmark, and real-work proof surfaces"
elif [[ "${ok_count}" -eq 0 && "${skip_count}" -gt 0 ]]; then
  message="verify-professional-readiness: no proof surfaces were selected"
else
  message="verify-professional-readiness: professional readiness has failing proof surfaces"
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -nc \
    --arg tool "verify-professional-readiness" \
    --arg repo_root "${REPO_ROOT}" \
    --arg summary_text "${summary_text}" \
    --arg message "${message}" \
    --argjson ok_count "${ok_count}" \
    --argjson skip_count "${skip_count}" \
    --argjson fail_count "${fail_count}" \
    --argjson surfaces "${surfaces_json}" \
    '{
      tool: $tool,
      repo_root: $repo_root,
      result: (if $fail_count == 0 then "ok" else "fail" end),
      counts: {
        ok: $ok_count,
        skip: $skip_count,
        fail: $fail_count
      },
      summary_text: $summary_text,
      message: $message,
      surfaces: $surfaces
    }'
else
  printf '%s\n' "${summary_text}"
  printf '%s\n' "${message}"
fi

exit "${overall_rc}"
