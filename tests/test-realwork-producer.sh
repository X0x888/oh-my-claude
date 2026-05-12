#!/usr/bin/env bash
# test-realwork-producer.sh — v1.39.0 W3 regression net for
# evals/realwork/result-from-session.sh.
#
# Bridges the gap closed by W3: scoring layer (run.sh score) consumed
# a result JSON no script produced. With this producer, ANY ULW
# session's state can be synthesized into a scorable result. The eval
# becomes falsifiable.
#
# Pinned behaviors:
#   1. Numeric extraction — tokens (chars/4 from directive_emitted),
#      tool_calls (count of "start" events), elapsed_seconds
#      (last_activity - session_start).
#   2. Per-outcome detector booleans match the actual session state.
#   3. End-to-end pipe into run.sh score — a perfect synthetic
#      session yields pass=true on at least one scenario.
#   4. CLI contract — --scenario required, --session selects, missing
#      state errors cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCER="${REPO_ROOT}/evals/realwork/result-from-session.sh"
SCORER="${REPO_ROOT}/evals/realwork/run.sh"

TEST_HOME="$(mktemp -d -t realwork-producer-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_STATE_ROOT}"

pass=0
fail=0

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

new_session() {
  local sid="$1"
  local sdir="${TEST_STATE_ROOT}/${sid}"
  mkdir -p "${sdir}"
  printf '%s' "$2" >"${sdir}/session_state.json"
  printf '%s\n' "${sdir}"
}

run_producer() {
  local sid="$1" scenario="$2"
  bash "${PRODUCER}" --scenario "${scenario}" --session "${sid}" --state-root "${TEST_STATE_ROOT}" 2>&1
}

# ---------------------------------------------------------------
# Part A: numeric extraction
# ---------------------------------------------------------------
sdir_a="$(new_session "sess-A" '{
  "session_start_ts": "100",
  "last_edit_ts": "250",
  "last_review_ts": "240",
  "subagent_dispatch_count": "2"
}')"
cat >"${sdir_a}/timing.jsonl" <<'JSONL'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"directive_emitted","ts":101,"prompt_seq":1,"name":"opener","chars":400}
{"kind":"directive_emitted","ts":102,"prompt_seq":1,"name":"intent","chars":200}
{"kind":"start","ts":105,"tool":"Read","prompt_seq":1,"tool_use_id":"t1"}
{"kind":"end","ts":105,"tool":"Read","prompt_seq":1,"tool_use_id":"t1"}
{"kind":"start","ts":106,"tool":"Bash","prompt_seq":1,"tool_use_id":"t2"}
{"kind":"end","ts":108,"tool":"Bash","prompt_seq":1,"tool_use_id":"t2"}
{"kind":"start","ts":110,"tool":"Write","prompt_seq":1,"tool_use_id":"t3"}
{"kind":"end","ts":111,"tool":"Write","prompt_seq":1,"tool_use_id":"t3"}
JSONL
result_a="$(run_producer "sess-A" "targeted-bugfix")"
tokens_a="$(jq -r '.tokens' <<<"${result_a}")"
tool_calls_a="$(jq -r '.tool_calls' <<<"${result_a}")"
elapsed_a="$(jq -r '.elapsed_seconds' <<<"${result_a}")"
assert_eq "A1 tokens (chars 600 / 4)" "150" "${tokens_a}"
assert_eq "A2 tool_calls (3 starts)" "3" "${tool_calls_a}"
assert_eq "A3 elapsed_seconds (250-100)" "150" "${elapsed_a}"

# ---------------------------------------------------------------
# Part B: outcome detectors — perfect targeted-bugfix shape
# ---------------------------------------------------------------
sdir_b="$(new_session "sess-B" '{
  "session_start_ts": "100",
  "last_edit_ts": "300",
  "last_review_ts": "290",
  "last_verify_ts": "295",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "test_command",
  "review_had_findings": "false",
  "code_edit_count": "3",
  "last_assistant_message": "**Changed.** Fixed counter off-by-one. **Verification.** test PASS. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/counter.ts" "src/counter.test.ts" >"${sdir_b}/edited_files.log"
result_b="$(run_producer "sess-B" "targeted-bugfix")"
assert_eq "B1 tests_passed true" "true" "$(jq -r '.outcomes.tests_passed' <<<"${result_b}")"
assert_eq "B2 targeted_verification true" "true" "$(jq -r '.outcomes.targeted_verification' <<<"${result_b}")"
assert_eq "B3 review_clean true" "true" "$(jq -r '.outcomes.review_clean' <<<"${result_b}")"
assert_eq "B4 regression_test_added true" "true" "$(jq -r '.outcomes.regression_test_added' <<<"${result_b}")"
assert_eq "B5 final_closeout_audit_ready true" "true" "$(jq -r '.outcomes.final_closeout_audit_ready' <<<"${result_b}")"

# ---------------------------------------------------------------
# Part C: negative cases — wrong scope, no review, no test file
# ---------------------------------------------------------------
sdir_c="$(new_session "sess-C" '{
  "session_start_ts": "100",
  "last_edit_ts": "300",
  "last_verify_outcome": "passed",
  "last_verify_scope": "lint",
  "code_edit_count": "1"
}')"
printf '%s\n' "src/counter.ts" >"${sdir_c}/edited_files.log"
result_c="$(run_producer "sess-C" "targeted-bugfix")"
assert_eq "C1 lint scope does NOT count as tests_passed" "false" "$(jq -r '.outcomes.tests_passed' <<<"${result_c}")"
assert_eq "C2 lint scope does NOT count as targeted_verification" "false" "$(jq -r '.outcomes.targeted_verification' <<<"${result_c}")"
assert_eq "C3 missing last_review_ts → review_clean false" "false" "$(jq -r '.outcomes.review_clean' <<<"${result_c}")"
assert_eq "C4 no test file in edits → regression_test_added false" "false" "$(jq -r '.outcomes.regression_test_added' <<<"${result_c}")"

# ---------------------------------------------------------------
# Part D: ui-shipping scenario detectors
# ---------------------------------------------------------------
sdir_d="$(new_session "sess-D" '{
  "session_start_ts": "100",
  "last_edit_ts": "500",
  "last_review_ts": "490",
  "last_verify_ts": "495",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "mcp_playwright",
  "review_had_findings": "false",
  "design_contract": "{\"palette\":\"warm\"}",
  "design_review_ts": "495",
  "design_review_had_findings": "false",
  "last_assistant_message": "**Changed.** Redesigned. **Verification.** browser_snapshot ok. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/Dashboard.tsx" "src/Dashboard.module.css" >"${sdir_d}/edited_files.log"
result_d="$(run_producer "sess-D" "ui-shipping")"
assert_eq "D1 design_contract_recorded true" "true" "$(jq -r '.outcomes.design_contract_recorded' <<<"${result_d}")"
assert_eq "D2 ui_files_changed true" "true" "$(jq -r '.outcomes.ui_files_changed' <<<"${result_d}")"
assert_eq "D3 browser_or_visual_verification true" "true" "$(jq -r '.outcomes.browser_or_visual_verification' <<<"${result_d}")"
assert_eq "D4 design_review_clean true" "true" "$(jq -r '.outcomes.design_review_clean' <<<"${result_d}")"
assert_eq "D5 no_layout_overlap default true" "true" "$(jq -r '.outcomes.no_layout_overlap' <<<"${result_d}")"

# ---------------------------------------------------------------
# Part E: broad-project-eval detectors
# ---------------------------------------------------------------
sdir_e="$(new_session "sess-E" '{
  "session_start_ts": "100",
  "last_edit_ts": "800",
  "last_review_ts": "790",
  "last_verify_ts": "795",
  "last_verify_outcome": "passed",
  "last_verify_scope": "full",
  "review_had_findings": "false",
  "subagent_dispatch_count": "5"
}')"
cat >"${sdir_e}/findings.json" <<'JSON'
{
  "findings": [
    {"id": "F-1", "status": "shipped", "claim": "x"},
    {"id": "F-2", "status": "deferred", "claim": "y", "reason": "blocked by F-99"}
  ],
  "waves": [
    {"id": "W1", "status": "completed"}
  ]
}
JSON
cat >"${sdir_e}/dispatch_log.jsonl" <<'JSONL'
{"agent": "product-lens", "ts": 200}
{"agent": "sre-lens", "ts": 250}
{"agent": "oracle", "ts": 300}
JSONL
result_e="$(run_producer "sess-E" "broad-project-eval")"
assert_eq "E1 full_verification true" "true" "$(jq -r '.outcomes.full_verification' <<<"${result_e}")"
assert_eq "E2 council_or_lens_coverage true (lens dispatched)" "true" "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e}")"
assert_eq "E3 wave_plan_recorded true" "true" "$(jq -r '.outcomes.wave_plan_recorded' <<<"${result_e}")"
assert_eq "E4 findings_resolved (all terminal w/ reasons)" "true" "$(jq -r '.outcomes.findings_resolved_or_deferred_with_why' <<<"${result_e}")"

# E5 negative: deferred finding without reason → false
sdir_e2="$(new_session "sess-E2" '{}')"
cat >"${sdir_e2}/findings.json" <<'JSON'
{"findings": [{"id":"F-1","status":"deferred","claim":"x"}], "waves": []}
JSON
result_e2="$(run_producer "sess-E2" "broad-project-eval")"
assert_eq "E5 deferred without reason → findings_resolved false" "false" "$(jq -r '.outcomes.findings_resolved_or_deferred_with_why' <<<"${result_e2}")"

# ---------------------------------------------------------------
# Part F: end-to-end pipe into the scorer
# ---------------------------------------------------------------
# Take the perfect targeted-bugfix result from sess-B and score it.
result_b_full="$(run_producer "sess-B" "targeted-bugfix")"
tmp_result="${TEST_HOME}/result_b.json"
printf '%s' "${result_b_full}" >"${tmp_result}"
score_output="$(bash "${SCORER}" score "${tmp_result}" 2>&1)"
score_value="$(jq -r '.score' <<<"${score_output}")"
pass_value="$(jq -r '.pass' <<<"${score_output}")"
# targeted-bugfix required_outcomes: tests_passed, targeted_verification,
# review_clean, regression_test_added, final_closeout_audit_ready — all
# true in sess-B. Budgets: tokens=150 (under 45000), tool_calls=0 (under 55),
# elapsed=200 (under 900). Score should be 100, pass true.
assert_eq "F1 perfect session scores 100" "100" "${score_value}"
assert_eq "F2 perfect session passes" "true" "${pass_value}"

# ---------------------------------------------------------------
# Part G: CLI contract
# ---------------------------------------------------------------
# G1: missing --scenario errors
if bash "${PRODUCER}" --session "sess-B" --state-root "${TEST_STATE_ROOT}" >/dev/null 2>&1; then
  printf '  FAIL: G1 expected non-zero exit when --scenario omitted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# G2: nonexistent session errors
if bash "${PRODUCER}" --scenario "x" --session "nope" --state-root "${TEST_STATE_ROOT}" >/dev/null 2>&1; then
  printf '  FAIL: G2 expected non-zero exit on missing session\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# G3: --help is exit 0
if bash "${PRODUCER}" --help >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: G3 --help should exit 0\n' >&2
  fail=$((fail + 1))
fi

printf '\nrealwork-producer tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
