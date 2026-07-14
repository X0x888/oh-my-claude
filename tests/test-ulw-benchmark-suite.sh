#!/usr/bin/env bash
# Canonical ULW behavior benchmark suite for the v1.33.0 consolidation
# work. These are not micro-tests for one helper; they are end-user
# scenario guards for the router's actual behavior:
#   - serious targeted execution
#   - broad council-style evaluation
#   - example-marker widening
#   - continuation after interruption/compact
#   - session-management preservation
#   - checkpoint/pause preservation
#   - advisory-over-code handling
#   - non-code advisory handling (research / writing / operations)
#   - quantitative / spreadsheet-style analysis handling
#   - UI/design routing
#   - writing / scholarly drafting
#   - research / source-quality synthesis
#   - mixed code + operations coordination
#   - operations / professional-assistant structuring
#   - native artifact delivery contracts (spreadsheet / deck / document)
#   - general-domain fallback classification
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
_ADVISORY_RESEARCH_PROMPT="ulw what are the tradeoffs between spaced repetition and active recall for graduate study?"
_ADVISORY_WRITING_PROMPT="ulw what structure should this grant proposal use?"
_ADVISORY_OPERATIONS_PROMPT="ulw what is the best way to structure this launch checklist?"
_ADVISORY_DATA_PROMPT="ulw what do these quarterly revenue, churn, and acquisition cost trends suggest about the product?"
_ADVISORY_REGULATED_PROMPT="ulw what does this contract clause imply for vendor liability in the UK?"
_UI_PROMPT="ulw redesign the dashboard settings page for better usability"
_WRITING_PROMPT="ulw write a concise abstract and introduction for a paper on distributed systems"
_RESEARCH_PROMPT="ulw research the evidence for spaced repetition in graduate study and produce a decision brief"
_QUANT_MIXED_PROMPT="ulw analyze the spreadsheet of quarterly revenue, churn, and acquisition cost trends and draft a KPI decision memo"
_REGULATED_MIXED_PROMPT="ulw draft a HIPAA compliance remediation memo for the patient-data workflow"
_SCHOLAR_MIXED_PROMPT="ulw research the literature on spaced repetition in graduate study and draft a short literature review with citations"
_MIXED_OPERATIONS_PROMPT="ulw fix the deploy-health endpoint, add regression tests, and create a release plan plus cutover checklist with owners, deadlines, and rollback steps"
_OPERATIONS_PROMPT="ulw turn this fellowship application timeline into an execution checklist with owners and deadlines"
_SPREADSHEET_ARTIFACT_PROMPT="ulw build a budget workbook with forecast formulas and variance tabs"
_PRESENTATION_ARTIFACT_PROMPT="ulw turn this quarterly update into a board presentation deck"
_DOCUMENT_ARTIFACT_PROMPT="ulw draft a formal policy document in a .docx artifact"
_GENERAL_PROMPT="ulw help me with this"
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
assert_contains "T2: coverage map precedes selection" "Build a COVERAGE MAP before selecting agents" "${ctx}"
assert_contains "T2: full installed/custom roster is considered" "FULL AVAILABLE AGENT ROSTER" "${ctx}"
assert_contains "T2: primary team is normally 1-4" "normally 1-4 specialists" "${ctx}"
assert_contains "T2: one specialist is valid" "ONE valid for a narrow specialist question" "${ctx}"
assert_contains "T2: include and skip rationale is required" "include reason, plus plausible skipped agent/family → why not applicable" "${ctx}"
assert_contains "T2: gap-fill is optional and bounded" "ONE gap-fill round of 0-2 best-fit specialists" "${ctx}"
assert_contains "T2: verification is independent and competence-matched" "best INDEPENDENT verifier" "${ctx}"
assert_contains "T2: verification names competence matching" "Match competence to claim" "${ctx}"
assert_not_contains "T2: no fixed 3-6 role-lens panel" "Select 3-6 relevant role-lenses" "${ctx}"
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
printf 'Test 4b: session-management prompt preserves the active objective and stays non-execution\n'
sid_4b="t4b-${RANDOM}"
mkdir -p "${_test_state_root}/${sid_4b}"
printf '{"current_objective":"finish the audit report","task_domain":"coding","workflow_mode":"ultrawork"}' \
  > "${_test_state_root}/${sid_4b}/session_state.json"
ctx="$(_run_router_context "${sid_4b}" "should I start a new session or continue here? context is at 60%")"
assert_contains "T4b: session-management opener present" "session-management advice, not execution" "${ctx}"
assert_contains "T4b: classification line guidance present" "**Domain:** coding | **Intent:** session-management" "${ctx}"
assert_contains "T4b: preserved objective surfaced" "Preserved active objective in the background: finish the audit report" "${ctx}"
assert_contains "T4b: preserved domain surfaced" "Underlying active task domain: coding" "${ctx}"
assert_not_contains "T4b: no execution opener on session-management" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 4c: checkpoint prompt preserves the active objective and avoids full-completion pressure\n'
sid_4c="t4c-${RANDOM}"
mkdir -p "${_test_state_root}/${sid_4c}"
printf '{"current_objective":"finish the audit report","task_domain":"coding","workflow_mode":"ultrawork"}' \
  > "${_test_state_root}/${sid_4c}/session_state.json"
ctx="$(_run_router_context "${sid_4c}" "checkpoint")"
assert_contains "T4c: checkpoint opener present" "checkpoint or pause request" "${ctx}"
assert_contains "T4c: checkpoint classification guidance present" "**Domain:** coding | **Intent:** checkpoint" "${ctx}"
assert_contains "T4c: preserved objective surfaced" "Preserved active objective in the background: finish the audit report" "${ctx}"
assert_contains "T4c: stop-cleanly directive present" "stop cleanly without forcing full completion in this turn" "${ctx}"
assert_not_contains "T4c: no execution opener on checkpoint" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 5: advisory-over-code stays advisory but still forces real-code grounding\n'
ctx="$(_run_router_context "t5-${RANDOM}" "${_ADVISORY_CODE_PROMPT}")"
assert_contains "T5: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T5: advisory-over-code directive present" "ADVISORY OVER CODE" "${ctx}"
assert_not_contains "T5: no execution opener on advisory turn" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 6: research advisory stays advisory while preserving research guidance\n'
ctx="$(_run_router_context "t6-${RANDOM}" "${_ADVISORY_RESEARCH_PROMPT}")"
assert_contains "T6: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T6: research domain surfaced" "Detected likely task domain: research or analysis." "${ctx}"
assert_contains "T6: librarian present" "Use librarian for authoritative sources" "${ctx}"
assert_contains "T6: briefing-analyst present" "briefing-analyst to synthesize findings" "${ctx}"
assert_not_contains "T6: no advisory-over-code on non-code advisory" "ADVISORY OVER CODE" "${ctx}"
assert_not_contains "T6: no execution opener on research advisory" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 7: writing advisory stays advisory while preserving writing guidance\n'
ctx="$(_run_router_context "t7-${RANDOM}" "${_ADVISORY_WRITING_PROMPT}")"
assert_contains "T7: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T7: writing domain surfaced" "Detected likely task domain: writing." "${ctx}"
assert_contains "T7: writing-architect present" "writing-architect" "${ctx}"
assert_contains "T7: no-invent-facts rule present" "Do not invent facts, citations, or quotations" "${ctx}"
assert_not_contains "T7: no execution opener on writing advisory" "**Ultrawork mode active.**" "${ctx}"
assert_not_contains "T7: no coding-specialist leak" "backend-api-developer" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 8: operations advisory stays advisory while preserving operations guidance\n'
ctx="$(_run_router_context "t8-${RANDOM}" "${_ADVISORY_OPERATIONS_PROMPT}")"
assert_contains "T8: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T8: operations domain surfaced" "Detected likely task domain: operations or professional-assistant work." "${ctx}"
assert_contains "T8: chief-of-staff present" "Use chief-of-staff to structure the deliverable" "${ctx}"
assert_contains "T8: owner/deadline rule present" "Every action item should have an owner" "${ctx}"
assert_not_contains "T8: no execution opener on operations advisory" "**Ultrawork mode active.**" "${ctx}"
assert_not_contains "T8: no coding-specialist leak" "frontend-developer" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 9: quantitative advisory stays advisory while preserving data-analysis discipline\n'
ctx="$(_run_router_context "t9-${RANDOM}" "${_ADVISORY_DATA_PROMPT}")"
assert_contains "T9: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T9: research domain surfaced" "Detected likely task domain: research or analysis." "${ctx}"
assert_contains "T9: quantitative directive present" "Quantitative or tabular analysis detected." "${ctx}"
assert_contains "T9: data-lens surfaced" "dispatch \`data-lens\`" "${ctx}"
assert_contains "T9: structured output surfaced" "include a compact table, metric summary, or scenario matrix" "${ctx}"
assert_not_contains "T9: no execution opener on quantitative advisory" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 9b: regulated advisory stays advisory while preserving authority-boundary discipline\n'
ctx="$(_run_router_context "t9b-${RANDOM}" "${_ADVISORY_REGULATED_PROMPT}")"
assert_contains "T9b: advisory opener present" "advisory or decision support, not direct execution" "${ctx}"
assert_contains "T9b: research domain surfaced" "Detected likely task domain: research or analysis." "${ctx}"
assert_contains "T9b: regulated directive present" "Regulated or high-stakes professional analysis detected." "${ctx}"
assert_contains "T9b: governing-source rule surfaced" "Identify the governing source" "${ctx}"
assert_contains "T9b: jurisdiction rule surfaced" "relevant jurisdiction or operating context" "${ctx}"
assert_contains "T9b: no-invent-authorities rule surfaced" "Do not invent authorities, legal/clinical obligations, or policy requirements." "${ctx}"
assert_contains "T9b: librarian surfaced" "Use \`librarian\` for current primary sources" "${ctx}"
assert_not_contains "T9b: no execution opener on regulated advisory" "**Ultrawork mode active.**" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 10: UI prompt still routes through the design contract\n'
ctx="$(_run_router_context "t9-${RANDOM}" "${_UI_PROMPT}")"
assert_contains "T10: ui design contract present" "UI/design work detected — context-aware design routing engaged." "${ctx}"
assert_contains "T10: inline contract heading survives" "## Design Contract" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 11: scholarly writing prompt preserves the writing specialist chain\n'
ctx="$(_run_router_context "t10-${RANDOM}" "${_WRITING_PROMPT}")"
assert_contains "T11: writing domain surfaced" "Detected likely task domain: writing." "${ctx}"
assert_contains "T11: formal-document hint survives" "formal (paper, report, proposal)" "${ctx}"
assert_contains "T11: writing-architect present" "writing-architect" "${ctx}"
assert_contains "T11: librarian support present" "librarian for factual support" "${ctx}"
assert_contains "T11: no-invent-facts rule present" "Do not invent facts, citations, or quotations" "${ctx}"
assert_not_contains "T11: no coding-specialist leak" "backend-api-developer" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 12: research prompt preserves source-quality and synthesis routing\n'
ctx="$(_run_router_context "t11-${RANDOM}" "${_RESEARCH_PROMPT}")"
assert_contains "T12: research domain surfaced" "Detected likely task domain: research or analysis." "${ctx}"
assert_contains "T12: librarian present" "Use librarian for authoritative sources" "${ctx}"
assert_contains "T12: briefing-analyst present" "briefing-analyst to synthesize findings" "${ctx}"
assert_contains "T12: metis present" "metis to challenge weak conclusions" "${ctx}"
assert_contains "T12: peer-reviewed ranking present" "peer-reviewed publications next" "${ctx}"
assert_not_contains "T12: no coding execution leak" "backend-api-developer" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 13: quantitative mixed prompt preserves data-analysis plus drafting workflow\n'
ctx="$(_run_router_context "t12-${RANDOM}" "${_QUANT_MIXED_PROMPT}")"
assert_contains "T13: mixed domain surfaced" "Detected likely task domain: mixed." "${ctx}"
assert_contains "T13: non-code-only mixed rule surfaced" "If the mix is non-code only" "${ctx}"
assert_contains "T13: drafting chain surfaced" "writing-architect / draft-writer" "${ctx}"
assert_contains "T13: quantitative directive present" "Quantitative or tabular analysis detected." "${ctx}"
assert_contains "T13: data-lens surfaced" "dispatch \`data-lens\`" "${ctx}"
assert_contains "T13: structured output surfaced" "include a compact table, metric summary, or scenario matrix" "${ctx}"
assert_contains "T13: synthesis surfaced" "Use \`briefing-analyst\` to synthesize the numbers into a recommendation." "${ctx}"
assert_not_contains "T13: no engineering leak in quantitative mixed path" "engineering specialists for code work" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 13b: regulated mixed prompt preserves evidence-first plus remediation drafting workflow\n'
ctx="$(_run_router_context "t13b-${RANDOM}" "${_REGULATED_MIXED_PROMPT}")"
assert_contains "T13b: mixed domain surfaced" "Detected likely task domain: mixed." "${ctx}"
assert_contains "T13b: non-code-only mixed rule surfaced" "If the mix is non-code only" "${ctx}"
assert_contains "T13b: drafting chain surfaced" "writing-architect / draft-writer" "${ctx}"
assert_contains "T13b: regulated directive present" "Regulated or high-stakes professional analysis detected." "${ctx}"
assert_contains "T13b: governing-source rule surfaced" "Identify the governing source" "${ctx}"
assert_contains "T13b: caveat carry-through surfaced" "carry the caveats, sign-off needs, and unresolved scope assumptions into the final artifact" "${ctx}"
assert_not_contains "T13b: no engineering leak in regulated mixed path" "engineering specialists for code work" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 14: scholar-style mixed prompt preserves evidence-first then drafting workflow\n'
ctx="$(_run_router_context "t12-${RANDOM}" "${_SCHOLAR_MIXED_PROMPT}")"
assert_contains "T14: mixed domain surfaced" "Detected likely task domain: mixed." "${ctx}"
assert_contains "T14: non-code-only rule surfaced" "If the mix is non-code only" "${ctx}"
assert_contains "T14: librarian-first rule surfaced" "gather evidence first with librarian" "${ctx}"
assert_contains "T14: briefing-analyst surfaced" "briefing-analyst as needed" "${ctx}"
assert_contains "T14: drafting chain surfaced" "writing-architect / draft-writer" "${ctx}"
assert_contains "T14: evidence-before-synthesis surfaced" "Evidence before synthesis, synthesis before polish." "${ctx}"
assert_not_contains "T14: no engineering leak in scholar mixed path" "engineering specialists for code work" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 15: mixed code-plus-operations prompt preserves chief-of-staff discipline inside mixed routing\n'
ctx="$(_run_router_context "t13-${RANDOM}" "${_MIXED_OPERATIONS_PROMPT}")"
assert_contains "T15: mixed domain surfaced" "Detected likely task domain: mixed." "${ctx}"
assert_contains "T15: code/non-code split surfaced" "Split the work into coding and non-coding streams" "${ctx}"
assert_contains "T15: chief-of-staff rule surfaced" "use chief-of-staff rather than leaving it as generic prose" "${ctx}"
assert_contains "T15: checklist/runbook structuring surfaced" "if the output is a checklist, cutover plan, rollout schedule, action tracker, or runbook" "${ctx}"
assert_contains "T15: owner/deadline/done-condition surfaced" "every action item should have an owner, a deadline, and a clear done-condition" "${ctx}"
assert_contains "T15: synchronization rule surfaced" "Keep the operational artifact synchronized with the implementation and verification state" "${ctx}"
assert_not_contains "T15: no non-code-only mixed rule leak" "If the mix is non-code only" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 16: operations prompt preserves professional-assistant structuring\n'
ctx="$(_run_router_context "t14-${RANDOM}" "${_OPERATIONS_PROMPT}")"
assert_contains "T16: operations domain surfaced" "Detected likely task domain: operations or professional-assistant work." "${ctx}"
assert_contains "T16: chief-of-staff present" "Use chief-of-staff to structure the deliverable" "${ctx}"
assert_contains "T16: checklist structuring present" "checklist, plan, schedule, decision matrix, or action-item tracker" "${ctx}"
assert_contains "T16: owner/deadline rule present" "Every action item should have an owner" "${ctx}"
assert_contains "T16: draft-writer pairing present" "pair that with draft-writer and editor-critic" "${ctx}"
assert_not_contains "T16: no coding execution leak" "frontend-developer" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 16b: spreadsheet artifact prompt preserves workbook-delivery contract\n'
ctx="$(_run_router_context "t14b-${RANDOM}" "${_SPREADSHEET_ARTIFACT_PROMPT}")"
assert_contains "T16b: execution opener present" "**Ultrawork mode active.**" "${ctx}"
assert_contains "T16b: operations domain surfaced" "Detected likely task domain: operations or professional-assistant work." "${ctx}"
assert_contains "T16b: quantitative directive present" "Quantitative or tabular analysis detected." "${ctx}"
assert_contains "T16b: workbook directive present" "Native spreadsheet/workbook deliverable detected." "${ctx}"
assert_contains "T16b: workbook direct artifact rule surfaced" "The workbook itself is the deliverable" "${ctx}"
assert_contains "T16b: workbook fallback surfaced" "sheet-by-sheet schema, formula map, assumptions table, and import-ready tab data" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 16c: presentation artifact prompt preserves deck-delivery contract\n'
ctx="$(_run_router_context "t14c-${RANDOM}" "${_PRESENTATION_ARTIFACT_PROMPT}")"
assert_contains "T16c: execution opener present" "**Ultrawork mode active.**" "${ctx}"
assert_contains "T16c: operations domain surfaced" "Detected likely task domain: operations or professional-assistant work." "${ctx}"
assert_contains "T16c: deck directive present" "Native presentation/deck deliverable detected." "${ctx}"
assert_contains "T16c: deck direct artifact rule surfaced" "The slide deck itself is the deliverable" "${ctx}"
assert_contains "T16c: deck fallback surfaced" "slide-by-slide outline with title, message, evidence, and presenter notes" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 16d: document artifact prompt preserves docx-delivery contract\n'
ctx="$(_run_router_context "t14d-${RANDOM}" "${_DOCUMENT_ARTIFACT_PROMPT}")"
assert_contains "T16d: execution opener present" "**Ultrawork mode active.**" "${ctx}"
assert_contains "T16d: writing domain surfaced" "Detected likely task domain: writing." "${ctx}"
assert_contains "T16d: document directive present" "Native document deliverable detected." "${ctx}"
assert_contains "T16d: document direct artifact rule surfaced" "The .docx / Word-style document itself is the deliverable" "${ctx}"
assert_contains "T16d: document fallback surfaced" "section-by-section draft with headings, table stubs, and formatting notes" "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 17: general-domain fallback stays explicit and non-code-default\n'
ctx="$(_run_router_context "t15-${RANDOM}" "${_GENERAL_PROMPT}")"
assert_contains "T17: execution opener present" "**Ultrawork mode active.**" "${ctx}"
assert_contains "T17: general domain surfaced" "**Domain:** general | **Intent:** execution" "${ctx}"
assert_contains "T17: general fallback rule surfaced" "Detected likely task domain: general." "${ctx}"
assert_contains "T17: classify-it-yourself rule surfaced" "classify it yourself before proceeding" "${ctx}"
assert_contains "T17: deliverable question surfaced" "what is the deliverable?" "${ctx}"
assert_contains "T17: repo-only coding fallback surfaced" "If the task involves a repository, treat it as coding." "${ctx}"
assert_contains "T17: no-code-default rule surfaced" "Do not default to code-oriented repo exploration unless the task truly requires it." "${ctx}"
assert_not_contains "T17: no specific domain leak" "Detected likely task domain: coding." "${ctx}"

# ----------------------------------------------------------------------
printf 'Test 18: balanced budget suppresses low-priority prompt tax, not core ULW routing\n'
_seed_defect_patterns
sid_16="t16-${RANDOM}"
ctx="$(_run_router_context "${sid_16}" "${_DENSE_PROMPT}" "OMC_PROMETHEUS_SUGGEST=on" "OMC_DIRECTIVE_BUDGET=balanced")"
assert_contains "T18: completeness survives balanced budget" "COMPLETENESS / COVERAGE QUERY DETECTED" "${ctx}"
assert_contains "T18: scope-interpretation directive survives balanced budget" "AMBIGUOUS PRODUCT-SHAPED PROMPT" "${ctx}"
assert_contains "T18: surface-broadening survives balanced budget" "INTENT-BROADENING DIRECTIVE" "${ctx}"
assert_contains "T18: divergent framing survives balanced budget" "DIVERGENT-FRAMING DIRECTIVE" "${ctx}"
assert_not_contains "T18: defect-watch is the trimmed low-priority layer" "Historical defect patterns from prior sessions" "${ctx}"
suppressed_16="$(_gate_count "${sid_16}" "directive-budget" "suppressed" "defect_watch")"
assert_ge "T18: balanced budget records at least one defect_watch suppression" 1 "${suppressed_16}"
names_16="$(_timing_names "${sid_16}")"
assert_not_contains "T18: suppressed directive does not hit timing rows" "defect_watch" "${names_16}"
fires_16_prom="$(_gate_count "${sid_16}" "bias-defense" "directive_fired" "prometheus-suggest")"
assert_eq "T18: selected bias-defense directive still records fired telemetry" "1" "${fires_16_prom}"

# ----------------------------------------------------------------------
printf 'Test 19: maximum budget preserves the full dense prompt shape\n'
_seed_defect_patterns
sid_17="t17-${RANDOM}"
ctx="$(_run_router_context "${sid_17}" "${_DENSE_PROMPT}" "OMC_PROMETHEUS_SUGGEST=on" "OMC_DIRECTIVE_BUDGET=maximum")"
assert_contains "T19: maximum keeps defect-watch" "Historical defect patterns from prior sessions" "${ctx}"
assert_contains "T19: maximum still keeps divergence" "DIVERGENT-FRAMING DIRECTIVE" "${ctx}"
suppressed_17="$(_gate_count "${sid_17}" "directive-budget" "suppressed")"
assert_eq "T19: maximum budget records zero suppressions on same prompt" "0" "${suppressed_17}"
names_17="$(_timing_names "${sid_17}")"
assert_contains "T19: defect_watch reaches timing rows under maximum" "defect_watch" "${names_17}"

printf '\nULW benchmark suite: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
