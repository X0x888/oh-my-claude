#!/usr/bin/env bash
# test-discover-session.sh — discover_latest_session correctness.
#
# v1.14.0 added cwd-aware filtering so two concurrent sessions for
# different projects do not race on mtime — manually-invoked autowork
# scripts (record-finding-list.sh, show-status.sh) must pick the
# session belonging to the current working directory, not whichever
# was touched most recently.
#
# This test exercises:
#   1. Single-session: discovery returns it.
#   2. Two sessions, different cwds, current PWD matches one: that one wins.
#   3. Two sessions, different cwds, current PWD matches neither: newest mtime wins (legacy).
#   4. Sessions without a stored cwd field: legacy newest-mtime behavior.
#   5. Two cwd matches: newest of the matches wins.
#   6. Empty STATE_ROOT directory: returns empty.
#   7. Missing STATE_ROOT: returns empty (no error).
#   8. Dormant resume sources and synthetic watchdog state are never selected.
#   9. Malformed ownership markers fail open instead of hiding a live session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

setup_test() {
  TEST_STATE_ROOT="$(mktemp -d)"
  STATE_ROOT="${TEST_STATE_ROOT}"
  bump_clock=0
}

teardown_test() {
  rm -rf "${TEST_STATE_ROOT}" 2>/dev/null || true
}

trap 'teardown_test' EXIT INT TERM

# Create a session dir with a stored cwd field. If cwd="" the field is omitted.
make_session() {
  local sid="$1"
  local stored_cwd="${2:-}"
  local sd="${STATE_ROOT}/${sid}"
  mkdir -p "${sd}"
  if [[ -n "${stored_cwd}" ]]; then
    jq -nc --arg cwd "${stored_cwd}" '{cwd:$cwd}' > "${sd}/${STATE_JSON}"
  else
    printf '%s\n' '{}' > "${sd}/${STATE_JSON}"
  fi
}

# Bump session mtime deterministically. Fixed mtimes make this test instant and
# avoid turning five ordering assertions into five seconds of wall-clock sleep.
bump_session() {
  bump_clock=$((bump_clock + 1))
  local stamp
  printf -v stamp '2024010100%02d.%02d' "${bump_clock}" "${bump_clock}"
  touch -t "${stamp}" "${STATE_ROOT}/$1"
}

# ---------------------------------------------------------------------
printf 'Test 1: single-session discovery\n'
setup_test
make_session "single-only" "/tmp/repo-a"
got="$(PWD=/tmp/repo-a discover_latest_session)"
assert_eq "single session is returned" "single-only" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf 'Test 2: two sessions, current PWD matches one — that one wins even if older\n'
setup_test
make_session "older-but-mine" "/tmp/repo-mine"
bump_session "older-but-mine"
make_session "newer-not-mine" "/tmp/repo-other"
bump_session "newer-not-mine"
got="$(PWD=/tmp/repo-mine discover_latest_session)"
assert_eq "cwd-matching older session beats newer-mtime non-match" "older-but-mine" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf 'Test 3: two sessions, current PWD matches neither — fall back to newest mtime\n'
setup_test
make_session "first-stranger" "/tmp/repo-x"
bump_session "first-stranger"
make_session "second-stranger" "/tmp/repo-y"
bump_session "second-stranger"
got="$(PWD=/tmp/repo-elsewhere discover_latest_session)"
assert_eq "no cwd match: newest-mtime wins (legacy)" "second-stranger" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 4: sessions without stored cwd — legacy newest-mtime behavior\n"
setup_test
make_session "old-no-cwd" ""
bump_session "old-no-cwd"
make_session "new-no-cwd" ""
bump_session "new-no-cwd"
got="$(PWD=/tmp/repo-anywhere discover_latest_session)"
assert_eq "no cwd field on either: newest-mtime wins" "new-no-cwd" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 5: newer matching session wins over older matching session\n"
setup_test
make_session "older-match" "/tmp/repo-shared"
bump_session "older-match"
make_session "newer-match" "/tmp/repo-shared"
bump_session "newer-match"
got="$(PWD=/tmp/repo-shared discover_latest_session)"
assert_eq "two cwd matches: newest of those wins" "newer-match" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 6: empty STATE_ROOT directory returns empty\n"
setup_test
got="$(PWD=/anywhere discover_latest_session)"
assert_eq "empty STATE_ROOT" "" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 7: missing STATE_ROOT returns empty\n"
setup_test
rm -rf "${STATE_ROOT}"
got="$(PWD=/anywhere discover_latest_session)"
assert_eq "missing STATE_ROOT" "" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 8: dormant resume sources and watchdog state are excluded\n"
setup_test
make_session "live-resume-target" "/tmp/repo-resumed"
make_session "dormant-resume-source" "/tmp/repo-resumed"
jq '.resume_transferred_to = "live-resume-target"' \
  "${STATE_ROOT}/dormant-resume-source/${STATE_JSON}" \
  > "${STATE_ROOT}/dormant-resume-source/${STATE_JSON}.tmp"
mv "${STATE_ROOT}/dormant-resume-source/${STATE_JSON}.tmp" \
  "${STATE_ROOT}/dormant-resume-source/${STATE_JSON}"
bump_session "dormant-resume-source"
mkdir -p "${STATE_ROOT}/_watchdog"
bump_session "_watchdog"
got="$(PWD=/tmp/repo-resumed discover_latest_session)"
assert_eq "newer dormant/watchdog dirs cannot beat live resume target" \
  "live-resume-target" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf "Test 9: malformed transfer marker fails open\n"
setup_test
make_session "older-valid-session" "/tmp/repo-malformed"
bump_session "older-valid-session"
make_session "newer-malformed-marker" "/tmp/repo-malformed"
jq '.resume_transferred_to = "../not-a-session"' \
  "${STATE_ROOT}/newer-malformed-marker/${STATE_JSON}" \
  > "${STATE_ROOT}/newer-malformed-marker/${STATE_JSON}.tmp"
mv "${STATE_ROOT}/newer-malformed-marker/${STATE_JSON}.tmp" \
  "${STATE_ROOT}/newer-malformed-marker/${STATE_JSON}"
bump_session "newer-malformed-marker"
got="$(PWD=/tmp/repo-malformed discover_latest_session)"
assert_eq "malformed fence cannot hide newest live session" \
  "newer-malformed-marker" "${got}"
teardown_test

# ---------------------------------------------------------------------
printf '\n=== Discover-Session: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
