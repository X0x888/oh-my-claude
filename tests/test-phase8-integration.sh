#!/usr/bin/env bash
# test-phase8-integration.sh — End-to-end wiring test for Council Phase 8.
#
# Closes the gap deferred from v1.13.0: record-finding-list.sh and
# stop-guard.sh were each tested in isolation, but the contract that
# binds them — `wave_total` from findings.json raises the discovered-
# scope gate's block cap from 2 to wave_total+1 — had no integration
# coverage. This test exercises the real scripts end-to-end against a
# real findings.json and a real discovered_scope.jsonl.
#
# Three scenarios:
#   1. No wave plan → cap=2 (legacy default, block twice then release).
#   2. Wave plan with N=4 waves → cap=5 (block five times then release).
#   3. wave_progress text reflects waves_completed correctly as wave
#      statuses transition pending → in_progress → completed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
RECORD_FINDING="${HOOK_DIR}/record-finding-list.sh"
STOP_GUARD="${HOOK_DIR}/stop-guard.sh"

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

# Initialize a session with execution intent and ULW mode active so the
# discovered-scope gate is reachable.
init_session() {
  local sid="$1"
  local state_dir="${TEST_HOME}/.claude/quality-pack/state/${sid}"
  mkdir -p "${state_dir}"
  jq -nc --arg ts "$(date +%s)" \
    '{workflow_mode:"ultrawork",task_domain:"coding",task_intent:"execution",current_objective:"phase8 integration test",last_user_prompt_ts:$ts}' \
    > "${state_dir}/session_state.json"
}

# Append N pending findings to discovered_scope.jsonl so the gate has
# something to block on. Findings are unique per call (caller sets a
# prefix to avoid dedup collisions across scenarios).
seed_pending_findings() {
  local sid="$1"
  local n="$2"
  local prefix="${3:-FX}"
  local scope_file="${TEST_HOME}/.claude/quality-pack/state/${sid}/discovered_scope.jsonl"
  local i
  for ((i=1; i<=n; i++)); do
    jq -nc --arg id "${prefix}-$(printf '%03d' "${i}")" --arg ts "$(date +%s)" \
      '{id:$id,severity:"high",summary:"seeded pending finding",status:"pending",ts:($ts|tonumber)}' \
      >> "${scope_file}"
  done
}

# Run stop-guard.sh against the session and capture its stdout.
sim_stop() {
  local sid="$1"
  local msg="${2:-Here is the completed work.}"
  printf '%s' "$(jq -nc --arg s "${sid}" --arg m "${msg}" \
    '{session_id:$s,last_assistant_message:$m}')" \
    | env OMC_DISCOVERED_SCOPE=on bash "${STOP_GUARD}" 2>/dev/null || true
}

# Decode the gate's JSON `reason` field. stop-guard.sh embeds the
# middle-dot separator as a literal `·` escape (because bash
# double-quoted strings do not interpret `\u`); the JSON consumer is
# expected to render it. For assertion stability we substitute the
# literal escape with the UTF-8 `·` byte sequence so tests can use the
# rendered character regardless of jq version or shell locale.
sim_stop_reason() {
  local raw decoded
  raw="$(sim_stop "$@")"
  if [[ -z "${raw}" ]]; then
    printf ''
    return
  fi
  decoded="$(printf '%s' "${raw}" | jq -r '.reason // empty' 2>/dev/null || printf '')"
  # Substitute the literal six-char `·` sequence with the UTF-8 dot.
  printf '%s' "${decoded//\\u00b7/·}"
}

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
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

printf '=== Phase 8 Integration Tests (record-finding-list ↔ stop-guard) ===\n\n'

# ---------------------------------------------------------------------
# Scenario 1: No wave plan → cap=2 (legacy default)
# ---------------------------------------------------------------------
printf 'Scenario 1: no wave plan, cap=2\n'
setup_test
init_session "phase8-no-wave"
seed_pending_findings "phase8-no-wave" 3 "S1"

# Initialize findings.json without assigning waves — wave_total = 0
echo '[
  {"id":"S1-001","summary":"a","severity":"high","surface":"x"},
  {"id":"S1-002","summary":"b","severity":"high","surface":"x"},
  {"id":"S1-003","summary":"c","severity":"high","surface":"x"}
]' | "${RECORD_FINDING}" init >/dev/null

# Block 1 — should fire with cap=2
out1_raw="$(sim_stop "phase8-no-wave")"
out1="$(printf '%s' "${out1_raw}" | jq -r '.reason // empty' 2>/dev/null | sed 's/\\u00b7/·/g' || printf '')"
assert_contains "scenario1: block 1 fires" '"decision":"block"' "${out1_raw}"
assert_contains "scenario1: block 1 announces 1/2" 'Discovered-scope gate · 1/2' "${out1}"
assert_not_contains "scenario1: no wave_progress text without a plan" 'Wave plan:' "${out1}"

# Block 2 — should fire with cap=2
out2_raw="$(sim_stop "phase8-no-wave")"
out2="$(printf '%s' "${out2_raw}" | jq -r '.reason // empty' 2>/dev/null | sed 's/\\u00b7/·/g' || printf '')"
assert_contains "scenario1: block 2 fires" '"decision":"block"' "${out2_raw}"
assert_contains "scenario1: block 2 announces 2/2" 'Discovered-scope gate · 2/2' "${out2}"

# Block 3 — should release (cap reached, scope gate falls through)
out3_raw="$(sim_stop "phase8-no-wave")"
out3="$(printf '%s' "${out3_raw}" | jq -r '.reason // empty' 2>/dev/null | sed 's/\\u00b7/·/g' || printf '')"
assert_not_contains "scenario1: block 3 releases (no scope-gate decision)" 'Discovered-scope gate' "${out3}"

teardown_test

# ---------------------------------------------------------------------
# Scenario 2: Wave plan with N=4 waves → cap=5 (wave_total + 1)
# ---------------------------------------------------------------------
printf '\nScenario 2: 4-wave plan, cap=5 (wave_total + 1)\n'
setup_test
init_session "phase8-with-wave"
seed_pending_findings "phase8-with-wave" 4 "S2"

# Initialize findings.json with 4 findings, then assign them across 4 waves
echo '[
  {"id":"F-001","summary":"a","severity":"high","surface":"alpha"},
  {"id":"F-002","summary":"b","severity":"high","surface":"beta"},
  {"id":"F-003","summary":"c","severity":"high","surface":"gamma"},
  {"id":"F-004","summary":"d","severity":"high","surface":"delta"}
]' | "${RECORD_FINDING}" init >/dev/null

"${RECORD_FINDING}" assign-wave 1 4 "alpha" F-001 >/dev/null
"${RECORD_FINDING}" assign-wave 2 4 "beta"  F-002 >/dev/null
"${RECORD_FINDING}" assign-wave 3 4 "gamma" F-003 >/dev/null
"${RECORD_FINDING}" assign-wave 4 4 "delta" F-004 >/dev/null

# Confirm the wave plan is what we expect
wave_total="$(jq '.waves|length' "${TEST_HOME}/.claude/quality-pack/state/phase8-with-wave/findings.json")"
assert_eq "scenario2: 4 waves recorded" "4" "${wave_total}"

# Block 1 — gate fires with cap=5, wave_progress 0/4
out1_raw="$(sim_stop "phase8-with-wave")"
out1="$(printf '%s' "${out1_raw}" | jq -r '.reason // empty' 2>/dev/null | sed 's/\\u00b7/·/g' || printf '')"
assert_contains "scenario2: block 1 fires" '"decision":"block"' "${out1_raw}"
assert_contains "scenario2: block 1 announces 1/5" 'Discovered-scope gate · 1/5' "${out1}"
assert_contains "scenario2: block 1 reports 0/4 waves complete" 'Wave plan: 0/4 waves completed' "${out1}"

# Mark wave 1 completed → waves_completed should advance to 1/4
"${RECORD_FINDING}" wave-status 1 completed deadbeef >/dev/null

# Block 2 — cap still 5, but wave_progress now 1/4
out2="$(sim_stop_reason "phase8-with-wave")"
assert_contains "scenario2: block 2 announces 2/5" 'Discovered-scope gate · 2/5' "${out2}"
assert_contains "scenario2: block 2 reports 1/4 waves complete" 'Wave plan: 1/4 waves completed' "${out2}"

# Block 3 — cap=5, 3/5
out3="$(sim_stop_reason "phase8-with-wave")"
assert_contains "scenario2: block 3 announces 3/5" 'Discovered-scope gate · 3/5' "${out3}"

# Block 4 — cap=5, 4/5
out4="$(sim_stop_reason "phase8-with-wave")"
assert_contains "scenario2: block 4 announces 4/5" 'Discovered-scope gate · 4/5' "${out4}"

# Block 5 — cap=5, 5/5 (final block)
out5="$(sim_stop_reason "phase8-with-wave")"
assert_contains "scenario2: block 5 announces 5/5" 'Discovered-scope gate · 5/5' "${out5}"

# Block 6 — cap reached, gate releases (scope-gate text absent from any reason)
out6="$(sim_stop_reason "phase8-with-wave")"
assert_not_contains "scenario2: block 6 releases (cap reached)" 'Discovered-scope gate' "${out6}"

teardown_test

# ---------------------------------------------------------------------
# Scenario 3: All findings shipped → pending=0 means gate releases
# even when the wave plan is active and we are nowhere near the cap.
# This exercises the precondition `pending_count > 0` in the gate.
# ---------------------------------------------------------------------
printf '\nScenario 3: pending=0 with active wave plan releases the gate\n'
setup_test
init_session "phase8-shipped"

# 2-wave plan, but no pending findings in discovered_scope.jsonl.
echo '[
  {"id":"F-101","summary":"a","severity":"high","surface":"x"},
  {"id":"F-102","summary":"b","severity":"high","surface":"y"}
]' | "${RECORD_FINDING}" init >/dev/null

"${RECORD_FINDING}" assign-wave 1 2 "x" F-101 >/dev/null
"${RECORD_FINDING}" assign-wave 2 2 "y" F-102 >/dev/null

# Touch the file so the gate sees discovered_scope.jsonl exists but is empty
: > "${TEST_HOME}/.claude/quality-pack/state/phase8-shipped/discovered_scope.jsonl"

out1="$(sim_stop_reason "phase8-shipped")"
assert_not_contains "scenario3: empty pending releases gate even with wave plan" 'Discovered-scope gate' "${out1}"

teardown_test

# ---------------------------------------------------------------------
# Scenario 4: wave_total field directly drives the cap.
# Tightens the regression: if record-finding-list.sh writes waves[]
# but stop-guard reads wave_total wrong, the cap silently falls back.
# ---------------------------------------------------------------------
printf '\nScenario 4: changing wave_total updates the announced cap\n'
setup_test
init_session "phase8-wave-cap-shape"
seed_pending_findings "phase8-wave-cap-shape" 2 "S4"

# Start with a 2-wave plan
echo '[
  {"id":"F-201","summary":"a","severity":"high","surface":"x"},
  {"id":"F-202","summary":"b","severity":"high","surface":"y"}
]' | "${RECORD_FINDING}" init >/dev/null
"${RECORD_FINDING}" assign-wave 1 2 "x" F-201 >/dev/null
"${RECORD_FINDING}" assign-wave 2 2 "y" F-202 >/dev/null

out1="$(sim_stop_reason "phase8-wave-cap-shape")"
assert_contains "scenario4: 2-wave plan announces cap=3" 'Discovered-scope gate · 1/3' "${out1}"

teardown_test

# ---------------------------------------------------------------------
printf '\n=== Phase 8 Integration: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
