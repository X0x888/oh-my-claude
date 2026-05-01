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
got=()
_tmp_capture="$(mktemp)"
_capture_replay() {
  got=()
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
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

printf '\n=== State-IO Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
