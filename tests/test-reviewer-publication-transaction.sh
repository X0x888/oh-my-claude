#!/usr/bin/env bash

# Crash/reordering regression net for reviewer publication. The dedicated
# reviewer hook owns dimension/evidence authority; the universal summary hook
# may publish accepted effects only after the exact lifecycle-bound reviewer
# receipt is durable. The receipt is the final WAL publication.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

TEST_HOME="$(mktemp -d -t reviewer-publication-home-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state" "${TEST_STATE_ROOT}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" \
  "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" \
  "${TEST_HOME}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" \
  "${TEST_HOME}/.claude/quality-pack/memory"
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"

ORIGINAL_HOME="${HOME}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${HOOK_DIR}/common.sh"

pass=0
fail=0

cleanup() {
  export HOME="${ORIGINAL_HOME}"
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_nonzero() {
  local label="$1" actual="$2"
  if [[ "${actual}" =~ ^[1-9][0-9]*$ ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected non-zero, actual=%q\n' \
      "${label}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing=%q output=%q\n' \
      "${label}" "${needle}" "${haystack:0:400}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected=%q output=%q\n' \
      "${label}" "${needle}" "${haystack:0:400}" >&2
    fail=$((fail + 1))
  fi
}

jsonl_count() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    jq -s 'length' "${path}"
  else
    printf '0'
  fi
}

artifact_byte_identity() {
  local path="$1" digest target
  if [[ -L "${path}" ]]; then
    target="$(readlink "${path}")" || return 1
    printf 'symlink:%s' "${target}"
  elif [[ -f "${path}" ]]; then
    digest="$(shasum -a 256 "${path}" | awk '{print $1}')" || return 1
    printf 'file:%s' "${digest}"
  elif [[ -e "${path}" ]]; then
    printf 'other'
  else
    printf 'absent'
  fi
}

reviewer_loose_stage_count() {
  local dir="$1"
  find "${dir}" -maxdepth 1 \
    \( -name '.reviewer-publication.stage.*' \
       -o -name 'quality_evidence.jsonl.tmp.*' \
       -o -name 'quality_frontier.json.tmp.*' \
       -o -name 'quality_frontier_history.jsonl.tmp.*' \) \
    | wc -l | tr -d '[:space:]'
}

reset_session() {
  local sid="$1" code_revision="${2:-0}"
  export SESSION_ID="${sid}"
  _state_validated=0
  ensure_session_dir
  printf '{}\n' >"$(session_file "session_state.json")"
  write_state_batch \
    "workflow_mode" "ultrawork" \
    "ulw_enforcement_active" "1" \
    "ulw_enforcement_generation" "1" \
    "review_cycle_id" "1" \
    "review_cycle_prompt_ts" "100" \
    "last_user_prompt_ts" "100" \
    "prompt_revision" "1" \
    "edit_revision" "${code_revision}" \
    "last_code_edit_revision" "${code_revision}" \
    "task_intent" "execution" \
    "review_dispatch_tracking_version" "1" \
    "native_agent_id_tracking_version" "1" \
    "subagent_dispatch_tracking_version" "1"
}

seed_reviewer_dispatch() {
  local sid="$1" native_id="$2" lifecycle_id="$3"
  local review_revision="${4:-0}" row
  export SESSION_ID="${sid}"
  row="$(jq -nc \
    --arg native "${native_id}" --arg lifecycle "${lifecycle_id}" \
    --argjson revision "${review_revision}" '
      {
        ts:100,
        agent_type:"quality-reviewer",
        description:"review the exact settled generation",
        lifecycle_dispatch_id:$lifecycle,
        edit_revision:$revision,
        code_revision:$revision,
        doc_revision:0,
        bash_revision:0,
        ui_revision:0,
        plan_revision:0,
        review_revision:$revision,
        objective_prompt_ts:100,
        objective_prompt_revision:1,
        objective_cycle_id:1,
        ulw_enforcement_generation:"1",
        review_dispatch_causality_version:1,
        native_agent_id:$native
      }
    ')"
  printf '%s\n' "${row}" >"$(session_file "pending_agents.jsonl")"
  printf '%s\n' "${row}" >"$(session_file "agent_dispatch_starts.jsonl")"
  jq -nc --arg native "${native_id}" --arg lifecycle "${lifecycle_id}" '
    {native_agent_id:$native,agent_type:"quality-reviewer",
     review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
     objective_cycle_id:1,ts:100}
  ' >"$(session_file "native_agent_bindings.jsonl")"
}

review_payload() {
  local sid="$1" native_id="$2" message="$3"
  jq -nc \
    --arg sid "${sid}" --arg native "${native_id}" \
    --arg message "${message}" '
      {session_id:$sid,agent_type:"quality-reviewer",agent_id:$native,
       last_assistant_message:$message,stop_hook_active:false}
    '
}

run_reviewer() {
  local sid="$1" native_id="$2" message="$3"
  local kill_at="${4:-}" fail_at="${5:-}" summary_finalize_kill="${6:-0}"
  local outcome_pending_kill="${7:-0}" rc
  set +e
  review_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_REVIEWER_TXN_KILL_AT="${kill_at}" \
      OMC_TEST_REVIEWER_TXN_FAIL_AT="${fail_at}" \
      OMC_TEST_REVIEWER_SUMMARY_KILL_AFTER_FINALIZE="${summary_finalize_kill}" \
      OMC_TEST_REVIEWER_OUTCOME_RECOVERY_KILL_AFTER_PENDING="${outcome_pending_kill}" \
      bash "${HOOK_DIR}/record-reviewer.sh" standard >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

# Run a sibling reviewer while an older exact waiter/receipt pair has neither
# live pending authority nor a settled parent outcome. That protected history
# must remain byte-addressable without becoming unrelated recovery work.
run_reviewer_with_protected_receipt_pair() {
  local sid="$1" native_id="$2" message="$3" rc
  set +e
  review_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/record-reviewer.sh" standard >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

run_reviewer_recovery() {
  local sid="$1" rc
  set +e
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-reviewer.sh" --recover-active "${sid}" \
    </dev/null >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

run_summary() {
  local sid="$1" native_id="$2" message="$3"
  review_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 || true
}

run_summary_output() {
  local sid="$1" native_id="$2" message="$3"
  local wait_attempts="${4:-1}"
  local recovery_claim="${5:-}"
  review_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_SUMMARY_REVIEWER_WAL_WAIT_ATTEMPTS="${wait_attempts}" \
      OMC_PUBLICATION_RECOVERY_INTERNAL="${recovery_claim:+1}" \
      OMC_REVIEWER_SUMMARY_REPLAY="${recovery_claim:+1}" \
      OMC_PUBLICATION_RECOVERY_CLAIM_ID="${recovery_claim}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" 2>/dev/null || true
}

run_stop() {
  local sid="$1"
  jq -nc --arg sid "${sid}" '
    {session_id:$sid,last_assistant_message:"Completion candidate.",
     stop_hook_active:false}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true
}

run_compact_session_start() {
  local sid="$1"
  jq -nc --arg sid "${sid}" \
    '{session_id:$sid,source:"compact"}' \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${TEST_HOME}/.claude/quality-pack/scripts/session-start-compact-handoff.sh" \
      2>/dev/null || true
}

run_resume_session_start() {
  local sid="$1"
  jq -nc --arg sid "${sid}" \
    '{session_id:$sid,source:"resume",transcript_path:""}' \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${TEST_HOME}/.claude/quality-pack/scripts/session-start-resume-handoff.sh" \
      2>/dev/null || true
}

run_user_prompt() {
  local sid="$1" prompt="$2"
  jq -nc --arg sid "${sid}" --arg prompt "${prompt}" \
    '{session_id:$sid,prompt:$prompt,transcript_path:"/tmp/none.jsonl"}' \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${TEST_HOME}/.claude/quality-pack/scripts/prompt-intent-router.sh" \
      2>/dev/null || true
}

printf 'Reviewer publication rejects NUL-normalized hook authority\n'
sid="reviewer-nul-hook-envelope"
native="native-reviewer-nul-hook-envelope"
lifecycle="dispatch-reviewernulhookenvelope"
reset_session "${sid}" 0
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}" 0
dir="${TEST_STATE_ROOT}/${sid}"
nul_review_payload="$(jq -nc --arg sid "${sid}" --arg native "${native}" '
  {session_id:$sid,agent_type:"quality-reviewer",agent_id:$native,
   last_assistant_message:("The generation is clean.\nVERDICT: CLEAN" + "\u0000"),
   stop_hook_active:false}')"
printf '%s' "${nul_review_payload}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-reviewer.sh" standard >/dev/null 2>&1 || true
printf '%s' "${nul_review_payload}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 || true
assert_eq "NUL-tailed CLEAN leaves pending owner intact" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "NUL-tailed CLEAN leaves start owner intact" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "NUL-tailed CLEAN publishes no reviewer receipt" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "NUL-tailed CLEAN publishes no universal summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "NUL-tailed CLEAN cannot tick review time" "" \
  "$(read_state "last_review_ts")"
assert_eq "NUL-tailed CLEAN cannot tick bug-hunt dimension" "" \
  "$(read_state "dim_bug_hunt_ts")"

printf 'Reviewer migration ledger rejects NUL-normalized persisted role\n'
sid="reviewer-nul-migration-ledger"
reset_session "${sid}" 0
seed_reviewer_dispatch "${sid}" "native-reviewer-nul-migration" \
  "dispatch-reviewernulmigration" 0
dir="${TEST_STATE_ROOT}/${sid}"
write_state "native_agent_id_tracking_version" ""
rm -f "${dir}/native_agent_bindings.jsonl"
for ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  jq -c 'del(.native_agent_id) | .agent_type += "\u0000"' \
    "${dir}/${ledger}" >"${dir}/${ledger}.tmp"
  mv "${dir}/${ledger}.tmp" "${dir}/${ledger}"
  cp "${dir}/${ledger}" "${dir}/${ledger}.before"
done
reviewer_nul_migration_rc="$(run_reviewer "${sid}" "" \
  $'The exact generation is clean.\nVERDICT: CLEAN')"
assert_nonzero "NUL-tailed migration reviewer row fails closed" \
  "${reviewer_nul_migration_rc}"
for ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  assert_eq "NUL migration reviewer preserves ${ledger}" "yes" \
    "$(cmp -s "${dir}/${ledger}.before" "${dir}/${ledger}" \
      && printf yes || printf no)"
done
assert_eq "NUL migration reviewer publishes no receipt" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

run_agent_dispatch() {
  local sid="$1" agent_type="$2" description="$3"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" \
    --arg description "${description}" '
      {session_id:$sid,tool_name:"Agent",
       tool_input:{subagent_type:$agent,description:$description,
         prompt:"continue the exact assigned work"}}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-pending-agent.sh" 2>/dev/null || true
}

run_agent_start() {
  local sid="$1" agent_type="$2" native_id="$3"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" \
    --arg native "${native_id}" '
      {session_id:$sid,agent_type:$agent,agent_id:$native}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/record-pending-agent.sh" start \
      >/dev/null 2>&1 || true
}

run_edit_pretool() {
  local sid="$1"
  jq -nc --arg sid "${sid}" '
    {session_id:$sid,tool_name:"Edit",tool_use_id:"edit-after-reviewer-wal",
     tool_input:{file_path:"/tmp/reviewer-wal-fixture",old_string:"a",new_string:"b"}}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/pretool-intent-guard.sh" 2>/dev/null || true
}

seed_advisory_dispatch() {
  local sid="$1" agent_type="$2" native_id="$3" lifecycle_id="$4" row
  export SESSION_ID="${sid}"
  row="$(jq -nc \
    --arg agent "${agent_type}" --arg native "${native_id}" \
    --arg lifecycle "${lifecycle_id}" '
      {
        ts:100,agent_type:$agent,description:"advisory structural review",
        lifecycle_dispatch_id:$lifecycle,edit_revision:0,code_revision:0,
        doc_revision:0,bash_revision:0,ui_revision:0,plan_revision:0,
        objective_prompt_ts:100,objective_prompt_revision:1,
        objective_cycle_id:1,ulw_enforcement_generation:"1",
        native_agent_id:$native
      }
    ')"
  printf '%s\n' "${row}" >"$(session_file "pending_agents.jsonl")"
  jq -nc --arg native "${native_id}" --arg agent "${agent_type}" \
      --arg lifecycle "${lifecycle_id}" '
    {native_agent_id:$native,agent_type:$agent,review_dispatch_id:"",
     lifecycle_dispatch_id:$lifecycle,objective_cycle_id:1,ts:100}
  ' >"$(session_file "native_agent_bindings.jsonl")"
}

run_advisory_summary() {
  local sid="$1" agent_type="$2" native_id="$3" message="$4"
  jq -nc \
    --arg sid "${sid}" --arg agent "${agent_type}" \
    --arg native "${native_id}" --arg message "${message}" '
      {session_id:$sid,agent_type:$agent,agent_id:$native,
       last_assistant_message:$message,stop_hook_active:false}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 || true
}

run_advisory_summary_effect_kill() {
  local sid="$1" agent_type="$2" native_id="$3" message="$4"
  local boundary="$5" rc
  set +e
  jq -nc \
    --arg sid "${sid}" --arg agent "${agent_type}" \
    --arg native "${native_id}" --arg message "${message}" '
      {session_id:$sid,agent_type:$agent,agent_id:$native,
       last_assistant_message:$message,stop_hook_active:false}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_SUMMARY_KILL_AFTER_EFFECT="${boundary}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null \
        2>"${TEST_STATE_ROOT}/${sid}/effect-kill.stderr"
  rc=$?
  set -e
  printf '%s' "${rc}"
}

run_advisory_summary_finalize_kill() {
  local sid="$1" agent_type="$2" native_id="$3" message="$4" rc
  set +e
  jq -nc \
    --arg sid "${sid}" --arg agent "${agent_type}" \
    --arg native "${native_id}" --arg message "${message}" '
      {session_id:$sid,agent_type:$agent,agent_id:$native,
       last_assistant_message:$message,stop_hook_active:false}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_SUMMARY_KILL_AFTER_FINALIZE=1 \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

quality_definition() {
  jq -cn '
    def criterion($id;$axis;$kind;$tool;$command;$artifacts): {
      id:$id,class:"must",axis:$axis,
      claim:("The " + $axis + " result is complete and causally verified."),
      rationale:("Independent " + $axis + " evidence is required."),
      surfaces:[($axis + " surface")],
      evidence_policy:{allowed_kinds:[$kind],minimum:1,
        requires_empirical:true,requires_independent_review:true},
      proof_method:("Inspect the exact " + $id + " proof."),
      proof_spec:{tool_names:[$tool],receipt_kinds:[$kind],
        command_contains:[$command],artifact_contains:$artifacts},
      failure_signal:("The exact " + $id + " proof is absent or fails."),
      tradeoff_boundary:"Convenience never weakens causal proof."
    };
    {
      north_star:"Ship a deliberate, distinctive, coherent, visionary, and complete recovery path.",
      audience:"Maintainers relying on crash-safe quality certification.",
      stakes:"Partial reviewer publication could falsely certify unfinished work.",
      ambition_boundary:"Prefer exact causal recovery over cosmetic completeness.",
      axes:{
        deliberate:"Every authority transition has an explicit reason.",
        distinctive:"The recovery contract is specific to this harness.",
        coherent:"Every consumer observes one publication generation.",
        visionary:"The strongest credible recovery design is tested.",
        complete:"Every crash boundary and hook order is covered."
      },
      standards:[{kind:"user",reference:"Comprehensive review mandate",
        rationale:"The user requires every identified issue to be fixed."}],
      anti_goals:["Do not self-certify provisional reviewer artifacts."],
      criteria:[
        criterion("Q-001";"deliberate";"inspection";"Grep";"Q-001";["AGENTS.md"]),
        criterion("Q-002";"distinctive";"inspection";"Grep";"Q-002";["README.md"]),
        criterion("Q-003";"coherent";"test";"Bash";
          "bash tests/test-reviewer-publication-transaction.sh --criterion Q-003";[]),
        criterion("Q-004";"visionary";"benchmark";"Bash";
          "bash tests/test-realwork-pairwise.sh --benchmark Q-004";[]),
        criterion("Q-005";"complete";"test";"Bash";
          "bash tests/test-stop-dispatch.sh --criterion Q-005";[])
      ]
    }
  '
}

build_quality_contract() {
  local definition objective_digest
  _omc_load_quality_contract
  definition="$(quality_definition)"
  objective_digest="$(_omc_token_digest \
    'Ship the exact reviewer publication transaction')"
  quality_contract_build_envelope "${definition}" 1 100 1 \
    "${objective_digest}" "1" 1 110 \
    "quality-planner" "native-quality-planner" \
    "dispatch-qualityplanner1234" 1
}

reset_quality_session() {
  local sid="$1" contract="$2"
  reset_session "${sid}" 0
  write_state_batch \
    "quality_contract_required" "1" \
    "quality_contract_id" "$(jq -r '.contract_id' <<<"${contract}")" \
    "quality_contract_revision" "$(jq -r '.contract_revision' <<<"${contract}")" \
    "quality_contract_cycle_id" "1" \
    "quality_contract_plan_revision" "1" \
    "quality_contract_prompt_revision" "1" \
    "quality_contract_late" "0" \
    "quality_contract_recheck_required" "" \
    "quality_constitution_status" "disabled" \
    "quality_constitution_blocking_ids" "" \
    "current_objective" "Ship the exact reviewer publication transaction" \
    "plan_revision" "1" \
    "last_edit_ts" "115" \
    "last_verify_ts" "120" \
    "last_verify_outcome" "passed" \
    "last_verify_confidence" "90"
  printf '%s\n' "${contract}" >"$(session_file "quality_contract.json")"
}

quality_receipt_rows() {
  local contract="$1" confidence="${2:-90}" id revision cycle
  local rows receipt tool command launcher_path launcher_digest
  local launcher_identity subject_path subject_digest subject_identity receipt_id
  local command_digest artifact proof_tool proof_target proof_identity project_test_cmd
  local canonical_agents canonical_readme tool_cwd
  id="$(jq -r '.contract_id' <<<"${contract}")"
  revision="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  canonical_agents="$(_verification_normalize_proof_path \
    "${REPO_ROOT}/AGENTS.md")"
  canonical_readme="$(_verification_normalize_proof_path \
    "${REPO_ROOT}/README.md")"
  tool_cwd="$(_verification_normalize_proof_path "${REPO_ROOT}")"
  rows="$(jq -cn \
    --arg id "${id}" --argjson revision "${revision}" \
    --argjson cycle "${cycle}" --argjson confidence "${confidence}" \
    --arg agents "${canonical_agents}" --arg readme "${canonical_readme}" '
      def row($n;$tool;$command;$kind;$artifact):
        {_v:3,receipt_id:("vr-proof-"+$n),tool_use_id:("tool-proof-"+$n),
         tool_name:$tool,input_digest:("input-digest-"+$n),command:$command,
         command_digest:("command-digest-"+$n),outcome:"passed",confidence:$confidence,
         method:(if $tool == "Bash" then "project_test_command"
                 else "source_inspection" end),
         scope:(if $tool == "Bash" then "full" else "workspace_source" end),
         evidence_kind:$kind,result:"1 passed",result_digest:("result-digest-"+$n),
         artifact_target:$artifact,
         artifact_digest:(if $artifact == "" then "" else ("artifact-digest-"+$n) end),
         launcher_path:"",launcher_digest:"",launcher_identity:"",
         subject_path:"",subject_digest:"",subject_identity:"",
         tool_cwd:"",proof_identity:("vp-proof-"+$n),
         edit_revision:0,code_revision:0,
         plan_revision:1,review_cycle_id:$cycle,quality_contract_id:$id,
         quality_contract_revision:$revision,ts:190};
      [row("001";"Grep";("Grep:"+$agents+":Q-001");"inspection";$agents),
       row("002";"Grep";("Grep:"+$readme+":Q-002");"inspection";$readme),
       row("003";"Bash";"bash tests/test-reviewer-publication-transaction.sh --criterion Q-003";"test";""),
       row("004";"Bash";"bash tests/test-realwork-pairwise.sh --benchmark Q-004";"benchmark";""),
       row("005";"Bash";"bash tests/test-stop-dispatch.sh --criterion Q-005";"test";"")]
      | .[]
    ')"
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    tool="$(jq -r '.tool_name' <<<"${receipt}")"
    command="$(jq -r '.command' <<<"${receipt}")"
    artifact="$(jq -r '.artifact_target' <<<"${receipt}")"
    command_digest="$(verification_receipt_command_digest \
      "${command}" "${tool}")"
    proof_tool="${tool}"
    proof_target="${command}"
    if [[ "${tool}" == "Bash" ]]; then
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
    elif [[ "${tool}" == "Grep" ]]; then
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
    fi
    proof_identity="$(_quality_contract_expected_proof_identity \
      "${proof_tool}" "${proof_target}" "${artifact}" "${contract}" 0 1)"
    receipt="$(jq -c \
      --arg command_digest "${command_digest}" \
      --arg proof_identity "${proof_identity}" '
        .command_digest=$command_digest | .proof_identity=$proof_identity
      ' <<<"${receipt}")"
    receipt_id="$(_quality_contract_receipt_expected_id "${receipt}")"
    jq -c --arg receipt_id "${receipt_id}" \
      '.receipt_id=$receipt_id' <<<"${receipt}"
  done <<<"${rows}"
}

write_quality_receipts() {
  local contract="$1" confidence="${2:-90}"
  quality_receipt_rows "${contract}" "${confidence}" \
    >"$(session_file "verification_receipts.jsonl")"
}

quality_review_json() {
  local contract="$1" confidence="${2:-90}" rows r1 r2 r3 r4 r5
  rows="$(quality_receipt_rows "${contract}" "${confidence}")"
  r1="$(jq -sr '[.[] | select(.tool_use_id == "tool-proof-001")][0].receipt_id' <<<"${rows}")"
  r2="$(jq -sr '[.[] | select(.tool_use_id == "tool-proof-002")][0].receipt_id' <<<"${rows}")"
  r3="$(jq -sr '[.[] | select(.tool_use_id == "tool-proof-003")][0].receipt_id' <<<"${rows}")"
  r4="$(jq -sr '[.[] | select(.tool_use_id == "tool-proof-004")][0].receipt_id' <<<"${rows}")"
  r5="$(jq -sr '[.[] | select(.tool_use_id == "tool-proof-005")][0].receipt_id' <<<"${rows}")"
  jq -cn --arg r1 "${r1}" --arg r2 "${r2}" --arg r3 "${r3}" \
    --arg r4 "${r4}" --arg r5 "${r5}" '
    {
      criteria:[
        {id:"Q-001",status:"met",evidence_kind:"inspection",
         basis:"The authority transition has an explicit causal rationale.",refs:[$r1]},
        {id:"Q-002",status:"met",evidence_kind:"inspection",
         basis:"The transaction is specific to the harness lifecycle.",refs:[$r2]},
        {id:"Q-003",status:"met",evidence_kind:"test",
         basis:"All consumers observe the same committed generation.",refs:[$r3]},
        {id:"Q-004",status:"met",evidence_kind:"benchmark",
         basis:"The strongest recovery design beat the provisional baseline.",refs:[$r4]},
        {id:"Q-005",status:"met",evidence_kind:"test",
         basis:"Every crash boundary and hook order has regression coverage.",refs:[$r5]}
      ],
      alternatives_searched:[
        "Compared direct writes and rejected their partial publication window.",
        "Compared rollback and roll-forward journals using injected process death."
      ],
      limits:["Production filesystem failures remain outside this local proof."],
      frontier:{material:false,bar_quality:"strong",
        title:"No remaining material dominating recovery",
        why:"Every in-scope publication boundary now converges exactly once.",
        recommended_move:"Ship the causally certified reviewer transaction.",
        criterion_ids:[],evidence:[$r4],
        experiment:"Killed each publication boundary and replayed the exact native completion."}
    }
  '
}

seed_excellence_dispatch() {
  local sid="$1" native_id="$2" lifecycle_id="$3" contract="$4" row
  export SESSION_ID="${sid}"
  row="$(jq -nc \
    --arg native "${native_id}" --arg lifecycle "${lifecycle_id}" \
    --arg contract_id "$(jq -r '.contract_id' <<<"${contract}")" \
    --argjson contract_revision "$(jq -r '.contract_revision' <<<"${contract}")" '
      {ts:100,agent_type:"excellence-reviewer",
       description:"certify the exact Definition generation",
       lifecycle_dispatch_id:$lifecycle,edit_revision:0,code_revision:0,
       doc_revision:0,bash_revision:0,ui_revision:0,plan_revision:1,
       review_revision:0,objective_prompt_ts:100,objective_prompt_revision:1,
       objective_cycle_id:1,ulw_enforcement_generation:"1",
       review_dispatch_causality_version:1,native_agent_id:$native,
       quality_contract_id:$contract_id,
       quality_contract_revision:$contract_revision}
    ')"
  printf '%s\n' "${row}" >"$(session_file "pending_agents.jsonl")"
  printf '%s\n' "${row}" >"$(session_file "agent_dispatch_starts.jsonl")"
  jq -nc --arg native "${native_id}" --arg lifecycle "${lifecycle_id}" '
    {native_agent_id:$native,agent_type:"excellence-reviewer",
     review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
     objective_cycle_id:1,ts:100}
  ' >"$(session_file "native_agent_bindings.jsonl")"
}

quality_review_message() {
  local review="$1"
  printf 'Independent Definition review.\nQUALITY_REVIEW_JSON: %s\nVERDICT: SHIP' \
    "${review}"
}

excellence_payload() {
  local sid="$1" native_id="$2" message="$3"
  jq -nc --arg sid "${sid}" --arg native "${native_id}" \
    --arg message "${message}" '
      {session_id:$sid,agent_type:"excellence-reviewer",agent_id:$native,
       last_assistant_message:$message,stop_hook_active:false}
    '
}

run_excellence() {
  local sid="$1" native_id="$2" message="$3" kill_at="${4:-}"
  local live_threshold="${5:-}" history_tail_fault="${6:-0}" rc
  set +e
  excellence_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_REVIEWER_TXN_KILL_AT="${kill_at}" \
      OMC_TEST_REVIEWER_HISTORY_TAIL_FAULT="${history_tail_fault}" \
      OMC_VERIFY_CONFIDENCE_THRESHOLD="${live_threshold}" \
      bash "${HOOK_DIR}/record-reviewer.sh" excellence >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

run_excellence_summary() {
  local sid="$1" native_id="$2" message="$3"
  excellence_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 || true
}

clean_message=$'The settled generation is clean.\nVERDICT: CLEAN'

printf 'Reviewer causality: native binding and causal rows are exact\n'
for binding_case in native agent lifecycle review cycle legacy duplicate malformed; do
  sid="reviewer-binding-${binding_case}"
  native="native-reviewer-binding-${binding_case}"
  lifecycle="dispatch-reviewerbinding${binding_case}1234"
  reset_session "${sid}"
  seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  case "${binding_case}" in
    native) jq -c '.native_agent_id="foreign-native"' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    agent) jq -c '.agent_type="foreign-reviewer"' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    lifecycle) jq -c '.lifecycle_dispatch_id="dispatch-foreignbinding1234"' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    review) jq -c '.review_dispatch_id="foreign-review"' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    cycle) jq -c '.objective_cycle_id=2' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    legacy) jq -c '{native_agent_id,agent_type}' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    duplicate) cat "${dir}/native_agent_bindings.jsonl" \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    malformed) { cat "${dir}/native_agent_bindings.jsonl"; \
      printf '%s\n' 'malformed-binding-row'; } >"${dir}/binding.tmp" ;;
  esac
  mv "${dir}/binding.tmp" "${dir}/native_agent_bindings.jsonl"
  run_reviewer "${sid}" "${native}" "${clean_message}" >/dev/null
  assert_eq "${binding_case} binding: review cannot tick a dimension" "" \
    "$(jq -r '.dim_code_quality_verdict // empty' \
      "${dir}/session_state.json")"
  assert_eq "${binding_case} binding: pending authority is retained" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${binding_case} binding: start authority is retained" \
    "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${binding_case} binding: no receipt is forged" "0" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
done

sid="reviewer-binding-missing-pending"
native="native-reviewer-binding-missing-pending"
lifecycle="dispatch-reviewerbindingmissingpending1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
: >"${dir}/pending_agents.jsonl"
run_reviewer "${sid}" "${native}" "${clean_message}" >/dev/null
assert_eq "missing pending: reviewer cannot tick a dimension" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' \
    "${dir}/session_state.json")"
assert_eq "missing pending: absent authority is not reconstructed" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "missing pending: start authority is retained" \
  "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "missing pending: no receipt is forged" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

sid="reviewer-binding-frozen-mismatch"
native="native-reviewer-binding-frozen-mismatch"
lifecycle="dispatch-reviewerbindingfrozenmismatch1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
jq -c '.objective_prompt_revision=2' \
  "${dir}/pending_agents.jsonl" >"${dir}/pending.tmp"
mv -f "${dir}/pending.tmp" "${dir}/pending_agents.jsonl"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
run_reviewer "${sid}" "${native}" "${clean_message}" >/dev/null
assert_eq "frozen mismatch: reviewer cannot tick a dimension" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' \
    "${dir}/session_state.json")"
assert_eq "frozen mismatch: pending authority is retained" \
  "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
assert_eq "frozen mismatch: start authority is retained" \
  "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "frozen mismatch: no receipt is forged" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

sid="reviewer-duplicate-start-candidate"
native="native-reviewer-duplicate-start"
lifecycle="dispatch-reviewerduplicatestart1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
cat "${dir}/agent_dispatch_starts.jsonl" \
  >>"${dir}/agent_dispatch_starts.jsonl.duplicate"
cat "${dir}/agent_dispatch_starts.jsonl" \
  >>"${dir}/agent_dispatch_starts.jsonl.duplicate"
mv "${dir}/agent_dispatch_starts.jsonl.duplicate" \
  "${dir}/agent_dispatch_starts.jsonl"
run_reviewer "${sid}" "${native}" "${clean_message}" >/dev/null
assert_eq "duplicate reviewer start: no dimension is published" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' \
    "${dir}/session_state.json")"
assert_eq "duplicate reviewer start: both ambiguous rows remain" "2" \
  "$(jq -s 'length' "${dir}/agent_dispatch_starts.jsonl")"

printf 'Reviewer/summary rendezvous: both hook orders\n'
sid="reviewer-order-first"
native="native-reviewer-first"
lifecycle="dispatch-reviewerfirst1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "reviewer-first: dedicated publication succeeds" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "reviewer-first: state is authoritative before summary" "CLEAN" \
  "$(jq -r '.dim_code_quality_verdict' "${dir}/session_state.json")"
assert_eq "reviewer-first: one receipt is published last" "1" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "reviewer-first: no universal summary is fabricated" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "reviewer-first: pending remains for universal hook" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
run_summary "${sid}" "${native}" "${clean_message}"
assert_eq "reviewer-first: summary consumes pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "reviewer-first: exact receipt authorizes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "reviewer-first: exact receipt authorizes accepted outcome" \
  "accepted" "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"

printf 'Reviewer recovery: waiter messages are content-bound and NUL-safe\n'
for waiter_corruption in modified nul; do
  sid="reviewer-waiter-integrity-${waiter_corruption}"
  native="native-reviewer-waiter-integrity-${waiter_corruption}"
  lifecycle="dispatch-reviewerwaiterintegrity${waiter_corruption}"
  reset_session "${sid}"
  seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  run_summary "${sid}" "${native}" "${clean_message}"
  waiter_digest="$(jq -r '.completion_digest' \
    "${dir}/reviewer_summary_waiters.jsonl")"
  jq -nc --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg digest "${waiter_digest}" '
    {schema_version:1,decided_at:101,lifecycle_dispatch_id:$lifecycle,
     agent_type:"quality-reviewer",reviewer_type:"standard",
     native_agent_id:$native,completion_digest:$digest,status:"accepted",
     reason:"",verdict:"CLEAN",start_review_revision:0,
     result_review_revision:0}
  ' >"${dir}/reviewer_publication_outcomes.jsonl"
  if [[ "${waiter_corruption}" == "modified" ]]; then
    jq -c '.message += " tampered"' \
      "${dir}/reviewer_summary_waiters.jsonl" \
      >"${dir}/reviewer_summary_waiters.jsonl.tmp"
  else
    jq -c '.message += "\u0000"' \
      "${dir}/reviewer_summary_waiters.jsonl" \
      >"${dir}/reviewer_summary_waiters.jsonl.tmp"
  fi
  mv -f "${dir}/reviewer_summary_waiters.jsonl.tmp" \
    "${dir}/reviewer_summary_waiters.jsonl"
  waiter_before="$(<"${dir}/reviewer_summary_waiters.jsonl")"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  receipt_before="$(<"${dir}/reviewer_publication_outcomes.jsonl")"
  waiter_recovery_rc="$(run_reviewer_recovery "${sid}")"
  assert_nonzero "${waiter_corruption} waiter: recovery fails closed" \
    "${waiter_recovery_rc}"
  assert_eq "${waiter_corruption} waiter: authority stays unconsumed" \
    "${waiter_before}" "$(<"${dir}/reviewer_summary_waiters.jsonl")"
  assert_eq "${waiter_corruption} waiter: pending stays byte-exact" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${waiter_corruption} waiter: start stays byte-exact" \
    "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${waiter_corruption} waiter: receipt stays byte-exact" \
    "${receipt_before}" "$(<"${dir}/reviewer_publication_outcomes.jsonl")"
  assert_eq "${waiter_corruption} waiter: no summary is replayed" "0" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${waiter_corruption} waiter: no parent outcome is published" \
    "0" "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
done

sid="reviewer-order-summary"
native="native-summary-first"
lifecycle="dispatch-summaryfirst12345"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
summary_first_waiter="$(<"${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "summary-first: leaves one durable reviewer waiter" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "summary-first: publishes no provisional claim" "false" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
assert_eq "summary-first: publishes no universal summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary-first: publishes no parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first: dedicated hook commits and replays" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "summary-first: exact pair publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary-first: exact pair publishes one outcome" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first: internal replay publishes no ignored duplicate" "0" \
  "$(jq -s '[.[] | select(.status == "ignored")] | length' \
    "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first: exact pair consumes both causal rows" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") ))"
assert_eq "summary-first: waiter is settled" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"

# A foreground/background delivery may consume the causal parent outcome
# before a post-commit crash-recovery pass sees the orphaned waiter. Its receipt
# projects the same compact outcome, so reviewer recovery still settles the
# waiter without replaying review effects.
printf '%s\n' "${summary_first_waiter}" \
  >"${dir}/reviewer_summary_waiters.jsonl"
jq -c '. as $outcome | $outcome + {
    notification_receipt:true,notification_kind:"agent-posttool",
    notification_key:"agent-posttool|tool:reviewer-orphan-receipt",
    notification_agent_type:.agent_type,
    notification_native_agent_id:(.native_agent_id // ""),
    notification_review_dispatch_id:(.review_dispatch_id // ""),
    completion_outcome:$outcome
  }' "${dir}/agent_completion_outcomes.jsonl" \
  >"${dir}/agent_completion_outcomes.receipt.jsonl"
mv -f "${dir}/agent_completion_outcomes.receipt.jsonl" \
  "${dir}/agent_completion_outcomes.jsonl"
assert_eq "receipt outcome: reviewer recovery succeeds" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "receipt outcome: reviewer orphan waiter settles" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "receipt outcome: reviewer effects remain singular" "1" \
  "$(jsonl_count "${dir}/review_history.jsonl")"

# A coordinate-shaped fragment is not a producer outcome. It must not retire
# a waiter merely because lifecycle/role/native/status happen to match.
printf '%s\n' "${summary_first_waiter}" \
  >"${dir}/reviewer_summary_waiters.jsonl"
jq -nc --arg lifecycle "$(jq -r '.lifecycle_dispatch_id' \
    <<<"${summary_first_waiter}")" \
    --arg agent "$(jq -r '.agent_type' <<<"${summary_first_waiter}")" \
    --arg native "$(jq -r '.native_agent_id' <<<"${summary_first_waiter}")" '
      {lifecycle_dispatch_id:$lifecycle,agent_type:$agent,
       native_agent_id:$native,status:"accepted"}
    ' >"${dir}/agent_completion_outcomes.jsonl"
assert_eq "partial outcome: reviewer recovery fails closed" "1" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "partial outcome: exact waiter remains protected" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"

# pending_agents.jsonl is a bounded compatibility ledger and may contain an
# unrelated legacy/malformed line. It is not transaction authority: an exact
# summary-first claim must still let the dedicated publisher derive its narrow
# capability, commit, and settle without deleting the unrelated raw bytes.
sid="reviewer-summary-first-pending-noise"
native="native-summary-first-pending-noise"
lifecycle="dispatch-summaryfirstnoise123"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
printf '%s\n' 'legacy-malformed-pending-noise' \
  >>"${dir}/pending_agents.jsonl"
assert_eq "pending noise: dedicated hook still commits and replays" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "pending noise: exact pair publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "pending noise: exact pair publishes one accepted outcome" \
  "accepted" "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "pending noise: exact valid pending row is consumed" "0" \
  "$(jq -Rsr '[split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")] | length' \
    "${dir}/pending_agents.jsonl")"
assert_eq "pending noise: unrelated raw line is preserved" "1" \
  "$(grep -Fxc 'legacy-malformed-pending-noise' \
    "${dir}/pending_agents.jsonl" || true)"
assert_eq "pending noise: reviewer waiter is settled" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"

printf 'Advisory reviewer contracts do not wait for a nonexistent dedicated hook\n'
for advisory_agent in abstraction-critic rigor-reviewer; do
  advisory_slug="${advisory_agent//-/_}"
  sid="advisory-${advisory_slug}"
  native="native-${advisory_slug}"
  lifecycle="dispatch-${advisory_slug}12345678"
  reset_session "${sid}"
  seed_advisory_dispatch \
    "${sid}" "${advisory_agent}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  run_advisory_summary \
    "${sid}" "${advisory_agent}" "${native}" "${clean_message}"
  assert_eq "${advisory_agent}: universal summary does not wait for receipt" \
    "1" "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${advisory_agent}: universal outcome is accepted" "accepted" \
    "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${advisory_agent}: pending lifecycle is consumed" "0" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  assert_eq "${advisory_agent}: no reviewer waiter can deadlock" "0" \
    "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
done

printf 'Namespaced lookalikes without configured hooks remain universal-only\n'
sid="namespaced-reviewer-lookalike"
native="native-namespaced-reviewer-lookalike"
reset_session "${sid}"
run_agent_dispatch "${sid}" "custom:quality-reviewer" \
  "review without a configured dedicated publisher" >/dev/null
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "namespaced lookalike: dispatch creates no dedicated start" "0" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
run_agent_start "${sid}" "custom:quality-reviewer" "${native}"
assert_eq "namespaced lookalike: native start binds the universal row" \
  "${native}" "$(jq -r '.native_agent_id // empty' \
    "${dir}/pending_agents.jsonl")"
assert_eq "namespaced lookalike: native bind still creates no dedicated start" \
  "0" "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
# The ordinary lookalike must not occupy the configured reviewer's causal slot.
# Basename-only matching used to make this pending row deny a real
# quality-reviewer dispatch even though no hook could ever publish the custom
# role's dedicated receipt.
run_agent_dispatch "${sid}" "quality-reviewer" \
  "review with the configured dedicated publisher" >/dev/null
assert_eq "namespaced lookalike: real reviewer dispatch is admitted" "2" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "namespaced lookalike: real reviewer alone gets dedicated start" \
  "quality-reviewer" "$(jq -r '.agent_type // empty' \
    "${dir}/agent_dispatch_starts.jsonl")"
run_advisory_summary \
  "${sid}" "custom:quality-reviewer" "${native}" "${clean_message}"
assert_eq "namespaced lookalike: universal result is accepted" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "namespaced lookalike: no phantom reviewer waiter is created" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "namespaced lookalike: custom completion preserves real pending" \
  "quality-reviewer" "$(jq -r '.agent_type // empty' \
    "${dir}/pending_agents.jsonl")"

# The same exact-identity rule applies to the echoed-ID migration path. A
# phantom pre-fix start for custom:quality-reviewer cannot be claimed by the
# configured quality-reviewer hook merely because the suffix and token match.
sid="reviewer-legacy-namespaced-lookalike"
native=""
lifecycle="dispatch-reviewerlegacynamespaced"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
write_state "native_agent_id_tracking_version" ""
for lookalike_file in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  jq -c '.agent_type="custom:quality-reviewer"
    | .review_dispatch_id="phantom-review"
    | .native_agent_id=""' "${dir}/${lookalike_file}" \
    >"${dir}/${lookalike_file}.tmp"
  mv -f "${dir}/${lookalike_file}.tmp" "${dir}/${lookalike_file}"
done
lookalike_review_message=$'A clean configured review.\nREVIEW_DISPATCH_ID: phantom-review\nVERDICT: CLEAN'
assert_eq "legacy namespaced lookalike: hook handles rejection" "0" \
  "$(run_reviewer "${sid}" "${native}" "${lookalike_review_message}")"
assert_eq "legacy namespaced lookalike: cannot publish verdict" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' \
    "${dir}/session_state.json")"
assert_eq "legacy namespaced lookalike: phantom start remains" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "legacy namespaced lookalike: no receipt is forged" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

printf 'Advisory reviewer recovery uses the universal publisher, not a phantom receipt\n'
for advisory_agent in abstraction-critic rigor-reviewer custom:quality-reviewer; do
  advisory_slug="${advisory_agent//:/_}"
  advisory_slug="${advisory_slug//-/_}"

  sid="advisory-finalize-${advisory_slug}"
  native="native-finalize-${advisory_slug}"
  lifecycle="dispatch-finalize-${advisory_slug}12345678"
  reset_session "${sid}"
  seed_advisory_dispatch \
    "${sid}" "${advisory_agent}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  advisory_finalize_rc="$(run_advisory_summary_finalize_kill \
    "${sid}" "${advisory_agent}" "${native}" "${clean_message}")"
  assert_eq "${advisory_agent}: finalizer split kills the publisher" \
    "137" "${advisory_finalize_rc}"
  assert_eq "${advisory_agent}: universal effects committed before death" \
    "true" "$(jq -r '.completion_claim_effects_complete // false' \
      "${dir}/pending_agents.jsonl")"
  assert_eq "${advisory_agent}: no outcome precedes barrier recovery" "0" \
    "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  write_state "advisory_recovery_probe" "finalizer"
  assert_eq "${advisory_agent}: barrier repairs the accepted outcome" \
    "accepted" "$(jq -r '.status' \
      "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${advisory_agent}: finalizer recovery repeats no effect" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${advisory_agent}: finalizer recovery settles the claim" "0" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  assert_eq "${advisory_agent}: recovery fabricates no reviewer authority" \
    "0" "$(( $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") \
      + $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") ))"

  sid="advisory-effect-${advisory_slug}"
  native="native-effect-${advisory_slug}"
  lifecycle="dispatch-effect-${advisory_slug}12345678"
  reset_session "${sid}"
  seed_advisory_dispatch \
    "${sid}" "${advisory_agent}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  advisory_effect_rc="$(run_advisory_summary_effect_kill \
    "${sid}" "${advisory_agent}" "${native}" "${clean_message}" \
    "summary")"
  assert_eq "${advisory_agent}: effect split kills the publisher" \
    "137" "${advisory_effect_rc}"
  assert_eq "${advisory_agent}: interrupted effect claim is incomplete" \
    "false" "$(jq -r '.completion_claim_effects_complete // false' \
      "${dir}/pending_agents.jsonl")"
  jq -c '.completion_claim_ts = 1' "${dir}/pending_agents.jsonl" \
    >"${dir}/pending_agents.expired.jsonl"
  mv -f "${dir}/pending_agents.expired.jsonl" \
    "${dir}/pending_agents.jsonl"
  write_state "advisory_recovery_probe" "effect"
  assert_eq "${advisory_agent}: expired effect replay is accepted" \
    "accepted" "$(jq -r '.status' \
      "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${advisory_agent}: effect replay remains idempotent" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${advisory_agent}: effect replay settles the claim" "0" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  assert_eq "${advisory_agent}: effect replay fabricates no receipt" "0" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
done

printf 'Reviewer prepare staging: pre-WAL death is inert and recoverable\n'
sid="reviewer-prepare-death"
native="native-reviewer-prepare-death"
lifecycle="dispatch-reviewerpreparedeath"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "prepare_complete")"
assert_nonzero "prepare death: injected process death is observable" \
  "${kill_rc}"
assert_eq "prepare death: fixed WAL was not published" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "prepare death: one inert prepare directory survives" "1" \
  "$(find "${dir}" -maxdepth 1 -type d \
      -name '.reviewer-transaction.prepare.*' | wc -l | tr -d ' ')"
assert_eq "prepare death: one inert receipt stage survives" "1" \
  "$(reviewer_loose_stage_count "${dir}")"
assert_eq "prepare death: no authoritative reviewer publication escaped" "0" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"
assert_eq "prepare death: healthy replay cleans staging and commits" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "prepare death: stale prepare directory is retired" "0" \
  "$(find "${dir}" -maxdepth 1 -type d \
      -name '.reviewer-transaction.prepare.*' | wc -l | tr -d ' ')"
assert_eq "prepare death: loose receipt stage is retired" "0" \
  "$(reviewer_loose_stage_count "${dir}")"
assert_eq "prepare death: publication and deferred summary converge once" "4" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") \
      + $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
assert_eq "prepare death: causal pair and waiter are settled" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

printf 'Reviewer WAL: every publication boundary converges exactly once\n'
boundaries='wal_prepared start_consumed state_published history_published receipt_published'
index=0
for boundary in ${boundaries}; do
  index=$((index + 1))
  sid="reviewer-wal-${index}"
  native="native-reviewer-wal-${index}"
  lifecycle="dispatch-reviewerwal${index}abcdefgh"
  reset_session "${sid}"
  seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  run_summary "${sid}" "${native}" "${clean_message}"
  kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
    "${boundary}")"
  assert_nonzero "${boundary}: injected process death is observable" \
    "${kill_rc}"
  assert_eq "${boundary}: durable WAL survives process death" "1" \
    "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
  stop_out="$(run_stop "${sid}")"
  assert_contains "${boundary}: ordinary Stop cannot observe provisional state" \
    "Reviewer publication · recovery pending" "${stop_out}"
  assert_eq "${boundary}: no provisional universal summary" "0" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${boundary}: no provisional parent outcome" "0" \
    "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  if [[ "${boundary}" == "receipt_published" ]]; then
    expected_receipts=1
  else
    expected_receipts=0
  fi
  assert_eq "${boundary}: receipt is the final commit marker" \
    "${expected_receipts}" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
  assert_eq "${boundary}: healthy replay finishes the transaction" "0" \
    "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
  assert_eq "${boundary}: recovered state is authoritative" "CLEAN" \
    "$(jq -r '.dim_code_quality_verdict' "${dir}/session_state.json")"
  assert_eq "${boundary}: recovered receipt is singular" "1" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
  assert_eq "${boundary}: recovered history is singular" "1" \
    "$(jsonl_count "${dir}/review_history.jsonl")"
  assert_eq "${boundary}: deferred summary is singular" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${boundary}: deferred outcome is singular" "1" \
    "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${boundary}: causal pair and waiter are settled" "0" \
    "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
        + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
        + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"
  assert_eq "${boundary}: completed WAL is retired" "0" \
    "$([[ -e "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
done

printf 'Reviewer recovery entrypoint: sentinel, authority, and post-commit death\n'
sid="reviewer-recover-missing-sentinel"
native="native-reviewer-recover-sentinel"
lifecycle="dispatch-reviewerrecoversentinel"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "missing sentinel: injected process death is observable" \
  "${kill_rc}"
rm -f "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
assert_eq "missing sentinel: internal recovery does not fast-success" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "missing sentinel: valid WAL is actually retired" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "missing sentinel: receipt-bound waiter still converges" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"

sid="reviewer-recover-inactive-authority"
native="native-reviewer-recover-inactive"
lifecycle="dispatch-reviewerrecoverinactive"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "inactive authority: injected process death is observable" \
  "${kill_rc}"
jq '.workflow_mode="normal" | .ulw_enforcement_active="0"' \
  "${dir}/session_state.json" >"${dir}/session_state.inactive.json"
mv -f "${dir}/session_state.inactive.json" "${dir}/session_state.json"
assert_nonzero "inactive authority: recovery fails instead of ignoring WAL" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "inactive authority: unresolved WAL remains fail-closed" "1" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
jq '.workflow_mode="ultrawork" | .ulw_enforcement_active="1"' \
  "${dir}/session_state.json" >"${dir}/session_state.active.json"
mv -f "${dir}/session_state.active.json" "${dir}/session_state.json"
assert_eq "inactive authority: restored exact interval can recover" "0" \
  "$(run_reviewer_recovery "${sid}")"

sid="reviewer-recover-before-pretool"
native="native-reviewer-recover-pretool"
lifecycle="dispatch-reviewerrecoverpretool"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "PreTool recovery: injected process death is observable" \
  "${kill_rc}"
pretool_out="$(run_edit_pretool "${sid}")"
assert_not_contains "PreTool recovery: valid WAL does not deny newer tool" \
  '"permissionDecision":"deny"' "${pretool_out}"
assert_eq "PreTool recovery: fixed WAL is proven absent before tool" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "PreTool recovery: reviewer receipt/history converge exactly once" "2" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"

sid="reviewer-recover-after-receipt"
native="native-reviewer-recover-after-receipt"
lifecycle="dispatch-reviewerrecoverreceipt"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "transaction_committed")"
assert_nonzero "post-commit death: injected process death is observable" \
  "${kill_rc}"
assert_eq "post-commit death: receipt is durable" "1" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "post-commit death: no active WAL remains to trigger recovery" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "post-commit death: waiter is still awaiting replay" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "post-commit death: lifecycle reconciliation succeeds" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "post-commit death: summary converges without user replay" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "post-commit death: outcome and history remain singular" "2" \
  "$(( $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"
assert_eq "post-commit death: causal rows and waiter settle" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

sid="reviewer-recover-after-wal-retire"
native="native-reviewer-recover-after-wal-retire"
lifecycle="dispatch-reviewerrecoverwalretire"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_retired")"
assert_nonzero "WAL-retire death: injected process death is observable" \
  "${kill_rc}"
assert_eq "WAL-retire death: fixed WAL is atomically absent" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "WAL-retire death: one inert committed directory survives" "1" \
  "$(find "${dir}" -maxdepth 1 -type d \
      -name '.reviewer-transaction.committed.*' | wc -l | tr -d ' ')"
assert_eq "WAL-retire death: receipt and history are already durable" "2" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"
assert_eq "WAL-retire death: waiter has not published universal effects" "0" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
committed_dir="$(find "${dir}" -maxdepth 1 -type d \
  -name '.reviewer-transaction.committed.*' -print -quit)"
# This exact mktemp shape can be carried through the fixed-name rename when a
# summary continuation dies between staging and publishing its retry counter.
printf '1\n' >"${committed_dir}/.summary-retry-count.ABC123"
assert_eq "WAL-retire death: lifecycle recovery succeeds" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "WAL-retire death: inert WAL and exact retry temp are retired" "0" \
  "$(find "${dir}" -maxdepth 1 -type d \
      -name '.reviewer-transaction.committed.*' | wc -l | tr -d ' ')"
assert_eq "WAL-retire death: deferred summary and outcome converge once" "2" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
assert_eq "WAL-retire death: causal rows and waiter settle" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

printf 'Reviewer summary outcome split: ordinary locked writes repair exactly\n'
sid="reviewer-summary-post-finalizer-death"
native="native-reviewer-summary-finalizer"
lifecycle="dispatch-reviewersummaryfinalizer"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
assert_eq "post-finalizer death: summary-first waiter is durable" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "post-finalizer death: dedicated publication itself succeeds" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}" "" "" 1)"
assert_eq "post-finalizer death: effects-complete row is retained" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
assert_eq "post-finalizer death: accepted outcome has not landed" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "post-finalizer death: receipt and waiter remain repair authority" "2" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"
with_state_lock_batch "unrelated_after_reviewer_repair" "kept"
assert_eq "post-finalizer death: ordinary locked write persists" "kept" \
  "$(read_state "unrelated_after_reviewer_repair")"
assert_eq "post-finalizer death: accepted outcome is singular" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "post-finalizer death: pending and waiter converge" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

sid="reviewer-summary-post-pending-death"
native="native-reviewer-summary-pending"
lifecycle="dispatch-reviewersummarypending"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
assert_eq "post-pending death: dedicated publication itself succeeds" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}" "" "" 0 1)"
assert_eq "post-pending death: accepted outcome is already durable" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "post-pending death: pending consumed, waiter retained" "1" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"
with_state_lock_batch "unrelated_after_waiter_repair" "kept-too"
assert_eq "post-pending death: ordinary locked write persists" "kept-too" \
  "$(read_state "unrelated_after_waiter_repair")"
assert_eq "post-pending death: orphan waiter is retired" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "post-pending death: accepted outcome remains singular" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"

printf 'Incomplete reviewer summary claims fence prompts and recover by lease\n'
sid="reviewer-live-claim-prompt-fence"
native="native-reviewer-live-claim"
lifecycle="dispatch-reviewerliveclaim1234"
reset_session "${sid}"
write_state "current_objective" "Keep the settled reviewer objective"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "live claim: dedicated reviewer receipt is ready" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
live_claim_ready="${TEST_HOME}/reviewer-live-claim.ready"
live_claim_release="${TEST_HOME}/reviewer-live-claim.release"
live_claim_output="${TEST_HOME}/reviewer-live-claim.output"
review_payload "${sid}" "${native}" "${clean_message}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_TEST_SUMMARY_CLAIM_READY_FILE="${live_claim_ready}" \
    OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${live_claim_release}" \
    bash "${HOOK_DIR}/record-subagent-summary.sh" \
      >"${live_claim_output}" 2>&1 &
live_claim_pid=$!
for live_claim_wait in $(seq 1 500); do
  [[ -f "${live_claim_ready}" ]] && break
  sleep 0.02
done
assert_eq "live claim: summary reaches post-claim barrier" "1" \
  "$([[ -f "${live_claim_ready}" ]] && printf 1 || printf 0)"
assert_eq "live claim: reviewer-first path retains exact waiter" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "live claim: durable claim is effects-incomplete" "false" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
live_claim_prompt_revision="$(jq -r '.prompt_revision' \
  "${dir}/session_state.json")"
run_user_prompt "${sid}" \
  "Implement a newer objective while the old review callback is paused" \
  >/dev/null
assert_eq "live claim: racing prompt cannot advance revision" \
  "${live_claim_prompt_revision}" \
  "$(jq -r '.prompt_revision' "${dir}/session_state.json")"
assert_eq "live claim: racing prompt cannot replace objective" \
  "Keep the settled reviewer objective" \
  "$(jq -r '.current_objective' "${dir}/session_state.json")"
assert_eq "live claim: recovery probes publish no ignored outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
touch "${live_claim_release}"
wait "${live_claim_pid}"
assert_eq "live claim: exact owner finishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "live claim: exact owner publishes one accepted outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "live claim: pending and waiter settle after owner completes" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"
run_user_prompt "${sid}" \
  "Implement the newer objective after reviewer settlement" >/dev/null
assert_nonzero "live claim: newer prompt routes after settlement" \
  "$(( $(jq -r '.prompt_revision' "${dir}/session_state.json") \
      - live_claim_prompt_revision ))"

sid="reviewer-expired-incomplete-claim"
native="native-reviewer-expired-claim"
lifecycle="dispatch-reviewerexpiredclaim12"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "expired claim: dedicated reviewer receipt is ready" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
expired_claim_ready="${TEST_HOME}/reviewer-expired-claim.ready"
expired_claim_release="${TEST_HOME}/reviewer-expired-claim.release"
review_payload "${sid}" "${native}" "${clean_message}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_TEST_SUMMARY_CLAIM_READY_FILE="${expired_claim_ready}" \
    OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${expired_claim_release}" \
    bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 &
expired_claim_pid=$!
for expired_claim_wait in $(seq 1 500); do
  [[ -f "${expired_claim_ready}" ]] && break
  sleep 0.02
done
assert_eq "expired claim: summary reaches post-claim barrier" "1" \
  "$([[ -f "${expired_claim_ready}" ]] && printf 1 || printf 0)"
set +e
kill -KILL "${expired_claim_pid}" 2>/dev/null
wait "${expired_claim_pid}" 2>/dev/null
expired_claim_kill_rc=$?
set -e
assert_nonzero "expired claim: interrupted owner is observable" \
  "${expired_claim_kill_rc}"
expired_pending="${dir}/pending_agents.jsonl"
jq -c '.completion_claim_ts = 1' "${expired_pending}" \
  >"${expired_pending}.expired"
mv -f "${expired_pending}.expired" "${expired_pending}"
# Simulate death immediately after the first universal effect. Recovery must
# recognize the lifecycle-identical row and continue without duplicating it.
expired_digest="$(_omc_token_digest "${clean_message}")"
jq -nc --arg agent "quality-reviewer" --arg message "${clean_message}" \
  --arg lifecycle "${lifecycle}" --arg native "${native}" \
  --arg digest "${expired_digest}" '
    {ts:1,agent_type:$agent,message:$message,
     lifecycle_dispatch_id:$lifecycle,native_agent_id:$native,
     completion_digest:$digest}
  ' >"${dir}/subagent_summaries.jsonl"
assert_eq "expired claim: exact receipt-bound replay takes over" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "expired claim: partial summary effect remains singular" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "expired claim: recovered parent outcome is singular" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "expired claim: recovered parent outcome is accepted" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "expired claim: causal pending and waiter are settled" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"
assert_eq "expired claim: a second recovery is idempotent" "0" \
  "$(run_reviewer_recovery "${sid}")"
assert_eq "expired claim: replay never duplicates accepted artifacts" "2" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"

sid="expired-owner-rebind-fence"
native="native-expired-owner"
lifecycle="dispatch-expiredowner123456"
reset_session "${sid}"
write_state "current_objective" "Generation one objective"
seed_advisory_dispatch \
  "${sid}" "frontend-developer" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
expired_owner_ready="${TEST_HOME}/expired-owner.ready"
expired_owner_release="${TEST_HOME}/expired-owner.release"
jq -nc --arg sid "${sid}" --arg native "${native}" '
  {session_id:$sid,agent_type:"frontend-developer",agent_id:$native,
   last_assistant_message:"Old owner implementation.\nVERDICT: SHIP",
   stop_hook_active:false}
' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_SUMMARY_CLAIM_READY_FILE="${expired_owner_ready}" \
  OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${expired_owner_release}" \
  bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 &
expired_owner_pid=$!
for expired_owner_wait in $(seq 1 500); do
  [[ -f "${expired_owner_ready}" ]] && break
  sleep 0.02
done
assert_eq "expired owner: old summary reaches post-claim barrier" "1" \
  "$([[ -f "${expired_owner_ready}" ]] && printf 1 || printf 0)"
jq -c '.completion_claim_ts = 1' "${dir}/pending_agents.jsonl" \
  >"${dir}/pending_agents.expired.jsonl"
mv -f "${dir}/pending_agents.expired.jsonl" \
  "${dir}/pending_agents.jsonl"
expired_owner_rebind_out="$(run_agent_dispatch "${sid}" \
  "frontend-developer" \
  "[review-rebind:expired-owner-rebind] replace the expired owner")"
assert_not_contains "expired owner: explicit lease-expiry rebind is admitted" \
  '"permissionDecision":"deny"' "${expired_owner_rebind_out}"
assert_eq "expired owner: admission first replays the durable old claim" \
  "accepted" "$(jq -r '.status' \
    "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "expired owner: recovery publishes the old summary once" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "expired owner: recovered lifecycle no longer remains pending" "0" \
  "$(jq -s --arg lifecycle "${lifecycle}" \
    '[.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length' \
    "${dir}/pending_agents.jsonl")"
assert_eq "expired owner: replacement row is distinct and live" "1" \
  "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
    "${dir}/pending_agents.jsonl")"
jq '.ulw_enforcement_generation="2"
    | .review_cycle_id="2"
    | .review_cycle_prompt_ts="200"
    | .last_user_prompt_ts="200"
    | .prompt_revision="2"
    | .current_objective="Generation two objective"
    | .agent_first_specialist_ts=""
    | .agent_first_specialist_type=""' \
  "${dir}/session_state.json" >"${dir}/session_state.g2.json"
mv -f "${dir}/session_state.g2.json" "${dir}/session_state.json"
touch "${expired_owner_release}"
wait "${expired_owner_pid}"
assert_eq "expired owner: stale process duplicates no summary into G2" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "expired owner: stale process duplicates no outcome into G2" "1" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "expired owner: stale process cannot satisfy G2 agent-first" "" \
  "$(jq -r '.agent_first_specialist_ts // empty' "${dir}/session_state.json")"
assert_eq "expired owner: G2 objective survives old-owner release" \
  "Generation two objective" \
  "$(jq -r '.current_objective' "${dir}/session_state.json")"

sid="ordinary-summary-post-finalizer-death"
native="native-ordinary-summary-finalizer"
lifecycle="dispatch-ordinaryfinalizer123"
ordinary_message=$'Ordinary implementation completed.\nVERDICT: SHIP'
reset_session "${sid}"
seed_advisory_dispatch \
  "${sid}" "frontend-developer" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
set +e
jq -nc --arg sid "${sid}" --arg native "${native}" \
  --arg message "${ordinary_message}" '
    {session_id:$sid,agent_type:"frontend-developer",agent_id:$native,
     last_assistant_message:$message,stop_hook_active:false}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_TEST_SUMMARY_KILL_AFTER_FINALIZE=1 \
    bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
ordinary_finalize_rc=$?
set -e
assert_nonzero "ordinary finalizer split: process death is observable" \
  "${ordinary_finalize_rc}"
assert_eq "ordinary finalizer split: universal effects are singular" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "ordinary finalizer split: effects-complete recovery row remains" \
  "true" "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
assert_eq "ordinary finalizer split: accepted outcome is not fabricated" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
printf '%s\n' 'legacy-malformed-pending-noise' \
  >>"${dir}/pending_agents.jsonl"
ordinary_finalize_revision="$(jq -r '.prompt_revision' \
  "${dir}/session_state.json")"
ordinary_new_prompt="Route a newer objective only after repairing the old accepted outcome"
run_user_prompt "${sid}" "${ordinary_new_prompt}" >/dev/null
assert_eq "ordinary finalizer split: prompt barrier repairs outcome first" \
  "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "ordinary finalizer split: prompt recovery repeats no effects" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "ordinary finalizer split: prompt recovery settles exact row" "0" \
  "$(jq -Rsr '[split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")] | length' \
    "${dir}/pending_agents.jsonl")"
assert_eq "ordinary finalizer split: recovery preserves pending noise" "1" \
  "$(grep -Fxc 'legacy-malformed-pending-noise' \
    "${dir}/pending_agents.jsonl" || true)"
assert_eq "ordinary finalizer split: newer prompt routes after settlement" \
  "$((ordinary_finalize_revision + 1))" \
  "$(jq -r '.prompt_revision' "${dir}/session_state.json")"
assert_eq "ordinary finalizer split: recovered old claim cannot overwrite objective" \
  "${ordinary_new_prompt}" \
  "$(jq -r '.current_objective' "${dir}/session_state.json")"
run_advisory_summary \
  "${sid}" "frontend-developer" "${native}" "${ordinary_message}"
assert_eq "ordinary finalizer split: later duplicate remains idempotent" "2" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"

printf 'Ordinary summary effects: expired claims replay before prompt rotation\n'
ordinary_effect_boundaries="${OMC_TEST_EFFECT_BOUNDARIES:-council summary agent-first design scope background-waits uncertainty}"
ordinary_effect_index=0
export OMC_DISCOVERED_SCOPE=on
for ordinary_effect_boundary in ${ordinary_effect_boundaries}; do
  ordinary_effect_index=$((ordinary_effect_index + 1))
  sid="ordinary-effect-${ordinary_effect_index}"
  native="native-ordinary-effect-${ordinary_effect_index}"
  lifecycle="dispatch-ordinaryeffect${ordinary_effect_index}abcdefgh"
  ordinary_effect_agent="frontend-developer"
  ordinary_effect_message=$'Ordinary effect publication completed.\nVERDICT: SHIP'
  case "${ordinary_effect_boundary}" in
    design)
      ordinary_effect_message=$'## Design Contract\n### Direction\nA Stripe-inspired high-contrast utility surface with explicit hierarchy.\nVERDICT: SHIP'
      ;;
    scope|background-waits)
      ordinary_effect_message=$'Sibling behavior also requires coverage.\nFINDINGS_JSON: [{"severity":"medium","category":"completeness","file":"src/sibling.ts","line":12,"claim":"A sibling UI path also needs regression coverage","evidence":"The sibling branch lacks the recovered lifecycle assertion.","recommended_fix":"Add the same exact-lifecycle regression to the sibling path."}]\nVERDICT: SHIP'
      ;;
    uncertainty|council)
      ordinary_effect_agent="divergent-framer"
      ordinary_effect_message=$'Framing 1: event log.\nFraming 2: write-ahead journal.\nFraming 3: immutable generations.\nRank: Framing 2 best preserves causal recovery.\nVERDICT: FRAMINGS_READY (3)'
      ;;
  esac
  reset_session "${sid}"
  write_state "current_objective" \
    "Preserve the original objective until effect recovery settles"
  if [[ "${ordinary_effect_boundary}" == "uncertainty" ]]; then
    write_state "model_routing_uncertainty" "1"
  fi
  seed_advisory_dispatch "${sid}" "${ordinary_effect_agent}" \
    "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  if [[ "${ordinary_effect_boundary}" == "council" ]]; then
    jq -c '. + {
      purpose:"council",council_phase:"primary",
      council_objective_prompt_ts:100,
      council_objective_prompt_revision:1,
      council_ledger_generation:1,
      council_selection_agent:"divergent-framer"
    }' "${dir}/pending_agents.jsonl" \
      >"${dir}/pending_agents.council.jsonl"
    mv -f "${dir}/pending_agents.council.jsonl" \
      "${dir}/pending_agents.jsonl"
    jq -nc '{objective_prompt_ts:100,objective_prompt_revision:1,
      objective_cycle_id:1}' >"${dir}/council_coverage.json"
  fi
  ordinary_effect_rc="$(run_advisory_summary_effect_kill \
    "${sid}" "${ordinary_effect_agent}" "${native}" \
    "${ordinary_effect_message}" "${ordinary_effect_boundary}")"
  assert_eq "${ordinary_effect_boundary}: exact effect boundary kills the process" \
    "137" "${ordinary_effect_rc}"
  assert_eq "${ordinary_effect_boundary}: first summary effect is durable" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${ordinary_effect_boundary}: interrupted claim stays incomplete" \
    "false" "$(jq -r '.completion_claim_effects_complete // false' \
      "${dir}/pending_agents.jsonl")"
  assert_eq "${ordinary_effect_boundary}: no accepted outcome precedes recovery" \
    "0" "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  if [[ "${ordinary_effect_boundary}" == "design" ]]; then
    assert_contains "design: contract effect lands before the crash" \
      "Stripe-inspired" "$(cat "${dir}/design_contract.md" 2>/dev/null || true)"
  elif [[ "${ordinary_effect_boundary}" == "uncertainty" ]]; then
    assert_eq "uncertainty: deliberation effect lands before the crash" \
      "divergent-framer" \
      "$(jq -r '.model_uncertainty_deliberator_type // empty' \
        "${dir}/session_state.json")"
  elif [[ "${ordinary_effect_boundary}" == "council" ]]; then
    assert_eq "council: exact return lands before the crash" "1" \
      "$(jsonl_count "${dir}/council_returns.jsonl")"
  fi

  ordinary_effect_revision="$(jq -r '.prompt_revision' \
    "${dir}/session_state.json")"
  run_user_prompt "${sid}" \
    "Premature prompt must remain behind the fresh ${ordinary_effect_boundary} claim" \
    >/dev/null
  assert_eq "${ordinary_effect_boundary}: fresh claim fences prompt revision" \
    "${ordinary_effect_revision}" \
    "$(jq -r '.prompt_revision' "${dir}/session_state.json")"
  assert_eq "${ordinary_effect_boundary}: fresh claim fences objective" \
    "Preserve the original objective until effect recovery settles" \
    "$(jq -r '.current_objective' "${dir}/session_state.json")"

  jq -c '.completion_claim_ts = 1' "${dir}/pending_agents.jsonl" \
    >"${dir}/pending_agents.expired.jsonl"
  mv -f "${dir}/pending_agents.expired.jsonl" \
    "${dir}/pending_agents.jsonl"
  ordinary_effect_new_prompt="New objective after ${ordinary_effect_boundary} recovery"
  run_user_prompt "${sid}" "${ordinary_effect_new_prompt}" >/dev/null
  assert_eq "${ordinary_effect_boundary}: prompt-triggered replay accepts once" \
    "accepted" "$(jq -r '.status' \
      "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${ordinary_effect_boundary}: replay keeps summary singular" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${ordinary_effect_boundary}: replay settles exact claim" "0" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  assert_eq "${ordinary_effect_boundary}: prompt advances after recovery" \
    "$((ordinary_effect_revision + 1))" \
    "$(jq -r '.prompt_revision' "${dir}/session_state.json")"
  assert_eq "${ordinary_effect_boundary}: recovered callback cannot overwrite prompt" \
    "${ordinary_effect_new_prompt}" \
    "$(jq -r '.current_objective' "${dir}/session_state.json")"
  case "${ordinary_effect_boundary}" in
    design)
      assert_eq "design: replay dedupes cross-session archetype memory" "1" \
        "$(jq -s --arg sid "${sid}" \
          '[.[] | select(.session == $sid and .archetype == "Stripe")] | length' \
          "${TEST_HOME}/.claude/quality-pack/used-archetypes.jsonl" \
          2>/dev/null || printf 0)"
      ;;
    scope|background-waits)
      assert_eq "${ordinary_effect_boundary}: discovered scope is singular" \
        "1" "$(jsonl_count "${dir}/discovered_scope.jsonl")"
      ;;
    council)
      assert_eq "council: lifecycle return remains singular after replay" "1" \
        "$(jsonl_count "${dir}/council_returns.jsonl")"
      ;;
  esac
done
unset OMC_DISCOVERED_SCOPE

printf 'Prompt recovery: a newer objective cannot be rolled back or erase siblings\n'
sid="reviewer-router-newer-prompt"
native="native-reviewer-router-owner"
lifecycle="dispatch-reviewerrouterowner"
sibling_native="native-reviewer-router-sibling"
sibling_lifecycle="dispatch-reviewerroutersibling"
reset_session "${sid}"
write_state "current_objective" "Old objective before reviewer death"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "newer prompt: reviewer process death is observable" \
  "${kill_rc}"
sibling_row="$(jq -c \
  --arg native "${sibling_native}" --arg lifecycle "${sibling_lifecycle}" '
    .start_line | fromjson
    | .native_agent_id=$native
    | .lifecycle_dispatch_id=$lifecycle
    | .description="unrelated reviewer admitted during interrupted publication"
  ' "${dir}/.reviewer-transaction.wal/manifest.json" 2>/dev/null || true)"
assert_nonzero "newer prompt fixture: sibling row is generated" \
  "${#sibling_row}"
printf '%s\n' "${sibling_row}" >>"${dir}/pending_agents.jsonl"
printf '%s\n' "${sibling_row}" >>"${dir}/agent_dispatch_starts.jsonl"
jq -nc --arg native "${sibling_native}" --arg lifecycle "${sibling_lifecycle}" \
  '{native_agent_id:$native,agent_type:"quality-reviewer",
    review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
    objective_cycle_id:1,ts:100}' \
  >>"${dir}/native_agent_bindings.jsonl"
new_prompt="Implement the newer objective and preserve unrelated causal work"
run_user_prompt "${sid}" "${new_prompt}" >/dev/null
assert_eq "newer prompt: owner WAL is retired before routing" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "newer prompt: old reviewer receipt remains singular" "1" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "newer prompt: old reviewer history remains singular" "1" \
  "$(jsonl_count "${dir}/review_history.jsonl")"
assert_eq "newer prompt: routed objective wins after recovery" \
  "${new_prompt}" "$(jq -r '.current_objective // empty' \
    "${dir}/session_state.json")"
assert_eq "newer prompt: prompt revision advances after recovery" "2" \
  "$(jq -r '.prompt_revision // 0' "${dir}/session_state.json")"
sibling_rows="$(( $(jq -s --arg lifecycle "${sibling_lifecycle}" \
    '[.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length' \
    "${dir}/pending_agents.jsonl" 2>/dev/null || printf 0) \
  + $(jq -s --arg lifecycle "${sibling_lifecycle}" \
    '[.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length' \
    "${dir}/agent_dispatch_starts.jsonl" 2>/dev/null || printf 0) ))"
assert_nonzero "newer prompt: unrelated causal row is retained/tombstoned, not erased" \
  "${sibling_rows}"

printf 'Parallel callback recovery: sibling reviewer validates only settled state\n'
sid="reviewer-parallel-callback"
native="native-reviewer-parallel-owner"
lifecycle="dispatch-reviewerparallelowner"
sibling_native="native-reviewer-parallel-sibling"
sibling_lifecycle="dispatch-reviewerparallelsibling"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
owner_row="$(cat "${dir}/pending_agents.jsonl")"
owner_binding="$(cat "${dir}/native_agent_bindings.jsonl")"
seed_reviewer_dispatch \
  "${sid}" "${sibling_native}" "${sibling_lifecycle}"
sibling_row="$(cat "${dir}/pending_agents.jsonl")"
sibling_binding="$(cat "${dir}/native_agent_bindings.jsonl")"
printf '%s\n%s\n' "${owner_row}" "${sibling_row}" \
  >"${dir}/pending_agents.jsonl"
printf '%s\n%s\n' "${owner_row}" "${sibling_row}" \
  >"${dir}/agent_dispatch_starts.jsonl"
printf '%s\n%s\n' "${owner_binding}" "${sibling_binding}" \
  >"${dir}/native_agent_bindings.jsonl"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "parallel callback: owner process death is observable" \
  "${kill_rc}"
assert_eq "parallel callback: sibling recovers owner then commits itself" "0" \
  "$(run_reviewer "${sid}" "${sibling_native}" "${clean_message}")"
assert_eq "parallel callback: both dedicated receipts are singular" "2" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "parallel callback: both history rows are singular" "2" \
  "$(jsonl_count "${dir}/review_history.jsonl")"
assert_eq "parallel callback: fixed WAL is retired" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "parallel callback: both reviewer starts are consumed" "0" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
run_summary "${sid}" "${native}" "${clean_message}"
run_summary "${sid}" "${sibling_native}" "${clean_message}"
assert_eq "parallel callback: both universal summaries converge" "2" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "parallel callback: both pending rows converge" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

printf 'SessionStart recovery: stale compact/resume bytes never cross the boundary\n'
sid="reviewer-compact-recover"
native="native-reviewer-compact-recover"
lifecycle="dispatch-reviewercompactrecover"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
write_state "last_assistant_message" "PROVISIONAL-ASSISTANT-WAL-BYTES"
dir="${TEST_STATE_ROOT}/${sid}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "state_published")"
assert_nonzero "compact recovery: injected process death is observable" \
  "${kill_rc}"
printf '%s\n' 'PROVISIONAL-COMPACT-WAL-BYTES' >"${dir}/compact_handoff.md"
compact_out="$(run_compact_session_start "${sid}")"
assert_contains "compact recovery: bounded settled directive is emitted" \
  "pre-recovery compact manifest was deliberately omitted" "${compact_out}"
assert_not_contains "compact recovery: provisional manifest is never injected" \
  "PROVISIONAL-COMPACT-WAL-BYTES" "${compact_out}"
assert_eq "compact recovery: valid WAL is retired" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_nonzero "compact recovery: settled rehydrate clock is written" \
  "$(jq -r '.last_compact_rehydrate_ts // 0' "${dir}/session_state.json")"

sid="reviewer-compact-corrupt"
reset_session "${sid}"
dir="${TEST_STATE_ROOT}/${sid}"
mkdir "${dir}/.reviewer-transaction.wal"
printf '%s\n' 'PROVISIONAL-COMPACT-CORRUPT' >"${dir}/compact_handoff.md"
compact_out="$(run_compact_session_start "${sid}")"
assert_contains "compact corrupt: SessionStart fails closed" \
  "Compact continuation paused" "${compact_out}"
assert_not_contains "compact corrupt: stale manifest is never injected" \
  "PROVISIONAL-COMPACT-CORRUPT" "${compact_out}"
assert_eq "compact corrupt: invalid WAL remains for reset/repair" "1" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "compact corrupt: no rehydrate clock is fabricated" "0" \
  "$(jq -r '.last_compact_rehydrate_ts // 0' "${dir}/session_state.json")"

sid="reviewer-resume-recover"
native="native-reviewer-resume-recover"
lifecycle="dispatch-reviewerresumerecover"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
write_state "last_assistant_message" "PROVISIONAL-RESUME-WAL-BYTES"
dir="${TEST_STATE_ROOT}/${sid}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "history_published")"
assert_nonzero "resume recovery: injected process death is observable" \
  "${kill_rc}"
resume_out="$(run_resume_session_start "${sid}")"
assert_contains "resume recovery: bounded settled directive is emitted" \
  "publication transaction was recovered before this resume" "${resume_out}"
assert_not_contains "resume recovery: provisional assistant prose is omitted" \
  "PROVISIONAL-RESUME-WAL-BYTES" "${resume_out}"
assert_eq "resume recovery: valid WAL is retired" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"

sid="reviewer-resume-corrupt"
reset_session "${sid}"
dir="${TEST_STATE_ROOT}/${sid}"
mkdir "${dir}/.reviewer-transaction.wal"
resume_out="$(run_resume_session_start "${sid}")"
assert_contains "resume corrupt: SessionStart fails closed" \
  "Resume paused" "${resume_out}"
assert_eq "resume corrupt: invalid WAL remains for reset/repair" "1" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"

printf 'Reviewer WAL: migrated effects-complete pending consumption recovers\n'
sid="reviewer-wal-pending-consume"
native="native-reviewer-pending-consume"
lifecycle="dispatch-reviewerpendingconsume"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
pending_file="${dir}/pending_agents.jsonl"
pending_digest="$(_omc_token_digest "${clean_message}")"
jq -c --arg digest "${pending_digest}" --arg message "${clean_message}" '
  . + {completion_claim_id:"completion-migration-claim",
       completion_claim_ts:100,completion_claim_effects_complete:true,
       completion_claim_digest:$digest,completion_claim_message:$message}' \
  "${pending_file}" >"${pending_file}.tmp"
mv -f "${pending_file}.tmp" "${pending_file}"
pending_kill_rc="$(run_reviewer \
  "${sid}" "${native}" "${clean_message}" "pending_consumed")"
assert_nonzero "pending_consumed: injected process death is observable" \
  "${pending_kill_rc}"
assert_eq "pending_consumed: exact completed claim is consumed under WAL" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "pending_consumed: start remains until replay continues" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "pending_consumed: reviewer state is not yet advertised" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' "${dir}/session_state.json")"
assert_eq "pending_consumed: exact reviewer retry converges" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "pending_consumed: recovered verdict is authoritative" "CLEAN" \
  "$(jq -r '.dim_code_quality_verdict' "${dir}/session_state.json")"
assert_eq "pending_consumed: recovered receipt and history are singular" "2" \
  "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"
assert_eq "pending_consumed: WAL and start are retired" "0" \
  "$(( $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $([[ -e "${dir}/.reviewer-transaction.wal" ]] \
        && printf 1 || printf 0) ))"

printf 'Reviewer WAL: any sibling callback recovers before exact selection\n'
sid="reviewer-wal-continuation"
native="native-reviewer-wal-continuation"
lifecycle="dispatch-reviewerwalcontinuation"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
kill_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" \
  "wal_prepared")"
assert_nonzero "recovery continuation: fixture process death is observable" \
  "${kill_rc}"
parallel_native="native-reviewer-wal-parallel"
parallel_lifecycle="dispatch-reviewerwalparallel"
parallel_pending="$(jq -c \
  --arg native "${parallel_native}" --arg lifecycle "${parallel_lifecycle}" '
    .native_agent_id=$native | .lifecycle_dispatch_id=$lifecycle
  ' "${dir}/pending_agents.jsonl")"
printf '%s\n' "${parallel_pending}" >>"${dir}/pending_agents.jsonl"
printf '%s\n' "${parallel_pending}" >>"${dir}/agent_dispatch_starts.jsonl"
jq -nc --arg native "${parallel_native}" --arg lifecycle "${parallel_lifecycle}" '
  {native_agent_id:$native,agent_type:"quality-reviewer",
   review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
   objective_cycle_id:1,ts:100}
' >>"${dir}/native_agent_bindings.jsonl"
parallel_context="$(run_summary_output \
  "${sid}" "${parallel_native}" "${clean_message}" 1)"
assert_eq "immediate recovery: sibling emits no owner continuation" \
  "" "${parallel_context}"
assert_eq "immediate recovery: valid owner WAL is retired automatically" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "immediate recovery: owner receipt is singular" "1" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "immediate recovery: sibling waits on its own receipt" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "immediate recovery: sibling creates no retry sidecar" \
  "0" "$([[ -e "${dir}/.reviewer-transaction.wal/.summary-retry-count" ]] \
    && printf 1 || printf 0)"
owner_context="$(run_summary_output \
  "${sid}" "${native}" "${clean_message}" 1)"
assert_eq "immediate recovery: owner callback emits no continuation" \
  "" "${owner_context}"
assert_eq "immediate recovery: recovered owner publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "immediate recovery: sibling dedicated publication succeeds" "0" \
  "$(run_reviewer "${sid}" "${parallel_native}" "${clean_message}")"
assert_eq "immediate recovery: sibling waiter replay is exact" "2" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "immediate recovery: both accepted parent outcomes are singular" "2" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "immediate recovery: both reviewer history rows are singular" "2" \
  "$(jsonl_count "${dir}/review_history.jsonl")"
assert_eq "immediate recovery: only the newest live receipt is retained" "1" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "immediate recovery: all causal rows and waiters settle" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

# The universal hook's persistent-WAL continuation counter is an authority
# record, not an advisory integer. A raw NUL in an otherwise valid `0\n`
# record must not normalize through command substitution and spend the only
# native retry. Use the narrow receipt-bound replay entrypoint so the active
# WAL remains in place long enough to exercise that exact locked path.
sid="reviewer-summary-retry-count-nul"
native="native-reviewer-summary-retry-count-nul"
lifecycle="dispatch-reviewersummaryretrycountnul"
claim="completion-reviewer-summary-retry-count-nul"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_nonzero "retry-count NUL: valid reviewer WAL fixture is durable" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}" wal_prepared)"
completion_digest="$(_omc_token_digest "${clean_message}")"
jq -c \
  --arg claim "${claim}" \
  --arg message "${clean_message}" \
  --arg digest "${completion_digest}" \
  --argjson ts "$(date +%s)" '
    . + {completion_claim_id:$claim,completion_claim_ts:$ts,
         completion_claim_effects_complete:false,
         completion_claim_message:$message,
         completion_claim_digest:$digest}
  ' "${dir}/pending_agents.jsonl" \
  >"${dir}/pending_agents.jsonl.tmp"
mv -f "${dir}/pending_agents.jsonl.tmp" \
  "${dir}/pending_agents.jsonl"
retry_count_file="${dir}/.reviewer-transaction.wal/.summary-retry-count"
{
  printf '0'
  printf '\0\n'
} >"${retry_count_file}"
retry_count_before="$(cksum <"${retry_count_file}")"
retry_count_context="$(run_summary_output \
  "${sid}" "${native}" "${clean_message}" 1 "${claim}")"
assert_eq "retry-count NUL: malformed counter grants no continuation" "" \
  "${retry_count_context}"
assert_eq "retry-count NUL: malformed counter remains byte-identical" \
  "${retry_count_before}" \
  "$([[ -f "${retry_count_file}" ]] \
    && cksum <"${retry_count_file}" || printf absent)"
assert_eq "retry-count NUL: fixed WAL remains for explicit recovery" "1" \
  "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "retry-count NUL: no universal effect or outcome is published" "0" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"

printf 'Excellence authority: fabricated receipt references in both hook orders\n'
sid="excellence-contract-build"
reset_session "${sid}"
write_state "quality_constitution_status" "disabled"
_omc_load_quality_contract
quality_contract="$(build_quality_contract)"
quality_review="$(quality_review_json "${quality_contract}")"
quality_message="$(quality_review_message "${quality_review}")"
fabricated_review="$(jq -c '
  (.criteria[] | select(.id == "Q-001") | .refs) = ["vr-fabricated-001"]
' <<<"${quality_review}")"
fabricated_message="$(quality_review_message "${fabricated_review}")"

printf 'Excellence prepare staging: every loose pre-WAL artifact is reaped\n'
sid="excellence-prepare-death"
native="native-excellence-prepare-death"
lifecycle="dispatch-excellencepreparedeath"
reset_quality_session "${sid}" "${quality_contract}"
write_quality_receipts "${quality_contract}"
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
run_excellence_summary "${sid}" "${native}" "${quality_message}"
quality_kill_rc="$(run_excellence \
  "${sid}" "${native}" "${quality_message}" "prepare_complete")"
assert_nonzero "excellence prepare death: injected process death is observable" \
  "${quality_kill_rc}"
assert_eq "excellence prepare death: fixed WAL was not published" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" \
      || -L "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "excellence prepare death: four loose stages survive" "4" \
  "$(reviewer_loose_stage_count "${dir}")"
assert_eq "excellence prepare death: canonical quality artifacts remain absent" \
  "0" "$(( $([[ -e "${dir}/quality_evidence.jsonl" ]] \
                  && printf 1 || printf 0) \
             + $([[ -e "${dir}/quality_frontier.json" ]] \
                  && printf 1 || printf 0) \
             + $([[ -e "${dir}/quality_frontier_history.jsonl" ]] \
                  && printf 1 || printf 0) ))"
assert_eq "excellence prepare death: reviewer receipt remains absent" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "excellence prepare death: exact reviewer retry converges" "0" \
  "$(run_excellence "${sid}" "${native}" "${quality_message}")"
assert_eq "excellence prepare death: all loose stages are retired" "0" \
  "$(reviewer_loose_stage_count "${dir}")"
assert_eq "excellence prepare death: evidence and frontier history publish once" \
  "6" "$(( $(jsonl_count "${dir}/quality_evidence.jsonl") \
            + $(jsonl_count "${dir}/quality_frontier_history.jsonl") ))"
assert_eq "excellence prepare death: receipt, history, summary, and outcome converge once" \
  "4" "$(( $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
            + $(jsonl_count "${dir}/review_history.jsonl") \
            + $(jsonl_count "${dir}/subagent_summaries.jsonl") \
            + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"

printf 'Reviewer loose staging: non-regular exact candidates fail closed\n'
sid="reviewer-loose-stage-symlink"
reset_session "${sid}"
dir="${TEST_STATE_ROOT}/${sid}"
loose_stage_target="${TEST_HOME}/reviewer-loose-stage-target"
printf 'external-stage-bytes\n' >"${loose_stage_target}"
ln -s "${loose_stage_target}" \
  "${dir}/quality_frontier.json.tmp.ABC123"
loose_stage_rc="$(run_reviewer_recovery "${sid}")"
assert_nonzero "loose stage symlink: recovery fails closed" \
  "${loose_stage_rc}"
assert_eq "loose stage symlink: exact node is preserved" \
  "symlink:${loose_stage_target}" \
  "$(artifact_byte_identity "${dir}/quality_frontier.json.tmp.ABC123")"
assert_eq "loose stage symlink: external target is untouched" \
  "external-stage-bytes" "$(<"${loose_stage_target}")"
rm -f -- "${dir}/quality_frontier.json.tmp.ABC123"

printf 'Excellence authority: verification threshold is frozen at contract time\n'
assert_eq "frozen threshold: default contract captures threshold 40" "40" \
  "$(jq -r '.verification_threshold' <<<"${quality_contract}")"
sid="excellence-threshold-live-raised"
native="native-excellence-threshold-raised"
lifecycle="dispatch-excellencethresholdraised"
reset_quality_session "${sid}" "${quality_contract}"
write_quality_receipts "${quality_contract}"
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "frozen threshold: raising live env cannot reject frozen-valid proof" \
  "0" "$(run_excellence \
    "${sid}" "${native}" "${quality_message}" "" "95")"
assert_eq "frozen threshold: raised live env publishes complete evidence" "5" \
  "$(jsonl_count "${dir}/quality_evidence.jsonl")"
assert_eq "frozen threshold: raised live env publishes accepted receipt" \
  "accepted" "$(jq -r '.status' \
    "${dir}/reviewer_publication_outcomes.jsonl")"

high_threshold_contract="$(OMC_VERIFY_CONFIDENCE_THRESHOLD=70 \
  build_quality_contract)"
high_threshold_review_60="$(quality_review_json \
  "${high_threshold_contract}" 60)"
high_threshold_message_60="$(quality_review_message \
  "${high_threshold_review_60}")"
high_threshold_review_70="$(quality_review_json \
  "${high_threshold_contract}" 70)"
high_threshold_message_70="$(quality_review_message \
  "${high_threshold_review_70}")"
assert_eq "frozen threshold: high contract captures threshold 70" "70" \
  "$(jq -r '.verification_threshold' <<<"${high_threshold_contract}")"
sid="excellence-threshold-live-lowered"
native="native-excellence-threshold-lowered"
lifecycle="dispatch-excellencethresholdlowered"
reset_quality_session "${sid}" "${high_threshold_contract}"
write_quality_receipts "${high_threshold_contract}" 60
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${high_threshold_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "frozen threshold: lowering live env retains below-frozen proof" \
  "0" "$(run_excellence \
    "${sid}" "${native}" "${high_threshold_message_60}" "" "1")"
assert_eq "frozen threshold: below-frozen proof publishes no evidence" "0" \
  "$(jsonl_count "${dir}/quality_evidence.jsonl")"
assert_eq "frozen threshold: below-frozen proof publishes no receipt" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "frozen threshold: rejected proof retains exact causal pair" "2" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") ))"
write_quality_receipts "${high_threshold_contract}" 70
assert_eq "frozen threshold: threshold-satisfying retry commits" "0" \
  "$(run_excellence \
    "${sid}" "${native}" "${high_threshold_message_70}" "" "1")"
assert_eq "frozen threshold: corrected retry publishes complete evidence" "5" \
  "$(jsonl_count "${dir}/quality_evidence.jsonl")"

sid="excellence-fabricated-summary-first"
native="native-excellence-fabricated-summary"
lifecycle="dispatch-excellencefabricated1"
reset_quality_session "${sid}" "${quality_contract}"
write_quality_receipts "${quality_contract}"
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "quality fixture: frozen contract validates" "true" \
  "$(quality_contract_validate_current >/dev/null 2>&1 \
    && printf true || printf false)"
assert_eq "quality fixture: fabricated reference is structurally review-valid" \
  "true" "$(quality_review_validate_against_contract \
    "${fabricated_review}" "${quality_contract}" "VERDICT: SHIP" \
    >/dev/null 2>&1 && printf true || printf false)"
run_excellence_summary "${sid}" "${native}" "${fabricated_message}"
assert_eq "fabricated summary-first: suppression waits on reviewer receipt" \
  "reviewer-publication-pending" "$(jq -rs '
    [ .[] | select(.gate == "subagent-summary"
      and .event == "stale-result-ignored") ][-1].details.reason // ""
  ' "${dir}/gate_events.jsonl" 2>/dev/null || true)"
assert_eq "fabricated summary-first: provisional waiter is singular" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "fabricated summary-first: dedicated rejection retains call" "0" \
  "$(run_excellence "${sid}" "${native}" "${fabricated_message}")"
assert_eq "fabricated summary-first: no reviewer receipt is forged" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "fabricated summary-first: no quality evidence is accepted" "0" \
  "$(jsonl_count "${dir}/quality_evidence.jsonl")"
assert_eq "fabricated summary-first: no frontier is accepted" "0" \
  "$([[ -e "${dir}/quality_frontier.json" ]] && printf 1 || printf 0)"
assert_eq "fabricated summary-first: no universal effects are accepted" "0" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
assert_eq "fabricated summary-first: both causal rows remain" "2" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") ))"
run_excellence_summary "${sid}" "${native}" "${quality_message}"
assert_eq "fabricated summary-first: corrected waiter replaces old digest" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "fabricated summary-first: corrected reviewer commits" "0" \
  "$(run_excellence "${sid}" "${native}" "${quality_message}")"
assert_eq "fabricated summary-first: corrected proof publishes all criteria" \
  "5" "$(jsonl_count "${dir}/quality_evidence.jsonl")"
assert_eq "fabricated summary-first: corrected pair publishes one summary" \
  "1" "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "fabricated summary-first: corrected pair settles waiter" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"

sid="excellence-fabricated-reviewer-first"
native="native-excellence-fabricated-reviewer"
lifecycle="dispatch-excellencefabricated2"
reset_quality_session "${sid}" "${quality_contract}"
write_quality_receipts "${quality_contract}"
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "fabricated reviewer-first: dedicated hook retains call" "0" \
  "$(run_excellence "${sid}" "${native}" "${fabricated_message}")"
run_excellence_summary "${sid}" "${native}" "${fabricated_message}"
assert_eq "fabricated reviewer-first: no quality evidence is accepted" "0" \
  "$(jsonl_count "${dir}/quality_evidence.jsonl")"
assert_eq "fabricated reviewer-first: no universal effects are accepted" "0" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
assert_eq "fabricated reviewer-first: summary waits durably" "1" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "fabricated reviewer-first: corrected reviewer commits" "0" \
  "$(run_excellence "${sid}" "${native}" "${quality_message}")"
run_excellence_summary "${sid}" "${native}" "${quality_message}"
assert_eq "fabricated reviewer-first: corrected exact pair publishes summary" \
  "1" "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "fabricated reviewer-first: corrected pair settles waiter" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"

printf 'Excellence history: unreadable bounded tail fails closed\n'
sid="excellence-history-tail-fault"
native="native-excellence-history-tail-fault"
lifecycle="dispatch-excellencehistorytailfault"
reset_quality_session "${sid}" "${quality_contract}"
write_quality_receipts "${quality_contract}"
seed_excellence_dispatch \
  "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
dir="${TEST_STATE_ROOT}/${sid}"
: >"${dir}/quality_frontier_history.jsonl"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
start_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
history_tail_rc="$(run_excellence \
  "${sid}" "${native}" "${quality_message}" "" "" 1)"
assert_nonzero "frontier history tail: read failure propagates" \
  "${history_tail_rc}"
assert_eq "frontier history tail: reviewer state is byte-identical" \
  "${state_before}" "$(<"${dir}/session_state.json")"
assert_eq "frontier history tail: pending authority is byte-identical" \
  "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
assert_eq "frontier history tail: start authority is byte-identical" \
  "${start_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "frontier history tail: source ledger is not truncated" "0" \
  "$(wc -c <"${dir}/quality_frontier_history.jsonl" | tr -d '[:space:]')"
assert_eq "frontier history tail: no quality publication escapes" "0" \
  "$(( $(jsonl_count "${dir}/quality_evidence.jsonl") \
      + $(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl") \
      + $(jsonl_count "${dir}/review_history.jsonl") ))"
assert_eq "frontier history tail: no fixed or inert WAL is published" "0" \
  "$(( $([[ -e "${dir}/.reviewer-transaction.wal" \
            || -L "${dir}/.reviewer-transaction.wal" ]] \
          && printf 1 || printf 0) \
      + $(find "${dir}" -maxdepth 1 -type d \
          -name '.reviewer-transaction.committed.*' | wc -l | tr -d ' ') ))"

for history_invalid_shape in malformed missing-final-newline; do
  sid="excellence-history-${history_invalid_shape}"
  native="native-excellence-history-${history_invalid_shape}"
  lifecycle="dispatch-excellencehistory${history_invalid_shape//-/}1234"
  reset_quality_session "${sid}" "${quality_contract}"
  write_quality_receipts "${quality_contract}"
  dir="${TEST_STATE_ROOT}/${sid}"
  if [[ "${history_invalid_shape}" == "missing-final-newline" ]]; then
    seed_excellence_dispatch \
      "${sid}" "${native}-seed" "${lifecycle}-seed" "${quality_contract}"
    assert_eq "frontier history seed publishes" "0" \
      "$(run_excellence "${sid}" "${native}-seed" "${quality_message}")"
    history_without_newline="$(<"${dir}/quality_frontier_history.jsonl")"
    printf '%s' "${history_without_newline}" \
      >"${dir}/quality_frontier_history.jsonl"
  else
    printf '%s\n' '{"malformed_frontier_history":true}' \
      >"${dir}/quality_frontier_history.jsonl"
  fi
  seed_excellence_dispatch \
    "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
  invalid_history_state_before="$(<"${dir}/session_state.json")"
  invalid_history_pending_before="$(<"${dir}/pending_agents.jsonl")"
  invalid_history_start_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  invalid_history_source_before="$(shasum -a 256 \
    "${dir}/quality_frontier_history.jsonl" | awk '{print $1}')"
  invalid_history_receipts_before="$(jsonl_count \
    "${dir}/reviewer_publication_outcomes.jsonl")"
  invalid_history_evidence_before="$(artifact_byte_identity \
    "${dir}/quality_evidence.jsonl")"
  invalid_history_frontier_before="$(artifact_byte_identity \
    "${dir}/quality_frontier.json")"
  invalid_history_rc="$(run_excellence \
    "${sid}" "${native}" "${quality_message}")"
  assert_nonzero "frontier history ${history_invalid_shape}: publication fails closed" \
    "${invalid_history_rc}"
  assert_eq "frontier history ${history_invalid_shape}: state remains exact" \
    "${invalid_history_state_before}" "$(<"${dir}/session_state.json")"
  assert_eq "frontier history ${history_invalid_shape}: pending remains exact" \
    "${invalid_history_pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "frontier history ${history_invalid_shape}: start remains exact" \
    "${invalid_history_start_before}" \
    "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "frontier history ${history_invalid_shape}: source bytes remain exact" \
    "${invalid_history_source_before}" \
    "$(shasum -a 256 "${dir}/quality_frontier_history.jsonl" | awk '{print $1}')"
  assert_eq "frontier history ${history_invalid_shape}: no receipt escapes" \
    "${invalid_history_receipts_before}" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
  assert_eq "frontier history ${history_invalid_shape}: evidence remains exact" \
    "${invalid_history_evidence_before}" \
    "$(artifact_byte_identity "${dir}/quality_evidence.jsonl")"
  assert_eq "frontier history ${history_invalid_shape}: frontier remains exact" \
    "${invalid_history_frontier_before}" \
    "$(artifact_byte_identity "${dir}/quality_frontier.json")"
  assert_eq "frontier history ${history_invalid_shape}: no WAL residue escapes" \
    "0" \
    "$(find "${dir}" -maxdepth 1 \
      \( -name '.reviewer-transaction.wal' \
         -o -name '.reviewer-transaction.prepare.*' \
         -o -name '.reviewer-transaction.committed.*' \) \
      | wc -l | tr -d '[:space:]')"
done

printf 'Excellence WAL: every provisional quality artifact fails closed\n'
quality_boundaries='evidence_published frontier_published frontier_history_published'
quality_index=0
for boundary in ${quality_boundaries}; do
  quality_index=$((quality_index + 1))
  sid="excellence-wal-${quality_index}"
  native="native-excellence-wal-${quality_index}"
  lifecycle="dispatch-excellencewal${quality_index}abcdefgh"
  reset_quality_session "${sid}" "${quality_contract}"
  write_quality_receipts "${quality_contract}"
  seed_excellence_dispatch \
    "${sid}" "${native}" "${lifecycle}" "${quality_contract}"
  dir="${TEST_STATE_ROOT}/${sid}"
  run_excellence_summary "${sid}" "${native}" "${quality_message}"
  quality_kill_rc="$(run_excellence \
    "${sid}" "${native}" "${quality_message}" "${boundary}")"
  assert_nonzero "${boundary}: excellence process death is observable" \
    "${quality_kill_rc}"
  gate_json="$(quality_contract_gate_status_json 2>/dev/null || true)"
  assert_eq "${boundary}: provisional artifacts cannot certify Stop" \
    "reviewer_publication_pending" "$(jq -r '.status' <<<"${gate_json}")"
  assert_eq "${boundary}: reviewer commit receipt remains absent" "0" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
  assert_eq "${boundary}: provisional artifacts publish no universal effects" \
    "0" "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
  assert_eq "${boundary}: exact reviewer retry converges" "0" \
    "$(run_excellence "${sid}" "${native}" "${quality_message}")"
  assert_eq "${boundary}: recovered evidence set is complete" "5" \
    "$(jsonl_count "${dir}/quality_evidence.jsonl")"
  assert_eq "${boundary}: recovered history is singular" "1" \
    "$(jsonl_count "${dir}/quality_frontier_history.jsonl")"
  assert_eq "${boundary}: recovered universal summary is singular" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  gate_json="$(quality_contract_gate_status_json 2>/dev/null || true)"
  assert_eq "${boundary}: recovered Definition passes" "pass" \
    "$(jq -r '.status' <<<"${gate_json}")"
done

printf 'Reviewer WAL: deterministic failures and corrupt authority fail closed\n'
for boundary in wal_prepared state_published; do
  sid="reviewer-fail-${boundary}"
  native="native-reviewer-fail-${boundary}"
  lifecycle="dispatch-reviewerfail${boundary}1234"
  reset_session "${sid}"
  seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  fail_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}" '' \
    "${boundary}")"
  assert_nonzero "${boundary}: injected returned failure propagates" \
    "${fail_rc}"
  assert_eq "${boundary}: returned failure leaves recovery authority" "1" \
    "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
  assert_eq "${boundary}: healthy retry converges" "0" \
    "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
  run_summary "${sid}" "${native}" "${clean_message}"
  assert_eq "${boundary}: retry publishes one accepted summary" "1" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
done

sid="reviewer-corrupt-wal"
native="native-reviewer-corrupt"
lifecycle="dispatch-reviewercorrupt1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
start_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
mkdir "${dir}/.reviewer-transaction.wal"
printf '{"_v":999}\n' >"${dir}/.reviewer-transaction.wal/manifest.json"
corrupt_summary="$(run_summary_output \
  "${sid}" "${native}" "${clean_message}" 1)"
assert_eq "corrupt WAL returns no unbounded continuation" "" \
  "${corrupt_summary}"
assert_eq "corrupt WAL creates no reviewer waiter" "0" \
  "$(jsonl_count "${dir}/reviewer_summary_waiters.jsonl")"
assert_eq "corrupt WAL creates no universal side effects" "0" \
  "$(( $(jsonl_count "${dir}/subagent_summaries.jsonl") \
      + $(jsonl_count "${dir}/agent_completion_outcomes.jsonl") ))"
corrupt_rc="$(run_reviewer_recovery "${sid}")"
assert_nonzero "corrupt WAL refuses recovery" "${corrupt_rc}"
assert_eq "corrupt WAL preserves state bytes" "${state_before}" \
  "$(<"${dir}/session_state.json")"
assert_eq "corrupt WAL preserves pending bytes" "${pending_before}" \
  "$(<"${dir}/pending_agents.jsonl")"
assert_eq "corrupt WAL preserves start bytes" "${start_before}" \
  "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "corrupt WAL publishes no reviewer receipt" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

# Persisted WAL strings are projected through jq -r during recovery. Decoded
# NUL and trailing control framing must be rejected before Bash can normalize
# them into the exact causal row captured by the transaction.
for wal_string_case in start-line-nul start-line-newline; do
  sid="reviewer-wal-byte-${wal_string_case}"
  native="native-reviewer-wal-byte-${wal_string_case}"
  lifecycle="dispatch-reviewerwalbyte${wal_string_case//-/}"
  reset_session "${sid}"
  seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
  dir="${TEST_STATE_ROOT}/${sid}"
  assert_nonzero "${wal_string_case}: prepared WAL injection returns failure" \
    "$(run_reviewer "${sid}" "${native}" "${clean_message}" '' wal_prepared)"
  manifest="${dir}/.reviewer-transaction.wal/manifest.json"
  case "${wal_string_case}" in
    start-line-nul)
      jq '.start_line += "\u0000"' "${manifest}" >"${manifest}.tmp"
      ;;
    start-line-newline)
      jq '.start_line += "\n"' "${manifest}" >"${manifest}.tmp"
      ;;
  esac
  mv -f "${manifest}.tmp" "${manifest}"
  state_before="$(<"${dir}/session_state.json")"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  start_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  corrupt_rc="$(run_reviewer_recovery "${sid}")"
  assert_nonzero "${wal_string_case}: normalized WAL string is rejected" \
    "${corrupt_rc}"
  assert_eq "${wal_string_case}: state remains byte-identical" \
    "${state_before}" "$(<"${dir}/session_state.json")"
  assert_eq "${wal_string_case}: pending remains byte-identical" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${wal_string_case}: start remains byte-identical" \
    "${start_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${wal_string_case}: fixed WAL remains fail-closed" "1" \
    "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
  assert_eq "${wal_string_case}: no reviewer receipt is published" "0" \
    "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
done

# Live causal ledgers are independently hostile bytes at WAL replay time. A
# raw NUL appended to an otherwise exact start row used to disappear in Bash's
# read loop and authorize consumption of the normalized row.
sid="reviewer-wal-live-start-nul"
native="native-reviewer-wal-live-start-nul"
lifecycle="dispatch-reviewerwallivestartnul"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_nonzero "live start NUL: prepared WAL injection returns failure" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}" '' wal_prepared)"
start_line="$(<"${dir}/agent_dispatch_starts.jsonl")"
{
  printf '%s' "${start_line}"
  printf '\0\n'
} >"${dir}/agent_dispatch_starts.jsonl"
live_start_before="$(cksum <"${dir}/agent_dispatch_starts.jsonl")"
live_start_rc="$(run_reviewer_recovery "${sid}")"
assert_nonzero "live start NUL: causal ledger is rejected" "${live_start_rc}"
assert_eq "live start NUL: malformed ledger remains byte-identical" \
  "${live_start_before}" "$(cksum <"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "live start NUL: WAL remains for explicit repair" "1" \
  "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "live start NUL: no reviewer receipt is published" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

# Review-history idempotence is also lifecycle authority. A malformed
# canonical-looking history row cannot stand in for the WAL's exact append.
sid="reviewer-wal-live-history-nul"
native="native-reviewer-wal-live-history-nul"
lifecycle="dispatch-reviewerwallivehistorynul"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_nonzero "live history NUL: state boundary injection returns failure" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}" '' state_published)"
history_line="$(jq -r '.history_line' \
  "${dir}/.reviewer-transaction.wal/manifest.json")"
{
  printf '%s' "${history_line}"
  printf '\0\n'
} >"${dir}/review_history.jsonl"
live_history_before="$(cksum <"${dir}/review_history.jsonl")"
live_history_rc="$(run_reviewer_recovery "${sid}")"
assert_nonzero "live history NUL: idempotence ledger is rejected" \
  "${live_history_rc}"
assert_eq "live history NUL: malformed history remains byte-identical" \
  "${live_history_before}" "$(cksum <"${dir}/review_history.jsonl")"
assert_eq "live history NUL: WAL remains for explicit repair" "1" \
  "$([[ -d "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "live history NUL: no reviewer receipt is published" "0" \
  "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"

sid="reviewer-ambiguous-start"
native="native-reviewer-ambiguous"
lifecycle="dispatch-reviewerambiguous1"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' "$(<"${dir}/agent_dispatch_starts.jsonl")" \
  >>"${dir}/agent_dispatch_starts.jsonl"
ambiguous_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
ambiguous_rc="$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_nonzero "ambiguous lifecycle refuses first-match selection" \
  "${ambiguous_rc}"
assert_eq "ambiguous lifecycle preserves exact ledger" "${ambiguous_before}" \
  "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "ambiguous lifecycle publishes no verdict" "" \
  "$(jq -r '.dim_code_quality_verdict // empty' "${dir}/session_state.json")"

printf 'Reviewer receipts: protected orphan pair does not fence a sibling\n'
sid="reviewer-receipt-waiter-lock-race"
native="native-reviewer-receipt-waiter-race"
lifecycle="dispatch-reviewerreceiptwaiterrace"
old_lifecycle="dispatch-reviewerreceiptwaiterold"
# Empty native IDs remain valid only for pre-native migration waiters. Protect
# that compatibility receipt as well as current native-bound authority.
old_native=""
old_digest="$(_omc_token_digest "old reviewer summary")"
reset_session "${sid}" 0
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}" 0
dir="${TEST_STATE_ROOT}/${sid}"
jq -nc --arg lifecycle "${old_lifecycle}" --arg native "${old_native}" \
    --arg digest "${old_digest}" --arg message "old reviewer summary" '
  {schema_version:1,created_at:100,lifecycle_dispatch_id:$lifecycle,
   agent_type:"quality-reviewer",native_agent_id:$native,
   completion_digest:$digest,message:$message}
' >"${dir}/reviewer_summary_waiters.jsonl"
jq -nc --arg lifecycle "${old_lifecycle}" --arg native "${old_native}" \
    --arg digest "${old_digest}" '
  {schema_version:1,decided_at:100,lifecycle_dispatch_id:$lifecycle,
   agent_type:"quality-reviewer",reviewer_type:"standard",
   native_agent_id:$native,completion_digest:$digest,status:"accepted",
   reason:"",verdict:"CLEAN",start_review_revision:0,
   result_review_revision:0}
' >"${dir}/reviewer_publication_outcomes.jsonl"
assert_eq "protected orphan pair: sibling reviewer publication succeeds" "0" \
  "$(run_reviewer_with_protected_receipt_pair \
    "${sid}" "${native}" "${clean_message}")"
assert_eq "protected orphan pair: old and current reviewer receipts remain" \
  "2" "$(jsonl_count "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "protected orphan pair: old reviewer receipt remains protected" "1" \
  "$(jq -s --arg lifecycle "${old_lifecycle}" '
      [.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length
    ' "${dir}/reviewer_publication_outcomes.jsonl")"

printf 'Reviewer/summary rendezvous: rejection and digest mismatch\n'
sid="reviewer-rejected-summary-first"
native="native-reviewer-rejected"
lifecycle="dispatch-reviewerrejected12"
reset_session "${sid}" 0
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}" 0
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${clean_message}"
write_state "last_code_edit_revision" "1"
write_state "edit_revision" "1"
assert_eq "rejected summary-first reviewer is handled" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
assert_eq "rejected receipt names generation change" \
  "review_generation_changed" \
  "$(jq -r '.reason' "${dir}/reviewer_publication_outcomes.jsonl")"
assert_eq "rejected reviewer creates no universal summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "rejected reviewer creates cleanup-only outcome" "ignored" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "rejected reviewer settles causal rows and waiter" "0" \
  "$(( $(jsonl_count "${dir}/pending_agents.jsonl") \
      + $(jsonl_count "${dir}/agent_dispatch_starts.jsonl") \
      + $(jsonl_count "${dir}/reviewer_summary_waiters.jsonl") ))"

sid="reviewer-digest-mismatch"
native="native-reviewer-digest"
lifecycle="dispatch-reviewerdigest1234"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "digest fixture reviewer publishes" "0" \
  "$(run_reviewer "${sid}" "${native}" "${clean_message}")"
forged_message=$'A different clean transcript.\nVERDICT: CLEAN'
run_summary "${sid}" "${native}" "${forged_message}"
assert_eq "different transcript cannot reuse reviewer receipt" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "digest mismatch publishes no misleading outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "digest mismatch preserves pending for exact replay" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
run_summary "${sid}" "${native}" "${clean_message}"
assert_eq "exact transcript can still consume pending" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"

printf '/ulw-off: reviewer authority and recovery sentinels are removed\n'
sid="reviewer-deactivate"
native="native-reviewer-deactivate"
lifecycle="dispatch-reviewerdeactivate1"
reset_session "${sid}"
seed_reviewer_dispatch "${sid}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
printf '{"schema_version":1}\n' >"${dir}/reviewer_summary_waiters.jsonl"
printf '{"schema_version":1}\n' >"${dir}/reviewer_publication_outcomes.jsonl"
mkdir "${dir}/.reviewer-transaction.wal" \
  "${dir}/.reviewer-transaction.prepare.interrupted"
printf '{}\n' >"${dir}/.reviewer-transaction.wal/manifest.json"
printf '{}\n' >"${dir}/.reviewer-transaction.prepare.interrupted/staged"
deactivate_stage_target="${TEST_HOME}/reviewer-deactivate-stage-target"
printf 'external-deactivate-stage\n' >"${deactivate_stage_target}"
printf 'receipt-stage\n' >"${dir}/.reviewer-publication.stage.ABC123"
printf 'evidence-stage\n' >"${dir}/quality_evidence.jsonl.tmp.DEF456"
ln -s "${deactivate_stage_target}" \
  "${dir}/quality_frontier.json.tmp.GHI789"
printf 'history-stage\n' \
  >"${dir}/quality_frontier_history.jsonl.tmp.JKL012"
assert_eq "/ulw-off: all loose reviewer stage shapes are present" "4" \
  "$(reviewer_loose_stage_count "${dir}")"
managed_off_command='bash ~/.claude/skills/autowork/scripts/ulw-deactivate.sh "${CLAUDE_SESSION_ID}"'
near_miss_out="$(jq -nc --arg sid "${sid}" \
    --arg command "${managed_off_command}; true" '
      {session_id:$sid,tool_name:"Bash",tool_input:{command:$command}}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/pretool-intent-guard.sh" 2>/dev/null || true)"
assert_contains "/ulw-off: compound near-match remains denied by corrupt WAL" \
  '"permissionDecision":"deny"' "${near_miss_out}"
managed_off_pretool_out="$(jq -nc --arg sid "${sid}" \
    --arg command "${managed_off_command}" '
      {session_id:$sid,tool_name:"Bash",tool_input:{command:$command}}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/pretool-intent-guard.sh" 2>/dev/null || true)"
assert_eq "/ulw-off: exact managed command passes PreTool corrupt-WAL barrier" \
  "" "${managed_off_pretool_out}"
set +e
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  CLAUDE_SESSION_ID="${sid}" \
  bash "${TEST_HOME}/.claude/skills/autowork/scripts/ulw-deactivate.sh" \
    "${sid}" >/dev/null 2>&1
deactivate_rc=$?
set -e
assert_eq "deactivation succeeds with reviewer transaction artifacts" "0" \
  "${deactivate_rc}"
assert_eq "deactivation removes reviewer waiter" "0" \
  "$([[ -e "${dir}/reviewer_summary_waiters.jsonl" ]] && printf 1 || printf 0)"
assert_eq "deactivation removes reviewer receipt" "0" \
  "$([[ -e "${dir}/reviewer_publication_outcomes.jsonl" ]] && printf 1 || printf 0)"
assert_eq "deactivation removes fixed reviewer WAL" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.wal" ]] && printf 1 || printf 0)"
assert_eq "deactivation removes reviewer prepare directory" "0" \
  "$([[ -e "${dir}/.reviewer-transaction.prepare.interrupted" ]] \
    && printf 1 || printf 0)"
assert_eq "deactivation removes every loose reviewer stage" "0" \
  "$(reviewer_loose_stage_count "${dir}")"
assert_eq "deactivation never dereferences a loose-stage symlink" \
  "external-deactivate-stage" "$(<"${deactivate_stage_target}")"
assert_eq "deactivation taints the interrupted reviewer identity" \
  "quality-reviewer" "$(<"${dir}/dispatch_tainted_identities.log")"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
