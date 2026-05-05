#!/usr/bin/env bash
#
# tests/test-project-key-write.sh — regression net for the v1.32.6
# project_key wiring fix. v1.31.0 Wave 4 wired the read path in
# `_sweep_append_gate_events` (common.sh:1193-1194) but never the
# write path — so all swept telemetry rows carried `project_key:
# null`, defeating multi-project /ulw-report slicing across every
# cross-session ledger. v1.32.6 closes the gap by writing
# `_omc_project_key` into `session_state.json` at first ULW
# activation in prompt-intent-router.sh.
#
# This test exercises the full write path: setup a fake git repo,
# invoke the router with a /ulw prompt, verify session_state.json
# carries a non-null project_key matching `_omc_project_key`'s
# output for the same repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t project-key-home-XXXXXX)"
_test_state_root="${_test_home}/state"
_test_repo="${_test_home}/fake-repo"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}" "${_test_repo}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

# Setup a fake git repo with a known remote — gives _omc_project_key
# a deterministic value to assert against.
(
  cd "${_test_repo}" || exit 1
  git init -q
  git remote add origin "https://github.com/test-org/test-repo.git"
  git config user.email "test@example.test"
  git config user.name "Test"
)

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
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

_cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup EXIT

# Compute the expected project_key for the fake repo.
expected_key="$(cd "${_test_repo}" && _omc_project_key)"

_run_router() {
  local session_id="$1" prompt_text="$2"
  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    --arg cwd "${_test_repo}" \
    '{session_id:$sid, prompt:$p, cwd:$cwd}')"
  cd "${_test_repo}"
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" >/dev/null 2>&1 \
    || true
  cd "${REPO_ROOT}"
}

# ---------------------------------------------------------------------
printf 'Test 1: _omc_project_key produces a 12-char hex string for the fake repo\n'
assert_match "T1: 12-char hex" '^[0-9a-f]{12}$' "${expected_key}"

# ---------------------------------------------------------------------
printf 'Test 2: router writes project_key to session_state.json on /ulw prompt\n'
sid_t2="t2-$$-${RANDOM}"
_run_router "${sid_t2}" "ulw fix the project_key wiring debt"
state_file="${_test_state_root}/${sid_t2}/session_state.json"

if [[ -f "${state_file}" ]]; then
  written_key="$(jq -r '.project_key // ""' "${state_file}" 2>/dev/null)"
  assert_eq "T2: project_key in state matches _omc_project_key()" "${expected_key}" "${written_key}"
else
  printf '  FAIL: T2: session_state.json not created at %s\n' "${state_file}" >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 3: project_key is first-write-wins (does not change on second prompt)\n'
sid_t3="t3-$$-${RANDOM}"
_run_router "${sid_t3}" "ulw initial prompt"
state_file_t3="${_test_state_root}/${sid_t3}/session_state.json"
key_first="$(jq -r '.project_key // ""' "${state_file_t3}" 2>/dev/null)"

# Change the remote URL to simulate a remote rename mid-session.
# project_key in state should NOT change — first-write-wins.
(cd "${_test_repo}" && git remote set-url origin "https://github.com/test-org/renamed-repo.git")

_run_router "${sid_t3}" "ulw second prompt after remote rename"
key_second="$(jq -r '.project_key // ""' "${state_file_t3}" 2>/dev/null)"

assert_eq "T3: project_key preserved across prompts (first-write-wins)" "${key_first}" "${key_second}"

# Reset the remote so subsequent tests aren't affected.
(cd "${_test_repo}" && git remote set-url origin "https://github.com/test-org/test-repo.git")

# ---------------------------------------------------------------------
printf 'Test 4: non-git directory falls back to _omc_project_id (cwd hash)\n'
non_git_dir="${_test_home}/non-git-cwd"
mkdir -p "${non_git_dir}"

# Compute fallback in the non-git dir (cwd hash of dir name).
expected_fallback="$(cd "${non_git_dir}" && _omc_project_key)"
assert_match "T4: non-git fallback is 12-char hex" '^[0-9a-f]{12}$' "${expected_fallback}"

sid_t4="t4-$$-${RANDOM}"
hook_json_t4="$(jq -nc \
  --arg sid "${sid_t4}" \
  --arg p "ulw run from non-git dir" \
  --arg cwd "${non_git_dir}" \
  '{session_id:$sid, prompt:$p, cwd:$cwd}')"
cd "${non_git_dir}"
HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
  <<<"${hook_json_t4}" >/dev/null 2>&1 \
  || true
cd "${REPO_ROOT}"

state_file_t4="${_test_state_root}/${sid_t4}/session_state.json"
written_fallback="$(jq -r '.project_key // ""' "${state_file_t4}" 2>/dev/null)"
assert_eq "T4: non-git project_key matches _omc_project_id fallback" "${expected_fallback}" "${written_fallback}"

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# Test 5 (v1.32.8 BLOCK fix): non-ULW session-start writes project_key
# ---------------------------------------------------------------------
# Pre-1.32.8 the project_key write was inside the router's ULW gate.
# Sessions that never go ULW (welcome banner / resume hint only) still
# called record_gate_event but tagged rows with project_key=null. This
# test pins the v1.32.8 fix: session-start-welcome.sh is now an
# unconditional caller of record_project_key_if_unset.
printf 'Test 5: non-ULW session-start-welcome writes project_key\n'

sid_t5="t5-$$-${RANDOM}"
hook_json_t5="$(jq -nc \
  --arg sid "${sid_t5}" \
  --arg cwd "${_test_repo}" \
  '{session_id:$sid, source:"startup", cwd:$cwd}')"
cd "${_test_repo}"
HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-welcome.sh" \
  <<<"${hook_json_t5}" >/dev/null 2>&1 \
  || true
cd "${REPO_ROOT}"

state_file_t5="${_test_state_root}/${sid_t5}/session_state.json"
if [[ -f "${state_file_t5}" ]]; then
  written_t5="$(jq -r '.project_key // ""' "${state_file_t5}" 2>/dev/null)"
  assert_eq "T5: session-start-welcome writes project_key (non-ULW path)" "${expected_key}" "${written_t5}"
else
  printf '  FAIL: T5: session-start-welcome did not create session_state.json at %s\n' "${state_file_t5}" >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf '\n=== project-key-write tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
