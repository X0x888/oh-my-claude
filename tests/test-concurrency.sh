#!/usr/bin/env bash
#
# test-concurrency.sh — stress-test with_state_lock and with_state_lock_batch
# under concurrent writers.
#
# The hook scripts rely on these primitives to serialize read-modify-write
# sequences against parallel PostToolUse / SubagentStop events. Without a
# test that forks real processes, a regression in the lock primitive would
# go unnoticed until a user hits a dropped counter in production.
#
# Each block sets up a fresh state directory, forks N background writers,
# waits for all of them, and asserts that no update was lost.
#
# Count: 30 concurrent writers is enough to reliably interleave on a single
# developer machine without making the test slow. Lower counts would miss
# races; higher counts would just spend time and not catch more bugs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_STATE_ROOT}"
export SESSION_ID="test-concurrency"
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

reset_state() {
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  printf '{}\n' > "${state_file}"
}

# ===========================================================================
# Test 1: with_state_lock serializes read-modify-write on a shared counter.
#
# The exact pattern used by record-advisory-verification.sh's
# _increment_stall_counter and mark-edit.sh's _increment_edit_counter.
# ===========================================================================
printf 'with_state_lock serializes read-modify-write:\n'

reset_state
write_state "counter" "0"

WRITERS=30

_inc_counter() {
  local c
  c="$(read_state "counter")"
  c="${c:-0}"
  # Small pause inside the critical section to make a race more likely
  # if the lock were absent. With the lock, this pause cannot cause a
  # lost update — the lock blocks other writers until we're done.
  if command -v perl >/dev/null 2>&1; then
    perl -e 'select(undef,undef,undef,0.001)' 2>/dev/null || true
  fi
  write_state "counter" "$((c + 1))"
}

for _ in $(seq 1 "${WRITERS}"); do
  ( with_state_lock _inc_counter ) &
done
wait

final="$(read_state "counter")"
assert_eq "counter equals writer count (${WRITERS})" "${WRITERS}" "${final}"

# ===========================================================================
# Test 2: with_state_lock_batch preserves all writes under contention.
#
# The pattern used by mark-edit.sh's batched writes. Each writer writes a
# unique key; afterwards every key must be present with the value we set.
# Without the lock, overlapping jq/mv sequences can drop keys.
# ===========================================================================
printf 'with_state_lock_batch preserves writes under contention:\n'

reset_state

for i in $(seq 1 "${WRITERS}"); do
  ( with_state_lock_batch "batch_key_${i}" "value_${i}" ) &
done
wait

lost=0
for i in $(seq 1 "${WRITERS}"); do
  v="$(read_state "batch_key_${i}")"
  if [[ "${v}" != "value_${i}" ]]; then
    lost=$((lost + 1))
  fi
done
assert_eq "no key lost across ${WRITERS} concurrent batches" "0" "${lost}"

# ===========================================================================
# Test 3: mixed workload — single-key writers + batch writers.
#
# Simulates the real hook mix: mark-edit.sh (batch) racing with
# record-advisory-verification.sh (single-key via with_state_lock).
# After all writers finish, the counter must equal the writer count AND
# every batch key must be present.
# ===========================================================================
printf 'mixed single and batch writers cooperate under lock:\n'

reset_state
write_state "counter" "0"

for i in $(seq 1 "${WRITERS}"); do
  if (( i % 2 == 0 )); then
    ( with_state_lock _inc_counter ) &
  else
    ( with_state_lock_batch "mixed_key_${i}" "mixed_${i}" ) &
  fi
done
wait

expected_counter=$((WRITERS / 2))
final_counter="$(read_state "counter")"
assert_eq "counter equals even-indexed writer count (${expected_counter})" \
  "${expected_counter}" "${final_counter}"

missing_keys=0
for i in $(seq 1 "${WRITERS}"); do
  if (( i % 2 == 1 )); then
    v="$(read_state "mixed_key_${i}")"
    if [[ "${v}" != "mixed_${i}" ]]; then
      missing_keys=$((missing_keys + 1))
    fi
  fi
done
assert_eq "all odd-indexed batch keys present" "0" "${missing_keys}"

# ===========================================================================
# Test 4: metrics lock serializes agent metric writes.
#
# record_agent_metric is backgrounded (&) from record-reviewer.sh on every
# reviewer SubagentStop. If a user dispatches 5 reviewers in parallel, 5
# backgrounded processes compete for the agent-metrics file. The internal
# with_metrics_lock must serialize them or we lose invocation counts.
# ===========================================================================
printf 'with_metrics_lock serializes concurrent record_agent_metric:\n'

METRICS_TMP="$(mktemp -d)"
export _AGENT_METRICS_FILE="${METRICS_TMP}/agent-metrics.json"
export _AGENT_METRICS_LOCK="${METRICS_TMP}/.agent-metrics.lock"
printf '{}' > "${_AGENT_METRICS_FILE}"

METRIC_WRITERS=20
for _ in $(seq 1 "${METRIC_WRITERS}"); do
  ( record_agent_metric "concurrency-test-agent" "clean" 80 ) &
done
wait

invocations="$(jq -r '.agents["concurrency-test-agent"].invocations // 0' "${_AGENT_METRICS_FILE}")"
assert_eq "agent metric invocations equal writer count (${METRIC_WRITERS})" \
  "${METRIC_WRITERS}" "${invocations}"

rm -rf "${METRICS_TMP}"

# ===========================================================================
# Test 5: concurrent planner completions keep artifact and state paired.
#
# SubagentStop events can finish together. The Markdown plan and plan_agent /
# plan_revision metadata must be committed under one writer lock; otherwise the
# last file writer can differ from the last state writer.
# ===========================================================================
printf 'record-plan keeps concurrent artifact/state writes consistent:\n'

reset_state
PLAN_WRITERS=16
RECORD_PLAN="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh"
plan_pids=()
for i in $(seq 1 "${PLAN_WRITERS}"); do
  payload="$(jq -nc --arg sid "${SESSION_ID}" --arg agent "planner-${i}" \
    --arg msg "PLAN_BODY_${i}\nVERDICT: PLAN_READY" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$msg}')"
  ( printf '%s' "${payload}" | STATE_ROOT="${TEST_STATE_ROOT}" bash "${RECORD_PLAN}" ) &
  plan_pids+=("$!")
done
plan_hook_failures=0
for plan_pid in "${plan_pids[@]}"; do
  wait "${plan_pid}" || plan_hook_failures=$((plan_hook_failures + 1))
done

plan_revision="$(read_state "plan_revision")"
plan_agent="$(read_state "plan_agent")"
plan_file="$(session_file "current_plan.md")"
file_agent="$(sed -n '1s/^# Plan from //p' "${plan_file}")"
body_index="${plan_agent#planner-}"
body_matches=0
if grep -Fq "PLAN_BODY_${body_index}" "${plan_file}"; then
  body_matches=1
fi
assert_eq "all concurrent planner hooks publish successfully" "0" "${plan_hook_failures}"
assert_eq "all concurrent plans increment revision" "${PLAN_WRITERS}" "${plan_revision}"
assert_eq "current_plan.md header matches plan_agent state" "${plan_agent}" "${file_agent}"
assert_eq "current_plan.md body matches plan_agent state" "1" "${body_matches}"

# ===========================================================================
# Test 5b: authoritative plan publication gets its dedicated wait budget.
#
# Force six failed lock claims. The generic two-attempt budget would drop this
# callback; record-plan's bounded durable-evidence budget must keep polling and
# publish exactly once. This avoids a wall-clock sleep and pins the override
# independently from the 16-writer scheduler stress above.
# ===========================================================================
printf 'record-plan uses the durable publication lock budget:\n'

reset_state
rm -f "${plan_file}"
plan_budget_shim="${TEST_STATE_ROOT}/plan-budget-shim"
plan_budget_count="${TEST_STATE_ROOT}/plan-budget-count"
mkdir -p "${plan_budget_shim}"
printf '0\n' >"${plan_budget_count}"
printf '%s\n' \
  '#!/bin/sh' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'case "${dest}" in' \
  '  */.state.lock.owner)' \
  '    count="$(cat "${OMC_PLAN_BUDGET_COUNT}" 2>/dev/null || printf 0)"' \
  '    count=$((count + 1))' \
  '    printf "%s\n" "${count}" >"${OMC_PLAN_BUDGET_COUNT}"' \
  '    if [ "${count}" -le 6 ]; then exit 1; fi' \
  '    ;;' \
  'esac' \
  'exec /bin/ln "$@"' \
  >"${plan_budget_shim}/ln"
chmod +x "${plan_budget_shim}/ln"
plan_budget_payload="$(jq -nc --arg sid "${SESSION_ID}" \
  --arg msg $'PLAN_BODY_BUDGET\nVERDICT: PLAN_READY' \
  '{session_id:$sid,agent_type:"planner-budget",last_assistant_message:$msg}')"
plan_budget_rc=0
printf '%s' "${plan_budget_payload}" \
  | env PATH="${plan_budget_shim}:${PATH}" \
    OMC_PLAN_BUDGET_COUNT="${plan_budget_count}" \
    OMC_STATE_LOCK_MAX_ATTEMPTS=2 \
    OMC_RECORD_PLAN_LOCK_MAX_ATTEMPTS=20 \
    STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${RECORD_PLAN}" >/dev/null 2>&1 \
  || plan_budget_rc=$?
assert_eq "plan-specific budget survives the generic two-attempt cap" \
  "0" "${plan_budget_rc}"
assert_eq "plan-specific budget keeps polling through six denied claims" \
  "7" "$(cat "${plan_budget_count}")"
assert_eq "durably-waited plan advances revision once" \
  "1" "$(read_state "plan_revision")"
assert_eq "durably-waited plan publishes matching artifact" \
  "1" "$(grep -Fc 'PLAN_BODY_BUDGET' "${plan_file}" 2>/dev/null || echo 0)"

# ===========================================================================
# Test 6: plan publication failure is explicit and cannot advance state.
#
# A directory at current_plan.md reproduces the pre-fix failure exactly: `mv`
# treated it as a destination directory, moved the staged file inside it, and
# the OR-list lock wrapper suppressed errexit so has_plan/plan_revision still
# advanced. The hook must now fail non-zero before either artifact or state is
# published.
# ===========================================================================
printf 'record-plan fails closed when the artifact target is invalid:\n'

reset_state
rm -f "${plan_file}"
mkdir "${plan_file}"
failure_payload="$(jq -nc --arg sid "${SESSION_ID}" \
  --arg msg $'PLAN_BODY_FAILURE\nVERDICT: PLAN_READY' \
  '{session_id:$sid,agent_type:"planner-failure",last_assistant_message:$msg}')"
plan_failure_rc=0
printf '%s' "${failure_payload}" \
  | STATE_ROOT="${TEST_STATE_ROOT}" bash "${RECORD_PLAN}" >/dev/null 2>&1 \
  || plan_failure_rc=$?
artifact_children="$(find "${plan_file}" -mindepth 1 -maxdepth 1 -print \
  | wc -l | tr -d '[:space:]')"
assert_eq "invalid plan target returns failure" "1" "${plan_failure_rc}"
assert_eq "failed plan publish leaves has_plan unset" "" "$(read_state "has_plan")"
assert_eq "failed plan publish leaves plan_revision unset" "" "$(read_state "plan_revision")"
assert_eq "failed plan publish does not move a staged file into target directory" \
  "0" "${artifact_children}"
rmdir "${plan_file}"

# A symlink is not an owned regular artifact. Replacing it would mutate an
# external target and make transaction rollback unable to restore the prior
# shape, so publication must fail before any canonical mutation.
printf 'record-plan rejects a symlink artifact target:\n'
reset_state
plan_symlink_target="${TEST_STATE_ROOT}/external-plan-target.md"
printf '%s\n' 'EXTERNAL_PLAN_SENTINEL' >"${plan_symlink_target}"
ln -s "${plan_symlink_target}" "${plan_file}"
plan_symlink_rc=0
printf '%s' "${failure_payload}" \
  | STATE_ROOT="${TEST_STATE_ROOT}" bash "${RECORD_PLAN}" >/dev/null 2>&1 \
  || plan_symlink_rc=$?
assert_eq "symlink plan target returns failure" "1" "${plan_symlink_rc}"
assert_eq "symlink plan target remains a symlink" "yes" \
  "$([[ -L "${plan_file}" ]] && printf yes || printf no)"
assert_eq "symlink external target remains untouched" "EXTERNAL_PLAN_SENTINEL" \
  "$(cat "${plan_symlink_target}")"
assert_eq "symlink rejection leaves plan_revision unset" "" \
  "$(read_state "plan_revision")"
assert_eq "symlink rejection leaves no unpublished stage" "0" \
  "$(find "$(dirname "${plan_file}")" -maxdepth 1 \
      -name '.current-plan-stage.*' -print | wc -l | tr -d '[:space:]')"
rm -f "${plan_file}" "${plan_symlink_target}"

# ===========================================================================
# Test 7: a planner waiting on the state lock cannot publish after /ulw-off.
#
# Pause record-plan at its first state-lock mkdir, after it has captured the
# active enforcement generation but before the artifact/state transaction.
# Deactivation wins the real session lock; when the planner resumes, its
# in-lock interval check must reject the stale callback without creating either
# current_plan.md or executable plan state.
# ===========================================================================
printf 'record-plan rejects a callback whose ULW interval closes while waiting:\n'

reset_state
rm -f "$(session_file "current_plan.md")"
with_state_lock_batch \
  "workflow_mode" "ultrawork" \
  "ulw_enforcement_active" "1" \
  "ulw_enforcement_generation" "7" \
  "task_intent" "execution" \
  "last_user_prompt_ts" "700" \
  "plan_revision" "0"
touch "$(session_file ".ulw_active")"

plan_race_shim="${TEST_STATE_ROOT}/plan-race-shim"
plan_race_ready="${TEST_STATE_ROOT}/plan-race-ready"
plan_race_release="${TEST_STATE_ROOT}/plan-race-release"
mkdir -p "${plan_race_shim}"
printf '%s\n' \
  '#!/bin/sh' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'case "${dest}" in' \
  '  */.state.lock.owner)' \
  '    /usr/bin/touch "${OMC_PLAN_RACE_READY}"' \
  '    while [ ! -f "${OMC_PLAN_RACE_RELEASE}" ]; do /bin/sleep 0.01; done' \
  '    ;;' \
  'esac' \
  'exec /bin/ln "$@"' \
  >"${plan_race_shim}/ln"
chmod +x "${plan_race_shim}/ln"

plan_race_payload="$(jq -nc --arg sid "${SESSION_ID}" \
  --arg msg $'STALE_PLAN_BODY\nVERDICT: PLAN_READY' \
  '{session_id:$sid,agent_type:"quality-planner",last_assistant_message:$msg}')"
(
  printf '%s' "${plan_race_payload}" \
    | env PATH="${plan_race_shim}:${PATH}" \
      OMC_PLAN_RACE_READY="${plan_race_ready}" \
      OMC_PLAN_RACE_RELEASE="${plan_race_release}" \
      STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${RECORD_PLAN}" >/dev/null 2>&1
) &
plan_race_pid=$!
for _plan_race_wait in $(seq 1 500); do
  [[ -f "${plan_race_ready}" ]] && break
  kill -0 "${plan_race_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "record-plan reaches deterministic state-lock barrier" "yes" \
  "$([[ -f "${plan_race_ready}" ]] && printf yes || printf no)"

deactivate_rc=0
STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/ulw-deactivate.sh" \
    "${SESSION_ID}" >/dev/null 2>&1 || deactivate_rc=$?
assert_eq "/ulw-off wins the lock while planner is paused" "0" "${deactivate_rc}"
touch "${plan_race_release}"
plan_race_rc=0
wait "${plan_race_pid}" || plan_race_rc=$?
assert_eq "stale planner callback exits without publication failure" "0" "${plan_race_rc}"
assert_eq "stale planner creates no current_plan.md" "no" \
  "$([[ -e "$(session_file "current_plan.md")" ]] && printf yes || printf no)"
assert_eq "stale planner leaves has_plan unset" "" "$(read_state "has_plan")"
assert_eq "stale planner leaves plan_verdict unset" "" "$(read_state "plan_verdict")"
assert_eq "stale planner cannot advance plan_revision" "0" "$(read_state "plan_revision")"
assert_eq "planner race finishes with enforcement inactive" "0" \
  "$(read_state "ulw_enforcement_active")"

# ===========================================================================
# Summary
# ===========================================================================

printf '\n'
printf '=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
