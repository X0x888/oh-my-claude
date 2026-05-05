#!/usr/bin/env bash
#
# tests/test-backfill-project-key.sh — regression net for the v1.32.9
# backfill tool. The tool walks existing session_state.json files,
# computes _omc_project_key from each session's recorded cwd, and
# writes back when the field is missing. This pins:
#   - Idempotency (rerun after backfill is a no-op)
#   - Fixture-dir filter (non-UUID dirs are skipped)
#   - _watchdog skip
#   - cwd-missing skip (can't compute without cwd)
#   - already-set skip (don't clobber an existing key)
#   - cwd-no-longer-exists fallback to cwd-hash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/backfill-project-key.sh"

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

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "${actual}" =~ ${pattern} ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%q\n    actual=%q\n' "${label}" "${pattern}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

setup_fixture() {
  TEST_STATE_ROOT="$(mktemp -d)"
  TEST_HOME="$(mktemp -d)"

  # Create a fake git repo for the cwd that backfill candidates point at.
  TEST_REPO="${TEST_HOME}/fake-repo"
  mkdir -p "${TEST_REPO}"
  (
    cd "${TEST_REPO}" || exit 1
    git init -q
    git remote add origin "https://github.com/test-org/test-repo.git"
  )

  # Candidate 1: UUID session, cwd set, project_key missing → BACKFILL
  local sid_a="11111111-2222-3333-4444-555555555555"
  mkdir -p "${TEST_STATE_ROOT}/${sid_a}"
  jq -n --arg cwd "${TEST_REPO}" '{cwd:$cwd, workflow_mode:"ultrawork"}' \
    > "${TEST_STATE_ROOT}/${sid_a}/session_state.json"

  # Candidate 2: UUID session, project_key already set → SKIP (already-set)
  local sid_b="22222222-3333-4444-5555-666666666666"
  mkdir -p "${TEST_STATE_ROOT}/${sid_b}"
  jq -n --arg cwd "${TEST_REPO}" --arg pk "preexisting00" \
    '{cwd:$cwd, project_key:$pk}' \
    > "${TEST_STATE_ROOT}/${sid_b}/session_state.json"

  # Candidate 3: UUID session, cwd missing → SKIP (no-cwd)
  local sid_c="33333333-4444-5555-6666-777777777777"
  mkdir -p "${TEST_STATE_ROOT}/${sid_c}"
  jq -n '{workflow_mode:"ultrawork"}' \
    > "${TEST_STATE_ROOT}/${sid_c}/session_state.json"

  # Candidate 4: fixture-shape (non-UUID) session → SKIP (fixture filter)
  local sid_d="p4-2398"
  mkdir -p "${TEST_STATE_ROOT}/${sid_d}"
  jq -n --arg cwd "${TEST_REPO}" '{cwd:$cwd}' \
    > "${TEST_STATE_ROOT}/${sid_d}/session_state.json"

  # Candidate 5: _watchdog session → SKIP (watchdog filter)
  mkdir -p "${TEST_STATE_ROOT}/_watchdog"
  jq -n --arg cwd "${TEST_REPO}" '{cwd:$cwd}' \
    > "${TEST_STATE_ROOT}/_watchdog/session_state.json"

  # Candidate 6: UUID session, cwd points at a non-existent dir →
  # FALLBACK to cwd-hash (still backfills with degraded value)
  local sid_e="66666666-7777-8888-9999-aaaaaaaaaaaa"
  mkdir -p "${TEST_STATE_ROOT}/${sid_e}"
  jq -n --arg cwd "/path/that/does/not/exist/anywhere/123" \
    '{cwd:$cwd}' \
    > "${TEST_STATE_ROOT}/${sid_e}/session_state.json"
}

teardown_fixture() {
  rm -rf "${TEST_STATE_ROOT}" "${TEST_HOME}" 2>/dev/null || true
}

# ---------------------------------------------------------------------
printf 'Test 1: dry-run reports counts without writing\n'
setup_fixture
out_dry="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" --dry-run 2>&1)"
assert_match "T1: dry-run reports backfilled count" '2 backfilled' "${out_dry}"
assert_match "T1: dry-run reports already-set" '1 already-set' "${out_dry}"
assert_match "T1: dry-run reports no-cwd" '1 no-cwd' "${out_dry}"
assert_match "T1: dry-run reports fixture skip" '1 fixture' "${out_dry}"
assert_match "T1: dry-run reports watchdog skip" '1 _watchdog' "${out_dry}"
# Verify session_state.json files unchanged after dry-run
key_after_dry="$(jq -r '.project_key // ""' \
  "${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555/session_state.json")"
assert_eq "T1: dry-run did not write project_key" "" "${key_after_dry}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 2: real run backfills UUID session with valid cwd\n'
setup_fixture
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" >/dev/null 2>&1
key_a="$(jq -r '.project_key // ""' \
  "${TEST_STATE_ROOT}/11111111-2222-3333-4444-555555555555/session_state.json")"
assert_match "T2: candidate A got 12-char hex project_key" '^[0-9a-f]{12}$' "${key_a}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 3: existing project_key is not clobbered\n'
setup_fixture
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" >/dev/null 2>&1
key_b="$(jq -r '.project_key // ""' \
  "${TEST_STATE_ROOT}/22222222-3333-4444-5555-666666666666/session_state.json")"
assert_eq "T3: pre-existing project_key preserved" "preexisting00" "${key_b}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 4: fixture-shape session skipped (no project_key written)\n'
setup_fixture
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" >/dev/null 2>&1
key_d="$(jq -r '.project_key // ""' \
  "${TEST_STATE_ROOT}/p4-2398/session_state.json")"
assert_eq "T4: fixture session not backfilled" "" "${key_d}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 5: rerun is idempotent (already-set sessions skipped)\n'
setup_fixture
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" >/dev/null 2>&1
out_second="$(STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" 2>&1)"
assert_match "T5: rerun reports 0 backfilled" 'Backfilled 0 session_state.json files' "${out_second}"
assert_match "T5: rerun reports 3 already-set (A + B + E from prior run)" '3 already-set' "${out_second}"
teardown_fixture

# ---------------------------------------------------------------------
printf 'Test 6: cwd no-longer-exists falls back to cwd-hash\n'
setup_fixture
STATE_ROOT="${TEST_STATE_ROOT}" HOME="${TEST_HOME}" COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" bash "${TOOL}" >/dev/null 2>&1
key_e="$(jq -r '.project_key // ""' \
  "${TEST_STATE_ROOT}/66666666-7777-8888-9999-aaaaaaaaaaaa/session_state.json")"
assert_match "T6: missing-cwd session got 12-char hex via fallback" '^[0-9a-f]{12}$' "${key_e}"
teardown_fixture

# ---------------------------------------------------------------------
printf '\n=== backfill-project-key tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
