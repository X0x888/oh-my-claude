#!/usr/bin/env bash
# Focused tests for show-status.sh — covers the v1.27.0 (Wave 5)
# defensive parse + canary-empty fixes that were caught by quality
# reviewer findings 1 and 2.
#
# These are end-to-end runs (script-level), not unit tests of helper
# functions, because the bugs lived in the show-status script body
# (parameter expansion + grep-c fallback) — not in a library function.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SHOW_STATUS="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-status.sh"

pass=0
fail=0

assert_zero_exit() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    rc=$?
    printf '  FAIL: %s (rc=%d)\n' "${label}" "${rc}" >&2
    "$@" 2>&1 | tail -10 >&2
    fail=$((fail + 1))
  fi
}

assert_output_contains() {
  local label="$1" needle="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "${out}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    output(first 400)=%q\n' "${label}" "${needle}" "${out:0:400}" >&2
    fail=$((fail + 1))
  fi
}

assert_output_NOT_contains() {
  local label="$1" needle="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "${out}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected_needle=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# Build a synthetic STATE_ROOT + SESSION_ID for each test.
mk_session() {
  local _root _sid
  _root="$(mktemp -d -t show-status-test-XXXXXX)"
  _sid="ut-$$-$RANDOM"
  mkdir -p "${_root}/${_sid}"
  printf '%s|%s' "${_root}" "${_sid}"
}

teardown_session() {
  rm -rf "$1"
}

# ----------------------------------------------------------------------
printf 'Test 1: defensive parse on malformed last_verify_factors does NOT crash (Wave-5 review #1)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"30","last_verify_factors":"framework:30|total:30","last_verify_method":"shellcheck","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"

# Even with malformed factors (missing test_match: segment), show-status
# should exit 0 and render a sane breakdown (zero-falling-back).
assert_zero_exit "T1: malformed factors does not crash" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

assert_output_contains "T1: breakdown line still rendered" \
  "Breakdown:" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# The malformed test_match segment should fall back to 0/40, not bleed
# the framework string into the output.
assert_output_contains "T1: malformed test_match falls back to 0/40" \
  "test-cmd-match=0/40" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

assert_output_NOT_contains "T1: malformed parse does NOT leak verbatim" \
  "test-cmd-match=framework" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 2: empty canary.jsonl does NOT crash and suppresses zero-row panel (Wave-5 review #2)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
: > "${ROOT}/${SID}/canary.jsonl"

assert_zero_exit "T2: empty canary.jsonl does not crash" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

# Total=0 → suppress the panel entirely (per Wave-5 polish).
assert_output_NOT_contains "T2: zero-total panel suppressed" \
  "total=0" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_NOT_contains "T2: no model-drift header on empty file" \
  "Model-drift canary" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 3: populated canary.jsonl renders the verdict-distribution panel\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
{
  printf '%s\n' '{"verdict":"clean","claim_count":1}'
  printf '%s\n' '{"verdict":"unverified","claim_count":4}'
  printf '%s\n' '{"verdict":"covered","claim_count":3}'
} > "${ROOT}/${SID}/canary.jsonl"

assert_output_contains "T3: total reflects 3 rows" \
  "total=3" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: clean=1" \
  "clean=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: unverified=1" \
  "unverified=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T3: alert mentions claim_count threshold" \
  "claim_count" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 4: MCP-path verification renders the "no breakdown" fallback line (Wave-5 review #4)\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"30","last_verify_method":"mcp_browser_console_check","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
# Note: no last_verify_factors key — simulating MCP path that doesn't set it.

assert_output_contains "T4: MCP fallback line renders" \
  "MCP-path verification" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T4: still shows confidence + method" \
  "Method: mcp_browser_console_check" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 5: hint logic — when threshold gap > largest single factor, emit combine-hint\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
# Confidence 0/100 with all factors at 0. Default threshold is 40. The
# single-factor branches cover need<=40, so gap=40 still triggers the
# test-cmd hint. To force the combine branch, use a custom threshold.
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","last_verify_confidence":"0","last_verify_factors":"test_match:0|framework:0|output_counts:0|clear_outcome:0|total:0","last_verify_method":"unknown","project_test_cmd":"npm test","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"

# threshold=70 forces gap=70, which exceeds any single factor's max (40).
assert_output_contains "T5: combine-hint when threshold gap > 40" \
  "combine" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" OMC_VERIFY_CONFIDENCE_THRESHOLD=70 bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 5b: live status surfaces directive prompt-surface totals in timing line\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","session_start_ts":"%s"}' \
  "$(date +%s)" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/timing.jsonl" <<'EOF'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"directive_emitted","ts":101,"prompt_seq":1,"name":"ui_design_contract","chars":160}
{"kind":"directive_emitted","ts":102,"prompt_seq":1,"name":"intent_classification","chars":80}
{"kind":"prompt_end","ts":106,"prompt_seq":1,"duration_s":6}
EOF

assert_output_contains "T5b: directive surface totals rendered in status timing line" \
  "directive surface 240 chars (2 fires)" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"

teardown_session "${ROOT}"

# ----------------------------------------------------------------------
printf 'Test 6: --explain renders per-flag rationale (v1.30.0 Wave 7)\n'
# Closes the v1.29.0 product-lens P2-10 deferred item: users wanting to
# disable a flag previously had to read the 422-line conf-example file
# to learn what each flag does.
out_explain="$(bash "${SHOW_STATUS}" --explain 2>&1 || true)"
if [[ "${out_explain}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain header missing; got first 300 chars:\n%s\n' \
    "${out_explain:0:300}" >&2
  fail=$((fail + 1))
fi

# Must list at least one known flag with its description.
if [[ "${out_explain}" == *"prompt_persist"* ]] \
    && [[ "${out_explain}" == *"In-session prompt"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain did not surface prompt_persist + description\n' >&2
  fail=$((fail + 1))
fi

# Must group by cluster (at least one cluster header is present).
if [[ "${out_explain}" == *"── gates ──"* ]] \
    || [[ "${out_explain}" == *"── memory ──"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain missing cluster grouping headers\n' >&2
  fail=$((fail + 1))
fi

# --explain is session-independent: must succeed even with no session state.
_no_state_root="$(mktemp -d)"
out_no_session="$(STATE_ROOT="${_no_state_root}" bash "${SHOW_STATUS}" --explain 2>&1 || true)"
rm -rf "${_no_state_root}"
if [[ "${out_no_session}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --explain failed when no session state was present\n' >&2
  fail=$((fail + 1))
fi

# Help mode lists --explain.
out_help="$(bash "${SHOW_STATUS}" --help 2>&1 || true)"
if [[ "${out_help}" == *"--explain"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: --help does not document --explain\n' >&2
  fail=$((fail + 1))
fi

# v1.31.0 Wave 6 (design-lens F-027): bare-positional argument forms
# accepted in addition to --double-dash.
printf '\nT7: bare-positional argument forms (v1.31.0 grammar normalization)\n'
# Use a fresh STATE_ROOT for each so the CI environment (no real
# session) and local dev (a real session present) both produce the
# "No active ULW session found." empty-state path. The assertion is
# specifically that the BARE form does NOT exit with 'Unknown argument'
# — that's the regression net for v1.31.0 grammar normalization.
out_summary_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" summary 2>&1 || true)"
if [[ "${out_summary_pos}" == *"Unknown argument"* ]]; then
  printf '  FAIL: bare `summary` rejected as Unknown argument\n%s\n' "${out_summary_pos}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
  printf '  PASS: bare `summary` accepted\n'
fi
out_explain_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" explain 2>&1 || true)"
if [[ "${out_explain_pos}" == *"flag rationale"* ]]; then
  pass=$((pass + 1))
  printf '  PASS: bare `explain` works\n'
else
  printf '  FAIL: bare `explain` failed\n' >&2
  fail=$((fail + 1))
fi
out_classifier_pos="$(STATE_ROOT="$(mktemp -d)" bash "${SHOW_STATUS}" classifier 2>&1 || true)"
if [[ "${out_classifier_pos}" == *"Unknown argument"* ]]; then
  printf '  FAIL: bare `classifier` rejected as Unknown argument\n%s\n' "${out_classifier_pos}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
  printf '  PASS: bare `classifier` accepted\n'
fi
# --help shows BOTH grammar forms.
out_help_full="$(bash "${SHOW_STATUS}" --help 2>&1 || true)"
if [[ "${out_help_full}" == *"[summary | classifier | explain]"* ]] \
   && [[ "${out_help_full}" == *"--summary"* ]]; then
  pass=$((pass + 1))
  printf '  PASS: --help documents both positional and --flag forms\n'
else
  printf '  FAIL: --help missing one of the grammar forms\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 8: delivery-contract section surfaces prompt contract and remaining obligations\n'
parts="$(mk_session)"
ROOT="${parts%|*}"
SID="${parts##*|}"
ts_now="$(date +%s)"
printf '{"workflow_mode":"ultrawork","task_intent":"execution","task_domain":"coding","current_objective":"Ship the auth fix","done_contract_primary":"Ship the auth fix","done_contract_commit_mode":"required","done_contract_prompt_surfaces":"tests,docs,release","done_contract_test_expectation":"add_or_update_tests","verification_contract_required":"code_review,code_verify,prose_review,test_surface,release_surface,commit_record","last_code_edit_ts":"%s","last_doc_edit_ts":"%s","last_review_ts":"%s","last_doc_review_ts":"%s","last_verify_ts":"%s","last_verify_outcome":"passed","last_verify_confidence":"80","session_start_ts":"%s"}' \
  "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" "${ts_now}" > "${ROOT}/${SID}/session_state.json"
cat > "${ROOT}/${SID}/edited_files.log" <<'EOF'
/project/src/auth.ts
/project/tests/auth.test.ts
/project/README.md
/project/CHANGELOG.md
EOF

assert_output_contains "T8: full status renders delivery-contract header" \
  "--- Delivery Contract ---" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: commit intent rendered" \
  "Commit intent:       required" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: prompt surfaces humanized" \
  "Prompt surfaces:     tests · docs · release" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: touched surfaces rendered" \
  "Touched surfaces:    code=2 · docs=2 · tests=1 · release=1" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: remaining commit obligation rendered" \
  "create the requested commit before stopping" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}"
assert_output_contains "T8: summary mode surfaces contract" \
  "Contract:   commit=required · prompt surfaces=tests · docs · release" \
  env STATE_ROOT="${ROOT}" SESSION_ID="${SID}" bash "${SHOW_STATUS}" --summary
teardown_session "${ROOT}"

printf '\n=== Show-Status Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
