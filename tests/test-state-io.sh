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

# The per-process validation cache must not trust an external NUL-free rewrite.
# This is the same race shape as a concurrent hook replacing session_state.json
# after an earlier read/write in a long-lived test process.
printf 'Test 7a: cached validation detects later NUL-free corruption\n'
reset_state
write_state "cache_seed" "valid"
printf 'externally corrupted but NUL free {{{\n' \
  > "$(session_file "${STATE_JSON}")"
write_state "after_cached_recovery" "ok"
assert_eq "cached corrupt rewrite is recovered" "ok" \
  "$(read_state "after_cached_recovery")"

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
  local fixture_pid="$1" fixture_label="$2" fixture_birth="${3:-}"
  _fixture_claim="${ownerfile}.claim.${fixture_label}"
  _fixture_token="${fixture_pid}:${_fixture_claim##*/}:1"
  [[ -z "${fixture_birth}" ]] \
    || _fixture_token="${_fixture_token}:${fixture_birth}"
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
printf 'Test 9d2: partial release retains exact claim for successor reap\n'
reset_state
_partial_release_rc_file="${TEST_STATE_ROOT}/partial-release.rc"
(
  _partial_release_rc=0
  OMC_TEST_LOCK_RELEASE_FAIL_LOCKDIR="${lockdir}" \
  OMC_TEST_LOCK_RELEASE_FAIL_STAGE="after-lockdir" \
    _with_lockdir "${lockdir}" "partial-release-test" true \
      || _partial_release_rc=$?
  printf '%s\n' "${_partial_release_rc}" >"${_partial_release_rc_file}"
) &
_partial_release_pid=$!
wait "${_partial_release_pid}"
_partial_release_token="$(cat "${ownerfile}" 2>/dev/null || true)"
_partial_release_claim_name="${_partial_release_token#*:}"
_partial_release_claim_name="${_partial_release_claim_name%%:*}"
_partial_release_claim="${ownerfile%/*}/${_partial_release_claim_name}"
assert_eq "partial release reports failure" "1" \
  "$(<"${_partial_release_rc_file}")"
assert_eq "partial release preserves canonical owner" "yes" \
  "$([[ -f "${ownerfile}" && ! -L "${ownerfile}" ]] \
    && printf yes || printf no)"
assert_eq "partial release preserves exact election claim" \
  "${_partial_release_token}" \
  "$(cat "${_partial_release_claim}" 2>/dev/null || true)"
assert_eq "partial release removed compatibility directory first" "no" \
  "$([[ -e "${lockdir}" || -L "${lockdir}" ]] \
    && printf yes || printf no)"
_acquire_after_partial_release() {
  write_state "after_partial_release" "ok"
}
with_state_lock _acquire_after_partial_release
assert_eq "successor reaps partial release and enters" "ok" \
  "$(read_state "after_partial_release")"
assert_eq "successor removes partial-release owner" "no" \
  "$([[ -e "${ownerfile}" || -L "${ownerfile}" ]] \
    && printf yes || printf no)"
assert_eq "successor removes partial-release claim" "no" \
  "$([[ -e "${_partial_release_claim}" \
      || -L "${_partial_release_claim}" ]] \
    && printf yes || printf no)"
rm -f "${_partial_release_rc_file}"

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

# SIGKILL can also land in the tiny pre-publication window after mktemp but
# before the complete token is linked into `.claim.*`. This file is never
# ownership authority and must not accumulate indefinitely.
_claim_gc_prepare="${ownerfile}.prepare.crash-residue"
: >"${_claim_gc_prepare}"
touch -t 200001010000 "${_claim_gc_prepare}"
with_state_lock true
assert_eq "later acquisition scavenges stale preparation residue" "no" \
  "$([[ -e "${_claim_gc_prepare}" ]] && printf yes || printf no)"

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
printf 'Test 9l: live reused PID with a different birth is reclaimed\n'
reset_state
_make_atomic_owner_fixture "$$" "reused-pid" "old.birth"
_reused_pid_claim="${_fixture_claim}"
_birth_seam="${TEST_STATE_ROOT}/birth-identities.tsv"
printf '%s\t%s\n' "$$" "new.birth" >"${_birth_seam}"
_acquire_after_reused_pid() { write_state "after_reused_pid" "ok"; }
OMC_TEST_PROCESS_BIRTH_IDENTITY_FILE="${_birth_seam}" \
  with_state_lock _acquire_after_reused_pid
assert_eq "reused PID with mismatched birth is stale" "ok" \
  "$(read_state "after_reused_pid")"
assert_eq "reused-PID owner claim is cleaned" "no" \
  "$([[ -e "${_reused_pid_claim}" ]] && printf yes || printf no)"

# ----------------------------------------------------------------------
printf 'Test 9m: unavailable birth observation fails safe as live\n'
reset_state
_make_atomic_owner_fixture "$$" "birth-unavailable" "old.birth"
_birth_unavailable_claim="${_fixture_claim}"
printf '%s\t%s\n' "$$" "unavailable" >"${_birth_seam}"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=2
_birth_unavailable_rc=0
OMC_TEST_PROCESS_BIRTH_IDENTITY_FILE="${_birth_seam}" \
  with_state_lock true || _birth_unavailable_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "unavailable birth observation preserves possible live owner" \
  "1" "${_birth_unavailable_rc}"
assert_eq "unavailable birth keeps canonical owner intact" \
  "${_fixture_token}" "$(cat "${ownerfile}")"
rm -f "${ownerfile}" "${_birth_unavailable_claim}" \
  "${lockdir}/holder.pid" "${_birth_seam}"
rmdir "${lockdir}"

# ----------------------------------------------------------------------
printf 'Test 9n: lock metadata must match as complete canonical bytes\n'
reset_state
_make_atomic_owner_fixture "$$" "nul-owner"
_nul_owner_claim="${_fixture_claim}"
_nul_owner_token="${_fixture_token}"
# owner and claim are hard links: one raw NUL poisons both records. The exact
# release must preserve every ownership artifact instead of comparing only the
# shell-visible prefix.
printf '\0' >>"${ownerfile}"
_nul_release_rc=0
omc_release_lockdir_owner_exact \
  "${lockdir}" "${_nul_owner_token}" "nul-owner-release" \
  >/dev/null 2>&1 || _nul_release_rc=$?
assert_eq "NUL-tailed exact owner cannot be released" "1" \
  "${_nul_release_rc}"
assert_eq "NUL-tailed owner sentinel remains" "yes" \
  "$([[ -f "${ownerfile}" ]] && printf yes || printf no)"
assert_eq "NUL-tailed owner claim remains" "yes" \
  "$([[ -f "${_nul_owner_claim}" ]] && printf yes || printf no)"
rm -f "${ownerfile}" "${_nul_owner_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

_make_atomic_owner_fixture "$$" "blank-owner"
_blank_owner_claim="${_fixture_claim}"
_blank_owner_token="${_fixture_token}"
printf '\n' >>"${ownerfile}"
_blank_release_rc=0
omc_release_lockdir_owner_exact \
  "${lockdir}" "${_blank_owner_token}" "blank-owner-release" \
  >/dev/null 2>&1 || _blank_release_rc=$?
assert_eq "extra blank line cannot alias exact owner" "1" \
  "${_blank_release_rc}"
assert_eq "extra-line owner remains authoritative" "yes" \
  "$([[ -f "${ownerfile}" && -f "${_blank_owner_claim}" ]] \
    && printf yes || printf no)"
rm -f "${ownerfile}" "${_blank_owner_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

_make_atomic_owner_fixture "$$" "nul-claim"
_nul_claim="${_fixture_claim}"
_nul_claim_token="${_fixture_token}"
# Break the hard link so only the unique claim generation is malformed.
rm -f "${_nul_claim}"
printf '%s\n' "${_nul_claim_token}" >"${_nul_claim}"
printf '\0' >>"${_nul_claim}"
_nul_claim_release_rc=0
omc_release_lockdir_owner_exact \
  "${lockdir}" "${_nul_claim_token}" "nul-claim-release" \
  >/dev/null 2>&1 || _nul_claim_release_rc=$?
assert_eq "NUL-tailed election claim cannot release owner" "1" \
  "${_nul_claim_release_rc}"
assert_eq "claim tamper preserves canonical owner and claim" "yes" \
  "$([[ -f "${ownerfile}" && -f "${_nul_claim}" ]] \
    && printf yes || printf no)"
rm -f "${ownerfile}" "${_nul_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

_tampered_reap_owner_pid=999999
while kill -0 "${_tampered_reap_owner_pid}" 2>/dev/null; do
  _tampered_reap_owner_pid=$((_tampered_reap_owner_pid + 1))
done
_make_atomic_owner_fixture "${_tampered_reap_owner_pid}" "nul-reap-owner"
_tampered_reap_owner_claim="${_fixture_claim}"
_tampered_reap_owner_token="${_fixture_token}"
_tampered_reaper_pid=$((_tampered_reap_owner_pid + 1))
while kill -0 "${_tampered_reaper_pid}" 2>/dev/null; do
  _tampered_reaper_pid=$((_tampered_reaper_pid + 1))
done
_tampered_reaper_claim="${ownerfile}.claim.nul-reaper"
_tampered_reaper_token="${_tampered_reaper_pid}:${_tampered_reaper_claim##*/}:1"
printf '%s\n' "${_tampered_reaper_token}" >"${_tampered_reaper_claim}"
_tampered_reap="${_tampered_reap_owner_claim}.reap.${_tampered_reaper_claim##*/}"
rm -f "${_tampered_reap_owner_claim}"
printf '%s\n' "${_tampered_reap_owner_token}" >"${_tampered_reap}"
printf '\0' >>"${_tampered_reap}"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=1
_tampered_reap_rc=0
with_state_lock true >/dev/null 2>&1 || _tampered_reap_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "NUL-tailed reap record cannot elect a successor" "1" \
  "${_tampered_reap_rc}"
assert_eq "tampered reap keeps canonical owner" \
  "${_tampered_reap_owner_token}" "$(cat "${ownerfile}")"
assert_eq "tampered reap is not consumed" "yes" \
  "$([[ -f "${_tampered_reap}" ]] && printf yes || printf no)"
rm -f "${ownerfile}" "${_tampered_reap}" "${_tampered_reaper_claim}" \
  "${lockdir}/holder.pid"
rmdir "${lockdir}"

_make_atomic_owner_fixture "${_tampered_reap_owner_pid}" "nul-pid-owner"
_tampered_pid_claim="${_fixture_claim}"
printf '%s' "${_tampered_reap_owner_pid}" >"${lockdir}/holder.pid"
printf '\0\n' >>"${lockdir}/holder.pid"
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=1
_tampered_pid_rc=0
with_state_lock true >/dev/null 2>&1 || _tampered_pid_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
assert_eq "NUL-tailed compatibility PID cannot authorize reap" "1" \
  "${_tampered_pid_rc}"
assert_eq "malformed compatibility PID preserves owner generation" "yes" \
  "$([[ -f "${ownerfile}" && -f "${_tampered_pid_claim}" \
      && -d "${lockdir}" ]] && printf yes || printf no)"
rm -f "${ownerfile}" "${_tampered_pid_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

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

# Bash 3.2 on macOS preserves the parent's `$$` inside `( ... )`. Exercise the
# actual subshell path so the direct-child PPID proof used by acquisition and
# reentry stays paired; an implementation that compares the inherited `$$`
# would deadlock/drop the nested callback here.
_subshell_reentry_result="$(session_file ".test-subshell-reentry")"
(
  _subshell_inner_count=0
  _subshell_inner_body() {
    _subshell_inner_count=$((_subshell_inner_count + 1))
  }
  _subshell_outer_body() {
    with_state_lock _subshell_inner_body
    with_state_lock _subshell_inner_body
  }
  with_state_lock _subshell_outer_body
  printf '%s\n' "${_subshell_inner_count}" >"${_subshell_reentry_result}"
)
assert_eq "T18: nested lock reentry works in a macOS-style subshell" "2" \
  "$(<"${_subshell_reentry_result}")"
rm -f "${_subshell_reentry_result}"

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

lockdir="$(session_file ".state.lock")"
ownerfile="${lockdir}.owner"
_make_atomic_owner_fixture "$$" "forgedreentry"
_forged_reentry_token="${_fixture_token}"
export _OMC_STATE_LOCK_HELD=1
export _OMC_STATE_LOCK_HELD_SESSION="${SESSION_ID}"
export _OMC_STATE_LOCK_HELD_LOCKDIR="${lockdir}"
export _OMC_STATE_LOCK_HELD_OWNER_TOKEN="${_forged_reentry_token}"
_forged_reentry_ran=0
_forged_reentry_body() { _forged_reentry_ran=1; }
_attempts_before="${OMC_STATE_LOCK_MAX_ATTEMPTS}"
OMC_STATE_LOCK_MAX_ATTEMPTS=1
_forged_reentry_rc=0
with_state_lock _forged_reentry_body >/dev/null 2>&1 \
  || _forged_reentry_rc=$?
OMC_STATE_LOCK_MAX_ATTEMPTS="${_attempts_before}"
unset _OMC_STATE_LOCK_HELD _OMC_STATE_LOCK_HELD_SESSION
unset _OMC_STATE_LOCK_HELD_LOCKDIR _OMC_STATE_LOCK_HELD_OWNER_TOKEN
assert_eq "T18: exported exact-looking reentry marker cannot skip mutex" "1" \
  "${_forged_reentry_rc}"
assert_eq "T18: exported reentry marker executes no callback" "0" \
  "${_forged_reentry_ran}"
rm -f "${ownerfile}" "${_fixture_claim}" "${lockdir}/holder.pid"
rmdir "${lockdir}"

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

# ----------------------------------------------------------------------
# Test 20b: jq decodes JSON \u0000 into a byte Bash cannot represent. Reject
# only the poisoned requested value before projection, preserving positional
# alignment and unrelated live authority. A later locked validation treats the
# containing object as corrupt and archives it instead of normalizing it.
printf '\nTest 20b: NUL-bearing state values never normalize into authority\n'
SESSION_ID="test-state-nul-boundary-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
jq -nc '{workflow_mode:"ultrawork",poison:("9999999999" + "\u0000"),
  after:"1"}' >"$(session_file "${STATE_JSON}")"
assert_eq "T20b: unrelated state remains readable" "ultrawork" \
  "$(read_state "workflow_mode")"
assert_eq "T20b: NUL-bearing scalar is rejected before Bash" "" \
  "$(read_state "poison")"
_tmp_capture="${STATE_ROOT}/${SESSION_ID}/nul-bulk.capture"
read_state_keys workflow_mode poison after >"${_tmp_capture}"
_capture_replay
assert_eq "T20b: bulk position 0 remains authoritative" "ultrawork" \
  "${got[0]}"
assert_eq "T20b: poisoned bulk position is empty" "" "${got[1]}"
assert_eq "T20b: later bulk position cannot shift" "1" "${got[2]}"
_state_validated=0
_ensure_valid_state
assert_eq "T20b: validation archives poisoned state" "1" \
  "$(find "${STATE_ROOT}/${SESSION_ID}" -maxdepth 1 \
      -name 'session_state.json.corrupt.*' -type f | wc -l \
      | tr -d '[:space:]')"
assert_eq "T20b: recovery marker is visible" "true" \
  "$(jq -r 'has("recovered_from_corrupt_ts")' \
    "$(session_file "${STATE_JSON}")")"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 20c: legacy sidecars remain compatible text inputs, but their complete
# bytes must be NUL-free and stable before emission. A missing JSON key must
# never revive a shell-normalized authority token from a malformed sidecar.
printf '\nTest 20c: legacy state sidecars reject raw NUL without aliasing\n'
SESSION_ID="test-legacy-state-nul-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
printf '{}\n' >"$(session_file "${STATE_JSON}")"
printf 'ultra\0work\n' >"$(session_file "workflow_mode")"
assert_eq "T20c: NUL-bearing legacy authority is rejected" "" \
  "$(read_state "workflow_mode")"
printf 'line one\nline two\n' >"$(session_file "legacy_multiline")"
assert_eq "T20c: safe multiline legacy text remains readable" \
  $'line one\nline two' "$(read_state "legacy_multiline")"
ln -s "$(session_file "legacy_multiline")" \
  "$(session_file "legacy_symlink")"
assert_eq "T20c: legacy symlink is not followed" "" \
  "$(read_state "legacy_symlink")"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 20d: jq can accept a literal NUL outside a JSON string and normalize a
# numeric token. The complete raw state envelope must be rejected before any
# unrelated field, bulk position, or ownership coordinate is projected.
printf '\nTest 20d: raw-NUL state envelopes never normalize numeric authority\n'
SESSION_ID="test-raw-state-nul-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
printf '{"workflow_mode":"ultrawork","edit_revision":1\0}\n' \
  >"$(session_file "${STATE_JSON}")"
assert_eq "T20d: raw-NUL envelope blocks unrelated scalar reads" "" \
  "$(read_state "workflow_mode")"
_tmp_capture="${STATE_ROOT}/${SESSION_ID}/raw-nul-bulk.capture"
read_state_keys workflow_mode edit_revision >"${_tmp_capture}"
_capture_replay
assert_eq "T20d: raw-NUL bulk position 0 is empty" "" "${got[0]}"
assert_eq "T20d: raw-NUL bulk position 1 is empty" "" "${got[1]}"
assert_eq "T20d: discovery envelope rejects raw NUL" "rejected" \
  "$(_omc_state_envelope_is_shell_safe "$(session_file "${STATE_JSON}")" \
    && printf accepted || printf rejected)"
_state_validated=0
_ensure_valid_state
assert_eq "T20d: locked validation archives raw-NUL state" "1" \
  "$(find "${STATE_ROOT}/${SESSION_ID}" -maxdepth 1 \
      -name 'session_state.json.corrupt.*' -type f | wc -l \
      | tr -d '[:space:]')"
assert_eq "T20d: recovered state is raw-NUL-free" "accepted" \
  "$(_omc_state_envelope_is_shell_safe "$(session_file "${STATE_JSON}")" \
    && printf accepted || printf rejected)"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 21: JSONL row rewrites are all-or-nothing. Completion hooks call this
# helper from functions whose status is explicitly inspected; Bash therefore
# cannot be trusted to stop at an unchecked command under `set -e`. Exercise
# every publication boundary and prove the authoritative ledger is unchanged.
printf '\nTest 21: atomic JSONL row rewrite fails closed at every boundary\n'
SESSION_ID="test-jsonl-rewrite-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
_rewrite_file="$(session_file "rewrite.jsonl")"
_rewrite_a='{"id":"a","value":1}'
_rewrite_b='{"id":"b","value":2}'
_rewrite_new='{"id":"a","value":3}'
printf '%s\n%s\n' "${_rewrite_a}" "${_rewrite_b}" >"${_rewrite_file}"
_rewrite_before="$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"
for _rewrite_fault in mktemp write publish; do
  _rewrite_rc=0
  rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_a}" \
    "${_rewrite_new}" "${_rewrite_fault}" || _rewrite_rc=$?
  assert_ne "T21: ${_rewrite_fault} fault returns nonzero" "0" \
    "${_rewrite_rc}"
  assert_eq "T21: ${_rewrite_fault} fault preserves ledger" \
    "${_rewrite_before}" \
    "$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"
done
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_a}" \
  "${_rewrite_new}"
assert_eq "T21: replacement publishes exactly once" \
  "${_rewrite_new}" "$(sed -n '1p' "${_rewrite_file}")"
assert_eq "T21: replacement preserves unrelated row" \
  "${_rewrite_b}" "$(sed -n '2p' "${_rewrite_file}")"
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_new}" ""
assert_eq "T21: deletion removes only selected row" \
  "${_rewrite_b}" "$(cat "${_rewrite_file}")"
printf '%s\n' "${_rewrite_b}" >"${_rewrite_file}"
_rewrite_before="$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"
_rewrite_rc=0
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_b}" "" write \
  || _rewrite_rc=$?
assert_ne "T21: sole-row delete write fault returns nonzero" "0" \
  "${_rewrite_rc}"
assert_eq "T21: sole-row delete write fault preserves ledger" \
  "${_rewrite_before}" \
  "$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"
_rewrite_rc=0
rewrite_jsonl_line_atomic "${_rewrite_file}" '{"id":"missing"}' \
  '{"id":"replacement"}' || _rewrite_rc=$?
assert_ne "T21: missing selection fails" "0" "${_rewrite_rc}"
printf '%s\n%s\n' "${_rewrite_b}" "${_rewrite_b}" >"${_rewrite_file}"
_rewrite_rc=0
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_b}" \
  "${_rewrite_new}" || _rewrite_rc=$?
assert_ne "T21: duplicate exact selection fails closed" "0" "${_rewrite_rc}"
assert_eq "T21: duplicate failure preserves both rows" "2" \
  "$(wc -l <"${_rewrite_file}" | tr -d '[:space:]')"
printf '%s\n\n%s\n' "${_rewrite_a}" "${_rewrite_b}" >"${_rewrite_file}"
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_a}" \
  "${_rewrite_new}"
assert_eq "T21: successful rewrite preserves unrelated blank rows" "" \
  "$(sed -n '2p' "${_rewrite_file}")"
assert_eq "T21: blank-row preservation keeps trailing row position" \
  "${_rewrite_b}" "$(sed -n '3p' "${_rewrite_file}")"

# Raw NUL in an unrelated row must never be laundered by rewriting a healthy
# row. The primitive rejects the source and leaves every byte untouched.
{
  printf '%s\n%s' "${_rewrite_a}" "${_rewrite_b}"
  printf '\0\n'
} >"${_rewrite_file}"
_rewrite_before="$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"
_rewrite_rc=0
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_a}" \
  "${_rewrite_new}" || _rewrite_rc=$?
assert_ne "T21: unrelated raw NUL fails closed" "0" "${_rewrite_rc}"
assert_eq "T21: raw-NUL failure preserves every source byte" \
  "${_rewrite_before}" \
  "$(shasum -a 256 "${_rewrite_file}" | awk '{print $1}')"

# A source without a final newline retains that exact framing after replacing
# a different row; line-oriented Bash rewrites used to append one silently.
printf '%s\n%s' "${_rewrite_a}" "${_rewrite_b}" >"${_rewrite_file}"
_rewrite_expected="$(session_file "rewrite-expected.jsonl")"
printf '%s\n%s' "${_rewrite_new}" "${_rewrite_b}" >"${_rewrite_expected}"
rewrite_jsonl_line_atomic "${_rewrite_file}" "${_rewrite_a}" \
  "${_rewrite_new}"
assert_eq "T21: missing-final-newline framing remains byte-exact" "yes" \
  "$(cmp -s "${_rewrite_expected}" "${_rewrite_file}" \
    && printf yes || printf no)"
rm -f "${_rewrite_expected}"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 22: Every outer state mutation is fenced by interrupted dispatch/reset
# authority both before lock acquisition and after a waiter acquires. The
# latter closes the check/acquire race for callbacks that queued behind an
# Agent admission. An inherited legacy bypass variable has no authority.
printf '\nTest 22: state-lock dispatch recovery fence closes precheck/acquire race\n'
SESSION_ID="test-state-lock-dispatch-fence-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
reset_state
_dispatch_txn="$(session_file ".dispatch-txn.interrupted")"
mkdir "${_dispatch_txn}"

_fenced_state_writer() {
  write_state "dispatch_fence_writer" "must-not-land"
}

_dispatch_fence_rc=0
with_state_lock _fenced_state_writer >/dev/null 2>&1 \
  || _dispatch_fence_rc=$?
assert_eq "T22: pre-acquisition dispatch fence returns recovery status" \
  "76" "${_dispatch_fence_rc}"
assert_eq "T22: pre-acquisition dispatch fence preserves state" "" \
  "$(read_state "dispatch_fence_writer")"

_forged_reset_rc=0
OMC_PUBLICATION_RESET_INTERNAL=1 \
  with_state_lock _fenced_state_writer >/dev/null 2>&1 \
    || _forged_reset_rc=$?
assert_eq "T22: inherited reset env cannot bypass dispatch fence" \
  "76" "${_forged_reset_rc}"
assert_eq "T22: forged reset env publishes no state" "" \
  "$(read_state "dispatch_fence_writer")"
_deactivate_session_unlocked() {
  write_state "forged_scoped_reset_writer" "must-not-land"
}
export _OMC_STATE_LOCK_AUTH_KIND="ulw-deactivate"
export _OMC_STATE_LOCK_AUTH_SESSION="${SESSION_ID}"
_OMC_STATE_LOCK_AUTH_GENERATION="$(_omc_current_state_generation)"
export _OMC_STATE_LOCK_AUTH_GENERATION
_OMC_STATE_LOCK_AUTH_TRANSACTION="$(_omc_current_reset_transaction_fingerprint \
  "${SESSION_ID}")"
export _OMC_STATE_LOCK_AUTH_TRANSACTION
export _OMC_STATE_LOCK_AUTH_CALLBACK="_deactivate_session_unlocked"
export _OMC_STATE_LOCK_AUTH_CONSUMED=0
_forged_scoped_reset_rc=0
with_state_lock _deactivate_session_unlocked >/dev/null 2>&1 \
  || _forged_scoped_reset_rc=$?
unset _OMC_STATE_LOCK_AUTH_KIND _OMC_STATE_LOCK_AUTH_SESSION
unset _OMC_STATE_LOCK_AUTH_GENERATION _OMC_STATE_LOCK_AUTH_TRANSACTION
unset _OMC_STATE_LOCK_AUTH_CALLBACK _OMC_STATE_LOCK_AUTH_CONSUMED
assert_eq "T22: exported exact-looking scoped reset is fenced" "76" \
  "${_forged_scoped_reset_rc}"
assert_eq "T22: exported scoped reset publishes no state" "" \
  "$(read_state "forged_scoped_reset_writer")"
rmdir "${_dispatch_txn}"
write_state "dispatch_fence_writer" ""

_holder_ready="$(session_file ".test-holder-ready")"
_holder_release="$(session_file ".test-holder-release")"
_waiter_ready="$(session_file ".test-waiter-ready")"
_waiter_release="$(session_file ".test-waiter-release")"
_waiter_rc_file="$(session_file ".test-waiter-rc")"

_hold_state_lock_for_dispatch_race() {
  : >"${_holder_ready}"
  while [[ ! -e "${_holder_release}" ]]; do
    sleep 0.01
  done
}
_queued_state_writer() {
  write_state "queued_dispatch_fence_writer" "must-not-land"
}

( with_state_lock _hold_state_lock_for_dispatch_race ) &
_holder_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${_holder_ready}" ]] && break
  kill -0 "${_holder_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T22: holder acquired state mutex" "yes" \
  "$([[ -e "${_holder_ready}" ]] && printf yes || printf no)"

(
  _queued_rc=0
  OMC_TEST_STATE_LOCK_PREACQUIRE_READY_FILE="${_waiter_ready}" \
  OMC_TEST_STATE_LOCK_PREACQUIRE_RELEASE_FILE="${_waiter_release}" \
    with_state_lock _queued_state_writer >/dev/null 2>&1 \
      || _queued_rc=$?
  printf '%s\n' "${_queued_rc}" >"${_waiter_rc_file}"
) &
_waiter_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${_waiter_ready}" ]] && break
  kill -0 "${_waiter_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T22: waiter passed both recovery fast checks" "yes" \
  "$([[ -e "${_waiter_ready}" ]] && printf yes || printf no)"

mkdir "${_dispatch_txn}"
: >"${_waiter_release}"
# The holder still owns the lock, so the released waiter must queue. Its unique
# owner claim makes that state observable without relying on a timing-only nap.
for _wait in $(seq 1 500); do
  _claim_count="$(find "$(session_file "")" -maxdepth 1 \
    -name '.state.lock.owner.claim.*' -type f 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  [[ "${_claim_count:-0}" -ge 2 ]] && break
  kill -0 "${_waiter_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "T22: waiter queued behind held mutex" "yes" \
  "$([[ "${_claim_count:-0}" -ge 2 ]] && printf yes || printf no)"
: >"${_holder_release}"
wait "${_holder_pid}"
wait "${_waiter_pid}"
assert_eq "T22: post-acquisition dispatch fence returns recovery status" \
  "76" "$(<"${_waiter_rc_file}")"
assert_eq "T22: queued writer publishes no state" "" \
  "$(read_state "queued_dispatch_fence_writer")"

rmdir "${_dispatch_txn}"
rm -f "${_holder_ready}" "${_holder_release}" \
  "${_waiter_ready}" "${_waiter_release}" "${_waiter_rc_file}"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 22b: Publication recovery authority is minted only by an exact bundled
# caller through the scoped wrapper. The retired ambient flag cannot skip a
# fixed-WAL fence, and a basename lookalike outside the bundle is not canonical.
printf '\nTest 22b: publication recovery requires exact scoped caller authority\n'
SESSION_ID="test-state-lock-publication-auth-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
reset_state
_publication_env_body="$(session_file ".test-publication-env-body")"
_publication_env_rc="$(session_file ".test-publication-env-rc")"
(
  export OMC_PUBLICATION_RECOVERY_INTERNAL=1
  omc_publication_recovery_needed() { return 0; }
  omc_recover_active_publication_transactions() { return 1; }
  _publication_env_writer() { : >"${_publication_env_body}"; }
  _publication_rc=0
  with_state_lock _publication_env_writer >/dev/null 2>&1 \
    || _publication_rc=$?
  printf '%s\n' "${_publication_rc}" >"${_publication_env_rc}"
)
assert_ne "T22b: inherited publication env cannot skip recovery fence" "0" \
  "$(<"${_publication_env_rc}")"
assert_eq "T22b: inherited publication env executes no callback" "no" \
  "$([[ -e "${_publication_env_body}" ]] && printf yes || printf no)"

_fake_recovery_dir="$(session_file ".fake-recovery-caller")"
_fake_recovery_script="${_fake_recovery_dir}/record-plan.sh"
_fake_recovery_result="$(session_file ".fake-recovery-result")"
mkdir "${_fake_recovery_dir}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'source "${OMC_TEST_COMMON_SH}"' \
  'if _omc_publication_recovery_caller_allowed "$0"; then' \
  '  printf allowed >"${OMC_TEST_CALLER_RESULT}"' \
  'else' \
  '  printf denied >"${OMC_TEST_CALLER_RESULT}"' \
  'fi' >"${_fake_recovery_script}"
chmod +x "${_fake_recovery_script}"
OMC_TEST_COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
OMC_TEST_CALLER_RESULT="${_fake_recovery_result}" \
  bash "${_fake_recovery_script}"
assert_eq "T22b: lookalike recovery basename outside bundle is denied" \
  "denied" "$(<"${_fake_recovery_result}")"
_trusted_autowork_dir="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
_trusted_quality_dir="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts"
assert_eq "T22b: exact planner cold-recovery callback pair is admitted" "yes" \
  "$(_omc_publication_recovery_pair_allowed \
      "${_trusted_autowork_dir}/record-plan.sh" \
      _recover_cold_plan_publication_unlocked \
      && printf yes || printf no)"
assert_eq "T22b: exact planner active-recovery callback pair is admitted" "yes" \
  "$(_omc_publication_recovery_pair_allowed \
      "${_trusted_autowork_dir}/record-plan.sh" \
      _recover_active_plan_publication_unlocked \
      && printf yes || printf no)"
assert_eq "T22b: exact reviewer recovery callback pair is admitted" "yes" \
  "$(_omc_publication_recovery_pair_allowed \
      "${_trusted_autowork_dir}/record-reviewer.sh" \
      _recover_active_reviewer_unlocked \
      && printf yes || printf no)"
assert_eq "T22b: canonical quality-pack caller path resolves exactly" "yes" \
  "$(_omc_publication_recovery_caller_allowed \
      "${_trusted_quality_dir}/pre-compact-snapshot.sh" \
      && printf yes || printf no)"
assert_eq "T22b: compact hook cannot mint publication recovery" "no" \
  "$(_omc_publication_recovery_pair_allowed \
      "${_trusted_quality_dir}/pre-compact-snapshot.sh" \
      _precompact_begin_boundary_unlocked \
      && printf yes || printf no)"
assert_eq "T22b: exact planner path cannot authorize arbitrary callback" "no" \
  "$(_omc_publication_recovery_pair_allowed \
      "${_trusted_autowork_dir}/record-plan.sh" arbitrary_callback \
      && printf yes || printf no)"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 23: A successful resume handoff makes the source report-only. Its
# generation remains stable for replay, but mode/generation helpers and every
# ordinary state mutation reject it. Invalid/self markers remain fail-open.
printf '\nTest 23: transferred resume source is lifecycle- and mutation-fenced\n'
SESSION_ID="test-state-lock-resume-transfer-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
reset_state
_transfer_owner="test-state-lock-resume-owner-$$"
with_state_lock_batch \
  "workflow_mode" "ultrawork" \
  "ulw_enforcement_active" "1" \
  "ulw_enforcement_generation" "7" \
  "resume_transferred_to" "${_transfer_owner}"
_transfer_state="$(session_file "${STATE_JSON}")"
_transfer_before="$(shasum -a 256 "${_transfer_state}" | awk '{print $1}')"
_transfer_mode_rc=0
is_ultrawork_mode || _transfer_mode_rc=$?
assert_eq "T23: transferred source is not active ultrawork" "1" \
  "${_transfer_mode_rc}"
_OMC_ULW_CAPTURED_GENERATION=7
_transfer_generation_rc=0
omc_enforcement_generation_matches_capture || _transfer_generation_rc=$?
assert_eq "T23: copied generation cannot authorize old callbacks" "1" \
  "${_transfer_generation_rc}"
unset _OMC_ULW_CAPTURED_GENERATION
_transfer_writer() { write_state "transferred_writer" "must-not-land"; }
_transfer_write_rc=0
with_state_lock _transfer_writer >/dev/null 2>&1 \
  || _transfer_write_rc=$?
assert_eq "T23: transferred-source state fence returns ownership status" \
  "78" "${_transfer_write_rc}"
assert_eq "T23: transferred-source state remains byte-stable" \
  "${_transfer_before}" \
  "$(shasum -a 256 "${_transfer_state}" | awk '{print $1}')"
_forged_transfer_reset_rc=0
OMC_PUBLICATION_RESET_INTERNAL=1 \
  with_state_lock _transfer_writer >/dev/null 2>&1 \
    || _forged_transfer_reset_rc=$?
assert_eq "T23: inherited reset env cannot bypass transfer fence" \
  "78" "${_forged_transfer_reset_rc}"
assert_eq "T23: forged reset env preserves transferred source" \
  "${_transfer_before}" \
  "$(shasum -a 256 "${_transfer_state}" | awk '{print $1}')"
jq --arg owner "${_transfer_owner}" \
  '.resume_transferred_to=($owner + "\u0000")' \
  "${_transfer_state}" >"${_transfer_state}.tmp"
mv "${_transfer_state}.tmp" "${_transfer_state}"
assert_eq "T23: NUL-bearing transfer marker fails open" "yes" \
  "$(is_ultrawork_mode && printf yes || printf no)"
_write_state_batch_unlocked "resume_transferred_to" "../malformed"
assert_eq "T23: malformed transfer marker fails open" "yes" \
  "$(is_ultrawork_mode && printf yes || printf no)"
_write_state_batch_unlocked "resume_transferred_to" "${SESSION_ID}"
assert_eq "T23: self transfer marker fails open" "yes" \
  "$(is_ultrawork_mode && printf yes || printf no)"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 23b: matching-looking exported resume capability variables are not a
# state-lock capability. Only the non-exported resume owner process whose
# canonical init token names its current PID can mutate the generation.
printf '\nTest 23b: inherited resume target capability is rejected\n'
SESSION_ID="test-state-lock-resume-cap-forgery-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
_forged_resume_txn="resume-init-forgedcapability123456"
_forged_resume_source="forged-resume-source"
_write_state_batch_unlocked \
  "resume_initialization_txn_id" "${_forged_resume_txn}" \
  "resume_initialization_source_id" "${_forged_resume_source}" \
  "resume_transferred_to" ""
_forged_resume_writer() {
  write_state "forged_resume_writer" "must-not-land"
}
export _OMC_RESUME_TARGET_CAP_TXN_ID="${_forged_resume_txn}"
export _OMC_RESUME_TARGET_CAP_SOURCE_ID="${_forged_resume_source}"
export _OMC_RESUME_TARGET_CAP_LOCKDIR="${STATE_ROOT}.resume-init-locks/${SESSION_ID}.lock"
export _OMC_RESUME_TARGET_CAP_OWNER_TOKEN="$$:.owner.claim.forged:1:legacy"
_forged_resume_rc=0
with_state_lock _forged_resume_writer >/dev/null 2>&1 \
  || _forged_resume_rc=$?
unset _OMC_RESUME_TARGET_CAP_TXN_ID _OMC_RESUME_TARGET_CAP_SOURCE_ID
unset _OMC_RESUME_TARGET_CAP_LOCKDIR _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
assert_eq "T23b: exported forged resume capability is fenced" "79" \
  "${_forged_resume_rc}"
assert_eq "T23b: forged resume capability publishes no state" "" \
  "$(read_state "forged_resume_writer")"

# A process-local-looking token with this exact PID is still replayed authority
# when its process-birth coordinate does not match the live process. The
# capability must validate the full birth-bound owner record, not PID alone.
_replayed_resume_lock="${STATE_ROOT}.resume-init-locks/${SESSION_ID}.lock"
mkdir -p "${_replayed_resume_lock%/*}"
_replayed_resume_token="$$:.resume-replayed.claim:7:definitely.wrong.birth"
printf '%s\n' "${_replayed_resume_token}" \
  >"${_replayed_resume_lock}.owner"
_OMC_RESUME_TARGET_CAP_TXN_ID="${_forged_resume_txn}"
_OMC_RESUME_TARGET_CAP_SOURCE_ID="${_forged_resume_source}"
_OMC_RESUME_TARGET_CAP_LOCKDIR="${_replayed_resume_lock}"
_OMC_RESUME_TARGET_CAP_OWNER_TOKEN="${_replayed_resume_token}"
export -n _OMC_RESUME_TARGET_CAP_TXN_ID \
  _OMC_RESUME_TARGET_CAP_SOURCE_ID _OMC_RESUME_TARGET_CAP_LOCKDIR \
  _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
_replayed_resume_rc=0
with_state_lock _forged_resume_writer >/dev/null 2>&1 \
  || _replayed_resume_rc=$?
unset _OMC_RESUME_TARGET_CAP_TXN_ID _OMC_RESUME_TARGET_CAP_SOURCE_ID
unset _OMC_RESUME_TARGET_CAP_LOCKDIR _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
assert_eq "T23b: replayed same-PID token with wrong birth is fenced" "79" \
  "${_replayed_resume_rc}"
assert_eq "T23b: replayed birth identity publishes no state" "" \
  "$(read_state "forged_resume_writer")"

# General lock liveness deliberately preserves legacy PID-only owners. Resume
# mutation authority may not inherit that compatibility fallback: even a
# non-exported, canonical, same-PID token must carry an observable exact birth.
_legacy_resume_token="$$:.resume-legacy.claim:8:legacy"
printf '%s\n' "${_legacy_resume_token}" \
  >"${_replayed_resume_lock}.owner"
_OMC_RESUME_TARGET_CAP_TXN_ID="${_forged_resume_txn}"
_OMC_RESUME_TARGET_CAP_SOURCE_ID="${_forged_resume_source}"
_OMC_RESUME_TARGET_CAP_LOCKDIR="${_replayed_resume_lock}"
_OMC_RESUME_TARGET_CAP_OWNER_TOKEN="${_legacy_resume_token}"
export -n _OMC_RESUME_TARGET_CAP_TXN_ID \
  _OMC_RESUME_TARGET_CAP_SOURCE_ID _OMC_RESUME_TARGET_CAP_LOCKDIR \
  _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
_legacy_resume_writer() {
  write_state "legacy_resume_writer" "must-not-land"
}
_legacy_resume_rc=0
with_state_lock _legacy_resume_writer >/dev/null 2>&1 \
  || _legacy_resume_rc=$?
unset _OMC_RESUME_TARGET_CAP_TXN_ID _OMC_RESUME_TARGET_CAP_SOURCE_ID
unset _OMC_RESUME_TARGET_CAP_LOCKDIR _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
assert_eq "T23b: same-PID legacy resume capability is fenced" "79" \
  "${_legacy_resume_rc}"
assert_eq "T23b: legacy resume capability publishes no state" "" \
  "$(read_state "legacy_resume_writer")"

# An otherwise well-formed birth-bound token also fails closed when the
# current process birth cannot be observed. This differs intentionally from
# stale-lock reaping, which continues to treat the same ambiguity as live.
_unobservable_resume_token="$$:.resume-unobservable.claim:9:recorded.birth"
_resume_birth_seam="${TEST_STATE_ROOT}/resume-birth-unavailable.tsv"
printf '%s\tunavailable\n' "$$" >"${_resume_birth_seam}"
printf '%s\n' "${_unobservable_resume_token}" \
  >"${_replayed_resume_lock}.owner"
_OMC_RESUME_TARGET_CAP_TXN_ID="${_forged_resume_txn}"
_OMC_RESUME_TARGET_CAP_SOURCE_ID="${_forged_resume_source}"
_OMC_RESUME_TARGET_CAP_LOCKDIR="${_replayed_resume_lock}"
_OMC_RESUME_TARGET_CAP_OWNER_TOKEN="${_unobservable_resume_token}"
export -n _OMC_RESUME_TARGET_CAP_TXN_ID \
  _OMC_RESUME_TARGET_CAP_SOURCE_ID _OMC_RESUME_TARGET_CAP_LOCKDIR \
  _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
_unobservable_resume_writer() {
  write_state "unobservable_resume_writer" "must-not-land"
}
_unobservable_resume_rc=0
OMC_TEST_PROCESS_BIRTH_IDENTITY_FILE="${_resume_birth_seam}" \
  with_state_lock _unobservable_resume_writer >/dev/null 2>&1 \
  || _unobservable_resume_rc=$?
unset _OMC_RESUME_TARGET_CAP_TXN_ID _OMC_RESUME_TARGET_CAP_SOURCE_ID
unset _OMC_RESUME_TARGET_CAP_LOCKDIR _OMC_RESUME_TARGET_CAP_OWNER_TOKEN
assert_eq "T23b: unobservable-birth resume capability is fenced" "79" \
  "${_unobservable_resume_rc}"
assert_eq "T23b: unobservable-birth capability publishes no state" "" \
  "$(read_state "unobservable_resume_writer")"
rm -f "${_resume_birth_seam}"
rm -f "${_replayed_resume_lock}.owner"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 23c: Resume lifecycle coordinates are typed state authority. Partial
# init pairs, non-string coordinates, and non-string downstream ownership all
# fail closed for ordinary mutations; exact managed reset is the only bypass.
printf '\nTest 23c: malformed resume lifecycle fields fence state mutation\n'
SESSION_ID="test-state-lock-resume-malformed-$$"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
ensure_session_dir
_malformed_resume_writer_ran=0
_malformed_resume_writer() { _malformed_resume_writer_ran=1; }
_malformed_resume_cases=(
  '{"resume_initialization_txn_id":7,"resume_initialization_source_id":"source","resume_transferred_to":""}'
  '{"resume_initialization_txn_id":"resume-init-partial123456","resume_transferred_to":""}'
  '{"resume_initialization_txn_id":"resume-init-typed123456","resume_initialization_source_id":"source","resume_transferred_to":9}'
  '{"resume_initialization_txn_id":"","resume_initialization_source_id":null,"resume_transferred_to":""}'
  '{"resume_initialization_txn_id":"\u0000","resume_initialization_source_id":"\u0000","resume_transferred_to":""}'
  '{"resume_transferred_to":"\u0000"}'
)
for _malformed_resume_json in "${_malformed_resume_cases[@]}"; do
  printf '%s\n' "${_malformed_resume_json}" \
    >"$(session_file "${STATE_JSON}")"
  _state_validated=0
  _malformed_resume_rc=0
  with_state_lock _malformed_resume_writer >/dev/null 2>&1 \
    || _malformed_resume_rc=$?
  assert_eq "T23c: malformed lifecycle shape returns resume fence" "79" \
    "${_malformed_resume_rc}"
done
assert_eq "T23c: malformed lifecycle callback never executes" "0" \
  "${_malformed_resume_writer_ran}"
rm -rf "${STATE_ROOT:?}/${SESSION_ID:?}" 2>/dev/null || true
unset SESSION_ID

# ----------------------------------------------------------------------
# Test 24: Explicit-session publication recovery must lock and prune the
# session passed by the caller, never the ambient callback SESSION_ID. A stub
# retires the selected pending row so this test isolates the orphan-waiter
# cleanup boundary after the universal recovery action.
printf '\nTest 24: explicit-session orphan waiter cleanup targets its owner\n'
_waiter_source_sid="test-explicit-waiter-source-$$"
_waiter_target_sid="test-explicit-waiter-target-$$"
mkdir -p "${STATE_ROOT}/${_waiter_source_sid}" \
  "${STATE_ROOT}/${_waiter_target_sid}"
_waiter_message="orphaned reviewer result"
_waiter_digest="$(_omc_token_digest "${_waiter_message}")"
_waiter_lifecycle="dispatch-explicitwaitersource123"
_waiter_native="native-explicit-waiter-source"
_waiter_row="$(jq -nc \
  --arg lifecycle "${_waiter_lifecycle}" \
  --arg native "${_waiter_native}" \
  --arg digest "${_waiter_digest}" \
  --arg message "${_waiter_message}" '
    {schema_version:1,created_at:1,lifecycle_dispatch_id:$lifecycle,
     agent_type:"quality-reviewer",native_agent_id:$native,
     completion_digest:$digest,message:$message}
  ')"
printf '%s\n' "${_waiter_row}" \
  >"${STATE_ROOT}/${_waiter_source_sid}/reviewer_summary_waiters.jsonl"
printf '%s\n' "${_waiter_row}" \
  >"${STATE_ROOT}/${_waiter_target_sid}/reviewer_summary_waiters.jsonl"
jq -nc \
  --arg lifecycle "${_waiter_lifecycle}" \
  --arg native "${_waiter_native}" \
  --arg digest "${_waiter_digest}" \
  --arg message "${_waiter_message}" '
    {review_dispatch_abandoned:false,
     completion_claim_id:"completion-explicitwaitersource123",
     completion_claim_ts:1,completion_claim_effects_complete:true,
     lifecycle_dispatch_id:$lifecycle,native_agent_id:$native,
     agent_type:"quality-reviewer",completion_claim_digest:$digest,
     completion_claim_message:$message}
  ' >"${STATE_ROOT}/${_waiter_source_sid}/pending_agents.jsonl"
printf '{}\n' >"${STATE_ROOT}/${_waiter_source_sid}/session_state.json"
printf '{}\n' >"${STATE_ROOT}/${_waiter_target_sid}/session_state.json"
_waiter_target_before="$(shasum -a 256 \
  "${STATE_ROOT}/${_waiter_target_sid}/reviewer_summary_waiters.jsonl" \
  | awk '{print $1}')"
_waiter_stub_dir="${TEST_STATE_ROOT}/explicit-waiter-stubs"
mkdir -p "${_waiter_stub_dir}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'payload="$(cat)"' \
  'sid="$(jq -r '\''.session_id // ""'\'' <<<"${payload}")"' \
  ': >"${STATE_ROOT}/${sid}/pending_agents.jsonl"' \
  >"${_waiter_stub_dir}/record-subagent-summary.sh"
chmod +x "${_waiter_stub_dir}/record-subagent-summary.sh"
SESSION_ID="${_waiter_target_sid}"
export STATE_ROOT
_waiter_recovery_rc=0
_OMC_AUTOWORK_SCRIPTS_DIR="${_waiter_stub_dir}" \
  omc_recover_active_publication_transactions "${_waiter_source_sid}" \
  || _waiter_recovery_rc=$?
assert_eq "T24: explicit-source recovery succeeds" "0" \
  "${_waiter_recovery_rc}"
assert_eq "T24: source orphan waiter is pruned" "0" \
  "$(wc -l \
    <"${STATE_ROOT}/${_waiter_source_sid}/reviewer_summary_waiters.jsonl" \
    | tr -d '[:space:]')"
assert_eq "T24: ambient target waiter remains byte-identical" \
  "${_waiter_target_before}" \
  "$(shasum -a 256 \
    "${STATE_ROOT}/${_waiter_target_sid}/reviewer_summary_waiters.jsonl" \
    | awk '{print $1}')"
rm -rf "${STATE_ROOT:?}/${_waiter_source_sid:?}" \
  "${STATE_ROOT:?}/${_waiter_target_sid:?}" "${_waiter_stub_dir}"
unset SESSION_ID

printf '\n=== State-IO Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
