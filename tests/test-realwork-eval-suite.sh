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
assert_contains "validate scenario count" "Validated 13 real-work scenario(s)" "${out}"

printf 'Test 2: list surfaces scenario ids and risk tiers\n'
out="$(bash "${RUNNER}" list)"
assert_contains "list targeted scenario" "targeted-bugfix" "${out}"
assert_contains "list broad scenario" "broad-project-eval" "${out}"
assert_contains "list ui scenario" "ui-shipping" "${out}"
assert_contains "list advisory code scenario" "advisory-code-guidance" "${out}"
assert_contains "list advisory writing scenario" "advisory-writing-guidance" "${out}"
assert_contains "list advisory research scenario" "advisory-research-guidance" "${out}"
assert_contains "list advisory operations scenario" "advisory-operations-guidance" "${out}"
assert_contains "list mixed rollout scenario" "mixed-rollout-migration" "${out}"
assert_contains "list mixed cutover scenario" "mixed-cutover-checklist" "${out}"
assert_contains "list writing scenario" "writing-proposal" "${out}"
assert_contains "list research scenario" "research-brief" "${out}"
assert_contains "list scholarly scenario" "scholarly-review" "${out}"
assert_contains "list operations scenario" "operations-plan" "${out}"
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

printf 'Test 5: writing scenario scores 100 when doc-review and delivery land\n'
cat > "${tmp}/writing-perfect.json" <<'JSON'
{
  "scenario_id": "writing-proposal",
  "tokens": 1200,
  "tool_calls": 8,
  "elapsed_seconds": 90,
  "outcomes": {
    "writer_deliverable_ready": true,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/writing-perfect.json")"
assert_eq "writing perfect score" "100" "$(jq -r '.score' <<<"${score_json}")"
assert_eq "writing perfect pass" "true" "$(jq -r '.pass' <<<"${score_json}")"

printf 'Test 6: UI shipping scenario requires visual verification and clean design review\n'
cat > "${tmp}/ui-imperfect.json" <<'JSON'
{
  "scenario_id": "ui-shipping",
  "tokens": 1600,
  "tool_calls": 14,
  "elapsed_seconds": 120,
  "outcomes": {
    "design_contract_recorded": true,
    "ui_files_changed": true,
    "browser_or_visual_verification": false,
    "design_review_clean": true,
    "no_layout_overlap": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/ui-imperfect.json")"
assert_eq "ui imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "ui missing visual verification" "browser_or_visual_verification" "${score_json}"

printf 'Test 7: research scenario exposes missing non-coding proof\n'
cat > "${tmp}/research-imperfect.json" <<'JSON'
{
  "scenario_id": "research-brief",
  "tokens": 1800,
  "tool_calls": 12,
  "elapsed_seconds": 120,
  "outcomes": {
    "research_report_ready": true,
    "analysis_specialist_coverage": false,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/research-imperfect.json")"
assert_eq "research imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "research missing analysis coverage" "analysis_specialist_coverage" "${score_json}"

printf 'Test 8: scholarly mixed workflow requires both research and drafting proof\n'
cat > "${tmp}/scholarly-imperfect.json" <<'JSON'
{
  "scenario_id": "scholarly-review",
  "tokens": 2500,
  "tool_calls": 15,
  "elapsed_seconds": 180,
  "outcomes": {
    "research_report_ready": true,
    "analysis_specialist_coverage": true,
    "writer_deliverable_ready": false,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/scholarly-imperfect.json")"
assert_eq "scholarly imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "scholarly missing writer proof" "writer_deliverable_ready" "${score_json}"

printf 'Test 9: advisory-over-code scenario requires direct answer and grounded inspection\n'
cat > "${tmp}/advisory-code-imperfect.json" <<'JSON'
{
  "scenario_id": "advisory-code-guidance",
  "tokens": 900,
  "tool_calls": 6,
  "elapsed_seconds": 80,
  "outcomes": {
    "direct_advisory_answer": true,
    "advisory_code_grounded": false
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/advisory-code-imperfect.json")"
assert_eq "advisory code imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "advisory code missing grounding" "advisory_code_grounded" "${score_json}"

printf 'Test 10: advisory research scenario scores 100 when direct answer stays research-grounded\n'
cat > "${tmp}/advisory-research-perfect.json" <<'JSON'
{
  "scenario_id": "advisory-research-guidance",
  "tokens": 1200,
  "tool_calls": 9,
  "elapsed_seconds": 90,
  "outcomes": {
    "direct_advisory_answer": true,
    "research_report_ready": true,
    "analysis_specialist_coverage": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/advisory-research-perfect.json")"
assert_eq "advisory research perfect score" "100" "$(jq -r '.score' <<<"${score_json}")"
assert_eq "advisory research perfect pass" "true" "$(jq -r '.pass' <<<"${score_json}")"

printf 'Test 11: advisory writing scenario exposes missing specialist coverage\n'
cat > "${tmp}/advisory-writing-imperfect.json" <<'JSON'
{
  "scenario_id": "advisory-writing-guidance",
  "tokens": 800,
  "tool_calls": 4,
  "elapsed_seconds": 60,
  "outcomes": {
    "direct_advisory_answer": true,
    "writing_specialist_coverage": false
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/advisory-writing-imperfect.json")"
assert_eq "advisory writing imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "advisory writing missing specialist coverage" "writing_specialist_coverage" "${score_json}"

printf 'Test 12: mixed code-plus-non-code scenario requires both implementation and communication proof\n'
cat > "${tmp}/mixed-imperfect.json" <<'JSON'
{
  "scenario_id": "mixed-rollout-migration",
  "tokens": 3000,
  "tool_calls": 20,
  "elapsed_seconds": 240,
  "outcomes": {
    "tests_passed": true,
    "targeted_verification": true,
    "regression_test_added": true,
    "review_clean": true,
    "research_report_ready": true,
    "analysis_specialist_coverage": true,
    "writer_deliverable_ready": false,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/mixed-imperfect.json")"
assert_eq "mixed imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "mixed missing writer proof" "writer_deliverable_ready" "${score_json}"

printf 'Test 13: mixed code-plus-operations scenario requires delivered operations artifact\n'
cat > "${tmp}/mixed-ops-imperfect.json" <<'JSON'
{
  "scenario_id": "mixed-cutover-checklist",
  "tokens": 2800,
  "tool_calls": 18,
  "elapsed_seconds": 220,
  "outcomes": {
    "tests_passed": true,
    "targeted_verification": true,
    "regression_test_added": true,
    "review_clean": true,
    "operations_deliverable_ready": false,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/mixed-ops-imperfect.json")"
assert_eq "mixed ops imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "mixed ops missing delivered operations artifact" "operations_deliverable_ready" "${score_json}"

printf '\nReal-work eval suite tests: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
