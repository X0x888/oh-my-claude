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
# 1 def + 6 call sites (misfires, summary, serendipity-log, gate-skips,
# gate_events, used-archetypes) = 7 total. If a future contributor open-
# codes a 7th cap site instead of calling the helper, this fails — same
# anti-pattern the helper was created to prevent.
# Strip leading whitespace + comment lines so doc references don't inflate.
miscall_count="$(grep -vE '^\s*#' "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
  | grep -c '_cap_cross_session_jsonl' || true)"
assert_eq "expected 7 mentions in common.sh (1 def + 6 callers)" "7" "${miscall_count}"

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
printf '\n=== Cross-Session Rotation Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
