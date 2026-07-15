#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

pass=0
fail=0
TEST_ROOT="$(mktemp -d)"
export HOME="${TEST_ROOT}/home"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${HOME}/.claude/quality-pack/state" "${STATE_ROOT}"
touch "${HOME}/.claude/quality-pack/state/.ulw_active"

cleanup() { rm -rf "${TEST_ROOT}"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then ok; else
    bad "${label} (expected=${expected} actual=${actual})"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then ok; else
    bad "${label} (missing=${needle}; actual=${haystack})"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then ok; else
    bad "${label} (unexpected=${needle})"
  fi
}

assert_missing() {
  local label="$1" path="$2"
  if [[ ! -s "${path}" ]]; then ok; else bad "${label} (${path} was non-empty)"; fi
}

new_session() {
  SESSION_ID="$1"
  export SESSION_ID
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  printf '%s\n' \
    '{"last_user_prompt_ts":"100","prompt_revision":"1","review_cycle_id":"1","review_cycle_prompt_ts":"100","workflow_mode":"ultrawork"}' \
    > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
}

coverage() {
  local command="$1" payload="${2:-}"
  if [[ -n "${payload}" ]]; then
    printf '%s' "${payload}" | bash "${HOOK_DIR}/record-council-coverage.sh" "${command}"
  else
    bash "${HOOK_DIR}/record-council-coverage.sh" "${command}"
  fi
}

dispatch() {
  local agent="$1" description="$2"
  jq -nc \
    --arg session "${SESSION_ID}" \
    --arg agent "${agent}" \
    --arg description "${description}" \
    '{session_id:$session,tool_name:"Agent",tool_input:{subagent_type:$agent,description:$description}}' \
    | bash "${HOOK_DIR}/record-pending-agent.sh"
}

return_agent() {
  local agent="$1" message="${2:-VERDICT: CLEAN}" native_id="${3:-}"
  jq -nc \
    --arg session "${SESSION_ID}" \
    --arg agent "${agent}" \
    --arg message "${message}" \
    --arg native_id "${native_id}" \
    '{session_id:$session,agent_type:$agent,last_assistant_message:$message}
     + if $native_id == "" then {} else {agent_id:$native_id} end' \
    | OMC_DISCOVERED_SCOPE=on bash "${HOOK_DIR}/record-subagent-summary.sh"
}

start_agent() {
  local agent="$1" native_id="$2"
  jq -nc --arg session "${SESSION_ID}" --arg agent "${agent}" \
    --arg native_id "${native_id}" \
    '{session_id:$session,agent_type:$agent,agent_id:$native_id}' \
    | bash "${HOOK_DIR}/record-pending-agent.sh" start
}

one_primary_payload() {
  local agent="$1"
  jq -nc --arg agent "${agent}" '{
    objective:"adaptive audit",
    coverage_rows:[
      {id:"security",need:"trust boundaries",evidence:"auth handlers exist",impact:"high",competence:"security",status:"selected"}
    ],
    selections:[
      {agent:$agent,phase:"primary",coverage_ids:["security"],reason:"matches the trust-boundary risk",non_goals:["visual design"]}
    ]
  }'
}

printf 'Council init envelope and atomic CAS:\n'
new_session "envelope"
base="$(one_primary_payload "alpha:auditor")"
zero_primary="$(printf '%s' "${base}" | jq '.selections=[] | .coverage_rows[0].status="covered-inline" | .coverage_rows[0].reason="inline"')"
if coverage init "${zero_primary}" >/dev/null 2>&1; then bad "init accepted zero primaries"; else ok; fi
gap_at_init="$(printf '%s' "${base}" | jq '.selections[0].phase="gap-fill"')"
if coverage init "${gap_at_init}" >/dev/null 2>&1; then bad "init accepted a gap-fill selection"; else ok; fi

five="$(jq -nc '
  [range(1;6) | {id:("r"+tostring),need:"need",evidence:"evidence",impact:"high",competence:("c"+tostring),status:"selected"}] as $rows
  | [range(1;6) | {agent:("agent-"+tostring),phase:"primary",coverage_ids:[("r"+tostring)],reason:"independent",non_goals:["other rows"]}] as $selections
  | {objective:"exceptional audit",coverage_rows:$rows,selections:$selections}')"
if coverage init "${five}" >/dev/null 2>&1; then bad "init accepted >4 without an exception ledger"; else ok; fi
five_exception="$(printf '%s' "${five}" | jq '.primary_exception={reason:"five independent systems",cost:"five calls",independent_high_impact_coverage_ids:["r1","r2","r3","r4","r5"]}')"
if coverage init "${five_exception}" >/dev/null 2>&1; then ok; else bad "evidenced >4 exception was rejected"; fi

new_session "cas"
cas_payload="$(one_primary_payload "alpha:auditor")"
set +e
(coverage init "${cas_payload}" >/dev/null 2>"${TEST_ROOT}/cas1.err") & p1=$!
(coverage init "${cas_payload}" >/dev/null 2>"${TEST_ROOT}/cas2.err") & p2=$!
wait "${p1}"; rc1=$?
wait "${p2}"; rc2=$?
set -e
successes=0
[[ "${rc1}" -eq 0 ]] && successes=$((successes + 1))
[[ "${rc2}" -eq 0 ]] && successes=$((successes + 1))
assert_eq "same-prompt concurrent init has one winner" "1" "${successes}"

printf 'Exact and safely bound agent identity:\n'
new_session "namespace"
coverage init "$(one_primary_payload "alpha:auditor")" >/dev/null
beta_denied="$(dispatch "beta:auditor" "[council:primary] wrong namespace")"
assert_contains "namespaced selection does not short-match another namespace" '"permissionDecision":"deny"' "${beta_denied}"
alpha_allowed="$(dispatch "alpha:auditor" "[council:primary] exact namespace")"
assert_eq "exact namespaced identity is allowed" "" "${alpha_allowed}"
return_agent "alpha:auditor"

new_session "legacy-name"
coverage init "$(one_primary_payload "auditor")" >/dev/null
legacy_allowed="$(dispatch "alpha:auditor" "[council:primary] bind installed short name")"
assert_eq "unnamespaced selection binds once" "" "${legacy_allowed}"
assert_eq "resolved runtime identity persisted" "alpha:auditor" \
  "$(jq -r '.selections[0].resolved_agent' "${STATE_ROOT}/${SESSION_ID}/council_coverage.json")"
return_agent "alpha:auditor"
legacy_collision="$(dispatch "beta:auditor" "[council:primary] collide with bound short name")"
assert_contains "bound short identity cannot authorize a second namespace" '"permissionDecision":"deny"' "${legacy_collision}"

new_session "prior-pending"
coverage init "$(one_primary_payload "alpha:auditor")" >/dev/null
dispatch "alpha:auditor" "[council:primary] interrupted prior objective" >/dev/null
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
jq '.last_user_prompt_ts="101" | .prompt_revision="2"' "${state_file}" >"${state_file}.tmp"
mv "${state_file}.tmp" "${state_file}"
coverage init "$(one_primary_payload "alpha:auditor")" >/dev/null
prior_pending_file="${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
assert_eq "new objective preserves obsolete Council provenance as a tombstone" \
  "true" "$(jq -r '.review_dispatch_abandoned // false' "${prior_pending_file}")"
fresh_identity="$(dispatch "alpha:auditor" "[council:primary] fresh objective")"
assert_contains "prior-objective identity reuse offers an explicit binding" \
  '[review-rebind:' "${fresh_identity}"
fresh_rebind_id="$(printf '%s' "${fresh_identity}" \
  | sed -n 's/.*\[review-rebind:\([^]]*\)\].*/\1/p')"
fresh_bound="$(dispatch "alpha:auditor" \
  "[council:primary] [review-rebind:${fresh_rebind_id}] fresh objective; emit REVIEW_DISPATCH_ID: ${fresh_rebind_id} immediately before VERDICT")"
assert_eq "ID-bound fresh objective can reuse the exact identity" "" "${fresh_bound}"
return_agent "alpha:auditor" \
  $'Fresh objective returned.\n'"REVIEW_DISPATCH_ID: ${fresh_rebind_id}"$'\nVERDICT: CLEAN'
assert_eq "new-first return leaves only the prior tombstone" "1" \
  "$(jq -s '[.[] | select(.review_dispatch_abandoned == true)] | length' "${prior_pending_file}")"
assert_eq "fresh bound return records exactly one Council result" "1" \
  "$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl")"
prior_summary_count="$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/subagent_summaries.jsonl")"
return_agent "alpha:auditor" $'Late prior objective.\nVERDICT: CLEAN'
assert_eq "late prior return is suppressed after the new result" "${prior_summary_count}" \
  "$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/subagent_summaries.jsonl")"
assert_eq "late prior return clears only its tombstone" "0" \
  "$(jq -s 'length' "${prior_pending_file}")"

new_session "wrong-phase-rebind"
coverage init "$(one_primary_payload "alpha:auditor")" >/dev/null
dispatch "alpha:auditor" "[council:primary] live primary" >/dev/null
wrong_pending="${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
wrong_dispatches="${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl"
wrong_expired_claim="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${wrong_expired_claim}" '
  . + {completion_claim_id:"wrong-phase-stale-claim",
       completion_claim_ts:$expired,
       completion_claim_effects_complete:false}
' "${wrong_pending}" >"${wrong_pending}.tmp"
mv "${wrong_pending}.tmp" "${wrong_pending}"
wrong_pending_before="$(cat "${wrong_pending}")"
wrong_dispatches_before="$(cat "${wrong_dispatches}")"
wrong_phase="$(dispatch "alpha:auditor" \
  "[council:gap-fill] [review-rebind:wrong-phase] invalid phase")"
assert_contains "wrong-phase rebound dispatch is denied before mutation" \
  'gap-fill-before-reconciliation' "${wrong_phase}"
assert_eq "wrong-phase denial leaves pending provenance byte-identical" \
  "${wrong_pending_before}" "$(cat "${wrong_pending}")"
assert_eq "wrong-phase denial leaves durable dispatch audit byte-identical" \
  "${wrong_dispatches_before}" "$(cat "${wrong_dispatches}")"
unlisted_rebind="$(dispatch "beta:auditor" \
  "[council:primary] [review-rebind:unlisted] invalid selection")"
assert_contains "unlisted rebound dispatch is denied" \
  'unlisted-exact-agent' "${unlisted_rebind}"
assert_eq "unlisted denial leaves legitimate primary live" \
  "${wrong_pending_before}" "$(cat "${wrong_pending}")"
jq -c 'del(.completion_claim_id,.completion_claim_ts,.completion_claim_effects_complete)' \
  "${wrong_pending}" >"${wrong_pending}.tmp"
mv "${wrong_pending}.tmp" "${wrong_pending}"
return_agent "alpha:auditor"
completed_primary_duplicate="$(dispatch "alpha:auditor" \
  "[council:primary] do not repay completed selection")"
assert_contains "completed primary selection cannot be dispatched twice" \
  'duplicate-council-selection-dispatch' "${completed_primary_duplicate}"

new_session "primary-new-first-rebind"
coverage init "$(one_primary_payload "alpha:auditor")" >/dev/null
dispatch "alpha:auditor" "[council:primary] original primary" >/dev/null
primary_rebind="$(dispatch "alpha:auditor" \
  "[council:primary] [review-rebind:primary-retry] confirmed interrupted; emit REVIEW_DISPATCH_ID: primary-retry immediately before VERDICT")"
assert_eq "current primary can be rebound once while its pending attempt is live" \
  "" "${primary_rebind}"
return_agent "alpha:auditor" \
  $'Primary replacement.\nREVIEW_DISPATCH_ID: primary-retry\nVERDICT: CLEAN'
primary_third="$(dispatch "alpha:auditor" \
  "[council:primary] [review-rebind:primary-third] must not replace completed retry")"
assert_contains "primary tombstone cannot authorize a third paid dispatch" \
  'duplicate-council-selection-dispatch' "${primary_third}"
assert_eq "completed primary replacement remains the one live audit row" "1" \
  "$(jq -s '[.[] | select(.agent_type == "alpha:auditor" and (.review_dispatch_superseded // false) != true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
return_agent "alpha:auditor" $'Late original primary.\nVERDICT: CLEAN'

new_session "effects-complete-reviewer-recovery"
effects_base="$(one_primary_payload "quality-reviewer")"
coverage init "${effects_base}" >/dev/null
dispatch "quality-reviewer" "[council:primary] reviewer summary-first crash" >/dev/null
return_agent "quality-reviewer" $'Council review returned.\nVERDICT: CLEAN'
effects_pending="${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
assert_eq "summary-first Council reviewer keeps effects-complete coordination row" \
  "true" "$(jq -r '.completion_claim_effects_complete // false' "${effects_pending}")"
effects_expired="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${effects_expired}" '.completion_claim_ts=$expired' \
  "${effects_pending}" >"${effects_pending}.tmp"
mv "${effects_pending}.tmp" "${effects_pending}"
effects_reconciliation="$(printf '%s' "${effects_base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"summary-side Council return committed",
  primary_returns:["quality-reviewer"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return",reason:"covered"}]
}')"
if coverage update "${effects_reconciliation}" >/dev/null 2>&1; then
  ok
else
  bad "stale effects-complete coordination row blocked Council reconciliation"
fi
effects_retry_unbound="$(dispatch "quality-reviewer" \
  "ordinary reviewer retry after second-hook crash")"
assert_contains "stale effects-complete reviewer recovery requires explicit ID" \
  '[review-rebind:' "${effects_retry_unbound}"
effects_retry_bound="$(dispatch "quality-reviewer" \
  "[review-rebind:effects-retry] recover missing reviewer dimension; emit REVIEW_DISPATCH_ID: effects-retry immediately before VERDICT")"
assert_eq "ordinary ID-bound reviewer retry can recover missing second hook" "" \
  "${effects_retry_bound}"
assert_eq "accepted Council return is not charged as another Council dispatch" "1" \
  "$(jq -s '[.[] | select((.review_dispatch_superseded // false) != true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"

new_session "invalid-rebind-verdict"
invalid_base="$(one_primary_payload "alpha:auditor")"
coverage init "${invalid_base}" >/dev/null
dispatch "alpha:auditor" "[council:primary] original call" >/dev/null
start_agent "alpha:auditor" "native-invalid-old"
dispatch "alpha:auditor" \
  "[council:primary] [review-rebind:invalid-tail] confirmed interrupted; emit the binding before VERDICT" \
  >/dev/null
start_agent "alpha:auditor" "native-invalid-malformed"
invalid_tail_message=$'Replacement returned.\nREVIEW_DISPATCH_ID: invalid-tail\nVERDICT: GARBAGE'
return_agent "alpha:auditor" "${invalid_tail_message}" "native-invalid-malformed"
invalid_pending="${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
assert_eq "unknown uppercase verdict cannot authenticate a dispatch ID" \
  "invalid-tail" "$(jq -s -r '[.[] | select(.review_dispatch_id == "invalid-tail")][0].review_dispatch_id // ""' "${invalid_pending}")"
assert_missing "invalid universal token records no authoritative summary" \
  "${STATE_ROOT}/${SESSION_ID}/subagent_summaries.jsonl"
assert_missing "invalid universal token records no Council return" \
  "${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
assert_missing "invalid universal token creates no discovered-scope debt" \
  "${STATE_ROOT}/${SESSION_ID}/discovered_scope.jsonl"
invalid_unbound_retry="$(dispatch "alpha:auditor" \
  "[council:primary] retry malformed ended call")"
assert_contains "malformed ended call cannot be repaid without confirmation" \
  '[review-rebind:' "${invalid_unbound_retry}"
invalid_final_dispatch="$(dispatch "alpha:auditor" \
  "[council:primary] [review-rebind:invalid-final] confirmed malformed call ended")"
assert_eq "fresh confirmed retry is admitted after malformed final tail" \
  "" "${invalid_final_dispatch}"
start_agent "alpha:auditor" "native-invalid-final"
assert_eq "each superseded malformed attempt remains auditable" "2" \
  "$(jq -s '[.[] | select(.review_dispatch_superseded == true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
return_agent "alpha:auditor" \
  $'Final replacement returned.\nVERDICT: CLEAN' "native-invalid-final"
assert_eq "valid native replacement records one Council return" "1" \
  "$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl")"
summary_after_final="$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/subagent_summaries.jsonl")"
return_agent "alpha:auditor" $'Late original call.\nVERDICT: CLEAN' \
  "native-invalid-old"
assert_eq "late old native Stop is suppressed after valid replacement" \
  "${summary_after_final}" \
  "$(jq -s 'length' "${STATE_ROOT}/${SESSION_ID}/subagent_summaries.jsonl")"
invalid_reconciled="$(printf '%s' "${invalid_base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"valid replacement returned",
  primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",
    evidence:"replacement return",reason:"covered"}]
}')"
coverage update "${invalid_reconciled}" >/dev/null
if coverage complete >/dev/null 2>&1; then
  ok
else
  bad "Council did not complete after malformed-call recovery"
fi

printf 'Reconciliation, gap-fill, and completion lifecycle:\n'
new_session "lifecycle"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
assert_eq "Council ledger binds the nonzero current review cycle" "1" \
  "$(jq -r '.objective_cycle_id' "${STATE_ROOT}/${SESSION_ID}/council_coverage.json")"
premature_gap="$(dispatch "beta:data-auditor" "[council:gap-fill] before primary reconciliation")"
assert_contains "gap-fill before post-primary generation is denied" '"permissionDecision":"deny"' "${premature_gap}"
if coverage complete >/dev/null 2>&1; then bad "complete accepted an unreconciled primary"; else ok; fi

primary_complete="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary return reconciled",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return grounded the row",reason:"no residual hole"}]
}')"
# Same timestamp/revision is not sufficient: a stale return from another
# objective cycle must not satisfy the current selection.
jq -nc '{ts:100,selection_agent:"alpha:auditor",actual_agent:"alpha:auditor",
  council_phase:"primary",objective_prompt_ts:100,
  objective_prompt_revision:1,objective_cycle_id:99,contract_valid:true}' \
  >"${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
if coverage update "${primary_complete}" >/dev/null 2>&1; then bad "update accepted before the selected primary returned"; else ok; fi
dispatch "alpha:auditor" "[council:primary] inspect trust" >/dev/null
assert_eq "current Council pending row carries the nonzero objective cycle" "1" \
  "$(jq -s -r '[.[] | select(.objective_cycle_id == 1)][0].objective_cycle_id // 0' \
    "${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl")"
return_agent "alpha:auditor"
assert_eq "current Council return carries the nonzero objective cycle" "1" \
  "$(jq -s -r '[.[] | select(.actual_agent == "alpha:auditor" and
      .objective_cycle_id == 1)][0].objective_cycle_id // 0' \
    "${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl")"

uncovered_primary_complete="$(printf '%s' "${primary_complete}" \
  | jq '.reconciliation.coverage_results[0].status="uncovered"
        | .reconciliation.coverage_results[0].reason="still unresolved"')"
if coverage update "${uncovered_primary_complete}" >/dev/null 2>&1; then
  bad "primary-complete accepted an uncovered selected result"
else
  ok
fi
if coverage complete >/dev/null 2>&1; then
  bad "uncovered primary-complete armed completion without gap-fill"
else
  ok
fi
assert_eq "rejected uncovered primary-complete does not arm handoff" "" \
  "$(jq -r '.council_assessment_ready // empty' "${STATE_ROOT}/${SESSION_ID}/session_state.json")"

three_gaps="$(printf '%s' "${base}" | jq '
  .coverage_rows += [
    {id:"g1",need:"g1",evidence:"e1",impact:"high",competence:"c1",status:"selected"},
    {id:"g2",need:"g2",evidence:"e2",impact:"high",competence:"c2",status:"selected"},
    {id:"g3",need:"g3",evidence:"e3",impact:"high",competence:"c3",status:"selected"}
  ]
  | .selections += [
    {agent:"gap-1",phase:"gap-fill",coverage_ids:["g1"],reason:"r1",non_goals:["other"]},
    {agent:"gap-2",phase:"gap-fill",coverage_ids:["g2"],reason:"r2",non_goals:["other"]},
    {agent:"gap-3",phase:"gap-fill",coverage_ids:["g3"],reason:"r3",non_goals:["other"]}
  ]
  | .reconciliation={status:"gap-fill-required",evidence:"three gaps",primary_returns:["alpha:auditor"],gap_fill_returns:[],coverage_results:[
      {coverage_id:"security",status:"evidenced",evidence:"done",reason:"covered"},
      {coverage_id:"g1",status:"uncovered",evidence:"hole",reason:"needs g1"},
      {coverage_id:"g2",status:"uncovered",evidence:"hole",reason:"needs g2"},
      {coverage_id:"g3",status:"uncovered",evidence:"hole",reason:"needs g3"}
    ]}')"
if coverage update "${three_gaps}" >/dev/null 2>&1; then bad "update accepted more than two gap-fill agents"; else ok; fi

gap_payload="$(printf '%s' "${base}" | jq '
  .coverage_rows += [{id:"data",need:"storage integrity",evidence:"primary found mutable cache",impact:"high",competence:"data integrity",status:"selected"}]
  | .selections += [{agent:"beta:data-auditor",phase:"gap-fill",coverage_ids:["data"],reason:"owns the newly exposed data risk",non_goals:["auth policy"]}]
  | .reconciliation={status:"gap-fill-required",evidence:"primary exposed a storage hole",primary_returns:["alpha:auditor"],gap_fill_returns:[],coverage_results:[
      {coverage_id:"security",status:"evidenced",evidence:"primary completed it",reason:"covered"},
      {coverage_id:"data",status:"newly-discovered",evidence:"mutable cache observed",reason:"requires data competence"}
    ]}')"
coverage update "${gap_payload}" >/dev/null
assert_eq "post-primary update advances generation" "2" \
  "$(jq -r '.generation' "${STATE_ROOT}/${SESSION_ID}/council_coverage.json")"
gap_allowed="$(dispatch "beta:data-auditor" "[council:gap-fill] inspect storage hole")"
assert_eq "listed gap-fill is allowed after reconciliation" "" "${gap_allowed}"
if coverage complete >/dev/null 2>&1; then bad "complete accepted an in-flight gap-fill"; else ok; fi
return_agent "beta:data-auditor"
if coverage complete >/dev/null 2>&1; then bad "complete accepted before final gap reconciliation"; else ok; fi

second_round="$(printf '%s' "${gap_payload}" | jq '
  .coverage_rows += [{id:"ops",need:"operations",evidence:"late thought",impact:"high",competence:"operations",status:"selected"}]
  | .selections += [{agent:"gamma:ops-auditor",phase:"gap-fill",coverage_ids:["ops"],reason:"second round",non_goals:["data"]}]
  | .reconciliation.coverage_results += [{coverage_id:"ops",status:"newly-discovered",evidence:"late thought",reason:"would require another round"}]')"
if coverage update "${second_round}" >/dev/null 2>&1; then bad "update added a second gap-fill round after the first was selected"; else ok; fi

gap_complete="$(printf '%s' "${gap_payload}" | jq '
  .reconciliation.status="gap-fill-complete"
  | .reconciliation.gap_fill_returns=["beta:data-auditor"]
  | .reconciliation.coverage_results[1].status="evidenced"
  | .reconciliation.coverage_results[1].reason="gap specialist resolved the evidence question"')"
coverage update "${gap_complete}" >/dev/null
printf 'malformed pending row\n' > "${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
if coverage complete >/dev/null 2>&1; then bad "complete failed open on a corrupt pending ledger"; else ok; fi
rm -f "${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
# Same timestamp/revision but another cycle is historical and cannot block the
# current completion handoff.
jq -nc '{ts:100,agent_type:"wrong-cycle-worker",purpose:"council",
  council_phase:"verification",council_objective_prompt_ts:100,
  council_objective_prompt_revision:1,objective_cycle_id:99}' \
  >"${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
coverage complete >/dev/null
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
assert_eq "complete is the handoff producer" "1" "$(jq -r '.council_assessment_ready' "${state_file}")"
assert_eq "completion records its prompt revision" "1" "$(jq -r '.council_assessment_prompt_revision' "${state_file}")"

printf 'Current-cycle Council ledgers survive fan-out beyond 32 rows:\n'
new_session "current-cycle-capacity"
capacity_base="$(one_primary_payload "alpha:auditor")"
coverage init "${capacity_base}" >/dev/null
capacity_dispatches="${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl"
capacity_returns="${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
for capacity_i in $(seq 1 40); do
  jq -nc --argjson i "${capacity_i}" \
    '{ts:(1000+$i),agent_type:("capacity-audit-"+($i|tostring)),
      purpose:"capacity-probe",council_phase:"primary",
      council_objective_prompt_ts:100,council_objective_prompt_revision:1,
      objective_cycle_id:1}' >>"${capacity_dispatches}"
  jq -nc --argjson i "${capacity_i}" \
    '{ts:(1000+$i),selection_agent:("capacity-return-"+($i|tostring)),
      actual_agent:("capacity-return-"+($i|tostring)),council_phase:"primary",
      objective_prompt_ts:100,objective_prompt_revision:1,
      objective_cycle_id:1,contract_valid:true}' >>"${capacity_returns}"
done
dispatch "alpha:auditor" "[council:primary] retained current-cycle dispatch" >/dev/null
assert_eq "Council dispatch append preserves all 40 current-cycle rows" "41" \
  "$(jq -s 'length' "${capacity_dispatches}")"
return_agent "alpha:auditor"
assert_eq "Council return append preserves all 40 current-cycle rows" "41" \
  "$(jq -s 'length' "${capacity_returns}")"
capacity_reconciled="$(printf '%s' "${capacity_base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"retained return reconciled",
  primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",
    evidence:"retained current return",reason:"covered"}]
}')"
coverage update "${capacity_reconciled}" >/dev/null
if coverage complete >/dev/null 2>&1; then
  ok
else
  bad "current-cycle rows beyond 32 prevented valid Council completion"
fi

new_session "same-turn-phase8"
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
jq '.council_phase8_active="1" | .council_phase8_prompt_revision="1"' \
  "${state_file}" >"${state_file}.tmp"
mv "${state_file}.tmp" "${state_file}"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
assert_eq "init preserves same-turn Phase 8 authorization" "1" \
  "$(jq -r '.council_phase8_active' "${state_file}")"
dispatch "alpha:auditor" "[council:primary] same-turn assessment" >/dev/null
return_agent "alpha:auditor"
same_turn_reconciliation="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary returned",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return",reason:"covered"}]
}')"
coverage update "${same_turn_reconciliation}" >/dev/null
coverage complete >/dev/null
assert_eq "complete preserves active same-turn Phase 8" "1" \
  "$(jq -r '.council_phase8_active' "${state_file}")"
assert_eq "same-turn Phase 8 does not arm a redundant follow-up" "" \
  "$(jq -r '.council_assessment_ready // empty' "${state_file}")"

new_session "stale-phase8"
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
jq '.council_phase8_active="1" | .council_phase8_prompt_revision="0"' \
  "${state_file}" >"${state_file}.tmp"
mv "${state_file}.tmp" "${state_file}"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
assert_eq "init clears Phase 8 authorization from another prompt revision" "" \
  "$(jq -r '.council_phase8_active // empty' "${state_file}")"
dispatch "alpha:auditor" "[council:primary] advisory assessment" >/dev/null
return_agent "alpha:auditor"
stale_phase8_reconciliation="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary returned",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return",reason:"covered"}]
}')"
coverage update "${stale_phase8_reconciliation}" >/dev/null
coverage complete >/dev/null
assert_eq "stale Phase 8 bit cannot suppress this assessment handoff" "1" \
  "$(jq -r '.council_assessment_ready' "${state_file}")"

printf 'Immutable reconciliation inputs:\n'
new_session "immutable-coverage"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
dispatch "alpha:auditor" "[council:primary] immutable evidence" >/dev/null
return_agent "alpha:auditor"
immutable_reconciliation="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary returned",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return",reason:"covered"}]
}')"
rewritten_objective="$(printf '%s' "${immutable_reconciliation}" | jq '.objective="different objective"')"
if coverage update "${rewritten_objective}" >/dev/null 2>&1; then
  bad "update rewrote the dispatched Council objective"
else
  ok
fi
rewritten_row="$(printf '%s' "${immutable_reconciliation}" | jq '.coverage_rows[0].evidence="post-hoc replacement"')"
if coverage update "${rewritten_row}" >/dev/null 2>&1; then
  bad "update rewrote an existing coverage row"
else
  ok
fi
coverage update "${immutable_reconciliation}" >/dev/null
assert_eq "valid reconciliation preserves original objective" "adaptive audit" \
  "$(jq -r '.objective' "${STATE_ROOT}/${SESSION_ID}/council_coverage.json")"

printf 'Optional verification lifecycle and provenance:\n'
new_session "verification"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
dispatch "alpha:auditor" "[council:primary] establish claim" >/dev/null
return_agent "alpha:auditor"
premature_verifier="$(dispatch "verifier-one" "[council:verification] premature check")"
assert_contains "verification before final reconciliation is denied" \
  'verification-before-final-reconciliation' "${premature_verifier}"
verification_reconciliation="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary returned",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return",reason:"covered"}]
}')"
coverage update "${verification_reconciliation}" >/dev/null
verifier_allowed="$(dispatch "verifier-one" "[council:verification] independent check")"
assert_eq "first verifier is allowed after final reconciliation" "" "${verifier_allowed}"
pending_file="${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
assert_eq "verification pending row carries current objective revision" "1" \
  "$(jq -s -r '[.[] | select(.council_phase == "verification")][0].council_objective_prompt_revision' "${pending_file}")"
assert_eq "verification pending row carries reconciled ledger generation" "2" \
  "$(jq -s -r '[.[] | select(.council_phase == "verification")][0].council_ledger_generation' "${pending_file}")"
if coverage complete >/dev/null 2>&1; then
  bad "complete accepted an in-flight verifier"
else
  ok
fi
# Simulate a summary recorder killed after its durable claim but before any
# effects. Once the 120s lease expires, recovery remains ID-bound and the old
# verifier audit is superseded in the same logical slot.
verification_expired_claim="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${verification_expired_claim}" '
  . + {completion_claim_id:"crashed-verifier-summary",
       completion_claim_ts:$expired,
       completion_claim_effects_complete:false}
' "${pending_file}" >"${pending_file}.tmp"
mv "${pending_file}.tmp" "${pending_file}"
active_verifier_duplicate="$(dispatch "verifier-one" \
  "[council:verification] recover expired claimed verifier")"
assert_contains "expired Council claim denial offers safe killed-call rebind" \
  '[review-rebind:' "${active_verifier_duplicate}"
verifier_rebound="$(dispatch "verifier-one" \
  "[council:verification] [review-rebind:verify-retry] confirmed interrupted; emit REVIEW_DISPATCH_ID: verify-retry immediately before VERDICT")"
assert_eq "expired claimed verifier rebinds in the same logical slot" "" \
  "${verifier_rebound}"
assert_eq "old verifier audit is preserved as superseded provenance" "1" \
  "$(jq -s '[.[] | select(.review_dispatch_superseded == true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
assert_eq "one replacement remains the only live verifier identity" "1" \
  "$(jq -s '[.[] | select(.council_phase == "verification" and (.review_dispatch_superseded // false) != true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
return_agent "verifier-one" \
  $'Replacement verified.\nREVIEW_DISPATCH_ID: verify-retry\nVERDICT: CLEAN'
assert_eq "new-first verifier return leaves only abandoned old pending" "1" \
  "$(jq -s '[.[] | select(.review_dispatch_abandoned == true)] | length' "${pending_file}")"
third_rebind="$(dispatch "verifier-one" \
  "[council:verification] [review-rebind:verify-third] must not replace completed retry")"
assert_contains "current tombstone cannot authorize replacing a completed retry" \
  'duplicate-verifier-identity' "${third_rebind}"
assert_eq "completed replacement audit remains live after third rebind denial" "1" \
  "$(jq -s '[.[] | select(.agent_type == "verifier-one" and (.review_dispatch_superseded // false) != true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
return_agent "verifier-one" $'Late killed verifier.\nVERDICT: CLEAN'
returns_file="${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
assert_eq "verification return is recorded with phase provenance" "verification" \
  "$(jq -s -r '[.[] | select(.actual_agent == "verifier-one")][0].council_phase' "${returns_file}")"
assert_eq "verification return keeps the objective revision" "1" \
  "$(jq -s -r '[.[] | select(.actual_agent == "verifier-one")][0].objective_prompt_revision' "${returns_file}")"
assert_eq "late old verifier creates no second Council return" "1" \
  "$(jq -s '[.[] | select(.actual_agent == "verifier-one")] | length' "${returns_file}")"

# A prior-objective tombstone alone must not authorize replacing a verifier
# that already completed in the current objective.
jq -nc '{ts:1,agent_type:"verifier-one",purpose:"council",
  council_phase:"verification",council_objective_prompt_ts:99,
  council_objective_prompt_revision:0,review_dispatch_abandoned:true,
  objective_prompt_ts:99,objective_prompt_revision:0}' >>"${pending_file}"
completed_rebind="$(dispatch "verifier-one" \
  "[council:verification] [review-rebind:completed-edge] must not replace completed current verifier")"
assert_contains "prior tombstone cannot turn a completed current verifier into a retry" \
  'duplicate-verifier-identity' "${completed_rebind}"
assert_eq "completed current verifier audit remains live, not superseded" "1" \
  "$(jq -s '[.[] | select(.agent_type == "verifier-one" and (.review_dispatch_superseded // false) != true)] | length' \
    "${STATE_ROOT}/${SESSION_ID}/council_dispatches.jsonl")"
return_agent "verifier-one" $'Synthetic prior tombstone.\nVERDICT: CLEAN'
duplicate_verifier="$(dispatch "verifier-one" \
  "[council:verification] [review-rebind:current-duplicate] duplicate identity")"
assert_contains "same verifier identity cannot consume a second slot" \
  'duplicate-verifier-identity' "${duplicate_verifier}"
dispatch "verifier-two" "[council:verification] second independent check" >/dev/null
return_agent "verifier-two"
dispatch "verifier-three" "[council:verification] third independent check" >/dev/null
return_agent "verifier-three"
fourth_verifier="$(dispatch "verifier-four" "[council:verification] exceeds cap")"
assert_contains "current objective accepts at most three verifiers" \
  'verification-cap-reached' "${fourth_verifier}"
if coverage complete >/dev/null 2>&1; then
  ok
else
  bad "complete rejected after all optional verifiers returned"
fi

printf 'Universal unsuccessful Council verdict contract:\n'
verdict_index=0
for unsuccessful_verdict in \
  'FINDINGS (1)' 'BLOCK (1)' 'NEEDS_CLARIFICATION' 'BLOCKED' \
  'INSUFFICIENT_SOURCES' 'HYPOTHESIS' 'NEEDS_EVIDENCE' \
  'NEEDS_PROBLEM_STATEMENT' 'INSUFFICIENT_OPTIONS' 'NEEDS_INPUT' \
  'NEEDS_RESEARCH' 'INCOMPLETE'; do
  verdict_index=$((verdict_index + 1))
  new_session "unsuccessful-${verdict_index}"
  verdict_agent="custom-${verdict_index}"
  coverage init "$(one_primary_payload "${verdict_agent}")" >/dev/null
  dispatch "${verdict_agent}" "[council:primary] exercise universal verdict" >/dev/null
  return_agent "${verdict_agent}" "No structured payload"$'\n'"VERDICT: ${unsuccessful_verdict}"
  contract_file="${STATE_ROOT}/${SESSION_ID}/discovered_scope.jsonl"
  assert_eq "${unsuccessful_verdict} without JSON records one contract violation" "1" \
    "$(jq -s 'length' "${contract_file}" 2>/dev/null || printf '0')"
  assert_contains "${unsuccessful_verdict} violation explains non-empty JSON requirement" \
    'valid non-empty FINDINGS_JSON' "$(jq -s -r '.[0].summary // ""' "${contract_file}" 2>/dev/null || true)"
done

new_session "incomplete-json"
coverage init "$(one_primary_payload "custom-incomplete")" >/dev/null
dispatch "custom-incomplete" "[council:primary] malformed structured result" >/dev/null
return_agent "custom-incomplete" $'FINDINGS_JSON: [{}]\nVERDICT: FINDINGS (1)'
incomplete_file="${STATE_ROOT}/${SESSION_ID}/discovered_scope.jsonl"
assert_eq "structurally incomplete FINDINGS_JSON produces one violation placeholder" "1" \
  "$(jq -s 'length' "${incomplete_file}" 2>/dev/null || printf '0')"
assert_contains "incomplete object is not normalized into an empty finding" \
  'valid non-empty FINDINGS_JSON' "$(jq -s -r '.[0].summary // ""' "${incomplete_file}" 2>/dev/null || true)"

printf 'Current-objective custom provenance:\n'
new_session "stale-return"
coverage init "$(one_primary_payload "custom-auditor")" >/dev/null
dispatch "custom-auditor" "[council:primary] current custom audit" >/dev/null
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
jq '.last_user_prompt_ts="101" | .prompt_revision="2"' "${state_file}" >"${state_file}.tmp"
mv "${state_file}.tmp" "${state_file}"
return_agent "custom-auditor" $'Native prose only\nVERDICT: FINDINGS (1)'
assert_missing "stale Council completion does not record a current return" \
  "${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
assert_missing "stale Council completion does not impose the custom contract" \
  "${STATE_ROOT}/${SESSION_ID}/discovered_scope.jsonl"
return_agent "custom-auditor" $'Later manual prose\nVERDICT: FINDINGS (1)'
assert_missing "later manual completion does not inherit Council provenance" \
  "${STATE_ROOT}/${SESSION_ID}/discovered_scope.jsonl"

printf 'Reviewer duplicate guard uses its non-evicting start ledger:\n'
new_session "reviewer-starts"
printf '%s\n' '{"agent_type":"quality-reviewer","ts":1}' \
  > "${STATE_ROOT}/${SESSION_ID}/agent_dispatch_starts.jsonl"
for i in $(seq 1 40); do
  jq -nc --arg i "${i}" '{agent_type:("ordinary-"+$i),ts:1}'
done > "${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
reviewer_denied="$(dispatch "quality-reviewer" "review current diff")"
assert_contains "ordinary fan-out cannot evict duplicate-reviewer evidence" \
  '"permissionDecision":"deny"' "${reviewer_denied}"

printf 'Phase 8 protocol keeps semantic review in the frozen batch:\n'
council_skill="$(cat "${REPO_ROOT}/bundle/dot-claude/skills/council/SKILL.md")"
router_source="$(cat "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh")"
assert_contains "Council skill batches every preselected semantic specialist" \
  'all already-selected semantic risk specialists in the same concurrent frozen-revision batch' \
  "${council_skill}"
assert_contains "Council skill reserves later specialist calls for real invalidation" \
  'genuinely new evidence or an invalidated risk-map premise' "${council_skill}"
assert_contains "Council skill marks every frozen dispatch for the pending-row producer" \
  'Prefix **every** Agent description in this settled batch with the exact machine marker `[review-batch]`' \
  "${council_skill}"
assert_contains "Council skill passes an assessed risk to the resolver" \
  '--risk "${MODEL_RISK}"' "${council_skill}"
assert_contains "Council skill gives uncertain assessments an explicit high floor" \
  '`UNCERTAINTY_MODE` always sets `MODEL_RISK=high`' "${council_skill}"
assert_contains "Council skill preserves independent deep escalation" \
  '`DEEP_MODE` still passes the helper' "${council_skill}"
assert_contains "Council skill states a convenient medium default" \
  '`medium` — the default when the assessment needs material judgment' "${council_skill}"
assert_not_contains "Council skill does not price every direct run as high risk" \
  '--risk high' "${council_skill}"
assert_contains "prompt router mirrors the frozen semantic batch" \
  'all already-selected semantic risk specialists in the same concurrent frozen-revision batch' \
  "${router_source}"
assert_contains "prompt router mirrors the later-call invalidation rule" \
  'Reserve any later semantic-specialist dispatch for genuinely new evidence or an invalidated risk-map premise' \
  "${router_source}"
assert_contains "prompt router requires the exact pending-row batch marker" \
  'Prefix EVERY Agent description in this frozen batch with exact \`[review-batch]\`' \
  "${router_source}"

printf '\n=== Council Coverage Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
