#!/usr/bin/env bash
# Tests for the workflow_substrate flag's RUNTIME enforcement in
# prompt-intent-router.sh.
#
# The flag gates whether the harness may use Claude Code's Workflow tool
# as an opt-in execution substrate for heavy fan-out. The static @-doctrine
# (model-robustness Mechanisms 2-3, autowork SKILL) presents the tool as
# "gated on workflow_substrate=on", but the model cannot evaluate that gate
# without the runtime value. This test pins the enforcement: when OFF, the
# router injects a suppression directive on active turns; when ON (default),
# nothing is injected and the static authorization stands.
#
# Drives the router end-to-end with synthetic prompts (mirrors
# test-divergence-directive.sh's harness). A post-implementation
# quality-reviewer finding (the flag was parsed but had no runtime consumer)
# motivated the enforcement this test covers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t workflow-substrate-home-XXXXXX)"
_test_state_root="${_test_home}/state"
_test_project="${_test_home}/project"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
mkdir -p "${_test_project}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:200}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpected needle=%q in haystack\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

_cleanup_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup_test EXIT

# Drive prompt-intent-router.sh and return the additionalContext string.
_run_router() {
  local session_id="$1"
  local prompt_text="$2"
  shift 2
  local env_args=("$@")

  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    --arg cwd "${_test_project}" \
    '{session_id:$sid, prompt:$p, cwd:$cwd}')"

  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    env ${env_args[@]+"${env_args[@]}"} \
    bash -c 'cd "$1" && bash "$2"' _ "${_test_project}" "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

_NEEDLE="WORKFLOW-SUBSTRATE DISABLED"

# An ordinary execution-intent ULW prompt and a bug-fix one. The
# suppression directive is gated on intent (active turn), NOT on
# paradigm-ambiguity — so it must fire on both, unlike the divergence
# directive which requires a paradigm-shape prompt.
_EXEC_PROMPT="ulw refactor the cache layer across the storage module"
_BUGFIX_PROMPT="ulw fix the off-by-one bug in lib/parse.ts:42"

# ----------------------------------------------------------------------
printf 'Test 1: OFF — suppression directive fires on an execution prompt\n'
out="$(_run_router "t1-${RANDOM}" "${_EXEC_PROMPT}" "OMC_WORKFLOW_SUBSTRATE=off")"
assert_contains "T1: suppression present when off" "${_NEEDLE}" "${out}"
assert_contains "T1: names the Agent-tool fallback" "Agent" "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: OFF fires regardless of paradigm (intent-gated, not paradigm-gated)\n'
# Unlike divergence_directive, this fires on ANY active turn — a bug-fix
# prompt (no paradigm decision) must still get the suppression when off.
out="$(_run_router "t2-${RANDOM}" "${_BUGFIX_PROMPT}" "OMC_WORKFLOW_SUBSTRATE=off")"
assert_contains "T2: suppression present on non-paradigm exec prompt" "${_NEEDLE}" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: default (no env) — no suppression (default is on)\n'
out="$(_run_router "t3-${RANDOM}" "${_EXEC_PROMPT}")"
assert_not_contains "T3: no suppression at default-on" "${_NEEDLE}" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: explicit ON — no suppression\n'
out="$(_run_router "t4-${RANDOM}" "${_EXEC_PROMPT}" "OMC_WORKFLOW_SUBSTRATE=on")"
assert_not_contains "T4: no suppression when on" "${_NEEDLE}" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: OFF — suppression skipped on a checkpoint prompt (exclusion guard)\n'
# The directive gates on checkpoint_prompt -eq 0; a checkpoint meta-prompt
# must NOT receive it even with the flag off. Mirrors divergence T12.
out="$(_run_router "t5-${RANDOM}" "ulw checkpoint here please" "OMC_WORKFLOW_SUBSTRATE=off")"
assert_not_contains "T5: no suppression on checkpoint prompt" "${_NEEDLE}" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: OFF — suppression skipped on a session-management prompt (exclusion guard)\n'
# The directive gates on session_management_prompt -eq 0; a workflow-state
# meta-prompt must NOT receive it even with the flag off. Mirrors divergence
# T11. (If this prompt mis-classified as execution, the directive WOULD fire
# and this assertion would fail — so the test is self-checking.)
out="$(_run_router "t6-${RANDOM}" "ulw should I wrap up and start a fresh session?" "OMC_WORKFLOW_SUBSTRATE=off")"
assert_not_contains "T6: no suppression on session-management prompt" "${_NEEDLE}" "${out}"

# ----------------------------------------------------------------------
printf '\n=== test-workflow-substrate: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
