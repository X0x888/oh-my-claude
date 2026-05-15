#!/usr/bin/env bash
#
# Regression net for bundle/dot-claude/quality-pack/scripts/cleanup-orphan-resume.sh.
#
# The cleanup script kills stale `omc-resume-*` tmux sessions left
# behind by the resume-watchdog. The hot path runs `tmux list-sessions`
# + `tmux kill-session`; these tests mock both via a fake `tmux` binary
# on PATH so the real tmux server is never touched. Each test fixture
# defines a synthetic session set, drives the cleanup script, and
# asserts on a kill-log file written by the fake `tmux`.
#
# Coverage axes:
#   - excludes the current SESSION_ID's expected sess_name
#   - excludes attached sessions (session_attached >= 1)
#   - excludes sessions newer than the max-age threshold
#   - kills sessions older than the threshold with attached=0
#   - clean no-op when no `omc-resume-*` sessions exist
#   - clean no-op when `tmux` is not on PATH
#   - clean no-op when `cleanup_orphan_resume=off`
#   - configurable threshold via OMC_ORPHAN_RESUME_MAX_AGE_HOURS
#   - non-omc-resume tmux sessions are never touched

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLEANUP_SCRIPT="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/cleanup-orphan-resume.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# Build a synthetic tmux mock. The mock reads its `list-sessions` data
# from $TMUX_MOCK_DATA (one `name|created|attached` per line) and
# writes every `kill-session -t <name>` to $TMUX_MOCK_KILLS (one
# session-name per line).
make_mock_tmux() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"
  cat >"${mock_dir}/tmux" <<'MOCKSH'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions)
    if [[ -f "${TMUX_MOCK_DATA:-}" ]]; then
      cat "${TMUX_MOCK_DATA}"
    fi
    exit 0
    ;;
  kill-session)
    # Args: kill-session -t <name>
    if [[ "${2:-}" == "-t" && -n "${3:-}" ]]; then
      printf '%s\n' "${3}" >>"${TMUX_MOCK_KILLS:-/dev/null}"
    fi
    exit 0
    ;;
  has-session)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
MOCKSH
  chmod +x "${mock_dir}/tmux"
}

# Reset between tests.
reset_fixture() {
  : >"${TMUX_MOCK_DATA}"
  : >"${TMUX_MOCK_KILLS}"
}

setup_env() {
  # Isolate STATE_ROOT and HOME so the script's gate-event writes hit
  # a temp dir, not the user's real ~/.claude.
  export STATE_ROOT="${TMPDIR_TEST}/state"
  export HOME="${TMPDIR_TEST}/fake-home"
  mkdir -p "${STATE_ROOT}" "${HOME}/.claude/quality-pack" "${HOME}/.claude/skills/autowork/scripts"
  # The cleanup script sources $HOME/.claude/skills/autowork/scripts/
  # common.sh — symlink to the source repo so the new helpers are
  # available without running install.sh.
  ln -sf "${COMMON_SH}" "${HOME}/.claude/skills/autowork/scripts/common.sh"
  # The classifier/timing libs are lazy-loaded; symlink the lib dir too.
  if [[ -d "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib" ]]; then
    ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib" \
      "${HOME}/.claude/skills/autowork/scripts/lib"
  fi
  export TMUX_MOCK_DATA="${TMPDIR_TEST}/tmux-data"
  export TMUX_MOCK_KILLS="${TMPDIR_TEST}/tmux-kills"
  : >"${TMUX_MOCK_DATA}"
  : >"${TMUX_MOCK_KILLS}"
}

NOW="$(date +%s)"
# Helpers for synthetic ages (seconds → epoch_at_now_minus).
age_seconds() { printf '%s' "$(( NOW - $1 ))"; }
age_hours() { age_seconds "$(( $1 * 3600 ))"; }

# --------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------

setup_env
MOCK_BIN="${TMPDIR_TEST}/mockbin"
make_mock_tmux "${MOCK_BIN}"
# Prepend mock dir so our fake tmux wins.
export PATH="${MOCK_BIN}:${PATH}"

# Sanity-check the mock is on PATH.
if [[ "$(command -v tmux)" != "${MOCK_BIN}/tmux" ]]; then
  printf 'SETUP FAIL: mock tmux not on PATH (got %s)\n' "$(command -v tmux)" >&2
  exit 1
fi

# --------------------------------------------------------------------
# Test 1 — clean no-op when no omc-resume-* sessions exist
# --------------------------------------------------------------------
printf 'Test 1: empty session list → no kills, exit 0\n'
reset_fixture
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 1: no kills" "0" "${kill_count}"

# --------------------------------------------------------------------
# Test 2 — non-omc-resume sessions are NEVER touched
# --------------------------------------------------------------------
printf 'Test 2: non-omc tmux sessions are ignored\n'
reset_fixture
{
  printf 'my-work-session|%s|0\n' "$(age_hours 100)"
  printf 'main|%s|0\n' "$(age_hours 1)"
  printf 'background-job|%s|0\n' "$(age_hours 50)"
} >"${TMUX_MOCK_DATA}"
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 2: zero kills on non-omc sessions" "0" "${kill_count}"

# --------------------------------------------------------------------
# Test 3 — old, never-attached omc-resume sessions are killed
# --------------------------------------------------------------------
printf 'Test 3: stale omc-resume session is killed\n'
reset_fixture
printf 'omc-resume-xxx-old|%s|0\n' "$(age_hours 100)" >"${TMUX_MOCK_DATA}"
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 3: stale session killed" "1" "${kill_count}"
killed_name="$(head -1 "${TMUX_MOCK_KILLS}")"
assert_eq "Test 3: correct name killed" "omc-resume-xxx-old" "${killed_name}"

# --------------------------------------------------------------------
# Test 4 — current SESSION_ID's expected sess_name is EXCLUDED
# --------------------------------------------------------------------
printf 'Test 4: current session sess_name is excluded\n'
reset_fixture
# SESSION_ID=9b7683f9-9113-49dc-be80-ff3659c8e201 produces
# sid_short=9b7683f9-9113-49dc-be80- (first 24 chars after tr) and
# sess_name=omc-resume-9b7683f9-9113-49dc-be80-
{
  printf 'omc-resume-9b7683f9-9113-49dc-be80-|%s|0\n' "$(age_hours 100)"
  printf 'omc-resume-other-old|%s|0\n' "$(age_hours 100)"
} >"${TMUX_MOCK_DATA}"
SESSION_ID="9b7683f9-9113-49dc-be80-ff3659c8e201" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 4: one kill (the other one)" "1" "${kill_count}"
killed_name="$(head -1 "${TMUX_MOCK_KILLS}")"
assert_eq "Test 4: current sess_name NOT killed" "omc-resume-other-old" "${killed_name}"

# --------------------------------------------------------------------
# Test 5 — attached sessions are excluded
# --------------------------------------------------------------------
printf 'Test 5: attached sessions are excluded\n'
reset_fixture
{
  printf 'omc-resume-attached-old|%s|1\n' "$(age_hours 100)"
  printf 'omc-resume-unattached-old|%s|0\n' "$(age_hours 100)"
} >"${TMUX_MOCK_DATA}"
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 5: one kill (unattached only)" "1" "${kill_count}"
killed_name="$(head -1 "${TMUX_MOCK_KILLS}")"
assert_eq "Test 5: only unattached killed" "omc-resume-unattached-old" "${killed_name}"

# --------------------------------------------------------------------
# Test 6 — sessions newer than threshold are excluded
# --------------------------------------------------------------------
printf 'Test 6: sessions newer than threshold are excluded\n'
reset_fixture
{
  printf 'omc-resume-recent|%s|0\n' "$(age_hours 1)"      # 1h < 4h
  printf 'omc-resume-old|%s|0\n' "$(age_hours 100)"       # 100h > 4h
} >"${TMUX_MOCK_DATA}"
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 6: one kill (old only)" "1" "${kill_count}"
killed_name="$(head -1 "${TMUX_MOCK_KILLS}")"
assert_eq "Test 6: only old killed" "omc-resume-old" "${killed_name}"

# --------------------------------------------------------------------
# Test 7 — OMC_ORPHAN_RESUME_MAX_AGE_HOURS env override
# --------------------------------------------------------------------
printf 'Test 7: env max-age override applies\n'
reset_fixture
printf 'omc-resume-2h|%s|0\n' "$(age_hours 2)" >"${TMUX_MOCK_DATA}"
# Default threshold is 4h → would NOT kill a 2h session.
# Override to 1h → SHOULD kill.
OMC_ORPHAN_RESUME_MAX_AGE_HOURS=1 SESSION_ID="abcd-1234" \
  bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 7: override→kill" "1" "${kill_count}"

# --------------------------------------------------------------------
# Test 8 — cleanup_orphan_resume=off (via env) → no kills even on old sessions
# --------------------------------------------------------------------
printf 'Test 8: cleanup_orphan_resume=off → no kills\n'
reset_fixture
printf 'omc-resume-old|%s|0\n' "$(age_hours 100)" >"${TMUX_MOCK_DATA}"
OMC_CLEANUP_ORPHAN_RESUME=off SESSION_ID="abcd-1234" \
  bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 8: opt-out respected" "0" "${kill_count}"

# --------------------------------------------------------------------
# Test 9 — tmux absent → clean no-op
# --------------------------------------------------------------------
printf 'Test 9: tmux absent → clean no-op\n'
reset_fixture
NO_TMUX_PATH="${TMPDIR_TEST}/no-tmux-path"
mkdir -p "${NO_TMUX_PATH}"
# Synthesize a PATH that has the standard bins but no tmux mock.
clean_path="${NO_TMUX_PATH}:/usr/bin:/bin"
if PATH="${clean_path}" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: Test 9: nonzero exit when tmux absent\n' >&2
  fail=$((fail + 1))
fi

# --------------------------------------------------------------------
# Test 10 — malformed timestamp on one row doesn't break the loop
# --------------------------------------------------------------------
printf 'Test 10: malformed row is skipped, others processed\n'
reset_fixture
{
  printf 'omc-resume-bad|garbage|0\n'
  printf 'omc-resume-good|%s|0\n' "$(age_hours 100)"
} >"${TMUX_MOCK_DATA}"
SESSION_ID="abcd-1234" bash "${CLEANUP_SCRIPT}" </dev/null >/dev/null 2>&1
kill_count="$(wc -l <"${TMUX_MOCK_KILLS}" | tr -d ' ')"
assert_eq "Test 10: bad row skipped, good row killed" "1" "${kill_count}"
killed_name="$(head -1 "${TMUX_MOCK_KILLS}")"
assert_eq "Test 10: only good row killed" "omc-resume-good" "${killed_name}"

# --------------------------------------------------------------------
# Results
# --------------------------------------------------------------------
printf '\n=== cleanup-orphan-resume tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
exit "${fail}"
