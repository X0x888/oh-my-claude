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
  local missing_review=0 missing_verify=0 verify_failed=0 review_unremediated=0

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

  # New gate: verify ran but failed
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

  # New gate: review ran but findings not addressed
  if [[ "${missing_review}" -eq 0 ]]; then
    local review_had_findings
    review_had_findings="$(read_state "review_had_findings")"
    if [[ "${review_had_findings}" == "true" && -n "${last_review_ts}" && "${last_edit_ts}" -lt "${last_review_ts}" ]]; then
      review_unremediated=1
    fi
  fi

  if [[ "${missing_review}" -eq 0 && "${missing_verify}" -eq 0 && "${verify_failed}" -eq 0 && "${review_unremediated}" -eq 0 ]]; then
    printf 'allow:all_clear'
  else
    printf 'block:review=%d,verify=%d,verify_failed=%d,unremediated=%d' \
      "${missing_review}" "${missing_verify}" "${verify_failed}" "${review_unremediated}"
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


printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
