#!/usr/bin/env bash
# Tests for the v1.20.0 auto-memory skip directive in
# prompt-intent-router.sh. The directive instructs Claude to skip the
# session-stop and compact-time auto-memory passes on advisory and
# session-management turns, where work did not move forward and any
# project_*.md write would be low-signal noise.
#
# Drives the router end-to-end with synthetic prompts and parses the
# additionalContext field of the emitted JSON to confirm:
#   - advisory + session_management turns: directive present
#   - execution / continuation / checkpoint turns: directive absent
#   - OMC_AUTO_MEMORY=off: directive suppressed (no rule to skip)
#   - non-ULW advisory: directive still fires (auto-memory.md loads
#     in every session via @-import)
#
# Mirrors the structure of test-bias-defense-directives.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t auto-memory-skip-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
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

_run_router() {
  local session_id="$1"
  local prompt_text="$2"
  shift 2
  local env_args=("$@")

  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    '{session_id:$sid, prompt:$p, cwd:env.PWD}')"

  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    env ${env_args[@]+"${env_args[@]}"} \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

# ----------------------------------------------------------------------
printf 'Test 1: ULW + advisory → AUTO-MEMORY SKIP fires\n'
out="$(_run_router "t1-${RANDOM}" "ulw what do you think about the current memory system?")"
assert_contains "advisory routes through advisory branch" "advisory or decision support" "${out}"
assert_contains "AUTO-MEMORY SKIP present"  "AUTO-MEMORY SKIP" "${out}"
assert_contains "names auto-memory.md"      "auto-memory.md"   "${out}"
assert_contains "names compact.md"          "compact.md"       "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: ULW + session-management → AUTO-MEMORY SKIP fires\n'
out="$(_run_router "t2-${RANDOM}" "ulw should I start a fresh session for this?")"
assert_contains "AUTO-MEMORY SKIP present on SM" "AUTO-MEMORY SKIP" "${out}"
assert_contains "session-management label"      "session-management" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: ULW + execution → no AUTO-MEMORY SKIP\n'
out="$(_run_router "t3-${RANDOM}" "ulw add a new helper function in lib/parse.ts:42 to handle quoted strings")"
assert_not_contains "no SKIP on execution" "AUTO-MEMORY SKIP" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: ULW + checkpoint → no AUTO-MEMORY SKIP\n'
# Checkpoint turns are deliberate stopping points where the user may
# still want a memory wrap-up so the next session resumes cleanly. The
# SKIP directive deliberately excludes checkpoint from the suppression
# set.
out="$(_run_router "t4-${RANDOM}" "ulw checkpoint here please — wrap up cleanly")"
assert_not_contains "no SKIP on checkpoint" "AUTO-MEMORY SKIP" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: ULW + advisory + OMC_AUTO_MEMORY=off → no SKIP (no rule to skip)\n'
out="$(_run_router "t5-${RANDOM}" "ulw what do you think about the architecture?" \
  "OMC_AUTO_MEMORY=off")"
assert_not_contains "no SKIP when auto_memory=off" "AUTO-MEMORY SKIP" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: non-ULW + advisory → AUTO-MEMORY SKIP still fires\n'
# Non-ULW advisory must still get the SKIP directive because the rule
# files (auto-memory.md / compact.md) are loaded via @-import in every
# session, not just ULW sessions. A bare advisory prompt without `ulw`
# should still receive the directive so the model is consistently told
# to skip the rule on those turns.
out="$(_run_router "t6-${RANDOM}" "what do you think about the design?")"
assert_contains "non-ULW advisory still gets SKIP" "AUTO-MEMORY SKIP" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: non-ULW + execution → no SKIP\n'
out="$(_run_router "t7-${RANDOM}" "edit the file foo.py to add a try/except around line 42")"
assert_not_contains "no SKIP on non-ULW execution" "AUTO-MEMORY SKIP" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: SKIP includes the classified intent label for transparency\n'
# The directive embeds the classification so the model knows which
# branch fired. Verify both labels render correctly (advisory uses no
# underscore; session_management is hyphenated for display).
out="$(_run_router "t8a-${RANDOM}" "ulw what do you think about caching?")"
assert_contains "advisory label embedded" "classified as advisory" "${out}"

out="$(_run_router "t8b-${RANDOM}" "should we ship this in a fresh session?")"
assert_contains "session-management label embedded" "classified as session-management" "${out}"

# ----------------------------------------------------------------------
printf 'Test 9: project-level conf auto_memory=off suppresses SKIP\n'
# load_conf walks up from PWD looking for .claude/oh-my-claude.conf and
# reads auto_memory=off when no env var overrides. Drop a temp conf in
# a fresh CWD, run the router with that CWD, and assert the directive
# is suppressed. Mirrors how a real project would opt out via committed
# project-level conf rather than env-var-per-session.
_proj_dir="$(mktemp -d -t auto-memory-conf-proj-XXXXXX)"
mkdir -p "${_proj_dir}/.claude"
printf 'auto_memory=off\n' > "${_proj_dir}/.claude/oh-my-claude.conf"

# Build a hook payload whose cwd field points at the temp project so
# the router records that cwd. The conf walk-up uses $PWD, so we also
# cd into the temp dir for the router invocation.
_conf_hook="$(jq -nc \
  --arg sid "t9-${RANDOM}" \
  --arg p   "what do you think about caching?" \
  --arg cwd "${_proj_dir}" \
  '{session_id:$sid, prompt:$p, cwd:$cwd}')"

# Explicitly unset OMC_AUTO_MEMORY so the conf can take effect (env
# precedence wins over conf).
out="$(cd "${_proj_dir}" && \
  HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  env -u OMC_AUTO_MEMORY \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
  <<<"${_conf_hook}" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
  || true)"

assert_not_contains "project-conf auto_memory=off suppresses SKIP" "AUTO-MEMORY SKIP" "${out}"
rm -rf "${_proj_dir}"

# ----------------------------------------------------------------------
if (( fail > 0 )); then
  printf '\n%d/%d failed\n' "${fail}" "$((pass + fail))" >&2
  exit 1
fi

printf '\nAll %d auto-memory-skip assertions passed\n' "${pass}"
