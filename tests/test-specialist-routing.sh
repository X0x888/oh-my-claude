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
  local run_cwd="${3:-${PWD}}"
  local model_tier="${4:-}"
  (
    cd "${run_cwd}"
    local hook_json
    hook_json="$(jq -nc \
      --arg sid "${session_id}" \
      --arg p "${prompt_text}" \
      '{session_id:$sid, prompt:$p, cwd:env.PWD}')"
    if [[ -n "${model_tier}" ]]; then
      export OMC_MODEL_TIER="${model_tier}"
    fi
    HOME="${_test_home}" \
      STATE_ROOT="${_test_state_root}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      <<<"${hook_json}" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
      || true
  )
}

_seed_completed_council_handoff() {
  local session_id="$1" state_file now
  _run_router "${session_id}" "ulw evaluate my project" >/dev/null
  state_file="${_test_state_root}/${session_id}/session_state.json"
  now="$(date +%s)"
  jq --arg now "${now}" \
    '.council_assessment_ready="1"
     | .council_assessment_ts=$now
     | .council_assessment_prompt_revision=1' \
    "${state_file}" >"${state_file}.tmp" \
    && mv "${state_file}.tmp" "${state_file}"
}

# Two-turn Council handoff: routing alone is not completion. The completion
# producer is tested in test-council-coverage.sh; here we seed its state shape
# and verify that only the immediately adjacent approval restores Phase 8.
out_council_assess="$(_run_router "t-council-followup" "ulw evaluate my project")"
assert_contains "Council assessment route detected" "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_council_assess}"
assert_not_contains "assessment-only route does not claim implementation" "Step 7's presentation is NOT the finish line" "${out_council_assess}"
_council_state="${_test_state_root}/t-council-followup/session_state.json"
if [[ "$(jq -r '.council_assessment_ready // empty' "${_council_state}")" == "" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: routing an unfinished Council armed the handoff\n' >&2
  fail=$((fail + 1))
fi

out_council_recommended="$(_run_router "t-council-recommended-fixes" "ulw evaluate my project and implement the recommended fixes")"
assert_contains "recommended-fixes request stays Council" "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_council_recommended}"
assert_contains "recommended-fixes request enters Phase 8" "Step 7's presentation is NOT the finish line" "${out_council_recommended}"
if [[ "$(jq -r '.council_phase8_prompt_revision // empty' \
    "${_test_state_root}/t-council-recommended-fixes/session_state.json")" == "1" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: same-turn Phase 8 was not stamped with prompt revision 1\n' >&2
  fail=$((fail + 1))
fi

out_council_rubric="$(_run_router "t-council-rubric-only" "ulw evaluate my project and apply a rigorous security checklist")"
assert_contains "rubric-only request stays Council assessment" "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_council_rubric}"
assert_not_contains "rubric-only apply is not workspace mutation" "Step 7's presentation is NOT the finish line" "${out_council_rubric}"

out_council_no_changes="$(_run_router "t-council-global-optout" "ulw evaluate my project and implement fixes, but do not make any changes; report the plan")"
assert_contains "global no-change request stays Council assessment" "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_council_no_changes}"
assert_not_contains "global no-change clause suppresses Phase 8" "Step 7's presentation is NOT the finish line" "${out_council_no_changes}"

# A renamed checkout is recognized from independent repository markers, while
# an unrelated directory named `oh-my-claude` cannot activate self-audit mode
# from its basename alone.
_structural_repo="${_test_home}/renamed-harness-checkout"
mkdir -p \
  "${_structural_repo}/config" \
  "${_structural_repo}/bundle/dot-claude/skills/council"
ln -s "${REPO_ROOT}/install.sh" "${_structural_repo}/install.sh"
ln -s "${REPO_ROOT}/verify.sh" "${_structural_repo}/verify.sh"
ln -s "${REPO_ROOT}/config/settings.patch.json" "${_structural_repo}/config/settings.patch.json"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md" \
  "${_structural_repo}/bundle/dot-claude/skills/council/SKILL.md"

for _self_audit_prompt in \
  "self-audit the harness" \
  "audit the harness state-io contracts" \
  "review implicit contracts in the harness" \
  "run the Bug B self-audit"; do
  out_self_audit="$(_run_router "t-self-audit-${RANDOM}" "ulw ${_self_audit_prompt}" "${_structural_repo}")"
  assert_contains "structural self-audit routes Council: ${_self_audit_prompt}" \
    "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_self_audit}"
  assert_contains "structural self-audit activates harness prior: ${_self_audit_prompt}" \
    "Self-audit prior active" "${out_self_audit}"
done

_basename_only_repo="${_test_home}/oh-my-claude"
mkdir -p "${_basename_only_repo}"
out_false_self_audit="$(_run_router "t-self-audit-false-positive" \
  "ulw self-audit the harness" "${_basename_only_repo}")"
assert_not_contains "basename-only directory cannot trigger Council self-audit" \
  "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_false_self_audit}"

# Economy normally pins Agent calls to Sonnet, but an explicit Council deep
# request has a narrow precedence exception for selected Sonnet-backed Council
# specialists. Inherit-tier deliberators must remain unpinned.
out_deep_economy="$(_run_router "t-council-deep-economy" \
  "ulw evaluate my project --deep" "${PWD}" "economy")"
assert_contains "deep+economy Council route detected" \
  "ADAPTIVE COUNCIL EVALUATION DETECTED" "${out_deep_economy}"
assert_contains "deep+economy selected Council exception is explicit" \
  'selected Sonnet-backed Council specialists MAY instead receive `model: "opus"`' "${out_deep_economy}"
assert_contains "deep+economy keeps non-Council calls on Sonnet" \
  'All other economy-tier Agent calls stay on `model: "sonnet"`' "${out_deep_economy}"
assert_contains "deep+economy preserves inherit omission" \
  'for `model: inherit` deliberators participating in this deep Council, OMIT the model parameter' "${out_deep_economy}"
assert_not_contains "deep+economy removes contradictory every-call mandate" \
  'On EVERY `Agent()` call' "${out_deep_economy}"

_now="$(date +%s)"
jq --arg now "${_now}" \
  '.council_assessment_ready="1"
   | .council_assessment_ts=$now
   | .council_assessment_prompt_revision=1' \
  "${_council_state}" >"${_council_state}.tmp" \
  && mv "${_council_state}.tmp" "${_council_state}"
out_council_followup="$(_run_router "t-council-followup" "ulw implement all recommendations")"
assert_contains "Council approval turn restores Phase 8" "COUNCIL PHASE-8 CONTINUATION" "${out_council_followup}"
assert_contains "Council approval turn preserves exhaustive scope" "EXHAUSTIVE AUTHORIZATION matched" "${out_council_followup}"
if [[ "$(jq -r '.council_phase8_prompt_revision // empty' "${_council_state}")" == "2" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: follow-up Phase 8 was not stamped with current prompt revision 2\n' >&2
  fail=$((fail + 1))
fi

# Bounded and terse immediate approvals still consume the completed handoff as
# a valid Phase-8 transition. Top-N and severity subsets must not be promoted
# to exhaustive authorization merely because the prior assessment was broad.
_seed_completed_council_handoff "t-council-top-n"
out_council_top_n="$(_run_router "t-council-top-n" "ulw implement the top 3 findings")"
assert_contains "top-N approval restores Phase 8" "COUNCIL PHASE-8 CONTINUATION" "${out_council_top_n}"
assert_not_contains "top-N approval remains bounded" "EXHAUSTIVE AUTHORIZATION matched" "${out_council_top_n}"

_seed_completed_council_handoff "t-council-critical"
out_council_critical="$(_run_router "t-council-critical" "ulw implement only the critical findings")"
assert_contains "critical-only approval restores Phase 8" "COUNCIL PHASE-8 CONTINUATION" "${out_council_critical}"
assert_not_contains "critical-only approval remains bounded" "EXHAUSTIVE AUTHORIZATION matched" "${out_council_critical}"

_seed_completed_council_handoff "t-council-fix-all"
out_council_fix_all="$(_run_router "t-council-fix-all" "ulw fix all")"
assert_contains "terse fix-all approval restores Phase 8" "COUNCIL PHASE-8 CONTINUATION" "${out_council_fix_all}"
if [[ "$(jq -r '.council_phase8_active // empty' "${_test_state_root}/t-council-fix-all/session_state.json")" == "1" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: valid fix-all handoff was discarded instead of activating Phase 8\n' >&2
  fail=$((fail + 1))
fi

# An intervening prompt consumes a completed handoff. Later domain work with
# words like gap/recommendation/wave must remain an ordinary focused task.
_run_router "t-council-expiry" "ulw evaluate my project" >/dev/null
_expiry_state="${_test_state_root}/t-council-expiry/session_state.json"
jq --arg now "${_now}" \
  '.council_assessment_ready="1"
   | .council_assessment_ts=$now
   | .council_assessment_prompt_revision=1' \
  "${_expiry_state}" >"${_expiry_state}.tmp" \
  && mv "${_expiry_state}.tmp" "${_expiry_state}"
out_intervening="$(_run_router "t-council-expiry" "ulw explain the deployment setup")"
assert_not_contains "unrelated adjacent prompt does not enter Phase 8" "COUNCIL PHASE-8 CONTINUATION" "${out_intervening}"
out_late_gap="$(_run_router "t-council-expiry" "ulw fix the performance gap in the parser")"
assert_not_contains "non-adjacent gap wording cannot revive Council" "COUNCIL PHASE-8 CONTINUATION" "${out_late_gap}"

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
printf 'Test 5b: regulated advisory prompt adds source-boundary discipline\n'
out="$(_run_router "t5b-${RANDOM}" "ulw what does this contract clause imply for vendor liability in the UK?")"

assert_contains "regulated advisory research domain present" "Detected likely task domain: research or analysis" "${out}"
assert_contains "regulated advisory directive present" "Regulated or high-stakes professional analysis detected." "${out}"
assert_contains "regulated advisory names governing source" "Identify the governing source" "${out}"
assert_contains "regulated advisory names jurisdiction/effective-date rule" "effective-date window before drawing conclusions" "${out}"
assert_contains "regulated advisory names no-invent-authorities rule" "Do not invent authorities, legal/clinical obligations, or policy requirements." "${out}"
assert_contains "regulated advisory names librarian" "Use \`librarian\` for current primary sources" "${out}"
assert_contains "regulated advisory names briefing-analyst" "\`briefing-analyst\` to synthesize implications" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: operations-domain prompt routes through the operations specialist chain\n'
out="$(_run_router "t6-${RANDOM}" "ulw create a project plan for the Q3 launch")"

assert_contains "operations domain hint present" "Detected likely task domain: operations or professional-assistant work" "${out}"
assert_contains "operations names chief-of-staff" "Use chief-of-staff to structure the deliverable" "${out}"
assert_contains "operations names checklist/plan structuring" "Detect deliverable type: if the task implies a checklist, plan, schedule, decision matrix, or action-item tracker" "${out}"
assert_contains "operations names owner deadline done-condition" "Every action item should have an owner" "${out}"
assert_contains "operations names draft-writer pairing" "pair that with draft-writer and editor-critic" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6b: workbook prompt preserves native spreadsheet deliverable contract\n'
out="$(_run_router "t6b-${RANDOM}" "ulw build a budget workbook with forecast formulas and variance tabs")"

assert_contains "workbook domain hint present" "Detected likely task domain: operations or professional-assistant work" "${out}"
assert_contains "workbook quantitative directive present" "Quantitative or tabular analysis detected." "${out}"
assert_contains "workbook artifact directive present" "Native spreadsheet/workbook deliverable detected." "${out}"
assert_contains "workbook names direct artifact rule" "The workbook itself is the deliverable" "${out}"
assert_contains "workbook names native-file rule" "deliver the spreadsheet/workbook artifact" "${out}"
assert_contains "workbook names explicit fallback" "sheet-by-sheet schema, formula map, assumptions table, and import-ready tab data" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6c: presentation prompt preserves native deck deliverable contract\n'
out="$(_run_router "t6c-${RANDOM}" "ulw turn this quarterly update into a board presentation deck")"

assert_contains "deck domain hint present" "Detected likely task domain: operations or professional-assistant work" "${out}"
assert_contains "deck artifact directive present" "Native presentation/deck deliverable detected." "${out}"
assert_contains "deck names direct artifact rule" "The slide deck itself is the deliverable" "${out}"
assert_contains "deck names native-file rule" "deliver the presentation artifact" "${out}"
assert_contains "deck names explicit fallback" "slide-by-slide outline with title, message, evidence, and presenter notes" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6d: docx prompt preserves native document deliverable contract\n'
out="$(_run_router "t6d-${RANDOM}" "ulw draft a formal policy document in a .docx artifact")"

assert_contains "docx writing domain hint present" "Detected likely task domain: writing" "${out}"
assert_contains "docx artifact directive present" "Native document deliverable detected." "${out}"
assert_contains "docx names direct artifact rule" "The .docx / Word-style document itself is the deliverable" "${out}"
assert_contains "docx names native-file rule" "deliver the document artifact" "${out}"
assert_contains "docx names explicit fallback" "section-by-section draft with headings, table stubs, and formatting notes" "${out}"

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
printf 'Test 7b: regulated memo prompt preserves mixed evidence-plus-drafting workflow\n'
out="$(_run_router "t7b-${RANDOM}" "ulw draft a HIPAA compliance remediation memo for the patient-data workflow")"

assert_contains "regulated memo mixed domain present" "Detected likely task domain: mixed" "${out}"
assert_contains "regulated memo names non-code-only mixed rule" "If the mix is non-code only" "${out}"
assert_contains "regulated memo names drafting chain" "writing-architect / draft-writer" "${out}"
assert_contains "regulated memo directive present" "Regulated or high-stakes professional analysis detected." "${out}"
assert_contains "regulated memo names governing source" "Identify the governing source" "${out}"
assert_contains "regulated memo names sign-off caveat carry-through" "carry the caveats, sign-off needs, and unresolved scope assumptions into the final artifact" "${out}"
assert_not_contains "regulated memo no engineering leak" "engineering specialists for code work" "${out}"

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
