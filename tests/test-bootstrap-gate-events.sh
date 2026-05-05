#!/usr/bin/env bash
#
# tests/test-bootstrap-gate-events.sh — regression net for
# tools/bootstrap-gate-events-rollup.sh (v1.32.5 reviewer-driven fixes).
#
# Pre-1.32.5 the bootstrap claimed idempotency but actually double-
# counted on re-run because it left source files in place (the natural
# sweep is idempotent only because it `rm -rf`s the source dir).
# v1.32.5 added a `.bootstrap-aggregated` per-source stamp + fixture-
# dir filter + cross-session log lock when available. This test pins
# the fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/bootstrap-gate-events-rollup.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

setup_fixture() {
  TEST_STATE_ROOT="$(mktemp -d)"
  TEST_HOME="$(mktemp -d)"
  mkdir -p "${TEST_HOME}/.claude/quality-pack"

  # Real-shaped UUID session with 3 gate events
  local sid_real="11111111-2222-3333-4444-555555555555"
  mkdir -p "${TEST_STATE_ROOT}/${sid_real}"
  printf '{"event":"guard_block","gate":"quality","ts":"1"}\n' >> "${TEST_STATE_ROOT}/${sid_real}/gate_events.jsonl"
  printf '{"event":"guard_block","gate":"discovered-scope","ts":"2"}\n' >> "${TEST_STATE_ROOT}/${sid_real}/gate_events.jsonl"
  printf '{"event":"finding_status","gate":"finding-status","ts":"3"}\n' >> "${TEST_STATE_ROOT}/${sid_real}/gate_events.jsonl"
  printf '{}' > "${TEST_STATE_ROOT}/${sid_real}/session_state.json"

  # Fixture-shaped session (non-UUID) with 5 gate events — should be filtered
  local sid_fixture="p4-2398"
  mkdir -p "${TEST_STATE_ROOT}/${sid_fixture}"
  for i in 1 2 3 4 5; do
    printf '{"event":"guard_block","gate":"fixture-test","ts":"%s"}\n' "${i}" >> "${TEST_STATE_ROOT}/${sid_fixture}/gate_events.jsonl"
  done
  printf '{}' > "${TEST_STATE_ROOT}/${sid_fixture}/session_state.json"

  # _watchdog session (synthetic) with 7 events — should also be filtered
  mkdir -p "${TEST_STATE_ROOT}/_watchdog"
  for i in 1 2 3 4 5 6 7; do
    printf '{"event":"watchdog_tick","gate":"resume","ts":"%s"}\n' "${i}" >> "${TEST_STATE_ROOT}/_watchdog/gate_events.jsonl"
  done
}

teardown_fixture() {
  rm -rf "${TEST_STATE_ROOT}" "${TEST_HOME}" 2>/dev/null || true
}

# ---------------------------------------------------------------------
printf 'Test 1: dry-run reports counts without writing\n'
setup_fixture
out_dry="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" --dry-run 2>&1)"
assert_contains "T1: dry-run reports 1 session would aggregate" "1 sessions" "${out_dry}"
assert_contains "T1: dry-run reports 3 rows" "3 total rows" "${out_dry}"
assert_contains "T1: dry-run reports fixture skip" "1 fixture" "${out_dry}"
assert_contains "T1: dry-run reports watchdog skip" "1 _watchdog" "${out_dry}"
# Dst should not exist after dry-run
if [[ ! -f "${TEST_HOME}/.claude/quality-pack/gate_events.jsonl" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T1: dry-run wrote to dst\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 2: real run aggregates UUID-shape session, skips fixture + watchdog\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" >/dev/null 2>&1
dst_rows="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "T2: dst has 3 rows (UUID session only)" "3" "${dst_rows}"
# Verify fixture dir's events are NOT in dst
if grep -q "fixture-test" "${DST}" 2>/dev/null; then
  printf '  FAIL: T2: fixture rows leaked into dst\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# Verify watchdog rows are NOT in dst
if grep -q "watchdog_tick" "${DST}" 2>/dev/null; then
  printf '  FAIL: T2: _watchdog rows leaked into dst\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# Stamp file should exist
if [[ -f "${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2: stamp file not created\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 3: rerun skips stamped sessions (idempotency)\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" >/dev/null 2>&1
rows_after_first="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
out_second="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" 2>&1)"
rows_after_second="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "T3: row count unchanged after rerun (idempotency)" "${rows_after_first}" "${rows_after_second}"
assert_contains "T3: rerun reports stamped skip" "1 stamped" "${out_second}"
assert_contains "T3: rerun reports 0 sessions aggregated" "Aggregated 0 sessions" "${out_second}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 4: --force ignores stamps and re-aggregates\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" >/dev/null 2>&1
out_force="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" --force 2>&1)"
rows_after_force="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "T4: --force re-aggregates → 6 rows (3+3)" "6" "${rows_after_force}"
assert_contains "T4: --force aggregates 1 session" "Aggregated 1 sessions" "${out_force}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 5: rows tagged with session_id\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" bash "${TOOL}" >/dev/null 2>&1
sid_count="$(jq -r '.session_id' "${DST}" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo 0)"
assert_eq "T5: all rows tagged with session_id (1 unique sid)" "1" "${sid_count}"
sid_value="$(jq -r '.session_id' "${DST}" 2>/dev/null | head -1 || echo '')"
assert_eq "T5: session_id matches the source dir name" \
  "11111111-2222-3333-4444-555555555555" "${sid_value}"
teardown_fixture

# ---------------------------------------------------------------------
printf '\n=== bootstrap-gate-events tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
