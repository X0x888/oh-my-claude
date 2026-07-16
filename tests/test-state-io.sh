#!/usr/bin/env bash
# Focused tests for lib/state-io.sh — the extracted state I/O module.
#
# Existing tests (test-common-utilities.sh, test-concurrency.sh) exercise
# this surface loosely via the larger common.sh load. This file is the
# dedicated regression net for the lib.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
# shellcheck source=lib/value-shapes.sh
source "${REPO_ROOT}/tests/lib/value-shapes.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="state-io-test-session"
ensure_session_dir

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
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

assert_ne() {
  local label="$1" forbidden="$2" actual="$3"
  if [[ "${actual}" != "${forbidden}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected != %q got %q\n' "${label}" "${forbidden}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

reset_state() {
  rm -f "$(session_file "${STATE_JSON}")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
  _state_validated=0
}

# ----------------------------------------------------------------------
printf 'Test 1: read_state on missing key returns empty\n'
reset_state
got="$(read_state "no_such_key")"
assert_eq "missing key returns empty" "" "${got}"

# ----------------------------------------------------------------------
printf 'Test 2: write_state then read_state round-trip\n'
reset_state
write_state "alpha" "value-1"
got="$(read_state "alpha")"
assert_eq "round-trip preserves value" "value-1" "${got}"

# ----------------------------------------------------------------------
printf 'Test 3: write_state with shell-special characters (jq --arg escaping)\n'
reset_state
write_state "weird" "v\$alue with \`backticks\` and 'quotes' and \"doubles\""
got="$(read_state "weird")"
assert_eq "special chars survive --arg" "v\$alue with \`backticks\` and 'quotes' and \"doubles\"" "${got}"

# ----------------------------------------------------------------------
printf 'Test 4: write_state_batch atomic multi-key write\n'
reset_state
write_state_batch "k1" "v1" "k2" "v2" "k3" "v3"
assert_eq "batch k1" "v1" "$(read_state "k1")"
assert_eq "batch k2" "v2" "$(read_state "k2")"
assert_eq "batch k3" "v3" "$(read_state "k3")"

# ----------------------------------------------------------------------
printf 'Test 5: write_state_batch with odd arg count returns nonzero, no mutation\n'
reset_state
write_state "preexist" "stable"
rc=0
write_state_batch "lonely" 2>/dev/null || rc=$?
assert_ne "odd-arg returns nonzero" "0" "${rc}"
assert_eq "preexist untouched after odd-arg failure" "stable" "$(read_state "preexist")"
assert_eq "no half-written lonely key" "" "$(read_state "lonely")"

# ----------------------------------------------------------------------
printf 'Test 6: read_state fallback to plain file when JSON key missing\n'
reset_state
append_state "plain_file_key" "plain-value-1"
# JSON state has no "plain_file_key"; fallback should read from per-key file.
got="$(read_state "plain_file_key")"
# Trailing newline from `cat` is acceptable; strip for comparison.
assert_eq "fallback reads plain file" "plain-value-1" "${got%$'\n'}"

# ----------------------------------------------------------------------
printf 'Test 7: _ensure_valid_state recovers from corrupt JSON\n'
reset_state
# Inject corrupt JSON.
printf 'not valid json {{{\n' > "$(session_file "${STATE_JSON}")"
_state_validated=0
write_state "after_recovery" "ok"  # triggers _ensure_valid_state
got="$(read_state "after_recovery")"
assert_eq "post-recovery write/read works" "ok" "${got}"
# Archive file should exist
archive_count="$(find "$(session_file "")" -name "${STATE_JSON}.corrupt.*" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_ne "corrupt archive created" "0" "${archive_count}"

# ----------------------------------------------------------------------
printf 'Test 7b: corrupt-state recovery stamps sticky markers (v1.29.0 Wave 1)\n'
reset_state
# Inject corrupt JSON, trigger recovery, verify markers landed.
printf 'not valid json {{{\n' > "$(session_file "${STATE_JSON}")"
_state_validated=0
write_state "trigger" "go"  # triggers _ensure_valid_state recovery branch
recovered_ts="$(read_state "recovered_from_corrupt_ts")"
recovered_archive="$(read_state "recovered_from_corrupt_archive")"
assert_ne "T7b: recovered_from_corrupt_ts is non-empty" "" "${recovered_ts}"
assert_ne "T7b: recovered_from_corrupt_archive is non-empty" "" "${recovered_archive}"
# Marker MUST be a numeric epoch (router uses it as an arithmetic context).
ts_numeric="no"
[[ "${recovered_ts}" =~ ^[0-9]+$ ]] && ts_numeric="yes"
assert_eq "T7b: ts is numeric" "yes" "${ts_numeric}"
# Archive path must end in .corrupt.<digits>
archive_ok="no"
[[ "${recovered_archive}" == *.corrupt.* ]] && archive_ok="yes"
assert_eq "T7b: archive path ends in .corrupt.<ts>" "yes" "${archive_ok}"
# After clearing the markers, subsequent reads return empty (sticky pattern).
write_state "recovered_from_corrupt_ts" ""
write_state "recovered_from_corrupt_archive" ""
assert_eq "T7b: cleared marker reads empty" "" "$(read_state "recovered_from_corrupt_ts")"
assert_eq "T7b: cleared archive reads empty" "" "$(read_state "recovered_from_corrupt_archive")"

# ----------------------------------------------------------------------
printf 'Test 7c: read_state distinguishes empty-string from missing key (v1.29.0 metis F-3)\n'
reset_state
# Write a key with empty string AND create a sidecar file with the same name
# but stale data. Pre-fix: read_state would fall through to the sidecar.
# Post-fix: read_state honors the deliberate empty-string clear.
write_state "explicitly_empty" ""
printf 'STALE-SIDECAR-DATA' > "$(session_file "explicitly_empty")"
got_empty="$(read_state "explicitly_empty")"
assert_eq "T7c: explicit empty-string returns empty (NOT stale sidecar)" "" "${got_empty}"
# But missing-key fallback to sidecar still works (Test 6 invariant preserved).
got_missing="$(read_state "absent_key_with_sidecar")"
printf 'NEW-SIDECAR' > "$(session_file "absent_key_with_sidecar")"
got_missing="$(read_state "absent_key_with_sidecar")"
assert_eq "T7c: missing key still falls back to sidecar" "NEW-SIDECAR" "${got_missing}"

# ----------------------------------------------------------------------
printf 'Test 8: with_state_lock serializes 5 concurrent writers\n'
reset_state
pids=()
for i in 1 2 3 4 5; do
  ( with_state_lock write_state "ctr${i}" "value-${i}" ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done
# All 5 writes should have landed; serialized by lock.
for i in 1 2 3 4 5; do
  got="$(read_state "ctr${i}")"
  assert_eq "concurrent ctr${i} landed" "value-${i}" "${got}"
done
# Lock dir cleaned up
assert_eq "lock dir released after concurrent writers" "no" \
  "$([[ -d "$(session_file ".state.lock")" ]] && echo yes || echo no)"
assert_eq "atomic owner sentinel released after concurrent writers" "no" \
  "$([[ -e "$(session_file ".state.lock.owner")" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 8b: standalone write_state serializes concurrent writers by default\n'
reset_state
pids=()
for i in $(seq 1 20); do
  ( write_state "auto${i}" "value-${i}" ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done
jq empty "$(session_file "${STATE_JSON}")" >/dev/null
for i in $(seq 1 20); do
  got="$(read_state "auto${i}")"
  assert_eq "auto-locked writer auto${i} landed" "value-${i}" "${got}"
done
assert_eq "auto-lock dir released after standalone writers" "no" \
  "$([[ -d "$(session_file ".state.lock")" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 9: with_state_lock recovers from a stale lock\n'
reset_state
lockdir="$(session_file ".state.lock")"
mkdir -p "${lockdir}"
# Backdate the lockdir by 30 seconds (well beyond OMC_STATE_LOCK_STALE_SECS=5).
# `touch -t` accepts both BSD and GNU formats with [[CC]YY]MMDDhhmm[.ss].
backdate="$(date -v-30S +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null || echo "")"
if [[ -n "${backdate}" ]]; then
  touch -t "${backdate}" "${lockdir}"
fi
# Helper: simply set a key under the (presumed-stale) lock.
_acquire_after_stale() { write_state "after_stale" "ok"; }
with_state_lock _acquire_after_stale
got="$(read_state "after_stale")"
assert_eq "stale-lock recovery permits write" "ok" "${got}"

# ----------------------------------------------------------------------
printf 'Test 9b: live atomic owner is never reclaimed by stale mtime\n'
reset_state
lockdir="$(session_file ".state.lock")"
ownerfile="${lockdir}.owner"
_make_atomic_owner_fixture() {
  local fixture_pid="$1" fixture_label="$2"
  _fixture_claim="${ownerfile}.claim.${fixture_label}"
  _fixture_token="${fixture_pid}:${_fixture_claim##*/}:1"
  printf '%s\n' "${_fixture_token}" >"${_fixture_claim}"
  ln "${_fixture_claim}" "${ownerfile}"
  mkdir -p "${lockdir}"
  printf '%s\n' "${fixture_pid}" >"${lockdir}/holder.pid"
}
_make_atomic_owner_fixture "$$" "livefixture"
_live_claim="${_fixture_claim}"
_live_token="${_fixture_token}"
if [[ -n "${backdate}" ]]; then
  touch -t "${backdate}" "${lockdir}" "${ownerfile}" "${_live_claim}"
fi
_stale_before="${OMC_STATE_LOCK_STALE_SECS}"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_STALE_SECS=1
OMC_STATE_LOCK_MAX_ATTEMPTS=2
_live_owner_body() { write_state "false_recovery" "bad"; }
_live_owner_rc=0
with_state_lock _live_owner_body || _live_owner_rc=$?
OMC_STATE_LOCK_STALE_SECS="${_stale_before}"
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "stale mtime cannot recover a live atomic owner" "1" "${_live_owner_rc}"
assert_eq "live-owner rejection executes no competing body" "" \
  "$(read_state "false_recovery")"
assert_eq "live atomic owner remains authoritative" "${_live_token}" \
  "$(cat "${ownerfile}")"
rm -f "${ownerfile}" "${_live_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

# ----------------------------------------------------------------------
printf 'Test 9c: dead atomic owner is reclaimed immediately\n'
reset_state
_dead_owner_pid=999999
while kill -0 "${_dead_owner_pid}" 2>/dev/null; do
  _dead_owner_pid=$((_dead_owner_pid + 1))
done
_make_atomic_owner_fixture "${_dead_owner_pid}" "deadfixture"
_dead_claim="${_fixture_claim}"
_acquire_after_dead_owner() { write_state "after_dead_owner" "ok"; }
with_state_lock _acquire_after_dead_owner
assert_eq "dead atomic owner recovery permits write" "ok" \
  "$(read_state "after_dead_owner")"
assert_eq "dead atomic owner sentinel is cleaned" "no" \
  "$([[ -e "${ownerfile}" ]] && echo yes || echo no)"
assert_eq "dead atomic owner claim is cleaned" "no" \
  "$([[ -e "${_dead_claim}" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 9d: Bash 3 background owner PID is reclaimable after crash\n'
reset_state
_crash_ready="${TEST_STATE_ROOT}/crash-owner-ready"
_crash_owner_body() {
  : >"${_crash_ready}"
  while true; do sleep 1; done
}
( with_state_lock _crash_owner_body ) &
_crash_owner_pid=$!
for _crash_wait in $(seq 1 500); do
  [[ -f "${_crash_ready}" ]] && break
  kill -0 "${_crash_owner_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "background owner reaches locked body" "yes" \
  "$([[ -f "${_crash_ready}" ]] && printf yes || printf no)"
assert_eq "atomic sentinel records the real Bash 3 subshell PID" \
  "${_crash_owner_pid}" "$(cut -d: -f1 "${ownerfile}")"
kill -9 "${_crash_owner_pid}" 2>/dev/null || true
wait "${_crash_owner_pid}" 2>/dev/null || true
_acquire_after_crashed_subshell() { write_state "after_crashed_subshell" "ok"; }
with_state_lock _acquire_after_crashed_subshell
assert_eq "crashed background owner is reclaimed immediately" "ok" \
  "$(read_state "after_crashed_subshell")"
assert_eq "crashed background owner leaves no sentinel" "no" \
  "$([[ -e "${ownerfile}" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 9e: dead-owner observer cannot remove a successor lock\n'
reset_state
_old_dead_pid=999999
while kill -0 "${_old_dead_pid}" 2>/dev/null; do
  _old_dead_pid=$((_old_dead_pid + 1))
done
_make_atomic_owner_fixture "${_old_dead_pid}" "oldracefixture"
_old_race_claim="${_fixture_claim}"
_successor_claim="${ownerfile}.claim.successorfixture"
_successor_token="$$:${_successor_claim##*/}:1"
_owner_race_shim="${TEST_STATE_ROOT}/owner-race-shim"
mkdir -p "${_owner_race_shim}"
printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}:${2:-}" in' \
  '  "${OMC_OWNER_RACE_OLD_CLAIM}:"*".reap."*)' \
  '    /bin/rm -f "${OMC_OWNER_RACE_OLD_CLAIM}" "${OMC_OWNER_RACE_FILE}"' \
  '    printf "%s\n" "${OMC_OWNER_RACE_SUCCESSOR}" >"${OMC_OWNER_RACE_SUCCESSOR_CLAIM}"' \
  '    /bin/ln "${OMC_OWNER_RACE_SUCCESSOR_CLAIM}" "${OMC_OWNER_RACE_FILE}"' \
  '    printf "%s\n" "${OMC_OWNER_RACE_SUCCESSOR_PID}" >"${OMC_OWNER_RACE_PIDFILE}"' \
  '    ;;' \
  'esac' \
  'exec /bin/mv "$@"' \
  >"${_owner_race_shim}/mv"
chmod +x "${_owner_race_shim}/mv"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=1
_owner_race_rc=0
PATH="${_owner_race_shim}:${PATH}" \
  OMC_OWNER_RACE_FILE="${ownerfile}" \
  OMC_OWNER_RACE_OLD_CLAIM="${_old_race_claim}" \
  OMC_OWNER_RACE_SUCCESSOR="${_successor_token}" \
  OMC_OWNER_RACE_SUCCESSOR_CLAIM="${_successor_claim}" \
  OMC_OWNER_RACE_SUCCESSOR_PID="$$" \
  OMC_OWNER_RACE_PIDFILE="${lockdir}/holder.pid" \
  _with_lockdir "${lockdir}" "owner-race-test" true \
  || _owner_race_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "waiter declines acquisition after successor wins" "1" \
  "${_owner_race_rc}"
assert_eq "successor atomic owner survives stale observer" \
  "${_successor_token}" "$(cat "${ownerfile}")"
assert_eq "successor compatibility PID survives stale observer" "$$" \
  "$(cat "${lockdir}/holder.pid")"
rm -f "${ownerfile}" "${_old_race_claim}" "${_successor_claim}" \
  "${lockdir}/holder.pid"
rmdir "${lockdir}"

# ----------------------------------------------------------------------
printf 'Test 9f: a dead elected reaper can be taken over\n'
reset_state
_takeover_owner_pid=$((_old_dead_pid + 1))
while kill -0 "${_takeover_owner_pid}" 2>/dev/null; do
  _takeover_owner_pid=$((_takeover_owner_pid + 1))
done
_make_atomic_owner_fixture "${_takeover_owner_pid}" "takeoverowner"
_takeover_owner_claim="${_fixture_claim}"
_takeover_reaper_pid=$((_takeover_owner_pid + 1))
while kill -0 "${_takeover_reaper_pid}" 2>/dev/null; do
  _takeover_reaper_pid=$((_takeover_reaper_pid + 1))
done
_takeover_reaper_claim="${ownerfile}.claim.deadreaper"
_takeover_reaper_token="${_takeover_reaper_pid}:${_takeover_reaper_claim##*/}:1"
printf '%s\n' "${_takeover_reaper_token}" >"${_takeover_reaper_claim}"
_takeover_reap="${_takeover_owner_claim}.reap.${_takeover_reaper_claim##*/}"
mv "${_takeover_owner_claim}" "${_takeover_reap}"
_acquire_after_dead_reaper() { write_state "after_dead_reaper" "ok"; }
with_state_lock _acquire_after_dead_reaper
assert_eq "dead reaper takeover permits write" "ok" \
  "$(read_state "after_dead_reaper")"
assert_eq "dead reaper claim is cleaned" "no" \
  "$([[ -e "${_takeover_reaper_claim}" ]] && echo yes || echo no)"
assert_eq "dead reaper artifact is cleaned" "0" \
  "$(find "${lockdir%/*}" -maxdepth 1 \
      -name "${_takeover_owner_claim##*/}.reap.*" -print | wc -l | tr -d '[:space:]')"

# ----------------------------------------------------------------------
printf 'Test 9g: killed waiters leave no orphan claims after owner release\n'
reset_state
_claim_gc_ready="${TEST_STATE_ROOT}/claim-gc-ready"
_claim_gc_release="${TEST_STATE_ROOT}/claim-gc-release"
_claim_gc_owner_body() {
  : >"${_claim_gc_ready}"
  while [[ ! -f "${_claim_gc_release}" ]]; do sleep 0.01; done
}
( with_state_lock _claim_gc_owner_body ) &
_claim_gc_owner_pid=$!
for _claim_gc_wait in $(seq 1 500); do
  [[ -f "${_claim_gc_ready}" ]] && break
  sleep 0.01
done
assert_eq "claim-GC owner reaches locked body" "yes" \
  "$([[ -f "${_claim_gc_ready}" ]] && printf yes || printf no)"
( with_state_lock true ) &
_claim_gc_waiter_pid=$!
for _claim_gc_wait in $(seq 1 500); do
  _claim_gc_count="$(find "${lockdir%/*}" -maxdepth 1 \
    -name "${ownerfile##*/}.claim.*" ! -name '*.reap.*' -print \
    | wc -l | tr -d '[:space:]')"
  [[ "${_claim_gc_count}" -ge 2 ]] && break
  sleep 0.01
done
assert_eq "waiting contender publishes a unique claim" "yes" \
  "$([[ "${_claim_gc_count:-0}" -ge 2 ]] && printf yes || printf no)"
kill -9 "${_claim_gc_waiter_pid}" 2>/dev/null || true
wait "${_claim_gc_waiter_pid}" 2>/dev/null || true
: >"${_claim_gc_release}"
wait "${_claim_gc_owner_pid}"
# If the waiter was still observable during the first owner's final scan, the
# next successful owner must make the same bounded sweep and collect it.
with_state_lock true
assert_eq "later acquisition scavenges killed-waiter claim" "0" \
  "$(find "${lockdir%/*}" -maxdepth 1 \
      -name "${ownerfile##*/}.claim.*" -print | wc -l | tr -d '[:space:]')"

# ----------------------------------------------------------------------
printf 'Test 9h: post-unlink reaper crash residue is scavenged\n'
reset_state
_orphan_owner_pid=$((_takeover_reaper_pid + 1))
while kill -0 "${_orphan_owner_pid}" 2>/dev/null; do
  _orphan_owner_pid=$((_orphan_owner_pid + 1))
done
_orphan_reaper_pid=$((_orphan_owner_pid + 1))
while kill -0 "${_orphan_reaper_pid}" 2>/dev/null; do
  _orphan_reaper_pid=$((_orphan_reaper_pid + 1))
done
_orphan_owner_claim="${ownerfile}.claim.orphanowner"
_orphan_reaper_claim="${ownerfile}.claim.orphanreaper"
_orphan_owner_token="${_orphan_owner_pid}:${_orphan_owner_claim##*/}:1"
_orphan_reaper_token="${_orphan_reaper_pid}:${_orphan_reaper_claim##*/}:1"
printf '%s\n' "${_orphan_reaper_token}" >"${_orphan_reaper_claim}"
_orphan_reap="${_orphan_owner_claim}.reap.${_orphan_reaper_claim##*/}"
printf '%s\n' "${_orphan_owner_token}" >"${_orphan_reap}"
with_state_lock true
assert_eq "orphan post-unlink reap artifact is removed" "no" \
  "$([[ -e "${_orphan_reap}" ]] && printf yes || printf no)"
assert_eq "orphan post-unlink reaper claim is removed" "no" \
  "$([[ -e "${_orphan_reaper_claim}" ]] && printf yes || printf no)"

# ----------------------------------------------------------------------
printf 'Test 9i: stale reap with a reused claim name cannot block takeover\n'
reset_state
_reuse_owner_pid=$((_orphan_reaper_pid + 1))
while kill -0 "${_reuse_owner_pid}" 2>/dev/null; do
  _reuse_owner_pid=$((_reuse_owner_pid + 1))
done
_reuse_old_reaper_pid=$((_reuse_owner_pid + 1))
while kill -0 "${_reuse_old_reaper_pid}" 2>/dev/null; do
  _reuse_old_reaper_pid=$((_reuse_old_reaper_pid + 1))
done
_reuse_current_reaper_pid=$((_reuse_old_reaper_pid + 1))
while kill -0 "${_reuse_current_reaper_pid}" 2>/dev/null; do
  _reuse_current_reaper_pid=$((_reuse_current_reaper_pid + 1))
done
_reuse_owner_claim="${ownerfile}.claim.reused"
_reuse_owner_token="${_reuse_owner_pid}:${_reuse_owner_claim##*/}:2"
_reuse_old_reaper_claim="${ownerfile}.claim.aaa"
_reuse_current_reaper_claim="${ownerfile}.claim.zzz"
printf '%s\n' "${_reuse_old_reaper_pid}:${_reuse_old_reaper_claim##*/}:1" \
  >"${_reuse_old_reaper_claim}"
printf '%s\n' "${_reuse_current_reaper_pid}:${_reuse_current_reaper_claim##*/}:1" \
  >"${_reuse_current_reaper_claim}"
printf '%s\n' "${_reuse_owner_token}" >"${_reuse_owner_claim}"
ln "${_reuse_owner_claim}" "${ownerfile}"
mkdir -p "${lockdir}"
printf '%s\n' "${_reuse_owner_pid}" >"${lockdir}/holder.pid"
_reuse_old_reap="${_reuse_owner_claim}.reap.${_reuse_old_reaper_claim##*/}"
_reuse_current_reap="${_reuse_owner_claim}.reap.${_reuse_current_reaper_claim##*/}"
printf '%s\n' "${_orphan_owner_token}" >"${_reuse_old_reap}"
mv "${_reuse_owner_claim}" "${_reuse_current_reap}"
(
  # Exercise the takeover content bind itself; the production orphan sweep is
  # independently pinned by Test 9h and would otherwise remove the old row.
  _cleanup_orphan_lock_claims() { :; }
  _acquire_after_reused_claim() { write_state "after_reused_claim" "ok"; }
  with_state_lock _acquire_after_reused_claim
)
assert_eq "matching current reap wins past stale reused-name residue" "ok" \
  "$(read_state "after_reused_claim")"
rm -f "${_reuse_old_reap}" "${_reuse_old_reaper_claim}"

# ----------------------------------------------------------------------
printf 'Test 9j: mixed legacy/new crash shapes recover without harming live legacy owners\n'
reset_state
_mixed_atomic_pid=$((_reuse_current_reaper_pid + 1))
while kill -0 "${_mixed_atomic_pid}" 2>/dev/null; do
  _mixed_atomic_pid=$((_mixed_atomic_pid + 1))
done
_mixed_legacy_dead_pid=$((_mixed_atomic_pid + 1))
while kill -0 "${_mixed_legacy_dead_pid}" 2>/dev/null; do
  _mixed_legacy_dead_pid=$((_mixed_legacy_dead_pid + 1))
done
_make_atomic_owner_fixture "${_mixed_atomic_pid}" "mixeddead"
printf '%s\n' "${_mixed_legacy_dead_pid}" >"${lockdir}/holder.pid"
_acquire_after_mixed_dead() { write_state "after_mixed_dead" "ok"; }
with_state_lock _acquire_after_mixed_dead
assert_eq "dead mismatched legacy holder becomes recoverable" "ok" \
  "$(read_state "after_mixed_dead")"
assert_eq "mixed dead recovery leaves no lock directory" "no" \
  "$([[ -d "${lockdir}" ]] && printf yes || printf no)"

reset_state
_make_atomic_owner_fixture "${_mixed_atomic_pid}" "mixedlive"
_mixed_live_claim="${_fixture_claim}"
printf '%s\n' "$$" >"${lockdir}/holder.pid"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=2
_mixed_live_rc=0
with_state_lock true || _mixed_live_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "live mismatched legacy holder is not acquired over" "1" \
  "${_mixed_live_rc}"
assert_eq "dead overlay sentinel is cleared to expose legacy recovery" "no" \
  "$([[ -e "${ownerfile}" ]] && printf yes || printf no)"
assert_eq "live mismatched legacy directory remains authoritative" "$$" \
  "$(cat "${lockdir}/holder.pid")"
rm -f "${_mixed_live_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

# ----------------------------------------------------------------------
printf 'Test 9k: orphan GC rechecks canonical ownership at deletion boundary\n'
reset_state
_gc_turn_owner_claim="${ownerfile}.claim.turn-a"
_gc_turn_candidate_claim="${ownerfile}.claim.turn-b"
_gc_turn_candidate_pid=$((_mixed_legacy_dead_pid + 1))
while kill -0 "${_gc_turn_candidate_pid}" 2>/dev/null; do
  _gc_turn_candidate_pid=$((_gc_turn_candidate_pid + 1))
done
_gc_turn_owner_token="$$:${_gc_turn_owner_claim##*/}:1"
_gc_turn_candidate_token="${_gc_turn_candidate_pid}:${_gc_turn_candidate_claim##*/}:1"
printf '%s\n' "${_gc_turn_owner_token}" >"${_gc_turn_owner_claim}"
printf '%s\n' "${_gc_turn_candidate_token}" >"${_gc_turn_candidate_claim}"
ln "${_gc_turn_owner_claim}" "${ownerfile}"
(
  kill() {
    if [[ "${1:-}" == "-0" && "${2:-}" == "${_gc_turn_candidate_pid}" ]]; then
      rm -f "${ownerfile}"
      ln "${_gc_turn_candidate_claim}" "${ownerfile}"
      return 1
    fi
    builtin kill "$@"
  }
  _cleanup_orphan_lock_claims "${ownerfile}"
)
assert_eq "turnover candidate becomes the canonical token" \
  "${_gc_turn_candidate_token}" "$(cat "${ownerfile}")"
assert_eq "GC preserves a candidate that became canonical after snapshot" "yes" \
  "$([[ -f "${_gc_turn_candidate_claim}" ]] && printf yes || printf no)"
rm -f "${ownerfile}" "${_gc_turn_owner_claim}" "${_gc_turn_candidate_claim}"

# ----------------------------------------------------------------------
printf 'Test 10: with_state_lock_batch is one-shot atomic\n'
reset_state
with_state_lock_batch "atomic_a" "1" "atomic_b" "2" "atomic_c" "3"
assert_eq "batch_lock atomic_a" "1" "$(read_state "atomic_a")"
assert_eq "batch_lock atomic_b" "2" "$(read_state "atomic_b")"
assert_eq "batch_lock atomic_c" "3" "$(read_state "atomic_c")"
assert_eq "batch_lock released cleanly" "no" \
  "$([[ -d "$(session_file ".state.lock")" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 11: append_limited_state truncates to max_lines\n'
reset_state
target_key="trim_log"
for i in $(seq 1 25); do
  append_limited_state "${target_key}" "line ${i}" 10
done
file="$(session_file "${target_key}")"
line_count="$(wc -l < "${file}" | tr -d '[:space:]')"
assert_eq "append_limited_state caps file to 10 lines" "10" "${line_count}"
# The last line should be "line 25" (most recent kept).
last_line="$(tail -1 "${file}")"
assert_eq "tail-truncation keeps newest" "line 25" "${last_line}"

# ----------------------------------------------------------------------
printf 'Test 12: session_file is path-isolated under STATE_ROOT/SESSION_ID\n'
got="$(session_file "thing.json")"
case "${got}" in
  "${STATE_ROOT}/${SESSION_ID}/thing.json") pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: session_file path shape unexpected: %s\n' "${got}" >&2
    fail=$((fail + 1))
    ;;
esac

# ----------------------------------------------------------------------
# Portable read-into-array helper for bash 3.2 (mapfile is bash 4+).
# Producer must write to file ${_tmp_capture}; this then reads it back.
# This pattern avoids the subshell-loses-assignment trap of `producer | reader`.
#
# v1.34.0: switched to RS-delimited (`read -r -d $'\x1e'`) to match the
# read_state_keys contract change. The previous newline-delimited
# decode mis-aligned positional indices whenever a stored value
# contained an embedded newline (the entire reason Bug B existed).
got=()
_tmp_capture="$(mktemp)"
_capture_replay() {
  got=()
  local _line
  while IFS= read -r -d $'\x1e' _line; do
    got[${#got[@]}]="${_line}"
  done <"${_tmp_capture}"
}

# ----------------------------------------------------------------------
printf 'Test 13: read_state_keys bulk-reads N keys with positional alignment (v1.27.0 F-018)\n'
reset_state
write_state_batch "alpha" "one" "beta" "two" "gamma" "three"

# Read 3 keys in given order.
read_state_keys "alpha" "beta" "gamma" > "${_tmp_capture}"; _capture_replay
assert_eq "T13: 3 keys returned" "3" "${#got[@]}"
assert_eq "T13: alpha"   "one"   "${got[0]}"
assert_eq "T13: beta"    "two"   "${got[1]}"
assert_eq "T13: gamma"   "three" "${got[2]}"

# Order is preserved when caller permutes.
read_state_keys "gamma" "alpha" "beta" > "${_tmp_capture}"; _capture_replay
assert_eq "T13: order preserved gamma" "three" "${got[0]}"
assert_eq "T13: order preserved alpha" "one"   "${got[1]}"
assert_eq "T13: order preserved beta"  "two"   "${got[2]}"

# Missing keys emit empty lines, alignment preserved.
read_state_keys "alpha" "missing_key" "beta" "also_missing" > "${_tmp_capture}"; _capture_replay
assert_eq "T13: 4 lines for 4 args" "4" "${#got[@]}"
assert_eq "T13: present alpha"     "one" "${got[0]}"
assert_eq "T13: empty for missing" ""    "${got[1]}"
assert_eq "T13: present beta"      "two" "${got[2]}"
assert_eq "T13: empty for missing 2" ""  "${got[3]}"

# Empty argv → no output, exit 0.
output="$(read_state_keys 2>&1)"
assert_eq "T13: empty argv → empty output" "" "${output}"

# Missing state file → emits N empty lines for N args.
rm -f "$(session_file "${STATE_JSON}")"
read_state_keys "x" "y" "z" > "${_tmp_capture}"; _capture_replay
assert_eq "T13: 3 empty lines when state file missing" "3" "${#got[@]}"

# ----------------------------------------------------------------------
printf 'Test 14: read_state_keys returns all values from one call (perf invariant)\n'
reset_state
write_state_batch "k1" "v1" "k2" "v2" "k3" "v3" "k4" "v4" "k5" "v5"
read_state_keys "k1" "k2" "k3" "k4" "k5" > "${_tmp_capture}"; _capture_replay
assert_eq "T14: 5 values from one invocation" "5" "${#got[@]}"
assert_eq "T14: v1" "v1" "${got[0]}"
assert_eq "T14: v5" "v5" "${got[4]}"

# ----------------------------------------------------------------------
printf 'Test 15: empty-string and missing keys are intentionally indistinguishable\n'
# Documents the design choice: read_state_keys collapses
# write_state(key, "") and "key never written" to the same empty-line
# output. Call sites that need to distinguish must use read_state with
# its individual-file fallback; bulk reads are JSON-state-only.
reset_state
write_state_batch "explicit_empty" "" "explicit_value" "set"
read_state_keys "explicit_empty" "missing_key" "explicit_value" > "${_tmp_capture}"; _capture_replay
assert_eq "T15: 3 lines for 3 args" "3" "${#got[@]}"
assert_eq "T15: explicit empty -> empty line"     "" "${got[0]}"
assert_eq "T15: missing -> empty line"            "" "${got[1]}"
assert_eq "T15: explicit value preserved"      "set" "${got[2]}"
# Final assertion: the empty-string and missing cases are byte-identical
# under read_state_keys (this is the documented behavior).
assert_eq "T15: indistinguishable (got[0] == got[1])" "${got[0]}" "${got[1]}"

# ----------------------------------------------------------------------
printf 'Test 16: with_skips_lock emits log_anomaly on exhaustion (v1.30.0 Wave 2 / sre-lens F-5)\n'
# Locks in the v1.29.0 sre-lens F-5 fix: with_skips_lock previously
# returned 1 silently on exhaustion, missing the log_anomaly emit that
# every sister lock had. v1.30.0 routes all 7 lock helpers through
# _with_lockdir, which threads the caller's name through as the
# anomaly tag. Without this regression-lock, a future refactor that
# bypasses _with_lockdir's anomaly emit would silently regress F-5.
_HOOK_LOG_BACKUP="${HOOK_LOG}"
_TEST_HOOK_LOG="$(mktemp)"
HOOK_LOG="${_TEST_HOOK_LOG}"
_GATE_SKIPS_LOCK_BACKUP="${_GATE_SKIPS_LOCK}"
_TEST_LOCK_DIR="${TEST_STATE_ROOT}/.skips-lock-test"
_GATE_SKIPS_LOCK="${_TEST_LOCK_DIR}"
mkdir -p "${_TEST_LOCK_DIR}"

# Stale window large enough that recovery cannot reclaim within the
# test; attempt cap small so exhaustion is fast.
_lock_stale_backup="${OMC_STATE_LOCK_STALE_SECS}"
_lock_attempts_backup="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_STALE_SECS=600
OMC_STATE_LOCK_MAX_ATTEMPTS=2

# Capture rc via `|| _rc=$?` because `set -e` is in effect at the top
# of this file; a bare `with_skips_lock true` followed by `_rc=$?`
# would terminate the test on the first non-zero return.
_rc=0
with_skips_lock true || _rc=$?

OMC_STATE_LOCK_STALE_SECS="${_lock_stale_backup}"
OMC_STATE_LOCK_MAX_ATTEMPTS="${_lock_attempts_backup}"
_GATE_SKIPS_LOCK="${_GATE_SKIPS_LOCK_BACKUP}"
rmdir "${_TEST_LOCK_DIR}" 2>/dev/null || rm -rf "${_TEST_LOCK_DIR}"

assert_eq "T16: with_skips_lock returns nonzero on exhaustion" "1" "${_rc}"

# Hook log row format: `{ts}  [anomaly]  {tag}  {detail}`. Grep for the
# bare tag (with_skips_lock) — the diagnostic surface other locks share.
if grep -q "\\[anomaly\\][[:space:]]*with_skips_lock[[:space:]]" "${_TEST_HOOK_LOG}" 2>/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: T16: hooks.log missing anomaly row tagged with_skips_lock; got:\n%s\n' "$(cat "${_TEST_HOOK_LOG}")" >&2
  fail=$((fail + 1))
fi

if grep -q "lock not acquired after" "${_TEST_HOOK_LOG}" 2>/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: T16: anomaly detail missing lock-not-acquired phrase\n' >&2
  fail=$((fail + 1))
fi

HOOK_LOG="${_HOOK_LOG_BACKUP}"
rm -f "${_TEST_HOOK_LOG}"

# ----------------------------------------------------------------------
printf 'Test 17: _with_lockdir routes the caller tag through to log_anomaly (v1.30.0 Wave 2)\n'
# Sibling regression: an arbitrary caller-provided tag must appear
# verbatim in the anomaly row. Locks in the contract that the
# unification preserves per-helper attribution in /ulw-report.
_HOOK_LOG_BACKUP="${HOOK_LOG}"
_TEST_HOOK_LOG="$(mktemp)"
HOOK_LOG="${_TEST_HOOK_LOG}"
_TEST_LOCK_DIR="${TEST_STATE_ROOT}/.tag-routing-test"
mkdir -p "${_TEST_LOCK_DIR}"

OMC_STATE_LOCK_STALE_SECS=600
OMC_STATE_LOCK_MAX_ATTEMPTS=1

_rc=0
_with_lockdir "${_TEST_LOCK_DIR}" "synthetic_tag_for_test" true || _rc=$?

OMC_STATE_LOCK_STALE_SECS="${_lock_stale_backup}"
OMC_STATE_LOCK_MAX_ATTEMPTS="${_lock_attempts_backup}"
rmdir "${_TEST_LOCK_DIR}" 2>/dev/null || rm -rf "${_TEST_LOCK_DIR}"

assert_eq "T17: _with_lockdir returns nonzero on exhaustion" "1" "${_rc}"
if grep -q "synthetic_tag_for_test" "${_TEST_HOOK_LOG}" 2>/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: T17: hooks.log missing synthetic_tag_for_test in anomaly row; got:\n%s\n' "$(cat "${_TEST_HOOK_LOG}")" >&2
  fail=$((fail + 1))
fi

HOOK_LOG="${_HOOK_LOG_BACKUP}"
rm -f "${_TEST_HOOK_LOG}"

# v1.31.2 quality-reviewer F-3 followup: re-entrant with_state_lock
# detection. append_limited_state in v1.31.2 wraps its body in
# with_state_lock; some callers (record-pending-agent.sh) wrap a
# function that itself calls append_limited_state inside an outer
# with_state_lock. Without re-entrancy detection, the inner mkdir
# collides with the outer's already-held lockdir and the body
# silently drops.

printf '\nTest 18: with_state_lock re-entrant detection (skips inner acquire when outer is held)\n'
SESSION_ID="test-reentrant-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"

_inner_count=0
_inner_body() { _inner_count=$((_inner_count + 1)); }
_outer_body() {
  with_state_lock _inner_body
  with_state_lock _inner_body
}
with_state_lock _outer_body

assert_eq "T18: nested with_state_lock executes inner body twice" "2" "${_inner_count}"

# After the outer body completes, the marker MUST be unset so a
# subsequent top-level with_state_lock call goes through the
# acquisition path rather than treating itself as nested.
if [[ -n "${_OMC_STATE_LOCK_HELD:-}" ]]; then
  printf '  FAIL: T18: _OMC_STATE_LOCK_HELD leaked after outer body returned\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# A subsequent fresh acquisition must lock normally.
_post_inner=0
_post_body() { _post_inner=1; }
with_state_lock _post_body
assert_eq "T18: post-nested with_state_lock still acquires + runs body" "1" "${_post_inner}"

rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 19: Fixture-realism — round-trip every adversarial value class
#
# Why this exists: pre-Bug-B Test 13 used identifier-shaped fixtures
# ("alpha", "one") and missed the multi-line-value class entirely. Every
# new positional API test from now on must run against the full
# adversarial set (CONTRIBUTING.md "Fixture realism rule"). This test
# is the canonical regression net for that rule on read_state /
# write_state — without it, a future caller of read_state with a
# value containing newlines / tabs / RS / control bytes regresses
# silently.
printf '\nTest 19: read_state / write_state survive every adversarial value shape\n'
SESSION_ID="test-shape-invariants-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
reset_state
assert_value_shape_invariants "scalar_round_trip" write_state read_state
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true

# ----------------------------------------------------------------------
# Test 20: Fixture-realism — bulk read positional alignment under
# every adversarial value class, with the offending value rotated
# through positions 0, 3, and 5. This is the structural regression
# net for Bug B: positions 5-6 in production hold consequence-bearing
# recovery markers; an adversarial value at position 0 must NOT
# overflow into those slots regardless of its byte content.
printf '\nTest 20: read_state_keys positional alignment under adversarial value shapes\n'
SESSION_ID="test-bulk-shape-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
reset_state
assert_bulk_value_shape_invariants "bulk_pos_align" write_state_batch read_state_keys
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

printf '\n=== State-IO Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
