#!/usr/bin/env bash
# Focused tests for _cap_cross_session_jsonl — the cap helper that keeps
# cross-session aggregate JSONLs (classifier_misfires, session_summary,
# serendipity-log) bounded across years of accrual.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TEST_DIR}"; }
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

# ----------------------------------------------------------------------
printf 'Test 1: helper exists\n'
if declare -F _cap_cross_session_jsonl >/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: _cap_cross_session_jsonl not defined\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 2: missing file is a no-op (returns 0, creates nothing)\n'
missing="${TEST_DIR}/does-not-exist.jsonl"
_cap_cross_session_jsonl "${missing}" 100 80
rc=$?
assert_eq "no-op exit code" "0" "${rc}"
[[ ! -e "${missing}" ]] && pass=$((pass + 1)) || { printf '  FAIL: missing file should not be created\n' >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 3: file under cap is unchanged\n'
under="${TEST_DIR}/under.jsonl"
for i in $(seq 1 50); do printf '{"row":%d}\n' "${i}" >> "${under}"; done
before_md5="$(md5 -q "${under}" 2>/dev/null || md5sum "${under}" | awk '{print $1}')"
before_lines="$(wc -l < "${under}" | tr -d '[:space:]')"
_cap_cross_session_jsonl "${under}" 100 80
after_md5="$(md5 -q "${under}" 2>/dev/null || md5sum "${under}" | awk '{print $1}')"
after_lines="$(wc -l < "${under}" | tr -d '[:space:]')"
assert_eq "under-cap line count preserved" "50" "${after_lines}"
assert_eq "under-cap content preserved" "${before_md5}" "${after_md5}"

# ----------------------------------------------------------------------
printf 'Test 4: file at exactly cap is unchanged (boundary)\n'
exact="${TEST_DIR}/exact.jsonl"
for i in $(seq 1 100); do printf '{"row":%d}\n' "${i}" >> "${exact}"; done
_cap_cross_session_jsonl "${exact}" 100 80
got_lines="$(wc -l < "${exact}" | tr -d '[:space:]')"
assert_eq "at-cap unchanged" "100" "${got_lines}"

# ----------------------------------------------------------------------
printf 'Test 5: over-cap truncates to retain count\n'
over="${TEST_DIR}/over.jsonl"
for i in $(seq 1 250); do printf '{"row":%d}\n' "${i}" >> "${over}"; done
_cap_cross_session_jsonl "${over}" 100 80
got_lines="$(wc -l < "${over}" | tr -d '[:space:]')"
assert_eq "over-cap truncated to retain" "80" "${got_lines}"

# ----------------------------------------------------------------------
printf 'Test 6: truncation keeps the most recent rows (tail semantics)\n'
first_row="$(head -n 1 "${over}")"
last_row="$(tail -n 1 "${over}")"
assert_eq "first kept row is row 171" '{"row":171}' "${first_row}"
assert_eq "last row preserved" '{"row":250}' "${last_row}"

# ----------------------------------------------------------------------
printf 'Test 7: every cross-session JSONL cap goes through the helper\n'
# 1 def + 7 call sites (misfires, summary, serendipity-log, gate-skips,
# gate_events, used-archetypes, timing-log) = 8 total. If a future
# contributor open-codes an 8th cap site instead of calling the helper,
# this fails — same anti-pattern the helper was created to prevent.
# Strip leading whitespace + comment lines so doc references don't inflate.
# Anchor with `(^|[^a-zA-Z0-9_])` so the count excludes the v1.30.0
# `_do_cap_cross_session_jsonl` inner-helper occurrences (which have
# `_do_` as the leading substring), preventing a substring-match
# inflation when the public helper's name is a suffix of an internal one.
miscall_count="$(grep -vE '^\s*#' "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
  | grep -cE '(^|[^a-zA-Z0-9_])_cap_cross_session_jsonl' || true)"
assert_eq "expected 8 mentions in common.sh (1 def + 7 callers)" "8" "${miscall_count}"

# Also assert the open-coded idiom is fully retired: no more "tail -n N > tmp ; mv tmp file"
# blocks targeting cross-session JSONLs.
open_coded="$(grep -cE 'tail -n [0-9]+ "\$\{[^}]*(misfires|summary|skip|serendipity)' \
  "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" || true)"
assert_eq "no open-coded tail-N idiom remains for known cross-session aggregates" "0" "${open_coded}"

# ----------------------------------------------------------------------
printf 'Test 8: tmp file is cleaned up on tail success (no leftovers)\n'
clean="${TEST_DIR}/clean.jsonl"
for i in $(seq 1 200); do printf '{"row":%d}\n' "${i}" >> "${clean}"; done
_cap_cross_session_jsonl "${clean}" 100 80
leftover_count="$(find "${TEST_DIR}" -maxdepth 1 -name 'clean.jsonl.*' -type f | wc -l | tr -d '[:space:]')"
assert_eq "no temp files left behind" "0" "${leftover_count}"

# ----------------------------------------------------------------------
printf 'Test 9: idempotence — calling twice on the same overflow yields the same result\n'
idem="${TEST_DIR}/idem.jsonl"
for i in $(seq 1 300); do printf '{"row":%d}\n' "${i}" >> "${idem}"; done
_cap_cross_session_jsonl "${idem}" 100 80
sig1="$(md5 -q "${idem}" 2>/dev/null || md5sum "${idem}" | awk '{print $1}')"
_cap_cross_session_jsonl "${idem}" 100 80
sig2="$(md5 -q "${idem}" 2>/dev/null || md5sum "${idem}" | awk '{print $1}')"
assert_eq "second call is a no-op" "${sig1}" "${sig2}"

# ----------------------------------------------------------------------
printf 'Test 10: caller-driven cap values — different (cap, retain) pairs work independently\n'
multi="${TEST_DIR}/multi.jsonl"
for i in $(seq 1 600); do printf '{"row":%d}\n' "${i}" >> "${multi}"; done
_cap_cross_session_jsonl "${multi}" 500 400
got_a="$(wc -l < "${multi}" | tr -d '[:space:]')"
assert_eq "first cap retains 400" "400" "${got_a}"
# Second call with smaller cap on already-capped file
_cap_cross_session_jsonl "${multi}" 200 100
got_b="$(wc -l < "${multi}" | tr -d '[:space:]')"
assert_eq "second cap (200/100) further trims" "100" "${got_b}"

# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
printf 'Test 11: cap routes through with_cross_session_log_lock (v1.30.0 sre-lens F-2)\n'
# Locks in the v1.30.0 cap-race fix: when over-cap, the rotation must
# happen under with_cross_session_log_lock so concurrent SubagentStop
# bursts (council Phase 8 fan-out → 30+ rows in a few hundred ms) do
# not lose appends to the tail+mv window. Structural assertion: the
# helper body must reference with_cross_session_log_lock; an open-
# coded tail+mv inside _cap_cross_session_jsonl would silently regress.
cap_body="$(declare -f _cap_cross_session_jsonl)"
if [[ "${cap_body}" == *"with_cross_session_log_lock"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T11: _cap_cross_session_jsonl body lacks with_cross_session_log_lock\n' >&2
  fail=$((fail + 1))
fi
# Inner helper exists.
if declare -F _do_cap_cross_session_jsonl >/dev/null; then
  pass=$((pass + 1))
else
  printf '  FAIL: T11: _do_cap_cross_session_jsonl not defined\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 12: sweep marker corruption guard (v1.30.0 sre-lens F-3)\n'
# Locks in the F-3 fix: a corrupt or non-numeric .last_sweep marker
# must not crash sweep_stale_sessions under `set -euo pipefail` AND
# must not trigger the CPU-storm where every common.sh source re-runs
# the heavy find-walk. The guard validates the marker is `^[0-9]+$`;
# on corruption it stamps a fresh epoch and skips the round.
_T12_STATE_ROOT="$(mktemp -d)"
_T12_STATE_ROOT_BACKUP="${STATE_ROOT}"
STATE_ROOT="${_T12_STATE_ROOT}"
mkdir -p "${STATE_ROOT}"

# Case A: zero-byte marker (truncated by a crashed prior write).
: > "${STATE_ROOT}/.last_sweep"
_t12_rc=0
sweep_stale_sessions || _t12_rc=$?
assert_eq "T12 case A: zero-byte marker does not crash sweep" "0" "${_t12_rc}"
_t12_after="$(cat "${STATE_ROOT}/.last_sweep" 2>/dev/null || echo "")"
if [[ "${_t12_after}" =~ ^[0-9]+$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12 case A: zero-byte marker not reset to numeric epoch (got %q)\n' "${_t12_after}" >&2
  fail=$((fail + 1))
fi

# Case B: non-numeric garbage in marker.
printf 'garbage-content\n' > "${STATE_ROOT}/.last_sweep"
_t12_rc=0
sweep_stale_sessions || _t12_rc=$?
assert_eq "T12 case B: garbage marker does not crash sweep" "0" "${_t12_rc}"
_t12_after="$(cat "${STATE_ROOT}/.last_sweep" 2>/dev/null || echo "")"
if [[ "${_t12_after}" =~ ^[0-9]+$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T12 case B: garbage marker not reset to numeric epoch (got %q)\n' "${_t12_after}" >&2
  fail=$((fail + 1))
fi

# Case C: valid recent marker — sweep skips, marker unchanged.
_t12_now="$(date +%s)"
printf '%s\n' "${_t12_now}" > "${STATE_ROOT}/.last_sweep"
_t12_rc=0
sweep_stale_sessions || _t12_rc=$?
assert_eq "T12 case C: valid recent marker does not crash sweep" "0" "${_t12_rc}"
_t12_after="$(cat "${STATE_ROOT}/.last_sweep" 2>/dev/null || echo "")"
assert_eq "T12 case C: valid recent marker unchanged" "${_t12_now}" "${_t12_after}"

STATE_ROOT="${_T12_STATE_ROOT_BACKUP}"
rm -rf "${_T12_STATE_ROOT}"

printf '\n=== Cross-Session Rotation Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
