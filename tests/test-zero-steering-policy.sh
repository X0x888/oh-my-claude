#!/usr/bin/env bash
# test-zero-steering-policy.sh — focused regression coverage for the
# adaptive zero-steering posture added to support minimal-prompt real-work
# shipping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_HOME="$(mktemp -d -t zero-steering-home-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
TEST_PROJECT="${TEST_HOME}/project"
mkdir -p "${TEST_HOME}/.claude/quality-pack" "${TEST_STATE_ROOT}" "${TEST_PROJECT}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${TEST_HOME}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain=%q\n    actual=%q\n' "${label}" "${needle}" "${haystack:0:500}" >&2
    fail=$((fail + 1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected empty\n    actual=%q\n' "${label}" "${actual:0:500}" >&2
    fail=$((fail + 1))
  fi
}

write_session_json() {
  local sid="$1" json="$2"
  mkdir -p "${TEST_STATE_ROOT}/${sid}"
  printf '%s\n' "${json}" > "${TEST_STATE_ROOT}/${sid}/session_state.json"
}

run_router() {
  local sid="$1" prompt="$2"
  shift 2
  local env_args=("$@")
  local hook_json
  hook_json="$(jq -nc --arg sid "${sid}" --arg p "${prompt}" --arg cwd "${TEST_PROJECT}" \
    '{session_id:$sid,prompt:$p,cwd:$cwd}')"

  (
    cd "${TEST_PROJECT}" || exit 1
    HOME="${TEST_HOME}" \
      STATE_ROOT="${TEST_STATE_ROOT}" \
      env ${env_args[@]+"${env_args[@]}"} \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      <<<"${hook_json}" 2>/dev/null || true
  )
}

run_stop_guard() {
  local sid="$1"
  shift
  local env_args=("$@")
  local msg hook_json
  msg=$'**Changed.** Completed the requested work.\n\n**Verification.** Existing verification remains current.\n\n**Next.** Done.'
  hook_json="$(jq -nc --arg sid "${sid}" --arg msg "${msg}" \
    '{session_id:$sid,stop_hook_active:"false",last_assistant_message:$msg}')"

  (
    cd "${TEST_PROJECT}" || exit 1
    HOME="${TEST_HOME}" \
      STATE_ROOT="${TEST_STATE_ROOT}" \
      env ${env_args[@]+"${env_args[@]}"} \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" \
      <<<"${hook_json}" 2>/dev/null || true
  )
}

read_state_key() {
  local sid="$1" key="$2"
  jq -r --arg k "${key}" '.[$k] // ""' "${TEST_STATE_ROOT}/${sid}/session_state.json" 2>/dev/null || true
}

printf 'Test 1: risk classifier marks broad real-work prompt as high risk\n'
assert_eq "broad repo eval risk" "high" \
  "$(classify_task_risk_tier "ulw comprehensively evaluate this project and ship the highest leverage improvements" "execution" "mixed")"
assert_eq "small typo risk" "low" \
  "$(classify_task_risk_tier "ulw fix a small typo in README" "execution" "writing")"

printf 'Test 2: router persists zero-steering policy and risk tier\n'
sid="zs-router-${RANDOM}"
router_out="$(run_router "${sid}" "ulw comprehensively evaluate this project and ship the highest leverage improvements" OMC_QUALITY_POLICY=zero_steering)"
assert_eq "router policy persisted" "zero_steering" "$(read_state_key "${sid}" "quality_policy")"
assert_eq "router risk persisted" "high" "$(read_state_key "${sid}" "task_risk_tier")"
assert_contains "router emits zero-steering directive" "ZERO-STEERING POLICY" "${router_out}"

printf 'Test 3: balanced scorecard mode still releases with scorecard after cap\n'
sid="zs-scorecard-${RANDOM}"
write_session_json "${sid}" '{
  "workflow_mode":"ultrawork",
  "task_intent":"execution",
  "task_domain":"coding",
  "task_risk_tier":"high",
  "last_edit_ts":"1000",
  "last_code_edit_ts":"1000",
  "last_user_prompt_ts":"900",
  "stop_guard_blocks":"3"
}'
out="$(run_stop_guard "${sid}" OMC_QUALITY_POLICY=balanced OMC_GUARD_EXHAUSTION_MODE=scorecard)"
assert_eq "balanced exhaustion does not hard-block" "" "$(jq -r '.decision // ""' <<<"${out}" 2>/dev/null || true)"
assert_contains "balanced exhaustion emits scorecard" "QUALITY SCORECARD" "${out}"

printf 'Test 4: zero-steering keeps serious exhausted gates blocking\n'
sid="zs-block-${RANDOM}"
write_session_json "${sid}" '{
  "workflow_mode":"ultrawork",
  "task_intent":"execution",
  "task_domain":"coding",
  "task_risk_tier":"high",
  "last_edit_ts":"1000",
  "last_code_edit_ts":"1000",
  "last_user_prompt_ts":"900",
  "stop_guard_blocks":"3"
}'
out="$(run_stop_guard "${sid}" OMC_QUALITY_POLICY=zero_steering OMC_GUARD_EXHAUSTION_MODE=scorecard)"
assert_eq "zero-steering exhaustion hard-blocks" "block" "$(jq -r '.decision // ""' <<<"${out}")"
assert_contains "zero-steering block names policy escape hatch" "quality_policy=balanced" "${out}"

printf 'Test 5: high-risk advisory over code requires multiple evidence points\n'
sid="zs-advisory-${RANDOM}"
write_session_json "${sid}" '{
  "workflow_mode":"ultrawork",
  "task_intent":"advisory",
  "task_domain":"coding",
  "task_risk_tier":"high",
  "last_user_prompt_ts":"1000",
  "last_advisory_verify_ts":"1001",
  "advisory_evidence_count":"1"
}'
out="$(run_stop_guard "${sid}" OMC_QUALITY_POLICY=balanced)"
assert_eq "advisory evidence gate blocks" "block" "$(jq -r '.decision // ""' <<<"${out}")"
assert_contains "advisory evidence reason" "Advisory evidence gate" "${out}"

printf 'Test 6: advisory evidence gate clears at required breadth\n'
sid="zs-advisory-clear-${RANDOM}"
write_session_json "${sid}" '{
  "workflow_mode":"ultrawork",
  "task_intent":"advisory",
  "task_domain":"coding",
  "task_risk_tier":"high",
  "last_user_prompt_ts":"1000",
  "last_advisory_verify_ts":"1001",
  "advisory_evidence_count":"2"
}'
out="$(run_stop_guard "${sid}" OMC_QUALITY_POLICY=balanced)"
assert_empty "advisory evidence breadth allows clean advisory stop" "${out}"

printf 'Test 7: zero-steering high-risk plans require metis even when global gate flag is off\n'
sid="zs-metis-${RANDOM}"
now="$(date +%s)"
last_edit=$((now - 60))
write_session_json "${sid}" "$(jq -nc \
  --arg last_edit "${last_edit}" \
  '{
    workflow_mode:"ultrawork",
    task_intent:"execution",
    task_domain:"coding",
    task_risk_tier:"high",
    has_plan:"true",
    plan_complexity_high:"0",
    plan_ts:"1000",
    plan_complexity_signals:"risk=high",
    last_edit_ts:$last_edit,
    last_code_edit_ts:$last_edit,
    last_review_ts:$last_edit,
    last_verify_ts:$last_edit,
    last_verify_outcome:"passed",
    last_verify_confidence:"70",
    last_verify_scope:"full",
    last_excellence_review_ts:$last_edit,
    review_had_findings:"false"
  }')"
printf 'src/app.ts\n' > "${TEST_STATE_ROOT}/${sid}/edited_files.log"
out="$(run_stop_guard "${sid}" OMC_QUALITY_POLICY=zero_steering OMC_METIS_ON_PLAN_GATE=off)"
assert_eq "zero-steering metis gate blocks" "block" "$(jq -r '.decision // ""' <<<"${out}")"
assert_contains "zero-steering metis gate reason" "Metis-on-plan gate" "${out}"

printf '\nZero-steering policy tests: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
