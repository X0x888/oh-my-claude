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

assert_missing() {
  local label="$1" path="$2"
  if [[ ! -s "${path}" ]]; then ok; else bad "${label} (${path} was non-empty)"; fi
}

new_session() {
  SESSION_ID="$1"
  export SESSION_ID
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  printf '%s\n' \
    '{"last_user_prompt_ts":"100","prompt_revision":"1","workflow_mode":"ultrawork"}' \
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
  local agent="$1" message="${2:-VERDICT: CLEAN}"
  jq -nc \
    --arg session "${SESSION_ID}" \
    --arg agent "${agent}" \
    --arg message "${message}" \
    '{session_id:$session,agent_type:$agent,last_assistant_message:$message}' \
    | OMC_DISCOVERED_SCOPE=on bash "${HOOK_DIR}/record-subagent-summary.sh"
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
assert_missing "new objective drops obsolete Council pending provenance" \
  "${STATE_ROOT}/${SESSION_ID}/pending_agents.jsonl"
fresh_identity="$(dispatch "alpha:auditor" "[council:primary] fresh objective")"
assert_eq "interrupted prior objective does not reserve the fresh identity" "" "${fresh_identity}"
return_agent "alpha:auditor"

printf 'Reconciliation, gap-fill, and completion lifecycle:\n'
new_session "lifecycle"
base="$(one_primary_payload "alpha:auditor")"
coverage init "${base}" >/dev/null
premature_gap="$(dispatch "beta:data-auditor" "[council:gap-fill] before primary reconciliation")"
assert_contains "gap-fill before post-primary generation is denied" '"permissionDecision":"deny"' "${premature_gap}"
if coverage complete >/dev/null 2>&1; then bad "complete accepted an unreconciled primary"; else ok; fi

primary_complete="$(printf '%s' "${base}" | jq '.reconciliation={
  status:"primary-complete",evidence:"primary return reconciled",primary_returns:["alpha:auditor"],gap_fill_returns:[],
  coverage_results:[{coverage_id:"security",status:"evidenced",evidence:"return grounded the row",reason:"no residual hole"}]
}')"
if coverage update "${primary_complete}" >/dev/null 2>&1; then bad "update accepted before the selected primary returned"; else ok; fi
dispatch "alpha:auditor" "[council:primary] inspect trust" >/dev/null
return_agent "alpha:auditor"

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
coverage complete >/dev/null
state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
assert_eq "complete is the handoff producer" "1" "$(jq -r '.council_assessment_ready' "${state_file}")"
assert_eq "completion records its prompt revision" "1" "$(jq -r '.council_assessment_prompt_revision' "${state_file}")"

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
return_agent "verifier-one"
returns_file="${STATE_ROOT}/${SESSION_ID}/council_returns.jsonl"
assert_eq "verification return is recorded with phase provenance" "verification" \
  "$(jq -s -r '[.[] | select(.actual_agent == "verifier-one")][0].council_phase' "${returns_file}")"
assert_eq "verification return keeps the objective revision" "1" \
  "$(jq -s -r '[.[] | select(.actual_agent == "verifier-one")][0].objective_prompt_revision' "${returns_file}")"
duplicate_verifier="$(dispatch "verifier-one" "[council:verification] duplicate identity")"
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

printf '\n=== Council Coverage Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
