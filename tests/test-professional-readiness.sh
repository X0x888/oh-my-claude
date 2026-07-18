#!/usr/bin/env bash
# test-professional-readiness.sh — regression net for
# tools/verify-professional-readiness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/verify-professional-readiness.sh"
README_REAL="${REPO_ROOT}/README.md"
CONTRIBUTING_REAL="${REPO_ROOT}/CONTRIBUTING.md"
CLAUDE_REAL="${REPO_ROOT}/CLAUDE.md"
AGENTS_REAL="${REPO_ROOT}/AGENTS.md"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_jq_eq() {
  local label="$1" query="$2" expected="$3" json="$4"
  local actual
  actual="$(printf '%s' "${json}" | jq -r "${query}")"
  assert_eq "${label}" "${expected}" "${actual}"
}

TMP_DIR="$(mktemp -d -t professional-readiness-XXXXXX)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# mk_stub lives in tests/lib/composition-stubs.sh — shared across the
# readiness-composer test family. See that file's header for the contract.
# shellcheck source=lib/composition-stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/composition-stubs.sh"

run_tool() {
  local classification_cmd="$1"
  local routing_cmd="$2"
  local design_contract_cmd="$3"
  local inline_design_contract_cmd="$4"
  local benchmark_cmd="$5"
  local realwork_validate_cmd="$6"
  local realwork_scoring_cmd="$7"
  local realwork_producer_cmd="$8"
  local realwork_pairwise_cmd="$9"
  local pairwise_receipt_check_cmd="${PAIRWISE_RECEIPT_CHECK_OVERRIDE:-bash evals/realwork/pairwise.sh claim-check}"
  shift 9

  env \
    OMC_PRO_READINESS_CLASSIFICATION_CMD="bash ${classification_cmd}" \
    OMC_PRO_READINESS_ROUTING_CMD="bash ${routing_cmd}" \
    OMC_PRO_READINESS_DESIGN_CONTRACT_CMD="bash ${design_contract_cmd}" \
    OMC_PRO_READINESS_INLINE_DESIGN_CONTRACT_CMD="bash ${inline_design_contract_cmd}" \
    OMC_PRO_READINESS_BENCHMARK_CMD="bash ${benchmark_cmd}" \
    OMC_PRO_READINESS_REALWORK_VALIDATE_CMD="bash ${realwork_validate_cmd}" \
    OMC_PRO_READINESS_REALWORK_SCORING_CMD="bash ${realwork_scoring_cmd}" \
    OMC_PRO_READINESS_REALWORK_PRODUCER_CMD="bash ${realwork_producer_cmd}" \
    OMC_PRO_READINESS_REALWORK_PAIRWISE_CMD="bash ${realwork_pairwise_cmd}" \
    OMC_PRO_READINESS_PAIRWISE_RECEIPT_CHECK_CMD="${pairwise_receipt_check_cmd}" \
    bash "${TOOL}" "$@"
}

classification_ok="$(mk_stub classification-ok 0 'intent-classification: 539 passed, 0 failed')"
routing_ok="$(mk_stub routing-ok 0 'specialist-routing: 79 passed, 0 failed')"
design_contract_ok="$(mk_stub design-contract-ok 0 'test-design-contract: 162/162 passed')"
inline_design_contract_ok="$(mk_stub inline-design-contract-ok 0 'Testing write_session_design_contract...' 'PASS: 68' 'FAIL: 0')"
routing_fail="$(mk_stub routing-fail 1 'routing trace line' 'specialist-routing: 78 passed, 1 failed')"
benchmark_ok="$(mk_stub benchmark-ok 0 'ULW benchmark suite: 134 passed, 0 failed')"
realwork_validate_ok="$(mk_stub realwork-validate-ok 0 'Validated 20 real-work scenario(s)')"
realwork_scoring_ok="$(mk_stub realwork-scoring-ok 0 'Real-work eval suite tests: 53 passed, 0 failed')"
realwork_producer_ok="$(mk_stub realwork-producer-ok 0 'realwork-producer tests: 97 passed, 0 failed')"
realwork_pairwise_ok="$(mk_stub realwork-pairwise-ok 0 'real-work pairwise evaluator tests: 68 passed, 0 failed')"

printf 'Test 1: all-green text mode composes the proof surfaces\n'
out="$(
  run_tool \
    "${classification_ok}" \
    "${routing_ok}" \
    "${design_contract_ok}" \
    "${inline_design_contract_ok}" \
    "${benchmark_ok}" \
    "${realwork_validate_ok}" \
    "${realwork_scoring_ok}" \
    "${realwork_producer_ok}" \
    "${realwork_pairwise_ok}" 2>&1
)"
assert_contains "T1: classification surface ok" $'OK\tclassification\tintent-classification: 539 passed, 0 failed' "${out}"
assert_contains "T1: routing surface ok" $'OK\trouting\tspecialist-routing: 79 passed, 0 failed' "${out}"
assert_contains "T1: design-contract surface ok" $'OK\tdesign_contract\ttest-design-contract: 162/162 passed' "${out}"
assert_contains "T1: inline design-contract surface ok" $'OK\tinline_design_contract\tPASS: 68, FAIL: 0' "${out}"
assert_contains "T1: benchmark surface ok" $'OK\tbenchmark\tULW benchmark suite: 134 passed, 0 failed' "${out}"
assert_contains "T1: realwork validate ok" $'OK\trealwork_validate\tValidated 20 real-work scenario(s)' "${out}"
assert_contains "T1: realwork scoring ok" $'OK\trealwork_scoring\tReal-work eval suite tests: 53 passed, 0 failed' "${out}"
assert_contains "T1: realwork producer ok" $'OK\trealwork_producer\trealwork-producer tests: 97 passed, 0 failed' "${out}"
assert_contains "T1: realwork pairwise ok" $'OK\trealwork_pairwise\treal-work pairwise evaluator tests: 68 passed, 0 failed' "${out}"
assert_contains "T1: summary text" "verify-professional-readiness: summary: 9 OK, 0 SKIP, 0 FAIL" "${out}"
assert_contains "T1: green message" "verify-professional-readiness: professional readiness is green across classification, routing, UI design-contract, benchmark, and real-work proof surfaces" "${out}"

printf 'Test 2: json mode reports failing and skipped surfaces structurally\n'
set +e
out="$(
  run_tool \
    "${classification_ok}" \
    "${routing_fail}" \
    "${design_contract_ok}" \
    "${inline_design_contract_ok}" \
    "${benchmark_ok}" \
    "${realwork_validate_ok}" \
    "${realwork_scoring_ok}" \
    "${realwork_producer_ok}" \
    "${realwork_pairwise_ok}" \
    --skip-design-contract \
    --skip-benchmark \
    --skip-realwork-producer \
    --skip-realwork-pairwise \
    --json 2>&1
)"
rc="$?"
set -e
assert_eq "T2: json mode exits non-zero on failure" "1" "${rc}"
assert_jq_eq "T2: top-level result is fail" '.result' "fail" "${out}"
assert_jq_eq "T2: ok count" '.counts.ok' "4" "${out}"
assert_jq_eq "T2: skip count" '.counts.skip' "4" "${out}"
assert_jq_eq "T2: fail count" '.counts.fail' "1" "${out}"
assert_jq_eq "T2: routing status is FAIL" '.surfaces[] | select(.name=="routing") | .status' "FAIL" "${out}"
assert_jq_eq "T2: design-contract status is SKIP" '.surfaces[] | select(.name=="design_contract") | .status' "SKIP" "${out}"
assert_jq_eq "T2: benchmark status is SKIP" '.surfaces[] | select(.name=="benchmark") | .status' "SKIP" "${out}"
assert_jq_eq "T2: producer status is SKIP" '.surfaces[] | select(.name=="realwork_producer") | .status' "SKIP" "${out}"
assert_jq_eq "T2: pairwise status is SKIP" '.surfaces[] | select(.name=="realwork_pairwise") | .status' "SKIP" "${out}"
assert_jq_eq "T2: inline design-contract status is OK" '.surfaces[] | select(.name=="inline_design_contract") | .status' "OK" "${out}"
assert_jq_eq "T2: inline design-contract summary is normalized" '.surfaces[] | select(.name=="inline_design_contract") | .summary' "PASS: 68, FAIL: 0" "${out}"
assert_jq_eq "T2: routing output captured" '.surfaces[] | select(.name=="routing") | .output' $'routing trace line\nspecialist-routing: 78 passed, 1 failed' "${out}"
assert_jq_eq "T2: design-contract skip summary captured" '.surfaces[] | select(.name=="design_contract") | .summary' "verify-professional-readiness: design-contract audit skipped by caller" "${out}"
assert_jq_eq "T2: skip summary captured" '.surfaces[] | select(.name=="benchmark") | .summary' "verify-professional-readiness: benchmark audit skipped by caller" "${out}"

printf 'Test 3: help output documents the composed readiness surfaces\n'
out="$(bash "${TOOL}" --help)"
assert_contains "T3: help mentions classification" "intent classification regression net" "${out}"
assert_contains "T3: help mentions routing" "specialist routing contract" "${out}"
assert_contains "T3: help mentions 9-section design contract" "9-section UI design-contract contract" "${out}"
assert_contains "T3: help mentions inline design contract" "inline UI contract persistence / extraction contract" "${out}"
assert_contains "T3: help mentions benchmark" "canonical ULW benchmark suite" "${out}"
assert_contains "T3: help mentions design/UI coverage" "design/UI" "${out}"
assert_contains "T3: help mentions native artifact coverage" "native spreadsheet/document/presentation artifact workflows" "${out}"
assert_contains "T3: help mentions quantitative coverage" "quantitative/data-analysis" "${out}"
assert_contains "T3: help mentions regulated coverage" "regulated/high-stakes" "${out}"
assert_contains "T3: help mentions producer" "real session -> result producer contract" "${out}"
assert_contains "T3: help mentions pairwise evaluator" "blind pairwise quality-evaluator contract" "${out}"
assert_contains "T3: help mentions optional receipt" "--pairwise-receipt FILE" "${out}"

printf 'Test 4: an explicitly supplied pairwise receipt is a fail-closed surface\n'
pairwise_receipt="${TMP_DIR}/campaign receipt.json"
printf '{}\n' > "${pairwise_receipt}"
receipt_ok="$(mk_stub pairwise-receipt-ok 0 '{"pass":true,"failures":[]}')"
receipt_fail="$(mk_stub pairwise-receipt-fail 1 '{"pass":false,"failures":["win_rate"]}')"

out="$(
  PAIRWISE_RECEIPT_CHECK_OVERRIDE="bash ${receipt_ok}" \
    run_tool \
      "${classification_ok}" \
      "${routing_ok}" \
      "${design_contract_ok}" \
      "${inline_design_contract_ok}" \
      "${benchmark_ok}" \
      "${realwork_validate_ok}" \
      "${realwork_scoring_ok}" \
      "${realwork_producer_ok}" \
      "${realwork_pairwise_ok}" \
      --pairwise-receipt "${pairwise_receipt}" \
      --json
)"
assert_jq_eq "T4: receipt adds a tenth surface" '.counts.ok' "10" "${out}"
assert_jq_eq "T4: passing receipt is OK" '.surfaces[] | select(.name=="pairwise_receipt") | .status' "OK" "${out}"
assert_jq_eq "T4: passing receipt has a useful summary" '.surfaces[] | select(.name=="pairwise_receipt") | .summary' 'pairwise claim gate: PASS' "${out}"
assert_jq_eq "T4: receipt output is captured" '.surfaces[] | select(.name=="pairwise_receipt") | .output' '{"pass":true,"failures":[]}' "${out}"
assert_contains "T4: spaced receipt path reaches command" "campaign\\ receipt.json" "$(printf '%s' "${out}" | jq -r '.surfaces[] | select(.name=="pairwise_receipt") | .command')"

set +e
out="$(
  PAIRWISE_RECEIPT_CHECK_OVERRIDE="bash ${receipt_fail}" \
    run_tool \
      "${classification_ok}" \
      "${routing_ok}" \
      "${design_contract_ok}" \
      "${inline_design_contract_ok}" \
      "${benchmark_ok}" \
      "${realwork_validate_ok}" \
      "${realwork_scoring_ok}" \
      "${realwork_producer_ok}" \
      "${realwork_pairwise_ok}" \
      --pairwise-receipt "${pairwise_receipt}" \
      --json 2>&1
)"
rc="$?"
set -e
assert_eq "T4: failed claim receipt exits non-zero" "1" "${rc}"
assert_jq_eq "T4: failed receipt is FAIL" '.surfaces[] | select(.name=="pairwise_receipt") | .status' "FAIL" "${out}"
assert_jq_eq "T4: failed receipt names the empirical blocker" '.surfaces[] | select(.name=="pairwise_receipt") | .summary' 'pairwise claim gate: FAIL (win_rate)' "${out}"
assert_jq_eq "T4: failed receipt makes readiness fail" '.result' "fail" "${out}"

printf 'Test 5: docs inventory the professional-readiness helper\n'
readme_contents="$(cat "${README_REAL}")"
contributing_contents="$(cat "${CONTRIBUTING_REAL}")"
claude_contents="$(cat "${CLAUDE_REAL}")"
agents_contents="$(cat "${AGENTS_REAL}")"
assert_contains "T5: README mentions helper" 'tools/verify-professional-readiness.sh' "${readme_contents}"
assert_contains "T5: CONTRIBUTING mentions helper" 'tools/verify-professional-readiness.sh' "${contributing_contents}"
assert_contains "T5: CLAUDE mentions helper" 'verify-professional-readiness.sh' "${claude_contents}"
assert_contains "T5: AGENTS tools inventory mentions helper" 'verify-professional-readiness.sh' "${agents_contents}"

printf '\nprofessional-readiness tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
