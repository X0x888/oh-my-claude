#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common.sh for state functions
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="test-session"
ensure_session_dir

cleanup() {
  rm -rf "${TEST_STATE_ROOT}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Helper: reset state for a fresh test
reset_state() {
  rm -f "$(session_file "${STATE_JSON}")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

# Helper: simulate the stop-guard logic inline for testability.
# This replicates the core gate logic without needing stdin JSON.
run_stop_guard_check() {
  local last_edit_ts last_review_ts last_verify_ts task_domain
  local missing_review=0 missing_verify=0 verify_failed=0 verify_low_confidence=0 review_unremediated=0

  last_edit_ts="$(read_state "last_edit_ts")"
  last_review_ts="$(read_state "last_review_ts")"
  last_verify_ts="$(read_state "last_verify_ts")"
  task_domain="$(read_state "task_domain")"
  task_domain="${task_domain:-general}"

  if [[ -z "${last_edit_ts}" ]]; then
    printf 'allow:no_edits'
    return
  fi

  if [[ -z "${last_review_ts}" || "${last_review_ts}" -lt "${last_edit_ts}" ]]; then
    missing_review=1
  fi

  case "${task_domain}" in
    coding|mixed)
      if [[ -z "${last_verify_ts}" || "${last_verify_ts}" -lt "${last_edit_ts}" ]]; then
        missing_verify=1
      fi
      ;;
  esac

  # Gate: verify ran but failed
  if [[ "${missing_verify}" -eq 0 ]]; then
    case "${task_domain}" in
      coding|mixed)
        local verify_outcome
        verify_outcome="$(read_state "last_verify_outcome")"
        if [[ "${verify_outcome}" == "failed" ]]; then
          verify_failed=1
        fi
        ;;
    esac
  fi

  # Gate: verify ran but confidence below threshold
  if [[ "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 ]]; then
    case "${task_domain}" in
      coding|mixed)
        local last_verify_confidence
        last_verify_confidence="$(read_state "last_verify_confidence")"
        if [[ -n "${last_verify_confidence}" && "${last_verify_confidence}" =~ ^[0-9]+$ && "${last_verify_confidence}" -lt "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]]; then
          verify_low_confidence=1
        fi
        ;;
    esac
  fi

  # Gate: review ran but findings not addressed
  if [[ "${missing_review}" -eq 0 ]]; then
    local review_had_findings
    review_had_findings="$(read_state "review_had_findings")"
    if [[ "${review_had_findings}" == "true" && -n "${last_review_ts}" && "${last_edit_ts}" -lt "${last_review_ts}" ]]; then
      review_unremediated=1
    fi
  fi

  if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${verify_low_confidence}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
    printf 'allow:all_clear'
  else
    printf 'block:review=%d,verify=%d,verify_failed=%d,low_confidence=%d,unremediated=%d' \
      "${missing_review}" "${missing_verify}" "${verify_failed}" "${verify_low_confidence}" "${review_unremediated}"
  fi
}


printf '=== Quality Gate Tests ===\n\n'

# -------------------------------------------------------
# Section 1: Verification outcome detection
# -------------------------------------------------------
printf 'Verification outcome detection:\n'

# Test: passing test output
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed"
result="$(run_stop_guard_check)"
assert_not_contains "passed tests clear verify gate" "verify_failed=1" "${result}"

# Test: failed test output
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "failed"
result="$(run_stop_guard_check)"
assert_contains "failed tests block verify gate" "verify_failed=1" "${result}"

# Test: no outcome recorded (legacy/fallback) — should not block
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001"
result="$(run_stop_guard_check)"
assert_not_contains "no outcome defaults to pass" "verify_failed=1" "${result}"

# Test: failed verify on non-coding domain should not trigger
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "writing" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "failed"
result="$(run_stop_guard_check)"
assert_not_contains "writing domain ignores verify outcome" "verify_failed=1" "${result}"


# -------------------------------------------------------
# Section 2: Review findings detection
# -------------------------------------------------------
printf '\nReview findings detection:\n'

# Helper: simulate what record-reviewer.sh does with a given message
detect_findings() {
  local review_message="$1"
  local has_findings="true"
  if [[ -n "${review_message}" ]]; then
    if printf '%s' "${review_message}" \
      | grep -Eiq '\b(no (significant |major |critical |high.severity )?issues|looks (good|clean|solid)|well[- ]implemented|no findings|no defects|passes review|code is correct)\b'; then
      if printf '%s' "${review_message}" \
        | grep -Eiq '\b(but|however|though|although)\b.*\b(issue|concern|finding|problem|bug|regression|defect|risk)\b'; then
        has_findings="true"
      else
        has_findings="false"
      fi
    fi
  fi
  printf '%s' "${has_findings}"
}

assert_eq "clean review: 'looks good'" "false" "$(detect_findings "Summary: The code looks good. No major issues found.")"
assert_eq "clean review: 'no significant issues'" "false" "$(detect_findings "Summary: No significant issues detected. Clean implementation.")"
assert_eq "clean review: 'well-implemented'" "false" "$(detect_findings "Summary: The feature is well-implemented and properly tested.")"
assert_eq "clean review: 'passes review'" "false" "$(detect_findings "Summary: Code passes review with no concerns.")"
assert_eq "clean review: 'no defects'" "false" "$(detect_findings "Summary: No defects found in the changed files.")"
assert_eq "clean review: 'code is correct'" "false" "$(detect_findings "Summary: The code is correct and handles edge cases well.")"

assert_eq "findings: regression warning" "true" "$(detect_findings "Summary: Found 3 issues. 1. Missing null check in auth handler.")"
assert_eq "findings: generic review" "true" "$(detect_findings "Summary: Several concerns. The error handling is incomplete.")"
assert_eq "findings: empty message" "true" "$(detect_findings "")"
assert_eq "qualifier override: 'no issues but concern'" "true" "$(detect_findings "No significant issues, but found 3 moderate concerns that pose risk.")"
assert_eq "qualifier override: 'looks good however bug'" "true" "$(detect_findings "Looks good overall, however there is a regression in the auth handler.")"
assert_eq "no qualifier: 'looks good and well tested'" "false" "$(detect_findings "The implementation looks good and is well tested.")"


# -------------------------------------------------------
# Section 3: Post-review remediation gate
# -------------------------------------------------------
printf '\nPost-review remediation gate:\n'

# Test: review with findings + no post-review edits = block
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed" \
  "last_review_ts" "1002" "review_had_findings" "true"
result="$(run_stop_guard_check)"
assert_contains "unremediated findings block" "unremediated=1" "${result}"

# Test: review with findings + post-review edits = allow (edits happened)
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1003" "last_verify_ts" "1004" "last_verify_outcome" "passed" \
  "last_review_ts" "1002" "review_had_findings" "true"
result="$(run_stop_guard_check)"
# Note: last_edit_ts (1003) > last_review_ts (1002), so review is now stale → missing_review=1
# But review_unremediated should be 0 since missing_review=1 (skip remediation check)
assert_not_contains "post-edit review not flagged as unremediated" "unremediated=1" "${result}"

# Test: review clean (no findings) = allow
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed" \
  "last_review_ts" "1002" "review_had_findings" "false"
result="$(run_stop_guard_check)"
assert_eq "clean review allows stop" "allow:all_clear" "${result}"

# Test: no review yet = missing_review, not unremediated
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed"
result="$(run_stop_guard_check)"
assert_contains "no review = missing review" "review=1" "${result}"
assert_not_contains "no review ≠ unremediated" "unremediated=1" "${result}"


# -------------------------------------------------------
# Section 4: Combined conditions
# -------------------------------------------------------
printf '\nCombined conditions:\n'

# Test: everything good = allow
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed" \
  "last_review_ts" "1002" "review_had_findings" "false"
result="$(run_stop_guard_check)"
assert_eq "all gates clear" "allow:all_clear" "${result}"

# Test: no edits = allow (nothing to review)
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding"
result="$(run_stop_guard_check)"
assert_eq "no edits = allow" "allow:no_edits" "${result}"

# Test: verify failed + unremediated review = both flagged
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "failed" \
  "last_review_ts" "1002" "review_had_findings" "true"
result="$(run_stop_guard_check)"
assert_contains "both conditions flagged: verify_failed" "verify_failed=1" "${result}"
assert_contains "both conditions flagged: unremediated" "unremediated=1" "${result}"

# Test: writing domain — review findings matter, verify outcome does not
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "writing" \
  "last_edit_ts" "1000" "last_review_ts" "1002" "review_had_findings" "true"
result="$(run_stop_guard_check)"
assert_contains "writing: unremediated findings block" "unremediated=1" "${result}"
assert_not_contains "writing: no verify check" "verify_failed=1" "${result}"


# -------------------------------------------------------
# Section 5: Failure pattern matching
# -------------------------------------------------------
printf '\nVerification failure pattern matching:\n'

# Test patterns that should be detected as failures
is_failure() {
  local output="$1"
  # Matches the logic in record-verification.sh:
  # Case-sensitive for framework indicators + Rust errors, case-insensitive for counts/exit codes
  if printf '%s' "${output}" | grep -Eq '\b(FAIL(ED)?|ERROR(S)?|FAILURE(S)?)\b|error\[E[0-9]' \
    || printf '%s' "${output}" | grep -Eiq 'exit (code|status)[: ]*[1-9]|[1-9][0-9]* (failed|failing|failures?|errors?)'; then
    printf 'failed'
  else
    printf 'passed'
  fi
}

assert_eq "jest FAIL" "failed" "$(is_failure "FAIL src/auth.test.ts")"
assert_eq "pytest FAILED" "failed" "$(is_failure "FAILED tests/test_auth.py::test_login")"
assert_eq "go test FAIL" "failed" "$(is_failure "FAIL github.com/foo/bar [build failed]")"
assert_eq "generic ERROR" "failed" "$(is_failure "ERROR: Build failed with 2 errors")"
assert_eq "exit code 1" "failed" "$(is_failure "Process exited with exit code 1")"
assert_eq "N failed" "failed" "$(is_failure "Tests: 3 failed, 10 passed")"
assert_eq "N errors" "failed" "$(is_failure "Found 2 errors in src/")"
assert_eq "FAILURES" "failed" "$(is_failure "====== FAILURES ======")"

assert_eq "rust error" "failed" "$(is_failure "error[E0308]: mismatched types")"
assert_eq "swift failures" "failed" "$(is_failure "Executed 5 tests, with 2 failures (0 unexpected)")"

assert_eq "all pass" "passed" "$(is_failure "Tests: 10 passed, 0 failed")"
assert_eq "zero errors" "passed" "$(is_failure "Compilation: 0 errors, 0 warnings")"
assert_eq "exit code 0" "passed" "$(is_failure "Process exited with exit code 0")"
assert_eq "success" "passed" "$(is_failure "Build succeeded in 2.3s")"
assert_eq "clean output" "passed" "$(is_failure "✓ All tests passed")"
assert_eq "empty output" "passed" "$(is_failure "")"


# -------------------------------------------------------
# Section 6: MCP verification tool classification
# -------------------------------------------------------
printf '\nMCP verification tool classification:\n'

assert_eq "playwright snapshot = browser_dom_check" \
  "browser_dom_check" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_snapshot")"

assert_eq "playwright screenshot = browser_visual_check" \
  "browser_visual_check" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_take_screenshot")"

assert_eq "playwright console = browser_console_check" \
  "browser_console_check" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_console_messages")"

assert_eq "playwright network = browser_network_check" \
  "browser_network_check" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_network_requests")"

assert_eq "playwright evaluate = browser_eval_check" \
  "browser_eval_check" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_evaluate")"

assert_eq "computer-use screenshot = visual_check" \
  "visual_check" \
  "$(classify_mcp_verification_tool "mcp__computer-use__screenshot")"

assert_eq "playwright click = not verification" \
  "" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_click")"

assert_eq "playwright navigate = not verification" \
  "" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_navigate")"

assert_eq "playwright fill_form = not verification" \
  "" \
  "$(classify_mcp_verification_tool "mcp__plugin_playwright_playwright__browser_fill_form")"

assert_eq "unrelated MCP tool = not verification" \
  "" \
  "$(classify_mcp_verification_tool "mcp__plugin_context7_context7__resolve-library-id")"

assert_eq "empty tool name = not verification" \
  "" \
  "$(classify_mcp_verification_tool "")"

# Custom MCP tools via config
OMC_CUSTOM_VERIFY_MCP_TOOLS="mcp__my_cypress__*|mcp__api_tester__check*"
assert_eq "custom MCP tool matches glob" \
  "custom_mcp_tool" \
  "$(classify_mcp_verification_tool "mcp__my_cypress__run_test")"
assert_eq "custom MCP tool partial match" \
  "custom_mcp_tool" \
  "$(classify_mcp_verification_tool "mcp__api_tester__check_endpoint")"
assert_eq "custom MCP tool non-match" \
  "" \
  "$(classify_mcp_verification_tool "mcp__api_tester__setup")"
OMC_CUSTOM_VERIFY_MCP_TOOLS=""


# -------------------------------------------------------
# Section 7: MCP verification confidence scoring
# -------------------------------------------------------
printf '\nMCP verification confidence scoring:\n'

# --- Base scores (no UI context, no output) — all below threshold ---
assert_eq "snapshot base = 25 (below threshold)" \
  "25" \
  "$(score_mcp_verification_confidence "browser_dom_check" "")"

assert_eq "screenshot base = 20 (below threshold)" \
  "20" \
  "$(score_mcp_verification_confidence "browser_visual_check" "")"

assert_eq "console base = 30 (below threshold)" \
  "30" \
  "$(score_mcp_verification_confidence "browser_console_check" "")"

assert_eq "network base = 30 (below threshold)" \
  "30" \
  "$(score_mcp_verification_confidence "browser_network_check" "")"

assert_eq "eval base = 35 (below threshold)" \
  "35" \
  "$(score_mcp_verification_confidence "browser_eval_check" "")"

assert_eq "computer-use base = 15 (below threshold)" \
  "15" \
  "$(score_mcp_verification_confidence "visual_check" "")"

assert_eq "custom MCP base = 35 (below threshold)" \
  "35" \
  "$(score_mcp_verification_confidence "custom_mcp_tool" "")"

# --- All passive calls blocked at default threshold ---
assert_eq "passive snapshot blocked" \
  "false" \
  "$([[ "$(score_mcp_verification_confidence "browser_dom_check" "")" -ge "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]] && printf true || printf false)"

assert_eq "passive screenshot blocked" \
  "false" \
  "$([[ "$(score_mcp_verification_confidence "browser_visual_check" "")" -ge "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]] && printf true || printf false)"

assert_eq "passive console blocked" \
  "false" \
  "$([[ "$(score_mcp_verification_confidence "browser_console_check" "")" -ge "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]] && printf true || printf false)"

# --- UI context bonus brings observation tools above threshold ---
assert_eq "snapshot + UI context = 45 (passes)" \
  "45" \
  "$(score_mcp_verification_confidence "browser_dom_check" "" "true")"

assert_eq "screenshot + UI context = 40 (passes)" \
  "40" \
  "$(score_mcp_verification_confidence "browser_visual_check" "" "true")"

assert_eq "console + UI context = 50 (passes)" \
  "50" \
  "$(score_mcp_verification_confidence "browser_console_check" "" "true")"

assert_eq "computer-use + UI context = 35 (still blocked)" \
  "false" \
  "$([[ "$(score_mcp_verification_confidence "visual_check" "" "true")" -ge "${OMC_VERIFY_CONFIDENCE_THRESHOLD}" ]] && printf true || printf false)"

# --- Output bonuses can also push above threshold without UI context ---
assert_eq "snapshot + test counts = 40 (passes)" \
  "40" \
  "$(score_mcp_verification_confidence "browser_dom_check" "Ran 10 tests total")"

assert_eq "snapshot + counts + outcome = 50" \
  "50" \
  "$(score_mcp_verification_confidence "browser_dom_check" "10 tests passed. SUCCESS")"

assert_eq "eval + counts + UI = 70" \
  "70" \
  "$(score_mcp_verification_confidence "browser_eval_check" "Ran 10 tests total" "true")"


# -------------------------------------------------------
# Section 8: MCP verification outcome detection
# -------------------------------------------------------
printf '\nMCP verification outcome detection:\n'

assert_eq "empty output = passed" \
  "passed" \
  "$(detect_mcp_verification_outcome "" "browser_dom_check")"

assert_eq "console with TypeError = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "TypeError: Cannot read property 'foo'" "browser_console_check")"

assert_eq "console with uncaught = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "Uncaught ReferenceError: x is not defined" "browser_console_check")"

assert_eq "console clean = passed" \
  "passed" \
  "$(detect_mcp_verification_outcome "Page loaded successfully, 3 log entries" "browser_console_check")"

assert_eq "console informational error mention = passed (not false positive)" \
  "passed" \
  "$(detect_mcp_verification_outcome "Cleared previous error state" "browser_console_check")"

assert_eq "console with Error: prefix = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "Error: something broke" "browser_console_check")"

assert_eq "console with inline Error: = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "console.error Error: connection lost" "browser_console_check")"

assert_eq "network with 404 = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "GET /api/data — 404 Not Found" "browser_network_check")"

assert_eq "network with 401 = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "GET /api/me — 401 Unauthorized" "browser_network_check")"

assert_eq "network with 403 = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "POST /admin — 403 Forbidden" "browser_network_check")"

assert_eq "network clean = passed" \
  "passed" \
  "$(detect_mcp_verification_outcome "GET /api/data — 200 OK" "browser_network_check")"

assert_eq "network timeout config = passed (not false positive)" \
  "passed" \
  "$(detect_mcp_verification_outcome "GET /api/data — 200 OK, timeout: 30000ms" "browser_network_check")"

assert_eq "network timed out = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "GET /api/data — timed out after 30s" "browser_network_check")"

assert_eq "snapshot with error page = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "500 Internal Server Error" "browser_dom_check")"

assert_eq "snapshot clean = passed" \
  "passed" \
  "$(detect_mcp_verification_outcome "Welcome to the dashboard" "browser_dom_check")"

assert_eq "eval with assertion error = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "AssertionError: expected true to be false" "browser_eval_check")"

assert_eq "eval with TypeError = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "TypeError: undefined is not a function" "browser_eval_check")"

assert_eq "eval clean = passed" \
  "passed" \
  "$(detect_mcp_verification_outcome "42" "browser_eval_check")"

assert_eq "eval returning false = passed (not false positive)" \
  "passed" \
  "$(detect_mcp_verification_outcome '{"visible": false}' "browser_eval_check")"

assert_eq "eval with 'Error' in text = passed (not false positive)" \
  "passed" \
  "$(detect_mcp_verification_outcome "No Errors Found in scan" "browser_eval_check")"

assert_eq "eval with Error: prefix = failed" \
  "failed" \
  "$(detect_mcp_verification_outcome "Error: something broke" "browser_eval_check")"


# -------------------------------------------------------
# Section 9: MCP verification integrates with stop-guard
# -------------------------------------------------------
printf '\nMCP verification + stop-guard integration:\n'

# MCP verification with UI context (confidence 45) clears the gate
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed" \
  "last_verify_confidence" "45" "last_verify_method" "mcp_browser_dom_check" \
  "last_review_ts" "1002" "review_had_findings" "false"
result="$(run_stop_guard_check)"
assert_eq "MCP verification (UI context) clears gates" "allow:all_clear" "${result}"

# MCP verification with failure should block regardless of confidence
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "failed" \
  "last_verify_confidence" "45" "last_verify_method" "mcp_browser_dom_check" \
  "last_review_ts" "1002" "review_had_findings" "false"
result="$(run_stop_guard_check)"
assert_contains "MCP verification failure blocks" "verify_failed=1" "${result}"

# Passive MCP verification without UI context (confidence 25) should be low-confidence blocked
reset_state
write_state_batch "workflow_mode" "ultrawork" "task_domain" "coding" \
  "last_edit_ts" "1000" "last_verify_ts" "1001" "last_verify_outcome" "passed" \
  "last_verify_confidence" "25" "last_verify_method" "mcp_browser_dom_check" \
  "last_review_ts" "1002" "review_had_findings" "false"
result="$(run_stop_guard_check)"
assert_not_contains "passive MCP does not clear verify" "allow:all_clear" "${result}"


printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
