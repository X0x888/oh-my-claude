#!/usr/bin/env bash
# Tests for record-serendipity.sh — verifies per-session log, cross-session
# log, state counters, lock-correctness, and input validation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-serendipity.sh"

pass=0
fail=0

TEST_HOME="$(mktemp -d)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_STATE_ROOT}/serendipity-test-session"
mkdir -p "${TEST_HOME}/.claude/quality-pack"

# Save and override env for the duration of the test.
ORIG_HOME="${HOME}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"
export SESSION_ID="serendipity-test-session"

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
    printf '  FAIL: %s\n    expected to contain: %s\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

session_log="${TEST_STATE_ROOT}/${SESSION_ID}/serendipity_log.jsonl"
cross_log="${TEST_HOME}/.claude/quality-pack/serendipity-log.jsonl"
state_file="${TEST_STATE_ROOT}/${SESSION_ID}/session_state.json"

reset_logs() {
  rm -f "${session_log}" "${cross_log}" "${state_file}"
}

# ----------------------------------------------------------------------
printf 'Test 1: empty stdin → exit 2\n'
reset_logs
rc=0
echo "" | bash "${SCRIPT}" >/dev/null 2>&1 || rc=$?
assert_eq "empty stdin returns 2" "2" "${rc}"
assert_eq "no session log on rejection" "no" "$([[ -f "${session_log}" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 2: non-object JSON → exit 2\n'
reset_logs
rc=0
echo '[1,2,3]' | bash "${SCRIPT}" >/dev/null 2>&1 || rc=$?
assert_eq "non-object returns 2" "2" "${rc}"

# ----------------------------------------------------------------------
printf 'Test 3: object missing "fix" field → exit 2\n'
reset_logs
rc=0
echo '{"original_task":"x","conditions":"verified"}' | bash "${SCRIPT}" >/dev/null 2>&1 || rc=$?
assert_eq "missing fix field returns 2" "2" "${rc}"

# ----------------------------------------------------------------------
printf 'Test 4: minimal valid input writes both logs\n'
reset_logs
echo '{"fix":"Trim trailing newline in tail truncation"}' | bash "${SCRIPT}" 2>/dev/null
assert_eq "session log exists" "yes" "$([[ -f "${session_log}" ]] && echo yes || echo no)"
assert_eq "cross log exists" "yes" "$([[ -f "${cross_log}" ]] && echo yes || echo no)"
session_lines="$(wc -l < "${session_log}" | tr -d '[:space:]')"
assert_eq "session log has 1 row" "1" "${session_lines}"
cross_lines="$(wc -l < "${cross_log}" | tr -d '[:space:]')"
assert_eq "cross log has 1 row" "1" "${cross_lines}"
fix_val="$(jq -r '.fix' < "${session_log}")"
assert_eq "session row preserves fix" "Trim trailing newline in tail truncation" "${fix_val}"

# ----------------------------------------------------------------------
printf 'Test 5: full payload preserves all fields\n'
reset_logs
echo '{"fix":"Lock orphan cleanup","original_task":"v1.12 state-io extract","conditions":"verified, same-path, bounded","commit":"deadbeef"}' \
  | bash "${SCRIPT}" 2>/dev/null
assert_eq "fix preserved" "Lock orphan cleanup" "$(jq -r '.fix' < "${session_log}")"
assert_eq "original_task preserved" "v1.12 state-io extract" "$(jq -r '.original_task' < "${session_log}")"
assert_eq "conditions preserved" "verified, same-path, bounded" "$(jq -r '.conditions' < "${session_log}")"
assert_eq "commit preserved" "deadbeef" "$(jq -r '.commit' < "${session_log}")"
assert_eq "session id stamped" "${SESSION_ID}" "$(jq -r '(.session_id // .session)' < "${session_log}")"
# v1.31.0 Wave 4 (data-lens F-2 + F-3): ts is integer, _v stamped.
assert_eq "ts is integer" "number" "$(jq -r '.ts | type' < "${session_log}")"
assert_eq "_v schema version stamped" "1" "$(jq -r '._v' < "${session_log}")"

# ----------------------------------------------------------------------
printf 'Test 6: state counters increment monotonically\n'
reset_logs
echo '{"fix":"first"}'  | bash "${SCRIPT}" 2>/dev/null
echo '{"fix":"second"}' | bash "${SCRIPT}" 2>/dev/null
echo '{"fix":"third"}'  | bash "${SCRIPT}" 2>/dev/null
count_val="$(jq -r '.serendipity_count' < "${state_file}")"
assert_eq "count after 3 fires" "3" "${count_val}"
last_fix="$(jq -r '.last_serendipity_fix' < "${state_file}")"
assert_eq "last fix is third" "third" "${last_fix}"

# ----------------------------------------------------------------------
printf 'Test 7: cross-session log accumulates across SESSION_IDs\n'
reset_logs
mkdir -p "${TEST_STATE_ROOT}/other-session"
echo '{"fix":"sess A fix"}' | bash "${SCRIPT}" 2>/dev/null
SESSION_ID="other-session" bash -c "echo '{\"fix\":\"sess B fix\"}' | bash '${SCRIPT}'" 2>/dev/null
cross_count="$(wc -l < "${cross_log}" | tr -d '[:space:]')"
assert_eq "cross log has 2 rows across sessions" "2" "${cross_count}"
sessions="$(jq -r '(.session_id // .session)' < "${cross_log}" | sort -u | wc -l | tr -d '[:space:]')"
assert_eq "cross log spans 2 distinct sessions" "2" "${sessions}"

# ----------------------------------------------------------------------
printf 'Test 8: concurrent invocations preserve all writes (lock works)\n'
reset_logs
pids=()
for i in 1 2 3 4 5 6 7 8; do
  ( echo "{\"fix\":\"concurrent ${i}\"}" | bash "${SCRIPT}" 2>/dev/null ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done

session_lines="$(wc -l < "${session_log}" | tr -d '[:space:]')"
assert_eq "all 8 session writes landed" "8" "${session_lines}"
cross_lines="$(wc -l < "${cross_log}" | tr -d '[:space:]')"
assert_eq "all 8 cross writes landed" "8" "${cross_lines}"
final_count="$(jq -r '.serendipity_count' < "${state_file}")"
assert_eq "counter reached 8 (no lost updates)" "8" "${final_count}"
# State file is valid JSON
assert_eq "state json valid post-storm" "yes" "$(jq empty "${state_file}" 2>/dev/null && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 9: missing SESSION_ID exits 0 (hook-style guard)\n'
SESSION_ID="" rc=0
echo '{"fix":"x"}' | env -u SESSION_ID bash "${SCRIPT}" >/dev/null 2>&1 || rc=$?
assert_eq "missing SESSION_ID returns 0" "0" "${rc}"

# v1.40.x harness-improvement wave follow-up: silent-exit on missing
# SESSION_ID is the hook-safety contract, but when stdin carries an
# actual payload (non-TTY input) and SESSION_ID is unset, the script
# now emits a stderr warning so the caller knows the catch was
# dropped instead of logged. The hook-safety contract (exit code 0)
# is preserved — only the stderr surface changes.
printf 'Test 9b: missing SESSION_ID with piped payload emits stderr warning\n'
warn_output="$(echo '{"fix":"x"}' | env -u SESSION_ID bash "${SCRIPT}" 2>&1 >/dev/null)"
assert_contains "warning names SESSION_ID requirement" "SESSION_ID unset" "${warn_output}"
assert_contains "warning shows the explicit invocation form" "SESSION_ID=" "${warn_output}"

printf '\n=== Serendipity-Log Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
