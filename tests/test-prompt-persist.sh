#!/usr/bin/env bash
# Tests for the v1.30.0 prompt_persist flag.
#
# When `prompt_persist=off`:
#   - prompt-intent-router.sh skips the recent_prompts.jsonl append
#   - last_user_prompt in session_state.json is empty (not the verbatim
#     user prompt)
#   - last_user_prompt_ts is still updated (so consumers tracking
#     "did the prompt change?" still see the timestamp tick)
#   - is_prompt_persist_enabled returns 1 (false)
#
# When `prompt_persist=on` (default) or unset:
#   - recent_prompts.jsonl is appended with the verbatim text
#   - last_user_prompt is the verbatim text
#   - is_prompt_persist_enabled returns 0 (true)
#
# Both env var and project-level conf are exercised.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t prompt-persist-home-XXXXXX)"
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

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1"
  if "${@:2}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

assert_false() {
  local label="$1"
  if ! "${@:2}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s (expected false)\n' "${label}" >&2
    fail=$((fail + 1))
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

  # Bash 3.2 safety note: `${env_args[@]+"${env_args[@]}"}` is the
  # canonical shape for "expand to nothing if empty, otherwise expand
  # quoted" under set -u. The unquoted outer expansion here is safe
  # because env_args entries are always KEY=value pairs with no spaces;
  # if that invariant changes, switch to an explicit `[ ${#env_args[@]}
  # -gt 0 ]` guard.
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    env ${env_args[@]+"${env_args[@]}"} \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" >/dev/null 2>&1 \
    || true
}

# ----------------------------------------------------------------------
printf 'Test 1: is_prompt_persist_enabled defaults to true (on)\n'
unset OMC_PROMPT_PERSIST
assert_true "default on" is_prompt_persist_enabled

# ----------------------------------------------------------------------
printf 'Test 2: OMC_PROMPT_PERSIST=on returns true\n'
OMC_PROMPT_PERSIST=on assert_true "explicit on" is_prompt_persist_enabled

# ----------------------------------------------------------------------
printf 'Test 3: OMC_PROMPT_PERSIST=off returns false\n'
OMC_PROMPT_PERSIST=off assert_false "off returns false" is_prompt_persist_enabled

# ----------------------------------------------------------------------
printf 'Test 4: invalid value defaults to on (preserves safety)\n'
OMC_PROMPT_PERSIST=garbage assert_true "garbage value treated as on" is_prompt_persist_enabled

# ----------------------------------------------------------------------
printf 'Test 5: prompt_persist=on (default) — router writes prompt to disk\n'
sid_on="t5-${RANDOM}"
prompt_on="ulw fix the bug in foo.py:42 with secret_token=abc123"
_run_router "${sid_on}" "${prompt_on}"

state_file="${_test_state_root}/${sid_on}/session_state.json"
recent_file="${_test_state_root}/${sid_on}/recent_prompts.jsonl"

# v1.40.x F-007: persist=on now applies omc_redact_secrets BEFORE
# writing to disk. The non-secret prefix is preserved; secret-shaped
# substrings are replaced with <redacted-...> tokens.
if [[ -f "${state_file}" ]]; then
  last_prompt="$(jq -r '.last_user_prompt // ""' "${state_file}")"
  if [[ "${last_prompt}" == *"ulw fix the bug in foo.py:42"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: persist=on dropped non-secret prefix (got: %q)\n' "${last_prompt}" >&2
    fail=$((fail + 1))
  fi
  if [[ "${last_prompt}" != *"abc123"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: persist=on leaked secret token abc123 (got: %q)\n' "${last_prompt}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  FAIL: state file not created\n' >&2
  fail=$((fail + 1))
fi

if [[ -f "${recent_file}" ]]; then
  recent_text="$(jq -r '.text // ""' "${recent_file}" | head -1)"
  if [[ "${recent_text}" == *"ulw fix the bug in foo.py:42"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: recent_prompts.jsonl dropped non-secret prefix (got: %q)\n' "${recent_text}" >&2
    fail=$((fail + 1))
  fi
  if [[ "${recent_text}" != *"abc123"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: recent_prompts.jsonl leaked secret token abc123 (got: %q)\n' "${recent_text}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  FAIL: recent_prompts.jsonl not created with persist=on\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 6: prompt_persist=off (env) — router skips recent_prompts.jsonl\n'
sid_off="t6-${RANDOM}"
prompt_off="ulw fix the bug in bar.py:99 with api_key=sk-secret"
_run_router "${sid_off}" "${prompt_off}" "OMC_PROMPT_PERSIST=off"

state_file="${_test_state_root}/${sid_off}/session_state.json"
recent_file="${_test_state_root}/${sid_off}/recent_prompts.jsonl"

if [[ -f "${state_file}" ]]; then
  last_prompt="$(jq -r '.last_user_prompt // ""' "${state_file}")"
  assert_eq "last_user_prompt empty with persist=off" "" "${last_prompt}"
  last_ts="$(jq -r '.last_user_prompt_ts // ""' "${state_file}")"
  if [[ -n "${last_ts}" && "${last_ts}" =~ ^[0-9]+$ ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: last_user_prompt_ts should still be a numeric epoch with persist=off (was %q)\n' "${last_ts}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  FAIL: state file not created (off path)\n' >&2
  fail=$((fail + 1))
fi

if [[ ! -f "${recent_file}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: recent_prompts.jsonl exists with persist=off\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 7: prompt_persist=off via project conf suppresses persistence\n'
sid_proj="t7-${RANDOM}"
prompt_proj="ulw fix the bug with conf-set persist=off"

_proj_dir="$(mktemp -d -t prompt-persist-conf-proj-XXXXXX)"
mkdir -p "${_proj_dir}/.claude"
printf 'prompt_persist=off\n' > "${_proj_dir}/.claude/oh-my-claude.conf"

# Run the router with cwd pointed at the temp project. The conf walk-up
# in load_conf reads .claude/oh-my-claude.conf via $PWD.
hook_json="$(jq -nc \
  --arg sid "${sid_proj}" \
  --arg p "${prompt_proj}" \
  --arg cwd "${_proj_dir}" \
  '{session_id:$sid, prompt:$p, cwd:$cwd}')"

(
  cd "${_proj_dir}"
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" >/dev/null 2>&1 || true
)

state_file="${_test_state_root}/${sid_proj}/session_state.json"
recent_file="${_test_state_root}/${sid_proj}/recent_prompts.jsonl"

if [[ -f "${state_file}" ]]; then
  last_prompt="$(jq -r '.last_user_prompt // ""' "${state_file}")"
  assert_eq "last_user_prompt empty via project conf" "" "${last_prompt}"
fi

if [[ ! -f "${recent_file}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: recent_prompts.jsonl exists with project conf persist=off\n' >&2
  fail=$((fail + 1))
fi

rm -rf "${_proj_dir}"

# ----------------------------------------------------------------------
printf 'Test 8: env var overrides project conf when both set\n'
sid_envwins="t8-${RANDOM}"
prompt_envwins="ulw env should win over project conf"

_proj_dir2="$(mktemp -d -t prompt-persist-envwins-XXXXXX)"
mkdir -p "${_proj_dir2}/.claude"
# Project says off; env says on; env should win.
printf 'prompt_persist=off\n' > "${_proj_dir2}/.claude/oh-my-claude.conf"

hook_json="$(jq -nc \
  --arg sid "${sid_envwins}" \
  --arg p "${prompt_envwins}" \
  --arg cwd "${_proj_dir2}" \
  '{session_id:$sid, prompt:$p, cwd:$cwd}')"

(
  cd "${_proj_dir2}"
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    OMC_PROMPT_PERSIST=on \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" >/dev/null 2>&1 || true
)

state_file="${_test_state_root}/${sid_envwins}/session_state.json"
recent_file="${_test_state_root}/${sid_envwins}/recent_prompts.jsonl"

if [[ -f "${state_file}" ]]; then
  last_prompt="$(jq -r '.last_user_prompt // ""' "${state_file}")"
  assert_eq "env=on wins over conf=off" "${prompt_envwins}" "${last_prompt}"
fi

if [[ -f "${recent_file}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: env=on should still write recent_prompts.jsonl over conf=off\n' >&2
  fail=$((fail + 1))
fi

rm -rf "${_proj_dir2}"

# ----------------------------------------------------------------------
printf 'Test 9: omc-config registry contains prompt_persist row\n'
omc_config_sh="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"
if grep -q "^prompt_persist|bool|on|memory|" "${omc_config_sh}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: prompt_persist row not found in omc-config.sh emit_known_flags\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 10: minimal preset opts out (privacy posture)\n'
# emit_preset minimal must include `prompt_persist=off` because the
# minimal preset is the privacy-first profile per CLAUDE.md.
if (
  source "${omc_config_sh}" >/dev/null 2>&1 || true
  emit_preset minimal 2>/dev/null | grep -q "^prompt_persist=off$"
); then
  pass=$((pass + 1))
else
  printf '  FAIL: minimal preset missing prompt_persist=off\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 11: maximum + balanced presets keep prompt_persist=on\n'
for profile in maximum balanced; do
  if (
    source "${omc_config_sh}" >/dev/null 2>&1 || true
    emit_preset "${profile}" 2>/dev/null | grep -q "^prompt_persist=on$"
  ); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s preset missing prompt_persist=on\n' "${profile}" >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
printf 'Test 12: propagation — stop-failure-handler writes empty last_user_prompt to resume_request.json when persist=off\n'
# Closes the v1.30.0 Wave 1 quality-reviewer finding: with prompt_persist=off,
# the producer (router) clears last_user_prompt in state to empty. Multiple
# downstream consumers (stop-failure-handler, pre-compact-snapshot) read
# from state to populate cross-session artifacts. This regression locks in
# that the producer's clear correctly propagates to resume_request.json
# (which survives state-TTL and travels cross-session). Without this test,
# a future change that cached last_user_prompt outside state could silently
# break the privacy contract.
sid_prop="t12-${RANDOM}"
prompt_prop="ulw fix bug with secret_data=very-private when persist=off"
_run_router "${sid_prop}" "${prompt_prop}" "OMC_PROMPT_PERSIST=off"

# Compose a StopFailure hook payload. stop-failure-handler reads
# `session_id`, `matcher`, `transcript_path`, `cwd` from input; it reads
# `last_user_prompt` from session_state.json that the router wrote.
stop_failure_json="$(jq -nc \
  --arg sid "${sid_prop}" \
  --arg matcher "rate_limit" \
  --arg event "StopFailure" \
  --arg cwd "${PWD}" \
  '{session_id:$sid, matcher:$matcher, hook_event_name:$event, cwd:$cwd, transcript_path:""}')"

HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  OMC_PROMPT_PERSIST=off \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/stop-failure-handler.sh" \
  <<<"${stop_failure_json}" >/dev/null 2>&1 \
  || true

artifact_file="${_test_state_root}/${sid_prop}/resume_request.json"
if [[ -f "${artifact_file}" ]]; then
  artifact_prompt="$(jq -r '.last_user_prompt // ""' "${artifact_file}")"
  assert_eq "resume_request.json::last_user_prompt empty when persist=off" "" "${artifact_prompt}"
else
  printf '  FAIL: stop-failure-handler did not produce resume_request.json (sid=%s)\n' "${sid_prop}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 13: propagation — stop-failure-handler keeps prompt verbatim when persist=on\n'
# Mirror of Test 12 — when persist=on (default), the artifact MUST carry
# the verbatim user prompt. Asserts the propagation does not silently
# strip in the on path.
sid_prop_on="t13-${RANDOM}"
prompt_prop_on="ulw add a regression test to keep prompt persistence working"
_run_router "${sid_prop_on}" "${prompt_prop_on}" "OMC_PROMPT_PERSIST=on"

stop_failure_json="$(jq -nc \
  --arg sid "${sid_prop_on}" \
  --arg matcher "rate_limit" \
  --arg event "StopFailure" \
  --arg cwd "${PWD}" \
  '{session_id:$sid, matcher:$matcher, hook_event_name:$event, cwd:$cwd, transcript_path:""}')"

HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  OMC_PROMPT_PERSIST=on \
  bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/stop-failure-handler.sh" \
  <<<"${stop_failure_json}" >/dev/null 2>&1 \
  || true

artifact_file="${_test_state_root}/${sid_prop_on}/resume_request.json"
if [[ -f "${artifact_file}" ]]; then
  artifact_prompt="$(jq -r '.last_user_prompt // ""' "${artifact_file}")"
  assert_eq "resume_request.json::last_user_prompt verbatim when persist=on" "${prompt_prop_on}" "${artifact_prompt}"
else
  printf '  FAIL: stop-failure-handler did not produce resume_request.json on persist=on path (sid=%s)\n' "${sid_prop_on}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
