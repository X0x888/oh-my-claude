#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
pass=0
fail=0

# --- Harness ---

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
  # v1.43+: agent-first gate is opt-in (default off). Existing e2e cases
  # (Sequence K3, Gap 8t, Gap 8u, and the auto-satisfy helper at line ~76)
  # were authored when the gate was mandatory; preserve their semantics
  # by defaulting it ON for e2e runs. Tests exercising the new
  # default-off behavior live in test-pretool-intent-guard.sh
  # (T_aff_off_*) where the unit-test isolation is tighter.
  export OMC_AGENT_FIRST_GATE=on
  # v1.44 test-isolation fix: cd to TEST_HOME so load_conf's project-
  # conf walk-up does NOT reach the real user conf and apply non-security
  # flags (lazy_session_start, etc.) as "project". Without this cd, the
  # whole e2e sequence inherits the user's conf as a project layer.
  cd "${TEST_HOME}"
  # This suite owns the pre-existing hook interactions below, not the
  # Definition-of-Excellent lifecycle. Keep that orthogonal gate disabled so
  # a newly armed contract cannot mask the behavior each sequence is proving;
  # tests/test-definition-of-excellent-e2e.sh owns the default/adaptive path.
  export OMC_DEFINITION_OF_EXCELLENT=off
}

teardown_test() {
  cd "${ORIG_PWD:-${REPO_ROOT}}" 2>/dev/null || true
  export HOME="${ORIG_HOME}"
  unset OMC_AGENT_FIRST_GATE
  unset OMC_DEFINITION_OF_EXCELLENT
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

test_token_digest() {
  local token="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${token}" \
      | shasum -a 256 2>/dev/null \
      | awk '{print substr($1,1,24)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${token}" \
      | sha256sum 2>/dev/null \
      | awk '{print substr($1,1,24)}'
  else
    printf '%s' "${token}" \
      | cksum 2>/dev/null \
      | awk '{printf "%08x-%s", $1, $2}'
  fi
}

set_agent_first_satisfied() {
  local sid="$1" agent="${2:-quality-planner}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq --arg agent "${agent}" --arg ts "$(date +%s)" \
    '. + {agent_first_specialist_ts:$ts, agent_first_specialist_type:$agent}' \
    "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
    && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
}

# --- Hook simulators ---

sim_edit() {
  local sid="$1"
  local fp="${2:-/src/foo.ts}"
  # Synthetic edits represent a tool call that already passed PreToolUse.
  # Real /ulw execution now requires a shaping specialist before mutation,
  # so seed that floor here to keep unrelated stop-gate tests focused.
  if is_intent="$(read_st "${sid}" "task_intent")" && [[ "${is_intent}" == "execution" || "${is_intent}" == "continuation" ]]; then
    if [[ -z "$(read_st "${sid}" "agent_first_specialist_ts")" ]]; then
      set_agent_first_satisfied "${sid}"
    fi
  fi
  run_hook "${HOOK_DIR}/mark-edit.sh" \
    "$(jq -nc --arg s "${sid}" --arg f "${fp}" '{session_id:$s,tool_input:{file_path:$f}}')"
}

sim_verify() {
  local sid="$1"
  local cmd="${2:-npm test}"
  local res="${3:-}"
  local payload
  payload="$(jq -nc --arg s "${sid}" --arg c "${cmd}" --arg r "${res}" \
    --arg id "${sid}-verify" \
    '{session_id:$s,tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c},tool_response:$r}')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload}"
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "${payload}"
}

sim_mcp_verify() {
  local sid="$1"
  local tool_name="${2:-mcp__plugin_playwright_playwright__browser_snapshot}"
  local res="${3:-}"
  local payload
  payload="$(jq -nc --arg s "${sid}" --arg t "${tool_name}" --arg r "${res}" \
    --arg id "${sid}-mcp-verify" \
    '{session_id:$s,tool_name:$t,tool_use_id:$id,tool_input:{},tool_response:$r}')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload}"
  run_hook "${HOOK_DIR}/record-verification.sh" \
    "${payload}"
}

sim_review() {
  local sid="$1"
  local msg="${2:-Summary: The code looks good. No issues found.}"
  run_hook "${HOOK_DIR}/record-reviewer.sh" \
    "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
      '{session_id:$s,last_assistant_message:$m}')"
}

sim_release_review() {
  local sid="$1"
  local msg="${2:-Release review is clean.
VERDICT: CLEAN}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" release 2>/dev/null || true
}

sim_excellence_review() {
  local sid="$1"
  local msg="${2:-Verdict: The deliverable is complete and excellent.
VERDICT: SHIP}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | bash "${HOOK_DIR}/record-reviewer.sh" excellence 2>/dev/null || true
}

sim_planner() {
  local sid="$1"
  local agent_type="${2:-quality-planner}"
  local msg="${3:-Plan covers all branches.

VERDICT: PLAN_READY}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" --arg a "${agent_type}" \
    '{session_id:$s,last_assistant_message:$m,agent_type:$a}')" \
    | bash "${HOOK_DIR}/record-plan.sh" 2>/dev/null || true
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
  sim_edit "${sid}" "${fp}"
}

sim_edit_ui() {
  local sid="$1"
  local fp="${2:-/src/components/Button.tsx}"
  sim_edit "${sid}" "${fp}"
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
    | env OMC_GUARD_EXHAUSTION_MODE="${mode}" OMC_NO_DEFER_MODE="${OMC_NO_DEFER_MODE:-on}" \
      bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true
}

structured_closeout() {
  local sid="$1"
  local changed_text="${2:-Updated the requested files and behavior.}"
  local risks_text="${3:-}"
  local next_text="${4:-Done.}"
  local verify_cmd verify_line

  verify_cmd="$(read_st "${sid}" "last_verify_cmd")"
  if [[ -n "${verify_cmd}" ]]; then
    verify_line="\`${verify_cmd}\` completed cleanly."
  elif [[ -n "$(read_st "${sid}" "last_doc_review_ts")" ]]; then
    verify_line="\`editor-critic\` returned \`CLEAN\`; no automated verification ran."
  elif [[ -n "$(read_st "${sid}" "last_review_ts")" ]]; then
    verify_line="\`quality-reviewer\` returned \`CLEAN\`."
  else
    verify_line="No automated verification ran."
  fi

  printf '**Changed.** %s\n\n**Verification.** %s\n' "${changed_text}" "${verify_line}"
  if [[ -n "${risks_text}" ]]; then
    printf '\n**Risks.** %s\n' "${risks_text}"
  fi
  printf '\n**Objective coverage.** Covered the complete original objective; no requested work was omitted.\n'
  printf '\n**Next.** %s' "${next_text}"
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
assert_eq "mark-edit: missing edit revision starts at one" \
  "1" "$(read_st "s1" "edit_revision")"
assert_eq "mark-edit: missing code counter starts at one" \
  "1" "$(read_st "s1" "code_edit_count")"

# Verify edited_files.log was written
edited_log="${TEST_HOME}/.claude/quality-pack/state/s1/edited_files.log"
if [[ -f "${edited_log}" ]] && grep -q "/src/auth.ts" "${edited_log}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: edited_files.log should contain /src/auth.ts\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# Numeric session fields are untrusted strings. A poisoned revision/counter
# must neither execute through Bash arithmetic nor wrap/reset to a falsely
# fresh generation. mark-edit saturates these causal clocks conservatively.
setup_test
init_session "s1numeric"
numeric_marker="${TEST_HOME}/mark-edit-arithmetic-executed"
jq --arg poison "x[\$(touch ${numeric_marker})]" '
  .edit_revision=$poison
  | .prompt_revision="08"
  | .code_edit_count=$poison
' "${TEST_HOME}/.claude/quality-pack/state/s1numeric/session_state.json" \
  >"${TEST_HOME}/.claude/quality-pack/state/s1numeric/session_state.json.tmp"
mv "${TEST_HOME}/.claude/quality-pack/state/s1numeric/session_state.json.tmp" \
  "${TEST_HOME}/.claude/quality-pack/state/s1numeric/session_state.json"
sim_edit "s1numeric" "/src/numeric.ts"
assert_eq "mark-edit: poisoned revision becomes a fail-closed sentinel" \
  "overflow" "$(read_st "s1numeric" "edit_revision")"
assert_eq "mark-edit: poisoned unique counter saturates conservatively" \
  "999999999999999999" "$(read_st "s1numeric" "code_edit_count")"
assert_eq "mark-edit: malformed prompt revision is never normalized into authority" \
  "" "$(read_st "s1numeric" "last_edit_prompt_revision")"
assert_eq "mark-edit: poisoned arithmetic did not execute" "0" \
  "$([[ -e "${numeric_marker}" ]] && printf 1 || printf 0)"
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

# Decoded NUL bytes may not join adversarial output fragments into a passing
# count/outcome signal. The clean start remains available for an authentic
# redelivery; the poisoned completion publishes and consumes nothing.
setup_test
init_session "s2-nul"
nul_verify_start="$(jq -nc '{
  session_id:"s2-nul",tool_name:"Bash",tool_use_id:"s2-nul-verify",
  tool_input:{command:"pytest -q"},tool_response:""
}')"
nul_verify_result="$(jq -nc '{
  session_id:"s2-nul",tool_name:"Bash",tool_use_id:"s2-nul-verify",
  tool_input:{command:"pytest -q"},
  tool_response:("1" + "\u0000" + " passed")
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${nul_verify_start}"
run_hook "${HOOK_DIR}/record-verification.sh" "${nul_verify_result}"
assert_empty "verify(NUL output): no pass outcome is minted" \
  "$(read_st "s2-nul" "last_verify_outcome")"
assert_eq "verify(NUL output): no receipt is minted" "0" \
  "$([[ -e "${TEST_HOME}/.claude/quality-pack/state/s2-nul/verification_receipts.jsonl" ]] \
    && wc -l \
      <"${TEST_HOME}/.claude/quality-pack/state/s2-nul/verification_receipts.jsonl" \
      | tr -d '[:space:]' || printf 0)"
assert_eq "verify(NUL output): clean causal start is not consumed" "1" \
  "$(find "${TEST_HOME}/.claude/quality-pack/state/s2-nul/.verification-starts" \
      -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d '[:space:]')"
teardown_test

# Persisted one-shot start snapshots must validate every causal coordinate
# before jq raw output crosses into Bash. Each mutation below would normalize
# to the authentic start under the old post-projection checks.
for snapshot_poison in tool_use_id tool_name code_revision input_digest; do
  setup_test
  snapshot_sid="s2-start-${snapshot_poison}"
  init_session "${snapshot_sid}"
  snapshot_payload="$(jq -nc --arg sid "${snapshot_sid}" \
    --arg id "${snapshot_sid}-verify" '{
      session_id:$sid,tool_name:"Bash",tool_use_id:$id,
      tool_input:{command:"pytest -q"},tool_response:"2 passed"
    }')"
  run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${snapshot_payload}"
  snapshot_file="$(find \
    "${TEST_HOME}/.claude/quality-pack/state/${snapshot_sid}/.verification-starts" \
    -maxdepth 1 -type f -name '*.json' -print -quit)"
  case "${snapshot_poison}" in
    tool_use_id)
      jq '.tool_use_id += "\u0000"' "${snapshot_file}" \
        >"${snapshot_file}.tmp"
      ;;
    tool_name)
      jq '.tool_name += "\u0000"' "${snapshot_file}" \
        >"${snapshot_file}.tmp"
      ;;
    code_revision)
      jq '.code_revision = ((.code_revision | tostring) + "\u0000")' \
        "${snapshot_file}" >"${snapshot_file}.tmp"
      ;;
    input_digest)
      jq '.input_digest += "\u0000"' "${snapshot_file}" \
        >"${snapshot_file}.tmp"
      ;;
  esac
  mv "${snapshot_file}.tmp" "${snapshot_file}"
  run_hook "${HOOK_DIR}/record-verification.sh" "${snapshot_payload}"
  assert_empty "verify(start ${snapshot_poison}): no outcome is minted" \
    "$(read_st "${snapshot_sid}" "last_verify_outcome")"
  assert_eq "verify(start ${snapshot_poison}): no receipt is minted" "0" \
    "$([[ -e "${TEST_HOME}/.claude/quality-pack/state/${snapshot_sid}/verification_receipts.jsonl" ]] \
      && wc -l \
        <"${TEST_HOME}/.claude/quality-pack/state/${snapshot_sid}/verification_receipts.jsonl" \
        | tr -d '[:space:]' || printf 0)"
  teardown_test
done

# User-authorized wrapper patterns use canonical config precedence. A later
# malformed duplicate cannot erase the last valid row, and project config
# cannot broaden proof admission with a catch-all.
setup_test
{
  printf 'custom_verify_patterns=trusted-wrapper\n'
  printf 'custom_verify_patterns=[\n'
} > "${TEST_HOME}/.claude/oh-my-claude.conf"
mkdir -p "${TEST_HOME}/work/.claude"
printf 'custom_verify_patterns=.*\n' \
  > "${TEST_HOME}/work/.claude/oh-my-claude.conf"
cd "${TEST_HOME}/work"
init_session "s2-custom"
sim_verify "s2-custom" "trusted-wrapper --ci" "Checks: 2 passed"
assert_eq "verify(custom wrapper): trusted user matcher records proof" \
  "passed" "$(read_st "s2-custom" "last_verify_outcome")"
init_session "s2-project-catchall"
sim_verify "s2-project-catchall" "plain-command --ci" "command succeeded"
assert_empty "verify(custom wrapper): project catch-all is ignored" \
  "$(read_st "s2-project-catchall" "last_verify_ts")"
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
# Test 3a: record-verification.sh honors structured non-zero exit code
# -------------------------------------------------------
setup_test
init_session "s3a"
payload_s3a="$(jq -nc --arg s "s3a" --arg c "npm test" \
  '{session_id:$s,tool_name:"Bash",tool_use_id:"s3a-verify",tool_input:{command:$c},tool_response:{exit_code:1,output:"Tests: 10 passed"}}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${payload_s3a}"
run_hook "${HOOK_DIR}/record-verification.sh" "${payload_s3a}"

assert_eq "verify(exit_code): outcome is failed" "failed" "$(read_st "s3a" "last_verify_outcome")"
teardown_test


# -------------------------------------------------------
# Test 4: record-verification.sh — no tool_response defaults to passed
# -------------------------------------------------------
setup_test
init_session "s3b"
start_s3b="$(jq -nc '{
  session_id:"s3b",tool_name:"Bash",tool_use_id:"s3b-failed-hook",
  tool_input:{command:"npm test"}}')"
failure_s3b="$(jq -c '. + {
  hook_event_name:"PostToolUseFailure",error:"runner process terminated"}' \
  <<<"${start_s3b}")"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${start_s3b}"
run_hook "${HOOK_DIR}/record-verification.sh" "${failure_s3b}"
assert_eq "verify(failure hook): sparse Bash envelope is failed" "failed" \
  "$(read_st "s3b" "last_verify_outcome")"
teardown_test

setup_test
init_session "s3c"
start_s3c="$(jq -nc '{
  session_id:"s3c",
  tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
  tool_use_id:"s3c-failed-hook",
  tool_input:{url:"https://app.test/checkout",selector:"#checkout"}}')"
failure_s3c="$(jq -c '. + {
  hook_event_name:"PostToolUseFailure",error:"browser connection closed"}' \
  <<<"${start_s3c}")"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${start_s3c}"
run_hook "${HOOK_DIR}/record-verification.sh" "${failure_s3c}"
assert_eq "verify(failure hook): sparse MCP envelope is failed" "failed" \
  "$(read_st "s3c" "last_verify_outcome")"
teardown_test

setup_test
init_session "s3d"
printf 'authoritative source\n' > "${TEST_HOME}/source.txt"
start_s3d="$(jq -nc --arg path "${TEST_HOME}/source.txt" --arg cwd "${TEST_HOME}" '{
  session_id:"s3d",tool_name:"Read",tool_use_id:"s3d-failed-hook",cwd:$cwd,
  tool_input:{file_path:$path}}')"
failure_s3d="$(jq -c '. + {
  hook_event_name:"PostToolUseFailure",error:"source read was interrupted"}' \
  <<<"${start_s3d}")"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${start_s3d}"
run_hook "${HOOK_DIR}/record-verification.sh" "${failure_s3d}"
receipt_s3d="${TEST_HOME}/.claude/quality-pack/state/s3d/verification_receipts.jsonl"
assert_eq "verify(failure hook): source failure does not overwrite executable-test state" "" \
  "$(read_st "s3d" "last_verify_outcome")"
assert_eq "verify(failure hook): source failure mints a negative receipt" "failed" \
  "$(jq -sr '.[-1].outcome // empty' "${receipt_s3d}")"
assert_eq "verify(failure hook): source receipt retains evidence kind" "source" \
  "$(jq -sr '.[-1].evidence_kind // empty' "${receipt_s3d}")"
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
# Test 4a: verification is credited to its dispatch revision, not completion
# -------------------------------------------------------
setup_test
init_session "s4a"
sim_edit "s4a" "/src/before-test.ts"
timing_off_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-timing-off-verify",
  tool_input:{command:"npm test"},tool_response:"Tests: 10 passed, 0 failed"
}')"
printf '%s' "${timing_off_payload}" \
  | env OMC_TIME_TRACKING=off bash "${HOOK_DIR}/record-tool-start-revision.sh" 2>/dev/null || true
run_hook "${HOOK_DIR}/record-verification.sh" "${timing_off_payload}"
assert_eq "verify(causal): ordinary pass records start revision" "1" \
  "$(read_st "s4a" "last_verify_code_revision")"
assert_eq "verify(causal): timing opt-out does not disable start capture" "npm test" \
  "$(read_st "s4a" "last_verify_cmd")"

stale_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-stale-verify",
  tool_input:{command:"pytest -q"},tool_response:"12 passed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${stale_payload}"
# A peer edit lands while the test is in flight.
sim_edit "s4a" "/src/during-test.ts"
run_hook "${HOOK_DIR}/record-verification.sh" "${stale_payload}"

assert_eq "verify(causal): stale result preserves prior verified revision" "1" \
  "$(read_st "s4a" "last_verify_code_revision")"
assert_eq "verify(causal): stale result preserves prior command" "npm test" \
  "$(read_st "s4a" "last_verify_cmd")"
assert_eq "verify(causal): rejection reason is revision change" "code_revision_changed" \
  "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): diagnostic records dispatch revision" "1" \
  "$(read_st "s4a" "last_stale_verify_start_code_revision")"
assert_eq "verify(causal): diagnostic records completion revision" "2" \
  "$(read_st "s4a" "last_stale_verify_current_code_revision")"

# A fresh invocation after the edit sees revision 2 and may advance evidence.
sim_verify "s4a" "pytest -q" "12 passed"
assert_eq "verify(causal): post-edit rerun is accepted" "2" \
  "$(read_st "s4a" "last_verify_code_revision")"
assert_eq "verify(causal): post-edit rerun updates command" "pytest -q" \
  "$(read_st "s4a" "last_verify_cmd")"

# A matching tool-use ID/name is not enough: completion arguments must be
# byte-equivalent after canonical JSON normalization to those seen at start.
input_start_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-input-bound",
  tool_input:{command:"npm test",timeout:120000},
  tool_response:"Tests: 99 passed, 0 failed"
}')"
input_changed_payload="$(jq -c '
  .tool_input.command="npm test -- --runDifferentSuite"
' <<<"${input_start_payload}")"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${input_start_payload}"
run_hook "${HOOK_DIR}/record-verification.sh" "${input_changed_payload}"
assert_eq "verify(causal): changed completion input fails closed" "tool_input_changed" \
  "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): changed completion input preserves accepted command" "pytest -q" \
  "$(read_st "s4a" "last_verify_cmd")"

# A completion from the prior objective is stale even when Definition mode is
# disabled and no code revision changed between the two prompts.
cycle_state="${TEST_HOME}/.claude/quality-pack/state/s4a/session_state.json"
jq '.review_cycle_id="20"' "${cycle_state}" >"${cycle_state}.tmp" \
  && mv "${cycle_state}.tmp" "${cycle_state}"
cycle_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-cycle-bound",
  tool_input:{command:"npm test -- --runCycleSuite"},
  tool_response:"Tests: 99 passed, 0 failed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${cycle_payload}"
jq '.review_cycle_id="21"' "${cycle_state}" >"${cycle_state}.tmp" \
  && mv "${cycle_state}.tmp" "${cycle_state}"
run_hook "${HOOK_DIR}/record-verification.sh" "${cycle_payload}"
assert_eq "verify(causal): prior-objective completion fails closed" \
  "review_cycle_changed" "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): prior-objective completion preserves accepted command" \
  "pytest -q" "$(read_st "s4a" "last_verify_cmd")"

# The causal snapshot itself must remain a regular file beneath a regular
# directory. Replacing it with a symlink cannot smuggle start authority.
unsafe_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-unsafe-start",
  tool_input:{command:"npm test -- --runInBand"},
  tool_response:"Tests: 99 passed, 0 failed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${unsafe_payload}"
unsafe_sidecar="$(find \
  "${TEST_HOME}/.claude/quality-pack/state/s4a/.verification-starts" \
  -type f -name '*.json' -print -quit)"
cp "${unsafe_sidecar}" "${TEST_HOME}/unsafe-verification-start.json"
rm -f "${unsafe_sidecar}"
ln -s "${TEST_HOME}/unsafe-verification-start.json" "${unsafe_sidecar}"
run_hook "${HOOK_DIR}/record-verification.sh" "${unsafe_payload}"
assert_eq "verify(causal): symlink start snapshot fails closed" "invalid_start_snapshot" \
  "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): unsafe start preserves accepted command" "pytest -q" \
  "$(read_st "s4a" "last_verify_cmd")"

# Replaying a completion cannot reuse consumed dispatch evidence.
stale_count_marker="${TEST_HOME}/stale-count-arithmetic-executed"
jq --arg poison "x[\$(touch ${stale_count_marker})]" \
  '.stale_verify_count=$poison' "${cycle_state}" >"${cycle_state}.tmp" \
  && mv "${cycle_state}.tmp" "${cycle_state}"
run_hook "${HOOK_DIR}/record-verification.sh" "${stale_payload}"
assert_eq "verify(causal): missing snapshot fails closed" "missing_start_snapshot" \
  "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): replay does not advance accepted revision" "2" \
  "$(read_st "s4a" "last_verify_code_revision")"
assert_eq "verify(causal): poisoned stale counter saturates conservatively" \
  "999999999999999999" "$(read_st "s4a" "stale_verify_count")"
assert_eq "verify(causal): poisoned stale counter did not execute" "0" \
  "$([[ -e "${stale_count_marker}" ]] && printf 1 || printf 0)"

# The live causal clock and the consumed snapshot are both untrusted state.
# Malformed numeric text must reject the result before JSON-number publication
# and must never be evaluated as a Bash arithmetic expression.
numeric_verify_payload="$(jq -nc '{
  session_id:"s4a",tool_name:"Bash",tool_use_id:"s4a-numeric-state",
  tool_input:{command:"npm test -- --runNumericState"},
  tool_response:"Tests: 99 passed, 0 failed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${numeric_verify_payload}"
numeric_verify_marker="${TEST_HOME}/verify-current-arithmetic-executed"
numeric_verify_poison="x[\$(touch ${numeric_verify_marker})]"
jq --arg poison "${numeric_verify_poison}" \
  '.last_code_edit_revision=$poison' "${cycle_state}" >"${cycle_state}.tmp" \
  && mv "${cycle_state}.tmp" "${cycle_state}"
run_hook "${HOOK_DIR}/record-verification.sh" "${numeric_verify_payload}"
assert_eq "verify(causal): malformed live revision fails closed" \
  "invalid_current_numeric_state" "$(read_st "s4a" "last_stale_verify_reason")"
assert_eq "verify(causal): malformed live revision preserves accepted command" \
  "pytest -q" "$(read_st "s4a" "last_verify_cmd")"
assert_eq "verify(causal): malformed live revision did not execute" "0" \
  "$([[ -e "${numeric_verify_marker}" ]] && printf 1 || printf 0)"
teardown_test


# -------------------------------------------------------
# Test 4b: verification start authority is one-shot and path-safe
# -------------------------------------------------------
setup_test
init_session "s4b"
one_shot_payload="$(jq -nc '{
  session_id:"s4b",tool_name:"Bash",tool_use_id:"s4b-one-shot",
  tool_input:{command:"npm test -- --runReplayOnce"},
  tool_response:"Tests: 7 passed, 0 failed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${one_shot_payload}"
run_hook "${HOOK_DIR}/record-verification.sh" "${one_shot_payload}"
one_shot_receipts="${TEST_HOME}/.claude/quality-pack/state/s4b/verification_receipts.jsonl"
assert_eq "verify(authority): first completion is accepted" \
  "npm test -- --runReplayOnce" "$(read_st "s4b" "last_verify_cmd")"
assert_eq "verify(authority): first completion mints exactly one receipt" "1" \
  "$(jq -s '[.[] | select(.tool_use_id == "s4b-one-shot")] | length' \
    "${one_shot_receipts}" 2>/dev/null || printf '0')"

# The public sidecar pathname was atomically consumed before publication. An
# identical duplicate PostTool envelope has no authority and cannot append the
# same evidence a second time.
run_hook "${HOOK_DIR}/record-verification.sh" "${one_shot_payload}"
assert_eq "verify(authority): successful completion replay fails closed" \
  "missing_start_snapshot" "$(read_st "s4b" "last_stale_verify_reason")"
assert_eq "verify(authority): successful completion replay mints no receipt" "1" \
  "$(jq -s '[.[] | select(.tool_use_id == "s4b-one-shot")] | length' \
    "${one_shot_receipts}" 2>/dev/null || printf '0')"
assert_eq "verify(authority): consumed private nodes are removed" "0" \
  "$(find "${TEST_HOME}/.claude/quality-pack/state/s4b/.verification-starts" \
    -mindepth 1 -name '.verification-consumed.*' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"

# A failed atomic rename is a hard rejection: no result state or receipt is
# published from a snapshot that remains at its public lookup pathname.
consume_fail_payload="$(jq -nc '{
  session_id:"s4b",tool_name:"Bash",tool_use_id:"s4b-consume-fail",
  tool_input:{command:"pytest -q tests/consume_fail.py"},
  tool_response:"1 passed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${consume_fail_payload}"
consume_fail_sidecar="$(find \
  "${TEST_HOME}/.claude/quality-pack/state/s4b/.verification-starts" \
  -maxdepth 1 -type f -name '*.json' -print -quit)"
printf '%s' "${consume_fail_payload}" \
  | env OMC_TEST_VERIFICATION_CONSUME_RENAME_FAIL=1 \
    bash "${HOOK_DIR}/record-verification.sh" 2>/dev/null || true
assert_eq "verify(authority): consume rename failure is explicit" \
  "start_snapshot_consume_failed" \
  "$(read_st "s4b" "last_stale_verify_reason")"
assert_eq "verify(authority): consume failure preserves accepted result" \
  "npm test -- --runReplayOnce" "$(read_st "s4b" "last_verify_cmd")"
assert_eq "verify(authority): consume failure publishes no receipt" "0" \
  "$(jq -s '[.[] | select(.tool_use_id == "s4b-consume-fail")] | length' \
    "${one_shot_receipts}" 2>/dev/null || printf '0')"
if [[ -n "${consume_fail_sidecar}" && -f "${consume_fail_sidecar}" \
    && ! -L "${consume_fail_sidecar}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: verify(authority): failed rename must not parse or remove public authority\n' >&2
  fail=$((fail + 1))
fi
teardown_test

setup_test
init_session "s4c"
foreign_starts="${TEST_HOME}/foreign-verification-starts"
starts_boundary="${TEST_HOME}/.claude/quality-pack/state/s4c/.verification-starts"
mkdir -p "${foreign_starts}"
printf 'foreign sentinel\n' >"${foreign_starts}/sentinel"
ln -s "${foreign_starts}" "${starts_boundary}"
foreign_payload="$(jq -nc '{
  session_id:"s4c",tool_name:"Bash",tool_use_id:"s4c-foreign-dir",
  tool_input:{command:"npm test"},tool_response:"Tests: 3 passed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${foreign_payload}"
assert_eq "verify(authority): foreign symlink start directory stays a symlink" \
  "yes" "$([[ -L "${starts_boundary}" ]] && printf 'yes' || printf 'no')"
assert_eq "verify(authority): foreign symlink directory receives no snapshot" "1" \
  "$(find "${foreign_starts}" -mindepth 1 -maxdepth 1 \
    | wc -l | tr -d '[:space:]')"
assert_eq "verify(authority): rejected foreign start creates no result" "" \
  "$(read_st "s4c" "last_verify_cmd")"

rm -f "${starts_boundary}"
printf 'not a directory\n' >"${starts_boundary}"
non_dir_before="$(cksum "${starts_boundary}")"
non_dir_payload="$(jq -nc '{
  session_id:"s4c",tool_name:"Bash",tool_use_id:"s4c-nondirectory",
  tool_input:{command:"pytest -q"},tool_response:"2 passed"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${non_dir_payload}"
assert_eq "verify(authority): non-directory start boundary is unchanged" \
  "${non_dir_before}" "$(cksum "${starts_boundary}")"
assert_eq "verify(authority): non-directory boundary creates no result" "" \
  "$(read_st "s4c" "last_verify_cmd")"
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
# Test 7a: release-reviewer records release-specific state only
# -------------------------------------------------------
setup_test
init_session "s7a"
sim_edit "s7a" "/src/release.ts"
sim_release_review "s7a" "Release diff is clean.
VERDICT: CLEAN"

assert_not_empty "release-review: last_release_review_ts set" "$(read_st "s7a" "last_release_review_ts")"
assert_eq "release-review: no findings" "false" "$(read_st "s7a" "release_review_had_findings")"
assert_empty "release-review: does not set normal last_review_ts" "$(read_st "s7a" "last_review_ts")"
assert_empty "release-review: does not set review_had_findings" "$(read_st "s7a" "review_had_findings")"
assert_empty "release-review: does not tick bug_hunt" "$(read_st "s7a" "dim_bug_hunt_ts")"
assert_empty "release-review: does not tick code_quality" "$(read_st "s7a" "dim_code_quality_ts")"
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
output="$(sim_stop "sa" "$(structured_closeout "sa" "Updated /src/foo.ts for the requested fix.")")"

assert_empty "seq-A: stop allowed (no output)" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence A0: Clean work still blocks without an audit-ready closeout
# -------------------------------------------------------
setup_test
init_session "sa0"
sim_edit "sa0"
sim_verify "sa0" "npm test" "Tests: 3 passed, 0 failed"
sim_review "sa0" "Summary: Code looks clean. No issues."
output="$(sim_stop "sa0" "Here is the completed work.")"

assert_contains "seq-A0: final closure blocks placeholder wrap" '"decision":"block"' "${output}"
assert_contains "seq-A0: final closure names gate" "Final-closure gate" "${output}"
assert_contains "seq-A0: final closure asks for Changed" "Changed" "${output}"
assert_contains "seq-A0: final closure asks for Verification" "Verification" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence A1: Deferred work requires a Risks section in the closeout
# -------------------------------------------------------
setup_test
init_session "sa1"
sim_edit "sa1"
sim_verify "sa1" "npm test" "Tests: 4 passed, 0 failed"
sim_review "sa1" "Summary: Code looks clean. No issues."
jq -nc --arg id "DS-001" --argjson ts "$(date +%s)" \
  '{id:$id,severity:"medium",summary:"deferred follow-up",status:"deferred",reason:"awaiting upstream schema change",ts:$ts}' \
  > "${TEST_HOME}/.claude/quality-pack/state/sa1/discovered_scope.jsonl"
output="$(sim_stop "sa1" "$(structured_closeout "sa1" "Updated /src/foo.ts for the requested fix.")")"
assert_contains "seq-A1: deferred work without Risks blocks" '"decision":"block"' "${output}"
assert_contains "seq-A1: deferred work names Risks" "Risks" "${output}"

output="$(sim_stop "sa1" "$(structured_closeout "sa1" "Updated /src/foo.ts for the requested fix." "Deferred adjacent schema cleanup is awaiting upstream schema change.")")"
assert_empty "seq-A1: Risks section clears final closure gate" "${output}"
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
# After second edit, both review and verify are stale. The message uses the
# `validat` stem ("to validate" when project_test_cmd is detected on demand;
# "validation" otherwise) — assert on the stem so the test tracks both
# phrasings without requiring a specific copy.
assert_contains "seq-D: needs validation" "validat" "${output}"
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

# Fourth stop: exhausted, but default no_defer_mode keeps serious missing
# review/verification blocking after the cap.
out4="$(sim_stop "se")"
assert_contains "seq-E: fourth stop exhausted scorecard" "QUALITY SCORECARD" "${out4}"
assert_contains "seq-E: fourth stop remains blocked under no-defer" '"decision":"block"' "${out4}"
assert_contains "seq-E: fourth stop names block mode" "BLOCK MODE" "${out4}"
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
# v1.40.x-newer: block message must enumerate the new failure-mode
# example phrasings ('in your next prompt' etc.) so the model sees
# why the new shapes are also caught. If someone reverts the
# stop-guard message but leaves the regex intact, the gate would
# still fire — but with stale opaque prose; this assertion catches
# that drift.
assert_contains "seq-G: block lists 'in your next prompt' example" "in your next prompt" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence G2: v1.40.x-newer mid-iteration handoff phrasing blocked
# -------------------------------------------------------
# The reported failure had the model stop a mid-wave council session
# at W6/16 with "Continue from there in your next prompt." This
# locks the regex expansion + stop-guard wiring against the literal
# reported failure phrase.
setup_test
init_session "sg2"
sim_edit "sg2"
sim_verify "sg2" "npm test" "Tests: 5 passed"
sim_review "sg2" "Summary: Looks good."
output="$(sim_stop "sg2" "Next. W7 (PortfolioPerformanceMetrics) is the highest-impact remaining wave per the user's core-feature recapitulation. Continue from there in your next prompt.")"

assert_contains "seq-G2: in-your-next-prompt handoff blocked" '"decision":"block"' "${output}"
assert_contains "seq-G2: block names the new failure shape" "in your next prompt" "${output}"
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
output="$(sim_stop "si" "$(structured_closeout "si" "Updated /src/fixed.ts and completed the remediation pass.")")"

assert_empty "seq-I: full cycle allows stop" "${output}"
teardown_test


# -------------------------------------------------------
# Prompt routing tests
# -------------------------------------------------------
printf '\nPrompt routing:\n'

ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

setup_prompt_router() {
  # prompt-intent-router.sh sources both shared libraries from HOME paths.
  # Mirror the installed layout so a new direct dependency cannot turn every
  # router assertion into a silent hook no-op under run_hook's fail-open shim.
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-constitution-authority.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/lib/quality-constitution-authority.sh"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-contract.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/lib/quality-contract.sh"
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
# Sequence K3: Fresh execution prompt clears prior agent-first evidence
# -------------------------------------------------------
setup_test
setup_prompt_router
init_session "sk3af"
set_agent_first_satisfied "sk3af" "quality-planner"
state_dir="${TEST_HOME}/.claude/quality-pack/state/sk3af"
jq '. + {first_mutation_ts:"123",first_mutation_tool:"Edit",agent_first_gate_blocks:"2"}' \
  "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
  && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
sim_prompt "sk3af" "/ulw implement a new feature in this repo" >/dev/null
assert_empty "seq-K3: fresh execution clears agent-first timestamp" "$(read_st "sk3af" "agent_first_specialist_ts")"
assert_empty "seq-K3: fresh execution clears first mutation timestamp" "$(read_st "sk3af" "first_mutation_ts")"
assert_empty "seq-K3: fresh execution clears agent-first block count" "$(read_st "sk3af" "agent_first_gate_blocks")"
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
# Sequence N: Excellence reviewer records only its role-specific timestamp
# -------------------------------------------------------
setup_test
init_session "sn"
sim_excellence_review "sn" "Complete and excellent work.
VERDICT: CLEAN"

assert_empty "seq-N: excellence does not set last_review_ts" "$(read_st "sn" "last_review_ts")"
assert_empty "seq-N: excellence does not set review_had_findings" "$(read_st "sn" "review_had_findings")"
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
# Sequence P: Same-surface file count alone does not trigger excellence
# -------------------------------------------------------
setup_test
init_session "sp"
export OMC_GATE_LEVEL=standard
sim_edit "sp" "/src/a.ts"
sim_edit "sp" "/src/b.ts"
sim_edit "sp" "/src/c.ts"
sim_verify "sp" "npm test" "Tests: 10 passed"
sim_review "sp" "Summary: Looks good. No issues."
output="$(sim_stop "sp" "$(structured_closeout "sp" "Updated three files on one implementation surface.")")"

assert_empty "seq-P: same-surface three-file task does not summon excellence" "${output}"
assert_empty "seq-P: excellence guard remains untriggered" "$(read_st "sp" "excellence_guard_triggered")"
unset OMC_GATE_LEVEL
teardown_test


# -------------------------------------------------------
# Sequence Q: No excellence gate on single-file task
# -------------------------------------------------------
setup_test
init_session "sq"
sim_edit "sq" "/src/single.ts"
sim_verify "sq" "npm test" "Tests: 5 passed"
sim_review "sq" "Summary: Code looks clean."
output="$(sim_stop "sq" "$(structured_closeout "sq" "Updated /src/single.ts for the requested change.")")"

assert_empty "seq-Q: single-file allows stop" "${output}"
teardown_test


# -------------------------------------------------------
# Sequence R: Broad-objective excellence gate fires only once
# -------------------------------------------------------
setup_test
init_session "sr"
export OMC_GATE_LEVEL=standard
jq '.review_cycle_broad_scope="1"' \
  "${TEST_HOME}/.claude/quality-pack/state/sr/session_state.json" \
  >"${TEST_HOME}/.claude/quality-pack/state/sr/session_state.json.tmp" \
  && mv "${TEST_HOME}/.claude/quality-pack/state/sr/session_state.json.tmp" \
    "${TEST_HOME}/.claude/quality-pack/state/sr/session_state.json"
sim_edit "sr" "/src/a.ts"
sim_edit "sr" "/src/b.ts"
sim_edit "sr" "/src/c.ts"
sim_verify "sr" "npm test" "Tests: 10 passed"
sim_review "sr" "Summary: No issues."

# First stop: blocks for excellence
out1="$(sim_stop "sr")"
assert_contains "seq-R: first stop blocks for excellence" '"decision":"block"' "${out1}"

# Second stop: excellence_guard_triggered=1, skips excellence check, allows through
out2="$(sim_stop "sr" "$(structured_closeout "sr" "Updated the three source files for the requested change.")")"
assert_empty "seq-R: second stop allowed (gate already triggered)" "${out2}"
unset OMC_GATE_LEVEL
teardown_test


# -------------------------------------------------------
# Sequence S: Broad-objective excellence gate is satisfied by its reviewer
# -------------------------------------------------------
setup_test
init_session "ss"
export OMC_GATE_LEVEL=standard
jq '.review_cycle_broad_scope="1"' \
  "${TEST_HOME}/.claude/quality-pack/state/ss/session_state.json" \
  >"${TEST_HOME}/.claude/quality-pack/state/ss/session_state.json.tmp" \
  && mv "${TEST_HOME}/.claude/quality-pack/state/ss/session_state.json.tmp" \
    "${TEST_HOME}/.claude/quality-pack/state/ss/session_state.json"
sim_edit "ss" "/src/a.ts"
sim_edit "ss" "/src/b.ts"
sim_edit "ss" "/src/c.ts"
sim_verify "ss" "npm test" "Tests: 10 passed"
sim_review "ss" "Summary: No issues."

# First stop: blocks for excellence
out1="$(sim_stop "ss")"
assert_contains "seq-S: blocks for excellence" '"decision":"block"' "${out1}"

# Run excellence review
sim_excellence_review "ss" "Complete and excellent.
VERDICT: CLEAN"

# Stop: should allow through (excellence review recorded)
out2="$(sim_stop "ss" "$(structured_closeout "ss" "Updated the three source files for the requested change.")")"
assert_empty "seq-S: stop allowed after excellence review" "${out2}"
assert_not_empty "seq-S: excellence_review_ts set" "$(read_st "ss" "last_excellence_review_ts")"
unset OMC_GATE_LEVEL
teardown_test


# -------------------------------------------------------
# Sequence S2: Excellence's one-shot trigger is revision-scoped
# -------------------------------------------------------
setup_test
init_session "ss2"
export OMC_GATE_LEVEL=standard
state_file="${TEST_HOME}/.claude/quality-pack/state/ss2/session_state.json"
jq '.review_cycle_broad_scope="1"' "${state_file}" >"${state_file}.tmp" \
  && mv "${state_file}.tmp" "${state_file}"
sim_edit "ss2" "/src/broad.ts"
sim_verify "ss2" "npm test" "Tests: 5 passed"
sim_review "ss2" "Clean.
VERDICT: CLEAN"
out1="$(sim_stop "ss2")"
assert_contains "seq-S2: revision 1 triggers excellence" "excellence-reviewer" "${out1}"
sim_excellence_review "ss2"

# A new edit generation invalidates completeness. Fresh generic review and
# verification do not satisfy that specialist dimension, and the prior
# one-shot block must not suppress the new generation's excellence block.
sim_edit "ss2" "/src/broad.ts"
sim_verify "ss2" "npm test" "Tests: 5 passed"
sim_review "ss2" "Clean after the second edit.
VERDICT: CLEAN"
out2="$(sim_stop "ss2")"
assert_contains "seq-S2: revision 2 re-arms excellence block" '"decision":"block"' "${out2}"
assert_contains "seq-S2: revision 2 names excellence reviewer again" "excellence-reviewer" "${out2}"
unset OMC_GATE_LEVEL
teardown_test


# -------------------------------------------------------
# Sequence T: Excellence review must not overwrite review_had_findings
# Regression test: if a standard review sets review_had_findings=false,
# a subsequent excellence review must not clobber it to true.
# -------------------------------------------------------
setup_test
init_session "st"
sim_edit "st" "/src/a.ts"
sim_edit "st" "/src/b.ts"
sim_edit "st" "/src/c.ts"
sim_verify "st" "npm test" "Tests: 5 passed"
# Standard review: clean (sets review_had_findings=false)
sim_review "st" "Summary: No issues found. Code looks clean."
assert_eq "seq-T: standard review clean" "false" "$(read_st "st" "review_had_findings")"

# Excellence review: must NOT overwrite review_had_findings
sim_excellence_review "st" "Complete and excellent.
VERDICT: CLEAN"
assert_eq "seq-T: excellence preserves review_had_findings" "false" "$(read_st "st" "review_had_findings")"
assert_not_empty "seq-T: excellence_review_ts set" "$(read_st "st" "last_excellence_review_ts")"

# Stop: should allow through (no unremediated findings)
out="$(sim_stop "st" "$(structured_closeout "st" "Updated the three source files for the requested change.")")"
assert_empty "seq-T: stop allowed" "${out}"
teardown_test


# -------------------------------------------------------
# Sequence T2: Specialist CLEAN cannot clear standard-review findings
# -------------------------------------------------------
setup_test
init_session "st2"
sim_edit "st2" "/src/a.ts"
sim_review "st2" "A defect remains.
VERDICT: FINDINGS (1)"
standard_review_ts="$(read_st "st2" "last_review_ts")"
sim_design_reviewer "st2" "Visual review is clean.
VERDICT: CLEAN"
sim_excellence_review "st2" "Completeness review is clean.
VERDICT: CLEAN"
assert_eq "seq-T2: specialist CLEAN preserves standard findings" \
  "true" "$(read_st "st2" "review_had_findings")"
assert_eq "seq-T2: specialist CLEAN preserves standard review clock" \
  "${standard_review_ts}" "$(read_st "st2" "last_review_ts")"
teardown_test


# -------------------------------------------------------
# Sequence T3: Prose findings use doc-specific state and remain enforceable
# -------------------------------------------------------
setup_test
init_session "st3"
sim_edit_doc "st3" "/docs/guide.md"
sim_editor_critic "st3" "The guide omits a required migration warning.
VERDICT: FINDINGS (1)"
assert_empty "seq-T3: prose findings do not set standard review clock" \
  "$(read_st "st3" "last_review_ts")"
assert_empty "seq-T3: prose findings do not set standard findings state" \
  "$(read_st "st3" "review_had_findings")"
assert_eq "seq-T3: prose findings are recorded on doc-specific state" \
  "true" "$(read_st "st3" "doc_review_had_findings")"
out="$(sim_stop "st3")"
assert_contains "seq-T3: prose findings still block stop" '"decision":"block"' "${out}"
sleep 1
sim_edit_doc "st3" "/docs/guide.md"
sim_editor_critic "st3" "The migration warning is now complete.
VERDICT: CLEAN"
assert_eq "seq-T3: fresh prose CLEAN clears doc-specific findings" \
  "false" "$(read_st "st3" "doc_review_had_findings")"
out2="$(sim_stop "st3" "$(structured_closeout "st3" "Updated the migration guide and cleared prose findings.")")"
assert_empty "seq-T3: doc-only stop allowed after fix + fresh prose review" "${out2}"
teardown_test


# -------------------------------------------------------
# Sequence T4: Reviewer findings do not leak across fresh objective surfaces
# -------------------------------------------------------
setup_test
setup_prompt_router
init_session "st4a"
sim_edit_doc "st4a" "/docs/old-guide.md"
sim_editor_critic "st4a" "VERDICT: FINDINGS (1)"
sim_prompt "st4a" "/ulw implement the cache key helper in src/cache.ts" >/dev/null
sim_edit "st4a" "/src/cache.ts"
sim_verify "st4a" "npm test" "Tests: 5 passed"
sim_review "st4a" "The code-only objective is clean.
VERDICT: CLEAN"
out="$(OMC_CLOSEOUT_PREFLIGHT_PROBE=1 sim_stop "st4a" "$(structured_closeout "st4a" "Implemented the cache key helper.")")"
assert_empty "seq-T4a: prior prose FINDINGS do not block fresh code-only objective" "${out}"
teardown_test

setup_test
setup_prompt_router
init_session "st4b"
sim_edit "st4b" "/src/old-cache.ts"
sim_review "st4b" "VERDICT: FINDINGS (1)"
sim_prompt "st4b" "/ulw update the cache usage guide in docs/cache.md" >/dev/null
sim_edit_doc "st4b" "/docs/cache.md"
sim_editor_critic "st4b" "The docs-only objective is clean.
VERDICT: CLEAN"
# Keep this regression focused on finding isolation: the legacy universal
# quality gate can still see the earlier code-edit clock, so provide a fresh
# validation signal rather than conflating that separate migration behavior.
sim_verify "st4b" "npm test" "Tests: 5 passed"
out="$(OMC_CLOSEOUT_PREFLIGHT_PROBE=1 sim_stop "st4b" "$(structured_closeout "st4b" "Updated the cache usage guide.")")"
assert_empty "seq-T4b: prior code FINDINGS do not block fresh docs-only objective" "${out}"
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
sim_edit_doc "sw3" "/docs/a.md"
# Doc edits route to editor-critic for review, not quality-reviewer
sim_editor_critic "sw3" "Doc updated.
VERDICT: CLEAN"
# No sim_verify — doc-only edit should not require it
output="$(sim_stop "sw3" "$(structured_closeout "sw3" "Updated /docs/a.md with the requested documentation change.")")"
assert_empty "seq-W3: doc-only edit skips verify gate" "${output}"
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
cat >"${TEST_HOME}/.claude/quality-pack/state/sw4/review_history.jsonl" <<'EOF'
{"ts":1,"objective_prompt_ts":0,"reviewer_type":"standard","agent_type":"quality-reviewer","verdict":"FINDINGS","revision":1,"findings":[{"claim":"Prior code defect"}]}
EOF
output="$(OMC_GATE_LEVEL=basic sim_stop "sw4")"
assert_contains "seq-W4: code edit after review blocks" '"decision":"block"' "${output}"
assert_contains "seq-W4: mentions quality-reviewer" "quality-reviewer" "${output}"
assert_contains "seq-W4: quality re-review receives its anchor contract" \
  "REVIEW HISTORY:" "${output}"
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
cat >"${TEST_HOME}/.claude/quality-pack/state/sw5/review_history.jsonl" <<'EOF'
{"ts":1,"objective_prompt_ts":0,"reviewer_type":"prose","agent_type":"editor-critic","verdict":"FINDINGS","revision":1,"findings":[{"claim":"Prior prose concern"}]}
EOF
output="$(OMC_GATE_LEVEL=basic sim_stop "sw5")"
# Should still block (missing doc review), but for editor-critic not quality-reviewer
assert_contains "seq-W5: doc edit after code review blocks" '"decision":"block"' "${output}"
assert_contains "seq-W5: routes to editor-critic" "editor-critic" "${output}"
assert_not_contains "seq-W5: prose reviewer is not given unsupported anchor mode" \
  "REVIEW HISTORY:" "${output}"
assert_not_contains "seq-W5: editor-critic contract remains prose-native" \
  "review_history.jsonl" "$(cat "${REPO_ROOT}/bundle/dot-claude/agents/editor-critic.md")"
teardown_test


# -------------------------------------------------------
# Adaptive review-coverage tests
# -------------------------------------------------------
printf '\nDimension tracker:\n'


# Sequence U1: Three same-surface code files need generic quality only
setup_test
init_session "su1"
sim_edit "su1" "/src/a.ts"
sim_edit "su1" "/src/b.ts"
sim_edit "su1" "/src/c.ts"
sim_verify "su1" "npm test" "Tests: 10 passed"
sim_review "su1" "Clean.
VERDICT: CLEAN"

out1="$(sim_stop "su1" "$(structured_closeout "su1" "Updated three files on one implementation surface.")")"
assert_empty "seq-U1: same-surface code route stops after generic review" "${out1}"
assert_not_empty "seq-U1: dim bug_hunt set" "$(read_st "su1" "dim_bug_hunt_ts")"
assert_empty "seq-U1: no post-edit stress_test dimension" "$(read_st "su1" "dim_stress_test_ts")"
assert_empty "seq-U1: no same-surface completeness dimension" "$(read_st "su1" "dim_completeness_ts")"
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
sim_excellence_review "su2"

# Dimension gate should now require prose (editor-critic)
out="$(sim_stop "su2")"
assert_contains "seq-U2: block for prose dimension" '"decision":"block"' "${out}"
assert_contains "seq-U2: names editor-critic" "editor-critic" "${out}"

sim_editor_critic "su2"
out2="$(sim_stop "su2" "$(structured_closeout "su2" "Updated the source files and CHANGELOG entry for the requested change.")")"
assert_empty "seq-U2: stop allowed after editor-critic" "${out2}"
teardown_test

# Sequence U3: Six-plus cross-surface files require traceability.
# A doc edit is included so the v1.34.0 R5 (code-no-docs) inferred-contract rule
# does not block on the 6-file source-only shape — real complete work at this
# scale touches docs alongside the code.
setup_test
init_session "su3"
sim_edit "su3" "/src/a.ts"
sim_edit "su3" "/src/b.ts"
sim_edit "su3" "/src/c.ts"
sim_edit "su3" "/src/d.ts"
sim_edit "su3" "/src/e.ts"
sim_edit "su3" "/src/f.ts"
sim_edit_doc "su3" "/docs/architecture.md"
sim_verify "su3" "npm test" "Tests: 10 passed"
sim_review "su3" "Clean.
VERDICT: CLEAN"
sim_excellence_review "su3"
sim_editor_critic "su3"

# Dimension gate requires traceability at 6+ files
out="$(sim_stop "su3")"
assert_contains "seq-U3: block for traceability" '"decision":"block"' "${out}"
assert_contains "seq-U3: names briefing-analyst" "briefing-analyst" "${out}"

sim_briefing_analyst "su3"
out2="$(sim_stop "su3" "$(structured_closeout "su3" "Updated the six source files and refreshed docs/architecture.md so the traceability review loop is closed.")")"
assert_empty "seq-U3: stop allowed after briefing-analyst" "${out2}"
teardown_test

# Sequence U4: Single code file is covered by the generic quality reviewer
setup_test
init_session "su4"
sim_edit "su4" "/src/single.ts"
sim_verify "su4" "npm test" "Tests: 5 passed"
sim_review "su4" "Clean.
VERDICT: CLEAN"
output="$(sim_stop "su4" "$(structured_closeout "su4" "Updated /src/single.ts for the requested change.")")"
assert_empty "seq-U4: single-file generic review is sufficient" "${output}"
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
# Generic code dimensions are ticked; now edit another code file — they should
# be invalidated
# by the timestamp-based comparison (no explicit clearing needed)
sleep 1
sim_edit "su5" "/src/d.ts"

# Stop should block — last_code_edit_ts > dim_bug_hunt_ts etc.
output="$(sim_stop "su5")"
assert_contains "seq-U5: post-edit re-blocks" '"decision":"block"' "${output}"
teardown_test

# Sequence U5B: Revision clocks catch review/verify/edit ordering inside one
# epoch second. Force the legacy timestamps equal after the real hook calls;
# only the monotonic revisions can distinguish the final edit.
setup_test
init_session "su5b"
sim_edit "su5b" "/src/same-second.ts"
sim_verify "su5b" "npm test" "Tests: 5 passed"
sim_review "su5b" "Clean.
VERDICT: CLEAN"
sim_edit "su5b" "/src/same-second.ts"
state_file="${TEST_HOME}/.claude/quality-pack/state/su5b/session_state.json"
jq '.last_edit_ts="4242"
    | .last_code_edit_ts="4242"
    | .last_review_ts="4242"
    | .last_verify_ts="4242"' \
  "${state_file}" >"${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
assert_eq "seq-U5B: reviewer saw revision 1" "1" "$(read_st "su5b" "dim_bug_hunt_revision")"
assert_eq "seq-U5B: verification saw revision 1" "1" "$(read_st "su5b" "last_verify_code_revision")"
assert_eq "seq-U5B: final same-second edit advanced revision" "2" "$(read_st "su5b" "last_code_edit_revision")"
output="$(sim_stop "su5b")"
assert_contains "seq-U5B: equal timestamps still re-block" '"decision":"block"' "${output}"
assert_contains "seq-U5B: both review and verification are stale" \
  "Both review and verification missing" "${output}"
sim_verify "su5b" "npm test" "Tests: 5 passed"
sim_review "su5b" "Clean after the final bytes.
VERDICT: CLEAN"
output2="$(sim_stop "su5b" "$(structured_closeout "su5b" "Updated the same-second test file and revalidated its final revision.")")"
assert_empty "seq-U5B: fresh revision-aware review + verify recover" "${output2}"
teardown_test

# Sequence U5C: A real edit that lands while Stop is evaluating cannot race the
# clean-release write. Pause Stop inside its current-objective path scan (after
# the opening generation snapshot), advance the edit clocks through mark-edit,
# then let evaluation continue. The final CAS must refuse the stale release.
setup_test
init_session "su5c"
OMC_INFERRED_CONTRACT=off sim_edit "su5c" "/src/before-stop.ts"
sim_verify "su5c" "npm test" "Tests: 5 passed"
sim_review "su5c" "Clean before concurrent work.
VERDICT: CLEAN"
state_file="${TEST_HOME}/.claude/quality-pack/state/su5c/session_state.json"
jq '.review_cycle_prompt_ts=.last_user_prompt_ts
    | .review_cycle_edit_log_offset="0"
    | .review_cycle_bash_event_base="0"
    | .review_cycle_ui_semantic="0"
    | .review_cycle_prose_semantic="0"
    | .review_cycle_broad_scope="0"' \
  "${state_file}" >"${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"

cas_ready="${TEST_HOME}/cas-ready"
cas_release="${TEST_HOME}/cas-release"
cas_output="${TEST_HOME}/cas-stop-output"

cas_message="$(structured_closeout "su5c" "Updated /src/before-stop.ts and validated it.")"
cas_payload="$(jq -nc --arg s "su5c" --arg m "${cas_message}" \
  '{session_id:$s,last_assistant_message:$m}')"
(
  printf '%s' "${cas_payload}" \
    | env OMC_TEST_STOP_PATH_SCAN_READY_FILE="${cas_ready}" \
      OMC_TEST_STOP_PATH_SCAN_RELEASE_FILE="${cas_release}" \
      OMC_GATE_LEVEL=basic \
      OMC_NO_DEFER_MODE=off \
      OMC_INFERRED_CONTRACT=off \
      OMC_OBJECTIVE_CONTRACT_GATE=off \
      bash "${HOOK_DIR}/stop-guard.sh" >"${cas_output}" 2>/dev/null
) &
cas_pid=$!
for _cas_wait in $(seq 1 500); do
  [[ -f "${cas_ready}" ]] && break
  kill -0 "${cas_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ -f "${cas_ready}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: seq-U5C: Stop did not reach the controlled path-scan barrier\n' >&2
  fail=$((fail + 1))
fi

OMC_INFERRED_CONTRACT=off sim_edit "su5c" "/src/during-stop.ts"
touch "${cas_release}"
wait "${cas_pid}" 2>/dev/null || true
cas_result="$(cat "${cas_output}" 2>/dev/null || true)"
assert_contains "seq-U5C: concurrent edit refuses clean release" '"decision":"block"' "${cas_result}"
assert_contains "seq-U5C: block identifies generation CAS" "Stop generation CAS" "${cas_result}"
assert_eq "seq-U5C: raced Stop does not stamp completed" \
  "" "$(read_st "su5c" "session_outcome")"
assert_eq "seq-U5C: concurrent edit advanced the code generation" \
  "2" "$(read_st "su5c" "last_code_edit_revision")"

# The retry path is ordinary: fresh evidence for generation 2 clears it.
sim_verify "su5c" "npm test" "Tests: 5 passed"
sim_review "su5c" "Clean after concurrent work settled.
VERDICT: CLEAN"
output2="$(OMC_GATE_LEVEL=basic OMC_NO_DEFER_MODE=off \
  OMC_INFERRED_CONTRACT=off OMC_OBJECTIVE_CONTRACT_GATE=off \
  sim_stop "su5c" "$(structured_closeout "su5c" "Updated both source files and revalidated the final generation.")")"
assert_empty "seq-U5C: fresh retry releases normally" "${output2}"
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
# An early completeness pass is not required yet, but lets this sequence prove
# that the later doc edit invalidates aggregate review state.
sim_excellence_review "su6"
sleep 1
# Doc edit: should only invalidate prose (which wasn't ticked yet anyway,
# so now prose becomes required)
sim_edit_doc "su6" "/docs/a.md"

output="$(sim_stop "su6")"
# Should block for prose only, not for bug_hunt/code_quality/etc
assert_contains "seq-U6: doc edit blocks for prose" '"decision":"block"' "${output}"
assert_contains "seq-U6: names editor-critic" "editor-critic" "${output}"
assert_contains "seq-U6: batches completeness owner in same block" "excellence-reviewer" "${output}"
assert_contains "seq-U6: instructs one frozen-diff batch" "one frozen diff" "${output}"
# Metis is plan-phase only and must not appear in post-edit coverage.
if [[ "${output}" == *"run \`metis\`"* ]]; then
  printf '  FAIL: seq-U6: should not require metis for post-edit coverage\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
sim_editor_critic "su6"
sim_excellence_review "su6"
output2="$(sim_stop "su6" "$(structured_closeout "su6" "Updated source and documentation with fresh cross-surface reviews.")")"
assert_empty "seq-U6: one retry suffices after batched prose + completeness reviews" "${output2}"
teardown_test

# Sequence U7: Adaptive coverage gate exhaustion at 3 blocks
setup_test
init_session "su7"
sim_edit_ui "su7" "/src/components/Card.tsx"
sim_verify "su7" "npm test" "Tests: 10 passed"
sim_review "su7" "Clean.
VERDICT: CLEAN"

# 3 coverage blocks without running the selected design reviewer
out1="$(sim_stop "su7")"
assert_contains "seq-U7: block 1" '"decision":"block"' "${out1}"
out2="$(sim_stop "su7")"
assert_contains "seq-U7: block 2" '"decision":"block"' "${out2}"
out3="$(sim_stop "su7")"
assert_contains "seq-U7: block 3" '"decision":"block"' "${out3}"
assert_contains "seq-U7: final warning" "final review-coverage block" "${out3}"

# 4th stop: legacy scorecard release remains available when strict
# no-defer autonomy is explicitly disabled.
out4="$(OMC_NO_DEFER_MODE=off sim_stop_mode "su7" "scorecard")"
assert_contains "seq-U7: scorecard release emits scorecard" "QUALITY SCORECARD" "${out4}"
assert_not_contains "seq-U7: scorecard release is not a block" '"decision":"block"' "${out4}"
exhausted_detail="$(read_st "su7" "guard_exhausted_detail")"
assert_contains "seq-U7: exhaustion recorded" "dimensions_missing" "${exhausted_detail}"
# Schema-regression net: emit_scorecard_stop_context must use systemMessage,
# never hookSpecificOutput (silently dropped on Stop). Mirrors
# tests/test-timing.sh T29 for the time-summary path. Without this
# assertion, a future revert to the dropped-schema form would leave the
# scorecard invisible to the user — same failure mode the v1.24.0 /
# v1.25.0 stop-time-summary bug exhibited.
assert_contains "seq-U7: scorecard uses systemMessage schema" '"systemMessage"' "${out4}"
assert_not_contains "seq-U7: scorecard does not use dropped hookSpecificOutput schema" "hookSpecificOutput" "${out4}"
# Real-newline assertion: bash double-quoted "\n" passes through as the
# 2-char sequence backslash+n, which jq encodes as `\\n` in JSON and
# renders as literal `\n` glyphs in the user's terminal. The fix uses
# `printf -v body '%s\n%s\n%s' "$header" "$scorecard" "$footer"` so
# joins are real newlines. The assertion checks that the JSON does not
# carry the buggy 4-char escape (`\\\\n` in shell quoting → `\\n` literal).
assert_not_contains "seq-U7: scorecard does not contain literal \\\\n glyph" '\\n' "${out4}"
teardown_test

# Sequence U7B: Review coverage gate exhaustion in block mode keeps blocking
setup_test
init_session "su7b"
sim_edit_ui "su7b" "/src/components/Card.tsx"
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

# Sequence U8: One UI file requires design_quality immediately
setup_test
init_session "su8"
sim_edit_ui "su8" "/src/components/Button.tsx"
sim_verify "su8" "npm test" "Tests: 10 passed"
sim_review "su8" "Clean.
VERDICT: CLEAN"
# quality-reviewer ticks bug_hunt + code_quality, but design_quality remains.
out1="$(sim_stop "su8")"
assert_contains "seq-U8: dimension gate blocks" '"decision":"block"' "${out1}"
assert_contains "seq-U8: design quality in missing reviews" "design quality" "${out1}"

# Run design-reviewer — should tick design_quality
sim_design_reviewer "su8"

# Now stop should succeed (all dimensions ticked)
out2="$(sim_stop "su8" "$(structured_closeout "su8" "Updated the UI components and supporting utility for the requested change.")")"
assert_empty "seq-U8: stop allowed after design review" "${out2}"

# Verify ui_edit_count was tracked
assert_eq "seq-U8: ui_edit_count=1" "1" "$(read_st "su8" "ui_edit_count")"
assert_eq "seq-U8: code_edit_count=1" "1" "$(read_st "su8" "code_edit_count")"
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
# No design-reviewer needed — no UI files edited
out="$(sim_stop "su9" "$(structured_closeout "su9" "Updated the three non-UI source files for the requested change.")")"
assert_empty "seq-U9: no design gate for non-UI edits" "${out}"
assert_eq "seq-U9: ui_edit_count=0" "" "$(read_st "su9" "ui_edit_count")"
teardown_test


# -------------------------------------------------------
# Delivery-contract inferred-rule parser regressions
# -------------------------------------------------------
printf '\nDelivery-contract inferred rules:\n'

# Retired R1 must stay retired end to end: two implementation edits with fresh
# proof must not manufacture a test-file obligation merely from file count.
# The independent verification and closeout gates remain in force.
setup_test
init_session "sdc-r1"
sim_edit "sdc-r1" "/src/r1-a.ts"
sim_edit "sdc-r1" "/src/r1-b.ts"
sim_verify "sdc-r1" "npm test" "Tests: 5 passed"
# Keep verification valid for the generic gate while retaining the legacy
# scope shape that used to trigger inferred R1.
state_file="${TEST_HOME}/.claude/quality-pack/state/sdc-r1/session_state.json"
jq '.last_verify_scope="lint"' "${state_file}" >"${state_file}.tmp" \
  && mv "${state_file}.tmp" "${state_file}"
sim_review "sdc-r1" "Clean.
VERDICT: CLEAN"
out="$(sim_stop "sdc-r1" "$(structured_closeout "sdc-r1" "Updated both implementation files and verified the behavior.")")"
assert_empty "delivery retired R1: no inferred test-file block" "${out}"
assert_not_contains "delivery retired R1: state never restores rule" \
  "R1_missing_tests" "$(read_st "sdc-r1" "inferred_contract_rules")"
teardown_test

# Four implementation files deliberately leave R5 active. Its `(R5: ...)`
# detail tag exercises the colon-bearing safe parser path.
setup_test
init_session "sdc-r5"
sim_edit "sdc-r5" "/src/r5-a.ts"
sim_edit "sdc-r5" "/src/r5-b.ts"
sim_edit "sdc-r5" "/src/r5-c.ts"
sim_edit "sdc-r5" "/src/r5-d.ts"
sim_edit "sdc-r5" "/tests/r5.test.ts"
sim_verify "sdc-r5" "npm test" "Tests: 5 passed"
sim_review "sdc-r5" "Clean.
VERDICT: CLEAN"
sim_excellence_review "sdc-r5"
out="$(sim_stop "sdc-r5")"
assert_contains "delivery R5: stop emits a block" '"decision":"block"' "${out}"
assert_contains "delivery R5: block names R5" "R5:" "${out}"
assert_contains "delivery R5: block maps tag to docs" "docs" "${out}"
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

# Sequence LC: a passive browser observation on a non-UI edit (confidence=25)
# should NOT satisfy the verify gate at default threshold (40). The user must
# run a real test suite.
setup_test
init_session "slc"
sim_edit "slc" "/src/app.ts"

# A content-bearing DOM snapshot is a passed observation, but without a UI
# edit it remains below the coding verification threshold.
sim_mcp_verify "slc" \
  "mcp__plugin_playwright_playwright__browser_snapshot" \
  "DOM content: static source"

# Review passes
sim_review "slc" "Looks clean.
VERDICT: CLEAN"

# Stop should block because confidence (25) < threshold (40).
out="$(sim_stop "slc")"
assert_contains "seq-LC: low-confidence blocks" '"decision":"block"' "${out}"
assert_contains "seq-LC: mentions low confidence" "low confidence" "${out}"

# Now run npm test (scores 70+ with output) — should satisfy
sim_verify "slc" "npm test" "Tests: 10 passed, 0 failed"
out2="$(sim_stop "slc" "$(structured_closeout "slc" "Updated /src/app.ts and replaced the low-confidence verification with the project test suite.")")"
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

# Test MCP-V4: absent snapshot result is a failed observation
setup_test
init_session "smv4"
sim_mcp_verify "smv4" "mcp__plugin_playwright_playwright__browser_snapshot" ""
assert_eq "mcp-v4: empty output = failed" "failed" "$(read_st "smv4" "last_verify_outcome")"
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
sim_design_reviewer "smv5" "The rendered UI is intentional and coherent.
VERDICT: CLEAN"
out="$(sim_stop "smv5" "$(structured_closeout "smv5" "Updated /src/App.tsx for the requested UI change.")")"
assert_empty "mcp-v5: full MCP cycle allows stop" "${out}"
teardown_test

# Test MCP-V6: an empty passive MCP result is failed verification and blocks.
setup_test
init_session "smv6"
sim_edit "smv6" "/src/utils.ts"
sim_mcp_verify "smv6" "mcp__plugin_playwright_playwright__browser_snapshot" ""
sim_review "smv6" "Summary: The code looks good. No issues found."
out="$(sim_stop "smv6")"
assert_not_empty "mcp-v6: passive MCP on non-UI file blocks" "${out}"
assert_contains "mcp-v6: mentions failed verification" "Verification failed" "${out}"
teardown_test

# Test MCP-V7: computer-use screenshot records as visual_check
setup_test
init_session "smv7"
sim_mcp_verify "smv7" "mcp__computer-use__screenshot" "Screenshot captured"
assert_eq "mcp-v7: method" "mcp_visual_check" "$(read_st "smv7" "last_verify_method")"
assert_eq "mcp-v7: outcome passed" "passed" "$(read_st "smv7" "last_verify_outcome")"
teardown_test

# Test MCP-V8: executable browser calls cannot self-certify as verification.
# The mutation classifier treats run_code as interaction-capable; PostToolUse
# edit-clock wiring owns it, while record-verification must publish no receipt.
setup_test
init_session "smv8"
sim_mcp_verify "smv8" "mcp__plugin_playwright_playwright__browser_run_code" "42"
assert_empty "mcp-v8: run_code cannot self-verify" "$(read_st "smv8" "last_verify_method")"
teardown_test

# Test MCP-V9: optional filename persistence is a mutation, not observation.
setup_test
init_session "smv9"
smv9_payload="$(jq -nc '{
  session_id:"smv9",
  tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
  tool_use_id:"smv9-filename-save",
  tool_input:{filename:"proof/snapshot.md",target:"#checkout"},
  tool_response:"Snapshot saved to proof/snapshot.md"
}')"
run_hook "${HOOK_DIR}/record-tool-start-revision.sh" "${smv9_payload}"
run_hook "${HOOK_DIR}/mark-edit.sh" "${smv9_payload}"
run_hook "${HOOK_DIR}/record-verification.sh" "${smv9_payload}"
assert_eq "mcp-v9: filename save advances mutation generation" "1" \
  "$(read_st "smv9" "edit_revision")"
assert_empty "mcp-v9: filename save cannot self-verify" \
  "$(read_st "smv9" "last_verify_method")"
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
# v1.40.x harness-improvement wave: anchor changed from "FIRST self-assess"
# to "correctness AND completeness". The prior verbose form's FIRST/THEN
# procedural scaffolding was replaced with a single sentence framing the
# reviewer's lens — the new anchor stays load-bearing for the
# block-1-only-vs-block-2-concise distinction this sequence tests.
assert_contains "seq-AA: block 1 is verbose" "correctness AND completeness" "${out1}"

out2="$(sim_stop "saa")"
# Block 2 must NOT contain the verbose review_action body
if [[ "${out2}" == *"correctness AND completeness"* ]]; then
  printf '  FAIL: seq-AA: block 2 should drop verbose review_action text\n' >&2
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
out1="$(sim_stop "sbb" "$(structured_closeout "sbb" "Preserved the resumed-session state for the requested work.")")"
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
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-constitution-authority.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/lib/quality-constitution-authority.sh"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-contract.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/lib/quality-contract.sh"
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
# Gap 1b: compact handoff carries the delivery contract and remaining work
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg1b" "coding"
state_dir="${TEST_HOME}/.claude/quality-pack/state/cg1b"
jq '. + {
  done_contract_primary:"Ship the auth fix",
  done_contract_commit_mode:"required",
  done_contract_prompt_surfaces:"tests,docs",
  done_contract_test_expectation:"add_or_update_tests",
  verification_contract_required:"code_review,code_verify,prose_review,test_surface,commit_record"
}' "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
  && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
printf '/project/src/auth.ts\n' > "${state_dir}/edited_files.log"
sim_pre_compact "cg1b"
sim_post_compact "cg1b" "auto" "Summary body"
out_g1b="$(sim_session_start_compact "cg1b")"
assert_contains "gap1b: delivery contract carried into compact handoff" "Carry forward the preserved delivery contract: primary=Ship the auth fix; commit=required; push=unspecified; prompt surfaces=tests · docs;" "${out_g1b}"
assert_contains "gap1b: remaining obligations carried into compact handoff" "Outstanding obligations before Stop" "${out_g1b}"
assert_contains "gap1b: missing tests named in compact handoff" "add or update the requested tests/regression coverage" "${out_g1b}"
teardown_test

# -------------------------------------------------------
# Gap 1c: compact handoff surfaces push_mode alongside commit_mode
#   Defect repaired post-v1.36.0: push_mode was set in state by the
#   v1.34.0 router but never surfaced in the compact/resume handoff
#   text. After 4ac7e4d added Stop-time publish-record enforcement,
#   the asymmetric handoff line silently dropped the publish half of
#   compound prompts ("commit X then push") on resume.
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg1c" "coding"
state_dir="${TEST_HOME}/.claude/quality-pack/state/cg1c"
jq '. + {
  done_contract_primary:"Ship and publish the release",
  done_contract_commit_mode:"required",
  done_contract_push_mode:"required",
  done_contract_prompt_surfaces:"release",
  done_contract_test_expectation:"verify",
  verification_contract_required:"code_review,code_verify,release_surface,commit_record,publish_record"
}' "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
  && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
printf '/project/src/release.ts\n' > "${state_dir}/edited_files.log"
sim_pre_compact "cg1c"
sim_post_compact "cg1c" "auto" "Summary body"
out_g1c="$(sim_session_start_compact "cg1c")"
assert_contains "gap1c: compact handoff surfaces push=required" "commit=required; push=required;" "${out_g1c}"
assert_contains "gap1c: outstanding publish obligation surfaced on compact resume" "run the requested push/tag/release/publish action" "${out_g1c}"
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
printf '%s\n' \
  '{"ts":1,"agent_type":"abandoned-old","description":"must stay hidden","review_dispatch_abandoned":true}' \
  >>"${pending_file}"
if [[ -f "${pending_file}" ]] \
    && [[ "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' "${pending_file}")" -eq 2 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3: pending_agents.jsonl should have 2 live entries\n' >&2
  fail=$((fail + 1))
fi
# Snapshot should list both pending agents
sim_pre_compact "cg3"
snapshot="$(cat "${TEST_HOME}/.claude/quality-pack/state/cg3/precompact_snapshot.md" 2>/dev/null || echo "")"
assert_contains "gap3: snapshot lists quality-researcher" "quality-researcher" "${snapshot}"
assert_contains "gap3: snapshot lists librarian" "librarian" "${snapshot}"
assert_contains "gap3: snapshot section header" "Pending Specialists" "${snapshot}"
assert_not_contains "gap3: snapshot hides abandoned tombstones" "abandoned-old" "${snapshot}"
# SubagentStop for librarian should remove exactly one librarian entry
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3" '{session_id:$s,agent_type:"librarian",last_assistant_message:"Done."}')"
if [[ -f "${pending_file}" ]] \
  && [[ "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' "${pending_file}")" -eq 1 ]] \
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
assert_not_contains "gap3: compact handoff hides abandoned tombstones" "abandoned-old" "${out_g3}"
teardown_test

# -------------------------------------------------------
# Gap 3 Council: coverage ledger is objective-scoped and dispatch-enforced
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3ledger" "coding"

denied_no_ledger="$(sim_pre_agent_dispatch "cg3ledger" "security-lens" \
  "[council:primary] inspect trust boundaries")"
assert_contains "gap3-ledger: tagged primary without ledger is denied" \
  '"permissionDecision":"deny"' "${denied_no_ledger}"

council_ledger_payload="$(jq -nc '{
  objective:"whole-project trust and usability assessment",
  coverage_rows:[
    {id:"security",need:"trust boundaries",evidence:"auth and token handlers are present",impact:"credential exposure",competence:"application security",status:"selected"},
    {id:"visual",need:"visual polish",evidence:"no user-facing UI in scope",impact:"low",competence:"visual design",status:"skipped",reason:"repository is a CLI harness"}
  ],
  selections:[
    {agent:"security-lens",phase:"primary",coverage_ids:["security"],reason:"owns the evidenced trust boundary",non_goals:["visual styling"]}
  ]
}')"
printf '%s' "${council_ledger_payload}" \
  | SESSION_ID="cg3ledger" bash "${HOOK_DIR}/record-council-coverage.sh" init >/dev/null

allowed_dispatch="$(sim_pre_agent_dispatch "cg3ledger" "security-lens" \
  "[council:primary] inspect trust boundaries")"
assert_empty "gap3-ledger: listed primary dispatch is allowed" "${allowed_dispatch}"
council_dispatch_file="${TEST_HOME}/.claude/quality-pack/state/cg3ledger/council_dispatches.jsonl"
assert_eq "gap3-ledger: durable dispatch records Council purpose" "council" \
  "$(jq -r 'select(.agent_type=="security-lens") | .purpose' "${council_dispatch_file}")"
assert_eq "gap3-ledger: durable Council record captures primary phase" "primary" \
  "$(jq -r 'select(.agent_type=="security-lens") | .council_phase' "${council_dispatch_file}")"

# Agent calls are blocking in the real client. Record the selected primary's
# return before simulating a later user prompt; leaving it in flight would make
# a same-identity dispatch in the next objective causally ambiguous.
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3ledger" '{session_id:$s,agent_type:"security-lens",last_assistant_message:"VERDICT: CLEAN"}')"

denied_unlisted="$(sim_pre_agent_dispatch "cg3ledger" "product-lens" \
  "[council:primary] inspect product fit")"
assert_contains "gap3-ledger: unlisted tagged agent is denied" \
  '"permissionDecision":"deny"' "${denied_unlisted}"

# A new user-prompt generation cannot reuse the previous objective's ledger.
ledger_state="${TEST_HOME}/.claude/quality-pack/state/cg3ledger/session_state.json"
jq '.last_user_prompt_ts = ((.last_user_prompt_ts | tonumber) + 1 | tostring)
    | .prompt_revision = 1' \
  "${ledger_state}" >"${ledger_state}.tmp" && mv "${ledger_state}.tmp" "${ledger_state}"
denied_stale="$(sim_pre_agent_dispatch "cg3ledger" "security-lens" \
  "[council:primary] reuse stale selection")"
assert_contains "gap3-ledger: prior-objective ledger is denied" \
  '"permissionDecision":"deny"' "${denied_stale}"

# `update` is only for reconciliation inside the same Council prompt. It must
# not be usable to restamp a stale selection map as current after the objective
# changes; a new prompt has to use `init`, which also archives the old map.
if printf '%s' "${council_ledger_payload}" \
    | SESSION_ID="cg3ledger" bash "${HOOK_DIR}/record-council-coverage.sh" update \
      >/dev/null 2>&1; then
  printf '  FAIL: gap3-ledger: stale map was refreshed across prompt revisions\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# `init` on a genuinely new prompt replaces (and archives) the prior Council
# map, so repeated Council evaluations in one session are not forced to mutate
# stale coverage via `update`.
new_council_ledger_payload="$(printf '%s' "${council_ledger_payload}" \
  | jq '.objective = "new objective trust assessment"')"
printf '%s' "${new_council_ledger_payload}" \
  | SESSION_ID="cg3ledger" bash "${HOOK_DIR}/record-council-coverage.sh" init >/dev/null
allowed_new_objective="$(sim_pre_agent_dispatch "cg3ledger" "security-lens" \
  "[council:primary] inspect new-objective trust boundaries")"
assert_empty "gap3-ledger: new prompt can initialize a fresh Council map" \
  "${allowed_new_objective}"
coverage_history="${TEST_HOME}/.claude/quality-pack/state/cg3ledger/council_coverage_history.jsonl"
assert_eq "gap3-ledger: replaced objective is retained in bounded history" "1" \
  "$(wc -l <"${coverage_history}" | tr -d '[:space:]')"

# Selection IDs must equal the rows marked selected; assigning a skipped row
# is not a valid way to make the coverage table look complete.
invalid_ledger_payload="$(printf '%s' "${council_ledger_payload}" \
  | jq '.selections[0].coverage_ids += ["visual"]')"
if printf '%s' "${invalid_ledger_payload}" \
    | SESSION_ID="cg3ledger" bash "${HOOK_DIR}/record-council-coverage.sh" update \
      >/dev/null 2>&1; then
  printf '  FAIL: gap3-ledger: skipped row was accepted as selected coverage\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# -------------------------------------------------------
# Gap 3 privacy: subagent summary ledger redacts obvious secrets
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3p" "coding"
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3p" --arg m "Investigated with token sk-1234567890abcdef in logs." \
    '{session_id:$s,agent_type:"oracle",last_assistant_message:$m}')"
summary_file_p="${TEST_HOME}/.claude/quality-pack/state/cg3p/subagent_summaries.jsonl"
summary_payload="$(cat "${summary_file_p}" 2>/dev/null || true)"
assert_contains "gap3p: summary contains redaction marker" "<redacted-secret>" "${summary_payload}"
assert_not_contains "gap3p: summary does not contain raw token" "sk-1234567890abcdef" "${summary_payload}"
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
# Gap 3 authority boundary: JSON objects in the tolerant pending ledger may
# not normalize consequence-bearing fields after Bash extraction.
# -------------------------------------------------------
for pending_poison in agent_type abandoned claim_ts; do
  setup_test
  setup_compact_tests
  pending_sid="cg3-byte-${pending_poison}"
  init_session "${pending_sid}" "coding"
  sim_pre_agent_dispatch "${pending_sid}" "quality-researcher" \
    "original byte-bound dispatch" >/dev/null
  pending_byte_file="${TEST_HOME}/.claude/quality-pack/state/${pending_sid}/pending_agents.jsonl"
  case "${pending_poison}" in
    agent_type)
      jq -c '.agent_type += "\u0000"' "${pending_byte_file}" \
        >"${pending_byte_file}.tmp"
      ;;
    abandoned)
      jq -c '.review_dispatch_abandoned = ("true" + "\u0000")' \
        "${pending_byte_file}" >"${pending_byte_file}.tmp"
      ;;
    claim_ts)
      jq -c '. + {
        completion_claim_id:"completion-byte-boundary-12345678",
        completion_claim_ts:("1" + "\u0000"),
        completion_claim_effects_complete:false,
        completion_claim_digest:("a" * 64),
        completion_claim_message:"sealed callback"}' \
        "${pending_byte_file}" >"${pending_byte_file}.tmp"
      ;;
  esac
  mv "${pending_byte_file}.tmp" "${pending_byte_file}"
  cp "${pending_byte_file}" "${pending_byte_file}.before"
  pending_byte_payload="$(jq -nc --arg s "${pending_sid}" \
    '{session_id:$s,tool_name:"Agent",tool_input:{
      subagent_type:"quality-researcher",description:"must stay fenced",
      prompt:"do not admit over malformed authority"}}')"
  pending_byte_rc=0
  printf '%s' "${pending_byte_payload}" \
    | bash "${HOOK_DIR}/record-pending-agent.sh" \
      >/dev/null 2>&1 || pending_byte_rc=$?
  assert_eq "gap3-byte: ${pending_poison} row fails closed" \
    "1" "${pending_byte_rc}"
  assert_eq "gap3-byte: ${pending_poison} row remains byte-exact" "yes" \
    "$(cmp -s "${pending_byte_file}.before" "${pending_byte_file}" \
      && printf yes || printf no)"
  assert_eq "gap3-byte: ${pending_poison} admits no replacement" "1" \
    "$(wc -l <"${pending_byte_file}" | tr -d '[:space:]')"
  teardown_test
done

# Raw NUL in any member of the dispatch-authority set must be rejected before
# SubagentStart arms tracking or changes a causal ledger. Exercise the actual
# byte (not only a JSON `\u0000` escape), because Bash would otherwise discard
# it before a later field comparison.
for native_poison_ledger in pending_agents agent_dispatch_starts native_agent_bindings; do
  setup_test
  setup_compact_tests
  native_poison_sid="cg3-native-byte-${native_poison_ledger}"
  init_session "${native_poison_sid}" "coding"
  sim_pre_agent_dispatch "${native_poison_sid}" "quality-reviewer" \
    "review byte authority" >/dev/null
  native_poison_dir="${TEST_HOME}/.claude/quality-pack/state/${native_poison_sid}"
  native_poison_file="${native_poison_dir}/${native_poison_ledger}.jsonl"
  if [[ "${native_poison_ledger}" == "native_agent_bindings" ]]; then
    printf '%s\n' \
      '{"native_agent_id":"native-prior-safe","agent_type":"quality-reviewer","review_dispatch_id":"","lifecycle_dispatch_id":"dispatch-priorsafebinding123","objective_cycle_id":0,"ts":1}' \
      >"${native_poison_file}"
  fi
  printf '\0' >>"${native_poison_file}"
  cp "${native_poison_file}" "${native_poison_file}.before"
  cp "${native_poison_dir}/session_state.json" \
    "${native_poison_dir}/session_state.json.before"
  native_poison_payload="$(jq -nc --arg s "${native_poison_sid}" \
    '{session_id:$s,agent_id:"native-byte-start",agent_type:"quality-reviewer"}')"
  native_poison_rc=0
  printf '%s' "${native_poison_payload}" \
    | bash "${HOOK_DIR}/record-pending-agent.sh" start \
      >/dev/null 2>&1 || native_poison_rc=$?
  assert_eq "gap3-native-byte: ${native_poison_ledger} fails closed" \
    "1" "${native_poison_rc}"
  assert_eq "gap3-native-byte: ${native_poison_ledger} remains byte-exact" \
    "yes" "$(cmp -s "${native_poison_file}.before" \
      "${native_poison_file}" && printf yes || printf no)"
  assert_eq "gap3-native-byte: ${native_poison_ledger} mutates no state" \
    "yes" "$(cmp -s "${native_poison_dir}/session_state.json.before" \
      "${native_poison_dir}/session_state.json" && printf yes || printf no)"
  assert_eq "gap3-native-byte: no pending native authority is published" \
    "0" "$(jq -Rs '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch {})
        | select((.native_agent_id // "") == "native-byte-start")]
      | length
    ' "${native_poison_dir}/pending_agents.jsonl")"
  native_poison_dispatch_payload="$(jq -nc --arg s "${native_poison_sid}" '
    {session_id:$s,tool_name:"Agent",tool_input:{
      subagent_type:"librarian",description:"must not cross corrupt authority",
      prompt:"inspect without admission"}}
  ')"
  native_poison_dispatch_rc=0
  printf '%s' "${native_poison_dispatch_payload}" \
    | bash "${HOOK_DIR}/record-pending-agent.sh" \
      >/dev/null 2>&1 || native_poison_dispatch_rc=$?
  assert_eq "gap3-native-byte: ${native_poison_ledger} also fences dispatch" \
    "1" "${native_poison_dispatch_rc}"
  assert_eq "gap3-native-byte: dispatch preserves ${native_poison_ledger}" \
    "yes" "$(cmp -s "${native_poison_file}.before" \
      "${native_poison_file}" && printf yes || printf no)"
  assert_eq "gap3-native-byte: dispatch mutates no state" \
    "yes" "$(cmp -s "${native_poison_dir}/session_state.json.before" \
      "${native_poison_dir}/session_state.json" && printf yes || printf no)"
  teardown_test
done

# A duplicate start lifecycle is individually well-formed JSON but ambiguous
# authority. The binder must reject it without choosing one row or publishing
# a native registry entry.
setup_test
setup_compact_tests
init_session "cg3-native-duplicate" "coding"
sim_pre_agent_dispatch "cg3-native-duplicate" "quality-reviewer" \
  "review duplicate authority" >/dev/null
native_duplicate_dir="${TEST_HOME}/.claude/quality-pack/state/cg3-native-duplicate"
native_duplicate_pending="${native_duplicate_dir}/pending_agents.jsonl"
native_duplicate_starts="${native_duplicate_dir}/agent_dispatch_starts.jsonl"
native_duplicate_line="$(sed -n '1p' "${native_duplicate_starts}")"
printf '%s\n' "${native_duplicate_line}" >>"${native_duplicate_starts}"
cp "${native_duplicate_pending}" "${native_duplicate_pending}.before"
cp "${native_duplicate_starts}" "${native_duplicate_starts}.before"
native_duplicate_payload="$(jq -nc \
  '{session_id:"cg3-native-duplicate",agent_id:"native-duplicate-start",agent_type:"quality-reviewer"}')"
native_duplicate_rc=0
printf '%s' "${native_duplicate_payload}" \
  | bash "${HOOK_DIR}/record-pending-agent.sh" start \
    >/dev/null 2>&1 || native_duplicate_rc=$?
assert_eq "gap3-native-duplicate: ambiguous start lifecycle fails closed" \
  "1" "${native_duplicate_rc}"
assert_eq "gap3-native-duplicate: pending ledger remains byte-exact" "yes" \
  "$(cmp -s "${native_duplicate_pending}.before" \
    "${native_duplicate_pending}" && printf yes || printf no)"
assert_eq "gap3-native-duplicate: start ledger remains byte-exact" "yes" \
  "$(cmp -s "${native_duplicate_starts}.before" \
    "${native_duplicate_starts}" && printf yes || printf no)"
assert_eq "gap3-native-duplicate: no binding registry is published" "0" \
  "$([[ -s "${native_duplicate_dir}/native_agent_bindings.jsonl" ]] \
    && printf 1 || printf 0)"
teardown_test

# The dedicated reviewer callback may inherit an effects-complete summary
# claim. A raw-NUL sibling byte must not be ignored while selecting that
# otherwise exact role/native/message tuple, or the callback could acquire a
# publication capability from a ledger Bash cannot represent faithfully.
setup_test
setup_compact_tests
init_session "cg3-reviewer-claim-byte" "coding"
sim_pre_agent_dispatch "cg3-reviewer-claim-byte" "quality-reviewer" \
  "review claimed result" >/dev/null
reviewer_claim_start_payload="$(jq -nc \
  '{session_id:"cg3-reviewer-claim-byte",agent_id:"native-reviewer-claim-byte",agent_type:"quality-reviewer"}')"
printf '%s' "${reviewer_claim_start_payload}" \
  | bash "${HOOK_DIR}/record-pending-agent.sh" start >/dev/null 2>&1
reviewer_claim_dir="${TEST_HOME}/.claude/quality-pack/state/cg3-reviewer-claim-byte"
reviewer_claim_pending="${reviewer_claim_dir}/pending_agents.jsonl"
reviewer_claim_message='Reviewed the requested change.
VERDICT: CLEAN'
reviewer_claim_digest="$(test_token_digest "${reviewer_claim_message}")"
jq -c --arg message "${reviewer_claim_message}" \
  --arg digest "${reviewer_claim_digest}" '
    . + {completion_claim_id:"completion-reviewer-byte-12345678",
      completion_claim_ts:1,completion_claim_effects_complete:true,
      completion_claim_digest:$digest,completion_claim_message:$message}
  ' "${reviewer_claim_pending}" >"${reviewer_claim_pending}.tmp"
mv "${reviewer_claim_pending}.tmp" "${reviewer_claim_pending}"
printf '\0' >>"${reviewer_claim_pending}"
cp "${reviewer_claim_pending}" "${reviewer_claim_pending}.before"
cp "${reviewer_claim_dir}/session_state.json" \
  "${reviewer_claim_dir}/session_state.json.before"
reviewer_claim_callback="$(jq -nc --arg message "${reviewer_claim_message}" '
  {session_id:"cg3-reviewer-claim-byte",agent_id:"native-reviewer-claim-byte",
   agent_type:"quality-reviewer",last_assistant_message:$message}
')"
reviewer_claim_rc=0
printf '%s' "${reviewer_claim_callback}" \
  | bash "${HOOK_DIR}/record-reviewer.sh" \
    >/dev/null 2>&1 || reviewer_claim_rc=$?
assert_eq "gap3-reviewer-claim-byte: malformed claim grants no capability" \
  "0" "${reviewer_claim_rc}"
assert_eq "gap3-reviewer-claim-byte: pending claim remains byte-exact" "yes" \
  "$(cmp -s "${reviewer_claim_pending}.before" \
    "${reviewer_claim_pending}" && printf yes || printf no)"
assert_eq "gap3-reviewer-claim-byte: reviewer state remains byte-exact" "yes" \
  "$(cmp -s "${reviewer_claim_dir}/session_state.json.before" \
    "${reviewer_claim_dir}/session_state.json" && printf yes || printf no)"
assert_eq "gap3-reviewer-claim-byte: no reviewer receipt is published" "0" \
  "$([[ -s "${reviewer_claim_dir}/reviewer_publication_outcomes.jsonl" ]] \
    && printf 1 || printf 0)"
teardown_test

# -------------------------------------------------------
# Gap 3 edge case: same-exact-type concurrency is denied before FIFO ambiguity
# -------------------------------------------------------
setup_test
setup_compact_tests
init_session "cg3b" "coding"
sim_pre_agent_dispatch "cg3b" "quality-researcher" "first dispatch" >/dev/null
same_type_duplicate="$(sim_pre_agent_dispatch "cg3b" "quality-researcher" "second dispatch")"
assert_contains "gap3: same-exact active duplicate is denied" \
  "[Dispatch causality]" "${same_type_duplicate}"
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg3b" '{session_id:$s,agent_type:"quality-researcher",last_assistant_message:"Done."}')"
pending_file_b="${TEST_HOME}/.claude/quality-pack/state/cg3b/pending_agents.jsonl"
# The one admitted call is removed; there is no second row to misattribute.
if [[ ! -s "${pending_file_b}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap3: admitted exact-identity row did not settle\n    contents: %s\n' "$(cat "${pending_file_b}" 2>/dev/null)" >&2
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
sim_pre_agent_dispatch "culw" "quality-reviewer" "review launched before deactivation"
verification_starts_before="${TEST_HOME}/.claude/quality-pack/state/culw/.verification-starts"
mkdir -p "${verification_starts_before}"
printf '%s\n' '{"tool_use_id":"old","code_revision":"1"}' \
  >"${verification_starts_before}/old.json"
sim_pre_compact "culw"
# Confirm pre-compact did set the flags we want to clear
assert_eq "ulw-off: review flag set before deactivate" "1" "$(read_st "culw" "review_pending_at_compact")"
pending_before="${TEST_HOME}/.claude/quality-pack/state/culw/pending_agents.jsonl"
review_starts_before="${TEST_HOME}/.claude/quality-pack/state/culw/agent_dispatch_starts.jsonl"
[[ -f "${pending_before}" ]] && pass=$((pass + 1)) || { printf '  FAIL: ulw-off: pending file should exist before deactivate\n' >&2; fail=$((fail + 1)); }
[[ -f "${review_starts_before}" ]] && pass=$((pass + 1)) || { printf '  FAIL: ulw-off: reviewer-start file should exist before deactivate\n' >&2; fail=$((fail + 1)); }
[[ -f "${verification_starts_before}/old.json" ]] && pass=$((pass + 1)) || { printf '  FAIL: ulw-off: verification start should exist before deactivate\n' >&2; fail=$((fail + 1)); }

# Deterministic lifecycle race: let a verification PreTool hook pass its outer
# active-mode checks, then pause its state-lock acquisition. Deactivation must
# clear the sentinel/state first; when the old hook resumes, its in-lock recheck
# must refuse to recreate .verification-starts.
deactivate_race_ready="${TEST_HOME}/deactivate-race-ready"
deactivate_race_release="${TEST_HOME}/deactivate-race-release"
deactivate_race_payload="$(jq -nc --arg s "culw" \
  '{session_id:$s,tool_name:"Bash",tool_use_id:"deactivate-race",tool_input:{command:"npm test"}}')"
(
  printf '%s' "${deactivate_race_payload}" \
    | env OMC_TEST_VERIFICATION_START_LOCK_READY_FILE="${deactivate_race_ready}" \
      OMC_TEST_VERIFICATION_START_LOCK_RELEASE_FILE="${deactivate_race_release}" \
      bash "${HOOK_DIR}/record-tool-start-revision.sh" >/dev/null 2>&1
) &
deactivate_race_pid=$!
for _deactivate_wait in $(seq 1 500); do
  [[ -f "${deactivate_race_ready}" ]] && break
  kill -0 "${deactivate_race_pid}" 2>/dev/null || break
  sleep 0.01
done
if [[ -f "${deactivate_race_ready}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: ulw-off: verification PreTool did not reach lock barrier\n' >&2
  fail=$((fail + 1))
fi
# Generation-scoped closeout nonces belong to the interval being deactivated
# and must be quarantined with the other transient callback evidence.
mkdir -p "${TEST_HOME}/.claude/quality-pack/state/culw/.closeout-material-generations"
printf '1|deactivate-fixture\n' \
  >"${TEST_HOME}/.claude/quality-pack/state/culw/.closeout-material-generations/1.nonce"
# Run deactivation
printf '{}' | bash "${HOOK_DIR}/ulw-deactivate.sh" "culw" >/dev/null 2>&1 || true
touch "${deactivate_race_release}"
wait "${deactivate_race_pid}" 2>/dev/null || true
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
if [[ -e "${TEST_HOME}/.claude/quality-pack/state/culw/.closeout-material-generations" ]]; then
  printf '  FAIL: ulw-off: closeout material nonce directory should have been deleted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# Reviewer and verification starts belong to the same deactivated interval.
if [[ -e "${review_starts_before}" || -e "${verification_starts_before}" ]]; then
  printf '  FAIL: ulw-off: transient reviewer/verification starts should have been deleted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# The version marker is intentionally durable: a late completion from the old
# interval must fail closed rather than entering the legacy migration path.
assert_eq "ulw-off: reviewer causality version survives cleanup" \
  "1" "$(read_st "culw" "review_dispatch_tracking_version")"

# Reactivation permanently remembers that the old call can still return. The
# same identity therefore requires a fresh explicit binding; distinct roles
# remain frictionless.
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
culw_state="${TEST_HOME}/.claude/quality-pack/state/culw/session_state.json"
jq '.workflow_mode="ultrawork"
  | .ulw_enforcement_active="1"
  | .ulw_enforcement_generation = (
      ((((.ulw_enforcement_generation // "0") | tonumber?) // 0) + 1) | tostring
    )' "${culw_state}" >"${culw_state}.tmp" \
  && mv "${culw_state}.tmp" "${culw_state}"
reactivated_unbound="$(sim_pre_agent_dispatch "culw" "quality-reviewer" "fresh review after reactivation")"
assert_contains "ulw-off: same reviewer requires a post-reactivation binding" \
  "[review-rebind:" "${reactivated_unbound}"
reactivated_review="$(sim_pre_agent_dispatch "culw" "quality-reviewer" \
  '[review-rebind:reactivated-review] fresh review; emit REVIEW_DISPATCH_ID: reactivated-review immediately before VERDICT')"
assert_empty "ulw-off: bound same reviewer dispatches after reactivation" \
  "${reactivated_review}"
teardown_test

# -------------------------------------------------------
# Delayed compact callbacks cannot cross /ulw-off + reactivation
# -------------------------------------------------------
wait_for_compact_publish_barrier() {
  local pid="$1" ready_file="$2" label="$3" attempt
  for attempt in $(seq 1 500); do
    [[ -f "${ready_file}" ]] && break
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.01
  done
  if [[ -f "${ready_file}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s did not reach its controlled publication barrier\n' \
      "${label}" >&2
    fail=$((fail + 1))
  fi
}

deactivate_and_reactivate_compact_session() {
  local sid="$1" state_file
  state_file="${TEST_HOME}/.claude/quality-pack/state/${sid}/session_state.json"
  printf '{}' | bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
    >/dev/null 2>&1 || true
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
  jq '.workflow_mode="ultrawork"
      | .ulw_enforcement_active="1"
      | .session_outcome=""
      | .ulw_enforcement_generation = (
          ((((.ulw_enforcement_generation // "0") | tonumber?) // 0) + 1)
          | tostring
        )' "${state_file}" >"${state_file}.tmp" \
    && mv "${state_file}.tmp" "${state_file}"
}

# PreCompact has finished rendering but has not published. Reset/reactivation
# retires its interval; releasing the old process must publish neither artifact
# nor compact-adjacent state into the new active generation.
setup_test
setup_compact_tests
init_session "compact-race-pre" "coding"
compact_race_pre_dir="${TEST_HOME}/.claude/quality-pack/state/compact-race-pre"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="101"' \
  "${compact_race_pre_dir}/session_state.json" \
  >"${compact_race_pre_dir}/session_state.json.tmp" \
  && mv "${compact_race_pre_dir}/session_state.json.tmp" \
    "${compact_race_pre_dir}/session_state.json"
compact_pre_ready="${TEST_HOME}/compact-pre-ready"
compact_pre_release="${TEST_HOME}/compact-pre-release"
compact_pre_payload="$(jq -nc --arg s "compact-race-pre" \
  '{session_id:$s,trigger:"auto",custom_instructions:"",cwd:"/tmp",hook_event_name:"PreCompact"}')"
(
  printf '%s' "${compact_pre_payload}" \
    | env OMC_TEST_PRECOMPACT_PUBLISH_READY_FILE="${compact_pre_ready}" \
      OMC_TEST_PRECOMPACT_PUBLISH_RELEASE_FILE="${compact_pre_release}" \
      bash "${QUALITY_PACK_DIR}/pre-compact-snapshot.sh" >/dev/null 2>&1
) &
compact_pre_pid=$!
wait_for_compact_publish_barrier "${compact_pre_pid}" "${compact_pre_ready}" \
  "delayed PreCompact"
deactivate_and_reactivate_compact_session "compact-race-pre"
touch "${compact_pre_release}"
wait "${compact_pre_pid}" 2>/dev/null || true
[[ ! -e "${compact_race_pre_dir}/precompact_snapshot.md" ]] \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: delayed PreCompact recreated its retired snapshot\n' >&2; fail=$((fail + 1)); }
assert_empty "delayed PreCompact does not republish request clocks" \
  "$(read_st "compact-race-pre" "last_compact_request_ts")"
assert_empty "delayed PreCompact does not republish review continuity" \
  "$(read_st "compact-race-pre" "review_pending_at_compact")"
teardown_test

# PostCompact has already read the old snapshot and rendered its wrapper. The
# same interval transition must reject both wrapper publication and its paired
# just_compacted clocks.
setup_test
setup_compact_tests
init_session "compact-race-post" "coding"
compact_race_post_dir="${TEST_HOME}/.claude/quality-pack/state/compact-race-post"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="201"' \
  "${compact_race_post_dir}/session_state.json" \
  >"${compact_race_post_dir}/session_state.json.tmp" \
  && mv "${compact_race_post_dir}/session_state.json.tmp" \
    "${compact_race_post_dir}/session_state.json"
sim_pre_compact "compact-race-post"
compact_post_ready="${TEST_HOME}/compact-post-ready"
compact_post_release="${TEST_HOME}/compact-post-release"
compact_post_payload="$(jq -nc --arg s "compact-race-post" \
  '{session_id:$s,trigger:"auto",compact_summary:"old summary",cwd:"/tmp",hook_event_name:"PostCompact"}')"
(
  printf '%s' "${compact_post_payload}" \
    | env OMC_TEST_POSTCOMPACT_PUBLISH_READY_FILE="${compact_post_ready}" \
      OMC_TEST_POSTCOMPACT_PUBLISH_RELEASE_FILE="${compact_post_release}" \
      bash "${QUALITY_PACK_DIR}/post-compact-summary.sh" >/dev/null 2>&1
) &
compact_post_pid=$!
wait_for_compact_publish_barrier "${compact_post_pid}" \
  "${compact_post_ready}" "delayed PostCompact"
deactivate_and_reactivate_compact_session "compact-race-post"
touch "${compact_post_release}"
wait "${compact_post_pid}" 2>/dev/null || true
[[ ! -e "${compact_race_post_dir}/compact_handoff.md" ]] \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: delayed PostCompact recreated its retired handoff\n' >&2; fail=$((fail + 1)); }
assert_empty "delayed PostCompact does not republish continuation flag" \
  "$(read_st "compact-race-post" "just_compacted")"
assert_empty "delayed PostCompact does not republish summary clock" \
  "$(read_st "compact-race-post" "last_compact_summary_ts")"
teardown_test

# SessionStart has rendered the exact old context but has not stamped/emitted it.
# Reset/reactivation must make the old callback silent and leave no rehydrate
# state in the new generation.
setup_test
setup_compact_tests
init_session "compact-race-start" "coding"
compact_race_start_dir="${TEST_HOME}/.claude/quality-pack/state/compact-race-start"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="301"' \
  "${compact_race_start_dir}/session_state.json" \
  >"${compact_race_start_dir}/session_state.json.tmp" \
  && mv "${compact_race_start_dir}/session_state.json.tmp" \
    "${compact_race_start_dir}/session_state.json"
sim_pre_compact "compact-race-start"
sim_post_compact "compact-race-start" "auto" "old summary"
compact_start_ready="${TEST_HOME}/compact-start-ready"
compact_start_release="${TEST_HOME}/compact-start-release"
compact_start_output="${TEST_HOME}/compact-start-output"
compact_start_payload="$(jq -nc --arg s "compact-race-start" \
  '{session_id:$s,source:"compact",cwd:"/tmp",hook_event_name:"SessionStart"}')"
(
  printf '%s' "${compact_start_payload}" \
    | env OMC_TEST_COMPACT_REHYDRATE_READY_FILE="${compact_start_ready}" \
      OMC_TEST_COMPACT_REHYDRATE_RELEASE_FILE="${compact_start_release}" \
      bash "${QUALITY_PACK_DIR}/session-start-compact-handoff.sh" \
      >"${compact_start_output}" 2>/dev/null
) &
compact_start_pid=$!
wait_for_compact_publish_barrier "${compact_start_pid}" \
  "${compact_start_ready}" "delayed compact SessionStart"
deactivate_and_reactivate_compact_session "compact-race-start"
touch "${compact_start_release}"
wait "${compact_start_pid}" 2>/dev/null || true
assert_empty "delayed compact SessionStart emits no old-generation context" \
  "$(cat "${compact_start_output}" 2>/dev/null || true)"
assert_empty "delayed compact SessionStart does not republish rehydrate clock" \
  "$(read_st "compact-race-start" "last_compact_rehydrate_ts")"
assert_empty "delayed compact SessionStart does not force current context" \
  "$(read_st "compact-race-start" "directive_context_force_full")"
teardown_test

# -------------------------------------------------------
# ulw-off addresses an exact session and fails closed on ambiguity/failure
# -------------------------------------------------------
setup_test
init_session "off-arg-target" "coding"
init_session "off-env-target" "coding"
for off_sid in off-arg-target off-env-target; do
  off_state="${TEST_HOME}/.claude/quality-pack/state/${off_sid}/session_state.json"
  jq --arg generation "${off_sid}-generation" \
    '.ulw_enforcement_active="1" | .ulw_enforcement_generation=$generation' \
    "${off_state}" >"${off_state}.tmp" && mv "${off_state}.tmp" "${off_state}"
  touch "${TEST_HOME}/.claude/quality-pack/state/${off_sid}/.ulw_active"
done

off_arg_rc=0
off_arg_out="$(env CLAUDE_CODE_SESSION_ID="off-env-target" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "off-arg-target" 2>&1)" || off_arg_rc=$?
assert_eq "ulw-off exact argument succeeds" "0" "${off_arg_rc}"
assert_contains "ulw-off argument reports the addressed session" \
  "session off-arg-target" "${off_arg_out}"
assert_empty "ulw-off argument clears only its target workflow" \
  "$(read_st "off-arg-target" "workflow_mode")"
assert_eq "ulw-off argument takes precedence over environment" "ultrawork" \
  "$(read_st "off-env-target" "workflow_mode")"

off_env_rc=0
off_env_out="$(env -u SESSION_ID CLAUDE_CODE_SESSION_ID="off-env-target" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" 2>&1)" || off_env_rc=$?
assert_eq "ulw-off exact Claude session environment succeeds" "0" "${off_env_rc}"
assert_contains "ulw-off environment reports the addressed session" \
  "session off-env-target" "${off_env_out}"
assert_empty "ulw-off environment clears its exact target" \
  "$(read_st "off-env-target" "workflow_mode")"
teardown_test

setup_test
init_session "off-valid-byte-cwd" "coding"
init_session "off-nul-byte-cwd" "coding"
for off_sid in off-valid-byte-cwd off-nul-byte-cwd; do
  off_state="${TEST_HOME}/.claude/quality-pack/state/${off_sid}/session_state.json"
  jq --arg cwd "${PWD}" \
    '.cwd=$cwd | .ulw_enforcement_active="1"' \
    "${off_state}" >"${off_state}.tmp" && mv "${off_state}.tmp" "${off_state}"
done
off_nul_state="${TEST_HOME}/.claude/quality-pack/state/off-nul-byte-cwd/session_state.json"
jq '.cwd = (.cwd + "\u0000")' "${off_nul_state}" \
  >"${off_nul_state}.tmp" && mv "${off_nul_state}.tmp" "${off_nul_state}"
off_byte_rc=0
off_byte_out="$(env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
  bash "${HOOK_DIR}/ulw-deactivate.sh" 2>&1)" || off_byte_rc=$?
assert_eq "ulw-off ignores NUL-aliased cwd candidate" "0" "${off_byte_rc}"
assert_contains "ulw-off selects the exact safe cwd candidate" \
  "session off-valid-byte-cwd" "${off_byte_out}"
assert_empty "ulw-off deactivates safe cwd candidate" \
  "$(read_st "off-valid-byte-cwd" "workflow_mode")"
assert_eq "ulw-off preserves malformed cwd candidate" "ultrawork" \
  "$(read_st "off-nul-byte-cwd" "workflow_mode")"
teardown_test

setup_test
init_session "off-ambiguous-a" "coding"
init_session "off-ambiguous-b" "coding"
for off_sid in off-ambiguous-a off-ambiguous-b; do
  off_state="${TEST_HOME}/.claude/quality-pack/state/${off_sid}/session_state.json"
  jq --arg cwd "${PWD}" \
    '.cwd=$cwd | .ulw_enforcement_active="1"' \
    "${off_state}" >"${off_state}.tmp" && mv "${off_state}.tmp" "${off_state}"
done
off_ambiguous_rc=0
off_ambiguous_out="$(env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
  bash "${HOOK_DIR}/ulw-deactivate.sh" 2>&1)" || off_ambiguous_rc=$?
assert_eq "ulw-off refuses two active sessions in the same cwd" "1" \
  "${off_ambiguous_rc}"
assert_contains "ulw-off ambiguity names the exact-ID recovery" \
  "pass the exact session id" "${off_ambiguous_out}"
assert_eq "ulw-off ambiguity leaves session A active" "1" \
  "$(read_st "off-ambiguous-a" "ulw_enforcement_active")"
assert_eq "ulw-off ambiguity leaves session B active" "1" \
  "$(read_st "off-ambiguous-b" "ulw_enforcement_active")"

missing_off_sid="off-does-not-exist"
missing_off_dir="${TEST_HOME}/.claude/quality-pack/state/${missing_off_sid}"
off_missing_rc=0
off_missing_out="$(bash "${HOOK_DIR}/ulw-deactivate.sh" \
  "${missing_off_sid}" 2>&1)" || off_missing_rc=$?
assert_eq "ulw-off missing exact ID fails" "1" "${off_missing_rc}"
assert_contains "ulw-off missing exact ID reports no state" \
  "No state exists" "${off_missing_out}"
assert_eq "ulw-off missing exact ID creates no phantom session directory" "no" \
  "$([[ -e "${missing_off_dir}" ]] && printf yes || printf no)"

init_session "off-cleanup-failure" "coding"
cleanup_failure_dir="${TEST_HOME}/.claude/quality-pack/state/off-cleanup-failure"
cleanup_failure_state="${cleanup_failure_dir}/session_state.json"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="70"' \
  "${cleanup_failure_state}" >"${cleanup_failure_state}.tmp" \
  && mv "${cleanup_failure_state}.tmp" "${cleanup_failure_state}"
printf '%s\n' '70' >"${cleanup_failure_dir}/.ulw_active"
printf '%s\n' '{"agent_type":"quality-researcher"}' \
  >"${TEST_HOME}/cleanup-failure-pending.jsonl"
ln -s "${TEST_HOME}/cleanup-failure-pending.jsonl" \
  "${cleanup_failure_dir}/pending_agents.jsonl"
off_cleanup_rc=0
off_cleanup_out="$(bash "${HOOK_DIR}/ulw-deactivate.sh" \
  "off-cleanup-failure" 2>&1)" || off_cleanup_rc=$?
assert_eq "ulw-off untrusted transient converges" "0" \
  "${off_cleanup_rc}"
assert_contains "ulw-off untrusted transient reports exact session" \
  "session off-cleanup-failure" "${off_cleanup_out}"
assert_empty "ulw-off untrusted transient clears workflow" \
  "$(read_st "off-cleanup-failure" "workflow_mode")"
assert_eq "ulw-off untrusted transient closes enforcement" "0" \
  "$(read_st "off-cleanup-failure" "ulw_enforcement_active")"
assert_eq "ulw-off untrusted transient removes live symlink" "no" \
  "$([[ -e "${cleanup_failure_dir}/pending_agents.jsonl" \
        || -L "${cleanup_failure_dir}/pending_agents.jsonl" ]] \
    && printf yes || printf no)"
assert_eq "ulw-off untrusted transient preserves external target" \
  '{"agent_type":"quality-researcher"}' \
  "$(<"${TEST_HOME}/cleanup-failure-pending.jsonl")"
assert_eq "ulw-off untrusted transient retires session marker" "no" \
  "$([[ -e "${cleanup_failure_dir}/.ulw_active" \
        || -L "${cleanup_failure_dir}/.ulw_active" ]] \
    && printf yes || printf no)"
teardown_test

# -------------------------------------------------------
# ulw-off refuses a live subagent completion lease, then succeeds on retry
# -------------------------------------------------------
setup_test
init_session "off-summary-lease" "coding"
summary_lease_dir="${TEST_HOME}/.claude/quality-pack/state/off-summary-lease"
summary_lease_state="${summary_lease_dir}/session_state.json"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="71"' \
  "${summary_lease_state}" >"${summary_lease_state}.tmp" \
  && mv "${summary_lease_state}.tmp" "${summary_lease_state}"
printf '%s\n' '71' >"${summary_lease_dir}/.ulw_active"
sim_pre_agent_dispatch "off-summary-lease" "quality-researcher" \
  "research the exact lifecycle contract" >/dev/null
summary_claim_ready="${TEST_HOME}/summary-claim-ready"
summary_claim_release="${TEST_HOME}/summary-claim-release"
summary_claim_payload="$(jq -nc --arg sid "off-summary-lease" \
  --arg message $'Lifecycle research is complete.\nVERDICT: REPORT_READY' \
  '{session_id:$sid,agent_type:"quality-researcher",last_assistant_message:$message}')"
(
  printf '%s' "${summary_claim_payload}" \
    | env OMC_TEST_SUMMARY_CLAIM_READY_FILE="${summary_claim_ready}" \
      OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${summary_claim_release}" \
      OMC_DISCOVERED_SCOPE=off \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
) &
summary_claim_pid=$!
for _summary_claim_wait in $(seq 1 500); do
  [[ -f "${summary_claim_ready}" ]] && break
  kill -0 "${summary_claim_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "ulw-off lease: summary reaches post-claim barrier" "yes" \
  "$([[ -f "${summary_claim_ready}" ]] && printf yes || printf no)"
assert_eq "ulw-off lease: pending row carries a live incomplete claim" "1" \
  "$(jq -s '[.[] | select((.completion_claim_id // "") != "" and
      (.completion_claim_effects_complete // false) != true)] | length' \
    "${summary_lease_dir}/pending_agents.jsonl")"

summary_lease_off_rc=0
summary_lease_off_out="$(bash "${HOOK_DIR}/ulw-deactivate.sh" \
  "off-summary-lease" 2>&1)" || summary_lease_off_rc=$?
assert_eq "ulw-off lease: deactivation refuses a live claim" "1" \
  "${summary_lease_off_rc}"
assert_contains "ulw-off lease: refusal is explicit" \
  "could not clear transient state" "${summary_lease_off_out}"
assert_eq "ulw-off lease: failed attempt leaves enforcement active" "1" \
  "$(read_st "off-summary-lease" "ulw_enforcement_active")"

touch "${summary_claim_release}"
summary_claim_rc=0
wait "${summary_claim_pid}" || summary_claim_rc=$?
assert_eq "ulw-off lease: claimed summary finishes successfully" "0" \
  "${summary_claim_rc}"
summary_lease_summary_count=0
if [[ -f "${summary_lease_dir}/subagent_summaries.jsonl" ]]; then
  summary_lease_summary_count="$(jq -s \
    '[.[] | select(.agent_type == "quality-researcher")] | length' \
    "${summary_lease_dir}/subagent_summaries.jsonl")"
fi
assert_eq "ulw-off lease: summary publishes exactly once" "1" \
  "${summary_lease_summary_count}"
summary_lease_accepted_count=0
if [[ -f "${summary_lease_dir}/agent_completion_outcomes.jsonl" ]]; then
  summary_lease_accepted_count="$(jq -s \
    '[.[] | select(.agent_type == "quality-researcher" and .status == "accepted")] | length' \
    "${summary_lease_dir}/agent_completion_outcomes.jsonl")"
fi
assert_eq "ulw-off lease: accepted outcome publishes exactly once" "1" \
  "${summary_lease_accepted_count}"
assert_eq "ulw-off lease: completed summary consumes its claim row" "0" \
  "$(jq -s 'length' "${summary_lease_dir}/pending_agents.jsonl")"

summary_lease_retry_rc=0
summary_lease_retry_out="$(bash "${HOOK_DIR}/ulw-deactivate.sh" \
  "off-summary-lease" 2>&1)" || summary_lease_retry_rc=$?
assert_eq "ulw-off lease: retry succeeds after summary commit" "0" \
  "${summary_lease_retry_rc}"
assert_contains "ulw-off lease: retry reports exact session" \
  "session off-summary-lease" "${summary_lease_retry_out}"
assert_empty "ulw-off lease: retry clears workflow" \
  "$(read_st "off-summary-lease" "workflow_mode")"
assert_eq "ulw-off lease: retry closes enforcement" "0" \
  "$(read_st "off-summary-lease" "ulw_enforcement_active")"
teardown_test

# The reciprocal interleaving is fail-closed too: if an interval is forcibly
# closed and its claimed row removed while the completion is paused, the
# summary hook must revalidate after the barrier and publish no authoritative
# effect—not even an ignored outcome or an inline design/scope artifact.
setup_test
init_session "off-summary-forced-close" "coding"
forced_summary_dir="${TEST_HOME}/.claude/quality-pack/state/off-summary-forced-close"
forced_summary_state="${forced_summary_dir}/session_state.json"
jq '.ulw_enforcement_active="1" | .ulw_enforcement_generation="72"' \
  "${forced_summary_state}" >"${forced_summary_state}.tmp" \
  && mv "${forced_summary_state}.tmp" "${forced_summary_state}"
printf '%s\n' '72' >"${forced_summary_dir}/.ulw_active"
sim_pre_agent_dispatch "off-summary-forced-close" "frontend-developer" \
  "return a UI contract with one discovered finding" >/dev/null
forced_summary_ready="${TEST_HOME}/forced-summary-ready"
forced_summary_release="${TEST_HOME}/forced-summary-release"
forced_summary_payload="$(jq -nc --arg sid "off-summary-forced-close" \
  --arg message $'## Design Contract\n### Direction\nHigh-contrast utility UI.\nFINDINGS_JSON: [{"claim":"A sibling UI path also needs coverage","severity":"medium","category":"completeness"}]\nVERDICT: SHIP' \
  '{session_id:$sid,agent_type:"frontend-developer",last_assistant_message:$message}')"
(
  printf '%s' "${forced_summary_payload}" \
    | env OMC_TEST_SUMMARY_CLAIM_READY_FILE="${forced_summary_ready}" \
      OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${forced_summary_release}" \
      OMC_DISCOVERED_SCOPE=on \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
) &
forced_summary_pid=$!
for _forced_summary_wait in $(seq 1 500); do
  [[ -f "${forced_summary_ready}" ]] && break
  kill -0 "${forced_summary_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "forced close: summary reaches post-claim barrier" "yes" \
  "$([[ -f "${forced_summary_ready}" ]] && printf yes || printf no)"
assert_eq "forced close: barrier owns one incomplete claim" "1" \
  "$(jq -s '[.[] | select((.completion_claim_id // "") != "" and
      (.completion_claim_effects_complete // false) != true)] | length' \
    "${forced_summary_dir}/pending_agents.jsonl")"

jq '.ulw_enforcement_active="0" | .session_outcome="completed"' \
  "${forced_summary_state}" >"${forced_summary_state}.tmp" \
  && mv "${forced_summary_state}.tmp" "${forced_summary_state}"
rm -f "${forced_summary_dir}/pending_agents.jsonl" \
  "${forced_summary_dir}/.ulw_active"
touch "${forced_summary_release}"
forced_summary_rc=0
wait "${forced_summary_pid}" || forced_summary_rc=$?
assert_eq "forced close: stale claimed callback exits quietly" "0" \
  "${forced_summary_rc}"
forced_summary_count=0
[[ ! -f "${forced_summary_dir}/subagent_summaries.jsonl" ]] \
  || forced_summary_count="$(jq -s 'length' \
    "${forced_summary_dir}/subagent_summaries.jsonl")"
assert_eq "forced close: no summary side effect" "0" "${forced_summary_count}"
forced_outcome_count=0
[[ ! -f "${forced_summary_dir}/agent_completion_outcomes.jsonl" ]] \
  || forced_outcome_count="$(jq -s 'length' \
    "${forced_summary_dir}/agent_completion_outcomes.jsonl")"
assert_eq "forced close: no accepted or ignored outcome side effect" "0" \
  "${forced_outcome_count}"
assert_eq "forced close: no inline design contract side effect" "no" \
  "$([[ -e "${forced_summary_dir}/design_contract.md" ]] && printf yes || printf no)"
assert_eq "forced close: no discovered-scope side effect" "no" \
  "$([[ -e "${forced_summary_dir}/discovered_scope.jsonl" ]] && printf yes || printf no)"
assert_eq "forced close: terminal authority remains closed" "0" \
  "$(read_st "off-summary-forced-close" "ulw_enforcement_active")"
teardown_test

# -------------------------------------------------------
# Gap 8 (advisory-intent-preservation across compact + pretool-intent-guard):
# When the pre-compact prompt was non-execution, the compact handoff must emit
# an advisory-guard directive INSTEAD of the "keep momentum high" ULW directive,
# and a PreToolUse Bash guard must block destructive git/gh ops. This is the
# regression suite for the 2026-04-17 incident where a compact boundary lost
# advisory intent and Claude pushed unauthorized commits to a sibling repo.
# See feedback_advisory_means_no_edits memory for the originating incident.
# -------------------------------------------------------

# Helper: seed a state key on an already-initialized session. Intent-scoped
# compact tests need to flip task_intent away from the init_session default
# ("execution") before triggering the compact hooks.
set_intent() {
  local sid="$1" intent="$2" meta="${3:-}"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  jq --arg i "${intent}" --arg m "${meta}" \
    '. + {task_intent:$i} + (if $m != "" then {last_meta_request:$m} else {} end)' \
    "${state_dir}/session_state.json" > "${state_dir}/session_state.json.tmp" \
    && mv "${state_dir}/session_state.json.tmp" "${state_dir}/session_state.json"
}

# Helper: invoke the PreToolUse intent guard with a Bash command.
sim_pretool_bash() {
  local sid="$1" cmd="$2"
  run_hook "${HOOK_DIR}/pretool-intent-guard.sh" \
    "$(jq -nc --arg s "${sid}" --arg c "${cmd}" \
      '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},hook_event_name:"PreToolUse"}')"
}

# Gap 8a: advisory intent → compact → resume emits advisory guard + inlines meta_request
setup_test
setup_compact_tests
init_session "cg8a" "mixed"
set_intent "cg8a" "advisory" "what do you think of the landing page copy and CI setup?"
sim_pre_compact "cg8a"
sim_post_compact "cg8a" "auto" "Summary"
out_g8a="$(sim_session_start_compact "cg8a")"
assert_contains "gap8a: advisory intent triggers guard directive" "PRE-COMPACT INTENT WAS 'advisory'" "${out_g8a}"
assert_contains "gap8a: directive names forbidden ops" "Do NOT commit, push" "${out_g8a}"
# v1.21.0: Layer 1 directive was rewritten to drop the "wait for explicit
# authorization ('go ahead', 'implement', 'do it')" phrasing — the same
# permission-asking pattern the gate's reason text shed. Now asserts the
# new corrective shape (concrete-imperative template + FORBIDDEN cite).
assert_contains "gap8a: directive provides 'reply with:' imperative template" "reply with: implement the fix" "${out_g8a}"
assert_contains "gap8a: directive cites core.md FORBIDDEN" "FORBIDDEN" "${out_g8a}"
# Negative: directive must NOT contain the disturbing one-word-affirmation
# pattern. Same forbidden substrings as the pretool gate's reason text.
for forbidden_phrase in "say yes" "single yes" "reauthorize" "confirm with yes"; do
  if grep -qiF -- "${forbidden_phrase}" <<<"${out_g8a}"; then
    printf '  FAIL: gap8a: Layer 1 directive contains forbidden phrase: %s\n' "${forbidden_phrase}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
assert_contains "gap8a: meta_request inlined" "landing page copy and CI setup" "${out_g8a}"
# Guard directive must REPLACE the "keep momentum high" line, not supplement it.
if grep -q "keep momentum high" <<<"${out_g8a}"; then
  printf '  FAIL: gap8a: advisory intent should suppress the ULW momentum directive\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# Gap 8b: session_management intent also triggers guard directive
setup_test
setup_compact_tests
init_session "cg8b" "coding"
set_intent "cg8b" "session_management" "should we start a new session or keep going?"
sim_pre_compact "cg8b"
sim_post_compact "cg8b" "auto" "Summary"
out_g8b="$(sim_session_start_compact "cg8b")"
assert_contains "gap8b: session_management triggers guard" "PRE-COMPACT INTENT WAS 'session-management'" "${out_g8b}"
teardown_test

# Gap 8c: checkpoint intent also triggers guard directive
setup_test
setup_compact_tests
init_session "cg8c" "coding"
set_intent "cg8c" "checkpoint" "give me a checkpoint of what's done"
sim_pre_compact "cg8c"
sim_post_compact "cg8c" "auto" "Summary"
out_g8c="$(sim_session_start_compact "cg8c")"
assert_contains "gap8c: checkpoint triggers guard" "PRE-COMPACT INTENT WAS 'checkpoint'" "${out_g8c}"
teardown_test

# Gap 8d: execution intent (regression) still gets the momentum directive,
# not the guard. Explicit negative test — if this ever flips, ULW continuation
# is broken.
setup_test
setup_compact_tests
init_session "cg8d" "coding"
# init_session already sets task_intent=execution
sim_pre_compact "cg8d"
sim_post_compact "cg8d" "auto" "Summary"
out_g8d="$(sim_session_start_compact "cg8d")"
assert_contains "gap8d: execution intent gets momentum directive" "keep momentum high" "${out_g8d}"
if grep -q "PRE-COMPACT INTENT WAS" <<<"${out_g8d}"; then
  printf '  FAIL: gap8d: execution intent must NOT get the advisory guard directive\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown_test

# Gap 8e: PreToolUse guard BLOCKS git commit when intent is advisory
setup_test
setup_compact_tests
init_session "cg8e" "coding"
set_intent "cg8e" "advisory"
out_g8e="$(sim_pretool_bash "cg8e" "cd /tmp/somerepo && git commit -m 'fix typo'")"
assert_contains "gap8e: advisory + git commit → deny" "\"permissionDecision\":\"deny\"" "${out_g8e}"
assert_contains "gap8e: deny reason names the intent" "classified as 'advisory'" "${out_g8e}"
assert_eq "gap8e: block counter increments" "1" "$(read_st "cg8e" "pretool_intent_blocks")"
teardown_test

# Gap 8f: PreToolUse guard ALLOWS git status (read-only) under advisory
setup_test
setup_compact_tests
init_session "cg8f" "coding"
set_intent "cg8f" "advisory"
out_g8f="$(sim_pretool_bash "cg8f" "git status")"
if [[ -z "${out_g8f}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8f: git status must be allowed (got: %s)\n' "${out_g8f}" >&2
  fail=$((fail + 1))
fi
# Counter must not have incremented
counter="$(read_st "cg8f" "pretool_intent_blocks")"
if [[ -z "${counter}" ]] || [[ "${counter}" == "0" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8f: block counter should be 0 for read-only ops (got: %s)\n' "${counter}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8g: PreToolUse guard ALLOWS git commit when intent is execution
# Regression: this is the common case — never block under execution intent.
setup_test
setup_compact_tests
init_session "cg8g" "coding"
# intent=execution from init_session
set_agent_first_satisfied "cg8g"
out_g8g="$(sim_pretool_bash "cg8g" "git commit -m 'implement feature'")"
if [[ -z "${out_g8g}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8g: execution + git commit should pass through (got: %s)\n' "${out_g8g}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8h: PreToolUse guard blocks gh pr create under advisory
setup_test
setup_compact_tests
init_session "cg8h" "coding"
set_intent "cg8h" "advisory"
out_g8h="$(sim_pretool_bash "cg8h" "gh pr create --title 'new feature' --body 'adds X'")"
assert_contains "gap8h: advisory + gh pr create → deny" "\"permissionDecision\":\"deny\"" "${out_g8h}"
teardown_test

# Gap 8i: PreToolUse guard blocks a range of destructive git subcommands.
# One test per subcommand to catch regex regressions on specific patterns.
# Includes absolute-path bypasses (`/usr/bin/git`), plumbing verbs, branch
# rewriting, force-delete — expanded per quality-reviewer findings 1 and 2.
setup_test
setup_compact_tests
init_session "cg8i" "coding"
set_intent "cg8i" "advisory"
for cmd in \
  "git push origin main" \
  "git push --force-with-lease" \
  "git push --delete origin feature" \
  "git revert HEAD~1" \
  "git reset --hard HEAD~5" \
  "git rebase -i main" \
  "git cherry-pick abc123" \
  "git tag v1.0.0" \
  "git tag -i v1.0" \
  "git merge feature-branch" \
  "git am < patch.txt" \
  "git apply patch.txt" \
  "git branch -D old-feature" \
  "git branch --force main abc123" \
  "git switch -C main" \
  "git switch feature --force" \
  "git checkout -B main" \
  "git checkout --force main" \
  "git clean -fd" \
  "git update-ref refs/heads/main abc123" \
  "git symbolic-ref HEAD refs/heads/other" \
  "git filter-branch --tree-filter 'rm foo'" \
  "git replace abc123 def456" \
  "/usr/bin/git commit -m 'absolute path bypass attempt'" \
  "sudo git push origin main" \
  "cd /tmp/repo && git commit -m x" \
  "gh release create v1.0.0 --generate-notes" \
  "gh issue close 42" \
  "gh pr merge 123 --squash"; do
  out="$(sim_pretool_bash "cg8i" "${cmd}")"
  if grep -q "\"permissionDecision\":\"deny\"" <<<"${out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: gap8i: advisory + %s should be blocked (got: %s)\n' "${cmd}" "${out}" >&2
    fail=$((fail + 1))
  fi
done
teardown_test

# Gap 8m: Kill-switch honored — OMC_PRETOOL_INTENT_GUARD=false disables the guard.
# Excellence-reviewer finding #1: every comparable gate has a customization knob;
# this is the escape hatch for users whose workflow trips the classifier.
setup_test
setup_compact_tests
init_session "cg8m" "coding"
set_intent "cg8m" "advisory"
out_g8m="$(OMC_PRETOOL_INTENT_GUARD=false sim_pretool_bash "cg8m" "git commit -m 'should pass'")"
if [[ -z "${out_g8m}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8m: OMC_PRETOOL_INTENT_GUARD=false should disable guard (got: %s)\n' "${out_g8m}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8n: Release path — after the guard blocks, a fresh execution-framed
# UserPromptSubmit must reclassify task_intent to execution and let the next
# git commit through. This validates the recovery UX described in the denial
# message. Excellence-reviewer flagged this as an untested transition.
setup_test
setup_compact_tests
init_session "cg8n" "coding"
set_intent "cg8n" "advisory"
out_denied="$(sim_pretool_bash "cg8n" "git commit -m 'blocked'")"
assert_contains "gap8n: first commit under advisory is blocked" "\"permissionDecision\":\"deny\"" "${out_denied}"
# User replies with a clearly imperative prompt; the router reclassifies intent.
sim_user_prompt "cg8n" "implement the fix and commit it" >/dev/null
assert_eq "gap8n: intent reclassified to execution" "execution" "$(read_st "cg8n" "task_intent")"
set_agent_first_satisfied "cg8n"
out_allowed="$(sim_pretool_bash "cg8n" "git commit -m 'now allowed'")"
if [[ -z "${out_allowed}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8n: commit should pass after execution-framed reprompt (got: %s)\n' "${out_allowed}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8o: ulw-deactivate clears pretool_intent_blocks. Excellence-reviewer
# finding #3: the counter was being left behind on /ulw-off, leaking data
# into subsequent sessions.
setup_test
setup_compact_tests
init_session "cg8o" "coding"
set_intent "cg8o" "advisory"
sim_pretool_bash "cg8o" "git commit -m 'seed the counter'" >/dev/null
assert_eq "gap8o: counter seeded" "1" "$(read_st "cg8o" "pretool_intent_blocks")"
set_agent_first_satisfied "cg8o" "quality-planner"
# Deactivate — must clear the counter
printf '{}' | bash "${HOOK_DIR}/ulw-deactivate.sh" "cg8o" >/dev/null 2>&1 || true
assert_empty "gap8o: counter cleared by ulw-deactivate" "$(read_st "cg8o" "pretool_intent_blocks")"
assert_empty "gap8o: agent-first stamp cleared by ulw-deactivate" "$(read_st "cg8o" "agent_first_specialist_ts")"
teardown_test

# Gap 8l: PreToolUse guard allow-list edges — commands that look destructive
# but are read-only or local-reversible must pass through. Regression for
# reviewer finding #5: word-boundary regex drift could create false positives
# that silently block legitimate inspection work.
setup_test
setup_compact_tests
init_session "cg8l" "coding"
set_intent "cg8l" "advisory"
for cmd in \
  "git status" \
  "git log --oneline -20" \
  "git diff HEAD~1" \
  "git show abc123" \
  "git branch" \
  "git branch --list" \
  "git branch newbranch" \
  "git switch -c newbranch" \
  "git checkout -b newbranch" \
  "git checkout main" \
  "git merge-base HEAD main" \
  "git commit-tree abc123" \
  "git diff-tree HEAD" \
  "git stash push -m 'wip'" \
  "git stash pop" \
  "git fetch origin" \
  "git reset HEAD~1" \
  "git reset --soft HEAD~1" \
  "git reset --mixed HEAD~1" \
  "echo 'hello world'" \
  "ls -la" \
  "cat file.txt" \
  "my-git-tool commit" \
  "grep 'git commit' README.md" \
  "git log --grep='reset --hard'"; do
  out="$(sim_pretool_bash "cg8l" "${cmd}")"
  if [[ -z "${out}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: gap8l: read-only cmd [%s] should pass through but got: %s\n' "${cmd}" "${out}" >&2
    fail=$((fail + 1))
  fi
done
# Block counter must still be zero after only allow-list commands ran
counter_l="$(read_st "cg8l" "pretool_intent_blocks")"
if [[ -z "${counter_l}" ]] || [[ "${counter_l}" == "0" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8l: block counter should be 0 after allow-list ops (got: %s)\n' "${counter_l}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8j: PreToolUse guard bails without ULW sentinel (regression for
# fast-path exit). Removing the .ulw_active file must make the hook a no-op.
setup_test
setup_compact_tests
init_session "cg8j" "coding"
set_intent "cg8j" "advisory"
rm -f "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
out_g8j="$(sim_pretool_bash "cg8j" "git commit -m 'x'")"
if [[ -z "${out_g8j}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8j: no ULW sentinel → guard must exit 0 silently (got: %s)\n' "${out_g8j}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8k: PreToolUse guard allows edit tools under advisory intent. The same
# hook blocks edit tools for execution until the agent-first floor is met.
setup_test
setup_compact_tests
init_session "cg8k" "coding"
set_intent "cg8k" "advisory"
out_g8k="$(run_hook "${HOOK_DIR}/pretool-intent-guard.sh" \
  "$(jq -nc --arg s "cg8k" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/tmp/x",old_string:"a",new_string:"b"},hook_event_name:"PreToolUse"}')")"
if [[ -z "${out_g8k}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8k: non-Bash tool must pass through (got: %s)\n' "${out_g8k}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8t: execution mutations are agent-first. Read-only inspection is
# allowed before specialists; Edit/Bash mutations block until a qualifying
# shaping specialist (not a post-hoc reviewer) returns.
setup_test
setup_compact_tests
init_session "cg8t" "coding"
out_g8t_ro="$(sim_pretool_bash "cg8t" "git status 2>/dev/null")"
assert_eq "gap8t: read-only Bash allowed before agent-first specialist" "" "${out_g8t_ro}"
out_g8t_edit1="$(run_hook "${HOOK_DIR}/pretool-intent-guard.sh" \
  "$(jq -nc --arg s "cg8t" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/tmp/x",old_string:"a",new_string:"b"},hook_event_name:"PreToolUse"}')")"
assert_contains "gap8t: Edit before specialist is denied" "\"permissionDecision\":\"deny\"" "${out_g8t_edit1}"
assert_contains "gap8t: deny reason names agent-first" "Agent-first gate" "${out_g8t_edit1}"
for post_hoc_reviewer in quality-reviewer rigor-reviewer; do
  run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
    "$(jq -nc --arg s "cg8t" --arg a "${post_hoc_reviewer}" '{session_id:$s,agent_type:$a,last_assistant_message:"Clean.\nVERDICT: CLEAN"}')"
done
assert_empty "gap8t: post-hoc reviewers do not satisfy agent-first floor" "$(read_st "cg8t" "agent_first_specialist_ts")"
run_hook "${HOOK_DIR}/record-subagent-summary.sh" \
  "$(jq -nc --arg s "cg8t" '{session_id:$s,agent_type:"quality-planner",last_assistant_message:"Plan ready.\nVERDICT: PLAN_READY"}')"
assert_eq "gap8t: quality-planner stamps agent-first type" "quality-planner" "$(read_st "cg8t" "agent_first_specialist_type")"
out_g8t_edit2="$(run_hook "${HOOK_DIR}/pretool-intent-guard.sh" \
  "$(jq -nc --arg s "cg8t" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/tmp/x",old_string:"a",new_string:"b"},hook_event_name:"PreToolUse"}')")"
assert_eq "gap8t: Edit allowed after qualifying specialist" "" "${out_g8t_edit2}"
assert_eq "gap8t: first mutation tool recorded" "Edit" "$(read_st "cg8t" "first_mutation_tool")"
teardown_test

# Gap 8u: Stop-hook backstop catches stale wiring where an edit was recorded
# but no agent-first specialist returned.
setup_test
setup_compact_tests
init_session "cg8u" "coding"
run_hook "${HOOK_DIR}/mark-edit.sh" \
  "$(jq -nc --arg s "cg8u" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/tmp/backstop.ts"}}')"
out_g8u="$(run_hook "${HOOK_DIR}/stop-guard.sh" \
  "$(jq -nc --arg s "cg8u" '{session_id:$s,stop_hook_active:false,last_assistant_message:"done"}')")"
assert_contains "gap8u: Stop backstop blocks missing agent-first specialist" "Agent-first gate" "${out_g8u}"
teardown_test

# Gap 8p: guard blocks destructive commands even when git top-level flags
# sit between `git` and the verb. Reviewer finding: the original regex
# required the verb adjacent to `git`, so `git -c user.email=x commit`,
# `git --no-pager commit`, and `git --git-dir=/path commit` all slipped
# through — exactly the "work around by config override" escape hatch the
# guard is supposed to close. Each case covers one flag shape.
setup_test
setup_compact_tests
init_session "cg8p" "coding"
set_intent "cg8p" "advisory"
for cmd in \
  "git -c user.email=x commit -m 'bypass attempt'" \
  "git -c commit.gpgsign=false commit" \
  "git --no-pager commit" \
  "git --git-dir=/tmp/repo commit" \
  "git --git-dir /tmp/repo commit" \
  "git --work-tree /tmp commit" \
  "git --exec-path /usr/libexec/git-core commit" \
  "git --namespace foo commit" \
  "git --super-prefix sub/ commit" \
  "git --config-env foo=BAR commit" \
  "git --attr-source HEAD commit" \
  "git --attr-source=HEAD commit" \
  "git -C /tmp/repo commit -m x" \
  "git -c foo=bar -c baz=qux push origin main" \
  "/usr/bin/git --no-pager commit" \
  "sudo git -c user.email=x commit" \
  "git -c commit.gpgsign=false -c tag.gpgsign=false tag v9.9.9" \
  "git --no-pager --git-dir /tmp push"; do
  out="$(sim_pretool_bash "cg8p" "${cmd}")"
  if grep -q "\"permissionDecision\":\"deny\"" <<<"${out}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: gap8p: flag-injection bypass [%s] must be blocked (got: %s)\n' "${cmd}" "${out}" >&2
    fail=$((fail + 1))
  fi
done
teardown_test

# Gap 8q: guard allow-list — recovery flags and dry-run/list variants of
# otherwise-destructive verbs must pass through. Reviewer finding: the
# original regex blocked `git rebase --abort` and `git push --dry-run`,
# making it impossible for the model to recover from a merge/rebase
# conflict or report what a push would do while under advisory intent.
setup_test
setup_compact_tests
init_session "cg8q" "coding"
set_intent "cg8q" "advisory"
for cmd in \
  "git rebase --abort" \
  "git rebase --continue" \
  "git rebase --skip" \
  "git rebase --quit" \
  "git merge --abort" \
  "git merge --continue" \
  "git cherry-pick --abort" \
  "git cherry-pick --continue" \
  "git revert --abort" \
  "git am --abort" \
  "git push --dry-run origin main" \
  "git push -n" \
  "git commit --dry-run" \
  "git apply --check patch.diff" \
  "git apply --stat patch.diff" \
  "git apply --numstat patch.diff" \
  "git apply --summary patch.diff" \
  "git tag -l" \
  "git tag --list" \
  "git tag --list 'v1.*'" \
  "git tag --sort=-creatordate" \
  "git tag --sort -creatordate" \
  "git tag --contains HEAD" \
  "git tag --no-contains HEAD" \
  "git tag --points-at v1.13.0" \
  "git tag --merged main" \
  "git tag --no-merged main" \
  "git tag -n5" \
  "git tag -n" \
  "git tag --column" \
  "git tag --format='%(refname)'" \
  "git tag -l -i 'v1.*'"; do
  out="$(sim_pretool_bash "cg8q" "${cmd}")"
  if [[ -z "${out}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: gap8q: allow-list [%s] must pass through (got: %s)\n' "${cmd}" "${out}" >&2
    fail=$((fail + 1))
  fi
done
# Block counter must still be zero after only allow-list commands
counter_q="$(read_st "cg8q" "pretool_intent_blocks")"
if [[ -z "${counter_q}" ]] || [[ "${counter_q}" == "0" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8q: counter must stay 0 after allow-list ops (got: %s)\n' "${counter_q}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8r: compound-command correctness — an allowed segment chained with a
# destructive segment must still deny on the destructive segment. Regression
# guard: the allow-list must not short-circuit the whole line.
setup_test
setup_compact_tests
init_session "cg8r" "coding"
set_intent "cg8r" "advisory"
# Allow-variant + destructive via && → DENY
out_r1="$(sim_pretool_bash "cg8r" "git rebase --abort && git push --force")"
assert_contains "gap8r: rebase --abort && push --force still blocks" "\"permissionDecision\":\"deny\"" "${out_r1}"
# Allow-variant + flag-injection bypass via && → DENY
out_r2="$(sim_pretool_bash "cg8r" "git tag --list && git -c user.email=x commit")"
assert_contains "gap8r: tag --list && -c commit still blocks" "\"permissionDecision\":\"deny\"" "${out_r2}"
# Destructive via pipe → DENY (`|` also splits)
out_r3="$(sim_pretool_bash "cg8r" "echo foo | git commit -F -")"
assert_contains "gap8r: destructive after pipe still blocks" "\"permissionDecision\":\"deny\"" "${out_r3}"
# Compound where both segments are safe → ALLOW (no false deny on mixed-safe compound)
out_r4="$(sim_pretool_bash "cg8r" "git rebase --abort && git status")"
if [[ -z "${out_r4}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8r: recovery && status must ALLOW (got: %s)\n' "${out_r4}" >&2
  fail=$((fail + 1))
fi
teardown_test

# Gap 8s: verbose-first / terse-repeat denial reason. First block emits the
# full 9-line coaching text; subsequent blocks in the same session compress
# to a 2-line reminder so heavy blocking does not flood the conversation.
# Mirrors the stop-guard block-1-verbose / block-2+-terse pattern.
setup_test
setup_compact_tests
init_session "cg8s" "coding"
set_intent "cg8s" "advisory"

out_s1="$(sim_pretool_bash "cg8s" "git commit -m test")"
# v1.34.1+ (X-008): block-1 message tightened to recovery-first
# structure ("Recovery options:" + → If you intended / → If misclassified
# / → Bypass). The pre-fix verbose form ("What to do:" / "(a) Deliver"
# / "What NOT to do" section headers) was the design-lens-flagged bloat;
# the substance survives in the new form (concrete imperative + ulw-skip
# + puppeteering rule) but the structure is leaner. Block-2 is the same
# tighter shape minus the recovery options.
assert_contains "gap8s: first block blocks" "\"permissionDecision\":\"deny\"" "${out_s1}"
assert_contains "gap8s: first block has Recovery options header" "Recovery options:" "${out_s1}"
assert_contains "gap8s: first block names → If misclassified path" "If misclassified" "${out_s1}"
assert_contains "gap8s: first block names → Bypass path with /ulw-skip" "/ulw-skip" "${out_s1}"
assert_contains "gap8s: first block proposes concrete imperative" "concrete imperative" "${out_s1}"

counter_s1="$(read_st "cg8s" "pretool_intent_blocks")"
if [[ "${counter_s1}" == "1" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8s: after first block, pretool_intent_blocks should be 1 (got: %s)\n' "${counter_s1}" >&2
  fail=$((fail + 1))
fi

out_s2="$(sim_pretool_bash "cg8s" "git push origin main")"
# Second block should still deny...
assert_contains "gap8s: second block blocks" "\"permissionDecision\":\"deny\"" "${out_s2}"
# ...but should NOT contain the verbose coaching text from block-1
# (the lengthy Recovery-options block, the "concrete imperative" +
# "puppeteering" preamble).
if ! printf '%s' "${out_s2}" | grep -q "Recovery options:"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8s: second block must be terse (unexpected "Recovery options:" preamble)\n' >&2
  fail=$((fail + 1))
fi
if ! printf '%s' "${out_s2}" | grep -q "puppeteering"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8s: second block must be terse (unexpected "puppeteering" preamble)\n' >&2
  fail=$((fail + 1))
fi
# ...and should include a block-count marker so the user sees repeats.
assert_contains "gap8s: second block surfaces gate counter" "block 2" "${out_s2}"

counter_s2="$(read_st "cg8s" "pretool_intent_blocks")"
if [[ "${counter_s2}" == "2" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8s: after second block, pretool_intent_blocks should be 2 (got: %s)\n' "${counter_s2}" >&2
  fail=$((fail + 1))
fi

# Third block also terse, with "block 3"
out_s3="$(sim_pretool_bash "cg8s" "git reset --hard HEAD~1")"
assert_contains "gap8s: third block blocks" "\"permissionDecision\":\"deny\"" "${out_s3}"
assert_contains "gap8s: third block surfaces gate counter" "block 3" "${out_s3}"
if ! printf '%s' "${out_s3}" | grep -q "What to do:"; then
  pass=$((pass + 1))
else
  printf '  FAIL: gap8s: third block must be terse (unexpected verbose text)\n' >&2
  fail=$((fail + 1))
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


# -------------------------------------------------------
# Planner VERDICT contract (v1.14.0): record-plan.sh
# parses VERDICT: PLAN_READY|NEEDS_CLARIFICATION|BLOCKED
# and writes plan_verdict to session state.
# -------------------------------------------------------
printf '\nPlanner VERDICT contract:\n'

setup_test
init_session "pv1"
sim_planner "pv1" "quality-planner" "Plan covers auth, API, schema.

VERDICT: PLAN_READY"
assert_eq "planner(PLAN_READY): plan_verdict set" "PLAN_READY" "$(read_st "pv1" "plan_verdict")"
assert_eq "planner(PLAN_READY): has_plan true" "true" "$(read_st "pv1" "has_plan")"
assert_eq "planner(PLAN_READY): plan_agent recorded" "quality-planner" "$(read_st "pv1" "plan_agent")"
teardown_test

setup_test
init_session "pv2"
sim_planner "pv2" "prometheus" "Need user input on rate-limit policy.

VERDICT: NEEDS_CLARIFICATION"
assert_eq "planner(NEEDS_CLARIFICATION): plan_verdict set" "NEEDS_CLARIFICATION" "$(read_st "pv2" "plan_verdict")"
assert_eq "planner(NEEDS_CLARIFICATION): has_plan false" "false" "$(read_st "pv2" "has_plan")"
teardown_test

setup_test
init_session "pv3"
sim_planner "pv3" "quality-planner" "Cannot plan without database schema decision.

VERDICT: BLOCKED"
assert_eq "planner(BLOCKED): plan_verdict set" "BLOCKED" "$(read_st "pv3" "plan_verdict")"
teardown_test

setup_test
init_session "pv4"
# No VERDICT line: backward-compat default = PLAN_READY
sim_planner "pv4" "quality-planner" "Step 1. Implement.
Step 2. Test."
assert_eq "planner(no VERDICT): plan_verdict defaults to PLAN_READY" "PLAN_READY" "$(read_st "pv4" "plan_verdict")"
assert_eq "planner(no VERDICT): has_plan still true (legacy compat)" "true" "$(read_st "pv4" "has_plan")"
teardown_test

# Bash edit-clock producer coverage: a real Bash mutation must enter the same
# review/verification path as Edit/Write, never the D-001 "no edits" release.
setup_test
unset OMC_AGENT_FIRST_GATE
init_session "bash-edit-stop"
work="${TEST_HOME}/work"
mkdir -p "${work}"
printf 'changed\n' > "${work}/app.js"
run_hook "${HOOK_DIR}/posttool-dispatch.sh" \
  "$(jq -nc --arg cwd "${work}" '{
    session_id:"bash-edit-stop",tool_name:"Bash",tool_use_id:"tu-bash-edit",cwd:$cwd,
    tool_input:{command:"printf changed > app.js"},tool_response:{exit_code:0}
  }')" >/dev/null
assert_not_empty "Bash mutation records last_code_edit_ts" "$(read_st "bash-edit-stop" "last_code_edit_ts")"
output="$(sim_stop "bash-edit-stop" "Done.")"
assert_contains "Bash mutation enters quality gate instead of no-edit release" '"decision":"block"' "${output}"
assert_not_contains "Bash mutation is not marked released" 'released' "$(read_st "bash-edit-stop" "session_outcome")"
teardown_test

# v1.34.1+ (data-lens D-001): session_outcome must be written on every
# clean release path (not just the all-gates-pass `completed` exit). The
# pre-fix shape defaulted unwritten outcomes to "abandoned" via the sweep
# JSON field-merge, which made 100% of cross-session session_summary.jsonl
# rows look like model abandonments — the metric a user would naturally
# check first to evaluate the harness was wrong by construction.

# T-D001-A: stop with no edits writes session_outcome=released.
# init_session defaults: task_intent=execution, task_domain=coding,
# no last_edit_ts → stop-guard hits the "no edits" early-exit path
# (stop-guard.sh:383-388 in v1.34.1+).
setup_test
init_session "ow1"
sim_stop "ow1" "Done — no edits needed."
outcome="$(read_st "ow1" "session_outcome")"
assert_eq "stop with no edits writes outcome=released" "released" "${outcome}"
teardown_test

# T-D001-B: advisory task that ends without fresh edits writes outcome=released.
# Override task_intent to advisory; set advisory_verify ts so the advisory
# gate doesn't block (otherwise we hit a different code path).
setup_test
init_session "ow2"
state_file="${TEST_HOME}/.claude/quality-pack/state/ow2/session_state.json"
jq '. + {task_intent:"advisory", last_user_prompt_ts:"1000", last_advisory_verify_ts:"1001"}' \
  "${state_file}" > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"
sim_stop "ow2" "Here is my recommendation."
outcome="$(read_st "ow2" "session_outcome")"
assert_eq "advisory clean exit writes outcome=released" "released" "${outcome}"
teardown_test


printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
