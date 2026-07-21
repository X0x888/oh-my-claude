#!/usr/bin/env bash
#
# tests/test-bootstrap-gate-events.sh — regression net for
# tools/bootstrap-gate-events-rollup.sh (v1.32.5 reviewer-driven fixes).
#
# Pre-1.32.5 the bootstrap claimed idempotency but actually double-
# counted on re-run because it left source files in place (the natural
# sweep is idempotent only because it `rm -rf`s the source dir).
# v1.32.5 added a `.bootstrap-aggregated` per-source stamp + fixture-dir
# filter + cross-session log lock. The current regression also pins bounded
# inputs, per-session locking, occurrence-aware crash retry, strict state
# parsing, safe path handling, and observable enumeration failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/bootstrap-gate-events-rollup.sh"
COMMON_SH_UNDER_TEST="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

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

assert_file_unchanged() {
  local label="$1" expected="$2" actual="$3"
  if cmp -s "${expected}" "${actual}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
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
  {
    printf '{"event":"guard_block","gate":"quality","ts":"1"}\n'
    printf '{"event":"guard_block","gate":"discovered-scope","ts":"2"}\n'
    printf '{"event":"finding_status","gate":"finding-status","ts":"3"}\n'
  } >"${TEST_STATE_ROOT}/${sid_real}/gate_events.jsonl"
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
out_dry="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" --dry-run 2>&1)"
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
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
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
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
rows_after_first="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
out_second="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
rows_after_second="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "T3: row count unchanged after rerun (idempotency)" "${rows_after_first}" "${rows_after_second}"
assert_contains "T3: rerun reports stamped skip" "1 stamped" "${out_second}"
assert_contains "T3: rerun reports 0 sessions aggregated" "Aggregated 0 sessions" "${out_second}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 4: --force ignores stamps and re-aggregates\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
out_force="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" --force 2>&1)"
rows_after_force="$(wc -l < "${DST}" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "T4: --force re-aggregates → 6 rows (3+3)" "6" "${rows_after_force}"
assert_contains "T4: --force aggregates 1 session" "Aggregated 1 sessions" "${out_force}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 5: rows tagged with session_id\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
sid_count="$(jq -r '.session_id' "${DST}" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo 0)"
assert_eq "T5: all rows tagged with session_id (1 unique sid)" "1" "${sid_count}"
sid_value="$(jq -r '.session_id' "${DST}" 2>/dev/null | head -1 || echo '')"
assert_eq "T5: session_id matches the source dir name" \
  "11111111-2222-3333-4444-555555555555" "${sid_value}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 6: malformed tail cannot partially publish or stamp success\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
EXPECTED_DST="${TEST_HOME}/expected-gate-events.jsonl"
printf '{"event":"existing","gate":"existing","ts":"0"}\n' >"${DST}"
cp "${DST}" "${EXPECTED_DST}"
printf '{"event":"truncated"' >>"${REAL_DIR}/gate_events.jsonl"
set +e
out_malformed="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
malformed_rc=$?
set -e
assert_eq "T6: malformed source makes bootstrap fail" "1" "${malformed_rc}"
assert_contains "T6: failure identifies retry-safe source transaction" \
  "locked gate-event source/publication failed" "${out_malformed}"
assert_file_unchanged "T6: destination generation changed after source failure" \
  "${EXPECTED_DST}" "${DST}"
if [[ ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: malformed source was stamped as aggregated\n' >&2
  fail=$((fail + 1))
fi
if [[ -f "${REAL_DIR}/gate_events.jsonl" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: malformed source was deleted\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 7: lock acquisition failure has no unlocked retry or success stamp\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
EXPECTED_DST="${TEST_HOME}/expected-gate-events.jsonl"
LOCK_ATTEMPT_FILE="${TEST_HOME}/lock-attempts"
printf '{"event":"existing","gate":"existing","ts":"0"}\n' >"${DST}"
cp "${DST}" "${EXPECTED_DST}"
set +e
out_lock_failure="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" OMC_STATE_LOCK_MAX_ATTEMPTS=1 \
  OMC_TEST_STATE_LOCK_DENY_ATTEMPTS=1 \
  OMC_TEST_STATE_LOCK_ATTEMPT_FILE="${LOCK_ATTEMPT_FILE}" \
  bash "${TOOL}" 2>&1)"
lock_failure_rc=$?
set -e
assert_eq "T7: lock acquisition failure aborts bootstrap" "1" "${lock_failure_rc}"
assert_contains "T7: failure identifies locked transaction" \
  "bootstrap transaction failed" "${out_lock_failure}"
assert_file_unchanged "T7: destination changed after lock acquisition failure" \
  "${EXPECTED_DST}" "${DST}"
if [[ ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T7: lock failure stamped the source as aggregated\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 8: stamp failure after publication is occurrence-idempotent on retry\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
set +e
out_stamp_fail="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" OMC_TEST_BOOTSTRAP_FAIL_STAMP=1 \
  bash "${TOOL}" 2>&1)"
stamp_fail_rc=$?
set -e
assert_eq "T8: injected post-publication stamp failure is reported" "1" "${stamp_fail_rc}"
assert_contains "T8: failure says retry is safe" "retry is safe" "${out_stamp_fail}"
rows_after_failed_stamp="$(wc -l <"${DST}" | tr -d '[:space:]')"
assert_eq "T8: complete destination generation was published" "3" "${rows_after_failed_stamp}"
if [[ ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T8: failing stamp was reported as present\n' >&2
  fail=$((fail + 1))
fi
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
rows_after_stamp_retry="$(wc -l <"${DST}" | tr -d '[:space:]')"
assert_eq "T8: retry does not duplicate already-published occurrences" \
  "3" "${rows_after_stamp_retry}"
if [[ -f "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T8: retry did not publish success stamp\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 9: normal merge preserves source multiplicity without replay duplication\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
{
  printf '{"event":"same","gate":"quality","ts":"1"}\n'
  printf '{"event":"same","gate":"quality","ts":"1"}\n'
  printf '{"event":"other","gate":"quality","ts":"2"}\n'
} >"${REAL_DIR}/gate_events.jsonl"
printf '{"event":"same","gate":"quality","ts":"1","session_id":"11111111-2222-3333-4444-555555555555"}\n' >"${DST}"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
same_count="$(jq -r 'select(.event == "same") | .event' "${DST}" | wc -l | tr -d '[:space:]')"
all_count="$(wc -l <"${DST}" | tr -d '[:space:]')"
assert_eq "T9: legitimate duplicate source occurrences are preserved" "2" "${same_count}"
assert_eq "T9: one existing occurrence is not replayed" "3" "${all_count}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 10: malformed multi-document state fails closed\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
printf '{}\n{}\n' >"${REAL_DIR}/session_state.json"
set +e
out_bad_state="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
bad_state_rc=$?
set -e
assert_eq "T10: multi-document state is rejected" "1" "${bad_state_rc}"
assert_contains "T10: state rejection fails the source transaction" \
  "source/publication failed" "${out_bad_state}"
if [[ ! -e "${DST}" && ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T10: malformed state published data or a stamp\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 11: invalid project key and oversized source fail closed\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
printf '{"project_key":"aaaaaaaaaaaa\\n"}\n' >"${REAL_DIR}/session_state.json"
set +e
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
bad_key_rc=$?
set -e
assert_eq "T11: newline-bearing project key is rejected" "1" "${bad_key_rc}"
printf '{}' >"${REAL_DIR}/session_state.json"
dd if=/dev/zero of="${REAL_DIR}/gate_events.jsonl" bs=1048576 count=9 \
  >/dev/null 2>&1
set +e
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
oversized_rc=$?
set -e
assert_eq "T11: source over 8 MiB is rejected" "1" "${oversized_rc}"
if [[ ! -e "${DST}" && ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T11: invalid bounded input published data or a stamp\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 12: source mutation after staging cannot publish or stamp\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
READY="${TEST_HOME}/stage-ready"
RELEASE="${TEST_HOME}/stage-release"
RC_FILE="${TEST_HOME}/bootstrap-rc"
OUT_FILE="${TEST_HOME}/bootstrap-out"
(
  set +e
  STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
    COMMON_SH="${COMMON_SH_UNDER_TEST}" \
    OMC_TEST_BOOTSTRAP_STAGE_READY_FILE="${READY}" \
    OMC_TEST_BOOTSTRAP_STAGE_RELEASE_FILE="${RELEASE}" \
    bash "${TOOL}" >"${OUT_FILE}" 2>&1
  printf '%s\n' "$?" >"${RC_FILE}"
) &
bootstrap_pid=$!
ready_attempt=0
while [[ ! -e "${READY}" && "${ready_attempt}" -lt 500 ]]; do
  sleep 0.01
  ready_attempt=$((ready_attempt + 1))
done
if [[ -e "${READY}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12: bootstrap never reached post-stage barrier\n' >&2
  fail=$((fail + 1))
fi
printf '{"event":"late","gate":"quality","ts":"4"}\n' \
  >>"${REAL_DIR}/gate_events.jsonl"
: >"${RELEASE}"
wait "${bootstrap_pid}" || true
mutation_rc="$(tr -d '[:space:]' <"${RC_FILE}")"
assert_eq "T12: changed source generation is rejected" "1" "${mutation_rc}"
if [[ ! -e "${DST}" && ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12: changed source generation was published or stamped\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 13: unsafe roots, destinations, and stamps are rejected\n'
setup_fixture
ROOT_PARENT="$(mktemp -d)"
ROOT_LINK="${ROOT_PARENT}/state-link"
ln -s "${TEST_STATE_ROOT}" "${ROOT_LINK}"
set +e
STATE_ROOT="${ROOT_LINK}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
root_link_rc=$?
set -e
assert_eq "T13: symlinked state root is rejected" "1" "${root_link_rc}"
rm -rf "${ROOT_PARENT}"

DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
TARGET="${TEST_HOME}/outside-ledger"
printf '{"event":"outside"}\n' >"${TARGET}"
ln -s "${TARGET}" "${DST}"
set +e
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
dst_link_rc=$?
set -e
assert_eq "T13: symlinked destination is rejected" "1" "${dst_link_rc}"
assert_eq "T13: symlink target remains byte-identical" \
  '{"event":"outside"}' "$(tr -d '\n' <"${TARGET}")"
rm -f "${DST}"

REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
STAMP_TARGET="${TEST_HOME}/outside-stamp"
: >"${STAMP_TARGET}"
ln -s "${STAMP_TARGET}" "${REAL_DIR}/.bootstrap-aggregated"
set +e
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
stamp_link_rc=$?
set -e
assert_eq "T13: symlinked success stamp is rejected" "1" "${stamp_link_rc}"
if [[ ! -e "${DST}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T13: unsafe stamp permitted destination publication\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 14: enumeration failure is observable and publishes nothing\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
set +e
out_find_fail="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" OMC_TEST_BOOTSTRAP_FIND_FAILURE=1 \
  bash "${TOOL}" 2>&1)"
find_fail_rc=$?
set -e
assert_eq "T14: injected find failure aborts bootstrap" "1" "${find_fail_rc}"
assert_contains "T14: find failure is explicit" "failed to enumerate" "${out_find_fail}"
if [[ ! -e "${DST}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T14: enumeration failure published a destination\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 15: a stamped active session still imports later occurrences\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
printf '{"event":"late","gate":"quality","ts":"4"}\n' \
  >>"${REAL_DIR}/gate_events.jsonl"
out_incremental="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
incremental_rows="$(wc -l <"${DST}" | tr -d '[:space:]')"
assert_eq "T15: only the later occurrence is added" "4" "${incremental_rows}"
assert_contains "T15: changed stamped source is reported as aggregated" \
  "Aggregated 1 sessions" "${out_incremental}"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
stable_incremental_rows="$(wc -l <"${DST}" | tr -d '[:space:]')"
assert_eq "T15: unchanged incremental retry stays occurrence-idempotent" \
  "4" "${stable_incremental_rows}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 16: durable event identity deduplicates resume-copied rows\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
printf '%s\n' \
  '{"event_id":"ge:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1","event":"block","gate":"quality","ts":1,"session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","project_key":"aaaaaaaaaaaa"}' \
  >"${DST}"
printf '%s\n' \
  '{"event_id":"ge:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1","event":"block","gate":"quality","ts":1}' \
  >"${REAL_DIR}/gate_events.jsonl"
printf '{"project_key":"bbbbbbbbbbbb"}\n' \
  >"${REAL_DIR}/session_state.json"
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" >/dev/null 2>&1
identity_rows="$(wc -l <"${DST}" | tr -d '[:space:]')"
identity_sid="$(jq -r '.session_id' "${DST}")"
identity_project="$(jq -r '.project_key' "${DST}")"
assert_eq "T16: copied event identity is emitted once" "1" "${identity_rows}"
assert_eq "T16: first producer session attribution is retained" \
  "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "${identity_sid}"
assert_eq "T16: first producer project attribution is retained" \
  "aaaaaaaaaaaa" "${identity_project}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 17: conflicting producer payload for one event ID fails closed\n'
setup_fixture
DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
EXPECTED_DST="${TEST_HOME}/expected-gate-events.jsonl"
printf '%s\n' \
  '{"event_id":"ge:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1","event":"block","gate":"quality","ts":1,"session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}' \
  >"${DST}"
cp "${DST}" "${EXPECTED_DST}"
printf '%s\n' \
  '{"event_id":"ge:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1","event":"release","gate":"quality","ts":1}' \
  >"${REAL_DIR}/gate_events.jsonl"
set +e
conflict_out="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
  COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
conflict_rc=$?
set -e
assert_eq "T17: conflicting identity aborts bootstrap" "1" "${conflict_rc}"
assert_contains "T17: conflict is reported as retry-safe failure" \
  "source/publication failed" "${conflict_out}"
assert_file_unchanged "T17: conflict leaves destination unchanged" \
  "${EXPECTED_DST}" "${DST}"
if [[ ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T17: conflicting source was stamped as aggregated\n' >&2
  fail=$((fail + 1))
fi
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 18: gate IDs use the canonical embedded-session grammar\n'
for invalid_event_id in 'ge:.:1' 'ge:...:1' 'ge:a..b:1'; do
  setup_fixture
  DST="${TEST_HOME}/.claude/quality-pack/gate_events.jsonl"
  REAL_DIR="${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555"
  EXPECTED_DST="${TEST_HOME}/expected-gate-events.jsonl"
  printf '%s\n' \
    '{"event_id":"ge:valid-session:1","event":"block","gate":"quality","ts":1}' \
    >"${DST}"
  cp "${DST}" "${EXPECTED_DST}"
  jq -nc --arg event_id "${invalid_event_id}" \
    '{event_id:$event_id,event:"block",gate:"quality",ts:2}' \
    >"${REAL_DIR}/gate_events.jsonl"
  set +e
  invalid_id_out="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" \
    COMMON_SH="${COMMON_SH_UNDER_TEST}" bash "${TOOL}" 2>&1)"
  invalid_id_rc=$?
  set -e
  assert_eq "T18: ${invalid_event_id} aborts bootstrap" "1" \
    "${invalid_id_rc}"
  assert_contains "T18: ${invalid_event_id} reports retry-safe failure" \
    "source/publication failed" "${invalid_id_out}"
  assert_file_unchanged "T18: ${invalid_event_id} leaves destination unchanged" \
    "${EXPECTED_DST}" "${DST}"
  if [[ ! -e "${REAL_DIR}/.bootstrap-aggregated" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T18: %s source was stamped as aggregated\n' \
      "${invalid_event_id}" >&2
    fail=$((fail + 1))
  fi
  teardown_fixture
done

# ---------------------------------------------------------------------
printf '\n=== bootstrap-gate-events tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
