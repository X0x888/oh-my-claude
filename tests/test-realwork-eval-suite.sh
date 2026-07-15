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
assert_contains "validate scenario count" "Validated 20 real-work scenario(s)" "${out}"

printf 'Test 2: list surfaces scenario ids and risk tiers\n'
out="$(bash "${RUNNER}" list)"
assert_contains "list targeted scenario" "targeted-bugfix" "${out}"
assert_contains "list broad scenario" "broad-project-eval" "${out}"
assert_contains "list ui scenario" "ui-shipping" "${out}"
assert_contains "list advisory code scenario" "advisory-code-guidance" "${out}"
assert_contains "list advisory writing scenario" "advisory-writing-guidance" "${out}"
assert_contains "list advisory research scenario" "advisory-research-guidance" "${out}"
assert_contains "list advisory operations scenario" "advisory-operations-guidance" "${out}"
assert_contains "list advisory data scenario" "advisory-data-guidance" "${out}"
assert_contains "list advisory legal scenario" "advisory-legal-guidance" "${out}"
assert_contains "list mixed rollout scenario" "mixed-rollout-migration" "${out}"
assert_contains "list mixed cutover scenario" "mixed-cutover-checklist" "${out}"
assert_contains "list quantitative brief scenario" "quantitative-kpi-brief" "${out}"
assert_contains "list quantitative workbook scenario" "quantitative-workbook-model" "${out}"
assert_contains "list presentation deck scenario" "presentation-board-deck" "${out}"
assert_contains "list document docx scenario" "document-policy-docx" "${out}"
assert_contains "list regulated compliance memo scenario" "regulated-compliance-memo" "${out}"
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

printf 'Test 10b: advisory data scenario requires both direct answer and data-specialist coverage\n'
cat > "${tmp}/advisory-data-imperfect.json" <<'JSON'
{
  "scenario_id": "advisory-data-guidance",
  "tokens": 1000,
  "tool_calls": 7,
  "elapsed_seconds": 90,
  "outcomes": {
    "direct_advisory_answer": true,
    "data_specialist_coverage": false,
    "analysis_specialist_coverage": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/advisory-data-imperfect.json")"
assert_eq "advisory data imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "advisory data missing data-specialist coverage" "data_specialist_coverage" "${score_json}"

printf 'Test 10c: advisory legal scenario requires explicit regulated scope boundaries\n'
cat > "${tmp}/advisory-legal-imperfect.json" <<'JSON'
{
  "scenario_id": "advisory-legal-guidance",
  "tokens": 1100,
  "tool_calls": 8,
  "elapsed_seconds": 100,
  "outcomes": {
    "direct_advisory_answer": true,
    "research_report_ready": true,
    "analysis_specialist_coverage": true,
    "regulated_scope_explicit": false
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/advisory-legal-imperfect.json")"
assert_eq "advisory legal imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "advisory legal missing regulated scope" "regulated_scope_explicit" "${score_json}"

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
    "regression_test_added": false,
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
assert_eq "mixed rollout does not require an unrequested new test" "false" \
  "$(jq -r '.missing_outcomes | index("regression_test_added") != null' <<<"${score_json}")"

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

printf 'Test 13b: quantitative KPI brief requires data-specialist coverage and drafted deliverable\n'
cat > "${tmp}/quantitative-imperfect.json" <<'JSON'
{
  "scenario_id": "quantitative-kpi-brief",
  "tokens": 2600,
  "tool_calls": 18,
  "elapsed_seconds": 180,
  "outcomes": {
    "data_specialist_coverage": false,
    "analysis_specialist_coverage": true,
    "writer_deliverable_ready": false,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/quantitative-imperfect.json")"
assert_eq "quantitative imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "quantitative missing data-specialist coverage" "data_specialist_coverage" "${score_json}"
assert_contains "quantitative missing writer proof" "writer_deliverable_ready" "${score_json}"

printf 'Test 13c: quantitative workbook scenario requires a real spreadsheet artifact\n'
cat > "${tmp}/quantitative-workbook-imperfect.json" <<'JSON'
{
  "scenario_id": "quantitative-workbook-model",
  "tokens": 2500,
  "tool_calls": 16,
  "elapsed_seconds": 170,
  "outcomes": {
    "data_specialist_coverage": true,
    "analysis_specialist_coverage": true,
    "spreadsheet_artifact_ready": false,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/quantitative-workbook-imperfect.json")"
assert_eq "quantitative workbook imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "quantitative workbook missing spreadsheet artifact" "spreadsheet_artifact_ready" "${score_json}"

printf 'Test 13d: presentation deck scenario requires a real deck artifact\n'
cat > "${tmp}/presentation-deck-imperfect.json" <<'JSON'
{
  "scenario_id": "presentation-board-deck",
  "tokens": 2200,
  "tool_calls": 15,
  "elapsed_seconds": 180,
  "outcomes": {
    "presentation_artifact_ready": false,
    "operations_deliverable_ready": true,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/presentation-deck-imperfect.json")"
assert_eq "presentation deck imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "presentation deck missing artifact" "presentation_artifact_ready" "${score_json}"

printf 'Test 13e: presentation deck scenario requires a clean review pass\n'
cat > "${tmp}/presentation-deck-review-imperfect.json" <<'JSON'
{
  "scenario_id": "presentation-board-deck",
  "tokens": 2200,
  "tool_calls": 15,
  "elapsed_seconds": 180,
  "outcomes": {
    "presentation_artifact_ready": true,
    "operations_deliverable_ready": true,
    "doc_review_clean": false,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/presentation-deck-review-imperfect.json")"
assert_eq "presentation deck review imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "presentation deck missing review" "doc_review_clean" "${score_json}"

printf 'Test 13f: document docx scenario requires a real document artifact\n'
cat > "${tmp}/document-docx-imperfect.json" <<'JSON'
{
  "scenario_id": "document-policy-docx",
  "tokens": 2300,
  "tool_calls": 16,
  "elapsed_seconds": 190,
  "outcomes": {
    "document_artifact_ready": false,
    "writer_deliverable_ready": true,
    "doc_review_clean": true,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/document-docx-imperfect.json")"
assert_eq "document docx imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "document docx missing artifact" "document_artifact_ready" "${score_json}"

printf 'Test 13g: regulated compliance memo requires explicit regulated scope plus drafted deliverable\n'
cat > "${tmp}/regulated-imperfect.json" <<'JSON'
{
  "scenario_id": "regulated-compliance-memo",
  "tokens": 2800,
  "tool_calls": 20,
  "elapsed_seconds": 220,
  "outcomes": {
    "research_report_ready": true,
    "analysis_specialist_coverage": true,
    "writer_deliverable_ready": false,
    "doc_review_clean": true,
    "regulated_scope_explicit": false,
    "final_closeout_audit_ready": true
  }
}
JSON
score_json="$(bash "${RUNNER}" score "${tmp}/regulated-imperfect.json")"
assert_eq "regulated imperfect pass false" "false" "$(jq -r '.pass' <<<"${score_json}")"
assert_contains "regulated missing regulated scope" "regulated_scope_explicit" "${score_json}"
assert_contains "regulated missing writer proof" "writer_deliverable_ready" "${score_json}"

# ---------------------------------------------------------------------
# By-design-missing-fixture contract (defect D14 from the post-91fc96b
# cumulative review).
#
# evals/realwork/README.md:18-21 documents that scenario `fixture` paths
# are user-provided and intentionally NOT bundled — the harness would
# bloat with project-specific assets that map poorly to anyone else's
# real work. The schema validator (evals/realwork/run.sh validate)
# accepts any non-empty `fixture` string, so without an explicit
# regression net a future contributor could (a) file a "missing fixture
# directory" bug, or (b) commit synthetic fixtures and shift the
# realwork suite from outcome-oriented to fixture-coupled.
#
# This block pins the contract: every shipped scenario must declare a
# `fixture` path AND that path must NOT exist as a real directory under
# evals/realwork/. The negative assertion is the contract — flipping it
# to a positive assertion (fixtures exist) would itself be the
# regression we are guarding against.
printf 'Test 22: every scenario declares a fixture path that does not resolve on disk (by-design contract)\n'
realwork_dir="${REPO_ROOT}/evals/realwork"
shopt -s nullglob
scenarios=("${realwork_dir}"/scenarios/*.json)
shopt -u nullglob
if [[ "${#scenarios[@]}" -eq 0 ]]; then
  fail=$((fail + 1))
  printf '  FAIL: T22: no scenarios found under evals/realwork/scenarios/\n' >&2
fi
declared_count=0
resolved_count=0
for scenario_file in "${scenarios[@]}"; do
  fixture_path="$(jq -r '.fixture // empty' "${scenario_file}")"
  if [[ -z "${fixture_path}" ]]; then
    fail=$((fail + 1))
    printf '  FAIL: T22: scenario missing fixture field: %s\n' "${scenario_file}" >&2
    continue
  fi
  declared_count=$((declared_count + 1))
  # Resolve fixture relative to evals/realwork/ — same shape the README
  # documents the user follows.
  if [[ -e "${realwork_dir}/${fixture_path}" ]]; then
    resolved_count=$((resolved_count + 1))
    fail=$((fail + 1))
    printf '  FAIL: T22: fixture path resolved on disk (violates by-design contract): %s → %s\n' \
      "$(basename "${scenario_file}")" "${realwork_dir}/${fixture_path}" >&2
  fi
done
if [[ "${declared_count}" -gt 0 && "${resolved_count}" -eq 0 ]]; then
  pass=$((pass + 1))
  printf '  PASS: T22: all %d scenarios declare unresolved fixture paths\n' "${declared_count}"
fi

printf '\nReal-work eval suite tests: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
