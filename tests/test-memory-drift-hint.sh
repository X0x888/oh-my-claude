#!/usr/bin/env bash
# Tests for the v1.20.0 memory drift hint in prompt-intent-router.sh.
#
# The drift hint fires once per session when the user-scope auto-memory
# directory for the current cwd contains files older than 30 days. It
# points the model at /memory-audit and reminds it to verify named
# claims against current code.
#
# Asserts:
#   - hint fires when stale files (>30d) exist in memory dir
#   - hint does NOT fire when all files are recent
#   - hint does NOT fire when memory dir is absent
#   - hint does NOT fire when OMC_AUTO_MEMORY=off
#   - hint is one-shot per session: second prompt does NOT re-emit
#   - hint references /memory-audit for triage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t memory-drift-home-XXXXXX)"
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
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s (unexpected needle present)\n    needle=%q\n' "${label}" "${needle}" >&2
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

# Build a memory dir under the sandboxed HOME for a fictional cwd, plus
# the matching projects path Claude Code derives from cwd → cwd-with-
# slashes-replaced-by-dashes. The router uses pwd at runtime, so the
# test cwd's tr-encoded form must match the projects subdir under
# _test_home.
_make_memory_for_cwd() {
  local cwd="$1"
  local stale_count="${2:-0}"
  local recent_count="${3:-0}"
  local encoded_cwd
  encoded_cwd="$(printf '%s' "${cwd}" | tr '/' '-')"
  local memory_dir="${_test_home}/.claude/projects/${encoded_cwd}/memory"
  mkdir -p "${memory_dir}"

  local old_ts recent_ts
  old_ts="$(date -v-60d +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d '60 days ago' +%Y%m%d%H%M 2>/dev/null \
    || date +%Y%m%d%H%M)"
  recent_ts="$(date +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M)"

  local i
  for ((i = 1; i <= stale_count; i++)); do
    touch -t "${old_ts}" "${memory_dir}/project_stale_${i}.md"
  done
  for ((i = 1; i <= recent_count; i++)); do
    touch -t "${recent_ts}" "${memory_dir}/feedback_recent_${i}.md"
  done
  printf '%s' "${memory_dir}"
}

# Run the router with a given cwd and prompt; return additionalContext.
_run_router_in() {
  local cwd="$1"
  local session_id="$2"
  local prompt_text="$3"
  shift 3
  local env_args=("$@")

  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    --arg cwd "${cwd}" \
    '{session_id:$sid, prompt:$p, cwd:$cwd}')"

  ( cd "${cwd}" && \
    HOME="${_test_home}" \
      STATE_ROOT="${_test_state_root}" \
      env ${env_args[@]+"${env_args[@]}"} \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true )
}

# ----------------------------------------------------------------------
printf 'Test 1: hint fires when memory dir contains stale files\n'
test_cwd="$(mktemp -d -t drift-cwd-XXXXXX)"
_make_memory_for_cwd "${test_cwd}" 3 2 >/dev/null
shared_session_id="t1-${RANDOM}"
out="$(_run_router_in "${test_cwd}" "${shared_session_id}" "ulw add a helper to lib/parse.ts")"
assert_contains "drift hint header"   "MEMORY DRIFT HINT"   "${out}"
assert_contains "drift hint count"    "3 memory file"       "${out}"
assert_contains "drift hint refs audit" "/memory-audit"     "${out}"
assert_contains "drift hint nudges verification" "verify"   "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: hint is one-shot — second prompt in same session does NOT re-emit\n'
# Re-uses the SAME session_id so the memory_drift_hint_emitted flag set
# by the first invocation is read by the second. The flag lives in the
# per-session state file (sessions/<id>/session_state.json), so a
# fresh session_id would always re-emit — that's expected and not what
# this test exercises.
out2="$(_run_router_in "${test_cwd}" "${shared_session_id}" "ulw next step")"
assert_not_contains "no re-emit on second prompt" "MEMORY DRIFT HINT" "${out2}"

# Cleanup state for next tests so each test starts with a fresh flag.
rm -rf "${_test_state_root}"
mkdir -p "${_test_state_root}"
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
printf 'Test 3: hint does NOT fire when all files are recent\n'
test_cwd="$(mktemp -d -t drift-cwd-XXXXXX)"
_make_memory_for_cwd "${test_cwd}" 0 5 >/dev/null
out="$(_run_router_in "${test_cwd}" "t3-${RANDOM}" "ulw add a helper")"
assert_not_contains "no hint when all recent" "MEMORY DRIFT HINT" "${out}"
rm -rf "${_test_state_root}"; mkdir -p "${_test_state_root}"
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
printf 'Test 4: hint does NOT fire when memory dir does not exist\n'
test_cwd="$(mktemp -d -t drift-cwd-noexist-XXXXXX)"
# Do NOT create any memory dir for this cwd.
out="$(_run_router_in "${test_cwd}" "t4-${RANDOM}" "ulw add a helper")"
assert_not_contains "no hint when no memory dir" "MEMORY DRIFT HINT" "${out}"
rm -rf "${_test_state_root}"; mkdir -p "${_test_state_root}"
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
printf 'Test 5: hint does NOT fire when OMC_AUTO_MEMORY=off\n'
test_cwd="$(mktemp -d -t drift-cwd-off-XXXXXX)"
_make_memory_for_cwd "${test_cwd}" 5 0 >/dev/null
out="$(_run_router_in "${test_cwd}" "t5-${RANDOM}" "ulw add a helper" "OMC_AUTO_MEMORY=off")"
assert_not_contains "no hint when auto_memory=off" "MEMORY DRIFT HINT" "${out}"
rm -rf "${_test_state_root}"; mkdir -p "${_test_state_root}"
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
printf 'Test 6: hint fires for non-ULW sessions too (auto-memory loads in every session)\n'
test_cwd="$(mktemp -d -t drift-cwd-nonulw-XXXXXX)"
_make_memory_for_cwd "${test_cwd}" 2 0 >/dev/null
# Plain "fix the bug" prompt — execution intent but no ulw trigger.
out="$(_run_router_in "${test_cwd}" "t6-${RANDOM}" "fix the off-by-one bug in lib/parse.ts:42")"
assert_contains "non-ULW hint fires" "MEMORY DRIFT HINT" "${out}"
rm -rf "${_test_state_root}"; mkdir -p "${_test_state_root}"
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
printf 'Test 7: check_memory_drift unit-level — direct call paths\n'
# Direct unit tests on the helper.
test_cwd="$(mktemp -d -t drift-unit-XXXXXX)"

# Stale → returns hint.
_make_memory_for_cwd "${test_cwd}" 1 0 >/dev/null
unit_out="$(cd "${test_cwd}" && check_memory_drift)"
assert_contains "unit: stale → hint" "MEMORY DRIFT HINT" "${unit_out}"

# All recent → returns empty.
rm -rf "${_test_home}/.claude/projects"
_make_memory_for_cwd "${test_cwd}" 0 1 >/dev/null
unit_out="$(cd "${test_cwd}" && check_memory_drift)"
if [[ -z "${unit_out}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: unit: recent → empty (got: %q)\n' "${unit_out}" >&2
  fail=$((fail + 1))
fi

# auto_memory=off → empty even with stale.
rm -rf "${_test_home}/.claude/projects"
_make_memory_for_cwd "${test_cwd}" 1 0 >/dev/null
unit_out="$(cd "${test_cwd}" && OMC_AUTO_MEMORY=off check_memory_drift)"
if [[ -z "${unit_out}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: unit: auto_memory=off → empty (got: %q)\n' "${unit_out}" >&2
  fail=$((fail + 1))
fi
rm -rf "${test_cwd}"

# ----------------------------------------------------------------------
if (( fail > 0 )); then
  printf '\n%d/%d failed\n' "${fail}" "$((pass + fail))" >&2
  exit 1
fi

printf '\nAll %d memory-drift-hint assertions passed\n' "${pass}"
