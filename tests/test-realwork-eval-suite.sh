#!/usr/bin/env bash
# test-realwork-eval-suite.sh — schema and scoring regression net for
# outcome-oriented ULW real-work eval scenarios.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNNER="${REPO_ROOT}/evals/realwork/run.sh"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT

printf 'Test 1: scenario validation passes\n'
out="$(bash "${RUNNER}" validate)"
assert_contains "validate scenario count" "Validated 3 real-work scenario(s)" "${out}"

printf 'Test 2: list surfaces scenario ids and risk tiers\n'
out="$(bash "${RUNNER}" list)"
assert_contains "list targeted scenario" "targeted-bugfix" "${out}"
assert_contains "list broad scenario" "broad-project-eval" "${out}"
assert_contains "list high risk" $'broad-project-eval\thigh' "${out}"

printf 'Test 3: perfect result scores 100 and pass=true\n'
cat > "${tmp}/perfect.json" <<'JSON'
{
  "scenario_id": "targeted-bugfix",
  "tokens": 1000,
  "tool_calls": 10,
  "elapsed_seconds": 60,
  "outcomes": {
    "tests_passed": true,
    "targeted_verification": true,
    "review_clean": true,
    "regression_test_added": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/perfect.json")"
assert_eq "perfect score" "100" "$(jq -r '.score' <<<"${score_json}")"
assert_eq "perfect pass" "true" "$(jq -r '.pass' <<<"${score_json}")"

printf 'Test 4: missing outcomes and budget misses reduce score\n'
cat > "${tmp}/imperfect.json" <<'JSON'
{
  "scenario_id": "targeted-bugfix",
  "tokens": 999999,
  "tool_calls": 10,
  "elapsed_seconds": 60,
  "outcomes": {
    "tests_passed": true,
    "targeted_verification": false,
    "review_clean": true,
    "regression_test_added": false,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/imperfect.json")"
assert_eq "imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "missing targeted verification" "targeted_verification" "${score_json}"
assert_contains "missing regression test" "regression_test_added" "${score_json}"
assert_contains "budget tokens" "tokens" "${score_json}"

printf '\nReal-work eval suite tests: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
