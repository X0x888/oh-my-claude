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
  local attempt
  for attempt in 1 2 3 4 5; do
    rm -rf "${TEST_HOME}" 2>/dev/null || true
    [[ ! -e "${TEST_HOME}" ]] && return
    sleep 0.05
  done
  rm -rf "${TEST_HOME}" 2>/dev/null || true
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
      '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:$r}')"
}

sim_mcp_verify() {
  local sid="$1"
  local tool_name="${2:-mcp__plugin_playwright_playwright__browser_snapshot}"
  local res="${3:-}"
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "$(jq -nc --arg s "${sid}" --arg t "${tool_name}" --arg r "${res}" \
      '{session_id:$s,tool_name:$t,tool_input:{},tool_response:$r}')"
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

sim_design_reviewer() {
  local sid="$1"
  local msg="${2:-Visual design is distinctive and intentional.
VERDICT: CLEAN}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" design_quality 2>/dev/null || true
}

sim_edit_doc() {
  local sid="$1"
  local fp="${2:-/docs/README.md}"
  run_hook "${HOOK_DIR}/mark-edit.sh" \
    "$(jq -nc --arg s "${sid}" --arg f "${fp}" '{session_id:$s,tool_input:{file_path:$f}}')"
}

sim_edit_ui() {
  local sid="$1"
  local fp="${2:-/src/components/Button.tsx}"
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

sim_stop_mode() {
  local sid="$1"
  local mode="$2"
  local msg="${3:-Here is the completed work.}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | env OMC_GUARD_EXHAUSTION_MODE="${mode}" bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true
}

sim_status_mode() {
  local mode="$1"
  env OMC_GUARD_EXHAUSTION_MODE="${mode}" bash "${HOOK_DIR}/show-status.sh" 2>/dev/null || true
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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
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
assert_not_empty "verify(pass): confidence recorded" "$(read_st "s2" "last_verify_confidence")"
assert_not_empty "verify(pass): method recorded" "$(read_st "s2" "last_verify_method")"
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
# Test 7b: Narration-style findings must NOT pollute defect-pattern tracker.
# Regression test for the narration-fallback noise bug — reviewer prose like
# "Let me compile my findings…" used to match the old permissive fallback and
# record bogus defects classified as "unknown" or "security" (via incidental
# word matches). The hardened extraction regex should skip such prose; the
# verdict-level metric is all that should register.
# -------------------------------------------------------
setup_test
init_session "s7b"
# Purge any prior defect patterns so the count starts at a known state
defect_file="${TEST_HOME}/.claude/quality-pack/defect-patterns.json"
rm -f "${defect_file}"
sim_review "s7b" "I have a clear picture now. Let me compile my findings after careful analysis.
The tests appear well-structured and the security posture is acceptable.
VERDICT: FINDINGS (2)"
# Wait briefly for any backgrounded record_defect_pattern to complete.
# record-reviewer.sh backgrounds the write, so we give it time before asserting.
sleep 0.5

assert_eq "narration(v): review_had_findings still captured via VERDICT" "true" "$(read_st "s7b" "review_had_findings")"

if [[ -f "${defect_file}" ]]; then
  defect_total="$(jq -r '[.[] | select(type=="object") | .count] | add // 0' "${defect_file}" 2>/dev/null || printf '0')"
else
  defect_total=0
fi
assert_eq "narration(v): no defect pattern recorded from narration-only prose" "0" "${defect_total}"
teardown_test


# -------------------------------------------------------
# Test 7c: Structured numbered finding still records a defect pattern
# (complement to 7b — confirms the tightened regex hasn't broken the
# legitimate path).
# -------------------------------------------------------
setup_test
init_session "s7c"
defect_file="${TEST_HOME}/.claude/quality-pack/defect-patterns.json"
rm -f "${defect_file}"
sim_review "s7c" "1. Missing null check in auth handler — race on session token.
2. Untested error path in retry logic.
VERDICT: FINDINGS (2)"
sleep 0.5

assert_eq "structured(n): review_had_findings true" "true" "$(read_st "s7c" "review_had_findings")"

if [[ -f "${defect_file}" ]]; then
  defect_total="$(jq -r '[.[] | select(type=="object") | .count] | add // 0' "${defect_file}" 2>/dev/null || printf '0')"
else
  defect_total=0
fi
# Exactly one pattern entry should have been recorded (one sample per review)
if [[ "${defect_total}" -ge 1 ]]; then
  assert_eq "structured(n): defect pattern recorded from numbered finding" "1" "1"
else
  assert_eq "structured(n): defect pattern recorded from numbered finding" "1" "${defect_total}"
fi
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
assert_contains "seq-B: verify failed message" "failed" "${output}"
assert_contains "seq-B: verify failed names cmd" "npm test" "${output}"
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

# Fourth stop: exhausted, released with scorecard (scorecard mode is default)
out4="$(sim_stop "se")"
assert_contains "seq-E: fourth stop exhausted scorecard" "QUALITY SCORECARD" "${out4}"
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
# Sequence K2: Ordinary UI prompts inject design context
# -------------------------------------------------------
setup_test
setup_prompt_router
init_session "sk2"
output="$(sim_prompt "sk2" "Create a login page for onboarding")"

assert_contains "seq-K2: UI context injected" "UI/design work detected" "${output}"
assert_contains "seq-K2: design gate mentioned" "design-reviewer quality gate" "${output}"
teardown_test

# -------------------------------------------------------
# Sequence K3: Ambiguous backend prompts do not inject UI context
# -------------------------------------------------------
setup_test
setup_prompt_router
init_session "sk3"
output="$(sim_prompt "sk3" "Implement the REST API form parser and add CSS loading to webpack")"

assert_not_contains "seq-K3: no UI context on backend prompt" "UI/design work detected" "${output}"
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
assert_contains "seq-U1: names stress-test" "stress-test" "${out1}"

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
assert_contains "seq-U7: final warning" "final review-coverage block" "${out3}"

# 4th stop: exhausted in scorecard mode, released with scorecard
out4="$(sim_stop_mode "su7" "scorecard")"
assert_contains "seq-U7: scorecard release emits scorecard" "QUALITY SCORECARD" "${out4}"
assert_not_contains "seq-U7: scorecard release is not a block" '"decision":"block"' "${out4}"
exhausted_detail="$(read_st "su7" "guard_exhausted_detail")"
assert_contains "seq-U7: exhaustion recorded" "dimensions_missing" "${exhausted_detail}"
teardown_test

# Sequence U7B: Review coverage gate exhaustion in block mode keeps blocking
setup_test
init_session "su7b"
sim_edit "su7b" "/src/a.ts"
sim_edit "su7b" "/src/b.ts"
sim_edit "su7b" "/src/c.ts"
sim_verify "su7b" "npm test" "Tests: 10 passed"
sim_review "su7b" "Clean.
VERDICT: CLEAN"
sim_stop_mode "su7b" "block" >/dev/null
sim_stop_mode "su7b" "block" >/dev/null
sim_stop_mode "su7b" "block" >/dev/null
out4="$(sim_stop_mode "su7b" "block")"
assert_contains "seq-U7B: block mode blocks" '"decision":"block"' "${out4}"
assert_contains "seq-U7B: block mode named" "BLOCK MODE" "${out4}"
assert_contains "seq-U7B: block mode includes scorecard" "QUALITY SCORECARD" "${out4}"
teardown_test

# Sequence U8: UI file edits require design_quality dimension
setup_test
init_session "su8"
sim_edit_ui "su8" "/src/components/Button.tsx"
sim_edit_ui "su8" "/src/pages/Home.tsx"
sim_edit "su8" "/src/utils.ts"
sim_verify "su8" "npm test" "Tests: 10 passed"
sim_review "su8" "Clean.
VERDICT: CLEAN"
# quality-reviewer ticks bug_hunt + code_quality, but stress_test, completeness,
# and design_quality are still required. Stop should be blocked.
out1="$(sim_stop "su8")"
assert_contains "seq-U8: dimension gate blocks" '"decision":"block"' "${out1}"
assert_contains "seq-U8: design quality in missing reviews" "design quality" "${out1}"

# Run metis — ticks stress_test
sim_metis "su8"

# Run design-reviewer — should tick design_quality
sim_design_reviewer "su8"

# Run excellence-reviewer — ticks completeness
sim_excellence_review "su8"

# Now stop should succeed (all dimensions ticked)
out2="$(sim_stop "su8")"
assert_empty "seq-U8: stop allowed after design review" "${out2}"

# Verify ui_edit_count was tracked
assert_eq "seq-U8: ui_edit_count=2" "2" "$(read_st "su8" "ui_edit_count")"
assert_eq "seq-U8: code_edit_count=3" "3" "$(read_st "su8" "code_edit_count")"
teardown_test

# Sequence U9: Non-UI code edits do NOT require design_quality
setup_test
init_session "su9"
sim_edit "su9" "/src/a.ts"
sim_edit "su9" "/src/b.ts"
sim_edit "su9" "/src/c.ts"
sim_verify "su9" "npm test" "Tests: 10 passed"
sim_review "su9" "Clean.
VERDICT: CLEAN"
sim_metis "su9"
sim_excellence_review "su9"
# No design-reviewer needed — no UI files edited
out="$(sim_stop "su9")"
assert_empty "seq-U9: no design gate for non-UI edits" "${out}"
assert_eq "seq-U9: ui_edit_count=0" "" "$(read_st "su9" "ui_edit_count")"
teardown_test


# -------------------------------------------------------
# Status surface
# -------------------------------------------------------
printf '\nStatus surface:\n'

setup_test
init_session "sstatus"
sim_edit "sstatus" "/src/foo.ts"
sim_verify "sstatus" "npm test" "Tests: 10 passed"
sim_review "sstatus" "A regression risk remains.
VERDICT: FINDINGS (1)"
status_out="$(sim_status_mode "block")"
assert_contains "status: verification confidence shown" "Verification Confidence" "${status_out}"
assert_not_contains "status: verification method is no longer unknown" "Method: unknown" "${status_out}"
assert_contains "status: guard configuration shown" "Exhaustion mode:" "${status_out}"
assert_contains "status: findings-only dimensions shown" "bug_hunt: findings reported" "${status_out}"
teardown_test


# -------------------------------------------------------
# Low-confidence verification regression test
# -------------------------------------------------------
printf '\nLow-confidence verification:\n'

# Sequence LC: shellcheck-only verification (confidence=30) should NOT
# satisfy the verify gate at default threshold (40). The user must run
# a real test suite.
setup_test
init_session "slc"
sim_edit "slc" "/src/app.ts"

# Verify with shellcheck — scores 30 (framework keyword only, no output signals)
sim_verify "slc" "shellcheck src/app.ts" ""

# Review passes
sim_review "slc" "Looks clean.
VERDICT: CLEAN"

# Stop should block because confidence (30) < threshold (40)
out="$(sim_stop "slc")"
assert_contains "seq-LC: low-confidence blocks" '"decision":"block"' "${out}"
assert_contains "seq-LC: mentions low confidence" "low confidence" "${out}"

# Now run npm test (scores 70+ with output) — should satisfy
sim_verify "slc" "npm test" "Tests: 10 passed, 0 failed"
out2="$(sim_stop "slc")"
assert_empty "seq-LC: real verification satisfies gate" "${out2}"
teardown_test


# -------------------------------------------------------
# MCP verification e2e tests
# -------------------------------------------------------
printf '\nMCP verification (e2e):\n'

# Test MCP-V1: browser_snapshot records verification state
setup_test
init_session "smv1"
sim_mcp_verify "smv1" "mcp__plugin_playwright_playwright__browser_snapshot" "DOM content: Welcome to dashboard"
assert_not_empty "mcp-v1: last_verify_ts set" "$(read_st "smv1" "last_verify_ts")"
assert_eq "mcp-v1: outcome is passed" "passed" "$(read_st "smv1" "last_verify_outcome")"
assert_eq "mcp-v1: tool name recorded" "mcp__plugin_playwright_playwright__browser_snapshot" "$(read_st "smv1" "last_verify_cmd")"
assert_not_empty "mcp-v1: confidence recorded" "$(read_st "smv1" "last_verify_confidence")"
assert_eq "mcp-v1: method is mcp type" "mcp_browser_dom_check" "$(read_st "smv1" "last_verify_method")"
teardown_test

# Test MCP-V2: console_messages with error detects failure
setup_test
init_session "smv2"
sim_mcp_verify "smv2" "mcp__plugin_playwright_playwright__browser_console_messages" "TypeError: Cannot read properties of null"
assert_eq "mcp-v2: console error = failed" "failed" "$(read_st "smv2" "last_verify_outcome")"
assert_eq "mcp-v2: method" "mcp_browser_console_check" "$(read_st "smv2" "last_verify_method")"
teardown_test

# Test MCP-V3: network_requests with 401 detects failure
setup_test
init_session "smv3"
sim_mcp_verify "smv3" "mcp__plugin_playwright_playwright__browser_network_requests" "GET /api/me — 401 Unauthorized"
assert_eq "mcp-v3: 401 = failed" "failed" "$(read_st "smv3" "last_verify_outcome")"
teardown_test

# Test MCP-V4: empty snapshot = passed (but low confidence, gate blocks)
setup_test
init_session "smv4"
sim_mcp_verify "smv4" "mcp__plugin_playwright_playwright__browser_snapshot" ""
assert_eq "mcp-v4: empty output = passed" "passed" "$(read_st "smv4" "last_verify_outcome")"
# Without UI context, base confidence should be 25 (below threshold)
assert_eq "mcp-v4: low confidence" "25" "$(read_st "smv4" "last_verify_confidence")"
teardown_test

# Test MCP-V5: MCP verification with UI edit context in full sequence
setup_test
init_session "smv5"
sim_edit "smv5" "/src/App.tsx"
sim_mcp_verify "smv5" "mcp__plugin_playwright_playwright__browser_snapshot" "DOM content: Counter: 0"
# With UI edit, confidence should be 45 (25 base + 20 UI bonus)
assert_eq "mcp-v5: UI context boosts confidence" "45" "$(read_st "smv5" "last_verify_confidence")"
sim_review "smv5" "Summary: The code looks good. No issues found."
out="$(sim_stop "smv5")"
assert_empty "mcp-v5: full MCP cycle allows stop" "${out}"
teardown_test

# Test MCP-V6: passive MCP without UI edit blocks at stop
setup_test
init_session "smv6"
sim_edit "smv6" "/src/utils.ts"
sim_mcp_verify "smv6" "mcp__plugin_playwright_playwright__browser_snapshot" ""
sim_review "smv6" "Summary: The code looks good. No issues found."
out="$(sim_stop "smv6")"
assert_not_empty "mcp-v6: passive MCP on non-UI file blocks" "${out}"
assert_contains "mcp-v6: mentions low confidence" "low confidence" "${out}"
teardown_test

# Test MCP-V7: computer-use screenshot records as visual_check
setup_test
init_session "smv7"
sim_mcp_verify "smv7" "mcp__computer-use__screenshot" "Screenshot captured"
assert_eq "mcp-v7: method" "mcp_visual_check" "$(read_st "smv7" "last_verify_method")"
assert_eq "mcp-v7: outcome passed" "passed" "$(read_st "smv7" "last_verify_outcome")"
teardown_test

# Test MCP-V8: browser_run_code classified same as evaluate
setup_test
init_session "smv8"
sim_mcp_verify "smv8" "mcp__plugin_playwright_playwright__browser_run_code" "42"
assert_eq "mcp-v8: run_code = eval method" "mcp_browser_eval_check" "$(read_st "smv8" "last_verify_method")"
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


# -------------------------------------------------------
# Compaction hardening (gaps 1–7)
# -------------------------------------------------------
printf '\nCompaction hardening:\n'

QUALITY_PACK_DIR="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts"

# quality-pack scripts source common.sh via ${HOME}/.claude/... — mirror
# the symlink pattern established in setup_prompt_router so the test sandbox
# can execute them without a real install.
setup_compact_tests() {
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
}

sim_pre_agent_dispatch() {
  local sid="$1" subagent_type="$2" description="${3:-sample task}"
  run_hook "${HOOK_DIR}/record-pending-agent.sh" \
    "$(jq -nc --arg s "${sid}" --arg sa "${subagent_type}" --arg d "${description}" \
      '{session_id:$s,tool_name:"Agent",tool_input:{subagent_type:$sa,description:$d,prompt:"do a thing"}}')"
}

sim_pre_compact() {
  local sid="$1" trigger="${2:-auto}"
  run_hook "${QUALITY_PACK_DIR}/pre-compact-snapshot.sh" \
    "$(jq -nc --arg s "${sid}" --arg t "${trigger}" \
      '{session_id:$s,trigger:$t,custom_instructions:"",cwd:"/tmp",transcript_path:"/tmp/t.jsonl",hook_event_name:"PreCompact"}')"
}

sim_post_compact() {
  local sid="$1" trigger="${2:-auto}"
  # Use ${3-default} (not ${3:-default}) so an explicit empty string is
  # preserved — Gap 6 test needs to pass compact_summary="".
  local summary="${3-Native compact summary body}"
  run_hook "${QUALITY_PACK_DIR}/post-compact-summary.sh" \
    "$(jq -nc --arg s "${sid}" --arg t "${trigger}" --arg cs "${summary}" \
      '{session_id:$s,trigger:$t,compact_summary:$cs,cwd:"/tmp",transcript_path:"/tmp/t.jsonl",hook_event_name:"PostCompact"}')"
}

sim_session_start_compact() {
  local sid="$1"
  run_hook "${QUALITY_PACK_DIR}/session-start-compact-handoff.sh" \
    "$(jq -nc --arg s "${sid}" \
      '{session_id:$s,source:"compact",cwd:"/tmp",transcript_path:"/tmp/t.jsonl",hook_event_name:"SessionStart"}')"
}

sim_user_prompt() {
  local sid="$1" text="${2:-continue}"
  run_hook "${QUALITY_PACK_DIR}/prompt-intent-router.sh" \
    "$(jq -nc --arg s "${sid}" --arg p "${text}" '{session_id:$s,prompt:$p}')"
}

# -------------------------------------------------------
# Gap 1: ULW affirmation on post-compact session start
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg1" "coding"
sim_pre_compact "cg1"
sim_post_compact "cg1" "auto" "Summary body"
out_g1="$(sim_session_start_compact "cg1")"
assert_contains "gap1: injection mentions ultrawork still active" "Ultrawork mode is still active post-compact" "${out_g1}"
assert_contains "gap1: injection mentions domain" "coding" "${out_g1}"
teardown_test

# -------------------------------------------------------
# Gap 2: post-compact intent bias preserves short prompts as continuation
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg2" "coding"
# Seed a non-trivial previous objective
state_dir="${TEST_HOME}/.claude/quality-pack/state/cg2"
jq --arg o "Refactor the authentication middleware to support session refresh" \
  '. + {current_objective:$o}' "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
  && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
sim_pre_compact "cg2"
sim_post_compact "cg2" "auto" "Summary"
# Flag should be set
assert_eq "gap2: just_compacted set by post-compact" "1" "$(read_st "cg2" "just_compacted")"
# Short follow-up prompt should preserve the prior objective
sim_user_prompt "cg2" "status" >/dev/null
post_obj="$(read_st "cg2" "current_objective")"
assert_contains "gap2: objective preserved after short prompt" "Refactor the authentication middleware" "${post_obj}"
# Flag should have decayed
assert_empty "gap2: just_compacted cleared after use" "$(read_st "cg2" "just_compacted")"
teardown_test

# -------------------------------------------------------
# Gap 3: pending-agent tracking — dispatch, snapshot, clear
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3" "coding"
sim_pre_agent_dispatch "cg3" "quality-researcher" "check repo conventions"
sim_pre_agent_dispatch "cg3" "librarian" "verify API docs"
pending_file="${TEST_HOME}/.claude/quality-pack/state/cg3/pending_agents.jsonl"
if [[ -f "${pending_file}" ]] && [[ "$(wc -l <"${pending_file}")" -eq 2 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3: pending_agents.jsonl should have 2 entries\n' >&2
  fail=$((fail + 1))
fi
# Snapshot should list both pending agents
sim_pre_compact "cg3"
snapshot="$(cat "${TEST_HOME}/.claude/quality-pack/state/cg3/precompact_snapshot.md" 2>/dev/null || echo "")"
assert_contains "gap3: snapshot lists quality-researcher" "quality-researcher" "${snapshot}"
assert_contains "gap3: snapshot lists librarian" "librarian" "${snapshot}"
assert_contains "gap3: snapshot section header" "Pending Specialists" "${snapshot}"
# SubagentStop for librarian should remove exactly one librarian entry
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3" '{session_id:$s,agent_type:"librarian",last_assistant_message:"Done."}')"
if [[ -f "${pending_file}" ]] && [[ "$(wc -l <"${pending_file}")" -eq 1 ]] \
  && grep -q "quality-researcher" "${pending_file}" \
  && ! grep -q "librarian" "${pending_file}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3: librarian entry should be removed, quality-researcher should remain\n    contents: %s\n' "$(cat "${pending_file}" 2>/dev/null)" >&2
  fail=$((fail + 1))
fi
# Post-compact session start should emit re-dispatch directive
sim_post_compact "cg3" "auto" "Summary"
out_g3="$(sim_session_start_compact "cg3")"
assert_contains "gap3: handoff mentions interrupted dispatches" "Interrupted specialist dispatches" "${out_g3}"
teardown_test

# -------------------------------------------------------
# Gap 3 robustness: malformed JSONL line must not freeze the pending queue.
# Regression for quality-reviewer critical #1: a prior implementation used
# `jq --slurp` which aborted with exit 5 on the first non-JSONL line,
# silently leaving the pending queue untouched forever.
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3c" "coding"
sim_pre_agent_dispatch "cg3c" "quality-researcher" "real dispatch"
pending_file_c="${TEST_HOME}/.claude/quality-pack/state/cg3c/pending_agents.jsonl"
# Inject a garbage line between valid entries to simulate filesystem
# corruption or a tool-noise artifact.
printf 'this is not json at all\n' >> "${pending_file_c}"
sim_pre_agent_dispatch "cg3c" "librarian" "second dispatch"
# SubagentStop for quality-researcher should still remove the matching entry.
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3c" '{session_id:$s,agent_type:"quality-researcher",last_assistant_message:"Done."}')"
if grep -q "quality-researcher" "${pending_file_c}"; then
  printf '  FAIL: gap3-robust: quality-researcher entry should have been removed\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# The garbage line and the librarian entry should both still be present.
if grep -q "this is not json" "${pending_file_c}" && grep -q "librarian" "${pending_file_c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3-robust: garbage line or librarian entry lost\n    contents: %s\n' "$(cat "${pending_file_c}" 2>/dev/null)" >&2
  fail=$((fail + 1))
fi
teardown_test

# -------------------------------------------------------
# Gap 3 edge case: FIFO-oldest removal for same-type concurrent dispatches
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3b" "coding"
sim_pre_agent_dispatch "cg3b" "quality-researcher" "first dispatch"
sim_pre_agent_dispatch "cg3b" "quality-researcher" "second dispatch"
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3b" '{session_id:$s,agent_type:"quality-researcher",last_assistant_message:"Done."}')"
pending_file_b="${TEST_HOME}/.claude/quality-pack/state/cg3b/pending_agents.jsonl"
# The "first dispatch" (oldest FIFO entry) should be removed
if [[ -f "${pending_file_b}" ]] \
  && [[ "$(wc -l <"${pending_file_b}")" -eq 1 ]] \
  && grep -q "second dispatch" "${pending_file_b}" \
  && ! grep -q "first dispatch" "${pending_file_b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3: FIFO-oldest removal did not keep newest entry\n    contents: %s\n' "$(cat "${pending_file_b}" 2>/dev/null)" >&2
  fail=$((fail + 1))
fi
teardown_test

# -------------------------------------------------------
# Gap 4: pending-review enforcement across compact
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg4" "coding"
sim_edit "cg4" "/src/auth.ts"
# No review happens
sim_pre_compact "cg4"
assert_eq "gap4: review_pending_at_compact set" "1" "$(read_st "cg4" "review_pending_at_compact")"
sim_post_compact "cg4" "auto" "Summary"
out_g4="$(sim_session_start_compact "cg4")"
assert_contains "gap4: injection demands reviewer" "MUST run quality-reviewer" "${out_g4}"
# First post-compact prompt should clear the flag
sim_user_prompt "cg4" "status" >/dev/null
assert_empty "gap4: flag cleared after first post-compact prompt" "$(read_st "cg4" "review_pending_at_compact")"
teardown_test

# -------------------------------------------------------
# Gap 4 negative: no edits means no pending-review flag
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg4b" "coding"
sim_pre_compact "cg4b"
assert_empty "gap4b: no edits → no review_pending_at_compact flag" "$(read_st "cg4b" "review_pending_at_compact")"
teardown_test

# -------------------------------------------------------
# Gap 5: atomic batch write on pre-compact — all compact-adjacent state
# keys land together, so a concurrent SubagentStop cannot interleave a
# stale value between the trigger write and the request-timestamp write.
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg5" "coding"
sim_pre_compact "cg5" "manual"
assert_eq "gap5: trigger written by pre-compact" "manual" "$(read_st "cg5" "last_compact_trigger")"
assert_not_empty "gap5: request ts written by pre-compact" "$(read_st "cg5" "last_compact_request_ts")"
sim_post_compact "cg5" "manual" "Summary"
assert_eq "gap5: post-compact preserves trigger" "manual" "$(read_st "cg5" "last_compact_trigger")"
assert_eq "gap5: post-compact sets just_compacted" "1" "$(read_st "cg5" "just_compacted")"
teardown_test

# -------------------------------------------------------
# Gap 2 staleness: just_compacted flag with ts older than 15min decays
# to non-bias behavior on the next UserPromptSubmit.
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg2stale" "coding"
# Manually seed state with an old just_compacted timestamp (30 min in past)
state_dir="${TEST_HOME}/.claude/quality-pack/state/cg2stale"
stale_ts=$(( $(date +%s) - 1800 ))
jq --arg o "Prior objective from before the pause" --arg sts "${stale_ts}" \
  '. + {current_objective:$o,just_compacted:"1",just_compacted_ts:$sts}' \
  "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
  && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
# Trigger a prompt — the stale bias should NOT fire, so a clearly-new
# imperative should become the new objective.
sim_user_prompt "cg2stale" "implement a totally new feature unrelated to earlier work please" >/dev/null
new_obj="$(read_st "cg2stale" "current_objective")"
# With bias off, the router's normalized-objective branch takes over and
# stores the user's new prompt verbatim.
assert_contains "gap2-stale: stale flag ignored, new objective accepted" "implement a totally new feature" "${new_obj}"
# Flag should still be cleared regardless (single-use)
assert_empty "gap2-stale: stale flag cleared after read" "$(read_st "cg2stale" "just_compacted")"
teardown_test

# -------------------------------------------------------
# Gap 6: empty compact_summary handled gracefully
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg6" "coding"
sim_pre_compact "cg6"
sim_post_compact "cg6" "auto" ""
handoff="$(cat "${TEST_HOME}/.claude/quality-pack/state/cg6/compact_handoff.md" 2>/dev/null || echo "")"
assert_contains "gap6: empty summary gets fallback literal" "compact summary not provided by runtime" "${handoff}"
teardown_test

# -------------------------------------------------------
# ulw-off cleans up compact continuity state
# Regression for excellence-reviewer #1: `review_pending_at_compact` and
# related flags must not leak across a `/ulw-off` deactivation.
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "culw" "coding"
sim_edit "culw" "/src/leak.ts"
sim_pre_agent_dispatch "culw" "quality-researcher" "leaked dispatch"
sim_pre_compact "culw"
# Confirm pre-compact did set the flags we want to clear
assert_eq "ulw-off: review flag set before deactivate" "1" "$(read_st "culw" "review_pending_at_compact")"
pending_before="${TEST_HOME}/.claude/quality-pack/state/culw/pending_agents.jsonl"
[[ -f "${pending_before}" ]] && pass=$((pass + 1)) || { printf '  FAIL: ulw-off: pending file should exist before deactivate\n' >&2; fail=$((fail + 1)); }
# Run deactivation
run_hook "${HOOK_DIR}/ulw-deactivate.sh" '{}' >/dev/null
# All the flags should be cleared
assert_empty "ulw-off: workflow_mode cleared" "$(read_st "culw" "workflow_mode")"
assert_empty "ulw-off: review_pending_at_compact cleared" "$(read_st "culw" "review_pending_at_compact")"
assert_empty "ulw-off: just_compacted cleared" "$(read_st "culw" "just_compacted")"
assert_empty "ulw-off: compact_race_count cleared" "$(read_st "culw" "compact_race_count")"
# pending_agents.jsonl should be deleted
if [[ -f "${pending_before}" ]]; then
  printf '  FAIL: ulw-off: pending_agents.jsonl should have been deleted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# -------------------------------------------------------
# Gap 7: back-to-back compactions archive prior snapshot
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg7" "coding"
sim_pre_compact "cg7"
# Touch the prior snapshot to ensure its mtime is at or before "now", then
# trigger a second pre-compact without a SessionStart compact consume step.
sleep 1 2>/dev/null || true
sim_pre_compact "cg7"
# An archive file should exist
archives="$(find "${TEST_HOME}/.claude/quality-pack/state/cg7" -maxdepth 1 -name 'precompact_snapshot.*.md' 2>/dev/null)"
if [[ -n "${archives}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap7: archive file should exist after back-to-back compact\n' >&2
  fail=$((fail + 1))
fi
race_count="$(read_st "cg7" "compact_race_count")"
if [[ "${race_count}" -ge "1" ]] 2>/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap7: compact_race_count should be >= 1 (got %s)\n' "${race_count}" >&2
  fail=$((fail + 1))
fi
teardown_test


printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
