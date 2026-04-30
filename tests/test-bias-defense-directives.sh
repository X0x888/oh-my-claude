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
_test_project="${_test_home}/project"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
mkdir -p "${_test_project}"
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
# Test 10 (v1.23.0): EXEMPLIFYING SCOPE DETECTED widening directive
#
# Symmetric to prometheus-suggest / intent-verify but defends against
# the OPPOSITE bias (under-commitment / under-interpretation).
# Default ON — emits when an execution prompt contains example markers.
printf 'Test 10: exemplifying-directive default-ON fires on example markers\n'
_EXEMPLIFY_PROMPT="ulw enhance the dashboard, for instance adding filter chips"
out="$(_run_router "t10-${RANDOM}" "${_EXEMPLIFY_PROMPT}")"
assert_contains "EXEMPLIFYING directive present (default-ON)" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"
assert_contains "directive names class-treatment" \
  "Treat the example as ONE item" "${out}"
assert_contains "directive cites core.md" \
  "Excellence is not gold-plating" "${out}"

# ----------------------------------------------------------------------
printf 'Test 11: exemplifying-directive opt-out via OMC_EXEMPLIFYING_DIRECTIVE=off\n'
out="$(_run_router "t11-${RANDOM}" "${_EXEMPLIFY_PROMPT}" \
  "OMC_EXEMPLIFYING_DIRECTIVE=off")"
assert_not_contains "directive suppressed when off" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"

# ----------------------------------------------------------------------
printf 'Test 12: exemplifying-directive does NOT fire on prompt without markers\n'
out="$(_run_router "t12-${RANDOM}" "ulw fix the auth bug in lib/login.ts:42")"
assert_not_contains "no directive without markers" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"

# ----------------------------------------------------------------------
printf 'Test 13: exemplifying-directive fires INDEPENDENTLY of narrowing directives\n'
# Per the v1.23.0 design: narrowing (prometheus-suggest, intent-verify)
# and widening (exemplifying-directive) are orthogonal axes. A
# product-shaped prompt that ALSO contains example markers can
# legitimately receive both directives.
_DUAL_PROMPT="ulw build me a habit tracker app, for instance with streak counters"
out="$(_run_router "t13-${RANDOM}" "${_DUAL_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on")"
assert_contains "PROMETHEUS hint fires" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${out}"
assert_contains "EXEMPLIFYING fires alongside PROMETHEUS" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"

# ----------------------------------------------------------------------
printf 'Test 14: exemplifying-directive skipped on advisory prompt\n'
# Advisory branch is the early-return path; bias-defense block is
# inside the fresh-execution `else`. An advisory prompt with example
# markers should NOT receive the directive.
out="$(_run_router "t14-${RANDOM}" "ulw what do you think about icons such as lucide?")"
assert_not_contains "no EXEMPLIFYING on advisory" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"

# ----------------------------------------------------------------------
printf 'Test 15: user verbatim — "/ulw enhance the statusline, for instance ..."\n'
# The exact shape of the user's offending prompt that motivated this
# directive. Locks the regression so the failure mode the prompt
# captured cannot return without breaking this assertion.
_USER_VERBATIM="ulw can the status line be further enhanced for better ux? For instance, adding the information when will the limits be reset. Implement and then commit as needed."
out="$(_run_router "t15-${RANDOM}" "${_USER_VERBATIM}")"
assert_contains "user verbatim triggers directive" \
  "EXEMPLIFYING SCOPE DETECTED" "${out}"
assert_contains "directive includes worked example" \
  "reset countdown" "${out}"

# ----------------------------------------------------------------------
# Tests 16-18: end-to-end coverage that the router actually deposits a
# `record_gate_event "bias-defense" "directive_fired" directive=<name>`
# row into <session>/gate_events.jsonl when each of the three directives
# fires. Closes F-005 from the v1.23.x follow-up wave: prior tests only
# asserted the directive TEXT in additionalContext, never that the
# telemetry row /ulw-report depends on actually lands. If the
# record_gate_event call site silently regresses (typo in directive
# name, helper-rename without callsite update), the directive text
# would still appear but /ulw-report's "Bias-defense directives fired"
# section would render an empty placeholder — undetectable without
# this E2E assertion.

# Helper: read directive_fired rows from the session's gate_events.jsonl
# for a given directive name. Returns count.
_count_directive_fires() {
  local sid="$1" directive="$2"
  local f="${_test_state_root}/${sid}/gate_events.jsonl"
  [[ -f "${f}" ]] || { printf '0'; return; }
  jq -c --arg d "${directive}" \
    'select(.gate=="bias-defense" and .event=="directive_fired" and .details.directive==$d)' \
    "${f}" 2>/dev/null | wc -l | tr -d ' '
}

printf 'Test 16: exemplifying-directive E2E — gate_events row lands\n'
sid_16="t16-${RANDOM}"
_run_router "${sid_16}" "${_EXEMPLIFY_PROMPT}" >/dev/null
fires_16="$(_count_directive_fires "${sid_16}" "exemplifying")"
assert_contains "T16: exactly 1 exemplifying directive_fired row" "1" "${fires_16}"

printf 'Test 17: prometheus-suggest E2E — gate_events row lands when flag on\n'
sid_17="t17-${RANDOM}"
_run_router "${sid_17}" "${_PROD_PROMPT}" "OMC_PROMETHEUS_SUGGEST=on" >/dev/null
fires_17="$(_count_directive_fires "${sid_17}" "prometheus-suggest")"
assert_contains "T17: exactly 1 prometheus-suggest directive_fired row" "1" "${fires_17}"

printf 'Test 18: intent-verify E2E — gate_events row lands when flag on\n'
sid_18="t18-${RANDOM}"
# Use ambiguous-but-not-product prompt so prometheus does NOT win and
# suppress intent-verify (the router's _bias_directive_emitted gate).
_run_router "${sid_18}" "${_AMBIG_PROMPT}" "OMC_INTENT_VERIFY_DIRECTIVE=on" >/dev/null
fires_18="$(_count_directive_fires "${sid_18}" "intent-verify")"
assert_contains "T18: exactly 1 intent-verify directive_fired row" "1" "${fires_18}"

# ----------------------------------------------------------------------
printf 'Test 19: no directive_fired row emitted when no directive fires\n'
# Targeted prompt with no example markers, no product-shaped wording,
# no ambiguity — router takes the bias-defense block but emits nothing.
sid_19="t19-${RANDOM}"
_run_router "${sid_19}" "${_TARGETED_PROMPT}" \
  "OMC_PROMETHEUS_SUGGEST=on" "OMC_INTENT_VERIFY_DIRECTIVE=on" >/dev/null
fires_19_pro="$(_count_directive_fires "${sid_19}" "prometheus-suggest")"
fires_19_iv="$(_count_directive_fires "${sid_19}" "intent-verify")"
fires_19_ex="$(_count_directive_fires "${sid_19}" "exemplifying")"
assert_contains "T19: zero prometheus rows on targeted prompt" "0" "${fires_19_pro}"
assert_contains "T19: zero intent-verify rows on targeted prompt" "0" "${fires_19_iv}"
assert_contains "T19: zero exemplifying rows on targeted prompt" "0" "${fires_19_ex}"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
