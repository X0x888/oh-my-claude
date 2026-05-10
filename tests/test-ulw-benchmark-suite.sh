#!/usr/bin/env bash
# Canonical ULW behavior benchmark suite for the v1.33.0 consolidation
# work. These are not micro-tests for one helper; they are end-user
# scenario guards for the router's actual behavior:
#   - serious targeted execution
#   - broad council-style evaluation
#   - example-marker widening
#   - continuation after interruption/compact
#   - advisory-over-code handling
#   - UI/design routing
#   - directive-budget suppression in balanced mode
#   - maximum-budget parity on the same dense prompt
#
# This suite exists to catch the drift class the version audit surfaced:
# user-visible ULW behavior can change even when unit tests stay green.
# Every scenario asserts the traits that matter to a serious `/ulw`
# user: quality routing, automation posture, and prompt-tax control.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t ulw-benchmark-home-XXXXXX)"
_test_state_root="${_test_home}/state"
_test_project="${_test_home}/project"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}" "${_test_project}/src" "${_test_project}/tests"
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
    printf '  FAIL: %s\n    needle=%q\n    haystack(first 240)=%q\n' "${label}" "${needle}" "${haystack:0:240}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpected needle=%q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_ge() {
  local label="$1" floor="$2" actual="$3"
  if (( actual >= floor )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    floor=%d actual=%d\n' "${label}" "${floor}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

_cleanup_test() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup_test EXIT

_init_project_repo() {
  cat > "${_test_project}/src/app.ts" <<'EOF'
export function add(a: number, b: number): number {
  return a + b
}
EOF

  cat > "${_test_project}/tests/app.test.ts" <<'EOF'
import { add } from "../src/app"

test("add", () => {
  expect(add(1, 2)).toBe(3)
})
EOF

  (
    cd "${_test_project}"
    git init -q
    git config user.name "ULW Benchmark"
    git config user.email "ulw-benchmark@example.com"
    git add src/app.ts tests/app.test.ts
    git commit -qm "initial benchmark fixture"
  )
}

_run_router_json() {
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
    || true
}

_run_router_context() {
  local session_id="$1"
  local prompt_text="$2"
  shift 2
  _run_router_json "${session_id}" "${prompt_text}" "$@" \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

_gate_count() {
  local sid="$1" gate="$2" event="$3" directive="${4:-}"
  local f="${_test_state_root}/${sid}/gate_events.jsonl"
  [[ -f "${f}" ]] || { printf '0'; return; }
  if [[ -n "${directive}" ]]; then
    jq -c --arg g "${gate}" --arg e "${event}" --arg d "${directive}" \
      'select(.gate==$g and .event==$e and (.details.directive // "")==$d)' \
      "${f}" 2>/dev/null | wc -l | tr -d ' '
  else
    jq -c --arg g "${gate}" --arg e "${event}" \
      'select(.gate==$g and .event==$e)' \
      "${f}" 2>/dev/null | wc -l | tr -d ' '
  fi
}

_timing_names() {
  local sid="$1"
  local f="${_test_state_root}/${sid}/timing.jsonl"
  [[ -f "${f}" ]] || return 0
  jq -r 'select(.kind=="directive_emitted") | .name' "${f}" 2>/dev/null | sort -u || true
}

_seed_defect_patterns() {
  rm -f "${HOME}/.claude/quality-pack/defect-patterns.json"
  record_defect_pattern "integration" "resume flow skipped auth redirect after StopFailure"
  record_defect_pattern "missing_test" "statusline regression shipped without reset-window coverage"
  record_defect_pattern "docs" "release notes claimed telemetry that never surfaced"
}

_init_project_repo

_TARGETED_EXEC_PROMPT="ulw fix the off-by-one bug in src/app.ts and add regression coverage"
_COUNCIL_PROMPT="ulw evaluate this codebase and plan for improvements"
_EXEMPLIFY_PROMPT="ulw enhance the dashboard, for instance adding filter chips"
_ADVISORY_CODE_PROMPT="ulw what do you think about the current auth flow in this codebase and anything else to clean up?"
_UI_PROMPT="ulw redesign the dashboard settings page for better usability"
_DENSE_PROMPT="ulw design the auth strategy for a new dashboard in this codebase, for instance onboarding and recovery paths"

# ----------------------------------------------------------------------
printf 'Test 1: targeted execution stays in direct ULW execution posture\n'
ctx="$(_run_router_context "t1-${RANDOM}" "${_TARGETED_EXEC_PROMPT}")"
assert_contains "T1: execution opener present" "**Ultrawork mode active.**" "${ctx}"
assert_contains "T1: coding domain routing present" "Detected likely task domain: coding." "${ctx}"
assert_contains "T1: classification surfaced" "**Domain:** coding | **Intent:** execution" "${ctx}"
assert_not_contains "T1: no council evaluation on targeted execution" "COUNCIL EVALUATION DETECTED" "${ctx}"
assert_not_contains "T1: no advisory-over-code on direct execution" "ADVISORY OVER CODE" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 2: broad repo evaluation routes through council without collapsing into generic execution\n'
sid_2="t2-${RANDOM}"
ctx="$(_run_router_context "${sid_2}" "${_COUNCIL_PROMPT}")"
assert_contains "T2: council evaluation directive present" "COUNCIL EVALUATION DETECTED" "${ctx}"
assert_contains "T2: mixed-domain routing still surfaced" "Detected likely task domain: mixed." "${ctx}"
assert_contains "T2: project-surface broadening still present" "INTENT-BROADENING DIRECTIVE" "${ctx}"
assert_not_contains "T2: no advisory-over-code on execution-style council entry" "ADVISORY OVER CODE" "${ctx}"
risk_2="$(jq -r '.task_risk_tier // ""' "${_test_state_root}/${sid_2}/session_state.json")"
assert_eq "T2: broad repo eval classified high risk" "high" "${risk_2}"

# ----------------------------------------------------------------------
printf 'Test 2b: zero-steering policy injects compact strictness directive\n'
sid_2b="t2b-${RANDOM}"
ctx="$(_run_router_context "${sid_2b}" "${_COUNCIL_PROMPT}" OMC_QUALITY_POLICY=zero_steering)"
assert_contains "T2b: zero-steering directive present" "ZERO-STEERING POLICY" "${ctx}"
assert_contains "T2b: high-risk wording present" "high-risk autonomous shipping work" "${ctx}"
policy_2b="$(jq -r '.quality_policy // ""' "${_test_state_root}/${sid_2b}/session_state.json")"
assert_eq "T2b: quality policy persisted" "zero_steering" "${policy_2b}"

# ----------------------------------------------------------------------
printf 'Test 3: example-marker execution preserves widening + checklist discipline\n'
sid_3="t3-${RANDOM}"
ctx="$(_run_router_context "${sid_3}" "${_EXEMPLIFY_PROMPT}")"
assert_contains "T3: completeness directive present" "COMPLETENESS / COVERAGE QUERY DETECTED" "${ctx}"
assert_contains "T3: exemplifying sub-case present" "EXEMPLIFYING SCOPE DETECTED" "${ctx}"
assert_contains "T3: checklist workflow still present" "record-scope-checklist.sh init" "${ctx}"
fires_3="$(_gate_count "${sid_3}" "bias-defense" "directive_fired" "exemplifying")"
assert_eq "T3: exemplifying telemetry still lands" "1" "${fires_3}"

# ----------------------------------------------------------------------
printf 'Test 4: continuation prompt preserves prior objective and skips fresh-routing nudges\n'
sid_4="t4-${RANDOM}"
mkdir -p "${_test_state_root}/${sid_4}"
printf '{"current_objective":"finish the audit report","task_domain":"coding","workflow_mode":"ultrawork"}' \
  > "${_test_state_root}/${sid_4}/session_state.json"
ctx="$(_run_router_context "${sid_4}" "continue")"
assert_contains "T4: continuation opener present" "**Ultrawork continuation active.**" "${ctx}"
assert_contains "T4: preserved objective surfaced" "Preserved objective: finish the audit report" "${ctx}"
assert_not_contains "T4: no fresh ambiguous-scope nudge on continuation" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 5: advisory-over-code stays advisory but still forces real-code grounding\n'
ctx="$(_run_router_context "t5-${RANDOM}" "${_ADVISORY_CODE_PROMPT}")"
assert_contains "T5: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T5: advisory-over-code directive present" "ADVISORY OVER CODE" "${ctx}"
assert_not_contains "T5: no execution opener on advisory turn" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 6: UI prompt still routes through the design contract\n'
ctx="$(_run_router_context "t6-${RANDOM}" "${_UI_PROMPT}")"
assert_contains "T6: ui design contract present" "UI/design work detected — context-aware design routing engaged." "${ctx}"
assert_contains "T6: inline contract heading survives" "## Design Contract" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 7: balanced budget suppresses low-priority prompt tax, not core ULW routing\n'
_seed_defect_patterns
sid_7="t7-${RANDOM}"
ctx="$(_run_router_context "${sid_7}" "${_DENSE_PROMPT}" "OMC_PROMETHEUS_SUGGEST=on" "OMC_DIRECTIVE_BUDGET=balanced")"
assert_contains "T7: completeness survives balanced budget" "COMPLETENESS / COVERAGE QUERY DETECTED" "${ctx}"
assert_contains "T7: scope-interpretation directive survives balanced budget" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${ctx}"
assert_contains "T7: surface-broadening survives balanced budget" "INTENT-BROADENING DIRECTIVE" "${ctx}"
assert_contains "T7: divergent framing survives balanced budget" "DIVERGENT-FRAMING DIRECTIVE" "${ctx}"
assert_not_contains "T7: defect-watch is the trimmed low-priority layer" "Historical defect patterns from prior sessions" "${ctx}"
suppressed_7="$(_gate_count "${sid_7}" "directive-budget" "suppressed" "defect_watch")"
assert_ge "T7: balanced budget records at least one defect_watch suppression" 1 "${suppressed_7}"
names_7="$(_timing_names "${sid_7}")"
assert_not_contains "T7: suppressed directive does not hit timing rows" "defect_watch" "${names_7}"
fires_7_prom="$(_gate_count "${sid_7}" "bias-defense" "directive_fired" "prometheus-suggest")"
assert_eq "T7: selected bias-defense directive still records fired telemetry" "1" "${fires_7_prom}"

# ----------------------------------------------------------------------
printf 'Test 8: maximum budget preserves the full dense prompt shape\n'
_seed_defect_patterns
sid_8="t8-${RANDOM}"
ctx="$(_run_router_context "${sid_8}" "${_DENSE_PROMPT}" "OMC_PROMETHEUS_SUGGEST=on" "OMC_DIRECTIVE_BUDGET=maximum")"
assert_contains "T8: maximum keeps defect-watch" "Historical defect patterns from prior sessions" "${ctx}"
assert_contains "T8: maximum still keeps divergence" "DIVERGENT-FRAMING DIRECTIVE" "${ctx}"
suppressed_8="$(_gate_count "${sid_8}" "directive-budget" "suppressed")"
assert_eq "T8: maximum budget records zero suppressions on same prompt" "0" "${suppressed_8}"
names_8="$(_timing_names "${sid_8}")"
assert_contains "T8: defect_watch reaches timing rows under maximum" "defect_watch" "${names_8}"

printf '\nULW benchmark suite: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
