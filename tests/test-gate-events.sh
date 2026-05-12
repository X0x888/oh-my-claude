#!/usr/bin/env bash
# test-gate-events.sh — tests for record_gate_event helper and the per-event
# outcome attribution path through stop-guard.sh and record-finding-list.sh.
#
# v1.14.0 added per-gate-fire / per-finding-resolution telemetry to
# `<session>/gate_events.jsonl`. This test exercises (a) the helper
# directly via common.sh, (b) the wired sites in stop-guard.sh emit
# correct rows, (c) record-finding-list.sh status changes emit rows,
# and (d) per-session cap is honored under load.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

ORIG_HOME="${HOME}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}" 2>/dev/null || true
}

trap 'teardown_test' EXIT INT TERM

init_session() {
  local sid="$1"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${state_dir}"
  jq -nc --arg ts "$(date +%s)" \
    '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"execution",current_objective:"gate events test",last_user_prompt_ts:$ts}' \
    > "${state_dir}/session_state.json"
}

events_file_for() {
  printf '%s/.claude/quality-pack/state/%s/gate_events.jsonl' "${TEST_HOME}" "$1"
}

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
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

printf '=== Gate Events Tests (v1.14.0 per-event outcome attribution) ===\n\n'

# ---------------------------------------------------------------------
# Test 1: helper writes a well-formed JSONL row
# ---------------------------------------------------------------------
printf 'Test 1: record_gate_event writes a row with all top-level fields\n'
setup_test
init_session "ge1"
SESSION_ID="ge1" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash -c "
    set -euo pipefail
    . '${HOOK_DIR}/common.sh'
    SESSION_ID='ge1'
    record_gate_event 'discovered-scope' 'block' \
      'block_count=2' 'block_cap=5' \
      'pending_count=4' 'wave_total=4' 'waves_completed=1'
  "
events_file="$(events_file_for "ge1")"
[[ -f "${events_file}" ]] && pass=$((pass + 1)) || { printf '  FAIL: gate_events.jsonl not created\n' >&2; fail=$((fail + 1)); }

row="$(cat "${events_file}")"
assert_contains "row contains gate=discovered-scope" '"gate":"discovered-scope"' "${row}"
assert_contains "row contains event=block" '"event":"block"' "${row}"
assert_contains "row contains block_count=2" '"block_count":2' "${row}"
assert_contains "row contains block_cap=5" '"block_cap":5' "${row}"
assert_contains "row contains details.pending_count (numeric)" '"pending_count":4' "${row}"
assert_contains "row contains details.wave_total (numeric)" '"wave_total":4' "${row}"
assert_contains "row contains details.waves_completed (numeric)" '"waves_completed":1' "${row}"
teardown_test

# ---------------------------------------------------------------------
# Test 2: helper is a no-op when SESSION_ID is empty
# ---------------------------------------------------------------------
printf 'Test 2: helper exits 0 when SESSION_ID is empty (defensive)\n'
setup_test
out="$(SESSION_ID="" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash -c "
    set -euo pipefail
    . '${HOOK_DIR}/common.sh'
    SESSION_ID=''
    record_gate_event 'foo' 'block' 'block_count=1' && echo 'ok'
  ")"
assert_eq "no-session call returns ok (no-op)" "ok" "${out}"
teardown_test

# ---------------------------------------------------------------------
# Test 3: stop-guard emits a discovered-scope event when blocking
# ---------------------------------------------------------------------
printf 'Test 3: stop-guard.sh emits discovered-scope gate event on block\n'
setup_test
init_session "ge3"
sd="${TEST_HOME}/.claude/quality-pack/state/ge3"
# Seed a pending finding so the gate has something to block on.
jq -nc --arg id "FX-001" --argjson ts "$(date +%s)" \
  '{id:$id,severity:"high",summary:"seed",status:"pending",ts:$ts}' \
  > "${sd}/discovered_scope.jsonl"

out="$(printf '%s' "$(jq -nc --arg s ge3 '{session_id:$s,last_assistant_message:"work"}')" \
  | env OMC_DISCOVERED_SCOPE=on bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_contains "stop-guard emitted decision:block" '"decision":"block"' "${out}"

events_file="$(events_file_for "ge3")"
[[ -f "${events_file}" ]] && pass=$((pass + 1)) || { printf '  FAIL: stop-guard did not write gate_events.jsonl\n' >&2; fail=$((fail + 1)); }
last_event="$(tail -n 1 "${events_file}")"
assert_contains "stop-guard event has gate=discovered-scope" '"gate":"discovered-scope"' "${last_event}"
assert_contains "stop-guard event has event=block" '"event":"block"' "${last_event}"
assert_contains "stop-guard event records pending_count=1 (numeric)" '"pending_count":1' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
# Test 3b: stop-guard advisory gate emits an event when blocking
# ---------------------------------------------------------------------
printf 'Test 3b: stop-guard advisory gate emits an event\n'
setup_test
init_session "ge3b"
sd="${TEST_HOME}/.claude/quality-pack/state/ge3b"
# Configure as advisory intent + edits but no verification → triggers advisory gate.
jq -nc --arg ts "$(date +%s)" \
  '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"advisory",current_objective:"advisory test",last_user_prompt_ts:$ts,last_edit_ts:($ts|tonumber+10|tostring)}' \
  > "${sd}/session_state.json"
echo "/some/code.ts" > "${sd}/edited_files.log"

out="$(printf '%s' "$(jq -nc --arg s ge3b '{session_id:$s,last_assistant_message:"work"}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
events_file="$(events_file_for "ge3b")"
if [[ -f "${events_file}" ]] && grep -q '"gate":"advisory"' "${events_file}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: advisory gate did not emit a gate event (or event file missing)\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------
# Test 3c: final-closure gate emits an event when the wrap is not audit-ready
# ---------------------------------------------------------------------
printf 'Test 3c: stop-guard final-closure gate emits an event\n'
setup_test
init_session "ge3c"
sd="${TEST_HOME}/.claude/quality-pack/state/ge3c"
jq -nc --arg ts "$(date +%s)" \
  '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"execution",current_objective:"closure test",last_user_prompt_ts:$ts,last_edit_ts:$ts,last_code_edit_ts:$ts,last_verify_ts:$ts,last_verify_cmd:"npm test",last_verify_outcome:"passed",last_review_ts:$ts,review_had_findings:"false",subagent_dispatch_count:"1"}' \
  > "${sd}/session_state.json"
printf '/tmp/project/src/foo.ts\n' > "${sd}/edited_files.log"

out="$(printf '%s' "$(jq -nc --arg s ge3c '{session_id:$s,last_assistant_message:"Here is the completed work."}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_contains "final-closure gate blocks" '"decision":"block"' "${out}"
assert_contains "final-closure gate names itself" "Final-closure gate" "${out}"

events_file="$(events_file_for "ge3c")"
last_event="$(tail -n 1 "${events_file}")"
assert_contains "final-closure event has gate=final-closure" '"gate":"final-closure"' "${last_event}"
assert_contains "final-closure event has event=block" '"event":"block"' "${last_event}"
assert_contains "final-closure event records missing_verification" '"missing_verification":1' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
# Test 3d: delivery-contract gate emits an event when prompt-explicit
# surfaces were never touched
# ---------------------------------------------------------------------
printf 'Test 3d: stop-guard delivery-contract gate emits an event\n'
setup_test
init_session "ge3d"
sd="${TEST_HOME}/.claude/quality-pack/state/ge3d"
jq -nc --arg ts "$(date +%s)" \
  '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"execution",current_objective:"contract test",last_user_prompt_ts:$ts,last_edit_ts:$ts,last_code_edit_ts:$ts,last_verify_ts:$ts,last_verify_cmd:"npm test",last_verify_outcome:"passed",last_verify_confidence:"80",last_review_ts:$ts,review_had_findings:"false",done_contract_prompt_surfaces:"tests",done_contract_test_expectation:"add_or_update_tests",done_contract_commit_mode:"unspecified"}' \
  > "${sd}/session_state.json"
printf '/tmp/project/src/foo.ts\n' > "${sd}/edited_files.log"

out="$(printf '%s' "$(jq -nc --arg s ge3d '{session_id:$s,last_assistant_message:"**Changed.** Updated /tmp/project/src/foo.ts\n\n**Verification.** `npm test`\n\n**Next.** Done."}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_contains "delivery-contract gate blocks" '"decision":"block"' "${out}"
assert_contains "delivery-contract gate names itself" "Delivery-contract gate" "${out}"

events_file="$(events_file_for "ge3d")"
last_event="$(tail -n 1 "${events_file}")"
assert_contains "delivery-contract event has gate=delivery-contract" '"gate":"delivery-contract"' "${last_event}"
assert_contains "delivery-contract event has event=block" '"event":"block"' "${last_event}"
assert_contains "delivery-contract event records prompt surfaces" '"prompt_surfaces":"tests"' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
# Test 4: record-finding-list.sh status command emits a finding-status event
# ---------------------------------------------------------------------
printf 'Test 4: record-finding-list status command emits finding-status event\n'
setup_test
init_session "ge4"
echo '[
  {"id":"F-001","summary":"a","severity":"high","surface":"x"},
  {"id":"F-002","summary":"b","severity":"high","surface":"y"}
]' | "${HOOK_DIR}/record-finding-list.sh" init >/dev/null

"${HOOK_DIR}/record-finding-list.sh" status F-001 shipped abc123 "Wave 1 commit" >/dev/null

events_file="$(events_file_for "ge4")"
[[ -f "${events_file}" ]] && pass=$((pass + 1)) || { printf '  FAIL: record-finding-list did not write gate_events.jsonl\n' >&2; fail=$((fail + 1)); }
last_event="$(tail -n 1 "${events_file}")"
assert_contains "finding-status event has gate=finding-status" '"gate":"finding-status"' "${last_event}"
assert_contains "finding-status event has event=finding-status-change" '"event":"finding-status-change"' "${last_event}"
assert_contains "finding-status event records finding_id=F-001" '"finding_id":"F-001"' "${last_event}"
assert_contains "finding-status event records new status=shipped" '"finding_status":"shipped"' "${last_event}"
assert_contains "finding-status event records commit_sha" '"commit_sha":"abc123"' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
# Test 4b: record-finding-list wave-status emits a wave-status-change event
# ---------------------------------------------------------------------
printf 'Test 4b: record-finding-list wave-status emits a gate event\n'
setup_test
init_session "ge4b"
echo '[
  {"id":"F-001","summary":"a","severity":"high","surface":"x"}
]' | "${HOOK_DIR}/record-finding-list.sh" init >/dev/null
"${HOOK_DIR}/record-finding-list.sh" assign-wave 1 1 "x" F-001 >/dev/null
"${HOOK_DIR}/record-finding-list.sh" wave-status 1 completed deadbeef >/dev/null

events_file="$(events_file_for "ge4b")"
last_event="$(tail -n 1 "${events_file}")"
assert_contains "wave-status event has gate=wave-status" '"gate":"wave-status"' "${last_event}"
assert_contains "wave-status event has event=wave-status-change" '"event":"wave-status-change"' "${last_event}"
assert_contains "wave-status event records wave_idx=1 (numeric)" '"wave_idx":1' "${last_event}"
assert_contains "wave-status event records new wave_status=completed" '"wave_status":"completed"' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
# Test 5: per-session cap is honored
# ---------------------------------------------------------------------
printf 'Test 5: per-session cap (OMC_GATE_EVENTS_PER_SESSION_MAX) bounds row count\n'
setup_test
init_session "ge5"
SESSION_ID="ge5" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  OMC_GATE_EVENTS_PER_SESSION_MAX=10 \
  bash -c "
    set -euo pipefail
    . '${HOOK_DIR}/common.sh'
    SESSION_ID='ge5'
    for i in \$(seq 1 25); do
      record_gate_event 'discovered-scope' 'block' \"block_count=\${i}\" 'block_cap=99'
    done
  "
events_file="$(events_file_for "ge5")"
row_count="$(wc -l < "${events_file}" | tr -d '[:space:]')"
# After 25 writes with cap=10, file should hold at most 10 rows.
if [[ "${row_count}" -le 10 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: cap=10 not honored — got %s rows\n' "${row_count}" >&2
  fail=$((fail + 1))
fi
# Tail semantics — last row should be block 25, not block 1.
last_row="$(tail -n 1 "${events_file}")"
assert_contains "tail-truncate preserves newest" '"block_count":25' "${last_row}"
teardown_test

# ---------------------------------------------------------------------
# Test 6: ts field is a numeric epoch
# ---------------------------------------------------------------------
printf 'Test 6: ts is a numeric epoch\n'
setup_test
init_session "ge6"
SESSION_ID="ge6" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash -c "
    set -euo pipefail
    . '${HOOK_DIR}/common.sh'
    SESSION_ID='ge6'
    record_gate_event 'advisory' 'block' 'block_count=1' 'block_cap=1'
  "
events_file="$(events_file_for "ge6")"
ts_val="$(jq -r '.ts' "${events_file}")"
if [[ "${ts_val}" =~ ^[0-9]{10}$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: ts should be 10-digit epoch, got %q\n' "${ts_val}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ---------------------------------------------------------------------
# Test 7: v1.18.0 — mark-user-decision emits a user-decision-marked event
# under gate=finding-status. The event must be visible to /ulw-report.
# ---------------------------------------------------------------------
printf 'Test 7: record-finding-list mark-user-decision emits gate event\n'
setup_test
init_session "ge7"
echo '[
  {"id":"F-D01","summary":"requires prod credentials","severity":"medium","surface":"deploy"}
]' | "${HOOK_DIR}/record-finding-list.sh" init >/dev/null
# v1.40.0: mark-user-decision validates the reason against
# omc_reason_names_operational_block when no_defer_mode=on AND the
# session is ULW execution (init_session sets both). Use a reason in
# the operational accept set ("credentials missing") — the v1.39-era
# example "brand voice" is now correctly rejected by the validator and
# would fail this test under `set -e`.
"${HOOK_DIR}/record-finding-list.sh" mark-user-decision F-D01 "credentials missing" >/dev/null

events_file="$(events_file_for "ge7")"
last_event="$(tail -n 1 "${events_file}")"
assert_contains "user-decision event has gate=finding-status" \
  '"gate":"finding-status"' "${last_event}"
assert_contains "user-decision event has event=user-decision-marked" \
  '"event":"user-decision-marked"' "${last_event}"
assert_contains "user-decision event records finding_id=F-D01" \
  '"finding_id":"F-D01"' "${last_event}"
assert_contains "user-decision event records decision_reason" \
  '"decision_reason":"credentials missing"' "${last_event}"
teardown_test

# ---------------------------------------------------------------------
printf '\n=== Gate Events: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
