#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

ORIG_HOME="${HOME}"
pass=0
fail=0

# --- Harness ---

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}"
}

# Initialize session with ULW mode active
init_session() {
  local sid="$1"
  local domain="${2:-coding}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${state_dir}"
  jq -nc --arg d "${domain}" --arg ts "$(date +%s)" \
    '{workflow_mode:"ultrawork",task_domain:$d,task_intent:"execution",current_objective:"test",last_user_prompt_ts:$ts}' \
    > "${state_dir}/session_state.json"
}

# Run a hook script, pipe JSON to stdin, capture stdout
run_hook() {
  local script="$1"
  local json="$2"
  printf '%s' "${json}" | bash "${script}" 2>/dev/null || true
}

# Read a state key from session JSON
read_st() {
  local sid="$1"
  local key="$2"
  jq -r --arg k "${key}" '.[$k] // empty' \
    "${TEST_HOME}/.claude/quality-pack/state/${sid}/session_state.json" 2>/dev/null || true
}

# --- Hook simulators ---

sim_edit() {
  local sid="$1"
  local fp="${2:-/src/foo.ts}"
  run_hook "${HOOK_DIR}/mark-edit.sh" \
    "$(jq -nc --arg s "${sid}" --arg f "${fp}" '{session_id:$s,tool_input:{file_path:$f}}')"
}

sim_verify() {
  local sid="$1"
  local cmd="${2:-npm test}"
  local res="${3:-}"
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "$(jq -nc --arg s "${sid}" --arg c "${cmd}" --arg r "${res}" \
      '{session_id:$s,tool_input:{command:$c},tool_response:$r}')"
}

sim_review() {
  local sid="$1"
  local msg="${2:-Summary: The code looks good. No issues found.}"
  run_hook "${HOOK_DIR}/record-reviewer.sh" \
    "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
      '{session_id:$s,last_assistant_message:$m}')"
}

sim_excellence_review() {
  local sid="$1"
  local msg="${2:-Verdict: The deliverable is complete and excellent.
VERDICT: SHIP}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" excellence 2>/dev/null || true
}

sim_metis() {
  local sid="$1"
  local msg="${2:-Plan is ready to execute.
VERDICT: CLEAN}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" stress_test 2>/dev/null || true
}

sim_briefing_analyst() {
  local sid="$1"
  local msg="${2:-Brief is decision-ready.
VERDICT: CLEAN}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" traceability 2>/dev/null || true
}

sim_editor_critic() {
  local sid="$1"
  local msg="${2:-Draft is solid.
VERDICT: CLEAN}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" prose 2>/dev/null || true
}

sim_edit_doc() {
  local sid="$1"
  local fp="${2:-/docs/README.md}"
  run_hook "${HOOK_DIR}/mark-edit.sh" \
    "$(jq -nc --arg s "${sid}" --arg f "${fp}" '{session_id:$s,tool_input:{file_path:$f}}')"
}

sim_stop() {
  local sid="$1"
  local msg="${2:-Here is the completed work.}"
  run_hook "${HOOK_DIR}/stop-guard.sh" \
    "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
      '{session_id:$s,last_assistant_message:$m}')"
}

# --- Assertions ---

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected empty, got: %s\n' "${label}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_empty() {
  local label="$1" actual="$2"
  if [[ -n "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected non-empty output\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}


printf '=== End-to-End Hook Sequence Tests ===\n\n'


# -------------------------------------------------------
# Test 1: mark-edit.sh sets state correctly
# -------------------------------------------------------
printf 'Individual hooks:\n'

setup_test
init_session "s1"
sim_edit "s1" "/src/auth.ts"

assert_not_empty "mark-edit: last_edit_ts set" "$(read_st "s1" "last_edit_ts")"
assert_eq "mark-edit: guard counters reset" "0" "$(read_st "s1" "stop_guard_blocks")"

# Verify edited_files.log was written
edited_log="${TEST_HOME}/.claude/quality-pack/state/s1/edited_files.log"
if [[ -f "${edited_log}" ]] && grep -q "/src/auth.ts" "${edited_log}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: edited_files.log should contain /src/auth.ts\n' >&2
  fail=$((fail + 1))
fi
teardown_test


# -------------------------------------------------------
# Test 2: record-verification.sh — passing tests
# -------------------------------------------------------
setup_test
init_session "s2"
sim_verify "s2" "npm test" "Tests: 10 passed, 0 failed"

assert_not_empty "verify(pass): last_verify_ts set" "$(read_st "s2" "last_verify_ts")"
assert_eq "verify(pass): outcome is passed" "passed" "$(read_st "s2" "last_verify_outcome")"
assert_eq "verify(pass): command recorded" "npm test" "$(read_st "s2" "last_verify_cmd")"
teardown_test


# -------------------------------------------------------
# Test 3: record-verification.sh — failing tests
# -------------------------------------------------------
setup_test
init_session "s3"
sim_verify "s3" "npm test" "FAIL src/auth.test.ts\nTests: 2 failed, 8 passed"

assert_eq "verify(fail): outcome is failed" "failed" "$(read_st "s3" "last_verify_outcome")"
teardown_test


# -------------------------------------------------------
# Test 4: record-verification.sh — no tool_response defaults to passed
# -------------------------------------------------------
setup_test
init_session "s4"
sim_verify "s4" "npm test" ""

assert_eq "verify(no output): outcome defaults to passed" "passed" "$(read_st "s4" "last_verify_outcome")"
teardown_test


# -------------------------------------------------------
# Test 5: record-reviewer.sh — clean review
# -------------------------------------------------------
setup_test
init_session "s5"
sim_review "s5" "Summary: The code looks good. No significant issues found."

assert_not_empty "review(clean): last_review_ts set" "$(read_st "s5" "last_review_ts")"
assert_eq "review(clean): no findings" "false" "$(read_st "s5" "review_had_findings")"
teardown_test


# -------------------------------------------------------
# Test 6: record-reviewer.sh — findings detected
# -------------------------------------------------------
setup_test
init_session "s6"
sim_review "s6" "Summary: Found 3 issues. 1. Missing null check in auth handler. 2. Race condition in cache."

assert_eq "review(findings): has findings" "true" "$(read_st "s6" "review_had_findings")"
teardown_test


# -------------------------------------------------------
# Test 7: record-reviewer.sh — clean with qualifier override
# -------------------------------------------------------
setup_test
init_session "s7"
sim_review "s7" "Summary: No significant issues, but there is a regression risk in the error handler."

assert_eq "review(qualifier): findings override" "true" "$(read_st "s7" "review_had_findings")"
teardown_test


# -------------------------------------------------------
# Test 8: Non-test commands skip verification recording
# -------------------------------------------------------
setup_test
init_session "s8"
sim_verify "s8" "ls -la" ""

assert_empty "non-test cmd: no verify_ts" "$(read_st "s8" "last_verify_ts")"
teardown_test


# -------------------------------------------------------
# Sequence tests
# -------------------------------------------------------
printf '\nSequences:\n'


# -------------------------------------------------------
# Sequence A: Happy path — edit → verify(pass) → review(clean) → stop = allow
# -------------------------------------------------------
setup_test
init_session "sa"
sim_edit "sa"
sim_verify "sa" "npm test" "Tests: 10 passed, 0 failed"
sim_review "sa" "Summary: Code looks clean. No issues."
output="$(sim_stop "sa")"

assert_empty "seq-A: stop allowed (no output)" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence B: Verify fails — edit → verify(fail) → review(clean) → stop = block
# -------------------------------------------------------
setup_test
init_session "sb"
sim_edit "sb"
sim_verify "sb" "npm test" "FAIL src/auth.test.ts"
sim_review "sb" "Summary: Code looks good."
output="$(sim_stop "sb")"

assert_contains "seq-B: blocked" '"decision":"block"' "${output}"
assert_contains "seq-B: verify failed message" "verification command failed" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence C: Unremediated review — edit → verify(pass) → [wait] → review(findings) → stop = block
# -------------------------------------------------------
setup_test
init_session "sc"
sim_edit "sc"
sim_verify "sc" "npm test" "Tests: 5 passed"
sleep 1
sim_review "sc" "Summary: Found critical regression in auth flow. 1. Missing validation."
output="$(sim_stop "sc")"

assert_contains "seq-C: blocked" '"decision":"block"' "${output}"
assert_contains "seq-C: unremediated message" "reviewer flagged issues" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence D: Edit after review → needs re-review + re-verify
# -------------------------------------------------------
setup_test
init_session "sd"
sim_edit "sd"
sleep 1
sim_verify "sd" "npm test" "Tests: 5 passed"
sim_review "sd" "Summary: Found issue. 1. Off-by-one in loop."
sleep 1
sim_edit "sd" "/src/fixed.ts"
output="$(sim_stop "sd")"

assert_contains "seq-D: blocked" '"decision":"block"' "${output}"
# After second edit, both review and verify are stale
assert_contains "seq-D: needs validation" "validation" "${output}"
assert_contains "seq-D: needs reviewer" "quality-reviewer" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence E: Guard exhaustion — 4 stop attempts (limit=3)
# -------------------------------------------------------
setup_test
init_session "se"
sim_edit "se"

# First stop: blocked
out1="$(sim_stop "se")"
assert_contains "seq-E: first stop blocked" '"decision":"block"' "${out1}"
blocks1="$(read_st "se" "stop_guard_blocks")"
assert_eq "seq-E: guard_blocks=1" "1" "${blocks1}"

# Second stop: blocked, no penultimate warning yet
out2="$(sim_stop "se")"
assert_contains "seq-E: second stop blocked" '"decision":"block"' "${out2}"
blocks2="$(read_st "se" "stop_guard_blocks")"
assert_eq "seq-E: guard_blocks=2" "2" "${blocks2}"

# Third stop: blocked with penultimate warning
out3="$(sim_stop "se")"
assert_contains "seq-E: third stop blocked" '"decision":"block"' "${out3}"
assert_contains "seq-E: penultimate warning" "final guard block" "${out3}"
blocks3="$(read_st "se" "stop_guard_blocks")"
assert_eq "seq-E: guard_blocks=3" "3" "${blocks3}"

# Fourth stop: exhausted, allowed
out4="$(sim_stop "se")"
assert_empty "seq-E: fourth stop allowed (exhausted)" "${out4}"
assert_not_empty "seq-E: guard_exhausted set" "$(read_st "se" "guard_exhausted")"
detail="$(read_st "se" "guard_exhausted_detail")"
assert_contains "seq-E: exhaustion detail has review" "review=" "${detail}"
assert_contains "seq-E: exhaustion detail has verify" "verify=" "${detail}"
teardown_test


# -------------------------------------------------------
# Sequence F: Non-ULW session — hooks skip gracefully
# -------------------------------------------------------
setup_test
# Do NOT create .ulw_active sentinel
rm -f "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
init_session "sf"

sim_edit "sf"
assert_empty "seq-F: no edit_ts without ULW" "$(read_st "sf" "last_edit_ts")"

sim_verify "sf" "npm test" "FAIL"
assert_empty "seq-F: no verify_ts without ULW" "$(read_st "sf" "last_verify_ts")"

sim_review "sf" "Summary: Issues found."
assert_empty "seq-F: no review_ts without ULW" "$(read_st "sf" "last_review_ts")"
teardown_test


# -------------------------------------------------------
# Sequence G: Session handoff detection — deferral language blocked
# -------------------------------------------------------
setup_test
init_session "sg"
sim_edit "sg"
sim_verify "sg" "npm test" "Tests: 5 passed"
sim_review "sg" "Summary: Looks good."
output="$(sim_stop "sg" "I've completed wave 1. The remaining work is ready for a new session.")"

assert_contains "seq-G: handoff blocked" '"decision":"block"' "${output}"
assert_contains "seq-G: handoff reason" "deferred remaining work" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence H: Advisory gate — coding advisory without code inspection
# -------------------------------------------------------
setup_test
sid="sh"
state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${state_dir}"
# Set up as advisory over coding domain
jq -nc '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"advisory",current_objective:"how should we refactor auth?",last_user_prompt_ts:"9999999999"}' \
  > "${state_dir}/session_state.json"

output="$(sim_stop "${sid}")"
assert_contains "seq-H: advisory gate blocks" '"decision":"block"' "${output}"
assert_contains "seq-H: advisory reason" "code inspection" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence I: Full cycle with remediation — edit → verify → review(findings) → edit → verify → review(clean) → stop = allow
# -------------------------------------------------------
setup_test
init_session "si"
sim_edit "si"
sim_verify "si" "npm test" "Tests: 5 passed"
sleep 1
sim_review "si" "Summary: Found issue. 1. Missing error handling."
sleep 1
# Remediate: edit again
sim_edit "si" "/src/fixed.ts"
sim_verify "si" "npm test" "Tests: 6 passed, 0 failed"
sim_review "si" "Summary: Code looks clean. Issue resolved."
output="$(sim_stop "si")"

assert_empty "seq-I: full cycle allows stop" "${output}"
teardown_test


# -------------------------------------------------------
# Prompt routing tests
# -------------------------------------------------------
printf '\nPrompt routing:\n'

ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

setup_prompt_router() {
  # prompt-intent-router.sh sources common.sh from HOME path
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
}

sim_prompt() {
  local sid="$1"
  local prompt="$2"
  run_hook "${ROUTER}" \
    "$(jq -nc --arg s "${sid}" --arg p "${prompt}" '{session_id:$s,prompt:$p}')"
}


# -------------------------------------------------------
# Sequence J: Sticky gate — non-keyword prompt with active ULW session
# -------------------------------------------------------
setup_test
setup_prompt_router
init_session "sj"
output="$(sim_prompt "sj" "yes please continue with the implementation")"

assert_contains "seq-J: sticky gate injects context" "Ultrawork" "${output}"
assert_contains "seq-J: has additionalContext" "additionalContext" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence K: No sticky gate — non-keyword prompt without ULW session
# -------------------------------------------------------
setup_test
setup_prompt_router
sid="sk"
state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${state_dir}"
jq -nc '{task_intent:"execution",current_objective:"test"}' > "${state_dir}/session_state.json"
output="$(sim_prompt "${sid}" "yes please continue with the implementation")"

assert_empty "seq-K: no context without ULW" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence L: Bash test commands recorded as verification
# -------------------------------------------------------
setup_test
init_session "sl"
sim_verify "sl" "bash tests/test-quality-gates.sh" "=== Results: 10 passed, 0 failed ==="

assert_not_empty "seq-L: bash test recorded" "$(read_st "sl" "last_verify_ts")"
assert_eq "seq-L: outcome passed" "passed" "$(read_st "sl" "last_verify_outcome")"
assert_eq "seq-L: command recorded" "bash tests/test-quality-gates.sh" "$(read_st "sl" "last_verify_cmd")"
teardown_test


# -------------------------------------------------------
# Sequence M: shellcheck recorded as verification
# -------------------------------------------------------
setup_test
init_session "sm"
sim_verify "sm" "shellcheck bundle/dot-claude/skills/autowork/scripts/common.sh" ""

assert_not_empty "seq-M: shellcheck recorded" "$(read_st "sm" "last_verify_ts")"
assert_eq "seq-M: outcome passed" "passed" "$(read_st "sm" "last_verify_outcome")"
teardown_test


# -------------------------------------------------------
# Excellence gate tests
# -------------------------------------------------------
printf '\nExcellence gate:\n'


# -------------------------------------------------------
# Sequence N: Excellence reviewer records excellence timestamp
# -------------------------------------------------------
setup_test
init_session "sn"
sim_excellence_review "sn" "Verdict: Complete and excellent work."

assert_not_empty "seq-N: last_review_ts set" "$(read_st "sn" "last_review_ts")"
assert_not_empty "seq-N: last_excellence_review_ts set" "$(read_st "sn" "last_excellence_review_ts")"
teardown_test


# -------------------------------------------------------
# Sequence O: Standard review does NOT set excellence timestamp
# -------------------------------------------------------
setup_test
init_session "so"
sim_review "so" "Summary: Code looks good."

assert_not_empty "seq-O: last_review_ts set" "$(read_st "so" "last_review_ts")"
assert_empty "seq-O: no excellence_review_ts" "$(read_st "so" "last_excellence_review_ts")"
teardown_test


# -------------------------------------------------------
# Sequence P: Excellence gate blocks on multi-file task (3+ files)
# Note: seq-P/R/S/T disable the dimension gate via
# OMC_DIMENSION_GATE_FILE_COUNT=10 to isolate excellence-gate behavior.
# The dimension gate has its own dedicated tests (seq-U and friends).
# -------------------------------------------------------
setup_test
init_session "sp"
export OMC_DIMENSION_GATE_FILE_COUNT=10
sim_edit "sp" "/src/a.ts"
sim_edit "sp" "/src/b.ts"
sim_edit "sp" "/src/c.ts"
sim_verify "sp" "npm test" "Tests: 10 passed"
sim_review "sp" "Summary: Looks good. No issues."
output="$(sim_stop "sp")"

assert_contains "seq-P: excellence gate blocks" '"decision":"block"' "${output}"
assert_contains "seq-P: mentions excellence-reviewer" "excellence-reviewer" "${output}"
assert_contains "seq-P: mentions file count" "3 files edited" "${output}"
assert_eq "seq-P: excellence_guard_triggered" "1" "$(read_st "sp" "excellence_guard_triggered")"
unset OMC_DIMENSION_GATE_FILE_COUNT
teardown_test


# -------------------------------------------------------
# Sequence Q: No excellence gate on single-file task
# -------------------------------------------------------
setup_test
init_session "sq"
sim_edit "sq" "/src/single.ts"
sim_verify "sq" "npm test" "Tests: 5 passed"
sim_review "sq" "Summary: Code looks clean."
output="$(sim_stop "sq")"

assert_empty "seq-Q: single-file allows stop" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence R: Excellence gate fires only once
# -------------------------------------------------------
setup_test
init_session "sr"
export OMC_DIMENSION_GATE_FILE_COUNT=10
sim_edit "sr" "/src/a.ts"
sim_edit "sr" "/src/b.ts"
sim_edit "sr" "/src/c.ts"
sim_verify "sr" "npm test" "Tests: 10 passed"
sim_review "sr" "Summary: No issues."

# First stop: blocks for excellence
out1="$(sim_stop "sr")"
assert_contains "seq-R: first stop blocks for excellence" '"decision":"block"' "${out1}"

# Second stop: excellence_guard_triggered=1, skips excellence check, allows through
out2="$(sim_stop "sr")"
assert_empty "seq-R: second stop allowed (gate already triggered)" "${out2}"
unset OMC_DIMENSION_GATE_FILE_COUNT
teardown_test


# -------------------------------------------------------
# Sequence S: Excellence gate satisfied by running excellence reviewer
# -------------------------------------------------------
setup_test
init_session "ss"
export OMC_DIMENSION_GATE_FILE_COUNT=10
sim_edit "ss" "/src/a.ts"
sim_edit "ss" "/src/b.ts"
sim_edit "ss" "/src/c.ts"
sim_verify "ss" "npm test" "Tests: 10 passed"
sim_review "ss" "Summary: No issues."

# First stop: blocks for excellence
out1="$(sim_stop "ss")"
assert_contains "seq-S: blocks for excellence" '"decision":"block"' "${out1}"

# Run excellence review
sim_excellence_review "ss" "Verdict: Complete and excellent."

# Stop: should allow through (excellence review recorded)
out2="$(sim_stop "ss")"
assert_empty "seq-S: stop allowed after excellence review" "${out2}"
assert_not_empty "seq-S: excellence_review_ts set" "$(read_st "ss" "last_excellence_review_ts")"
unset OMC_DIMENSION_GATE_FILE_COUNT
teardown_test


# -------------------------------------------------------
# Sequence T: Excellence review must not overwrite review_had_findings
# Regression test: if a standard review sets review_had_findings=false,
# a subsequent excellence review must not clobber it to true.
# -------------------------------------------------------
setup_test
init_session "st"
export OMC_DIMENSION_GATE_FILE_COUNT=10
sim_edit "st" "/src/a.ts"
sim_edit "st" "/src/b.ts"
sim_edit "st" "/src/c.ts"
sim_verify "st" "npm test" "Tests: 5 passed"
# Standard review: clean (sets review_had_findings=false)
sim_review "st" "Summary: No issues found. Code looks clean."
assert_eq "seq-T: standard review clean" "false" "$(read_st "st" "review_had_findings")"

# Excellence review: must NOT overwrite review_had_findings
sim_excellence_review "st" "Verdict: Complete and excellent."
assert_eq "seq-T: excellence preserves review_had_findings" "false" "$(read_st "st" "review_had_findings")"
assert_not_empty "seq-T: excellence_review_ts set" "$(read_st "st" "last_excellence_review_ts")"

# Stop: should allow through (no unremediated findings)
out="$(sim_stop "st")"
assert_empty "seq-T: stop allowed" "${out}"
unset OMC_DIMENSION_GATE_FILE_COUNT
teardown_test


# -------------------------------------------------------
# VERDICT parsing tests (Fix #4)
# -------------------------------------------------------
printf '\nVERDICT parsing:\n'


# Sequence V1: VERDICT: CLEAN is authoritative (no findings)
setup_test
init_session "sv1"
sim_review "sv1" "Found several concerns that suggest a bug in the handler.

VERDICT: CLEAN"
assert_eq "seq-V1: VERDICT CLEAN authoritative" "false" "$(read_st "sv1" "review_had_findings")"
teardown_test

# Sequence V2: VERDICT: FINDINGS is authoritative (has findings)
setup_test
init_session "sv2"
sim_review "sv2" "Summary: Code looks clean. No significant issues.

VERDICT: FINDINGS (3)"
assert_eq "seq-V2: VERDICT FINDINGS authoritative" "true" "$(read_st "sv2" "review_had_findings")"
teardown_test

# Sequence V3: VERDICT: FINDINGS (0) treated as CLEAN
setup_test
init_session "sv3"
sim_review "sv3" "Reviewed. Nothing to fix.
VERDICT: FINDINGS (0)"
assert_eq "seq-V3: FINDINGS (0) = clean" "false" "$(read_st "sv3" "review_had_findings")"
teardown_test

# Sequence V4: No VERDICT line falls back to legacy regex (clean)
setup_test
init_session "sv4"
sim_review "sv4" "Summary: The code looks good. No significant issues found."
assert_eq "seq-V4: fallback detects clean" "false" "$(read_st "sv4" "review_had_findings")"
teardown_test

# Sequence V5: No VERDICT line falls back to legacy regex (findings)
setup_test
init_session "sv5"
sim_review "sv5" "Summary: Found 3 issues. 1. Missing null check."
assert_eq "seq-V5: fallback detects findings" "true" "$(read_st "sv5" "review_had_findings")"
teardown_test

# Sequence V6: Last VERDICT line wins (agent revises mid-message)
setup_test
init_session "sv6"
sim_review "sv6" "Initial scan looked clean.
VERDICT: CLEAN
Actually, on closer inspection:
VERDICT: FINDINGS (1)"
assert_eq "seq-V6: last VERDICT wins" "true" "$(read_st "sv6" "review_had_findings")"
teardown_test


# -------------------------------------------------------
# Doc-vs-code routing tests (Fix #3)
# -------------------------------------------------------
printf '\nDoc-vs-code routing:\n'


# Sequence W1: Code edit sets last_code_edit_ts, not last_doc_edit_ts
setup_test
init_session "sw1"
sim_edit "sw1" "/src/foo.ts"
assert_not_empty "seq-W1: last_code_edit_ts set" "$(read_st "sw1" "last_code_edit_ts")"
assert_empty "seq-W1: last_doc_edit_ts unset" "$(read_st "sw1" "last_doc_edit_ts")"
assert_eq "seq-W1: code_edit_count=1" "1" "$(read_st "sw1" "code_edit_count")"
teardown_test

# Sequence W2: Doc edit sets last_doc_edit_ts, not last_code_edit_ts
setup_test
init_session "sw2"
sim_edit_doc "sw2" "/docs/README.md"
assert_not_empty "seq-W2: last_doc_edit_ts set" "$(read_st "sw2" "last_doc_edit_ts")"
assert_empty "seq-W2: last_code_edit_ts unset" "$(read_st "sw2" "last_code_edit_ts")"
assert_eq "seq-W2: doc_edit_count=1" "1" "$(read_st "sw2" "doc_edit_count")"
teardown_test

# Sequence W3: Doc-only edits don't require verification
setup_test
init_session "sw3"
export OMC_DIMENSION_GATE_FILE_COUNT=10
sim_edit_doc "sw3" "/docs/a.md"
# Doc edits route to editor-critic for review, not quality-reviewer
sim_editor_critic "sw3" "Doc updated.
VERDICT: CLEAN"
# No sim_verify — doc-only edit should not require it
output="$(sim_stop "sw3")"
assert_empty "seq-W3: doc-only edit skips verify gate" "${output}"
unset OMC_DIMENSION_GATE_FILE_COUNT
teardown_test

# Sequence W4: Code edit after review still requires re-review
setup_test
init_session "sw4"
sim_edit "sw4" "/src/a.ts"
sim_verify "sw4" "npm test" "Tests: 5 passed"
sim_review "sw4" "Clean.
VERDICT: CLEAN"
sleep 1
sim_edit "sw4" "/src/b.ts"
output="$(sim_stop "sw4")"
assert_contains "seq-W4: code edit after review blocks" '"decision":"block"' "${output}"
assert_contains "seq-W4: mentions quality-reviewer" "quality-reviewer" "${output}"
teardown_test

# Sequence W5: Doc edit after code review does not require code re-review
setup_test
init_session "sw5"
sim_edit "sw5" "/src/a.ts"
sim_verify "sw5" "npm test" "Tests: 5 passed"
sim_review "sw5" "Clean.
VERDICT: CLEAN"
sleep 1
sim_edit_doc "sw5" "/docs/notes.md"
output="$(sim_stop "sw5")"
# Should still block (missing doc review), but for editor-critic not quality-reviewer
assert_contains "seq-W5: doc edit after code review blocks" '"decision":"block"' "${output}"
assert_contains "seq-W5: routes to editor-critic" "editor-critic" "${output}"
teardown_test


# -------------------------------------------------------
# Dimension tracker tests (Option C: prescribed sequence)
# -------------------------------------------------------
printf '\nDimension tracker:\n'


# Sequence U1: Full Sugar-Tracker-style complex-task flow = stop allowed
setup_test
init_session "su1"
# 3 code files triggers dimension gate at default threshold
sim_edit "su1" "/src/a.ts"
sim_edit "su1" "/src/b.ts"
sim_edit "su1" "/src/c.ts"
sim_verify "su1" "npm test" "Tests: 10 passed"
sim_review "su1" "Clean.
VERDICT: CLEAN"

# After quality-reviewer, standard gate passes but dimension gate blocks for metis
out1="$(sim_stop "su1")"
assert_contains "seq-U1: block 1 for missing metis" '"decision":"block"' "${out1}"
assert_contains "seq-U1: names metis" "metis" "${out1}"
assert_contains "seq-U1: names stress_test" "stress_test" "${out1}"

sim_metis "su1"

# Now blocks for excellence
out2="$(sim_stop "su1")"
assert_contains "seq-U1: block 2 for missing excellence" '"decision":"block"' "${out2}"
assert_contains "seq-U1: names excellence-reviewer" "excellence-reviewer" "${out2}"

sim_excellence_review "su1"

# All dimensions ticked, stop allowed
out3="$(sim_stop "su1")"
assert_empty "seq-U1: stop allowed after all dims ticked" "${out3}"
assert_not_empty "seq-U1: dim bug_hunt set" "$(read_st "su1" "dim_bug_hunt_ts")"
assert_not_empty "seq-U1: dim stress_test set" "$(read_st "su1" "dim_stress_test_ts")"
assert_not_empty "seq-U1: dim completeness set" "$(read_st "su1" "dim_completeness_ts")"
teardown_test

# Sequence U2: Complex task with doc edit requires editor-critic too
setup_test
init_session "su2"
sim_edit "su2" "/src/a.ts"
sim_edit "su2" "/src/b.ts"
sim_edit_doc "su2" "/CHANGELOG.md"
sim_verify "su2" "npm test" "Tests: 10 passed"
sim_review "su2" "Clean.
VERDICT: CLEAN"
sim_metis "su2"
sim_excellence_review "su2"

# Dimension gate should now require prose (editor-critic)
out="$(sim_stop "su2")"
assert_contains "seq-U2: block for prose dimension" '"decision":"block"' "${out}"
assert_contains "seq-U2: names editor-critic" "editor-critic" "${out}"

sim_editor_critic "su2"
out2="$(sim_stop "su2")"
assert_empty "seq-U2: stop allowed after editor-critic" "${out2}"
teardown_test

# Sequence U3: Very complex task (6+ files) requires briefing-analyst for traceability
setup_test
init_session "su3"
sim_edit "su3" "/src/a.ts"
sim_edit "su3" "/src/b.ts"
sim_edit "su3" "/src/c.ts"
sim_edit "su3" "/src/d.ts"
sim_edit "su3" "/src/e.ts"
sim_edit "su3" "/src/f.ts"
sim_verify "su3" "npm test" "Tests: 10 passed"
sim_review "su3" "Clean.
VERDICT: CLEAN"
sim_metis "su3"
sim_excellence_review "su3"

# Dimension gate requires traceability at 6+ files
out="$(sim_stop "su3")"
assert_contains "seq-U3: block for traceability" '"decision":"block"' "${out}"
assert_contains "seq-U3: names briefing-analyst" "briefing-analyst" "${out}"

sim_briefing_analyst "su3"
out2="$(sim_stop "su3")"
assert_empty "seq-U3: stop allowed after briefing-analyst" "${out2}"
teardown_test

# Sequence U4: Simple task (below threshold) bypasses dimension gate
setup_test
init_session "su4"
sim_edit "su4" "/src/single.ts"
sim_verify "su4" "npm test" "Tests: 5 passed"
sim_review "su4" "Clean.
VERDICT: CLEAN"
output="$(sim_stop "su4")"
assert_empty "seq-U4: single-file bypass dimension gate" "${output}"
teardown_test

# Sequence U5: Post-tick code edit invalidates code dimensions (timestamp-based)
setup_test
init_session "su5"
sim_edit "su5" "/src/a.ts"
sim_edit "su5" "/src/b.ts"
sim_edit "su5" "/src/c.ts"
sim_verify "su5" "npm test" "Tests: 10 passed"
sim_review "su5" "Clean.
VERDICT: CLEAN"
sim_metis "su5"
sim_excellence_review "su5"

# All dims ticked; now edit another code file — dimensions should be invalidated
# by the timestamp-based comparison (no explicit clearing needed)
sleep 1
sim_edit "su5" "/src/d.ts"

# Stop should block — last_code_edit_ts > dim_bug_hunt_ts etc.
output="$(sim_stop "su5")"
assert_contains "seq-U5: post-edit re-blocks" '"decision":"block"' "${output}"
teardown_test

# Sequence U6: Doc edit does NOT invalidate code dimensions
setup_test
init_session "su6"
sim_edit "su6" "/src/a.ts"
sim_edit "su6" "/src/b.ts"
sim_edit "su6" "/src/c.ts"
sim_verify "su6" "npm test" "Tests: 10 passed"
sim_review "su6" "Clean.
VERDICT: CLEAN"
sim_metis "su6"
sim_excellence_review "su6"
sleep 1
# Doc edit: should only invalidate prose (which wasn't ticked yet anyway,
# so now prose becomes required)
sim_edit_doc "su6" "/docs/a.md"

output="$(sim_stop "su6")"
# Should block for prose only, not for bug_hunt/code_quality/etc
assert_contains "seq-U6: doc edit blocks for prose" '"decision":"block"' "${output}"
assert_contains "seq-U6: names editor-critic" "editor-critic" "${output}"
# Should NOT name metis again — stress_test dimension is still valid
if [[ "${output}" == *"run \`metis\`"* ]]; then
  printf '  FAIL: seq-U6: should not re-require metis (stress_test still valid)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# Sequence U7: Dimension gate exhaustion at 3 blocks
setup_test
init_session "su7"
sim_edit "su7" "/src/a.ts"
sim_edit "su7" "/src/b.ts"
sim_edit "su7" "/src/c.ts"
sim_verify "su7" "npm test" "Tests: 10 passed"
sim_review "su7" "Clean.
VERDICT: CLEAN"

# 3 dimension-gate blocks without running metis
out1="$(sim_stop "su7")"
assert_contains "seq-U7: block 1" '"decision":"block"' "${out1}"
out2="$(sim_stop "su7")"
assert_contains "seq-U7: block 2" '"decision":"block"' "${out2}"
out3="$(sim_stop "su7")"
assert_contains "seq-U7: block 3" '"decision":"block"' "${out3}"
assert_contains "seq-U7: final warning" "final dimension-gate block" "${out3}"

# 4th stop: exhausted, allow (falls through to excellence gate which fires once)
out4="$(sim_stop "su7")"
# The excellence gate fires at block 4 because dim gate exhausted
# Either excellence gate blocks, or it allows. Verify dimension exhaustion was recorded.
exhausted_detail="$(read_st "su7" "guard_exhausted_detail")"
assert_contains "seq-U7: exhaustion recorded" "dimensions_missing" "${exhausted_detail}"
teardown_test


# -------------------------------------------------------
# Concise repeat-block message tests (Fix #6)
# -------------------------------------------------------
printf '\nConcise repeat messages:\n'


# Sequence AA: Block 1 verbose, block 2 concise
setup_test
init_session "saa"
sim_edit "saa" "/src/foo.ts"
# No review, no verify → keeps blocking on missing_review

out1="$(sim_stop "saa")"
assert_contains "seq-AA: block 1 is verbose" "FIRST self-assess" "${out1}"

out2="$(sim_stop "saa")"
# Block 2 must NOT contain the self-assess boilerplate
if [[ "${out2}" == *"FIRST self-assess"* ]]; then
  printf '  FAIL: seq-AA: block 2 should drop FIRST self-assess text\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "seq-AA: block 2 concise form" "Still missing" "${out2}"
assert_contains "seq-AA: block 2 preserves quality-reviewer" "quality-reviewer" "${out2}"

out3="$(sim_stop "saa")"
assert_contains "seq-AA: block 3 still concise" "Still missing" "${out3}"
assert_contains "seq-AA: block 3 final warning" "final guard block" "${out3}"
teardown_test


# -------------------------------------------------------
# Resumed-session grace test
# -------------------------------------------------------
printf '\nResumed-session grace:\n'

# Sequence BB: Resumed session with complex history gets one free stop
setup_test
sid="sbb"
state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
mkdir -p "${state_dir}"
# Simulate a resumed session: code_edit_count >= threshold, no dim ticks,
# resume_source_session_id is set.
jq -nc --arg ts "$(date +%s)" \
  '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"execution",
    current_objective:"resumed task",last_user_prompt_ts:$ts,
    last_edit_ts:$ts,last_code_edit_ts:$ts,last_verify_ts:$ts,
    last_verify_outcome:"passed",last_review_ts:$ts,review_had_findings:"false",
    code_edit_count:"5",resume_source_session_id:"prev-session-abc"}' \
  > "${state_dir}/session_state.json"

# First stop on resumed session: dimension gate should grant grace
out1="$(sim_stop "sbb")"
assert_empty "seq-BB: resumed session first stop allowed" "${out1}"
assert_eq "seq-BB: grace marked used" "1" "$(read_st "sbb" "dimension_resume_grace_used")"
teardown_test


printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
