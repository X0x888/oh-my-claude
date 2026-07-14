#!/usr/bin/env bash
# test-realwork-producer.sh — v1.39.0 W3 regression net for
# evals/realwork/result-from-session.sh.
#
# Bridges the gap closed by W3: scoring layer (run.sh score) consumed
# a result JSON no script produced. With this producer, ANY ULW
# session's state can be synthesized into a scorable result. The eval
# becomes falsifiable.
#
# Pinned behaviors:
#   1. Numeric extraction — tokens (chars/4 from directive_emitted),
#      tool_calls (count of "start" events), elapsed_seconds
#      (last_activity - session_start).
#   2. Per-outcome detector booleans match the actual session state.
#   3. End-to-end pipe into run.sh score — a perfect synthetic
#      session yields pass=true on at least one scenario.
#   4. CLI contract — --scenario required, --session selects, missing
#      state errors cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCER="${REPO_ROOT}/evals/realwork/result-from-session.sh"
SCORER="${REPO_ROOT}/evals/realwork/run.sh"

TEST_HOME="$(mktemp -d -t realwork-producer-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_STATE_ROOT}"

pass=0
fail=0

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

new_session() {
  local sid="$1"
  local sdir="${TEST_STATE_ROOT}/${sid}"
  mkdir -p "${sdir}"
  printf '%s' "$2" >"${sdir}/session_state.json"
  printf '%s\n' "${sdir}"
}

run_producer() {
  local sid="$1" scenario="$2"
  bash "${PRODUCER}" --scenario "${scenario}" --session "${sid}" --state-root "${TEST_STATE_ROOT}" 2>&1
}

# ---------------------------------------------------------------
# Part A: numeric extraction
# ---------------------------------------------------------------
sdir_a="$(new_session "sess-A" '{
  "session_start_ts": "100",
  "last_edit_ts": "250",
  "last_review_ts": "240",
  "subagent_dispatch_count": "2"
}')"
cat >"${sdir_a}/timing.jsonl" <<'JSONL'
{"kind":"prompt_start","ts":100,"prompt_seq":1}
{"kind":"directive_emitted","ts":101,"prompt_seq":1,"name":"opener","chars":400}
{"kind":"directive_emitted","ts":102,"prompt_seq":1,"name":"intent","chars":200}
{"kind":"start","ts":105,"tool":"Read","prompt_seq":1,"tool_use_id":"t1"}
{"kind":"end","ts":105,"tool":"Read","prompt_seq":1,"tool_use_id":"t1"}
{"kind":"start","ts":106,"tool":"Bash","prompt_seq":1,"tool_use_id":"t2"}
{"kind":"end","ts":108,"tool":"Bash","prompt_seq":1,"tool_use_id":"t2"}
{"kind":"start","ts":110,"tool":"Write","prompt_seq":1,"tool_use_id":"t3"}
{"kind":"end","ts":111,"tool":"Write","prompt_seq":1,"tool_use_id":"t3"}
JSONL
result_a="$(run_producer "sess-A" "targeted-bugfix")"
tokens_a="$(jq -r '.tokens' <<<"${result_a}")"
tool_calls_a="$(jq -r '.tool_calls' <<<"${result_a}")"
elapsed_a="$(jq -r '.elapsed_seconds' <<<"${result_a}")"
assert_eq "A1 tokens (chars 600 / 4)" "150" "${tokens_a}"
assert_eq "A2 tool_calls (3 starts)" "3" "${tool_calls_a}"
assert_eq "A3 elapsed_seconds (250-100)" "150" "${elapsed_a}"

# ---------------------------------------------------------------
# Part B: outcome detectors — perfect targeted-bugfix shape
# ---------------------------------------------------------------
sdir_b="$(new_session "sess-B" '{
  "session_start_ts": "100",
  "last_edit_ts": "300",
  "last_review_ts": "290",
  "last_verify_ts": "295",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "test_command",
  "review_had_findings": "false",
  "code_edit_count": "3",
  "last_assistant_message": "**Changed.** Fixed counter off-by-one. **Verification.** test PASS. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/counter.ts" "src/counter.test.ts" >"${sdir_b}/edited_files.log"
result_b="$(run_producer "sess-B" "targeted-bugfix")"
assert_eq "B1 tests_passed true" "true" "$(jq -r '.outcomes.tests_passed' <<<"${result_b}")"
assert_eq "B2 targeted_verification true" "true" "$(jq -r '.outcomes.targeted_verification' <<<"${result_b}")"
assert_eq "B3 review_clean true" "true" "$(jq -r '.outcomes.review_clean' <<<"${result_b}")"
assert_eq "B4 regression_test_added true" "true" "$(jq -r '.outcomes.regression_test_added' <<<"${result_b}")"
assert_eq "B5 final_closeout_audit_ready true" "true" "$(jq -r '.outcomes.final_closeout_audit_ready' <<<"${result_b}")"

# ---------------------------------------------------------------
# Part C: negative cases — wrong scope, no review, no test file
# ---------------------------------------------------------------
sdir_c="$(new_session "sess-C" '{
  "session_start_ts": "100",
  "last_edit_ts": "300",
  "last_verify_outcome": "passed",
  "last_verify_scope": "lint",
  "code_edit_count": "1"
}')"
printf '%s\n' "src/counter.ts" >"${sdir_c}/edited_files.log"
result_c="$(run_producer "sess-C" "targeted-bugfix")"
assert_eq "C1 lint scope does NOT count as tests_passed" "false" "$(jq -r '.outcomes.tests_passed' <<<"${result_c}")"
assert_eq "C2 lint scope does NOT count as targeted_verification" "false" "$(jq -r '.outcomes.targeted_verification' <<<"${result_c}")"
assert_eq "C3 missing last_review_ts → review_clean false" "false" "$(jq -r '.outcomes.review_clean' <<<"${result_c}")"
assert_eq "C4 no test file in edits → regression_test_added false" "false" "$(jq -r '.outcomes.regression_test_added' <<<"${result_c}")"

# ---------------------------------------------------------------
# Part D: ui-shipping scenario detectors
# ---------------------------------------------------------------
sdir_d="$(new_session "sess-D" '{
  "session_start_ts": "100",
  "last_edit_ts": "500",
  "last_review_ts": "490",
  "last_verify_ts": "495",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "mcp_playwright",
  "review_had_findings": "false",
  "design_contract": "{\"palette\":\"warm\"}",
  "last_code_edit_ts": "480",
  "last_code_edit_revision": "3",
  "dim_design_quality_ts": "495",
  "dim_design_quality_revision": "3",
  "dim_design_quality_verdict": "CLEAN",
  "last_assistant_message": "**Changed.** Redesigned. **Verification.** browser_snapshot ok. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/Dashboard.tsx" "src/Dashboard.module.css" >"${sdir_d}/edited_files.log"
result_d="$(run_producer "sess-D" "ui-shipping")"
assert_eq "D1 design_contract_recorded true" "true" "$(jq -r '.outcomes.design_contract_recorded' <<<"${result_d}")"
assert_eq "D2 ui_files_changed true" "true" "$(jq -r '.outcomes.ui_files_changed' <<<"${result_d}")"
assert_eq "D3 browser_or_visual_verification true" "true" "$(jq -r '.outcomes.browser_or_visual_verification' <<<"${result_d}")"
assert_eq "D4 design_review_clean true" "true" "$(jq -r '.outcomes.design_review_clean' <<<"${result_d}")"
assert_eq "D5 no_layout_overlap default true" "true" "$(jq -r '.outcomes.no_layout_overlap' <<<"${result_d}")"

# Canonical design verdict and generation are both load-bearing.
jq '.dim_design_quality_verdict="FINDINGS"' "${sdir_d}/session_state.json" >"${sdir_d}/session_state.json.tmp" \
  && mv "${sdir_d}/session_state.json.tmp" "${sdir_d}/session_state.json"
result_d_findings="$(run_producer "sess-D" "ui-shipping")"
assert_eq "D6 findings verdict is not clean design evidence" "false" \
  "$(jq -r '.outcomes.design_review_clean' <<<"${result_d_findings}")"
jq '.dim_design_quality_verdict="CLEAN" | .last_code_edit_revision="4"' "${sdir_d}/session_state.json" >"${sdir_d}/session_state.json.tmp" \
  && mv "${sdir_d}/session_state.json.tmp" "${sdir_d}/session_state.json"
result_d_stale="$(run_producer "sess-D" "ui-shipping")"
assert_eq "D7 stale design generation is not clean design evidence" "false" \
  "$(jq -r '.outcomes.design_review_clean' <<<"${result_d_stale}")"

# ---------------------------------------------------------------
# Part E: broad-project-eval detectors
# ---------------------------------------------------------------
sdir_e="$(new_session "sess-E" '{
  "session_start_ts": "100",
  "last_edit_ts": "800",
  "last_review_ts": "790",
  "last_verify_ts": "795",
  "last_verify_outcome": "passed",
  "last_verify_scope": "full",
  "review_had_findings": "false",
  "subagent_dispatch_count": "1"
}')"
cat >"${sdir_e}/findings.json" <<'JSON'
{
  "findings": [
    {"id": "F-1", "status": "shipped", "claim": "x"},
    {"id": "F-2", "status": "deferred", "claim": "y", "reason": "blocked by F-99"}
  ],
  "waves": [
    {"id": "W1", "status": "completed"}
  ]
}
JSON
cat >"${sdir_e}/dispatch_log.jsonl" <<'JSONL'
{"agent": "product-lens", "ts": 200}
JSONL
result_e="$(run_producer "sess-E" "broad-project-eval")"
assert_eq "E1 full_verification true" "true" "$(jq -r '.outcomes.full_verification' <<<"${result_e}")"
assert_eq "E2 council_or_lens_coverage true (one relevant lens dispatched)" "true" "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e}")"
assert_eq "E3 wave_plan_recorded true" "true" "$(jq -r '.outcomes.wave_plan_recorded' <<<"${result_e}")"
assert_eq "E4 findings_resolved (all terminal w/ reasons)" "true" "$(jq -r '.outcomes.findings_resolved_or_deferred_with_why' <<<"${result_e}")"

# E2b negative: raw panel size is not evidence when every dispatch is an
# unrelated implementation agent.
sdir_e_unrelated="$(new_session "sess-E-unrelated" '{"subagent_dispatch_count":"7"}')"
cat >"${sdir_e_unrelated}/dispatch_log.jsonl" <<'JSONL'
{"agent": "frontend-developer", "ts": 200}
{"agent": "backend-api-developer", "ts": 210}
{"agent": "test-automation-engineer", "ts": 220}
JSONL
result_e_unrelated="$(run_producer "sess-E-unrelated" "broad-project-eval")"
assert_eq "E2b unrelated agents do not satisfy council coverage" "false" "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e_unrelated}")"

# E2c negative: the mandatory generic code reviewer is a quality gate, not
# evidence that Council selected a task-specific evaluator.
sdir_e_generic_review="$(new_session "sess-E-generic-review" '{}')"
cat >"${sdir_e_generic_review}/subagent_summaries.jsonl" <<'JSONL'
{"agent_type": "quality-reviewer", "ts": 230, "message": "No code defects.\nVERDICT: CLEAN"}
JSONL
result_e_generic_review="$(run_producer "sess-E-generic-review" "broad-project-eval")"
assert_eq "E2c generic quality review does not satisfy council coverage" "false" "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e_generic_review}")"

# Surface/traceability reviewers are ordinary adaptive quality gates. Their
# presence alone is not proof that Council built a task-specific coverage map.
sdir_e_surface_reviews="$(new_session "sess-E-surface-reviews" '{}')"
cat >"${sdir_e_surface_reviews}/subagent_summaries.jsonl" <<'JSONL'
{"agent_type": "editor-critic", "ts": 240, "message": "Prose clean.\nVERDICT: CLEAN"}
{"agent_type": "design-reviewer", "ts": 250, "message": "UI clean.\nVERDICT: CLEAN"}
{"agent_type": "briefing-analyst", "ts": 260, "message": "Traceability clean.\nVERDICT: CLEAN"}
JSONL
result_e_surface_reviews="$(run_producer "sess-E-surface-reviews" "broad-project-eval")"
assert_eq "E2d ordinary surface reviewers do not satisfy council coverage" "false" "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e_surface_reviews}")"

# Full-roster Council evidence is explicit, not inferred from a name prefix.
sdir_e_custom="$(new_session "sess-E-custom" '{}')"
cat >"${sdir_e_custom}/council_dispatches.jsonl" <<'JSONL'
{"agent_type":"custom-trust-auditor","description":"[council:primary] inspect trust boundary","purpose":"council","council_phase":"primary","ts":270}
JSONL
result_e_custom="$(run_producer "sess-E-custom" "broad-project-eval")"
assert_eq "E2e explicit custom Council primary satisfies coverage" "true" \
  "$(jq -r '.outcomes.council_or_lens_coverage' <<<"${result_e_custom}")"

# E5 negative: deferred finding without reason → false
sdir_e2="$(new_session "sess-E2" '{}')"
cat >"${sdir_e2}/findings.json" <<'JSON'
{"findings": [{"id":"F-1","status":"deferred","claim":"x"}], "waves": []}
JSON
result_e2="$(run_producer "sess-E2" "broad-project-eval")"
assert_eq "E5 deferred without reason → findings_resolved false" "false" "$(jq -r '.outcomes.findings_resolved_or_deferred_with_why' <<<"${result_e2}")"

# ---------------------------------------------------------------
# Part F: non-coding outcome detectors
# ---------------------------------------------------------------
sdir_f="$(new_session "sess-F" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "320",
  "last_doc_review_ts": "340",
  "last_review_ts": "340",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Drafted the memo. **Verification.** editor-critic clean. **Risks.** none. **Next.** Done."
}')"
cat >"${sdir_f}/subagent_summaries.jsonl" <<'JSONL'
{"ts":300,"agent_type":"draft-writer","message":"Memo drafted.\nVERDICT: DELIVERED"}
{"ts":340,"agent_type":"editor-critic","message":"Looks good.\nVERDICT: CLEAN"}
JSONL
result_f="$(run_producer "sess-F" "writing-proposal")"
assert_eq "F1 writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_f}")"
assert_eq "F2 doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_f}")"

# Prose and standard review findings have separate state. Whichever reviewer
# happened to finish last must not overwrite the other domain's outcome.
sdir_f_doc_findings="$(new_session "sess-F-doc-findings" '{
  "last_doc_edit_ts": "320",
  "last_doc_review_ts": "340",
  "last_review_ts": "350",
  "doc_review_had_findings": "true",
  "review_had_findings": "false"
}')"
result_f_doc_findings="$(run_producer "sess-F-doc-findings" "writing-proposal")"
assert_eq "F2a prose findings survive later clean standard review" "false" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_f_doc_findings}")"

sdir_f_code_findings="$(new_session "sess-F-code-findings" '{
  "last_doc_edit_ts": "320",
  "last_doc_review_ts": "350",
  "last_review_ts": "340",
  "doc_review_had_findings": "false",
  "review_had_findings": "true"
}')"
result_f_code_findings="$(run_producer "sess-F-code-findings" "writing-proposal")"
assert_eq "F2b standard findings do not contaminate clean prose review" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_f_code_findings}")"

sdir_g="$(new_session "sess-G" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "420",
  "last_doc_review_ts": "450",
  "last_review_ts": "450",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Produced the brief. **Verification.** research and critique complete. **Risks.** none. **Next.** Done."
}')"
cat >"${sdir_g}/subagent_summaries.jsonl" <<'JSONL'
{"ts":310,"agent_type":"librarian","message":"Primary sources grounded.\nVERDICT: REPORT_READY"}
{"ts":360,"agent_type":"briefing-analyst","message":"Traceability is tight.\nVERDICT: CLEAN"}
{"ts":410,"agent_type":"metis","message":"Stress-tested and no gaps remain.\nVERDICT: CLEAN"}
JSONL
result_g="$(run_producer "sess-G" "research-brief")"
assert_eq "F3 research_report_ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_g}")"
assert_eq "F4 analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_g}")"
assert_eq "F5 research doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_g}")"

sdir_gq="$(new_session "sess-GQ" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "470",
  "last_doc_review_ts": "520",
  "last_review_ts": "520",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Drafted the KPI memo. **Verification.** numbers reviewed and prose checked. **Risks.** none. **Next.** Done."
}')"
cat >"${sdir_gq}/subagent_summaries.jsonl" <<'JSONL'
{"ts":260,"agent_type":"data-lens","message":"Instrumentation gaps and denominator choices reviewed.\nVERDICT: CLEAN"}
{"ts":320,"agent_type":"briefing-analyst","message":"Metrics synthesized into a decision-ready brief.\nVERDICT: CLEAN"}
{"ts":420,"agent_type":"draft-writer","message":"KPI decision memo drafted.\nVERDICT: DELIVERED"}
{"ts":520,"agent_type":"editor-critic","message":"Memo is explicit about assumptions and caveats.\nVERDICT: CLEAN"}
JSONL
result_gq="$(run_producer "sess-GQ" "quantitative-kpi-brief")"
assert_eq "F5b data_specialist_coverage true" "true" "$(jq -r '.outcomes.data_specialist_coverage' <<<"${result_gq}")"
assert_eq "F5c quantitative analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_gq}")"
assert_eq "F5d quantitative writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_gq}")"
assert_eq "F5e quantitative doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_gq}")"

sdir_gw="$(new_session "sess-GW" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "430",
  "last_review_ts": "470",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Produced the decision workbook. **Verification.** metric definitions, assumptions, and scenario tabs were checked. **Risks.** sensitivity assumptions are explicit. **Next.** Done."
}')"
printf '%s\n' "deliverables/q3-decision-model.xlsx" >"${sdir_gw}/edited_files.log"
cat >"${sdir_gw}/subagent_summaries.jsonl" <<'JSONL'
{"ts":260,"agent_type":"data-lens","message":"Denominators, instrumentation gaps, and forecast assumptions reviewed.\nVERDICT: CLEAN"}
{"ts":340,"agent_type":"briefing-analyst","message":"Decision scenarios synthesized into workbook structure.\nVERDICT: CLEAN"}
JSONL
result_gw="$(run_producer "sess-GW" "quantitative-workbook-model")"
assert_eq "F5f workbook data_specialist_coverage true" "true" "$(jq -r '.outcomes.data_specialist_coverage' <<<"${result_gw}")"
assert_eq "F5g workbook analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_gw}")"
assert_eq "F5h workbook spreadsheet_artifact_ready true" "true" "$(jq -r '.outcomes.spreadsheet_artifact_ready' <<<"${result_gw}")"
assert_eq "F5i workbook final_closeout_audit_ready true" "true" "$(jq -r '.outcomes.final_closeout_audit_ready' <<<"${result_gw}")"

sdir_gp="$(new_session "sess-GP" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "410",
  "last_doc_review_ts": "450",
  "last_review_ts": "450",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Produced the board deck. **Verification.** slide order, evidence hierarchy, and presenter assumptions were reviewed. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "deliverables/q2-board-update.pptx" >"${sdir_gp}/edited_files.log"
cat >"${sdir_gp}/subagent_summaries.jsonl" <<'JSONL'
{"ts":320,"agent_type":"chief-of-staff","message":"Board presentation structure delivered.\nVERDICT: DELIVERED"}
{"ts":450,"agent_type":"editor-critic","message":"Deck narrative and wording are clean.\nVERDICT: CLEAN"}
JSONL
result_gp="$(run_producer "sess-GP" "presentation-board-deck")"
assert_eq "F5j presentation_artifact_ready true" "true" "$(jq -r '.outcomes.presentation_artifact_ready' <<<"${result_gp}")"
assert_eq "F5k presentation operations_deliverable_ready true" "true" "$(jq -r '.outcomes.operations_deliverable_ready' <<<"${result_gp}")"
assert_eq "F5l presentation doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_gp}")"
assert_eq "F5m presentation final_closeout_audit_ready true" "true" "$(jq -r '.outcomes.final_closeout_audit_ready' <<<"${result_gp}")"

sdir_gd="$(new_session "sess-GD" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "430",
  "last_doc_review_ts": "470",
  "last_review_ts": "470",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Drafted the policy document. **Verification.** headings, table structure, and prose were reviewed. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "deliverables/privacy-policy.docx" >"${sdir_gd}/edited_files.log"
cat >"${sdir_gd}/subagent_summaries.jsonl" <<'JSONL'
{"ts":310,"agent_type":"draft-writer","message":"Policy document drafted.\nVERDICT: DELIVERED"}
{"ts":470,"agent_type":"editor-critic","message":"Document structure and prose are clean.\nVERDICT: CLEAN"}
JSONL
result_gd="$(run_producer "sess-GD" "document-policy-docx")"
assert_eq "F5n document_artifact_ready true" "true" "$(jq -r '.outcomes.document_artifact_ready' <<<"${result_gd}")"
assert_eq "F5o document writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_gd}")"
assert_eq "F5p document doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_gd}")"
assert_eq "F5q document final_closeout_audit_ready true" "true" "$(jq -r '.outcomes.final_closeout_audit_ready' <<<"${result_gd}")"

sdir_gr="$(new_session "sess-GR" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "540",
  "last_doc_review_ts": "590",
  "last_review_ts": "590",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Drafted the HIPAA remediation memo. **Verification.** governing source is the HIPAA privacy rule as of 2026, jurisdiction is US healthcare operations, and sign-off remains with the compliance owner. **Risks.** patient population assumptions are explicit. **Next.** Done."
}')"
cat >"${sdir_gr}/subagent_summaries.jsonl" <<'JSONL'
{"ts":260,"agent_type":"librarian","message":"HIPAA source material gathered.\nVERDICT: REPORT_READY"}
{"ts":320,"agent_type":"briefing-analyst","message":"Remediation implications synthesized.\nVERDICT: CLEAN"}
{"ts":430,"agent_type":"draft-writer","message":"Compliance memo drafted.\nVERDICT: DELIVERED"}
{"ts":590,"agent_type":"editor-critic","message":"Memo is explicit about authority and sign-off boundaries.\nVERDICT: CLEAN"}
JSONL
result_gr="$(run_producer "sess-GR" "regulated-compliance-memo")"
assert_eq "F5r regulated research_report_ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_gr}")"
assert_eq "F5s regulated analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_gr}")"
assert_eq "F5t regulated writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_gr}")"
assert_eq "F5u regulated doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_gr}")"
assert_eq "F5v regulated_scope_explicit true" "true" "$(jq -r '.outcomes.regulated_scope_explicit' <<<"${result_gr}")"

sdir_h="$(new_session "sess-H" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "260",
  "last_doc_review_ts": "290",
  "last_review_ts": "290",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Structured the action plan. **Verification.** editor-critic clean. **Risks.** none. **Next.** Done."
}')"
cat >"${sdir_h}/subagent_summaries.jsonl" <<'JSONL'
{"ts":250,"agent_type":"chief-of-staff","message":"Execution plan ready.\nVERDICT: DELIVERED"}
JSONL
result_h="$(run_producer "sess-H" "operations-plan")"
assert_eq "F6 operations_deliverable_ready true" "true" "$(jq -r '.outcomes.operations_deliverable_ready' <<<"${result_h}")"
assert_eq "F7 operations doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_h}")"

# Negative: stale doc review and non-delivered verdicts do not count.
sdir_h2="$(new_session "sess-H2" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "300",
  "last_doc_review_ts": "250",
  "last_review_ts": "250",
  "review_had_findings": "false"
}')"
cat >"${sdir_h2}/subagent_summaries.jsonl" <<'JSONL'
{"ts":200,"agent_type":"draft-writer","message":"Need facts first.\nVERDICT: NEEDS_RESEARCH"}
{"ts":210,"agent_type":"librarian","message":"Still unclear.\nVERDICT: INSUFFICIENT_SOURCES"}
{"ts":220,"agent_type":"chief-of-staff","message":"Need a user call.\nVERDICT: NEEDS_INPUT"}
JSONL
result_h2="$(run_producer "sess-H2" "writing-proposal")"
assert_eq "F8 writer_deliverable_ready false on NEEDS_RESEARCH" "false" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_h2}")"
assert_eq "F9 research_report_ready false on insufficient sources" "false" "$(jq -r '.outcomes.research_report_ready' <<<"${result_h2}")"
assert_eq "F10 operations_deliverable_ready false on NEEDS_INPUT" "false" "$(jq -r '.outcomes.operations_deliverable_ready' <<<"${result_h2}")"
assert_eq "F11 doc_review_clean false when stale" "false" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_h2}")"

# ---------------------------------------------------------------
# Part G: scholar-grade mixed workflow detector shape
# ---------------------------------------------------------------
sdir_i="$(new_session "sess-I" '{
  "session_start_ts": "100",
  "last_doc_edit_ts": "520",
  "last_doc_review_ts": "560",
  "last_review_ts": "560",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Drafted the literature review. **Verification.** sources checked and prose reviewed. **Risks.** none. **Next.** Done."
}')"
cat >"${sdir_i}/subagent_summaries.jsonl" <<'JSONL'
{"ts":300,"agent_type":"librarian","message":"Primary literature gathered.\nVERDICT: REPORT_READY"}
{"ts":360,"agent_type":"briefing-analyst","message":"Synthesis is decision-ready.\nVERDICT: CLEAN"}
{"ts":430,"agent_type":"draft-writer","message":"Literature review drafted.\nVERDICT: DELIVERED"}
{"ts":560,"agent_type":"editor-critic","message":"Citation placeholders are explicit and prose is clean.\nVERDICT: CLEAN"}
JSONL
result_i="$(run_producer "sess-I" "scholarly-review")"
assert_eq "G1 scholarly research_report_ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_i}")"
assert_eq "G2 scholarly analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_i}")"
assert_eq "G3 scholarly writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_i}")"
assert_eq "G4 scholarly doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_i}")"

# ---------------------------------------------------------------
# Part H: end-to-end pipe into the scorer
# ---------------------------------------------------------------
# Take the perfect targeted-bugfix result from sess-B and score it.
result_b_full="$(run_producer "sess-B" "targeted-bugfix")"
tmp_result="${TEST_HOME}/result_b.json"
printf '%s' "${result_b_full}" >"${tmp_result}"
score_output="$(bash "${SCORER}" score "${tmp_result}" 2>&1)"
score_value="$(jq -r '.score' <<<"${score_output}")"
pass_value="$(jq -r '.pass' <<<"${score_output}")"
# targeted-bugfix required_outcomes: tests_passed, targeted_verification,
# review_clean, regression_test_added, final_closeout_audit_ready — all
# true in sess-B. Budgets: tokens=150 (under 45000), tool_calls=0 (under 55),
# elapsed=200 (under 900). Score should be 100, pass true.
assert_eq "G1 perfect session scores 100" "100" "${score_value}"
assert_eq "G2 perfect session passes" "true" "${pass_value}"

# Also prove one non-coding scenario scores cleanly with the producer output.
tmp_writing_result="${TEST_HOME}/result_f.json"
printf '%s' "${result_f}" >"${tmp_writing_result}"
writing_score_output="$(bash "${SCORER}" score "${tmp_writing_result}" 2>&1)"
assert_eq "G3 writing scenario scores 100" "100" "$(jq -r '.score' <<<"${writing_score_output}")"
assert_eq "G4 writing scenario passes" "true" "$(jq -r '.pass' <<<"${writing_score_output}")"

tmp_scholarly_result="${TEST_HOME}/result_i.json"
printf '%s' "${result_i}" >"${tmp_scholarly_result}"
scholarly_score_output="$(bash "${SCORER}" score "${tmp_scholarly_result}" 2>&1)"
assert_eq "G5 scholarly scenario scores 100" "100" "$(jq -r '.score' <<<"${scholarly_score_output}")"
assert_eq "G6 scholarly scenario passes" "true" "$(jq -r '.pass' <<<"${scholarly_score_output}")"

tmp_quant_result="${TEST_HOME}/result_gq.json"
printf '%s' "${result_gq}" >"${tmp_quant_result}"
quant_score_output="$(bash "${SCORER}" score "${tmp_quant_result}" 2>&1)"
assert_eq "G7 quantitative scenario scores 100" "100" "$(jq -r '.score' <<<"${quant_score_output}")"
assert_eq "G8 quantitative scenario passes" "true" "$(jq -r '.pass' <<<"${quant_score_output}")"

tmp_workbook_result="${TEST_HOME}/result_gw.json"
printf '%s' "${result_gw}" >"${tmp_workbook_result}"
workbook_score_output="$(bash "${SCORER}" score "${tmp_workbook_result}" 2>&1)"
assert_eq "G9 workbook scenario scores 100" "100" "$(jq -r '.score' <<<"${workbook_score_output}")"
assert_eq "G10 workbook scenario passes" "true" "$(jq -r '.pass' <<<"${workbook_score_output}")"

tmp_presentation_result="${TEST_HOME}/result_gp.json"
printf '%s' "${result_gp}" >"${tmp_presentation_result}"
presentation_score_output="$(bash "${SCORER}" score "${tmp_presentation_result}" 2>&1)"
assert_eq "G11 presentation scenario scores 100" "100" "$(jq -r '.score' <<<"${presentation_score_output}")"
assert_eq "G12 presentation scenario passes" "true" "$(jq -r '.pass' <<<"${presentation_score_output}")"

tmp_document_result="${TEST_HOME}/result_gd.json"
printf '%s' "${result_gd}" >"${tmp_document_result}"
document_score_output="$(bash "${SCORER}" score "${tmp_document_result}" 2>&1)"
assert_eq "G13 document scenario scores 100" "100" "$(jq -r '.score' <<<"${document_score_output}")"
assert_eq "G14 document scenario passes" "true" "$(jq -r '.pass' <<<"${document_score_output}")"

tmp_regulated_result="${TEST_HOME}/result_gr.json"
printf '%s' "${result_gr}" >"${tmp_regulated_result}"
regulated_score_output="$(bash "${SCORER}" score "${tmp_regulated_result}" 2>&1)"
assert_eq "G15 regulated scenario scores 100" "100" "$(jq -r '.score' <<<"${regulated_score_output}")"
assert_eq "G16 regulated scenario passes" "true" "$(jq -r '.pass' <<<"${regulated_score_output}")"

# ---------------------------------------------------------------
# Part I: mixed code-plus-non-code detector shape
# ---------------------------------------------------------------
sdir_j="$(new_session "sess-J" '{
  "session_start_ts": "100",
  "last_edit_ts": "620",
  "last_doc_edit_ts": "650",
  "last_doc_review_ts": "690",
  "last_review_ts": "690",
  "last_verify_ts": "680",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "test_command",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Updated the payment module and drafted the rollout memo. **Verification.** targeted tests passed and sources were checked. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/payment/module.ts" "tests/payment/module.test.ts" "docs/rollout-memo.md" >"${sdir_j}/edited_files.log"
cat >"${sdir_j}/subagent_summaries.jsonl" <<'JSONL'
{"ts":300,"agent_type":"librarian","message":"Stripe API changes verified.\nVERDICT: REPORT_READY"}
{"ts":360,"agent_type":"briefing-analyst","message":"Migration tradeoffs synthesized.\nVERDICT: CLEAN"}
{"ts":520,"agent_type":"draft-writer","message":"Rollout memo drafted.\nVERDICT: DELIVERED"}
{"ts":690,"agent_type":"editor-critic","message":"Memo is clean and explicit.\nVERDICT: CLEAN"}
JSONL
result_j="$(run_producer "sess-J" "mixed-rollout-migration")"
assert_eq "I1 mixed tests_passed true" "true" "$(jq -r '.outcomes.tests_passed' <<<"${result_j}")"
assert_eq "I2 mixed targeted_verification true" "true" "$(jq -r '.outcomes.targeted_verification' <<<"${result_j}")"
assert_eq "I3 mixed regression_test_added true" "true" "$(jq -r '.outcomes.regression_test_added' <<<"${result_j}")"
assert_eq "I4 mixed review_clean true" "true" "$(jq -r '.outcomes.review_clean' <<<"${result_j}")"
assert_eq "I5 mixed research_report_ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_j}")"
assert_eq "I6 mixed analysis_specialist_coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_j}")"
assert_eq "I7 mixed writer_deliverable_ready true" "true" "$(jq -r '.outcomes.writer_deliverable_ready' <<<"${result_j}")"
assert_eq "I8 mixed doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_j}")"

tmp_mixed_result="${TEST_HOME}/result_j.json"
printf '%s' "${result_j}" >"${tmp_mixed_result}"
mixed_score_output="$(bash "${SCORER}" score "${tmp_mixed_result}" 2>&1)"
assert_eq "I9 mixed scenario scores 100" "100" "$(jq -r '.score' <<<"${mixed_score_output}")"
assert_eq "I10 mixed scenario passes" "true" "$(jq -r '.pass' <<<"${mixed_score_output}")"

# ---------------------------------------------------------------
# Part J: mixed code-plus-operations detector shape
# ---------------------------------------------------------------
sdir_o="$(new_session "sess-O" '{
  "session_start_ts": "100",
  "last_edit_ts": "540",
  "last_doc_edit_ts": "590",
  "last_doc_review_ts": "640",
  "last_review_ts": "640",
  "last_verify_ts": "610",
  "last_verify_outcome": "passed",
  "last_verify_scope": "targeted",
  "last_verify_method": "test_command",
  "review_had_findings": "false",
  "last_assistant_message": "**Changed.** Patched the deploy-health check and produced the cutover checklist. **Verification.** targeted tests passed and the release checklist was reviewed. **Risks.** none. **Next.** Done."
}')"
printf '%s\n' "src/deploy/health-check.ts" "tests/deploy/health-check.test.ts" "docs/cutover-checklist.md" >"${sdir_o}/edited_files.log"
cat >"${sdir_o}/subagent_summaries.jsonl" <<'JSONL'
{"ts":420,"agent_type":"chief-of-staff","message":"Cutover checklist delivered with owners, deadlines, and rollback steps.\nVERDICT: DELIVERED"}
{"ts":640,"agent_type":"editor-critic","message":"Checklist is explicit and clean.\nVERDICT: CLEAN"}
JSONL
result_o="$(run_producer "sess-O" "mixed-cutover-checklist")"
assert_eq "J1 mixed ops tests_passed true" "true" "$(jq -r '.outcomes.tests_passed' <<<"${result_o}")"
assert_eq "J2 mixed ops targeted_verification true" "true" "$(jq -r '.outcomes.targeted_verification' <<<"${result_o}")"
assert_eq "J3 mixed ops regression_test_added true" "true" "$(jq -r '.outcomes.regression_test_added' <<<"${result_o}")"
assert_eq "J4 mixed ops review_clean true" "true" "$(jq -r '.outcomes.review_clean' <<<"${result_o}")"
assert_eq "J5 mixed ops operations_deliverable_ready true" "true" "$(jq -r '.outcomes.operations_deliverable_ready' <<<"${result_o}")"
assert_eq "J6 mixed ops doc_review_clean true" "true" "$(jq -r '.outcomes.doc_review_clean' <<<"${result_o}")"

tmp_mixed_ops_result="${TEST_HOME}/result_o.json"
printf '%s' "${result_o}" >"${tmp_mixed_ops_result}"
mixed_ops_score_output="$(bash "${SCORER}" score "${tmp_mixed_ops_result}" 2>&1)"
assert_eq "J7 mixed ops scenario scores 100" "100" "$(jq -r '.score' <<<"${mixed_ops_score_output}")"
assert_eq "J8 mixed ops scenario passes" "true" "$(jq -r '.pass' <<<"${mixed_ops_score_output}")"

# ---------------------------------------------------------------
# Part K: advisory outcome detectors
# ---------------------------------------------------------------
sdir_k="$(new_session "sess-K" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "task_intent": "advisory",
  "task_domain": "coding",
  "task_risk_tier": "medium",
  "session_outcome": "released",
  "last_advisory_verify_ts": "220",
  "advisory_evidence_count": "1"
}')"
result_k="$(run_producer "sess-K" "advisory-code-guidance")"
assert_eq "K1 direct_advisory_answer true" "true" "$(jq -r '.outcomes.direct_advisory_answer' <<<"${result_k}")"
assert_eq "K2 advisory_code_grounded true with advisory evidence" "true" "$(jq -r '.outcomes.advisory_code_grounded' <<<"${result_k}")"

sdir_l="$(new_session "sess-L" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "last_edit_ts": "180",
  "task_intent": "advisory",
  "task_domain": "coding",
  "task_risk_tier": "high",
  "session_outcome": "released",
  "last_advisory_verify_ts": "220",
  "advisory_evidence_count": "1"
}')"
result_l="$(run_producer "sess-L" "advisory-code-guidance")"
assert_eq "K3 direct_advisory_answer false when edits happened after prompt" "false" "$(jq -r '.outcomes.direct_advisory_answer' <<<"${result_l}")"
assert_eq "K4 advisory_code_grounded false when not direct advisory" "false" "$(jq -r '.outcomes.advisory_code_grounded' <<<"${result_l}")"

sdir_m="$(new_session "sess-M" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "task_intent": "advisory",
  "task_domain": "writing",
  "session_outcome": "released"
}')"
cat >"${sdir_m}/subagent_summaries.jsonl" <<'JSONL'
{"ts":210,"agent_type":"writing-architect","message":"Recommended structure outlined.\nVERDICT: NEEDS_INPUT"}
{"ts":240,"agent_type":"chief-of-staff","message":"Checklist shape recommended.\nVERDICT: NEEDS_INPUT"}
JSONL
result_m="$(run_producer "sess-M" "advisory-writing-guidance")"
assert_eq "K5 writing_specialist_coverage true on writing-architect participation" "true" "$(jq -r '.outcomes.writing_specialist_coverage' <<<"${result_m}")"
assert_eq "K6 operations_specialist_coverage true on chief-of-staff participation" "true" "$(jq -r '.outcomes.operations_specialist_coverage' <<<"${result_m}")"

sdir_n="$(new_session "sess-N" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "task_intent": "advisory",
  "task_domain": "research",
  "session_outcome": "released"
}')"
cat >"${sdir_n}/subagent_summaries.jsonl" <<'JSONL'
{"ts":210,"agent_type":"librarian","message":"Evidence gathered.\nVERDICT: REPORT_READY"}
{"ts":230,"agent_type":"briefing-analyst","message":"Tradeoffs synthesized.\nVERDICT: CLEAN"}
JSONL
result_n="$(run_producer "sess-N" "advisory-research-guidance")"
assert_eq "K7 advisory research direct answer true" "true" "$(jq -r '.outcomes.direct_advisory_answer' <<<"${result_n}")"
assert_eq "K8 advisory research report ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_n}")"
assert_eq "K9 advisory research specialist coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_n}")"

sdir_n2="$(new_session "sess-N2" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "task_intent": "advisory",
  "task_domain": "research",
  "session_outcome": "released"
}')"
cat >"${sdir_n2}/subagent_summaries.jsonl" <<'JSONL'
{"ts":210,"agent_type":"data-lens","message":"Metric definitions and denominator choices reviewed.\nVERDICT: CLEAN"}
{"ts":240,"agent_type":"briefing-analyst","message":"The trend story is synthesized.\nVERDICT: CLEAN"}
JSONL
result_n2="$(run_producer "sess-N2" "advisory-data-guidance")"
assert_eq "K10 advisory data direct answer true" "true" "$(jq -r '.outcomes.direct_advisory_answer' <<<"${result_n2}")"
assert_eq "K11 advisory data specialist coverage true" "true" "$(jq -r '.outcomes.data_specialist_coverage' <<<"${result_n2}")"
assert_eq "K12 advisory data analysis coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_n2}")"

tmp_advisory_data_result="${TEST_HOME}/result_n2.json"
printf '%s' "${result_n2}" >"${tmp_advisory_data_result}"
advisory_data_score_output="$(bash "${SCORER}" score "${tmp_advisory_data_result}" 2>&1)"
assert_eq "K13 advisory data scenario scores 100" "100" "$(jq -r '.score' <<<"${advisory_data_score_output}")"
assert_eq "K14 advisory data scenario passes" "true" "$(jq -r '.pass' <<<"${advisory_data_score_output}")"

sdir_n3="$(new_session "sess-N3" '{
  "session_start_ts": "100",
  "last_user_prompt_ts": "150",
  "task_intent": "advisory",
  "task_domain": "research",
  "session_outcome": "released",
  "last_assistant_message": "**Changed.** Answered the liability question directly. **Verification.** governing source is the contract text as of the current revision, jurisdiction is the UK, and final sign-off remains with legal counsel. **Risks.** unresolved scope assumptions are explicit. **Next.** None."
}')"
cat >"${sdir_n3}/subagent_summaries.jsonl" <<'JSONL'
{"ts":210,"agent_type":"librarian","message":"Relevant source text gathered.\nVERDICT: REPORT_READY"}
{"ts":240,"agent_type":"briefing-analyst","message":"Implications synthesized.\nVERDICT: CLEAN"}
JSONL
result_n3="$(run_producer "sess-N3" "advisory-legal-guidance")"
assert_eq "K15 advisory legal direct answer true" "true" "$(jq -r '.outcomes.direct_advisory_answer' <<<"${result_n3}")"
assert_eq "K16 advisory legal report ready true" "true" "$(jq -r '.outcomes.research_report_ready' <<<"${result_n3}")"
assert_eq "K17 advisory legal analysis coverage true" "true" "$(jq -r '.outcomes.analysis_specialist_coverage' <<<"${result_n3}")"
assert_eq "K18 advisory legal regulated scope true" "true" "$(jq -r '.outcomes.regulated_scope_explicit' <<<"${result_n3}")"

tmp_advisory_legal_result="${TEST_HOME}/result_n3.json"
printf '%s' "${result_n3}" >"${tmp_advisory_legal_result}"
advisory_legal_score_output="$(bash "${SCORER}" score "${tmp_advisory_legal_result}" 2>&1)"
assert_eq "K19 advisory legal scenario scores 100" "100" "$(jq -r '.score' <<<"${advisory_legal_score_output}")"
assert_eq "K20 advisory legal scenario passes" "true" "$(jq -r '.pass' <<<"${advisory_legal_score_output}")"

# ---------------------------------------------------------------
# Part L: CLI contract
# ---------------------------------------------------------------
# L1: missing --scenario errors
if bash "${PRODUCER}" --session "sess-B" --state-root "${TEST_STATE_ROOT}" >/dev/null 2>&1; then
  printf '  FAIL: L1 expected non-zero exit when --scenario omitted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# L2: nonexistent session errors
if bash "${PRODUCER}" --scenario "x" --session "nope" --state-root "${TEST_STATE_ROOT}" >/dev/null 2>&1; then
  printf '  FAIL: L2 expected non-zero exit on missing session\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# L3: --help is exit 0
if bash "${PRODUCER}" --help >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: L3 --help should exit 0\n' >&2
  fail=$((fail + 1))
fi

printf '\nrealwork-producer tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
