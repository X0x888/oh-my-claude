#!/usr/bin/env bash
# Focused behavioral tests for the Definition of Excellent decision module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d -t omc-quality-contract-XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export STATE_ROOT="${TEST_ROOT}/state"
export SESSION_ID="quality-contract-test"
mkdir -p "${HOME}/.claude" "${STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/lib/quality-contract.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-contract.sh"

# The production router always publishes an explicit Constitution state before
# a planner can freeze a contract. This unit fixture exercises the disabled
# (baseline-only) branch until a focused profile-binding test opts into current.
ensure_session_dir
write_state "quality_constitution_status" "disabled"

pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_success() {
  local label="$1"
  shift
  if "$@" >/dev/null; then ok; else bad "${label} (expected success)"; fi
}

assert_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "${label} (expected failure)"; else ok; fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    ok
  else
    printf '  FAIL: %s: expected=<%s> actual=<%s>\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

printf 'Authority digests fail closed without SHA-256\n'
no_sha_dir="${TEST_ROOT}/no-sha-bin"
mkdir -p "${no_sha_dir}"
observer_safe_before="${_OMC_OBSERVER_SAFE_PATH}"
_OMC_OBSERVER_SAFE_PATH="${no_sha_dir}"
assert_failure "contract digest rejects a host with no SHA-256 tool" \
  _quality_contract_digest "definition-authority"
assert_failure "verification command receipt digest rejects no SHA-256" \
  verification_receipt_command_digest "Bash" "bash tests/run.sh"
assert_failure "sealed verification receipt ID rejects no SHA-256" \
  _quality_contract_receipt_expected_id \
  '{"tool_use_id":"tool","tool_name":"Bash","input_digest":"input"}'
_OMC_OBSERVER_SAFE_PATH="${observer_safe_before}"

definition_json() {
  jq -cn '
    {
      north_star:"Ship a durable outcome whose quality is independently demonstrable",
      audience:"Maintainers and real users relying on the finished system",
      stakes:"A shallow or generic result would preserve the exact babysitting failure",
      ambition_boundary:"Pursue the strongest defensible version without inventing unrelated product scope",
      axes:{
        deliberate:"Every material choice has an explicit rationale and tested tradeoff",
        distinctive:"The result reflects this project and avoids interchangeable generic defaults",
        visionary:"A credible step-change version is considered and tested against the repair-only baseline",
        coherent:"Code, interaction, documentation, and proof express one consistent design",
        complete:"Explicit scope, sibling scope, edge paths, operations, and verification are reconciled"
      },
      standards:[
        {kind:"user",reference:"Current user objective",rationale:"The current explicit direction is the highest-authority quality standard"},
        {kind:"repo",reference:"AGENTS.md project contracts",rationale:"Repository-native causal and verification invariants must remain intact"}
      ],
      anti_goals:["Do not turn quality into adjectives or a self-certified checklist"],
      criteria:[
        {id:"Q-005",class:"must",axis:"complete",claim:"Every required and adjacent surface is reconciled",rationale:"Silent sibling omissions are the primary completeness failure",surfaces:["delivery"],proof_method:"Run the broad project suite with the complete criterion target",proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],command_contains:["tests/test-stop-dispatch.sh","Q-005"],artifact_contains:[]},failure_signal:"Any required surface is missing, stale, or silently deferred",tradeoff_boundary:"External blockers may pause work but effort alone may not",evidence_policy:{allowed_kinds:["test","inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-003",class:"must",axis:"visionary",claim:"The strongest credible step-change candidate is empirically tested",rationale:"Repair-only thinking cannot establish a frontier quality bar",surfaces:["product frontier"],proof_method:"Benchmark the Q-003 step-change candidate against the baseline",proof_spec:{receipt_kinds:["benchmark"],tool_names:["Bash"],command_contains:["tests/test-stricter-verdict-wins.sh","Q-003","benchmark"],artifact_contains:[]},failure_signal:"No candidate leap was generated or the comparison is purely rhetorical",tradeoff_boundary:"Reject a candidate only after measured counterevidence",evidence_policy:{allowed_kinds:["benchmark","comparison","render"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-001",class:"must",axis:"deliberate",claim:"Material decisions expose rationale and falsifiable tradeoffs",rationale:"Unexplained defaults are accidental rather than deliberate",surfaces:["architecture"],proof_method:"Inspect the Q-001 decision record against implementation",proof_spec:{receipt_kinds:["inspection"],tool_names:["Grep"],command_contains:["Q-001"],artifact_contains:["AGENTS.md"]},failure_signal:"A material choice lacks rationale or contradicts its stated constraint",tradeoff_boundary:"Concise rationale is sufficient when the decision is reversible",evidence_policy:{allowed_kinds:["inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-004",class:"must",axis:"coherent",claim:"All changed surfaces express one consistent system design",rationale:"Local quality can still produce an incoherent whole",surfaces:["integration"],proof_method:"Run the Q-004 end-to-end causal integration trace",proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],command_contains:["tests/test-e2e-hook-sequence.sh","Q-004"],artifact_contains:[]},failure_signal:"Any consumer contradicts the shared contract or design language",tradeoff_boundary:"Compatibility adapters may differ only when their boundary is explicit",evidence_policy:{allowed_kinds:["inspection","test"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-002",class:"must",axis:"distinctive",claim:"The delivered form is specific to this project and audience",rationale:"Generic defaults cannot demonstrate veteran product judgment",surfaces:["experience"],proof_method:"Inspect the Q-002 anti-generic project experience evidence",proof_spec:{receipt_kinds:["inspection"],tool_names:["Grep"],command_contains:["Q-002"],artifact_contains:["README.md"]},failure_signal:"The result could be transplanted unchanged into an unrelated project",tradeoff_boundary:"Novelty without user value is not distinctiveness",evidence_policy:{allowed_kinds:["render","inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-006",class:"aspiration",axis:"visionary",claim:"A reversible follow-on leap remains explicitly evaluated",rationale:"The frontier should record ambitious options without making novelty mandatory",surfaces:["future experiment"],proof_method:"Compare the Q-006 reversible option with the shipped baseline",proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],command_contains:["tests/test-definition-of-excellent-e2e.sh","Q-006","comparison"],artifact_contains:[]},failure_signal:"The option is asserted without a measurable user benefit",tradeoff_boundary:"The aspiration may not delay proven mandatory criteria",evidence_policy:{allowed_kinds:["comparison"],minimum:1,requires_empirical:true,requires_independent_review:true}}
      ]
    }
  '
}

build_contract() {
  local definition objective_digest
  definition="$(definition_json)"
  objective_digest="$(_quality_contract_digest \
    'Build the full Definition of Excellent engine')"
  quality_contract_build_envelope "${definition}" 7 100 3 \
    "${objective_digest}" "generation-1" 1 110 \
    "quality-planner" "native-planner-1" "dispatch-planner-12345678" 1
}

write_current_profile_snapshot() {
  local statement="$1" generation="$2" observations="${3:-[]}"
  local profile_file="$4" recorded_reference_digest="${5:-}"
  local profile_digest reference_digest effective_digest snapshot_file profile_id
  local blocking_claim selectors
  profile_id="${profile_file%/*}"
  profile_id="${profile_id##*/}"
  mkdir -p "${profile_file%/*}"
  jq -cnS --arg statement "${statement}" --argjson generation "${generation}" \
    --arg recorded "${recorded_reference_digest}" --arg profile_id "${profile_id}" '
      {schema_version:1,profile_id:$profile_id,
       display_name:"Quality contract test",generation:$generation,
       claims:[{id:"qc_taste_blocking_1",category:"quality_floor",
         statement:$statement,rationale:"Pinned test quality floor",
         polarity:"must",enforcement:"blocking",authority:"user_pinned",
         status:"active",scope:{domains:[],task_types:[],surfaces:[],audiences:[],paths:[]},
         evidence_ids:[],created_at:1,last_supported_at:1,review_after:9999999999}],
       references:(if $recorded == "" then [] else
         [{id:"qr_contract_1",polarity:"exemplar",kind:"repo_path",
           locator:"exemplar.txt",because:"Pinned causal exemplar",
           aspects:"proof shape",do_not_copy:"incidental wording",
           authority:"user_confirmed",status:"active",added_at:1,
           content_digest:$recorded}] end)}' >"${profile_file}"
  profile_digest="$(_quality_contract_sha256_canonical_json_file "${profile_file}")"
  blocking_claim="$(jq -c '.claims[0]' "${profile_file}")"
  selectors='{"audience":"","domain":"coding","path":"","surface":"","task_type":"implementation"}'
  reference_digest="$(_quality_contract_sha256_canonical_json_text "${observations}")"
  effective_digest="$(_quality_contract_effective_constitution_digest \
    "${profile_digest}" "${reference_digest}")"
  snapshot_file="$(session_file quality_constitution_snapshot.json)"
  jq -cnS --arg profile_path "${profile_file}" --arg statement "${statement}" \
    --argjson generation "${generation}" --arg digest "${effective_digest}" \
    --arg profile_digest "${profile_digest}" \
    --arg reference_digest "${reference_digest}" \
    --arg profile_id "${profile_id}" \
    --argjson blocking_claim "${blocking_claim}" \
    --argjson observations "${observations}" '
      {schema_version:1,profile_exists:true,profile_path:$profile_path,
       profile_id:$profile_id,display_name:"Quality contract test",
       role:"planner",selectors:{domain:"coding",task_type:"implementation",
         surface:"",audience:"",path:""},generation:$generation,
       digest:$digest,profile_digest:$profile_digest,
       reference_integrity_digest:$reference_digest,
       blocking_claims:[$blocking_claim],
       advisory_claims:[],tentative_claims:[],references:[],
       quarantined_references:[],reference_observations:$observations,
       omitted:{claims:0,scope_filtered_claims:0,references:0}}' >"${snapshot_file}"
  write_state_batch \
    "quality_constitution_status" "current" \
    "quality_constitution_generation" "${generation}" \
    "quality_constitution_digest" "${effective_digest}" \
    "quality_constitution_blocking_ids" '["qc_taste_blocking_1"]' \
    "quality_constitution_selectors" "${selectors}"
}

seed_current_state() {
  local contract="$1"
  ensure_session_dir
  write_state_batch \
    "quality_contract_required" "1" \
    "quality_contract_id" "$(jq -r '.contract_id' <<<"${contract}")" \
    "quality_contract_revision" "$(jq -r '.contract_revision' <<<"${contract}")" \
    "quality_contract_cycle_id" "7" \
    "quality_contract_plan_revision" "1" \
    "quality_contract_prompt_revision" "3" \
    "quality_contract_late" "0" \
    "quality_contract_recheck_required" "" \
    "review_cycle_id" "7" \
    "review_cycle_prompt_ts" "100" \
    "current_objective" "Build the full Definition of Excellent engine" \
    "ulw_enforcement_generation" "generation-1" \
    "plan_revision" "1" \
    "edit_revision" "0" \
    "last_code_edit_revision" "0" \
    "last_verify_code_revision" "0" \
    "last_edit_ts" "115" \
    "last_verify_ts" "120" \
    "last_verify_outcome" "passed" \
    "last_verify_confidence" "80"
  printf '%s\n' "${contract}" >"$(session_file quality_contract.json)"
}

valid_review() {
  jq -cn '
    {
      criteria:[
        {id:"Q-001",status:"met",evidence_kind:"inspection",basis:"Rationale and tradeoffs match the implementation",refs:["vr-proof-001"]},
        {id:"Q-002",status:"met",evidence_kind:"inspection",basis:"The result is demonstrably project-specific",refs:["vr-proof-002"]},
        {id:"Q-003",status:"met",evidence_kind:"benchmark",basis:"The step-change candidate beat the baseline",refs:["vr-proof-003"]},
        {id:"Q-004",status:"met",evidence_kind:"test",basis:"All consumer surfaces share one causal contract",refs:["vr-proof-004"]},
        {id:"Q-005",status:"met",evidence_kind:"test",basis:"The objective matrix and broad suite are complete",refs:["vr-proof-005"]},
        {id:"Q-006",status:"met",evidence_kind:"comparison",basis:"The reversible follow-on was compared without delaying the mandatory floor",refs:["vr-proof-006"]}
      ],
      alternatives_searched:[
        "Compared a checklist-only gate and rejected it because it preserved self-certification",
        "Compared a causal contract plus blind frontier and selected it on replay resistance"
      ],
      limits:["Production traffic behavior remains outside this local review"],
      frontier:{material:false,bar_quality:"strong",title:"No remaining material dominating improvement",why:"The strongest in-scope candidate was measured and no longer dominates",recommended_move:"Ship the causally certified implementation",criterion_ids:[],evidence:["vr-proof-003"],experiment:"Compared the strongest candidate with the current implementation"}
    }
  '
}

fixture_receipt_with_proof_identity() {
  local contract="$1" receipt="$2"
  local tool command artifact method edit_revision plan_revision command_digest
  local proof_tool proof_target project_test_cmd proof_identity
  local launcher_path="" launcher_digest="" launcher_identity=""
  local subject_path="" subject_digest="" subject_identity="" receipt_id=""
  local tool_cwd=""
  tool="$(jq -r '.tool_name' <<<"${receipt}")"
  command="$(jq -r '.command' <<<"${receipt}")"
  artifact="$(jq -r '.artifact_target' <<<"${receipt}")"
  method="$(jq -r '.method' <<<"${receipt}")"
  edit_revision="$(jq -r '.edit_revision' <<<"${receipt}")"
  plan_revision="$(jq -r '.plan_revision' <<<"${receipt}")"
  proof_tool="${tool}"
  proof_target="${command}"
  tool_cwd="$(_verification_normalize_proof_path "${REPO_ROOT}")"
  command_digest="$(verification_receipt_command_digest \
    "${command}" "${tool}")"
  receipt="$(jq -c --arg command_digest "${command_digest}" \
    '.command_digest=$command_digest' <<<"${receipt}")"
  case "${tool}" in
    Bash)
      launcher_path="$(verification_command_launcher_path \
        "${command}" 2>/dev/null || true)"
      launcher_digest="$(_verification_sha256_file \
        "${launcher_path}" 2>/dev/null || true)"
      launcher_identity="$(_verification_file_identity \
        "${launcher_path}" 2>/dev/null || true)"
      subject_path="$(verification_command_subject_path \
        "${command}" "${tool_cwd}" 2>/dev/null || true)"
      [[ -n "${subject_path}" ]] || subject_path="${launcher_path}"
      subject_digest="$(_verification_sha256_file \
        "${subject_path}" 2>/dev/null || true)"
      subject_identity="$(_verification_file_identity \
        "${subject_path}" "${tool_cwd}" 2>/dev/null || true)"
      receipt="$(jq -c \
        --arg launcher_path "${launcher_path}" \
        --arg launcher_digest "${launcher_digest}" \
        --arg launcher_identity "${launcher_identity}" \
        --arg subject_path "${subject_path}" \
        --arg subject_digest "${subject_digest}" \
        --arg subject_identity "${subject_identity}" \
        --arg tool_cwd "${tool_cwd}" '
          .launcher_path=$launcher_path
          | .launcher_digest=$launcher_digest
          | .launcher_identity=$launcher_identity
          | .subject_path=$subject_path
          | .subject_digest=$subject_digest
          | .subject_identity=$subject_identity
          | .tool_cwd=$tool_cwd
        ' <<<"${receipt}")"
      project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
      [[ -n "${project_test_cmd}" ]] \
        || project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
      proof_target="$(verification_command_semantic_target \
        "${command}" "${project_test_cmd}")"
      ;;
    Grep)
      subject_path="${artifact}"
      subject_digest="$(_verification_sha256_file \
        "${subject_path}" 2>/dev/null || true)"
      subject_identity="$(_verification_file_identity \
        "${subject_path}" "${tool_cwd}" 2>/dev/null || true)"
      receipt="$(jq -c \
        --arg subject_path "${subject_path}" \
        --arg subject_digest "${subject_digest}" \
        --arg subject_identity "${subject_identity}" \
        --arg tool_cwd "${tool_cwd}" '
          .subject_path=$subject_path
          | .subject_digest=$subject_digest
          | .subject_identity=$subject_identity
          | .tool_cwd=$tool_cwd
        ' <<<"${receipt}")"
      ;;
    mcp__*)
      proof_tool="${method}"
      proof_target="mcp:${method#mcp_}:${artifact:-untargeted}"
      ;;
  esac
  proof_identity="$(_quality_contract_expected_proof_identity \
    "${proof_tool}" "${proof_target}" "${artifact}" "${contract}" \
    "${edit_revision}" "${plan_revision}")"
  receipt="$(jq -c --arg proof_identity "${proof_identity}" \
    '.proof_identity=$proof_identity' <<<"${receipt}")"
  receipt_id="$(_quality_contract_receipt_expected_id "${receipt}")"
  jq -c --arg receipt_id "${receipt_id}" \
    '.receipt_id=$receipt_id' <<<"${receipt}"
}

reseal_receipt_ledger() {
  local ledger="$1" tmp receipt receipt_id
  tmp="$(mktemp "${ledger}.reseal.XXXXXX")" || return 1
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    receipt_id="$(_quality_contract_receipt_expected_id "${receipt}")" \
      || { rm -f "${tmp}"; return 1; }
    jq -c --arg receipt_id "${receipt_id}" \
      '.receipt_id=$receipt_id' <<<"${receipt}" >>"${tmp}" \
      || { rm -f "${tmp}"; return 1; }
  done <"${ledger}"
  mv -f "${tmp}" "${ledger}"
}

write_receipts() {
  local contract="$1" edit_revision="${2:-0}" aspiration_result="${3:-passed}"
  local id rev cycle canonical_agents canonical_readme receipts receipt
  id="$(jq -r '.contract_id' <<<"${contract}")"
  rev="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  canonical_agents="$(_verification_normalize_proof_path "${REPO_ROOT}/AGENTS.md")"
  canonical_readme="$(_verification_normalize_proof_path "${REPO_ROOT}/README.md")"
  receipts="$(jq -cn \
    --arg id "${id}" --argjson rev "${rev}" --argjson cycle "${cycle}" \
    --argjson edit "${edit_revision}" \
    --arg agents "${canonical_agents}" --arg readme "${canonical_readme}" \
    --arg aspiration_result "${aspiration_result}" '
    def row($n;$tool;$command;$kind;$artifact;$outcome):
      {_v:3,receipt_id:("vr-proof-"+$n),tool_use_id:("tool-proof-"+$n),
       tool_name:$tool,input_digest:("input-digest-"+$n),command:$command,
       command_digest:("command-digest-"+$n),outcome:$outcome,confidence:90,
       method:(if $tool == "Bash" then "project_test_command" else "source_inspection" end),
       scope:(if $tool == "Bash" then "full" else "workspace_source" end),
       evidence_kind:$kind,result:(if $outcome == "passed" then "1 passed" else "1 failed" end),
       result_digest:("result-digest-"+$n),artifact_target:$artifact,
       artifact_digest:(if $artifact == "" then "" else ("artifact-digest-"+$n) end),
       launcher_path:"",launcher_digest:"",launcher_identity:"",
       subject_path:"",subject_digest:"",subject_identity:"",
       tool_cwd:"",proof_identity:"vp-placeholder-proof",
       edit_revision:$edit,code_revision:0,
       plan_revision:1,review_cycle_id:$cycle,quality_contract_id:$id,
       quality_contract_revision:$rev,ts:190};
    [row("001";"Grep";("Grep:"+$agents+":Q-001");"inspection";$agents;"passed"),
     row("002";"Grep";("Grep:"+$readme+":Q-002");"inspection";$readme;"passed"),
     row("003";"Bash";"bash tests/test-stricter-verdict-wins.sh --criterion Q-003 --benchmark";"benchmark";"";"passed"),
     row("004";"Bash";"bash tests/test-e2e-hook-sequence.sh --criterion Q-004";"test";"";"passed"),
     row("005";"Bash";"bash tests/test-stop-dispatch.sh --criterion Q-005";"test";"";"passed"),
     row("006";"Bash";"bash tests/test-definition-of-excellent-e2e.sh --criterion Q-006 --comparison";"comparison";"";$aspiration_result)]
    | .[]
  ')"
  : >"$(session_file verification_receipts.jsonl)"
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    fixture_receipt_with_proof_identity "${contract}" "${receipt}"
  done <<<"${receipts}" >>"$(session_file verification_receipts.jsonl)"
  QUALITY_RECEIPT_001="$(jq -r \
    'select(.tool_use_id == "tool-proof-001") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
  QUALITY_RECEIPT_002="$(jq -r \
    'select(.tool_use_id == "tool-proof-002") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
  QUALITY_RECEIPT_003="$(jq -r \
    'select(.tool_use_id == "tool-proof-003") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
  QUALITY_RECEIPT_004="$(jq -r \
    'select(.tool_use_id == "tool-proof-004") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
  QUALITY_RECEIPT_005="$(jq -r \
    'select(.tool_use_id == "tool-proof-005") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
  QUALITY_RECEIPT_006="$(jq -r \
    'select(.tool_use_id == "tool-proof-006") | .receipt_id' \
    "$(session_file verification_receipts.jsonl)")"
}

append_current_receipt() {
  local contract="$1" edit_revision="$2" suffix="$3" command="$4"
  local kind="$5" outcome="$6" ts="$7" confidence="${8:-90}"
  local tool="${9:-Bash}" artifact="${10:-}"
  local receipt
  receipt="$(jq -cn \
    --arg id "$(jq -r '.contract_id' <<<"${contract}")" \
    --argjson rev "$(jq -r '.contract_revision' <<<"${contract}")" \
    --argjson cycle "$(jq -r '.review_cycle_id' <<<"${contract}")" \
    --argjson edit "${edit_revision}" --arg suffix "${suffix}" \
    --arg command "${command}" --arg kind "${kind}" \
    --arg outcome "${outcome}" --argjson ts "${ts}" \
    --argjson confidence "${confidence}" --arg tool "${tool}" \
    --arg artifact "${artifact}" '
      {_v:3,receipt_id:("vr-proof-"+$suffix),tool_use_id:("tool-proof-"+$suffix),
       tool_name:$tool,input_digest:("input-digest-"+$suffix),command:$command,
       command_digest:("command-digest-"+$suffix),outcome:$outcome,confidence:$confidence,
       method:(if $tool == "Bash" then "project_test_command" else "source_inspection" end),
       scope:(if $tool == "Bash" then "full" else "workspace_source" end),
       evidence_kind:$kind,
       result:(if $outcome == "passed" then "1 passed" else "1 failed" end),
       result_digest:("result-digest-"+$suffix),artifact_target:$artifact,
       artifact_digest:(if $artifact == "" then "" else ("artifact-digest-"+$suffix) end),
       launcher_path:"",launcher_digest:"",launcher_identity:"",
       subject_path:"",subject_digest:"",subject_identity:"",
       tool_cwd:"",proof_identity:"vp-placeholder-proof",
       edit_revision:$edit,code_revision:0,
       plan_revision:1,review_cycle_id:$cycle,quality_contract_id:$id,
       quality_contract_revision:$rev,ts:$ts}
  ')"
  fixture_receipt_with_proof_identity "${contract}" "${receipt}" \
    >>"$(session_file verification_receipts.jsonl)"
}

write_evidence() {
  local contract="$1" edit_revision="${2:-0}" visionary_basis="${3:-The benchmarked frontier candidate improved the baseline}"
  local aspiration_result="${4:-passed}"
  local id rev cycle
  id="$(jq -r '.contract_id' <<<"${contract}")"
  rev="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  write_receipts "${contract}" "${edit_revision}" "${aspiration_result}"
  jq -cn \
    --arg id "${id}" --argjson rev "${rev}" --argjson cycle "${cycle}" \
    --argjson edit "${edit_revision}" --arg visionary_basis "${visionary_basis}" \
    --arg aspiration_result "${aspiration_result}" \
    --arg r1 "${QUALITY_RECEIPT_001}" --arg r2 "${QUALITY_RECEIPT_002}" \
    --arg r3 "${QUALITY_RECEIPT_003}" --arg r4 "${QUALITY_RECEIPT_004}" \
    --arg r5 "${QUALITY_RECEIPT_005}" --arg r6 "${QUALITY_RECEIPT_006}" '
    def row($n;$criterion;$axis;$class;$kind;$claim;$reference):
      {_v:1,contract_id:$id,contract_revision:$rev,review_cycle_id:$cycle,
       criterion_id:$criterion,axis:$axis,class:$class,
       evidence_id:("qe-"+$n),receipt_id:$reference,result:"passed",
       evidence_kind:$kind,claim:$claim,reference:$reference,
       edit_revision:$edit,plan_revision:1,reviewed_at:200,
       reviewer:"excellence-reviewer",native_agent_id:"native-reviewer-1",
       lifecycle_dispatch_id:"dispatch-reviewer-12345678"};
    [row("001";"Q-001";"deliberate";"must";"inspection";"Decision records match the implementation";$r1),
     row("002";"Q-002";"distinctive";"must";"inspection";"Project-specific anti-generic inspection passed";$r2),
     row("003";"Q-003";"visionary";"must";"benchmark";$visionary_basis;$r3),
     row("004";"Q-004";"coherent";"must";"test";"End-to-end integration trace passed";$r4),
     row("005";"Q-005";"complete";"must";"test";"Objective and sibling-scope matrix reconciled";$r5),
     row("006";"Q-006";"visionary";"aspiration";"comparison";"Reversible follow-on compared with the baseline";$r6)]
    | map(if .criterion_id == "Q-006" then .result = $aspiration_result else . end)
    | .[]
  ' >"$(session_file quality_evidence.jsonl)"
}

write_frontier() {
  local contract="$1" edit_revision="${2:-0}" status="${3:-clear}"
  local dominates=false materiality="none" evidence_ids receipt_ids
  [[ "${status}" == "clear" ]] || { dominates=true; materiality="medium"; }
  evidence_ids="$(jq -sc '[.[].evidence_id]' "$(session_file quality_evidence.jsonl)")"
  receipt_ids="$(jq -sc '[.[].receipt_id] | unique' \
    "$(session_file quality_evidence.jsonl)")"
  jq -cn \
    --arg id "$(jq -r '.contract_id' <<<"${contract}")" \
    --argjson rev "$(jq -r '.contract_revision' <<<"${contract}")" \
    --argjson cycle "$(jq -r '.review_cycle_id' <<<"${contract}")" \
    --argjson edit "${edit_revision}" --arg status "${status}" \
    --arg materiality "${materiality}" --argjson dominates "${dominates}" \
    --argjson evidence_ids "${evidence_ids}" \
    --argjson receipt_ids "${receipt_ids}" '
    {_v:1,contract_id:$id,contract_revision:$rev,review_cycle_id:$cycle,
     edit_revision:$edit,plan_revision:1,status:$status,materiality:$materiality,
     dominates_current:$dominates,
     title:(if $dominates then "A stronger visionary candidate remains" else "No material candidate dominates" end),
     why:(if $dominates then "The measured reversible leap remains inside the frozen ambition boundary" else "The strongest candidate was compared and no longer dominates" end),
     recommended_move:(if $dominates then "Implement and benchmark the bounded candidate" else "Ship the causally certified result" end),
     criterion_ids:(if $dominates then ["Q-006"] else [] end),
     evidence_ids:$evidence_ids,evidence:$receipt_ids,
     experiment:"Compared the strongest in-scope candidate against the baseline",
     alternatives_searched:["Compared the bounded reversible leap against the baseline","Compared the causal contract against a checklist-only gate"],
     limits:["Production traffic behavior remains outside this local review"],
     reviewed_at:200,reviewer:"excellence-reviewer",
     native_agent_id:"native-reviewer-1",
     lifecycle_dispatch_id:"dispatch-reviewer-12345678"}
  ' >"$(session_file quality_frontier.json)"
}

printf 'Test 1: adaptive arming and Zero Steering promotion\n'
assert_success "medium-risk execution arms" quality_contract_should_arm adaptive execution medium 0 0
assert_failure "low-risk narrow work stays compact" quality_contract_should_arm adaptive execution low 0 0
assert_success "explicit perfection mandate arms" quality_contract_should_arm adaptive execution low 0 1
assert_failure "advisory never arms" quality_contract_should_arm always advisory high 1 1
OMC_QUALITY_POLICY=zero_steering
assert_success "Zero Steering promotes adaptive" quality_contract_should_arm adaptive execution low 0 0
OMC_QUALITY_POLICY=balanced
assert_failure "off remains explicit user escape" quality_contract_should_arm off execution high 1 1

printf 'Test 2: mandatory five-axis contract validation and canonicalization\n'
definition="$(definition_json)"
assert_success "valid five-axis definition" quality_contract_validate_payload "${definition}"
unreachable_read_anchor="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["source"],tool_names:["Read"],
     command_contains:["Q-UNREACHABLE"],artifact_contains:["AGENTS.md"]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) =
    ["source"]
' <<<"${definition}")"
assert_failure "Read proof rejects command text absent from its persisted shape" \
  quality_contract_validate_payload "${unreachable_read_anchor}"
long_grep_anchor="$(printf 'x%.0s' {1..130})"
truncated_grep_anchor="$(jq --arg token "${long_grep_anchor}" '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) =
    [$token]
' <<<"${definition}")"
assert_failure "Grep proof rejects pattern language truncated by the recorder" \
  quality_contract_validate_payload "${truncated_grep_anchor}"
invalid_grep_regex="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["["]
' <<<"${definition}")"
assert_failure "Grep proof rejects an invalid constructed regex" \
  quality_contract_validate_payload "${invalid_grep_regex}"
duplicate_source_target="$(jq '.criteria += [{
  id:"Q-007",class:"aspiration",axis:"visionary",
  claim:"A second source criterion inspects the same physical artifact",
  rationale:"One physical observation cannot establish independent criteria",
  surfaces:["duplicate source"],proof_method:"Inspect the same AGENTS source",
  proof_spec:{receipt_kinds:["inspection"],tool_names:["Grep"],
    command_contains:["Q-007"],artifact_contains:["AGENTS.md"]},
  failure_signal:"The observation is not independent",
  tradeoff_boundary:"Distinct prose cannot manufacture a proof identity",
  evidence_policy:{allowed_kinds:["inspection"],minimum:1,
    requires_empirical:true,requires_independent_review:true}}]
' <<<"${definition}")"
assert_failure "duplicate Grep source targets are rejected during freeze" \
  quality_contract_validate_payload "${duplicate_source_target}"
distinct_source_tools="$(jq '.criteria += [{
  id:"Q-007",class:"aspiration",axis:"visionary",
  claim:"A direct source read remains independently inspectable",
  rationale:"Read and Grep are distinct observation methods",
  surfaces:["source read"],proof_method:"Read the frozen Definition source",
  proof_spec:{receipt_kinds:["source"],tool_names:["Read"],
    command_contains:["Read:","docs/definition-of-excellent.md"],artifact_contains:["docs/definition-of-excellent.md"]},
  failure_signal:"The source cannot be read",
  tradeoff_boundary:"The read may not replace the targeted grep criterion",
  evidence_policy:{allowed_kinds:["source"],minimum:1,
    requires_empirical:true,requires_independent_review:true}}]
' <<<"${definition}")"
assert_success "Read and Grep retain distinct source proof identities" \
  quality_contract_validate_payload "${distinct_source_tools}"
oversized_read_contract="$(jq '
  (.criteria[] | select(.id == "Q-007") | .proof_spec.command_contains) =
    ["Read:","common.sh"]
  | (.criteria[] | select(.id == "Q-007") | .proof_spec.artifact_contains) =
    ["bundle/dot-claude/skills/autowork/scripts/common.sh"]
' <<<"${distinct_source_tools}")"
assert_failure "Read proof cannot freeze beyond the runtime whole-file limit" \
  quality_contract_validate_payload "${oversized_read_contract}"
redacted_source_command="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) =
    ["--token","abcdefghijklmnopqrst"]
' <<<"${definition}")"
assert_failure "joined source command must survive runtime secret redaction" \
  quality_contract_validate_payload "${redacted_source_command}"
order_sensitive_grep="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) =
    ["[a","0]"]
' <<<"${definition}")"
assert_success "order-sensitive Grep regex is initially feasible" \
  quality_contract_validate_payload "${order_sensitive_grep}"
canonical_order_sensitive="$(quality_contract_canonicalize_payload \
  "${order_sensitive_grep}")"
assert_success "canonical Grep contract remains feasible" \
  quality_contract_validate_payload "${canonical_order_sensitive}"
assert_eq "canonicalization preserves Grep regex anchor order" \
  '["[a","0]"]' \
  "$(jq -c '.criteria[] | select(.id == "Q-001")
    | .proof_spec.command_contains' <<<"${canonical_order_sensitive}")"
q001_source_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${definition}")"
q001_source_target="$(_quality_contract_source_target_witness \
  "${q001_source_criterion}")"
q001_source_command="$(_quality_contract_source_command_witness \
  "${q001_source_criterion}" "${q001_source_target}")"
q001_source_receipt="$(jq -cn \
  --arg command "${q001_source_command}" --arg target "${q001_source_target}" '
    {tool_name:"Grep",evidence_kind:"inspection",command:$command,
     artifact_target:$target}')"
assert_success "exact frozen Grep pattern matches its source criterion" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${q001_source_receipt}" "${q001_source_criterion}"
q001_case_changed_receipt="$(jq \
  '.command |= sub("Q-001$";"q-001")' <<<"${q001_source_receipt}")"
assert_failure "Grep pattern case cannot drift from the frozen regex" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${q001_case_changed_receipt}" "${q001_source_criterion}"
q001_broadened_receipt="$(jq \
  '.command += "|.*"' <<<"${q001_source_receipt}")"
assert_failure "broader Grep regex cannot impersonate the frozen pattern" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${q001_broadened_receipt}" "${q001_source_criterion}"
case_collision_source="${TEST_ROOT}/q-001.md"
: >"${case_collision_source}"
case_collision_target="$(_verification_normalize_proof_path \
  "${case_collision_source}" 0 source)"
case_collision_criterion="$(jq '
  .proof_spec.artifact_contains=["q-001.md"]
  | .proof_spec.command_contains=["Q-001.md"]
' <<<"${q001_source_criterion}")"
case_collision_command="$(_quality_contract_source_command_witness \
  "${case_collision_criterion}" "${case_collision_target}")"
assert_eq "case-insensitive target text cannot consume a Grep regex anchor" \
  "Grep:${case_collision_target}:Q-001.md" "${case_collision_command}"
collapsed_bash_target="$(jq '
  (.criteria[] | select(.id == "Q-004") | .proof_spec.command_contains) =
    ["tests/test-stop-dispatch.sh","Q-004"]
' <<<"${definition}")"
assert_failure "opaque criterion argv cannot split one Bash proof target" \
  quality_contract_validate_payload "${collapsed_bash_target}"
q005_criterion="$(jq -c '.criteria[] | select(.id == "Q-005")' \
  <<<"${definition}")"
borrowed_q005_receipt="$(jq -cn '{tool_name:"Bash",evidence_kind:"test",
  command:"bash tests/test-agent-verdict-contract.sh tests/test-stop-dispatch.sh Q-005",
  artifact_target:""}')"
assert_failure "raw anchor argv cannot borrow another verifier semantic target" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${borrowed_q005_receipt}" "${q005_criterion}"
legitimate_q005_receipt="$(jq -cn '{tool_name:"Bash",evidence_kind:"test",
  command:"bash tests/test-stop-dispatch.sh --criterion Q-005",
  artifact_target:""}')"
assert_success "criterion accepts its frozen semantic verifier target" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${legitimate_q005_receipt}" "${q005_criterion}"
ambiguous_pytest_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["pytest","tests/test_alpha.py"]
' <<<"${definition}")"
assert_success "structured runner outranks its directly executable selector spelling" \
  quality_contract_validate_payload "${ambiguous_pytest_target}"
ambiguous_equal_rank_targets="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["tests/test-stop-dispatch.sh","tests/test-agent-verdict-contract.sh"]
' <<<"${definition}")"
assert_failure "two equally credible verifier paths remain ambiguous" \
  quality_contract_validate_payload "${ambiguous_equal_rank_targets}"
ordered_pytest_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["pytest tests/test_alpha.py"]
' <<<"${definition}")"
assert_success "one ordered runner-selector anchor freezes a unique target" \
  quality_contract_validate_payload "${ordered_pytest_target}"
multi_selector_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=60
multi_selector_pytest="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["pytest tests/test_alpha.py tests/test_beta.py"]
' <<<"${definition}")"
assert_success "multi-selector pytest retains its full threshold-capable target" \
  quality_contract_validate_payload "${multi_selector_pytest}"
multi_selector_bin="${TEST_ROOT}/multi-selector-bin"
mkdir -p "${multi_selector_bin}"
multi_selector_bin="$(cd "${multi_selector_bin}" && pwd -P)"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${multi_selector_bin}/cargo"
chmod +x "${multi_selector_bin}/cargo"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${multi_selector_bin}/shellcheck"
chmod +x "${multi_selector_bin}/shellcheck"
validate_with_provenance_bin() (
  export PATH="${multi_selector_bin}:${PATH}"
  export _OMC_HOOK_CALLER_PATH="${PATH}"
  hash -r
  quality_contract_validate_payload "$1"
)
multi_selector_cargo="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["cargo test -p crate_a --test integration"]
' <<<"${definition}")"
if validate_with_provenance_bin \
    "${multi_selector_cargo}" >/dev/null 2>&1; then
  ok
else
  bad "multi-selector Cargo lost threshold-capable proof output"
fi
OMC_VERIFY_CONFIDENCE_THRESHOLD="${multi_selector_threshold_before}"
pytest_option_overlap="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["pytest tests/test_alpha.py"]
  | .criteria += [{id:"Q-007",class:"aspiration",axis:"complete",
      claim:"The same selected test remains independently proven with a retry option",
      rationale:"Nonsemantic runner options cannot manufacture a second observation",
      surfaces:["selected test retry"],
      proof_method:"Run the same selected test with a bounded pytest retry option",
      proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],
        command_contains:["pytest tests/test_alpha.py --maxfail=1"],
        artifact_contains:[]},
      failure_signal:"The second receipt only changes runner control options",
      tradeoff_boundary:"Use a genuinely different selector for independent proof",
      evidence_policy:{allowed_kinds:["test"],minimum:1,
        requires_empirical:true,requires_independent_review:true}}]
' <<<"${definition}")"
assert_failure "plain and unknown-option runner aliases cannot split one proof surface" \
  quality_contract_validate_payload "${pytest_option_overlap}"
silent_shellcheck_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["shellcheck bundle/dot-claude/skills/autowork/scripts/lib/verification.sh"]
' <<<"${definition}")"
assert_success "silent ShellCheck proof can freeze at its real execution floor" \
  validate_with_provenance_bin "${silent_shellcheck_target}"
silent_bash_syntax_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["bash -n bundle/dot-claude/skills/autowork/scripts/lib/verification.sh"]
' <<<"${definition}")"
assert_success "silent bash -n proof can freeze at its real execution floor" \
  quality_contract_validate_payload "${silent_bash_syntax_target}"
silent_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=50
assert_failure "silent ShellCheck proof cannot borrow fabricated result output" \
  validate_with_provenance_bin "${silent_shellcheck_target}"
assert_failure "silent bash -n proof cannot borrow fabricated result output" \
  quality_contract_validate_payload "${silent_bash_syntax_target}"
OMC_VERIFY_CONFIDENCE_THRESHOLD="${silent_threshold_before}"
fixed_runner_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=30
swift_build_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["swift build"]
' <<<"${definition}")"
assert_failure "fixed build runner cannot borrow fabricated test-count output" \
  quality_contract_validate_payload "${swift_build_target}"
for nonexecuting_anchor in \
  'make test -q' \
  'make test --touch' \
  'pytest --cache-show' \
  'ruff check --show-files' \
  'tsc --init' \
  'swift build --show-bin-path' \
  'jest --clearCache' \
  'phpunit --warm-coverage-cache'; do
  nonexecuting_contract="$(jq --arg command "${nonexecuting_anchor}" '
    (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
      [$command]
  ' <<<"${definition}")"
  assert_failure "non-executing runner mode cannot freeze: ${nonexecuting_anchor}" \
    quality_contract_validate_payload "${nonexecuting_contract}"
done
fake_fixed_runner_dir="${TEST_ROOT}/fixed-runner-bin"
mkdir -p "${fake_fixed_runner_dir}"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${fake_fixed_runner_dir}/tsc"
chmod +x "${fake_fixed_runner_dir}/tsc"
tsc_only_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["tsc", "--noEmit"]
' <<<"${definition}")"
if PATH="${fake_fixed_runner_dir}:${PATH}" \
    quality_contract_validate_payload "${tsc_only_target}" >/dev/null 2>&1; then
  bad "fixed tsc runner borrowed fabricated test-count output"
else
  ok
fi
OMC_VERIFY_CONFIDENCE_THRESHOLD="${fixed_runner_threshold_before}"
npm_feasibility_root="${TEST_ROOT}/npm-feasibility"
mkdir -p "${npm_feasibility_root}"
printf '%s\n' '{"scripts":{"test":"vitest run"}}' \
  >"${npm_feasibility_root}/package.json"
if (
  cd "${npm_feasibility_root}" || exit 1
  OMC_VERIFY_CONFIDENCE_THRESHOLD=70
  export OMC_VERIFY_CONFIDENCE_THRESHOLD
  quality_contract_validate_payload "${definition}" >/dev/null 2>&1
); then
  bad "exact Bash target cannot borrow an unrelated npm project-test score"
else
  ok
fi
proof_launcher_root="${TEST_ROOT}/proof-launcher-feasibility"
proof_launcher_real_bin="${proof_launcher_root}/real-bin"
proof_launcher_link_bin="${proof_launcher_root}/link-bin"
mkdir -p "${proof_launcher_real_bin}" "${proof_launcher_link_bin}"
proof_launcher_real_bin="$(cd "${proof_launcher_real_bin}" && pwd -P)"
proof_launcher_link_bin="$(cd "${proof_launcher_link_bin}" && pwd -P)"
printf '%s\n' '#!/usr/bin/env bash' 'printf "1 test passed\\n"' \
  >"${proof_launcher_real_bin}/omc-proof-check"
chmod +x "${proof_launcher_real_bin}/omc-proof-check"
ln -s "${proof_launcher_real_bin}/omc-proof-check" \
  "${proof_launcher_link_bin}/omc-proof-check"
strict_launcher_target="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["omc-proof-check"]
' <<<"${definition}")"
if (
  export PATH="${proof_launcher_real_bin}:${PATH}"
  export _OMC_HOOK_CALLER_PATH="${PATH}"
  hash -r
  quality_contract_validate_payload "${strict_launcher_target}" \
    >/dev/null 2>&1
); then
  ok
else
  bad "regular strict launcher and subject witnesses should freeze"
fi
if (
  export PATH="${proof_launcher_link_bin}:${PATH}"
  export _OMC_HOOK_CALLER_PATH="${PATH}"
  hash -r
  quality_contract_validate_payload "${strict_launcher_target}" \
    >/dev/null 2>&1
); then
  bad "symlinked PATH launcher froze an unmintable Bash proof"
else
  ok
fi
canonical_definition="$(quality_contract_canonicalize_payload "${definition}")"
assert_success "validated payload remains valid after canonicalization" \
  quality_contract_validate_payload "${canonical_definition}"
spaced_duplicate_standard="$(jq '
  .standards += [(.standards[0]
    | .reference = ("  " + .reference + "  ")
    | .rationale = ("  " + .rationale + "  "))]
' <<<"${definition}")"
assert_success "raw distinct standard spellings reach canonicalization" \
  quality_contract_validate_payload "${spaced_duplicate_standard}"
assert_failure "contract canonicalizer never returns duplicate normalized standards" \
  quality_contract_canonicalize_payload "${spaced_duplicate_standard}"
canonical_multi_comparison="$(jq '.criteria += [{id:"Q-007",class:"aspiration",axis:"visionary",claim:"A second reversible comparison remains independently measurable",rationale:"A separate target prevents argv decoration from standing in for independent proof",surfaces:["second comparison"],proof_method:"Compare the second bounded candidate with its own named verifier target",proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],command_contains:["tests/test-quality-constitution-authority.sh","Q-007","comparison"],artifact_contains:[]},failure_signal:"The second candidate has no independent measured comparison",tradeoff_boundary:"The second comparison may not delay the mandatory floor",evidence_policy:{allowed_kinds:["comparison"],minimum:1,requires_empirical:true,requires_independent_review:true}}]' \
  <<<"${definition}")"
canonical_multi_comparison="$(quality_contract_canonicalize_payload \
  "${canonical_multi_comparison}")"
assert_success "canonical anchor sorting preserves distinct Bash target witnesses" \
  quality_contract_validate_payload "${canonical_multi_comparison}"
blank_north_star="$(jq '.north_star = "            "' <<<"${definition}")"
assert_failure "whitespace-only contract prose is not a valid quality bar" \
  quality_contract_validate_payload "${blank_north_star}"
blank_command_anchor="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["  "]
' <<<"${definition}")"
assert_failure "whitespace-only proof anchor cannot validate then trim empty" \
  quality_contract_validate_payload "${blank_command_anchor}"
canonical="$(quality_contract_canonicalize_payload "${definition}")"
assert_eq "criteria canonicalized by ID" "Q-001,Q-002,Q-003,Q-004,Q-005,Q-006" \
  "$(jq -r '[.criteria[].id] | join(",")' <<<"${canonical}")"
missing_visionary="$(jq 'del(.axes.visionary)' <<<"${definition}")"
assert_failure "visionary axis is mandatory" quality_contract_validate_payload "${missing_visionary}"
missing_visionary_criterion="$(jq '.criteria |= map(select(.axis != "visionary"))' <<<"${definition}")"
assert_failure "visionary must have an empirical must criterion" quality_contract_validate_payload "${missing_visionary_criterion}"
duplicate_ids="$(jq '.criteria[1].id = "Q-001"' <<<"${definition}")"
assert_failure "criterion IDs are unique" quality_contract_validate_payload "${duplicate_ids}"
no_empirical="$(jq '(.criteria[] | select(.axis == "visionary") | .evidence_policy.requires_empirical) = false' <<<"${definition}")"
assert_failure "mandatory axes cannot waive empirical proof" quality_contract_validate_payload "${no_empirical}"
no_anti_goals="$(jq '.anti_goals = []' <<<"${definition}")"
assert_failure "anti-goals are mandatory" quality_contract_validate_payload "${no_anti_goals}"
no_standards="$(jq '.standards = []' <<<"${definition}")"
assert_failure "standards are mandatory" quality_contract_validate_payload "${no_standards}"
null_profile_id="$(jq '.standards[0].profile_entry_id = null' <<<"${definition}")"
assert_failure "optional profile ID cannot be laundered through null" \
  quality_contract_validate_payload "${null_profile_id}"
no_user_standard="$(jq '.standards |= map(select(.kind != "user"))' <<<"${definition}")"
assert_failure "current user direction must remain an explicit standard" \
  quality_contract_validate_payload "${no_user_standard}"
no_independent_axis="$(jq '(.criteria[] | select(.axis == "complete" and .class == "must") | .evidence_policy.requires_independent_review) = false' <<<"${definition}")"
assert_failure "mandatory axis proof cannot waive independent review" \
  quality_contract_validate_payload "${no_independent_axis}"
multi_receipt_minimum="$(jq '(.criteria[] | select(.id == "Q-001") | .evidence_policy.minimum) = 2' <<<"${definition}")"
assert_failure "independent proofs must be separate uniquely anchored criteria" \
  quality_contract_validate_payload "${multi_receipt_minimum}"
collapsed_claims="$(jq '(.criteria[] | select(.class == "must") | .claim) = "Generic quality criterion is reported complete with current proof"' <<<"${definition}")"
assert_failure "five axis labels cannot launder one generic finish line" \
  quality_contract_validate_payload "${collapsed_claims}"
bare_wildcard="$(jq '(.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) = ["*"]' <<<"${definition}")"
assert_failure "bare tool wildcard cannot make every receipt eligible" \
  quality_contract_validate_payload "${bare_wildcard}"
unwired_tool="$(jq '(.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) = ["Foo"]' <<<"${definition}")"
assert_failure "contract cannot freeze proof around an unwired tool" \
  quality_contract_validate_payload "${unwired_tool}"
impossible_kind_tool="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["source"],tool_names:["Bash"],command_contains:["Q-001"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["source"]
' <<<"${definition}")"
assert_failure "contract rejects receipt kinds the named tool cannot mint" \
  quality_contract_validate_payload "${impossible_kind_tool}"
bash_render_proof="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],tool_names:["Bash"],
     command_contains:["tests/omc_definition_render.sh","Q-003","render"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_success "executable render proof can freeze when its result can reach threshold" \
  quality_contract_validate_payload "${bash_render_proof}"
bash_render_command='bash tests/omc_definition_render.sh --criterion Q-003 --render'
assert_eq "Bash render command stamps render evidence" "render" \
  "$(verification_receipt_evidence_kind framework_keyword unknown_test \
    "${bash_render_command}" 'render produced artifact: proof.png; 1 test passed; exit code: 0')"
assert_eq "generic test output cannot launder render argv" "test" \
  "$(verification_receipt_evidence_kind framework_keyword unknown_test \
    "${bash_render_command}" 'render tests: 5 passed')"
assert_eq "silent authoritative Bash render reaches only the execution floor" "40" \
  "$(score_verification_confidence "${bash_render_command}" "" "")"
assert_eq "result-bearing Bash render reaches threshold without name-only inflation" \
  "60" "$(score_verification_confidence "${bash_render_command}" \
    'render artifact: proof.png; 1 test passed; exit code: 0' "")"
mutating_browser_evaluate="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) =
    ["mcp__plugin_playwright_playwright__browser_evaluate"]
' <<<"${definition}")"
assert_failure "browser evaluate cannot freeze proof because mutation admission wins" \
  quality_contract_validate_payload "${mutating_browser_evaluate}"
mutating_browser_run_code="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) =
    ["mcp__plugin_playwright_playwright__browser_run_code"]
' <<<"${definition}")"
assert_failure "browser run_code cannot freeze proof because it never mints a receipt" \
  quality_contract_validate_payload "${mutating_browser_run_code}"
untargeted_browser_render="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_take_screenshot"],
     command_contains:["browser_take_screenshot"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
# Lowering the configured threshold is an explicit user policy choice. Under
# that policy a targeted screenshot language is confidence-feasible, so these
# two assertions continue to exercise the independent target-binding guards
# rather than passing incidentally because the default threshold is stricter.
render_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=30
assert_failure "browser render proof must bind a route, path, selector, or target" \
  quality_contract_validate_payload "${untargeted_browser_render}"
descriptor_only_browser_render="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_take_screenshot"],
     command_contains:["browser_take_screenshot"],artifact_contains:["target="]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_failure "descriptor-key-only browser anchor cannot launder target identity" \
  quality_contract_validate_payload "${descriptor_only_browser_render}"
OMC_VERIFY_CONFIDENCE_THRESHOLD="${render_threshold_before}"
targeted_browser_render="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_take_screenshot"],
     command_contains:["browser_take_screenshot"],artifact_contains:["target=#checkout"]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_eq "targeted passive screenshot retains conservative confidence" "30" \
  "$(score_mcp_verification_confidence browser_visual_check "" true)"
assert_eq "passive screenshot exposes no threshold-capable contract kind" "" \
  "$(_quality_contract_tool_possible_kinds \
    mcp__plugin_playwright_playwright__browser_take_screenshot 2>/dev/null || true)"
assert_failure "screenshot-only render language cannot freeze below reviewer threshold" \
  quality_contract_validate_payload "${targeted_browser_render}"
targeted_browser_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["inspection"],
     tool_names:["mcp__plugin_playwright_playwright__browser_snapshot"],
     command_contains:["browser_snapshot"],artifact_contains:["target=#checkout"]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["inspection"]
' <<<"${definition}")"
assert_eq "DOM snapshot UI-history bonus remains contingent, not intrinsic" "25" \
  "$(score_mcp_verification_confidence browser_dom_check "" false)"
assert_eq "snapshot exposes no intrinsically threshold-capable contract kind" "" \
  "$(_quality_contract_tool_possible_kinds \
    mcp__plugin_playwright_playwright__browser_snapshot 2>/dev/null || true)"
assert_failure "snapshot-only inspection cannot freeze on a contingent UI bonus" \
  quality_contract_validate_payload "${targeted_browser_snapshot}"
snapshot_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=25
assert_success "explicit threshold may admit an intrinsically reachable snapshot proof" \
  quality_contract_validate_payload "${targeted_browser_snapshot}"
fake_snapshot_tool="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) =
    ["mcp__fake_playwright__browser_snapshot"]
' <<<"${targeted_browser_snapshot}")"
assert_failure "suffix-shaped unknown MCP tool cannot borrow Playwright schema authority" \
  quality_contract_validate_payload "${fake_snapshot_tool}"
alias_collision_snapshot="$(jq '.criteria += [{
  id:"Q-007",class:"aspiration",axis:"visionary",
  claim:"A second connector alias independently proves the same targeted observation",
  rationale:"Alias transport names must not manufacture a second proof surface",
  surfaces:["checkout snapshot alias"],
  proof_method:"Inspect the same checkout target through the direct Playwright MCP alias",
  proof_spec:{receipt_kinds:["inspection"],
    tool_names:["mcp__playwright__browser_snapshot"],
    command_contains:["browser_snapshot"],artifact_contains:["target=#checkout"]},
  failure_signal:"The alias does not provide an independent observation",
  tradeoff_boundary:"Connector naming cannot substitute for distinct evidence",
  evidence_policy:{allowed_kinds:["inspection"],minimum:1,
    requires_empirical:true,requires_independent_review:true}
}]' <<<"${targeted_browser_snapshot}")"
assert_failure "MCP aliases cannot split one classifier-and-target proof identity" \
  quality_contract_validate_payload "${alias_collision_snapshot}"
snapshot_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${targeted_browser_snapshot}")"
snapshot_target_witness="$(_quality_contract_mcp_target_witness \
  "${snapshot_criterion}" \
  mcp__plugin_playwright_playwright__browser_snapshot)"
assert_eq "constructive target witness uses the production descriptor key" \
  "target=#checkout" "${snapshot_target_witness}"
snapshot_receipt="$(jq -cn --arg target "${snapshot_target_witness}" '
  {tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
   command:("mcp__plugin_playwright_playwright__browser_snapshot " + $target),
   evidence_kind:"inspection",artifact_target:$target}
')"
assert_success "the constructive snapshot witness matches a production-shaped receipt" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${snapshot_receipt}" "${snapshot_criterion}"
snapshot_prefix_receipt="$(jq -cn '
  {tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
   command:"mcp__plugin_playwright_playwright__browser_snapshot target=#checkout-evil",
   evidence_kind:"inspection",artifact_target:"target=#checkout-evil"}
')"
assert_failure "MCP target prefix cannot satisfy an exact frozen selector" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${snapshot_prefix_receipt}" "${snapshot_criterion}"
case_sensitive_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#Checkout"]
' <<<"${targeted_browser_snapshot}")"
case_sensitive_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${case_sensitive_snapshot}")"
assert_failure "MCP selector values remain case-sensitive" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${snapshot_receipt}" "${case_sensitive_criterion}"
case_distinct_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["snapshot"]
  | .criteria += [{id:"Q-007",class:"aspiration",axis:"coherent",
      claim:"The case-distinct browser selector remains independently observable",
      rationale:"CSS selector case is part of the exact frozen target identity",
      surfaces:["case-distinct checkout"],
      proof_method:"Inspect the uppercase checkout selector independently",
      proof_spec:{receipt_kinds:["inspection"],
        tool_names:["mcp__plugin_playwright_playwright__browser_snapshot"],
        command_contains:["snapshot"],artifact_contains:["target=#Checkout"]},
      failure_signal:"The uppercase selector state is not independently observed",
      tradeoff_boundary:"Only exact case-distinct browser targets count separately",
      evidence_policy:{allowed_kinds:["inspection"],minimum:1,
        requires_empirical:true,requires_independent_review:true}}]
' <<<"${targeted_browser_snapshot}")"
assert_success "case-distinct MCP selectors remain separate proof surfaces" \
  quality_contract_validate_payload "${case_distinct_snapshot}"
semicolon_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=alpha;beta"]
' <<<"${targeted_browser_snapshot}")"
assert_success "raw semicolon MCP value freezes through delimiter encoding" \
  quality_contract_validate_payload "${semicolon_snapshot}"
semicolon_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${semicolon_snapshot}")"
assert_eq "raw semicolon is encoded as one descriptor value" \
  "target=alpha%3Bbeta" "$(_quality_contract_mcp_target_witness \
    "${semicolon_criterion}" \
    mcp__plugin_playwright_playwright__browser_snapshot)"
literal_percent_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=alpha%3Bbeta"]
' <<<"${targeted_browser_snapshot}")"
literal_percent_criterion="$(jq -c \
  '.criteria[] | select(.id == "Q-001")' <<<"${literal_percent_snapshot}")"
assert_eq "literal percent sequence stays distinct from a semicolon" \
  "target=alpha%253Bbeta" "$(_quality_contract_mcp_target_witness \
    "${literal_percent_criterion}" \
    mcp__plugin_playwright_playwright__browser_snapshot)"
route_bound_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#checkout","observed_url=https://example.test/checkout"]
' <<<"${targeted_browser_snapshot}")"
assert_success "snapshot proof may bind both exact target and observed route" \
  quality_contract_validate_payload "${route_bound_snapshot}"
whitespace_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=  #checkout  "]
' <<<"${targeted_browser_snapshot}")"
whitespace_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${whitespace_snapshot}")"
assert_eq "browser target witness canonicalizes boundary whitespace" \
  "target=#checkout" "$(_quality_contract_mcp_target_witness \
    "${whitespace_criterion}" \
    mcp__plugin_playwright_playwright__browser_snapshot)"
whitespace_target_overlap="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["browser"]
  | .criteria += [{id:"Q-007",class:"aspiration",axis:"coherent",
      claim:"A whitespace-decorated selector remains independently observed",
      rationale:"Browser-equivalent selector whitespace must share one identity",
      surfaces:["checkout selector alias"],
      proof_method:"Inspect the whitespace-decorated checkout selector",
      proof_spec:{receipt_kinds:["inspection"],
        tool_names:["mcp__plugin_playwright_playwright__browser_snapshot"],
        command_contains:["snapshot"],artifact_contains:["target=  #checkout  "]},
      failure_signal:"One browser observation is counted as two targets",
      tradeoff_boundary:"Only semantically distinct browser targets are independent",
      evidence_policy:{allowed_kinds:["inspection"],minimum:1,
        requires_empirical:true,requires_independent_review:true}}]
' <<<"${targeted_browser_snapshot}")"
assert_failure "selector boundary whitespace cannot split one MCP proof identity" \
  quality_contract_validate_payload "${whitespace_target_overlap}"
route_bound_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${route_bound_snapshot}")"
route_bound_witness="$(_quality_contract_mcp_target_witness \
  "${route_bound_criterion}" \
  mcp__plugin_playwright_playwright__browser_snapshot)"
assert_eq "route-bound MCP witness preserves both exact descriptors" \
  "target=#checkout;observed_url=https://example.test/checkout" \
  "${route_bound_witness}"
route_bound_receipt="$(jq -cn --arg target "${route_bound_witness}" '
  {tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
   command:("mcp__plugin_playwright_playwright__browser_snapshot " + $target),
   evidence_kind:"inspection",artifact_target:$target}
')"
assert_success "route-bound receipt matches exact selector and route" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${route_bound_receipt}" "${route_bound_criterion}"
wrong_route_receipt="$(jq -c \
  '.artifact_target="target=#checkout;observed_url=https://example.test/other"' \
  <<<"${route_bound_receipt}")"
assert_failure "right selector on the wrong route cannot certify" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${wrong_route_receipt}" "${route_bound_criterion}"
for noncanonical_route in \
  'https://EXAMPLE.test/checkout' \
  'https://example.test:443/checkout' \
  'https://example.test:0443/checkout' \
  'https://example.test:08080/checkout' \
  'https://example.test:18446744073709551616/checkout' \
  'http://example.test:/checkout' \
  'https://example.test/a/../checkout' \
  'http://127.1/checkout' \
  'http://127.000.000.001/checkout' \
  'http://2130706433/checkout' \
  'http://0x7f000001/checkout' \
  'http://18446744073709551616.0.0.1/checkout' \
  'http://[0:0:0:0:0:0:0:1]:3000/checkout' \
  'http://[::0001]:3000/checkout' \
  'http://[::1]:/checkout' \
  'http://[::1]:80/checkout' \
  'https://example.test/a{b}' \
  'https://example.test/a^b' \
  'https://example.test/café'; do
  noncanonical_snapshot="$(jq --arg route \
    "observed_url=${noncanonical_route}" '
      (.criteria[] | select(.id == "Q-001")
        | .proof_spec.artifact_contains) = ["target=#checkout",$route]
    ' <<<"${targeted_browser_snapshot}")"
  assert_failure "noncanonical browser route cannot freeze: ${noncanonical_route}" \
    quality_contract_validate_payload "${noncanonical_snapshot}"
done
ipv6_route_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#checkout","observed_url=http://[::1]:3000/checkout"]
' <<<"${targeted_browser_snapshot}")"
assert_success "canonical bracketed IPv6 browser route may freeze" \
  quality_contract_validate_payload "${ipv6_route_snapshot}"
pipe_route_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#checkout","observed_url=https://example.test/a|b"]
' <<<"${targeted_browser_snapshot}")"
assert_success "canonical browser route preserves a literal path pipe" \
  quality_contract_validate_payload "${pipe_route_snapshot}"
percent_route_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#checkout","observed_url=https://example.test/a%20b"]
' <<<"${targeted_browser_snapshot}")"
percent_route_criterion="$(jq -c \
  '.criteria[] | select(.id == "Q-001")' <<<"${percent_route_snapshot}")"
assert_eq "descriptor escaping preserves literal percent without delimiter collision" \
  "target=#checkout;observed_url=https://example.test/a%2520b" \
  "$(_quality_contract_mcp_target_witness \
    "${percent_route_criterion}" \
    mcp__plugin_playwright_playwright__browser_snapshot)"
query_bound_snapshot="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["target=#checkout","observed_url=https://example.test/search?q=right#results"]
' <<<"${targeted_browser_snapshot}")"
assert_success "route-bound proof preserves query and fragment identity" \
  quality_contract_validate_payload "${query_bound_snapshot}"
query_bound_criterion="$(jq -c '.criteria[] | select(.id == "Q-001")' \
  <<<"${query_bound_snapshot}")"
query_bound_receipt="$(jq -cn '
  {tool_name:"mcp__plugin_playwright_playwright__browser_snapshot",
   command:"mcp__plugin_playwright_playwright__browser_snapshot target=#checkout",
   evidence_kind:"inspection",
   artifact_target:"target=#checkout;observed_url=https://example.test/search?q=right#results"}
')"
assert_success "matching query-state route certifies" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${query_bound_receipt}" "${query_bound_criterion}"
wrong_query_receipt="$(jq -c '
  .artifact_target = "target=#checkout;observed_url=https://example.test/search?q=wrong#results"
' <<<"${query_bound_receipt}")"
assert_failure "same path with a different query cannot certify" \
  _quality_contract_receipt_semantic_matches_criterion \
    "${wrong_query_receipt}" "${query_bound_criterion}"
mcp_subset_overlap="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["browser"]
  | .criteria += [{
      id:"Q-007",class:"aspiration",axis:"coherent",
      claim:"The route-specific checkout state has an independent observation",
      rationale:"A richer descriptor must not double-certify a selector-only proof",
      surfaces:["checkout route"],
      proof_method:"Inspect the route-bound checkout snapshot",
      proof_spec:{receipt_kinds:["inspection"],
        tool_names:["mcp__plugin_playwright_playwright__browser_snapshot"],
        command_contains:["snapshot"],
        artifact_contains:["target=#checkout","observed_url=https://example.test/checkout"]},
      failure_signal:"One richer receipt is accepted for both frozen criteria",
      tradeoff_boundary:"Use distinct targets or incompatible routes for independent proof",
      evidence_policy:{allowed_kinds:["inspection"],minimum:1,
        requires_empirical:true,requires_independent_review:true}}
    ]
' <<<"${targeted_browser_snapshot}")"
assert_failure "MCP selector-only and route-rich descriptor subsets cannot both freeze" \
  quality_contract_validate_payload "${mcp_subset_overlap}"
mcp_distinct_routes="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = ["browser"]
  | (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
      ["target=#checkout","observed_url=https://example.test/checkout?state=one"]
  | .criteria += [{
      id:"Q-007",class:"aspiration",axis:"coherent",
      claim:"A different checkout route state has an independent observation",
      rationale:"Incompatible exact routes require distinct connector observations",
      surfaces:["checkout route two"],
      proof_method:"Inspect the second route-bound checkout snapshot",
      proof_spec:{receipt_kinds:["inspection"],
        tool_names:["mcp__plugin_playwright_playwright__browser_snapshot"],
        command_contains:["snapshot"],
        artifact_contains:["target=#checkout","observed_url=https://example.test/checkout?state=two"]},
      failure_signal:"The second route state is not independently observed",
      tradeoff_boundary:"Exact route differences remain independent proof surfaces",
      evidence_policy:{allowed_kinds:["inspection"],minimum:1,
        requires_empirical:true,requires_independent_review:true}}
    ]
' <<<"${targeted_browser_snapshot}")"
assert_success "same selector on incompatible exact routes remains independently provable" \
  quality_contract_validate_payload "${mcp_distinct_routes}"
schema_incompatible_snapshot_target="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["route=/checkout"]
' <<<"${targeted_browser_snapshot}")"
assert_failure "snapshot proof rejects target keys absent from the concrete tool schema" \
  quality_contract_validate_payload "${schema_incompatible_snapshot_target}"
impossible_snapshot_anchor="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) =
    ["made-up-impossible-token"]
' <<<"${targeted_browser_snapshot}")"
assert_failure "exact MCP proof rejects command text absent from its concrete tool identity" \
  quality_contract_validate_payload "${impossible_snapshot_anchor}"
wildcard_cross_candidate="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_*"],
     command_contains:["browser_snapshot"],artifact_contains:["target=#checkout"]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
OMC_VERIFY_CONFIDENCE_THRESHOLD=20
assert_failure "wildcard MCP proof cannot union kind and command capability across tools" \
  quality_contract_validate_payload "${wildcard_cross_candidate}"
wildcard_single_witness="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_*"],
     command_contains:["browser_take_screenshot"],artifact_contains:["target=#checkout"]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_success "wildcard MCP proof remains valid when one concrete tool is a full witness" \
  quality_contract_validate_payload "${wildcard_single_witness}"
decoder_safe_path_before="${_OMC_OBSERVER_SAFE_PATH}"
_OMC_OBSERVER_SAFE_PATH="${TEST_ROOT}/png-decoder-unavailable"
assert_failure "screenshot proof cannot freeze when its decoded-PNG observer is unavailable" \
  quality_contract_validate_payload "${wildcard_single_witness}"
_OMC_OBSERVER_SAFE_PATH="${decoder_safe_path_before}"
screenshot_route_bound="$(jq '
  (.criteria[] | select(.id == "Q-003") | .proof_spec) =
    {receipt_kinds:["render"],
     tool_names:["mcp__plugin_playwright_playwright__browser_take_screenshot"],
     command_contains:["browser_take_screenshot"],
     artifact_contains:["target=#checkout",
       "observed_url=https://example.test/checkout"]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_failure "screenshot cannot freeze an output route its result schema does not expose" \
  quality_contract_validate_payload "${screenshot_route_bound}"
screenshot_route_criterion="$(jq -c \
  '.criteria[] | select(.id == "Q-003")' <<<"${screenshot_route_bound}")"
assert_failure "constructive screenshot witness rejects observed_url" \
  _quality_contract_mcp_target_witness \
    "${screenshot_route_criterion}" \
    mcp__plugin_playwright_playwright__browser_take_screenshot
untargetable_console="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["inspection"],
     tool_names:["mcp__plugin_playwright_playwright__browser_console_messages"],
     command_contains:["browser_console_messages"],artifact_contains:["target=#checkout"]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["inspection"]
' <<<"${definition}")"
assert_failure "MCP proof fails closed when the concrete tool has no target capability" \
  quality_contract_validate_payload "${untargetable_console}"
OMC_VERIFY_CONFIDENCE_THRESHOLD="${snapshot_threshold_before}"

# A maximal first-freeze contract must still have structural room for an
# authoritative scope addition. Payload validation admits additive revisions up
# to 20 criteria, while envelope construction reserves that headroom by capping
# revision 1 at ten.
ten_criterion_definition="$(jq '
  .criteria += [range(7;11) as $n | {
    id:("Q-" + (("000" + ($n|tostring))[-3:])),class:"aspiration",axis:"visionary",
    claim:("A bounded reversible frontier experiment " + ($n|tostring) + " remains measured"),
    rationale:("Experiment " + ($n|tostring) + " preserves additive scope headroom without weakening the floor"),
    surfaces:[("future experiment " + ($n|tostring))],
    proof_method:("Compare frontier experiment Q-" + (("000" + ($n|tostring))[-3:]) + " against the settled baseline"),
    proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],
      command_contains:[("tests/criterion-" + ($n|tostring) + "-comparison.sh"),
        ("Q-" + (("000" + ($n|tostring))[-3:])),"comparison"],artifact_contains:[]},
    failure_signal:("Experiment " + ($n|tostring) + " lacks a measurable reversible outcome"),
    tradeoff_boundary:("Experiment " + ($n|tostring) + " may not delay the mandatory floor"),
    evidence_policy:{allowed_kinds:["comparison"],minimum:1,
      requires_empirical:true,requires_independent_review:true}
  }]
' <<<"${definition}")"
eleven_criterion_definition="$(jq '
  .criteria += [{
    id:"Q-011",class:"must",axis:"complete",
    claim:"The authoritative scope addition is implemented and independently proven",
    rationale:"Substantive continuation must create a certifying obligation instead of disappearing into prose",
    surfaces:["authoritative scope addition"],
    proof_method:"Run the Q-011 scope-addition integration proof against the expanded objective",
    proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],
      command_contains:["tests/criterion-11-scope-addition-test.sh","Q-011"],artifact_contains:[]},
    failure_signal:"The added scope lacks implementation or current independent proof",
    tradeoff_boundary:"The addition may be explicitly rescoped but never silently omitted",
    evidence_policy:{allowed_kinds:["test"],minimum:1,
      requires_empirical:true,requires_independent_review:true}
  }]
' <<<"${ten_criterion_definition}")"
assert_success "additive payload has headroom beyond a ten-criterion floor" \
  quality_contract_validate_payload "${eleven_criterion_definition}"
objective_digest_for_headroom="$(_quality_contract_digest \
  'Exercise additive criterion headroom')"
assert_failure "first contract cannot consume additive criterion reserve" \
  quality_contract_build_envelope "${eleven_criterion_definition}" 7 100 3 \
    "${objective_digest_for_headroom}" generation-1 1 110 quality-planner \
    native-planner-1 dispatch-planner-headroom1 1
ten_criterion_envelope="$(quality_contract_build_envelope \
  "${ten_criterion_definition}" 7 100 3 "${objective_digest_for_headroom}" \
  generation-1 1 110 quality-planner native-planner-1 \
  dispatch-planner-headroom1 1)"
assert_success "scope addition preserves the full ten-criterion floor" \
  quality_contract_revision_preserves_floor \
    "${eleven_criterion_definition}" "${ten_criterion_envelope}"
printf '%s\n' "${ten_criterion_envelope}" >"$(session_file quality_contract.json)"
assert_success "revision two can publish the eleventh certifying criterion" \
  quality_contract_build_envelope "${eleven_criterion_definition}" 7 100 3 \
    "${objective_digest_for_headroom}" generation-1 1 120 quality-planner \
    native-planner-2 dispatch-planner-headroom2 2
rm -f "$(session_file quality_contract.json)"
multi_tool_proof="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) = ["Grep","Bash"]
' <<<"${definition}")"
assert_failure "one criterion cannot union alternative proof tools" \
  quality_contract_validate_payload "${multi_tool_proof}"
multi_kind_proof="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.receipt_kinds) = ["inspection","test"]
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["inspection","test"]
' <<<"${definition}")"
assert_failure "one criterion cannot union alternative receipt kinds" \
  quality_contract_validate_payload "${multi_kind_proof}"
union_covered_proof="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["inspection"],tool_names:["Bash","Grep"],
     command_contains:["Q-001","anchor-b2","anchor-c3","anchor-u"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-002") | .proof_spec) =
    {receipt_kinds:["inspection"],tool_names:["Bash"],
     command_contains:["Q-001","anchor-b"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-005") | .proof_spec) =
    {receipt_kinds:["inspection"],tool_names:["Grep"],
     command_contains:["Q-001","anchor-c"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-001" or .id == "Q-002" or .id == "Q-005")
      | .evidence_policy.allowed_kinds) = ["inspection"]
' <<<"${definition}")"
assert_failure "union-covered criterion cannot freeze an exact-one proof deadlock" \
  quality_contract_validate_payload "${union_covered_proof}"
kind_forcing_anchor="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["Q-005","benchmark"]
' <<<"${definition}")"
assert_failure "Bash anchor cannot force a different receipt kind" \
  quality_contract_validate_payload "${kind_forcing_anchor}"
help_only_anchor="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["Q-005","--help"]
' <<<"${definition}")"
assert_failure "Bash help-mode anchor cannot freeze non-executing proof" \
  quality_contract_validate_payload "${help_only_anchor}"
compound_only_anchor="$(jq '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["Q-005","&& echo"]
' <<<"${definition}")"
assert_failure "Bash compound-shell anchor cannot freeze rejected proof" \
  quality_contract_validate_payload "${compound_only_anchor}"
long_a="$(printf '%0200d' 0 | tr '0' 'a')"
long_b="$(printf '%0200d' 0 | tr '0' 'b')"
long_c="$(printf '%0200d' 0 | tr '0' 'c')"
long_d="$(printf '%0300d' 0 | tr '0' 'd')"
long_e="$(printf '%0300d' 0 | tr '0' 'e')"
long_f="$(printf '%0300d' 0 | tr '0' 'f')"
long_g="$(printf '%0300d' 0 | tr '0' 'g')"
overlong_command_language="$(jq \
  --arg a "${long_a}" --arg b "${long_b}" --arg c "${long_c}" '
  (.criteria[] | select(.id == "Q-005") | .proof_spec.command_contains) =
    ["Q-005",$a,$b,$c]
' <<<"${definition}")"
assert_failure "command anchors must fit the authoritative 500-character receipt" \
  quality_contract_validate_payload "${overlong_command_language}"
overlong_artifact_language="$(jq \
  --arg d "${long_d}" --arg e "${long_e}" --arg f "${long_f}" --arg g "${long_g}" '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.command_contains) = []
  | (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
      [$d,$e,$f,$g]
' <<<"${definition}")"
assert_failure "artifact anchors must fit the authoritative 1000-character target" \
  quality_contract_validate_payload "${overlong_artifact_language}"
canonical_impossible_read="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["source"],tool_names:["Read"],
     command_contains:["Q-001","/../"],artifact_contains:["AGENTS.md"]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["source"]
' <<<"${definition}")"
assert_failure "Read proof cannot require a path fragment canonicalization removes" \
  quality_contract_validate_payload "${canonical_impossible_read}"
canonical_double_slash="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.artifact_contains) =
    ["AGENTS.md","//"]
' <<<"${definition}")"
assert_failure "source artifact anchor cannot require canonical double slash" \
  quality_contract_validate_payload "${canonical_double_slash}"
long_z="$(printf '%0300d' 0 | tr '0' 'z')"
source_name_max_violation="$(jq --arg z "${long_z}" '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["source"],tool_names:["Read"],
     command_contains:["Q-001"],artifact_contains:[$z]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["source"]
' <<<"${definition}")"
assert_failure "source path anchor cannot exceed one filesystem component" \
  quality_contract_validate_payload "${source_name_max_violation}"
emoji_token='😀'
long_emoji=''
for _emoji_n in $(seq 1 200); do
  long_emoji="${long_emoji}${emoji_token}"
done
grep_pattern_name_max_gap="$(jq --arg token "${long_emoji}" '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["inspection"],tool_names:["Grep"],
     command_contains:["Q-001",$token],artifact_contains:["AGENTS.md"]}
' <<<"${definition}")"
assert_failure "Grep anchor must fit either persisted pattern or canonical path bytes" \
  quality_contract_validate_payload "${grep_pattern_name_max_gap}"
root_gap_a="$(printf '%0200d' 0 | tr '0' 'r')"
root_gap_b="$(printf '%0200d' 0 | tr '0' 's')"
root_gap_c="$(printf '%070d' 0 | tr '0' 't')"
source_root_overhead_gap="$(jq \
  --arg a "${root_gap_a}" --arg b "${root_gap_b}" --arg c "${root_gap_c}" '
  (.criteria[] | select(.id == "Q-001") | .proof_spec) =
    {receipt_kinds:["source"],tool_names:["Read"],
     command_contains:["Q-001",$a,$b],artifact_contains:[$c]}
  | (.criteria[] | select(.id == "Q-001") | .evidence_policy.allowed_kinds) = ["source"]
' <<<"${definition}")"
assert_failure "source command witness reserves canonical project-root overhead" \
  quality_contract_validate_payload "${source_root_overhead_gap}"
bash_artifact_target="$(jq '
  (.criteria[] | select(.id == "Q-001") | .proof_spec.tool_names) = ["Bash"]
' <<<"${definition}")"
assert_failure "Bash-only proof cannot require an artifact target it never stamps" \
  quality_contract_validate_payload "${bash_artifact_target}"
duplicate_aspiration_proof="$(jq '
  (.criteria[] | select(.id == "Q-006") | .proof_spec) =
    (.criteria[] | select(.id == "Q-001") | .proof_spec)
  | (.criteria[] | select(.id == "Q-006") | .evidence_policy.allowed_kinds) = ["inspection"]
' <<<"${definition}")"
assert_failure "aspiration cannot duplicate a mandatory proof language" \
  quality_contract_validate_payload "${duplicate_aspiration_proof}"
subset_aspiration_proof="$(jq '
  (.criteria[] | select(.id == "Q-006") | .proof_spec) =
    {receipt_kinds:["inspection"],tool_names:["Grep"],
     command_contains:["Q-001","Q-006"],artifact_contains:["AGENTS.md"]}
  | (.criteria[] | select(.id == "Q-006") | .evidence_policy.allowed_kinds) = ["inspection"]
' <<<"${definition}")"
assert_failure "criterion proof language cannot imply another criterion" \
  quality_contract_validate_payload "${subset_aspiration_proof}"
secret_payload="$(jq '.north_star += " sk-ant-abcdefghijklmnopqrstuv"' <<<"${definition}")"
assert_failure "provider keys are rejected before contract persistence" \
  quality_contract_validate_payload "${secret_payload}"
ensure_session_dir
write_state_batch \
  "quality_constitution_status" "current" \
  "quality_constitution_blocking_ids" '[]'
rm -f "$(session_file quality_constitution_snapshot.json)"
assert_failure "current Constitution state cannot freeze against a missing advisory-only snapshot" \
  build_contract
write_state "quality_constitution_status" "disabled"
cat >"$(session_file quality_constitution_snapshot.json)" <<'JSON'
{"schema_version":1,"generation":1,"digest":"constitution-digest-test","blocking_claims":[{"id":"qc_taste_blocking_1","statement":"Prefer causal proof over generic quality claims"}],"advisory_claims":[],"tentative_claims":[]}
JSON
write_state "quality_constitution_blocking_ids" '["qc_taste_blocking_1"]'
assert_failure "active explicit profile ID cannot be silently dropped" \
  quality_contract_validate_profile_bindings "${definition}"
profile_bound="$(jq '.standards += [{kind:"profile",reference:"Prefer causal proof over generic quality claims",rationale:"The user pinned this project-specific taste rule",profile_entry_id:"qc_taste_blocking_1"}]' <<<"${definition}")"
assert_success "bound explicit profile standard validates" \
  quality_contract_validate_profile_bindings "${profile_bound}"
profile_snapshot_file="$(session_file quality_constitution_snapshot.json)"
cp "${profile_snapshot_file}" "${profile_snapshot_file}.valid"
jq '.generation=1.5' "${profile_snapshot_file}.valid" \
  >"${profile_snapshot_file}"
assert_failure "profile binding rejects fractional snapshot generation" \
  quality_contract_validate_profile_bindings "${profile_bound}"
jq '.generation=1000000000000000' "${profile_snapshot_file}.valid" \
  >"${profile_snapshot_file}"
assert_failure "profile binding rejects oversized snapshot generation" \
  quality_contract_validate_profile_bindings "${profile_bound}"
mv -f "${profile_snapshot_file}.valid" "${profile_snapshot_file}"
profile_misquoted="$(jq '(.standards[] | select(.kind == "profile") | .reference) = "Do the opposite of the pinned rule"' <<<"${profile_bound}")"
assert_failure "profile ID cannot be paired with a contradictory statement" \
  quality_contract_validate_profile_bindings "${profile_misquoted}"
write_state "quality_constitution_blocking_ids" 'qc_taste_blocking_1'
assert_success "comma-form router profile IDs bind identically" \
  quality_contract_validate_profile_bindings "${profile_bound}"
write_state "quality_constitution_blocking_ids" '[]'
rm -f "$(session_file quality_constitution_snapshot.json)"
write_state "quality_constitution_status" "disabled"

printf 'Test 3: exact structural-tail extraction rejects spoofing and trailing prose\n'
contract_message=$'Planner prose\nQUALITY_CONTRACT_JSON: '"${definition}"$'\nVERDICT: PLAN_READY'
extracted="$(quality_contract_extract_json "${contract_message}")"
assert_eq "contract extraction canonicalizes" "${canonical}" "${extracted}"
duplicate_message=$'QUALITY_CONTRACT_JSON: '"${definition}"$'\nquoted replay\nQUALITY_CONTRACT_JSON: '"${definition}"$'\nVERDICT: PLAN_READY'
assert_failure "duplicate marker replay rejected" quality_contract_extract_json "${duplicate_message}"
trailing_message="${contract_message}"$'\nI am done'
assert_failure "completion prose after verdict rejected" quality_contract_extract_json "${trailing_message}"
wrong_verdict=$'QUALITY_CONTRACT_JSON: '"${definition}"$'\nVERDICT: BLOCKED'
assert_failure "non-ready plan cannot publish contract" quality_contract_extract_json "${wrong_verdict}"

printf 'Test 4: authoritative envelope and current-generation validation\n'
contract="$(build_contract)"
assert_success "authoritative contract envelope validates" quality_contract_validate_envelope "${contract}"
nul_constitution_contract="$(jq \
  '.quality_constitution_digest += "\u0000"' <<<"${contract}")"
nul_constitution_identity="$(jq -cS '
  if ._v == 2 then
    {contract_revision,review_cycle_id,objective_prompt_ts,
     objective_prompt_revision,objective_digest,ulw_enforcement_generation,
     plan_revision,verification_threshold,created_ts,planner,payload_digest,
     profile_blocking_ids,quality_constitution_generation,
     quality_constitution_digest,late}
  else
    {contract_revision,review_cycle_id,objective_prompt_ts,
     objective_prompt_revision,objective_digest,ulw_enforcement_generation,
     plan_revision,created_ts,planner,payload_digest,profile_blocking_ids,
     quality_constitution_generation,quality_constitution_digest,late}
  end
' <<<"${nul_constitution_contract}")"
nul_constitution_id="qc-$(_quality_contract_digest \
  "${nul_constitution_identity}")"
nul_constitution_contract="$(jq --arg id "${nul_constitution_id}" \
  '.contract_id = $id' <<<"${nul_constitution_contract}")"
assert_failure "NUL-tailed Constitution digest fails even after envelope reseal" \
  quality_contract_validate_envelope "${nul_constitution_contract}"
assert_failure "envelope construction rejects arithmetic-width revision text" \
  quality_contract_build_envelope "${definition}" \
    7 100 3 "$(_quality_contract_digest 'Overflow-safe contract revision')" \
    generation-1 1 110 quality-planner native-planner-1 \
    dispatch-planner-overflow 999999999999999999999999999999
assert_eq "new contracts seal the threshold-bearing envelope schema" "2:40" \
  "$(jq -r '[(._v|tostring),(.verification_threshold|tostring)] | join(":")' \
    <<<"${contract}")"
threshold_tamper="$(jq '.verification_threshold = 41' <<<"${contract}")"
assert_failure "sealed verifier threshold participates in contract identity" \
  quality_contract_validate_envelope "${threshold_tamper}"
envelope_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=100
assert_success "sealed envelope validity is independent of later verifier policy changes" \
  quality_contract_validate_envelope "${contract}"
assert_success "floor comparison uses the sealed threshold, not later live policy" \
  quality_contract_revision_preserves_floor "${definition}" "${contract}"
OMC_VERIFY_CONFIDENCE_THRESHOLD="${envelope_threshold_before}"

# A sealed profile floor remains intrinsically valid when live user taste or a
# referenced exemplar changes. The next contract revision must retain that old
# row while binding the current statement; otherwise removal/rewording creates
# an impossible keep-old-vs-bind-new deadlock.
profile_project="${TEST_ROOT}/profile-project"
mkdir -p "${profile_project}"
profile_project_physical="$(cd "${profile_project}" && pwd -P)"
profile_project_key="$(cd "${profile_project_physical}" && _omc_project_key)"
profile_file="${HOME}/.claude/omc-user/quality-constitutions/profiles/qcp_${profile_project_key}/constitution.json"
printf 'reference version A\n' >"${profile_project}/exemplar.txt"
reference_a="$(_quality_contract_sha256_file "${profile_project}/exemplar.txt")"
observation_a="$(jq -cn --arg digest "${reference_a}" '
  [{id:"qr_contract_1",kind:"repo_path",locator:"exemplar.txt",
    recorded_digest:$digest,observed_digest:$digest,integrity:"verified",detail:""}]')"
old_profile_statement='Prefer causal proof over generic quality claims'
new_profile_statement='Prefer causal proof with explicit failure receipts'
write_state "cwd" "${profile_project}"
write_current_profile_snapshot "${old_profile_statement}" 1 \
  "${observation_a}" "${profile_file}" "${reference_a}"
profile_objective_digest="$(_quality_contract_digest \
  'Build the full Definition of Excellent engine')"
profile_contract_v1="$(quality_contract_build_envelope \
  "${profile_bound}" 7 100 3 "${profile_objective_digest}" generation-1 \
  1 120 quality-planner native-profile-1 dispatch-profile-12345678 1)"
seed_current_state "${profile_contract_v1}"
assert_success "live profile and repository reference validate before drift" \
  quality_contract_validate_current
live_snapshot="$(<"$(session_file quality_constitution_snapshot.json)")"
for nul_digest_field in digest profile_digest reference_integrity_digest; do
  assert_failure "compiled snapshot rejects NUL-tailed ${nul_digest_field}" \
    _quality_contract_snapshot_live_current \
    "$(jq --arg field "${nul_digest_field}" \
      '.[$field] += "\u0000"' <<<"${live_snapshot}")"
done
assert_failure "compiled snapshot rejects fractional generation authority" \
  _quality_contract_snapshot_live_current \
  "$(jq '.generation=1.5' <<<"${live_snapshot}")"
assert_failure "compiled snapshot rejects oversized generation authority" \
  _quality_contract_snapshot_live_current \
  "$(jq '.generation=1000000000000000' <<<"${live_snapshot}")"
profile_state_generation="$(read_state quality_constitution_generation)"
write_state "quality_constitution_generation" "1000000000000000"
assert_failure "profile metadata rejects oversized generation mirror" \
  _quality_contract_profile_metadata_json
write_state "quality_constitution_generation" "${profile_state_generation}"
omitted_claim_snapshot="$(jq '.blocking_claims = []' <<<"${live_snapshot}")"
assert_failure "compiled snapshot cannot omit a live matching blocking claim" \
  _quality_contract_snapshot_live_current "${omitted_claim_snapshot}"
fabricated_claim_snapshot="$(jq \
  '.advisory_claims = [.blocking_claims[0] | .enforcement = "advisory"]' \
  <<<"${live_snapshot}")"
assert_failure "compiled snapshot cannot fabricate an advisory profile claim" \
  _quality_contract_snapshot_live_current "${fabricated_claim_snapshot}"
forged_selector_snapshot="$(jq '.selectors.domain = "research"' \
  <<<"${live_snapshot}")"
assert_failure "compiled selector must match the router state mirror" \
  _quality_contract_snapshot_live_current "${forged_selector_snapshot}"
inconsistent_snapshot="$(jq \
  '.reference_observations[0].recorded_digest = ("b" * 64)' \
  <<<"${live_snapshot}")"
inconsistent_reference_digest="$(_quality_contract_sha256_canonical_json_text \
  "$(jq -c '.reference_observations' <<<"${inconsistent_snapshot}")")"
inconsistent_effective_digest="$(_quality_contract_effective_constitution_digest \
  "$(jq -r '.profile_digest' <<<"${inconsistent_snapshot}")" \
  "${inconsistent_reference_digest}")"
inconsistent_snapshot="$(jq \
  --arg reference_digest "${inconsistent_reference_digest}" \
  --arg digest "${inconsistent_effective_digest}" \
  '.reference_integrity_digest = $reference_digest | .digest = $digest' \
  <<<"${inconsistent_snapshot}")"
assert_failure "verified reference identity requires equal recorded and observed digests" \
  _quality_contract_snapshot_live_current "${inconsistent_snapshot}"
omitted_snapshot="$(jq '.reference_observations = []' <<<"${live_snapshot}")"
omitted_reference_digest="$(_quality_contract_sha256_canonical_json_text '[]')"
omitted_effective_digest="$(_quality_contract_effective_constitution_digest \
  "$(jq -r '.profile_digest' <<<"${omitted_snapshot}")" \
  "${omitted_reference_digest}")"
omitted_snapshot="$(jq --arg reference_digest "${omitted_reference_digest}" \
  --arg digest "${omitted_effective_digest}" '
    .reference_integrity_digest = $reference_digest | .digest = $digest
  ' <<<"${omitted_snapshot}")"
assert_failure "resealed snapshot cannot omit a live profile reference" \
  _quality_contract_snapshot_live_current "${omitted_snapshot}"
alternate_profile_dir="${profile_file%/*}/../qcp_unrelated_profile"
mkdir -p "${alternate_profile_dir}"
cp "${profile_file}" "${alternate_profile_dir}/constitution.json"
aliased_profile_snapshot="$(jq --arg path \
  "${profile_file%/*}/../qcp_unrelated_profile/constitution.json" \
  '.profile_path = $path' <<<"${live_snapshot}")"
assert_failure "profile path is exact-project-bound, not lexical-prefix-bound" \
  _quality_contract_snapshot_live_current "${aliased_profile_snapshot}"
mv "${profile_file}" "${profile_file}.real"
ln -s "${profile_file}.real" "${profile_file}"
assert_failure "symlinked live Constitution profile is never followed" \
  _quality_contract_snapshot_live_current "${live_snapshot}"
rm -f "${profile_file}"
mv "${profile_file}.real" "${profile_file}"
profile_user_root="${HOME}/.claude/omc-user"
mv "${profile_user_root}" "${profile_user_root}.real"
ln -s "${profile_user_root}.real" "${profile_user_root}"
assert_failure "symlinked omc-user ancestor is never followed" \
  _quality_contract_snapshot_live_current "${live_snapshot}"
rm -f "${profile_user_root}"
mv "${profile_user_root}.real" "${profile_user_root}"
profile_claude_root="${HOME}/.claude"
mv "${profile_claude_root}" "${profile_claude_root}.real"
ln -s "${profile_claude_root}.real" "${profile_claude_root}"
assert_failure "symlinked .claude ancestor is never followed" \
  _quality_contract_snapshot_live_current "${live_snapshot}"
rm -f "${profile_claude_root}"
mv "${profile_claude_root}.real" "${profile_claude_root}"
profile_digest_mirror="$(read_state quality_constitution_digest)"
write_state "quality_constitution_digest" "mismatched-constitution-digest"
assert_failure "snapshot and session digest mirrors must agree" \
  quality_contract_validate_current
write_state "quality_constitution_digest" "${profile_digest_mirror}"
profile_selector_mirror="$(read_state quality_constitution_selectors)"
write_state "quality_constitution_selectors" \
  '{"audience":"","domain":"research","path":"","surface":"","task_type":"research"}'
assert_failure "snapshot and session selector mirrors must agree" \
  quality_contract_validate_current
write_state "quality_constitution_selectors" "${profile_selector_mirror}"
write_state "quality_constitution_blocking_ids" '[]'
assert_failure "snapshot and session blocking-ID mirrors must agree" \
  quality_contract_validate_current
write_state "quality_constitution_blocking_ids" '["qc_taste_blocking_1"]'
printf 'reference version B\n' >"${profile_project}/exemplar.txt"
assert_failure "live repository-reference drift stales the frozen contract" \
  quality_contract_validate_current
reference_b="$(_quality_contract_sha256_file "${profile_project}/exemplar.txt")"
laundered_snapshot="$(jq --arg digest "${reference_b}" '
  .reference_observations[0].recorded_digest = $digest
  | .reference_observations[0].observed_digest = $digest
  | .reference_observations[0].integrity = "verified"
  | .reference_observations[0].detail = ""
' <<<"${live_snapshot}")"
laundered_reference_digest="$(_quality_contract_sha256_canonical_json_text \
  "$(jq -c '.reference_observations' <<<"${laundered_snapshot}")")"
laundered_effective_digest="$(_quality_contract_effective_constitution_digest \
  "$(jq -r '.profile_digest' <<<"${laundered_snapshot}")" \
  "${laundered_reference_digest}")"
laundered_snapshot="$(jq --arg reference_digest "${laundered_reference_digest}" \
  --arg digest "${laundered_effective_digest}" '
    .reference_integrity_digest = $reference_digest | .digest = $digest
  ' <<<"${laundered_snapshot}")"
assert_failure "resealed current bytes cannot launder a drifted recorded reference" \
  _quality_contract_snapshot_live_current "${laundered_snapshot}"
observation_b="$(jq -cn --arg recorded "${reference_a}" --arg observed "${reference_b}" '
  [{id:"qr_contract_1",kind:"repo_path",locator:"exemplar.txt",
    recorded_digest:$recorded,observed_digest:$observed,integrity:"drifted",
    detail:"current artifact digest differs from the user-confirmed digest"}]')"
write_current_profile_snapshot "${old_profile_statement}" 1 \
  "${observation_b}" "${profile_file}" "${reference_a}"
assert_success "unchanged definition preserves the pre-drift contract floor" \
  quality_contract_revision_preserves_floor "${profile_bound}" "${profile_contract_v1}"
profile_contract_v2="$(quality_contract_build_envelope \
  "${profile_bound}" 7 100 3 "${profile_objective_digest}" generation-1 \
  2 130 quality-planner native-profile-2 dispatch-profile-22345678 2)"
jq -c --argjson archived_at 130 \
  '. + {archived_at:$archived_at,archive_reason:"contract-revision"}' \
  <<<"${profile_contract_v1}" >"$(session_file quality_contract_history.jsonl)"
printf '%s\n' "${profile_contract_v2}" >"$(session_file quality_contract.json)"
seed_current_state "${profile_contract_v2}"
write_state_batch \
  "plan_revision" "2" \
  "quality_contract_plan_revision" "2"
assert_success "recompiled quarantined reference can publish a current additive revision" \
  quality_contract_validate_current

write_current_profile_snapshot "${new_profile_statement}" 2 \
  "${observation_b}" "${profile_file}" "${reference_a}"
assert_success "old envelope remains intrinsically valid after profile rewording" \
  quality_contract_validate_envelope "${profile_contract_v1}"
assert_failure "pre-reword contract is stale against the live Constitution" \
  quality_contract_validate_current
reworded_profile_definition="$(jq --arg statement "${new_profile_statement}" '
  .standards += [{kind:"profile",reference:$statement,
    rationale:"The current user-pinned wording is independently binding",
    profile_entry_id:"qc_taste_blocking_1"}]
' <<<"${profile_bound}")"
assert_success "reworded profile may coexist with its byte-exact frozen predecessor" \
  quality_contract_validate_payload "${reworded_profile_definition}"
assert_success "reworded profile definition preserves the original standard floor" \
  quality_contract_revision_preserves_floor \
    "${reworded_profile_definition}" "${profile_contract_v1}"
profile_contract_v3="$(quality_contract_build_envelope \
  "${reworded_profile_definition}" 7 100 3 "${profile_objective_digest}" generation-1 \
  3 140 quality-planner native-profile-3 dispatch-profile-32345678 3)"
jq -c --argjson archived_at 140 \
  '. + {archived_at:$archived_at,archive_reason:"contract-revision"}' \
  <<<"${profile_contract_v2}" >>"$(session_file quality_contract_history.jsonl)"
printf '%s\n' "${profile_contract_v3}" >"$(session_file quality_contract.json)"
seed_current_state "${profile_contract_v3}"
write_state_batch \
  "plan_revision" "3" \
  "quality_contract_plan_revision" "3"
assert_success "additive reword revision binds current taste and retained history" \
  quality_contract_validate_current
dropped_frozen_profile="$(jq --arg old "${old_profile_statement}" '
  .standards |= map(select(.kind != "profile" or .reference != $old))
' <<<"${reworded_profile_definition}")"
assert_failure "profile reword cannot drop its already-frozen predecessor" \
  quality_contract_revision_preserves_floor \
    "${dropped_frozen_profile}" "${profile_contract_v1}"

rm -f "$(session_file quality_contract.json)" \
  "$(session_file quality_contract_history.jsonl)" \
  "$(session_file quality_constitution_snapshot.json)"
write_state_batch \
  "quality_constitution_status" "disabled" \
  "quality_constitution_generation" "" \
  "quality_constitution_digest" "" \
  "quality_constitution_blocking_ids" '[]' \
  "cwd" ""

additive_revision="$(jq '.criteria += [{id:"Q-007",class:"aspiration",axis:"visionary",claim:"A second reversible follow-on experiment remains available",rationale:"The frozen floor may be extended without being weakened",surfaces:["future experiment"],proof_method:"Compare the Q-007 reversible experiment against the shipped baseline",proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],command_contains:["tests/test-quality-constitution-authority.sh","Q-007","comparison"],artifact_contains:[]},failure_signal:"The experiment cannot be reversed or has no measurable user benefit",tradeoff_boundary:"The aspiration may not delay the proven must-criteria",evidence_policy:{allowed_kinds:["comparison"],minimum:1,requires_empirical:true,requires_independent_review:true}}]' <<<"${definition}")"
assert_success "replan may add aspiration without lowering floor" \
  quality_contract_revision_preserves_floor "${additive_revision}" "${contract}"
weakened_revision="$(jq '(.criteria[] | select(.id == "Q-003") | .claim) = "A weaker visionary claim replaces the measured leap"' <<<"${definition}")"
assert_failure "replan cannot weaken an old must criterion" \
  quality_contract_revision_preserves_floor "${weakened_revision}" "${contract}"
dropped_anti_goal="$(jq '.anti_goals=["Do not expand beyond the frozen objective boundary"]' <<<"${definition}")"
assert_failure "replan cannot drop frozen anti-goals" \
  quality_contract_revision_preserves_floor "${dropped_anti_goal}" "${contract}"
dropped_user_standard="$(jq '.standards |= map(select(.kind != "user"))' <<<"${definition}")"
assert_failure "replan cannot drop explicit user standards" \
  quality_contract_revision_preserves_floor "${dropped_user_standard}" "${contract}"
changed_north_star="$(jq '.north_star = "A retrospective finish line rewritten after implementation began"' <<<"${definition}")"
assert_failure "replan cannot rewrite the frozen north star" \
  quality_contract_revision_preserves_floor "${changed_north_star}" "${contract}"
changed_axis="$(jq '.axes.distinctive = "A different post-hoc definition of distinctiveness now applies"' <<<"${definition}")"
assert_failure "replan cannot rewrite a frozen axis" \
  quality_contract_revision_preserves_floor "${changed_axis}" "${contract}"
dropped_aspiration="$(jq '.criteria |= map(select(.class != "aspiration"))' <<<"${definition}")"
assert_failure "replan cannot silently drop a frozen aspiration" \
  quality_contract_revision_preserves_floor "${dropped_aspiration}" "${contract}"

# Objective identity may change inside one review cycle only through the
# router's exact one-use additive-scope transition. The older addition ledger
# is duplicate-delivery metadata and is deliberately insufficient by itself.
seed_current_state "${contract}"
write_state "quality_contract_enforcement_generation" "generation-1"
scope_addition='also ship an interactive migration preview and rollback path'
scope_addition_digest="$(_omc_authority_digest "${scope_addition}")"
scope_objective=$'Build the full Definition of Excellent engine\n\nScope addition (authoritative):\n'"${scope_addition}"
scope_objective_digest="$(_quality_contract_digest "${scope_objective}")"
arbitrary_objective='Replace the objective with an unrelated reporting product'
arbitrary_objective_digest="$(_quality_contract_digest \
  "${arbitrary_objective}")"
write_state_batch \
  "current_objective" "${arbitrary_objective}" \
  "quality_contract_prompt_revision" "4" \
  "quality_contract_recheck_required" "1" \
  "quality_contract_status" "recheck-required" \
  "quality_contract_scope_addition_digests" "${scope_addition_digest}" \
  "quality_contract_scope_transition" ""
assert_failure "stale addition ledger cannot authorize arbitrary objective swap" \
  quality_contract_build_envelope "${additive_revision}" 7 100 4 \
    "${arbitrary_objective_digest}" generation-1 2 130 quality-planner \
    native-scope-negative dispatch-scope-negative-12345678 2

scope_transition="$(jq -cnS \
  --arg prior_contract_id "$(jq -r '.contract_id' <<<"${contract}")" \
  --argjson prior_contract_revision "$(jq -r '.contract_revision' \
    <<<"${contract}")" \
  --arg prior_objective_digest "$(jq -r '.objective_digest' \
    <<<"${contract}")" \
  --arg merged_objective_digest "${scope_objective_digest}" \
  --arg addition_digest "${scope_addition_digest}" '
    {schema_version:1,prior_contract_id:$prior_contract_id,
     prior_contract_revision:$prior_contract_revision,
     prior_objective_digest:$prior_objective_digest,
     merged_objective_digest:$merged_objective_digest,
     scope_prompt_revision:4,review_cycle_id:7,
     enforcement_generation:"generation-1",
     addition_digests:[$addition_digest]}
  ')"
write_state "quality_contract_scope_transition" "${scope_transition}"
assert_failure "transition cannot authorize a different merged objective" \
  quality_contract_build_envelope "${additive_revision}" 7 100 4 \
    "${arbitrary_objective_digest}" generation-1 2 130 quality-planner \
    native-scope-mismatch dispatch-scope-mismatch-12345678 2

write_state "current_objective" "${scope_objective}"
# Guard/Stop diagnostics may replace this fast status mirror after denying a
# mutation. The exact latch and transition, not the observational mirror, own
# additive re-contract authorization.
write_state "quality_contract_status" "missing-or-stale"
scope_contract="$(quality_contract_build_envelope \
  "${additive_revision}" 7 100 4 "${scope_objective_digest}" generation-1 \
  2 130 quality-planner native-scope-positive \
  dispatch-scope-positive-12345678 2)"
assert_success "status-mirror drift cannot revoke an exact additive scope transition" \
  quality_contract_validate_envelope "${scope_contract}"
assert_eq "additive envelope binds merged objective digest" \
  "${scope_objective_digest}" \
  "$(jq -r '.objective_digest' <<<"${scope_contract}")"

jq -c '. + {archived_at:130,archive_reason:"contract-revision"}' \
  <<<"${contract}" >"$(session_file quality_contract_history.jsonl)"
printf '%s\n' "${scope_contract}" >"$(session_file quality_contract.json)"
write_state_batch \
  "quality_contract_id" "$(jq -r '.contract_id' <<<"${scope_contract}")" \
  "quality_contract_revision" "2" \
  "quality_contract_plan_revision" "2" \
  "quality_contract_prompt_revision" "4" \
  "quality_contract_enforcement_generation" "generation-1" \
  "quality_contract_recheck_required" "" \
  "quality_contract_scope_transition" "" \
  "quality_contract_status" "frozen" \
  "plan_revision" "2"
assert_success "accepted additive contract validates after transition consumption" \
  quality_contract_validate_current

# Restore the baseline fixture used by the remaining currentness/gate tests.
rm -f "$(session_file quality_contract_history.jsonl)"
seed_current_state "${contract}"
write_state_batch \
  "quality_contract_enforcement_generation" "generation-1" \
  "quality_contract_scope_addition_digests" "" \
  "quality_contract_scope_transition" "" \
  "quality_contract_status" "frozen"
assert_success "current state accepts matching causal envelope" quality_contract_validate_current
current_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=100
assert_success "current sealed contract survives later verifier-threshold changes" \
  quality_contract_validate_current
OMC_VERIFY_CONFIDENCE_THRESHOLD="${current_threshold_before}"
printf '%s\n' "${contract}" >"$(session_file quality_contract_floor.json)"
write_state_batch \
  "first_mutation_ts" "121" \
  "quality_contract_frozen_id" "$(jq -r '.contract_id' <<<"${contract}")" \
  "quality_contract_frozen_revision" "$(jq -r '.contract_revision' <<<"${contract}")" \
  "quality_contract_frozen_payload_digest" "$(jq -r '.payload_digest' <<<"${contract}")"
assert_success "current contract remains bound to immutable mutation floor" \
  quality_contract_validate_current
rm -f "$(session_file quality_contract_floor.json)"
assert_failure "deleting frozen floor after review invalidates current contract" \
  quality_contract_validate_current
printf '%s\n' "${contract}" >"$(session_file quality_contract_floor.json)"
tampered="$(jq '.definition.axes.visionary = "A different unsealed ambition now replaces the planned one"' <<<"${contract}")"
assert_failure "payload tampering breaks digest" quality_contract_validate_envelope "${tampered}"
tampered_planner="$(jq '.planner.native_agent_id = "native-attacker-1"' <<<"${contract}")"
assert_failure "planner identity tampering breaks contract identity" \
  quality_contract_validate_envelope "${tampered_planner}"
tampered_late="$(jq '.late = true' <<<"${contract}")"
assert_failure "late-freeze metadata is sealed into contract identity" \
  quality_contract_validate_envelope "${tampered_late}"
write_state "quality_contract_prompt_revision" "4"
assert_failure "wrong objective prompt revision is stale" quality_contract_validate_current
write_state "quality_contract_prompt_revision" "3"
write_state "quality_constitution_status" "invalid"
assert_failure "corrupt user-owned constitution fails current contract closed" \
  quality_contract_validate_current
write_state "quality_constitution_status" "disabled"
write_state "review_cycle_id" "8"
assert_failure "prior-cycle replay is stale" quality_contract_validate_current
write_state "review_cycle_id" "7"
write_state "quality_contract_recheck_required" "1"
assert_failure "scope-expanding continuation forces recontract" quality_contract_validate_current
write_state "quality_contract_recheck_required" ""

printf 'Test 5: review envelope must cover exact contract and agree with verdict\n'
review="$(valid_review "${contract}")"
assert_success "SHIP review matches contract and clear frontier" \
  quality_review_validate_against_contract "${review}" "${contract}" "VERDICT: SHIP"
review_message=$'Review prose\nQUALITY_REVIEW_JSON: '"${review}"$'\nVERDICT: SHIP'
review_canonical="$(quality_review_extract_json "${review_message}")"
assert_eq "review extraction preserves exact criterion set" "Q-001,Q-002,Q-003,Q-004,Q-005,Q-006" \
  "$(jq -r '[.criteria[].id] | join(",")' <<<"${review_canonical}")"
replayed_review="$(jq '(.criteria[] | select(.id == "Q-003") | .evidence_kind) = "source"' <<<"${review}")"
assert_failure "review cannot replay evidence under a different contract policy" \
  quality_review_validate_against_contract "${replayed_review}" "${contract}" "VERDICT: SHIP"
forged_frontier_reference="$(jq '.frontier.evidence=["vr-forged-frontier-0001"]' \
  <<<"${review}")"
assert_failure "frontier evidence must cite a criterion assessment receipt" \
  quality_review_validate_against_contract \
    "${forged_frontier_reference}" "${contract}" "VERDICT: SHIP"
missing_assessment="$(jq '.criteria |= map(select(.id != "Q-003"))' <<<"${review}")"
assert_failure "review cannot silently omit visionary criterion" \
  quality_review_validate_against_contract "${missing_assessment}" "${contract}" "VERDICT: SHIP"
open_ship="$(jq '.frontier.material=true | .frontier.criterion_ids=["Q-003"] | (.criteria[] | select(.id == "Q-003") | .status)="unmet"' <<<"${review}")"
assert_failure "SHIP cannot coexist with material open frontier" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: SHIP"
assert_success "FINDINGS count equals the deterministic unmet count" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: FINDINGS (1)"
assert_success "review canonicalizer returns a schema-valid normalized payload" \
  quality_review_validate_payload "$(quality_review_canonicalize_payload "${review}")"
collapsed_alternatives="$(jq '
  .alternatives_searched = [
    "Compared the same bounded alternative against the baseline",
    "  Compared the same bounded alternative against the baseline  "]
' <<<"${review}")"
assert_failure "trim-equivalent alternatives cannot collapse below the schema floor" \
  quality_review_validate_payload "${collapsed_alternatives}"
collapsed_limits="$(jq '
  .limits = ["Production traffic remains unobserved",
    "  Production traffic remains unobserved  "]
' <<<"${review}")"
assert_failure "trim-equivalent review limits are not silently merged" \
  quality_review_validate_payload "${collapsed_limits}"
spaced_assessment_ref="$(jq '
  (.criteria[] | select(.id == "Q-001") | .refs) = [" vr-proof-001 "]
' <<<"${review}")"
assert_failure "assessment receipt IDs reject surrounding-space aliases" \
  quality_review_validate_payload "${spaced_assessment_ref}"
spaced_frontier_ref="$(jq '
  .frontier.evidence = [" vr-proof-003 "]
' <<<"${review}")"
assert_failure "frontier receipt IDs reject surrounding-space aliases" \
  quality_review_validate_payload "${spaced_frontier_ref}"
assert_failure "FINDINGS count cannot overstate the unmet count" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: FINDINGS (2)"
empty_open_frontier="$(jq '.frontier.material=true | .frontier.criterion_ids=[] | (.criteria[] | select(.id == "Q-003") | .status)="unmet"' <<<"${review}")"
assert_failure "FINDINGS must identify every unmet mandatory frontier criterion" \
  quality_review_validate_against_contract \
    "${empty_open_frontier}" "${contract}" "VERDICT: FINDINGS (1)"
unsupported_frontier="$(jq '.frontier.material=true | .frontier.criterion_ids=["Q-003"]' <<<"${review}")"
assert_success "material frontier may dominate an already-met threshold" \
  quality_review_validate_against_contract "${unsupported_frontier}" "${contract}" "VERDICT: FINDINGS (1)"
cost_rejection="$(jq '.alternatives_searched[1]="Rejected because the implementation was too expensive and time-consuming for this session"' <<<"${review}")"
assert_failure "cost is not evidence for rejecting the frontier" \
  quality_review_validate_payload "${cost_rejection}"
measured_rejection="$(jq '.alternatives_searched[1]="Rejected because the benchmark measured a 42 percent latency regression"' <<<"${review}")"
assert_success "measured counterevidence may reject a frontier candidate" \
  quality_review_validate_payload "${measured_rejection}"
cost_move="$(jq '.frontier.recommended_move="Do not pursue the implementation because it takes too long and is too expensive"' <<<"${review}")"
assert_failure "cost alone cannot clear the recommended frontier move" \
  quality_review_validate_payload "${cost_move}"
user_difficulty="$(jq '.frontier.why="Navigation is too hard for keyboard-only users under the measured interaction path"' <<<"${review}")"
assert_success "user difficulty is a quality finding, not implementation cost" \
  quality_review_validate_payload "${user_difficulty}"
decorated_cost="$(jq '.frontier.recommended_move="The implementation is too hard and takes too long but was tested manually"' <<<"${review}")"
assert_failure "cost prose cannot borrow authority from a decorative tested keyword" \
  quality_review_validate_payload "${decorated_cost}"
unicode_adjacent_cost="$(jq '.frontier.recommended_move="préimplementation takes too long for the candidate"' \
  <<<"${review}")"
assert_failure "Unicode-adjacent prose has the same cost boundary at publish and gate time" \
  quality_review_validate_payload "${unicode_adjacent_cost}"
workflow_latency="$(jq '.frontier.why="The workflow takes too long for keyboard users to complete the checkout"' \
  <<<"${review}")"
assert_success "workflow latency is not confused with implementation work cost" \
  quality_review_validate_payload "${workflow_latency}"
product_session_latency="$(jq '.frontier.why="The checkout session takes too long to load the alternative payment option"' \
  <<<"${review}")"
assert_success "product-session latency is not confused with implementation effort" \
  quality_review_validate_payload "${product_session_latency}"
implementation_user_latency="$(jq '.frontier.why="The current implementation takes too long to render the alternative checkout option for users"' \
  <<<"${review}")"
assert_failure "implementation cost wording cannot borrow a user-facing product noun" \
  quality_review_validate_payload "${implementation_user_latency}"
explicit_user_latency="$(jq '.frontier.why="Checkout takes too long for users to complete the alternative payment interaction"' \
  <<<"${review}")"
assert_success "explicit user workflow latency remains a product-quality finding" \
  quality_review_validate_payload "${explicit_user_latency}"
solution_keyboard_difficulty="$(jq '.frontier.why="The solution is too hard for keyboard users to use"' \
  <<<"${review}")"
assert_success "solution wording does not hide user-facing accessibility difficulty" \
  quality_review_validate_payload "${solution_keyboard_difficulty}"
forbidden_render_cost_phrases=(
  "The implementation takes too long to render the alternative, so we skipped it"
  "We skipped the candidate because the implementation takes too long to render"
  "The code change takes too long to render, so the alternative was not explored"
  "The implementation takes too long to render the alternative, so we abandoned it"
  "The implementation takes too long to render the alternative, so we left it out"
  "The implementation takes too long to render the alternative, so we chose not to pursue it"
  "The implementation takes too long to render the alternative, so we avoided further investigation"
  "The implementation takes too long to render the alternative; it was omitted"
  "The implementation takes too long to render the alternative, making it impractical"
)
for forbidden_render_cost_phrase in "${forbidden_render_cost_phrases[@]}"; do
  forbidden_render_cost_review="$(jq --arg value "${forbidden_render_cost_phrase}" \
    '.frontier.recommended_move=$value' <<<"${review}")"
  assert_failure "render wording cannot disguise engineering-cost deferral: ${forbidden_render_cost_phrase}" \
    quality_review_validate_payload "${forbidden_render_cost_review}"
done
unicode_casefold_boundary="$(jq '.frontier.recommended_move="İmplementation takes too long for the candidate"' \
  <<<"${review}")"
assert_success "non-ASCII casefold boundary is identical at publication time" \
  quality_review_validate_payload "${unicode_casefold_boundary}"
user_session_timeout="$(jq '.frontier.experiment="The checkout session ended before the alternative payment option loaded"' \
  <<<"${review}")"
assert_success "user session timeout remains product evidence" \
  quality_review_validate_payload "${user_session_timeout}"
time_pressure_experiment="$(jq '.frontier.experiment="We ran out of time, so no larger improvement was explored"' \
  <<<"${review}")"
assert_failure "review time pressure cannot replace frontier evidence" \
  quality_review_validate_payload "${time_pressure_experiment}"
time_constraints_experiment="$(jq '.frontier.experiment="Time constraints prevented exploring a stronger alternative"' \
  <<<"${review}")"
assert_failure "generic time constraints cannot replace frontier evidence" \
  quality_review_validate_payload "${time_constraints_experiment}"
limited_time_experiment="$(jq '.frontier.experiment="Limited time prevented exploring the alternative"' \
  <<<"${review}")"
assert_failure "limited process time cannot replace frontier evidence" \
  quality_review_validate_payload "${limited_time_experiment}"
time_limitations_experiment="$(jq '.frontier.experiment="Time limitations prevented testing the candidate"' \
  <<<"${review}")"
assert_failure "process time limitations cannot replace frontier evidence" \
  quality_review_validate_payload "${time_limitations_experiment}"
time_budget_experiment="$(jq '.frontier.experiment="The time budget did not permit another experiment"' \
  <<<"${review}")"
assert_failure "a process time budget cannot replace frontier evidence" \
  quality_review_validate_payload "${time_budget_experiment}"
scheduling_experiment="$(jq '.frontier.experiment="Scheduling constraints prevented exploring the improvement"' \
  <<<"${review}")"
assert_failure "scheduling pressure cannot replace frontier evidence" \
  quality_review_validate_payload "${scheduling_experiment}"
forbidden_time_phrases=(
  "We lacked time to explore another candidate"
  "No time remained to test the alternative"
  "The schedule did not allow us to compare another option"
  "The timebox ended before we explored another candidate"
  "We could not test the alternative before the deadline"
  "We ran out of runway before testing the candidate"
)
for forbidden_time_phrase in "${forbidden_time_phrases[@]}"; do
  forbidden_time_review="$(jq --arg value "${forbidden_time_phrase}" \
    '.frontier.experiment=$value' <<<"${review}")"
  assert_failure "ordinary process time pressure cannot clear frontier: ${forbidden_time_phrase}" \
    quality_review_validate_payload "${forbidden_time_review}"
done
cross_sentence_time_phrases=(
  "We ran out of time. No larger alternative was explored."
  "The deadline arrived. We did not test another candidate."
  "Time constraints prevented further work. The visionary option remains unexplored."
  "No time remained. Another candidate was not compared."
)
for cross_sentence_time_phrase in "${cross_sentence_time_phrases[@]}"; do
  cross_sentence_time_review="$(jq --arg value "${cross_sentence_time_phrase}" \
    '.frontier.experiment=$value' <<<"${review}")"
  assert_failure "punctuation cannot separate process-time cost from the frontier: ${cross_sentence_time_phrase}" \
    quality_review_validate_payload "${cross_sentence_time_review}"
done
cost_only_limit="$(jq '.limits=["The implementation is too expensive for another candidate"]' \
  <<<"${review}")"
assert_failure "engineering cost cannot be hidden in review limits" \
  quality_review_validate_payload "${cost_only_limit}"
time_only_limit="$(jq '.limits=["We ran out of time before exploring another candidate"]' \
  <<<"${review}")"
assert_failure "process-time deferral cannot be hidden in review limits" \
  quality_review_validate_payload "${time_only_limit}"
time_only_title="$(jq '.frontier.title="No time remained for another alternative"' \
  <<<"${review}")"
assert_failure "process-time deferral cannot be hidden in the frontier title" \
  quality_review_validate_payload "${time_only_title}"
external_limit="$(jq '.limits=["Production traffic remains unobserved because the external staging API is unavailable"]' \
  <<<"${review}")"
assert_success "a concrete external production-observation limit remains admissible" \
  quality_review_validate_payload "${external_limit}"
insufficient_time_experiment="$(jq '.frontier.experiment="Insufficient time prevented testing the next candidate"' \
  <<<"${review}")"
assert_failure "insufficient time cannot replace frontier evidence" \
  quality_review_validate_payload "${insufficient_time_experiment}"
deadline_experiment="$(jq '.frontier.experiment="The deadline left too little time to explore another option"' \
  <<<"${review}")"
assert_failure "generic deadline pressure cannot replace frontier evidence" \
  quality_review_validate_payload "${deadline_experiment}"
deadline_product_option="$(jq '.frontier.why="The deadline option was not visible to keyboard users"' \
  <<<"${review}")"
assert_success "a product deadline option is not confused with review pressure" \
  quality_review_validate_payload "${deadline_product_option}"
deadline_product_latency="$(jq '.frontier.why="The deadline option loaded after checkout"' \
  <<<"${review}")"
assert_success "product deadline-option latency remains admissible evidence" \
  quality_review_validate_payload "${deadline_product_latency}"
limited_time_product_option="$(jq '.frontier.why="The limited time offer option loaded after checkout"' \
  <<<"${review}")"
assert_success "a limited-time product option is not process pressure" \
  quality_review_validate_payload "${limited_time_product_option}"

printf 'Test 6: evidence and frontier gate recomputes current proof\n'
write_evidence "${contract}" 0
fixture_receipts_json="$(jq -sc '.' \
  "$(session_file verification_receipts.jsonl)")"
assert_success "schema-v3 fixture ledger validates with rederived receipt IDs" \
  _quality_contract_receipts_schema_valid "${fixture_receipts_json}"
assert_failure "receipt row cap rejects leading-zero arithmetic text" \
  _quality_contract_receipts_schema_valid "${fixture_receipts_json}" 08
assert_failure "JSONL byte cap rejects leading-zero arithmetic text" \
  _quality_contract_read_jsonl_array \
  "$(session_file verification_receipts.jsonl)" 08 512
assert_failure "JSONL line cap rejects leading-zero arithmetic text" \
  _quality_contract_read_jsonl_array \
  "$(session_file verification_receipts.jsonl)" 262144 08
assert_failure "JSON byte cap rejects leading-zero arithmetic text" \
  _quality_contract_read_json_file "$(session_file session_state.json)" 08
raw_nul_json="${TEST_ROOT}/raw-nul-authority.json"
raw_nul_jsonl="${TEST_ROOT}/raw-nul-authority.jsonl"
decoded_nul_json="${TEST_ROOT}/decoded-nul-authority.json"
decoded_nul_jsonl="${TEST_ROOT}/decoded-nul-authority.jsonl"
printf '{"revision":1\000}\n' >"${raw_nul_json}"
printf '{"revision":1\000}\n' >"${raw_nul_jsonl}"
printf '%s\n' '{"revision":"unsafe\u0000value"}' >"${decoded_nul_json}"
printf '%s\n' '{"unsafe\u0000key":1}' >"${decoded_nul_jsonl}"
assert_failure "JSON authority reader rejects literal NUL accepted by jq" \
  _quality_contract_read_json_file "${raw_nul_json}" 65536
assert_failure "JSONL authority reader rejects literal NUL accepted by jq" \
  _quality_contract_read_jsonl_array "${raw_nul_jsonl}" 65536 4
assert_failure "JSON authority reader rejects decoded NUL values" \
  _quality_contract_read_json_file "${decoded_nul_json}" 65536
assert_failure "JSONL authority reader rejects decoded NUL keys" \
  _quality_contract_read_jsonl_array "${decoded_nul_jsonl}" 65536 4
printf '%s' '{"revision":1}' >"${raw_nul_jsonl}"
assert_failure "JSONL authority reader rejects an unterminated final row" \
  _quality_contract_read_jsonl_array "${raw_nul_jsonl}" 65536 4

run_authority_reader_replacement_race() {
  local mode="$1" label="$2" source replacement ready release output errors
  local reader_pid reader_rc reader_attempt ready_seen expected_digest
  local actual_digest output_bytes temp_count temp_path
  source="${TEST_ROOT}/reader-race-${mode}"
  replacement="${source}.replacement"
  ready="${source}.ready"
  release="${source}.release"
  output="${source}.output"
  errors="${source}.errors"
  if [[ "${mode}" == "json" ]]; then
    printf '%s\n' '{"revision":1}' >"${source}"
  else
    printf '%s\n%s\n' '{"revision":1}' '{"revision":2}' >"${source}"
  fi
  (
    export OMC_TEST_QUALITY_CONTRACT_READER_READY_FILE="${ready}"
    export OMC_TEST_QUALITY_CONTRACT_READER_RELEASE_FILE="${release}"
    export OMC_TEST_QUALITY_CONTRACT_READER_MATCH_FILE="${source}"
    if [[ "${mode}" == "json" ]]; then
      _quality_contract_read_json_file "${source}" 65536
    else
      _quality_contract_read_jsonl_array "${source}" 65536 4
    fi
  ) >"${output}" 2>"${errors}" &
  reader_pid=$!

  reader_attempt=0
  ready_seen=0
  while [[ ! -f "${ready}" && "${reader_attempt}" -lt 500 ]]; do
    kill -0 "${reader_pid}" 2>/dev/null || break
    sleep 0.01
    reader_attempt=$((reader_attempt + 1))
  done
  if [[ -f "${ready}" && ! -L "${ready}" ]]; then
    ready_seen=1
  fi

  # jq accepts a literal NUL in this position after silently normalizing it.
  # Replacing the public inode after the private parse must still invalidate
  # the read, emit no stale payload, and leave the replacement untouched.
  printf '{"revision":3\000}\n' >"${replacement}"
  expected_digest="$(_verification_sha256_file "${replacement}")"
  mv -f "${replacement}" "${source}"
  : >"${release}"
  set +e
  wait "${reader_pid}"
  reader_rc=$?
  set -e

  if [[ "${reader_rc}" -ne 0 ]]; then
    ok
  else
    bad "${label} rejects an atomic replacement after parsing"
  fi
  output_bytes="$(LC_ALL=C wc -c <"${output}" | tr -d '[:space:]')"
  assert_eq "${label} emits no stale snapshot after replacement" \
    "0" "${output_bytes}"
  actual_digest="$(_verification_sha256_file "${source}")"
  assert_eq "${label} does not rewrite the replacement authority" \
    "${expected_digest}" "${actual_digest}"

  temp_count=0
  for temp_path in "${source}.quality-read."*; do
    [[ -e "${temp_path}" || -L "${temp_path}" ]] || continue
    temp_count=$((temp_count + 1))
  done
  assert_eq "${label} removes its private snapshot after rejection" \
    "0" "${temp_count}"
  assert_eq "${label} test synchronization completed" "1" "${ready_seen}"
}

run_authority_reader_replacement_race json "JSON authority reader"
run_authority_reader_replacement_race jsonl "JSONL authority reader"

for bounded_field in edit_revision code_revision plan_revision review_cycle_id \
    quality_contract_revision ts; do
  oversized_receipt="$(jq -c --arg field "${bounded_field}" \
    '.[0][$field]=1000000000000000' <<<"${fixture_receipts_json}")"
  assert_failure "receipt rejects oversized ${bounded_field}" \
    _quality_contract_receipts_schema_valid "${oversized_receipt}"
done
assert_failure "receipt rejects exponent timestamp authority" \
  _quality_contract_receipts_schema_valid \
  "$(jq -c '.[0].ts=1e100' <<<"${fixture_receipts_json}")"
fixture_bash_receipt="$(jq -c \
  'map(select(.tool_name == "Bash"))[0]' <<<"${fixture_receipts_json}")"
fixture_v2_receipt="$(jq -c '._v=2' <<<"${fixture_bash_receipt}")"
assert_failure "schema-v2 verification receipts fail closed explicitly" \
  _quality_contract_receipts_schema_valid "[${fixture_v2_receipt}]" 1
fixture_command_tamper="$(jq -c '.command += " --forged"' \
  <<<"${fixture_bash_receipt}")"
assert_failure "stored command text cannot drift from its sealed digest" \
  _quality_contract_receipts_schema_valid "[${fixture_command_tamper}]" 1
fixture_result_tamper="$(jq -c '.result="99 tests passed"' \
  <<<"${fixture_bash_receipt}")"
assert_failure "reviewer-visible result excerpt is receipt-ID material" \
  _quality_contract_receipts_schema_valid "[${fixture_result_tamper}]" 1
fixture_substituted_paths="$(jq -c '
  .launcher_path=.subject_path
  | .launcher_digest=.subject_digest
  | .launcher_identity=.subject_identity
' <<<"${fixture_bash_receipt}")"
fixture_substituted_id="$(_quality_contract_receipt_expected_id \
  "${fixture_substituted_paths}")"
fixture_substituted_paths="$(jq -c --arg id "${fixture_substituted_id}" \
  '.receipt_id=$id' <<<"${fixture_substituted_paths}")"
assert_success "substituted path fixture remains structurally sealed" \
  _quality_contract_receipts_schema_valid "[${fixture_substituted_paths}]" 1
assert_failure "Bash provenance paths must rederive from the stored command" \
  _quality_contract_receipt_provenance_current "${fixture_substituted_paths}"
grep_current_dir="${TEST_ROOT}/grep-current-proof"
mkdir -p "${grep_current_dir}"
printf '%s\n' 'stable exact Grep source' >"${grep_current_dir}/source.txt"
grep_current_cwd="$(_verification_normalize_proof_path "${grep_current_dir}")"
grep_current_path="$(_verification_normalize_proof_path \
  "${grep_current_dir}/source.txt" 0 source)"
grep_current_digest="$(_verification_sha256_file "${grep_current_path}")"
grep_current_identity="$(_verification_file_identity \
  "${grep_current_path}" "${grep_current_cwd}")"
grep_current_receipt="$(jq -cn \
  --arg path "${grep_current_path}" --arg digest "${grep_current_digest}" \
  --arg identity "${grep_current_identity}" --arg cwd "${grep_current_cwd}" '
  {tool_name:"Grep",outcome:"passed",command:("Grep:"+$path+":stable"),
   artifact_target:$path,subject_path:$path,subject_digest:$digest,
   subject_identity:$identity,tool_cwd:$cwd}')"
assert_success "current Grep source provenance validates before replacement" \
  _quality_contract_receipt_provenance_current "${grep_current_receipt}"
printf '%s\n' 'unrelated settled sibling' >"${grep_current_dir}/sibling.txt"
grep_sibling_identity="$(_verification_file_identity \
  "${grep_current_path}" "${grep_current_cwd}")"
if [[ "${grep_sibling_identity}" != "${grep_current_identity}" ]]; then
  ok
else
  bad "sibling creation must change strict interval identity"
fi
assert_success "unrelated sibling churn preserves settled Grep provenance" \
  _quality_contract_receipt_provenance_current "${grep_current_receipt}"
printf '%s\n' 'background replacement' >"${grep_current_dir}/source.txt"
assert_failure "background Grep source replacement stales accepted provenance" \
  _quality_contract_receipt_provenance_current "${grep_current_receipt}"
assert_success "fixture uses recorder evidence rows one reference at a time" \
  jq -se 'all(.[];
    (keys | sort) == ["_v","axis","claim","class","contract_id",
      "contract_revision","criterion_id","edit_revision","evidence_id",
      "evidence_kind","lifecycle_dispatch_id","native_agent_id",
      "plan_revision","receipt_id","reference","result",
      "review_cycle_id","reviewed_at","reviewer"])' \
  "$(session_file quality_evidence.jsonl)"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "proof without fresh-eyes frontier blocks" "missing_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 0 clear
assert_success "fixture uses translated authoritative frontier receipt" \
  jq -e '(keys | sort) == ["_v","alternatives_searched","contract_id",
    "contract_revision","criterion_ids","dominates_current","edit_revision",
    "evidence","evidence_ids","experiment","lifecycle_dispatch_id","limits",
    "materiality","native_agent_id","plan_revision","recommended_move",
    "review_cycle_id","reviewed_at","reviewer","status","title","why"]' \
  "$(session_file quality_frontier.json)"
gate="$(quality_contract_gate_status_json)"
assert_eq "all criteria plus clear frontier pass" "pass" "$(jq -r '.status' <<<"${gate}")"
gate_threshold_before="${OMC_VERIFY_CONFIDENCE_THRESHOLD}"
OMC_VERIFY_CONFIDENCE_THRESHOLD=100
gate="$(quality_contract_gate_status_json)"
assert_eq "gate uses the threshold frozen with its contract" "pass" \
  "$(jq -r '.status' <<<"${gate}")"
OMC_VERIFY_CONFIDENCE_THRESHOLD="${gate_threshold_before}"
assert_eq "all five mandatory criteria satisfied" "5/5" \
  "$(jq -r '(.satisfied_count|tostring)+"/"+(.required_count|tostring)' <<<"${gate}")"

current_edit_revision="$(read_state edit_revision 2>/dev/null || true)"
for malformed_edit_revision in 08 poison 1000000000000000; do
  write_state "edit_revision" "${malformed_edit_revision}"
  gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
  assert_eq "live gate rejects malformed edit revision ${malformed_edit_revision}" \
    "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"
done
write_state "edit_revision" "${current_edit_revision}"

assert_failure "legacy verification rejects leading-zero threshold" \
  _quality_contract_verification_current 08
for malformed_verify_case in \
    'last_verify_confidence|08' \
    'last_verify_ts|1000000000000000' \
    'last_edit_ts|08' \
    'last_verify_code_revision|1000000000000000' \
    'last_code_edit_revision|1000000000000000'; do
  malformed_verify_key="${malformed_verify_case%%|*}"
  malformed_verify_value="${malformed_verify_case#*|}"
  prior_verify_value="$(read_state "${malformed_verify_key}" 2>/dev/null || true)"
  write_state "${malformed_verify_key}" "${malformed_verify_value}"
  assert_failure "legacy verification rejects malformed ${malformed_verify_key}" \
    _quality_contract_verification_current 40
  write_state "${malformed_verify_key}" "${prior_verify_value}"
done

evidence_schema_fixture="$(jq -sc '.' \
  "$(session_file quality_evidence.jsonl)")"
for bounded_field in contract_revision review_cycle_id edit_revision \
    plan_revision reviewed_at; do
  oversized_evidence="$(jq -c --arg field "${bounded_field}" \
    'map(.[$field]=1000000000000000)' <<<"${evidence_schema_fixture}")"
  assert_failure "evidence rejects oversized ${bounded_field}" \
    _quality_contract_evidence_schema_valid "${oversized_evidence}"
done
frontier_schema_fixture="$(cat "$(session_file quality_frontier.json)")"
for bounded_field in contract_revision review_cycle_id edit_revision \
    plan_revision reviewed_at; do
  oversized_frontier="$(jq -c --arg field "${bounded_field}" \
    '.[$field]=1000000000000000' <<<"${frontier_schema_fixture}")"
  assert_failure "frontier rejects oversized ${bounded_field}" \
    _quality_contract_frontier_schema_valid "${oversized_frontier}"
done
jq -c '.reviewed_at=1000000000000000' \
  "$(session_file quality_evidence.jsonl)" \
  >"$(session_file quality_evidence.jsonl).tmp"
mv -f "$(session_file quality_evidence.jsonl).tmp" \
  "$(session_file quality_evidence.jsonl)"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "live gate rejects oversized evidence chronology" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 0
write_frontier "${contract}" 0 clear
jq '.reviewed_at=1000000000000000' \
  "$(session_file quality_frontier.json)" \
  >"$(session_file quality_frontier.json).tmp"
mv -f "$(session_file quality_frontier.json).tmp" \
  "$(session_file quality_frontier.json)"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "live gate rejects oversized frontier chronology" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 0 clear

write_frontier "${contract}" 0 open
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "material frontier blocks even when every threshold criterion passed" \
  "open_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 0 clear

canonical_agents_target="$(_verification_normalize_proof_path \
  "${REPO_ROOT}/AGENTS.md")"
append_current_receipt "${contract}" 0 "q001-observation-unavailable" \
  "Grep:${canonical_agents_target}:Q-001" \
  inspection failed 205 90 Grep "${canonical_agents_target}"
gate="$(quality_contract_gate_status_json)"
assert_eq "failed observation does not invalidate accepted semantic review" \
  "pass" "$(jq -r '.status' <<<"${gate}")"
append_current_receipt "${contract}" 0 "q001-observation-identical" \
  "Grep:${canonical_agents_target}:Q-001" \
  inspection passed 206 90 Grep "${canonical_agents_target}"
receipts_file="$(session_file verification_receipts.jsonl)"
q001_accepted_digest="$(jq -r --arg id "${QUALITY_RECEIPT_001}" \
  'select(.receipt_id == $id) | .artifact_digest' \
  "${receipts_file}")"
jq -c --arg digest "${q001_accepted_digest}" '
  if .tool_use_id == "tool-proof-q001-observation-identical"
  then .artifact_digest=$digest else . end
' "${receipts_file}" >"${receipts_file}.tmp"
mv -f "${receipts_file}.tmp" "${receipts_file}"
reseal_receipt_ledger "${receipts_file}"
gate="$(quality_contract_gate_status_json)"
assert_eq "byte-identical repeated observation does not force re-review" \
  "pass" "$(jq -r '.status' <<<"${gate}")"
append_current_receipt "${contract}" 0 "q001-observation-unreviewed" \
  "Grep:${canonical_agents_target}:Q-001" \
  inspection passed 207 90 Grep "${canonical_agents_target}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "later successful observation requires fresh reviewer semantics" \
  "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "unreviewed observation identifies its exact criterion" "Q-001" \
  "$(jq -r '.stale_ids | join(",")' <<<"${gate}")"
write_evidence "${contract}" 0
write_frontier "${contract}" 0 clear

append_current_receipt "${contract}" 0 "q003-negative-current" \
  'bash tests/test-stricter-verdict-wins.sh --criterion Q-003 --benchmark' \
  benchmark failed 210 1
append_current_receipt "${contract}" 0 "q004-unrelated-pass" \
  'bash tests/test-e2e-hook-sequence.sh --criterion Q-004' \
  test passed 220
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "even low-confidence failed criterion proof stales an earlier clean review" \
  "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "unrelated newer pass cannot hide the failed criterion" "Q-003" \
  "$(jq -r '.stale_ids | join(",")' <<<"${gate}")"
write_evidence "${contract}" 0
write_frontier "${contract}" 0 clear

append_current_receipt "${contract}" 0 "q003-decorative-mismatch-fail" \
  'bash tests/test-stricter-verdict-wins.sh --criterion Q-003 --comparison' \
  test failed 230
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "later failure cannot hide behind changed argv decoration or evidence kind" \
  "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "proof identity binds decorative-mismatch failure to its criterion" \
  "Q-003" "$(jq -r '.stale_ids | join(",")' <<<"${gate}")"
write_evidence "${contract}" 0
write_frontier "${contract}" 0 clear

write_state "edit_revision" "1"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "later edit stales criterion proof" "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "all stale criteria are identified" "5" "$(jq -r '.stale_ids | length' <<<"${gate}")"

write_evidence "${contract}" 1
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "fresh proof cannot reuse stale frontier" "stale_frontier" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1 "The benchmarked frontier candidate improved the baseline" failed
write_frontier "${contract}" 1 open
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "material frontier remains blocking" "open_frontier" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
gate="$(quality_contract_gate_status_json)"
assert_eq "fresh frontier clears after remediation" "pass" "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1 "The benchmarked frontier candidate improved the baseline" failed
write_frontier "${contract}" 1 clear
gate="$(quality_contract_gate_status_json)"
assert_eq "unmet aspiration does not block a strong clear frontier" "pass" \
  "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear

evidence_file="$(session_file quality_evidence.jsonl)"
jq -c --arg id "${QUALITY_RECEIPT_001}" \
  'if .criterion_id == "Q-002" then .receipt_id=$id | .reference=$id else . end' \
  "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "one receipt cannot be reused across two criteria" "invalid_evidence" \
  "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
receipts_file="$(session_file verification_receipts.jsonl)"
q001_receipt="$(jq -c --arg id "${QUALITY_RECEIPT_001}" \
  'select(.receipt_id == $id)' "${receipts_file}")"
jq -c --argjson source "${q001_receipt}" --arg id "${QUALITY_RECEIPT_002}" '
  if .receipt_id == $id then
    .command=$source.command
    | .command_digest=$source.command_digest
    | .artifact_digest=$source.artifact_digest
    | .artifact_target=$source.artifact_target
    | .subject_path=$source.subject_path
    | .subject_digest=$source.subject_digest
    | .subject_identity=$source.subject_identity
    | .proof_identity=$source.proof_identity
  else . end' \
  "${receipts_file}" >"${receipts_file}.tmp"
mv -f "${receipts_file}.tmp" "${receipts_file}"
reseal_receipt_ledger "${receipts_file}"
duplicate_receipt_id="$(jq -r \
  'select(.tool_use_id == "tool-proof-002") | .receipt_id' \
  "${receipts_file}")"
jq -c --arg id "${duplicate_receipt_id}" '
  if .criterion_id == "Q-002" then
    .receipt_id=$id | .reference=$id
  else . end' "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
write_frontier "${contract}" 1 clear
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "fresh tool IDs cannot duplicate one semantic proof across criteria" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
wrong_target_path="$(_verification_normalize_proof_path \
  "${REPO_ROOT}/README.md" 0 source)"
wrong_target_digest="$(_verification_sha256_file "${wrong_target_path}")"
wrong_target_cwd="$(_verification_normalize_proof_path "${REPO_ROOT}")"
wrong_target_identity="$(_verification_file_identity \
  "${wrong_target_path}" "${wrong_target_cwd}")"
wrong_target_command="Grep:${wrong_target_path}:Q-001"
wrong_target_command_digest="$(verification_receipt_command_digest \
  "${wrong_target_command}" Grep)"
jq -c --arg id "${QUALITY_RECEIPT_001}" \
  --arg target "${wrong_target_path}" \
  --arg digest "${wrong_target_digest}" \
  --arg identity "${wrong_target_identity}" \
  --arg command "${wrong_target_command}" \
  --arg command_digest "${wrong_target_command_digest}" '
  if .receipt_id == $id then
    .artifact_target=$target
    | .subject_path=$target
    | .subject_digest=$digest
    | .subject_identity=$identity
    | .command=$command
    | .command_digest=$command_digest
  else . end' \
  "${receipts_file}" >"${receipts_file}.tmp"
mv -f "${receipts_file}.tmp" "${receipts_file}"
reseal_receipt_ledger "${receipts_file}"
wrong_target_receipt_id="$(jq -r \
  'select(.tool_use_id == "tool-proof-001") | .receipt_id' \
  "${receipts_file}")"
jq -c --arg id "${wrong_target_receipt_id}" '
  if .criterion_id == "Q-001" then
    .receipt_id=$id | .reference=$id
  else . end' "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
write_frontier "${contract}" 1 clear
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "receipt from wrong artifact target invalidates the evidence portfolio" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
jq -c 'if .criterion_id == "Q-001" then .receipt_id="vr-forged-0001" | .reference="vr-forged-0001" else . end' \
  "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "reviewer prose cannot forge a missing receipt" "invalid_evidence" \
  "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear

write_state "last_verify_ts" "114"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "unrelated legacy verification clock cannot erase bound receipts" \
  "pass" "$(jq -r '.status' <<<"${gate}")"
assert_eq "receipt-backed verification remains current" "true" \
  "$(jq -r '.verification_current' <<<"${gate}")"
write_state "last_verify_ts" "120"
write_state "last_code_edit_revision" "1"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "unrelated legacy code clock cannot erase bound receipts" "pass" \
  "$(jq -r '.status' <<<"${gate}")"
write_state "last_code_edit_revision" "0"

frontier_file="$(session_file quality_frontier.json)"
jq '.evidence_ids[0]="qe-forged-reference"' "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "frontier cannot detach itself from authoritative evidence IDs" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 1 clear

frontier_file="$(session_file quality_frontier.json)"
jq '.criterion_ids=["Q-004"]' "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "clear frontier cannot retain stale blocking criterion IDs" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 1 clear

frontier_file="$(session_file quality_frontier.json)"
jq '.limits=["We ran out of time before exploring another candidate"]' \
  "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "gate rejects process-time deferral hidden in frontier limits" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 1 clear

frontier_file="$(session_file quality_frontier.json)"
jq '.title="No time remained for another alternative"' \
  "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "gate rejects process-time deferral hidden in frontier title" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 1 clear

evidence_file="$(session_file quality_evidence.jsonl)"
jq -c --arg id "${QUALITY_RECEIPT_005}" 'if .criterion_id == "Q-006" then
    .receipt_id=$id | .reference=$id
  else . end' "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
frontier_file="$(session_file quality_frontier.json)"
jq --arg id "${QUALITY_RECEIPT_006}" \
  '.evidence |= map(select(. != $id))' \
  "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "forged aspiration evidence cannot hide behind mandatory proof" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear

frontier_file="$(session_file quality_frontier.json)"
jq --arg id "${QUALITY_RECEIPT_006}" \
  '.evidence |= map(select(. != $id))' \
  "${frontier_file}" >"${frontier_file}.tmp"
mv -f "${frontier_file}.tmp" "${frontier_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "frontier receipt set must exactly equal accepted evidence receipts" \
  "invalid_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 1 clear

write_evidence "${contract}" 1 "Implementation is too expensive and takes too long for this session"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "cost-shaped visionary claim invalidates reviewer evidence" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1 "préimplementation takes too long for the candidate"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "Unicode-adjacent cost boundary is identical in the gate" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1 "İmplementation takes too long for the candidate"
write_frontier "${contract}" 1 clear
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "non-ASCII casefold boundary is identical in the gate" \
  "pass" "$(jq -r '.status' <<<"${gate}")"
write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear

printf 'Test 7: frontier counterproof distinguishes observations from assertion chatter\n'
prior_observation='{"proof_identity":"vp-same-proof","result_digest":"result-a","artifact_digest":"artifact-a","evidence_kind":"inspection","tool_name":"Grep"}'
identical_observation='{"proof_identity":"vp-same-proof","result_digest":"result-a","artifact_digest":"artifact-a","evidence_kind":"inspection","tool_name":"Grep"}'
result_only_observation='{"proof_identity":"vp-same-proof","result_digest":"result-b","artifact_digest":"artifact-a","evidence_kind":"inspection","tool_name":"Grep"}'
changed_observation='{"proof_identity":"vp-same-proof","result_digest":"result-b","artifact_digest":"artifact-b","evidence_kind":"inspection","tool_name":"Grep"}'
changed_assertion='{"proof_identity":"vp-same-proof","result_digest":"result-b","artifact_digest":"artifact-b","evidence_kind":"test","tool_name":"Bash"}'
different_assertion='{"proof_identity":"vp-new-proof","result_digest":"result-a","artifact_digest":"artifact-a","evidence_kind":"test","tool_name":"Bash"}'
assert_failure "identical observation is not frontier counterproof" \
  _quality_contract_counterproof_is_distinct \
  "${prior_observation}" "${identical_observation}"
assert_failure "result chatter without changed observed artifact is not counterproof" \
  _quality_contract_counterproof_is_distinct \
  "${prior_observation}" "${result_only_observation}"
assert_success "changed observation artifact and result are distinct counterproof" \
  _quality_contract_counterproof_is_distinct \
  "${prior_observation}" "${changed_observation}"
assert_failure "assertion output drift cannot clear a frontier" \
  _quality_contract_counterproof_is_distinct \
  "${prior_observation}" "${changed_assertion}"
assert_success "different assertion proof identity is distinct counterproof" \
  _quality_contract_counterproof_is_distinct \
  "${changed_assertion}" "${different_assertion}"

printf 'Test 8: summaries are bounded and include the visionary axis/status\n'
router_summary="$(quality_contract_router_summary adaptive execution high 1 1)"
if [[ ${#router_summary} -le 240 && "${router_summary}" == *visionary* ]]; then
  ok
else
  bad "router summary must be bounded and name visionary"
fi
append_current_receipt "${contract}" 1 "q003-summary-failure" \
  'bash tests/test-stricter-verdict-wins.sh --criterion Q-003 --benchmark' \
  benchmark failed 240 1
status_summary="$(quality_contract_status_summary 2>/dev/null || true)"
if [[ ${#status_summary} -le 320 \
    && "${status_summary}" == *"; stale Q-003"* ]]; then
  ok
else
  bad "status summary must be bounded and name missing visionary proof"
fi

printf 'Test 9: syntax and Bash-3-compatible source surface\n'
lib="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/quality-contract.sh"
if bash -n "${lib}"; then ok; else bad "library fails bash -n"; fi
for fn in quality_contract_should_arm quality_contract_arm_decision_json \
  quality_contract_extract_json quality_review_extract_json \
  quality_contract_validate_payload quality_contract_canonicalize_payload \
  quality_contract_validate_profile_bindings quality_contract_revision_preserves_floor \
  quality_contract_build_envelope quality_contract_validate_envelope \
  quality_contract_validate_current quality_review_validate_payload \
  quality_review_validate_against_contract quality_contract_gate_status_json \
  quality_contract_router_summary quality_contract_status_summary; do
  if declare -F "${fn}" >/dev/null; then ok; else bad "missing public function ${fn}"; fi
done

printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
