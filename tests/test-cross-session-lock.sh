#!/usr/bin/env bash
#
# test-cross-session-lock.sh — stress-test with_cross_session_log_lock.
#
# v1.16.0 introduced this helper after a maintainability audit flagged
# bare `printf >> file` appends in record-archetype.sh and
# record-serendipity.sh as a silent-corruption window: two SubagentStop
# hooks across sessions in the same project can fire close enough in
# time to interleave bytes mid-row in the cross-session aggregate.
#
# The lock is what makes the next refactor safe (rotation, batching,
# multi-line writes will all reuse it), so a regression test that forks
# real processes is required — without it, a future change to the lock
# path or the stale-recovery semantics would silently regress the
# invariant.
#
# Each block sets up a fresh log file, forks N background writers, waits
# for all of them, then asserts row integrity (count + validity).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_ROOT}/state"
export SESSION_ID="test-cross-session-lock"
ensure_session_dir

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  rm -rf "${TEST_ROOT}"
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

# ===========================================================================
# Test 1: 30 concurrent writers — no rows lost, no torn lines.
#
# Replicates the failure mode the lock exists to prevent: 30 SubagentStop
# hooks across sessions all writing to the same cross-session log. Each
# writer appends a JSONL row keyed by writer index; afterwards we count
# rows AND validate every row parses as JSON with the expected index.
# ===========================================================================
printf 'with_cross_session_log_lock serializes parallel appends:\n'

LOG_FILE="${TEST_ROOT}/parallel-writers.jsonl"
WRITERS=30

# shellcheck disable=SC2329 # invoked indirectly (background subshell)
_write_row() {
  local idx="$1"
  local row
  row="$(jq -nc --argjson i "${idx}" '{idx:$i, payload:"x"}')"
  # shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
  _do_append() {
    printf '%s\n' "${row}" >> "${LOG_FILE}"
  }
  with_cross_session_log_lock "${LOG_FILE}" _do_append
}

for i in $(seq 1 "${WRITERS}"); do
  ( _write_row "${i}" ) &
done
wait

# Assert row count.
row_count="$(wc -l < "${LOG_FILE}" | tr -d '[:space:]')"
assert_eq "row count equals writer count" "${WRITERS}" "${row_count}"

# Assert every row parses as JSON. Per-line parse so a single torn row
# doesn't false-pass via slurp tolerance.
bad_rows=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] && continue
  if ! jq -e 'type == "object" and has("idx")' <<<"${line}" >/dev/null 2>&1; then
    bad_rows=$((bad_rows + 1))
  fi
done < "${LOG_FILE}"
assert_eq "all rows parse as JSON with idx field" "0" "${bad_rows}"

# Assert every writer's idx appears exactly once.
missing_or_dup=0
for i in $(seq 1 "${WRITERS}"); do
  hits="$(jq -r --argjson i "${i}" 'select(.idx == $i) | .idx' "${LOG_FILE}" | wc -l | tr -d '[:space:]')"
  if [[ "${hits}" != "1" ]]; then
    missing_or_dup=$((missing_or_dup + 1))
  fi
done
assert_eq "each writer's idx appears exactly once" "0" "${missing_or_dup}"

# Lock dir should be removed after the last writer finishes.
if [[ -d "${LOG_FILE}.lock" ]]; then
  printf '  FAIL: lock dir not cleaned up after all writers\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ===========================================================================
# Test 2: distinct log paths use distinct lock dirs (no false contention).
#
# Two writers hitting *different* logs at the same time must not block
# each other. A timing-based assertion is fragile, so we validate the
# property structurally: after parallel writes to N distinct logs, each
# log has exactly one row AND each lock dir is cleaned up.
# ===========================================================================
printf 'distinct log paths use distinct lock dirs:\n'

DISTINCT_LOGS_DIR="${TEST_ROOT}/distinct-logs"
mkdir -p "${DISTINCT_LOGS_DIR}"
N_LOGS=10

for i in $(seq 1 "${N_LOGS}"); do
  log="${DISTINCT_LOGS_DIR}/log-${i}.jsonl"
  (
    # shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
    _do_one_append() {
      printf '{"i":%s}\n' "${i}" >> "${log}"
    }
    with_cross_session_log_lock "${log}" _do_one_append
  ) &
done
wait

short_logs=0
leaked_locks=0
for i in $(seq 1 "${N_LOGS}"); do
  log="${DISTINCT_LOGS_DIR}/log-${i}.jsonl"
  count="$(wc -l < "${log}" | tr -d '[:space:]')"
  if [[ "${count}" != "1" ]]; then
    short_logs=$((short_logs + 1))
  fi
  if [[ -d "${log}.lock" ]]; then
    leaked_locks=$((leaked_locks + 1))
  fi
done
assert_eq "all distinct logs got exactly one row" "0" "${short_logs}"
assert_eq "all distinct lock dirs cleaned up" "0" "${leaked_locks}"

# ===========================================================================
# Test 3: missing log_path argument is rejected (defensive contract).
# ===========================================================================
printf 'missing log_path is rejected:\n'

set +e
with_cross_session_log_lock "" true 2>/dev/null
rc=$?
set -e
if [[ "${rc}" != "0" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: missing log_path returned 0 (should error)\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Test 4: stale-lock recovery — a left-over lock dir older than
# OMC_STATE_LOCK_STALE_SECS does not block subsequent writers.
#
# Simulate a crashed writer by leaving a lock dir whose mtime is older
# than the stale threshold. The next call must recover and write.
# ===========================================================================
printf 'stale lock dir is recovered:\n'

STALE_LOG="${TEST_ROOT}/stale.jsonl"
mkdir -p "${STALE_LOG}.lock"

# Backdate the lock dir's mtime well past the stale threshold. Use the
# exported value (or the same default the helper uses) plus a buffer so
# we don't race the threshold.
stale_secs="${OMC_STATE_LOCK_STALE_SECS:-30}"
backdate_to=$(( $(date +%s) - stale_secs - 60 ))
# Cross-platform mtime backdate: macOS `touch -t YYYYMMDDhhmm`.
touch -t "$(date -r "${backdate_to}" +%Y%m%d%H%M.%S 2>/dev/null || \
            date -d "@${backdate_to}" +%Y%m%d%H%M.%S 2>/dev/null)" \
  "${STALE_LOG}.lock" 2>/dev/null || true

# shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
_stale_writer() {
  printf '{"after":"stale"}\n' >> "${STALE_LOG}"
}
with_cross_session_log_lock "${STALE_LOG}" _stale_writer

stale_count="$(wc -l < "${STALE_LOG}" | tr -d '[:space:]')"
assert_eq "writer recovered past stale lock and wrote one row" "1" "${stale_count}"

# Lock dir should be cleaned up after the recovery.
if [[ -d "${STALE_LOG}.lock" ]]; then
  printf '  FAIL: stale lock dir not cleaned up after recovery\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ===========================================================================
# Test 5: parent dir is auto-created. If a writer points at a fresh
# path under HOME (e.g. first-ever run on a clean install), the helper
# must mkdir -p the parent before attempting the lock or the writer
# silently fails.
# ===========================================================================
printf 'parent dir is auto-created:\n'

DEEP_LOG="${TEST_ROOT}/never/before/seen/dir/log.jsonl"
# shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
_deep_writer() {
  printf '{"deep":1}\n' >> "${DEEP_LOG}"
}
with_cross_session_log_lock "${DEEP_LOG}" _deep_writer

if [[ -f "${DEEP_LOG}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: deep log path not created\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Test 6: rc-propagation. The helper claims `local rc=0; "$@" || rc=$?; …
# return "${rc}"`. That contract is what the writer refactors rely on with
# their `|| log_anomaly … || true` suffix — a regression that quietly turns
# this into `return 0` would silently swallow disk-full / read-only-HOME
# failures and never emit log_anomaly. Lock that contract in.
# ===========================================================================
printf 'with_cross_session_log_lock propagates inner rc:\n'

RC_LOG="${TEST_ROOT}/rc-propagation.jsonl"
# shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
_failer() { return 7; }
set +e
with_cross_session_log_lock "${RC_LOG}" _failer
inner_rc=$?
set -e
assert_eq "non-zero inner rc propagates to caller" "7" "${inner_rc}"
# And the lock dir must still be cleaned up even when the inner fn fails —
# a leaked lock here would block subsequent writers until stale-recovery.
if [[ -d "${RC_LOG}.lock" ]]; then
  printf '  FAIL: lock dir leaked after inner-fn failure\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ===========================================================================
# Test 7: held-lock max-attempts path. Test 4 covered stale-lock recovery,
# but the non-stale (genuinely-held) path is its own contract: after
# OMC_STATE_LOCK_MAX_ATTEMPTS failures, return 1 and emit log_anomaly. With
# max_attempts forced to 2, hold the lock from a backgrounded sleeper and
# verify the contending caller exits non-zero promptly. The sleeper is
# torn down via the EXIT trap so the test cleanup remains hermetic.
# ===========================================================================
printf 'held-lock max-attempts returns non-zero:\n'

HELD_LOG="${TEST_ROOT}/held.jsonl"
# Acquire the lock by hand so the sleeper holds the dir but exits cleanly
# (we control the rmdir; the sleeper just owns wall-clock time).
mkdir -p "$(dirname "${HELD_LOG}")"
mkdir "${HELD_LOG}.lock"
# Backdate slightly but stay well under the stale threshold so this test
# exercises the held-not-stale path, not the stale-recovery path.
touch "${HELD_LOG}.lock"

# shellcheck disable=SC2329 # invoked indirectly via with_cross_session_log_lock
_held_writer() { printf '{"x":1}\n' >> "${HELD_LOG}"; }
# Force the helper to give up fast. Also keep stale threshold high so we
# don't accidentally hit the recovery path.
prev_max="${OMC_STATE_LOCK_MAX_ATTEMPTS:-}"
prev_stale="${OMC_STATE_LOCK_STALE_SECS:-}"
export OMC_STATE_LOCK_MAX_ATTEMPTS=2
export OMC_STATE_LOCK_STALE_SECS=600
set +e
with_cross_session_log_lock "${HELD_LOG}" _held_writer
held_rc=$?
set -e
# Restore original env (best-effort).
if [[ -n "${prev_max}" ]]; then export OMC_STATE_LOCK_MAX_ATTEMPTS="${prev_max}"; else unset OMC_STATE_LOCK_MAX_ATTEMPTS; fi
if [[ -n "${prev_stale}" ]]; then export OMC_STATE_LOCK_STALE_SECS="${prev_stale}"; else unset OMC_STATE_LOCK_STALE_SECS; fi

assert_eq "contending caller returns non-zero when lock is held" "1" "${held_rc}"
# Inner function must NOT have run.
if [[ -f "${HELD_LOG}" ]]; then
  printf '  FAIL: inner fn ran despite contention (HELD_LOG should not exist)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# Release the held lock so cleanup is clean.
rmdir "${HELD_LOG}.lock" 2>/dev/null || true

# ===========================================================================
# Result
# ===========================================================================
printf '\nResults: pass=%d fail=%d\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
