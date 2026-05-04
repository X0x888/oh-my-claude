#!/usr/bin/env bash
# Tests for the v1.32.0 divergent-framing directive injection in
# prompt-intent-router.sh.
#
# Drives the router end-to-end with synthetic prompts and parses the
# additionalContext / gate_events.jsonl artifacts to confirm:
#   - default-ON behavior: directive injected on paradigm-ambiguous prompts
#   - opt-out via OMC_DIVERGENCE_DIRECTIVE=off
#   - intent gating: skipped on session_management / checkpoint;
#     fires on advisory + execution + continuation (mirrors the v1.26.0
#     completeness-directive pattern — paradigm enumeration is useful on
#     advisory turns too, e.g., "what's the best way to model auth?")
#   - axis independence: co-fires with other bias-defense directives
#   - telemetry row shape: directive=divergence lands in gate_events.jsonl
#   - directive contract: key contract phrases survive future edits
#
# Mirrors the structure of test-bias-defense-directives.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t divergence-directive-home-XXXXXX)"
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

# Helper: count directive_fired rows for a given directive name.
_count_directive_fires() {
  local sid="$1" directive="$2"
  local f="${_test_state_root}/${sid}/gate_events.jsonl"
  [[ -f "${f}" ]] || { printf '0'; return; }
  jq -c --arg d "${directive}" \
    'select(.gate=="bias-defense" and .event=="directive_fired" and .details.directive==$d)' \
    "${f}" 2>/dev/null | wc -l | tr -d ' '
}

# Canonical paradigm-ambiguous prompts. Each names a paradigm-shape
# decision the router must detect. Picked so the prompts route to
# different intents (execution / advisory / continuation) — verifies
# the directive's gate fires on each branch except session_management
# and checkpoint.
#
# Execution-intent (imperative + paradigm-decision verb + abstract
# noun): _PARADIGM_DESIGN_PROMPT.
# Advisory-intent (question framing): _PARADIGM_HOW_PROMPT,
# _PARADIGM_BEST_PROMPT.
_PARADIGM_DESIGN_PROMPT="ulw design the auth strategy for a multi-tenant rollout"
_PARADIGM_HOW_PROMPT="ulw how should we handle rate limit retries in the resume watchdog"
_PARADIGM_VS_PROMPT="ulw websockets vs polling for the live status feed"
_PARADIGM_BEST_PROMPT="ulw what is the best way to model auth state across the wizard"
_PARADIGM_BACKTICK_VS_PROMPT='ulw should I use `Redux` or `Context` for the global state'

# Negative prompts — the directive must NOT fire on these.
_BUGFIX_PROMPT="ulw fix the off-by-one bug in lib/parse.ts:42"
_SCOPED_PROMPT="ulw rename the function getUser to fetchUser in src/api/users.ts"
_CONCRETE_PROMPT="ulw add a debug log to bundle/dot-claude/skills/autowork/scripts/common.sh"

# ----------------------------------------------------------------------
printf 'Test 1: default-ON — directive fires on execution-intent paradigm prompt\n'
out="$(_run_router "t1-${RANDOM}" "${_PARADIGM_DESIGN_PROMPT}")"
assert_contains "T1: directive present" "DIVERGENT-FRAMING DIRECTIVE" "${out}"
assert_contains "T1: names /diverge as escalation" "/diverge" "${out}"
assert_contains "T1: requires inline enumeration" "INLINE in your opener" "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: default-ON fires on X vs Y prompt\n'
out="$(_run_router "t2-${RANDOM}" "${_PARADIGM_VS_PROMPT}")"
assert_contains "T2: directive present on X vs Y" "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: default-ON fires on advisory-intent "best way" prompt\n'
# Question framing routes to advisory; the new gate (post-v1.32.0)
# fires the directive on advisory too — paradigm enumeration is the
# correct response to "what's the best way to model auth?".
out="$(_run_router "t3-${RANDOM}" "${_PARADIGM_BEST_PROMPT}")"
assert_contains "T3: directive present on advisory paradigm question" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: default-ON fires on advisory-intent "how should we" prompt\n'
out="$(_run_router "t4-${RANDOM}" "${_PARADIGM_HOW_PROMPT}")"
assert_contains "T4: directive present on advisory how-should-we" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: backtick-fenced X vs Y still fires (comparison overrides code-anchor disqualifier)\n'
out="$(_run_router "t5-${RANDOM}" "${_PARADIGM_BACKTICK_VS_PROMPT}")"
assert_contains "T5: directive present on backticked X-vs-Y" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: opt-out via OMC_DIVERGENCE_DIRECTIVE=off suppresses the directive\n'
out="$(_run_router "t6-${RANDOM}" "${_PARADIGM_DESIGN_PROMPT}" \
  "OMC_DIVERGENCE_DIRECTIVE=off")"
assert_not_contains "T6: directive suppressed when off" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: bug-fix prompt does NOT fire (bug-fix vocabulary disqualifier)\n'
out="$(_run_router "t7-${RANDOM}" "${_BUGFIX_PROMPT}")"
assert_not_contains "T7: no directive on bug-fix" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: scoped rename with code anchor does NOT fire\n'
out="$(_run_router "t8-${RANDOM}" "${_SCOPED_PROMPT}")"
assert_not_contains "T8: no directive on scoped rename" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 9: concrete edit with file path does NOT fire\n'
out="$(_run_router "t9-${RANDOM}" "${_CONCRETE_PROMPT}")"
assert_not_contains "T9: no directive on concrete edit" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 10: non-paradigm advisory prompt does NOT fire (classifier rejects)\n'
out="$(_run_router "t10-${RANDOM}" "what do you think about the current dashboard?")"
assert_not_contains "T10: no directive on non-paradigm advisory" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 11: directive skipped on session-management prompt\n'
# Session-management framing ("should I start a fresh session") routes
# through the session_management branch which the directive's gate
# excludes — meta-workflow prompts should not receive paradigm framing.
out="$(_run_router "t11-${RANDOM}" "should I start a fresh session for this?" \
  "OMC_DIVERGENCE_DIRECTIVE=on")"
assert_not_contains "T11: no directive on session-mgmt" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 12: directive skipped on checkpoint prompt\n'
out="$(_run_router "t12-${RANDOM}" "ulw checkpoint here please")"
assert_not_contains "T12: no directive on checkpoint" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 13: directive fires INDEPENDENTLY of intent-broadening (orthogonal axes, execution-intent prompt)\n'
# A paradigm-ambiguous EXECUTION prompt under intent-broadening=on must
# receive BOTH directives — paradigm enumeration (divergence) and
# surface reconciliation (intent-broadening) target different failure
# axes. Note: intent-broadening skips on advisory, so this test must
# use an execution-intent prompt to exercise the co-fire path.
out="$(_run_router "t13-${RANDOM}" "${_PARADIGM_DESIGN_PROMPT}" \
  "OMC_INTENT_BROADENING=on")"
assert_contains "T13: divergence fires" "DIVERGENT-FRAMING DIRECTIVE" "${out}"
assert_contains "T13: intent-broadening also fires" "INTENT-BROADENING DIRECTIVE" "${out}"

# Reciprocal axis-independence (post-quality-reviewer F-4): turning
# intent-broadening OFF must not suppress divergence. Locks the
# orthogonal-axes property from both directions — divergence's gate
# does not transitively depend on intent-broadening's flag.
printf 'Test 13b: divergence still fires when intent-broadening is OFF\n'
out="$(_run_router "t13b-${RANDOM}" "${_PARADIGM_DESIGN_PROMPT}" \
  "OMC_INTENT_BROADENING=off")"
assert_contains "T13b: divergence fires (intent-broadening=off)" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"
assert_not_contains "T13b: intent-broadening suppressed" \
  "INTENT-BROADENING DIRECTIVE" "${out}"

# ----------------------------------------------------------------------
printf 'Test 14: directive fires INDEPENDENTLY of completeness directive\n'
# A paradigm-ambiguous prompt that ALSO contains completeness vocabulary
# legitimately receives both — different failure axes.
_DUAL_PROMPT="ulw how should we handle every consumer of the rate-limit API"
out="$(_run_router "t14-${RANDOM}" "${_DUAL_PROMPT}")"
assert_contains "T14: divergence fires" "DIVERGENT-FRAMING DIRECTIVE" "${out}"
assert_contains "T14: completeness also fires" "COMPLETENESS / COVERAGE QUERY DETECTED" "${out}"

# ----------------------------------------------------------------------
printf 'Test 15: telemetry row lands — directive=divergence in gate_events.jsonl\n'
sid_15="t15-${RANDOM}"
_run_router "${sid_15}" "${_PARADIGM_DESIGN_PROMPT}" >/dev/null
fires_15="$(_count_directive_fires "${sid_15}" "divergence")"
assert_contains "T15: exactly 1 divergence directive_fired row" "1" "${fires_15}"

# ----------------------------------------------------------------------
printf 'Test 16: telemetry — opt-out emits zero rows\n'
sid_16="t16-${RANDOM}"
_run_router "${sid_16}" "${_PARADIGM_DESIGN_PROMPT}" \
  "OMC_DIVERGENCE_DIRECTIVE=off" >/dev/null
fires_16="$(_count_directive_fires "${sid_16}" "divergence")"
assert_contains "T16: zero rows when off" "0" "${fires_16}"

# ----------------------------------------------------------------------
printf 'Test 17: telemetry — bug-fix prompt emits zero rows\n'
sid_17="t17-${RANDOM}"
_run_router "${sid_17}" "${_BUGFIX_PROMPT}" >/dev/null
fires_17="$(_count_directive_fires "${sid_17}" "divergence")"
assert_contains "T17: zero rows on bug-fix" "0" "${fires_17}"

# ----------------------------------------------------------------------
printf 'Test 18: directive contract — key phrases survive\n'
# Lock the contract: the directive must teach inline enumeration with
# 2-3 framings, EASY/HARD affordances, redirect-if clause, and explicit
# /diverge escalation. If a future edit strips one of these, this test
# breaks before the regression ships.
out="$(_run_router "t18-${RANDOM}" "${_PARADIGM_DESIGN_PROMPT}")"
assert_contains "T18: 2-3 framings" "2-3 alternative framings" "${out}"
assert_contains "T18: EASY affordance" "EASY" "${out}"
assert_contains "T18: HARD affordance" "HARD" "${out}"
assert_contains "T18: redirect-if clause" "redirect if" "${out}"
assert_contains "T18: pick-with-reason" "Pick one with a one-line reason" "${out}"
assert_contains "T18: /diverge escalation" "Escalate to" "${out}"
assert_contains "T18: inline-not-subagent bias" "inline lateral thinking" "${out}"

# ----------------------------------------------------------------------
printf 'Test 18b: env=on overrides project conf=off (post-quality-reviewer F-5)\n'
# Symmetric to T6 (env=off suppresses default-on). T18b verifies the
# env-precedence semantics in the OPPOSITE direction: a project-level
# divergence_directive=off conf is overridden by OMC_DIVERGENCE_DIRECTIVE=on
# at the env layer. Locks the documented conf-precedence contract
# (env > project > user) at the router boundary, not just the parser.
sid_18b="t18b-${RANDOM}"
mkdir -p "${_test_project}/.claude"
cat > "${_test_project}/.claude/oh-my-claude.conf" <<EOF
divergence_directive=off
EOF
out="$(_run_router "${sid_18b}" "${_PARADIGM_DESIGN_PROMPT}" \
  "OMC_DIVERGENCE_DIRECTIVE=on")"
assert_contains "T18b: env=on overrides conf=off" \
  "DIVERGENT-FRAMING DIRECTIVE" "${out}"
fires_18b="$(_count_directive_fires "${sid_18b}" "divergence")"
assert_contains "T18b: telemetry row lands when env overrides" "1" "${fires_18b}"
rm -f "${_test_project}/.claude/oh-my-claude.conf"

# ----------------------------------------------------------------------
printf 'Test 19: telemetry — advisory paradigm prompt also emits the row\n'
# Mirror of T15 but on the advisory branch. The new v1.32.0 gate fires
# on advisory; the row must land regardless of intent so /ulw-report
# accounting reflects all fires.
sid_19="t19-${RANDOM}"
_run_router "${sid_19}" "${_PARADIGM_BEST_PROMPT}" >/dev/null
fires_19="$(_count_directive_fires "${sid_19}" "divergence")"
assert_contains "T19: exactly 1 row on advisory paradigm prompt" "1" "${fires_19}"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
