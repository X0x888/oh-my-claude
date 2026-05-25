#!/usr/bin/env bash
# Tests for the domain-routing specialist hints in
# prompt-intent-router.sh.
#
# The original regression net for this file was coding-only: it closed
# the "orphan engineering specialists" gap where the coding-domain hint
# named only reasoning helpers and left the implementers discoverable
# only through manual slash commands. The product claims broader
# professional coverage than coding, though, so this test now locks the
# full cross-domain routing contract: coding specialists remain present,
# and the writing / research / operations / mixed / general branches all
# carry the load-bearing guidance the README promises to non-coding
# professionals.
#
# Mirrors the sandbox setup of test-bias-defense-directives.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t specialist-routing-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

pass=0
fail=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack(first 400)=%q\n' "${label}" "${needle}" "${haystack:0:400}" >&2
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
  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${session_id}" \
    --arg p "${prompt_text}" \
    '{session_id:$sid, prompt:$p, cwd:env.PWD}')"
  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
    <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

# A coding-domain ULW prompt with explicit code-anchored signals so the
# router consistently selects the `coding` branch (not `mixed`) across
# project profiles. The classifier scores prompts by keyword density,
# so we use unambiguous terms ("fix the off-by-one bug", file path).
_CODING_PROMPT="ulw fix the off-by-one bug in src/payment/processor.ts line 42"

# ----------------------------------------------------------------------
printf 'Test 1: coding-domain hint enumerates engineering specialists\n'
out="$(_run_router "t1-${RANDOM}" "${_CODING_PROMPT}")"

assert_contains "domain hint present"            "Detected likely task domain: coding" "${out}"
assert_contains "names backend-api-developer"    "backend-api-developer"               "${out}"
assert_contains "names frontend-developer (v1.27.0 F-016)" "frontend-developer"        "${out}"
assert_contains "names devops-infrastructure"    "devops-infrastructure-engineer"      "${out}"
assert_contains "names test-automation"          "test-automation-engineer"            "${out}"
assert_contains "names fullstack-feature"        "fullstack-feature-builder"           "${out}"
assert_contains "names ios-ui-developer"         "ios-ui-developer"                    "${out}"
assert_contains "names ios-core-engineer"        "ios-core-engineer"                   "${out}"
assert_contains "names ios-deployment"           "ios-deployment-specialist"           "${out}"
assert_contains "names ios-ecosystem"            "ios-ecosystem-integrator"            "${out}"
assert_contains "names abstraction-critic"       "abstraction-critic"                  "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: existing reasoning specialists are still routed\n'
out="$(_run_router "t2-${RANDOM}" "${_CODING_PROMPT}")"

assert_contains "names prometheus"               "prometheus for interview-first"      "${out}"
assert_contains "names quality-planner"          "quality-planner"                     "${out}"
assert_contains "names quality-researcher"       "quality-researcher"                  "${out}"
assert_contains "names librarian"                "librarian"                           "${out}"
assert_contains "names metis"                    "metis"                               "${out}"
assert_contains "names oracle"                   "oracle"                              "${out}"

# ----------------------------------------------------------------------
printf 'Test 2b: planner/prometheus disambiguation guidance present (v1.27.0 F-017)\n'
out="$(_run_router "t2b-${RANDOM}" "${_CODING_PROMPT}")"
assert_contains "prometheus → quality-planner deferral guidance" \
  "Defer to quality-planner instead when the request is concrete enough" "${out}"
assert_contains "quality-planner → prometheus deferral guidance" \
  "Defer to prometheus instead when the request is broad" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: vague catch-all line is gone\n'
out="$(_run_router "t3-${RANDOM}" "${_CODING_PROMPT}")"

assert_not_contains "no generic catch-all" "the closest specialist engineering agent" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: writing-domain prompt routes through the writing specialist chain\n'
out="$(_run_router "t4-${RANDOM}" "ulw draft a quarterly business proposal")"

assert_contains "writing domain hint present" "Detected likely task domain: writing" "${out}"
assert_contains "writing names writing-architect" "writing-architect" "${out}"
assert_contains "writing names librarian factual support" "librarian for factual support" "${out}"
assert_contains "writing names draft-writer" "draft-writer" "${out}"
assert_contains "writing names editor-critic" "editor-critic" "${out}"
assert_contains "writing names no-invent-facts rule" "Do not invent facts, citations, or quotations" "${out}"

# Writing-domain hint is independent of the coding routing. Engineering
# specialist nudges should not bleed into other domains.
assert_not_contains "no backend leak in writing"  "backend-api-developer"          "${out}"
assert_not_contains "no devops leak in writing"   "devops-infrastructure-engineer" "${out}"
assert_not_contains "no test-auto leak in writing" "test-automation-engineer"      "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: research-domain prompt routes through the research specialist chain\n'
out="$(_run_router "t5-${RANDOM}" "ulw compare Redis vs Memcached and summarize tradeoffs")"

assert_contains "research domain hint present" "Detected likely task domain: research or analysis" "${out}"
assert_contains "research names librarian" "Use librarian for authoritative sources" "${out}"
assert_contains "research names briefing-analyst" "briefing-analyst to synthesize findings" "${out}"
assert_contains "research names metis" "metis to challenge weak conclusions" "${out}"
assert_contains "research names editor-critic" "editor-critic for prose-heavy deliverables" "${out}"
assert_contains "research names source-quality rule" "primary sources and official documentation rank highest" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: operations-domain prompt routes through the operations specialist chain\n'
out="$(_run_router "t6-${RANDOM}" "ulw create a project plan for the Q3 launch")"

assert_contains "operations domain hint present" "Detected likely task domain: operations or professional-assistant work" "${out}"
assert_contains "operations names chief-of-staff" "Use chief-of-staff to structure the deliverable" "${out}"
assert_contains "operations names checklist/plan structuring" "Detect deliverable type: if the task implies a checklist, plan, schedule, decision matrix, or action-item tracker" "${out}"
assert_contains "operations names owner deadline done-condition" "Every action item should have an owner" "${out}"
assert_contains "operations names draft-writer pairing" "pair that with draft-writer and editor-critic" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: mixed-domain prompt names both coding and non-coding coordination\n'
out="$(_run_router "t7-${RANDOM}" "ulw implement the login endpoint, research the accessibility tradeoffs, and write the rollout memo")"

assert_contains "mixed domain hint present" "Detected likely task domain: mixed" "${out}"
assert_contains "mixed names domain-identification rule" "First identify WHICH domains are actually in play" "${out}"
assert_contains "mixed names code/non-code split rule" "Split the work into coding and non-coding streams" "${out}"
assert_contains "mixed names engineering specialists" "use the engineering specialists for code work" "${out}"
assert_contains "mixed names non-coding specialists" "writing, research, or operations specialists" "${out}"
assert_contains "mixed names coordination rule" "Keep them coordinated" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: mixed code-plus-operations prompt preserves chief-of-staff discipline\n'
out="$(_run_router "t8-${RANDOM}" "ulw fix the deploy-health endpoint, add regression tests, and create a release plan plus cutover checklist with owners, deadlines, and rollback steps")"

assert_contains "mixed ops domain hint present" "Detected likely task domain: mixed" "${out}"
assert_contains "mixed ops names code/non-code split rule" "Split the work into coding and non-coding streams" "${out}"
assert_contains "mixed ops names chief-of-staff rule" "use chief-of-staff rather than leaving it as generic prose" "${out}"
assert_contains "mixed ops names checklist/runbook structuring" "if the output is a checklist, cutover plan, rollout schedule, action tracker, or runbook" "${out}"
assert_contains "mixed ops names owner/deadline/done-condition rule" "every action item should have an owner, a deadline, and a clear done-condition" "${out}"
assert_contains "mixed ops names synchronization rule" "Keep the operational artifact synchronized with the implementation and verification state" "${out}"

# ----------------------------------------------------------------------
printf 'Test 9: scholar-style mixed prompt names evidence-first then drafting chain\n'
out="$(_run_router "t9-${RANDOM}" "ulw research the literature on spaced repetition in graduate study and draft a short literature review with citations")"

assert_contains "scholar mixed domain hint present" "Detected likely task domain: mixed" "${out}"
assert_contains "scholar mixed names non-code-only rule" "If the mix is non-code only" "${out}"
assert_contains "scholar mixed names librarian" "gather evidence first with librarian" "${out}"
assert_contains "scholar mixed names briefing-analyst" "briefing-analyst as needed" "${out}"
assert_contains "scholar mixed names drafting chain" "writing-architect / draft-writer" "${out}"
assert_contains "scholar mixed names editor-critic" "finish with editor-critic" "${out}"
assert_contains "scholar mixed names evidence-first rule" "Evidence before synthesis, synthesis before polish" "${out}"
assert_not_contains "scholar mixed no engineering leak" "engineering specialists for code work" "${out}"

# ----------------------------------------------------------------------
printf 'Test 10: general-domain prompt names the classify-before-proceed contract\n'
out="$(_run_router "t10-${RANDOM}" "ulw help me with this")"

assert_contains "general domain hint present" "Detected likely task domain: general" "${out}"
assert_contains "general names classify-it-yourself rule" "classify it yourself before proceeding" "${out}"
assert_contains "general names deliverable question" "Ask: what is the deliverable?" "${out}"
assert_contains "general names coding fallback only when repo involved" "If the task involves a repository, treat it as coding" "${out}"
assert_contains "general names no-code-default rule" "Do not default to code-oriented repo exploration unless the task truly requires it" "${out}"

# ----------------------------------------------------------------------
printf '\n'
printf 'specialist-routing: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
