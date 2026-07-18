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
        {id:"Q-005",class:"must",axis:"complete",claim:"Every required and adjacent surface is reconciled",rationale:"Silent sibling omissions are the primary completeness failure",surfaces:["delivery"],proof_method:"Run the broad project suite with the complete criterion target",proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],command_contains:["Q-005"],artifact_contains:[]},failure_signal:"Any required surface is missing, stale, or silently deferred",tradeoff_boundary:"External blockers may pause work but effort alone may not",evidence_policy:{allowed_kinds:["test","inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-003",class:"must",axis:"visionary",claim:"The strongest credible step-change candidate is empirically tested",rationale:"Repair-only thinking cannot establish a frontier quality bar",surfaces:["product frontier"],proof_method:"Benchmark the Q-003 step-change candidate against the baseline",proof_spec:{receipt_kinds:["benchmark"],tool_names:["Bash"],command_contains:["Q-003","benchmark"],artifact_contains:[]},failure_signal:"No candidate leap was generated or the comparison is purely rhetorical",tradeoff_boundary:"Reject a candidate only after measured counterevidence",evidence_policy:{allowed_kinds:["benchmark","comparison","render"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-001",class:"must",axis:"deliberate",claim:"Material decisions expose rationale and falsifiable tradeoffs",rationale:"Unexplained defaults are accidental rather than deliberate",surfaces:["architecture"],proof_method:"Inspect the Q-001 decision record against implementation",proof_spec:{receipt_kinds:["inspection"],tool_names:["Grep"],command_contains:["Q-001"],artifact_contains:["AGENTS.md"]},failure_signal:"A material choice lacks rationale or contradicts its stated constraint",tradeoff_boundary:"Concise rationale is sufficient when the decision is reversible",evidence_policy:{allowed_kinds:["inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-004",class:"must",axis:"coherent",claim:"All changed surfaces express one consistent system design",rationale:"Local quality can still produce an incoherent whole",surfaces:["integration"],proof_method:"Run the Q-004 end-to-end causal integration trace",proof_spec:{receipt_kinds:["test"],tool_names:["Bash"],command_contains:["Q-004"],artifact_contains:[]},failure_signal:"Any consumer contradicts the shared contract or design language",tradeoff_boundary:"Compatibility adapters may differ only when their boundary is explicit",evidence_policy:{allowed_kinds:["inspection","test"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-002",class:"must",axis:"distinctive",claim:"The delivered form is specific to this project and audience",rationale:"Generic defaults cannot demonstrate veteran product judgment",surfaces:["experience"],proof_method:"Inspect the Q-002 anti-generic project experience evidence",proof_spec:{receipt_kinds:["inspection"],tool_names:["Grep"],command_contains:["Q-002"],artifact_contains:["README.md"]},failure_signal:"The result could be transplanted unchanged into an unrelated project",tradeoff_boundary:"Novelty without user value is not distinctiveness",evidence_policy:{allowed_kinds:["render","inspection"],minimum:1,requires_empirical:true,requires_independent_review:true}},
        {id:"Q-006",class:"aspiration",axis:"visionary",claim:"A reversible follow-on leap remains explicitly evaluated",rationale:"The frontier should record ambitious options without making novelty mandatory",surfaces:["future experiment"],proof_method:"Compare the Q-006 reversible option with the shipped baseline",proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],command_contains:["Q-006","comparison"],artifact_contains:[]},failure_signal:"The option is asserted without a measurable user benefit",tradeoff_boundary:"The aspiration may not delay proven mandatory criteria",evidence_policy:{allowed_kinds:["comparison"],minimum:1,requires_empirical:true,requires_independent_review:true}}
      ]
    }
  '
}

build_contract() {
  local definition objective_digest
  definition="$(definition_json)"
  objective_digest="$(_omc_token_digest 'Build the full Definition of Excellent engine')"
  quality_contract_build_envelope "${definition}" 7 100 3 \
    "${objective_digest}" "generation-1" 1 110 \
    "quality-planner" "native-planner-1" "dispatch-planner-12345678" 1
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

write_receipts() {
  local contract="$1" edit_revision="${2:-0}" aspiration_result="${3:-passed}"
  local id rev cycle
  id="$(jq -r '.contract_id' <<<"${contract}")"
  rev="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  jq -cn \
    --arg id "${id}" --argjson rev "${rev}" --argjson cycle "${cycle}" \
    --argjson edit "${edit_revision}" --arg aspiration_result "${aspiration_result}" '
    def row($n;$tool;$command;$kind;$artifact;$outcome):
      {_v:2,receipt_id:("vr-proof-"+$n),tool_use_id:("tool-proof-"+$n),
       tool_name:$tool,input_digest:("input-digest-"+$n),command:$command,
       command_digest:("command-digest-"+$n),outcome:$outcome,confidence:90,
       method:(if $tool == "Bash" then "project_test_command" else "source_inspection" end),
       scope:(if $tool == "Bash" then "full" else "workspace_source" end),
       evidence_kind:$kind,result:(if $outcome == "passed" then "1 passed" else "1 failed" end),
       result_digest:("result-digest-"+$n),artifact_target:$artifact,
       artifact_digest:(if $artifact == "" then "" else ("artifact-digest-"+$n) end),
       proof_identity:("vp-proof-"+$n),edit_revision:$edit,code_revision:0,
       plan_revision:1,review_cycle_id:$cycle,quality_contract_id:$id,
       quality_contract_revision:$rev,ts:190};
    [row("001";"Grep";"Grep:/repo/AGENTS.md:Q-001 decision rationale";"inspection";"/repo/AGENTS.md";"passed"),
     row("002";"Grep";"Grep:/repo/README.md:Q-002 distinctive audience";"inspection";"/repo/README.md";"passed"),
     row("003";"Bash";"bash tests/test-quality-contract.sh --criterion Q-003 --benchmark";"benchmark";"";"passed"),
     row("004";"Bash";"bash tests/test-quality-contract.sh --criterion Q-004";"test";"";"passed"),
     row("005";"Bash";"bash tools/run-tests.sh --full --criterion Q-005";"test";"";"passed"),
     row("006";"Bash";"bash tests/test-quality-contract.sh --criterion Q-006 --comparison";"comparison";"";$aspiration_result)]
    | .[]
  ' >"$(session_file verification_receipts.jsonl)"
}

append_current_receipt() {
  local contract="$1" edit_revision="$2" suffix="$3" command="$4"
  local kind="$5" outcome="$6" ts="$7" confidence="${8:-90}"
  local tool="${9:-Bash}" artifact="${10:-}"
  jq -cn \
    --arg id "$(jq -r '.contract_id' <<<"${contract}")" \
    --argjson rev "$(jq -r '.contract_revision' <<<"${contract}")" \
    --argjson cycle "$(jq -r '.review_cycle_id' <<<"${contract}")" \
    --argjson edit "${edit_revision}" --arg suffix "${suffix}" \
    --arg command "${command}" --arg kind "${kind}" \
    --arg outcome "${outcome}" --argjson ts "${ts}" \
    --argjson confidence "${confidence}" --arg tool "${tool}" \
    --arg artifact "${artifact}" '
      {_v:2,receipt_id:("vr-proof-"+$suffix),tool_use_id:("tool-proof-"+$suffix),
       tool_name:$tool,input_digest:("input-digest-"+$suffix),command:$command,
       command_digest:("command-digest-"+$suffix),outcome:$outcome,confidence:$confidence,
       method:(if $tool == "Bash" then "project_test_command" else "source_inspection" end),
       scope:(if $tool == "Bash" then "full" else "workspace_source" end),
       evidence_kind:$kind,
       result:(if $outcome == "passed" then "1 passed" else "1 failed" end),
       result_digest:("result-digest-"+$suffix),artifact_target:$artifact,
       artifact_digest:(if $artifact == "" then "" else ("artifact-digest-"+$suffix) end),
       proof_identity:("vp-proof-"+$suffix),edit_revision:$edit,code_revision:0,
       plan_revision:1,review_cycle_id:$cycle,quality_contract_id:$id,
       quality_contract_revision:$rev,ts:$ts}
  ' >>"$(session_file verification_receipts.jsonl)"
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
    --arg aspiration_result "${aspiration_result}" '
    def row($n;$criterion;$axis;$class;$kind;$claim;$reference):
      {_v:1,contract_id:$id,contract_revision:$rev,review_cycle_id:$cycle,
       criterion_id:$criterion,axis:$axis,class:$class,
       evidence_id:("qe-"+$n),receipt_id:("vr-proof-"+$n),result:"passed",
       evidence_kind:$kind,claim:$claim,reference:$reference,
       edit_revision:$edit,plan_revision:1,reviewed_at:200,
       reviewer:"excellence-reviewer",native_agent_id:"native-reviewer-1",
       lifecycle_dispatch_id:"dispatch-reviewer-12345678"};
    [row("001";"Q-001";"deliberate";"must";"inspection";"Decision records match the implementation";"vr-proof-001"),
     row("002";"Q-002";"distinctive";"must";"inspection";"Project-specific anti-generic inspection passed";"vr-proof-002"),
     row("003";"Q-003";"visionary";"must";"benchmark";$visionary_basis;"vr-proof-003"),
     row("004";"Q-004";"coherent";"must";"test";"End-to-end integration trace passed";"vr-proof-004"),
     row("005";"Q-005";"complete";"must";"test";"Objective and sibling-scope matrix reconciled";"vr-proof-005"),
     row("006";"Q-006";"visionary";"aspiration";"comparison";"Reversible follow-on compared with the baseline";"vr-proof-006")]
    | map(if .criterion_id == "Q-006" then .result = $aspiration_result else . end)
    | .[]
  ' >"$(session_file quality_evidence.jsonl)"
}

write_frontier() {
  local contract="$1" edit_revision="${2:-0}" status="${3:-clear}"
  local dominates=false materiality="none" evidence_ids
  [[ "${status}" == "clear" ]] || { dominates=true; materiality="medium"; }
  evidence_ids="$(jq -sc '[.[].evidence_id]' "$(session_file quality_evidence.jsonl)")"
  jq -cn \
    --arg id "$(jq -r '.contract_id' <<<"${contract}")" \
    --argjson rev "$(jq -r '.contract_revision' <<<"${contract}")" \
    --argjson cycle "$(jq -r '.review_cycle_id' <<<"${contract}")" \
    --argjson edit "${edit_revision}" --arg status "${status}" \
    --arg materiality "${materiality}" --argjson dominates "${dominates}" \
    --argjson evidence_ids "${evidence_ids}" '
    {_v:1,contract_id:$id,contract_revision:$rev,review_cycle_id:$cycle,
     edit_revision:$edit,plan_revision:1,status:$status,materiality:$materiality,
     dominates_current:$dominates,
     title:(if $dominates then "A stronger visionary candidate remains" else "No material candidate dominates" end),
     why:(if $dominates then "The measured reversible leap remains inside the frozen ambition boundary" else "The strongest candidate was compared and no longer dominates" end),
     recommended_move:(if $dominates then "Implement and benchmark the bounded candidate" else "Ship the causally certified result" end),
     criterion_ids:(if $dominates then ["Q-006"] else [] end),
     evidence_ids:$evidence_ids,evidence:["vr-proof-003"],
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
canonical_definition="$(quality_contract_canonicalize_payload "${definition}")"
assert_success "validated payload remains valid after canonicalization" \
  quality_contract_validate_payload "${canonical_definition}"
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
     command_contains:["Q-003","render"],artifact_contains:[]}
  | (.criteria[] | select(.id == "Q-003") | .evidence_policy.allowed_kinds) = ["render"]
' <<<"${definition}")"
assert_success "executable render proof can freeze when its result can reach threshold" \
  quality_contract_validate_payload "${bash_render_proof}"
bash_render_command='bash tests/omc_definition_render.sh --criterion Q-003 --render'
assert_eq "Bash render command stamps render evidence" "render" \
  "$(verification_receipt_evidence_kind framework_keyword unknown_test \
    "${bash_render_command}")"
assert_eq "silent Bash render remains below threshold" "30" \
  "$(score_verification_confidence "${bash_render_command}" "" "")"
assert_eq "result-bearing Bash render reaches threshold without name-only inflation" \
  "60" "$(score_verification_confidence "${bash_render_command}" \
    '1 test passed; exit code: 0' "")"
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
     command_contains:["browser_take_screenshot"],artifact_contains:["route=/checkout"]}
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
     command_contains:["browser_snapshot"],artifact_contains:["route=/checkout"]}
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
      command_contains:[("Q-" + (("000" + ($n|tostring))[-3:])),"comparison"],artifact_contains:[]},
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
      command_contains:["Q-011"],artifact_contains:[]},
    failure_signal:"The added scope lacks implementation or current independent proof",
    tradeoff_boundary:"The addition may be explicitly rescoped but never silently omitted",
    evidence_policy:{allowed_kinds:["test"],minimum:1,
      requires_empirical:true,requires_independent_review:true}
  }]
' <<<"${ten_criterion_definition}")"
assert_success "additive payload has headroom beyond a ten-criterion floor" \
  quality_contract_validate_payload "${eleven_criterion_definition}"
objective_digest_for_headroom="$(_omc_token_digest 'Exercise additive criterion headroom')"
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
assert_success "revision two can publish the eleventh certifying criterion" \
  quality_contract_build_envelope "${eleven_criterion_definition}" 7 100 3 \
    "${objective_digest_for_headroom}" generation-1 1 120 quality-planner \
    native-planner-2 dispatch-planner-headroom2 2
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
cat >"$(session_file quality_constitution_snapshot.json)" <<'JSON'
{"schema_version":1,"generation":1,"digest":"constitution-digest-test","blocking_claims":[{"id":"taste-blocking-1","statement":"Prefer causal proof over generic quality claims"}],"advisory_claims":[],"tentative_claims":[]}
JSON
write_state "quality_constitution_blocking_ids" '["taste-blocking-1"]'
assert_failure "active explicit profile ID cannot be silently dropped" \
  quality_contract_validate_profile_bindings "${definition}"
profile_bound="$(jq '.standards += [{kind:"profile",reference:"Prefer causal proof over generic quality claims",rationale:"The user pinned this project-specific taste rule",profile_entry_id:"taste-blocking-1"}]' <<<"${definition}")"
assert_success "bound explicit profile standard validates" \
  quality_contract_validate_profile_bindings "${profile_bound}"
profile_misquoted="$(jq '(.standards[] | select(.kind == "profile") | .reference) = "Do the opposite of the pinned rule"' <<<"${profile_bound}")"
assert_failure "profile ID cannot be paired with a contradictory statement" \
  quality_contract_validate_profile_bindings "${profile_misquoted}"
write_state "quality_constitution_blocking_ids" 'taste-blocking-1'
assert_success "comma-form router profile IDs bind identically" \
  quality_contract_validate_profile_bindings "${profile_bound}"
write_state "quality_constitution_blocking_ids" '[]'

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
additive_revision="$(jq '.criteria += [{id:"Q-007",class:"aspiration",axis:"visionary",claim:"A second reversible follow-on experiment remains available",rationale:"The frozen floor may be extended without being weakened",surfaces:["future experiment"],proof_method:"Compare the Q-007 reversible experiment against the shipped baseline",proof_spec:{receipt_kinds:["comparison"],tool_names:["Bash"],command_contains:["Q-007","comparison"],artifact_contains:[]},failure_signal:"The experiment cannot be reversed or has no measurable user benefit",tradeoff_boundary:"The aspiration may not delay the proven must-criteria",evidence_policy:{allowed_kinds:["comparison"],minimum:1,requires_empirical:true,requires_independent_review:true}}]' <<<"${definition}")"
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
seed_current_state "${contract}"
assert_success "current state accepts matching causal envelope" quality_contract_validate_current
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
write_state "quality_constitution_status" "current"
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
missing_assessment="$(jq '.criteria |= map(select(.id != "Q-003"))' <<<"${review}")"
assert_failure "review cannot silently omit visionary criterion" \
  quality_review_validate_against_contract "${missing_assessment}" "${contract}" "VERDICT: SHIP"
open_ship="$(jq '.frontier.material=true | .frontier.criterion_ids=["Q-003"] | (.criteria[] | select(.id == "Q-003") | .status)="unmet"' <<<"${review}")"
assert_failure "SHIP cannot coexist with material open frontier" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: SHIP"
assert_success "FINDINGS count equals the deterministic unmet count" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: FINDINGS (1)"
assert_failure "FINDINGS count cannot overstate the unmet count" \
  quality_review_validate_against_contract "${open_ship}" "${contract}" "VERDICT: FINDINGS (2)"
unsupported_frontier="$(jq '.frontier.material=true | .frontier.criterion_ids=["Q-003"]' <<<"${review}")"
assert_success "material frontier may dominate an already-met threshold" \
  quality_review_validate_against_contract "${unsupported_frontier}" "${contract}" "VERDICT: FINDINGS (1)"
cost_rejection="$(jq '.alternatives_searched[1]="Rejected because it was too expensive and time-consuming for this session"' <<<"${review}")"
assert_failure "cost is not evidence for rejecting the frontier" \
  quality_review_validate_payload "${cost_rejection}"
measured_rejection="$(jq '.alternatives_searched[1]="Rejected because the benchmark measured a 42 percent latency regression"' <<<"${review}")"
assert_success "measured counterevidence may reject a frontier candidate" \
  quality_review_validate_payload "${measured_rejection}"
cost_move="$(jq '.frontier.recommended_move="Do not pursue it because it takes too long and is too expensive"' <<<"${review}")"
assert_failure "cost alone cannot clear the recommended frontier move" \
  quality_review_validate_payload "${cost_move}"

printf 'Test 6: evidence and frontier gate recomputes current proof\n'
write_evidence "${contract}" 0
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
assert_eq "all five mandatory criteria satisfied" "5/5" \
  "$(jq -r '(.satisfied_count|tostring)+"/"+(.required_count|tostring)' <<<"${gate}")"

write_frontier "${contract}" 0 open
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "material frontier blocks even when every threshold criterion passed" \
  "open_frontier" "$(jq -r '.status' <<<"${gate}")"
write_frontier "${contract}" 0 clear

append_current_receipt "${contract}" 0 "q001-observation-unavailable" \
  'Grep:/repo/AGENTS.md:Q-001 unavailable observation' \
  inspection failed 205 90 Grep /repo/AGENTS.md
gate="$(quality_contract_gate_status_json)"
assert_eq "failed observation does not invalidate accepted semantic review" \
  "pass" "$(jq -r '.status' <<<"${gate}")"
append_current_receipt "${contract}" 0 "q001-observation-unreviewed" \
  'Grep:/repo/AGENTS.md:Q-001 later observation' \
  inspection passed 206 90 Grep /repo/AGENTS.md
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "later successful observation requires fresh reviewer semantics" \
  "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "unreviewed observation identifies its exact criterion" "Q-001" \
  "$(jq -r '.stale_ids | join(",")' <<<"${gate}")"
write_evidence "${contract}" 0
write_frontier "${contract}" 0 clear

append_current_receipt "${contract}" 0 "q003-negative-current" \
  'bash tests/test-quality-contract.sh --criterion Q-003 --benchmark' \
  benchmark failed 210 1
append_current_receipt "${contract}" 0 "q004-unrelated-pass" \
  'bash tests/test-quality-contract.sh --criterion Q-004' \
  test passed 220
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "even low-confidence failed criterion proof stales an earlier clean review" \
  "stale_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "unrelated newer pass cannot hide the failed criterion" "Q-003" \
  "$(jq -r '.stale_ids | join(",")' <<<"${gate}")"
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
jq -c 'if .criterion_id == "Q-002" then .receipt_id="vr-proof-001" | .reference="vr-proof-001" else . end' \
  "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "one receipt cannot be reused across two criteria" "invalid_evidence" \
  "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
receipts_file="$(session_file verification_receipts.jsonl)"
q001_receipt="$(jq -c 'select(.receipt_id == "vr-proof-001")' "${receipts_file}")"
jq -c --argjson source "${q001_receipt}" '
  if .receipt_id == "vr-proof-002" then
    .command_digest=$source.command_digest
    | .result_digest=$source.result_digest
    | .artifact_digest=$source.artifact_digest
    | .proof_identity=$source.proof_identity
  else . end' \
  "${receipts_file}" >"${receipts_file}.tmp"
mv -f "${receipts_file}.tmp" "${receipts_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "fresh tool IDs cannot duplicate one semantic proof across criteria" \
  "invalid_evidence" "$(jq -r '.status' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
jq -c 'if .receipt_id == "vr-proof-001" then .artifact_target="/repo/OTHER.md" else . end' \
  "${receipts_file}" >"${receipts_file}.tmp"
mv -f "${receipts_file}.tmp" "${receipts_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "receipt from wrong artifact target cannot satisfy criterion" \
  "missing_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "wrong-target criterion is named" "Q-001" \
  "$(jq -r '.missing_ids | join(",")' <<<"${gate}")"

write_evidence "${contract}" 1
write_frontier "${contract}" 1 clear
jq -c 'if .criterion_id == "Q-001" then .receipt_id="vr-forged-0001" | .reference="vr-forged-0001" else . end' \
  "${evidence_file}" >"${evidence_file}.tmp"
mv -f "${evidence_file}.tmp" "${evidence_file}"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "reviewer prose cannot forge a missing receipt" "missing_evidence" \
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

write_evidence "${contract}" 1 "Too expensive and takes too long for this session"
gate="$(quality_contract_gate_status_json 2>/dev/null || true)"
assert_eq "cost-shaped visionary claim cannot satisfy empirical floor" "missing_evidence" "$(jq -r '.status' <<<"${gate}")"
assert_eq "visionary criterion is named" "Q-003" "$(jq -r '.missing_ids | join(",")' <<<"${gate}")"

printf 'Test 7: summaries are bounded and include the visionary axis/status\n'
router_summary="$(quality_contract_router_summary adaptive execution high 1 1)"
if [[ ${#router_summary} -le 240 && "${router_summary}" == *visionary* ]]; then
  ok
else
  bad "router summary must be bounded and name visionary"
fi
status_summary="$(quality_contract_status_summary 2>/dev/null || true)"
if [[ ${#status_summary} -le 320 && "${status_summary}" == *Q-003* ]]; then
  ok
else
  bad "status summary must be bounded and name missing visionary proof"
fi

printf 'Test 8: syntax and Bash-3-compatible source surface\n'
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
