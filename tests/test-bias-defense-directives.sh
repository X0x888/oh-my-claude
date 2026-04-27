#!/usr/bin/env bash
# Tests for the v1.19.0 bias-defense directive injections in
# prompt-intent-router.sh — prometheus-suggest and intent-verify.
#
# Drives the router end-to-end with synthetic prompts and parses the
# additionalContext field of the emitted JSON to confirm:
#   - default-OFF behavior: no directive injected
#   - flag-ON + matching prompt: directive present
#   - flag-ON + non-matching prompt: no directive
#   - both-ON suppression: prometheus wins, intent-verify suppressed
#   - non-execution branches (continuation, advisory) skip the directives
#
# Mirrors the structure of test-bias-defense-classifier.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Sandbox HOME and STATE_ROOT before any sourcing. The router under
# test sources `${HOME}/.claude/skills/autowork/scripts/common.sh` from
# the installed harness; we redirect HOME to a temporary fixture that
# symlinks .claude/{skills,quality-pack} to the dev tree so the router
# picks up the in-development helpers (is_product_shaped_request,
# is_ambiguous_execution_request) instead of whatever is installed.
_test_home="$(mktemp -d -t bias-defense-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
# Symlink only the read-only subdirs (scripts, memory) so cross-session
# telemetry files (agent-metrics.json, gate-skips.jsonl) write into the
# per-test home rather than leaking into the dev tree.
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

# Drive prompt-intent-router.sh and return the additionalContext string
# (joined newlines). HOME is forwarded so the router's
# `${HOME}/.claude/...` source paths resolve to the dev tree.
_run_router() {
  local session_id="$1"
  local prompt_text="$2"
  shift 2
  # Remaining args are KEY=VALUE pairs to set in the env (e.g.
  # OMC_PROMETHEUS_SUGGEST=on).
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

# A "ulw-active" prompt: the router needs the workflow_mode flag set OR
# is_ulw_trigger to match. Most test prompts include the literal `ulw`
# token to trigger the ULW branch on the first turn, since the test does
# not pre-warm workflow_mode.
_PROD_PROMPT="ulw build me a habit tracker app"
_AMBIG_PROMPT="ulw implement the feature flag"
_TARGETED_PROMPT="ulw fix the off-by-one bug in lib/parse.ts:42"
_LONG_PROMPT="ulw $(printf 'I need you to implement the user authentication system with email and password login, password reset via email tokens, session management using JWT, role-based access control, and full test coverage.')"
_ADVISORY_PROMPT="ulw what do you think about the current dashboard?"

# ----------------------------------------------------------------------
printf 'Test 1: default-OFF — no directive emitted\n'
out="$(_run_router "t1-${RANDOM}" "${_PROD_PROMPT}")"
assert_not_contains "no PROMETHEUS hint default" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "no INTENT VERIFY default"   "INTENT VERIFICATION"            "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: prometheus-suggest fires on product+ambiguous\n'
out="$(_run_router "t2-${RANDOM}" "${_PROD_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on")"
assert_contains "PROMETHEUS hint present" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_contains "names /prometheus"       "/prometheus"                     "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: prometheus-suggest does NOT fire on targeted code change\n'
out="$(_run_router "t3-${RANDOM}" "${_TARGETED_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on")"
assert_not_contains "no PROMETHEUS on targeted" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: prometheus-suggest does NOT fire on long detailed brief\n'
out="$(_run_router "t4-${RANDOM}" "${_LONG_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on")"
assert_not_contains "no PROMETHEUS on long brief" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: intent-verify fires on short ambiguous execution prompt\n'
out="$(_run_router "t5-${RANDOM}" "${_AMBIG_PROMPT}" \
  "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_contains "INTENT VERIFY present" "INTENT VERIFICATION" "${out}"
assert_contains "asks to restate goal"  "restate the user's goal" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: intent-verify does NOT fire when prometheus-suggest already fired\n'
out="$(_run_router "t6-${RANDOM}" "${_PROD_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_contains   "PROMETHEUS fires"      "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "INTENT VERIFY suppressed" "INTENT VERIFICATION"        "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: intent-verify does NOT fire on targeted prompt\n'
out="$(_run_router "t7-${RANDOM}" "${_TARGETED_PROMPT}" \
  "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_not_contains "no INTENT VERIFY on targeted" "INTENT VERIFICATION" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: directives skipped on advisory branch\n'
# Advisory prompts route through the `advisory_prompt=1` branch — the
# bias-defense block is in the `else` branch (execution-only), so the
# advisory message wins and neither directive fires.
out="$(_run_router "t8-${RANDOM}" "${_ADVISORY_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_contains    "advisory branch fires"      "advisory or decision support" "${out}"
assert_not_contains "no PROMETHEUS on advisory" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "no INTENT VERIFY on advisory" "INTENT VERIFICATION"          "${out}"

# ----------------------------------------------------------------------
printf 'Test 9a: directives skipped on session-management prompt\n'
# Session-management requires both an SM keyword (fresh session, this
# session, context limit, etc.) AND an advisory framing (should/would/?).
# "Should I start a fresh session for this?" hits both gates and routes
# through the session_management branch, skipping the bias-defense
# block in the execution `else`.
out="$(_run_router "t9a-${RANDOM}" "should I start a fresh session for this?" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_not_contains "no PROMETHEUS on session-mgmt"   "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "no INTENT VERIFY on session-mgmt" "INTENT VERIFICATION"            "${out}"

# ----------------------------------------------------------------------
printf 'Test 9b: directives skipped on checkpoint prompt\n'
# Explicit checkpoint requests are routed through the checkpoint branch
# and skip the execution `else` entirely.
out="$(_run_router "t9b-${RANDOM}" "ulw checkpoint here please" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_not_contains "no PROMETHEUS on checkpoint"   "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "no INTENT VERIFY on checkpoint" "INTENT VERIFICATION"            "${out}"

# ----------------------------------------------------------------------
printf 'Test 9: directives skipped on continuation prompt\n'
# A continuation prompt re-uses the prior objective; the bias-defense
# block is in the fresh-execution `else` branch, so neither fires.
# Pre-seed an objective so is_continuation_request has something to
# carry over.
sid_cont="t9-${RANDOM}"
mkdir -p "${_test_state_root}/${sid_cont}"
printf '{"current_objective":"prior task","task_domain":"coding","workflow_mode":"ultrawork"}' \
  > "${_test_state_root}/${sid_cont}/session_state.json"
out="$(_run_router "${sid_cont}" "continue" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on")"
assert_not_contains "no PROMETHEUS on continuation"   "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_not_contains "no INTENT VERIFY on continuation" "INTENT VERIFICATION"            "${out}"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
