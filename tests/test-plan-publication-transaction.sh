#!/usr/bin/env bash

# Crash/reordering regression net for planner publication. The dedicated plan
# hook owns the executable plan/Definition decision; the universal summary
# hook may publish effects only after a lifecycle-bound receipt from that
# transaction. Every pre-commit publication boundary is recoverable to one
# complete old generation, while the post-commit boundary remains one complete
# new generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

TEST_HOME="$(mktemp -d -t plan-publication-home-XXXXXX)"
TEST_STATE_ROOT="${TEST_HOME}/state"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state" "${TEST_STATE_ROOT}" \
  "${TEST_HOME}/.claude/skills" "${TEST_HOME}/.claude/quality-pack"
touch "${TEST_HOME}/.claude/quality-pack/state/.ulw_active"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" \
  "${TEST_HOME}/.claude/skills/autowork"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" \
  "${TEST_HOME}/.claude/quality-pack/scripts"

ORIGINAL_HOME="${HOME}"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${HOOK_DIR}/common.sh"
_omc_load_quality_contract

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

jsonl_count() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    jq -s 'length' "${path}"
  else
    printf '0'
  fi
}

state_artifact_manifest() {
  local root="$1" relative path digest target
  shift
  for relative in "$@"; do
    path="${root}/${relative}"
    if [[ -L "${path}" ]]; then
      target="$(readlink "${path}")" || return 1
      printf '%s\tsymlink\t%s\n' "${relative}" "${target}"
    elif [[ -f "${path}" ]]; then
      digest="$(shasum -a 256 "${path}" | awk '{print $1}')" || return 1
      printf '%s\tfile\t%s\n' "${relative}" "${digest}"
    elif [[ -e "${path}" ]]; then
      printf '%s\tother\n' "${relative}"
    else
      printf '%s\tabsent\n' "${relative}"
    fi
  done
}

reset_session() {
  local sid="$1" plan_revision="${2:-0}"
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
    "plan_revision" "${plan_revision}" \
    "plan_verdict" "OLD" \
    "has_plan" "true" \
    "task_intent" "execution" \
    "plan_dispatch_tracking_version" "1" \
    "native_agent_id_tracking_version" "1" \
    "subagent_dispatch_tracking_version" "1"
  printf 'old-plan-%s\n' "${sid}" >"$(session_file "current_plan.md")"
}

seed_dispatch() {
  local sid="$1" native_id="$2" lifecycle_id="$3"
  local plan_revision="${4:-0}" prompt_revision="${5:-1}"
  local enforcement_generation="${6:-1}" row
  export SESSION_ID="${sid}"
  row="$(jq -nc \
    --arg native "${native_id}" \
    --arg lifecycle "${lifecycle_id}" \
    --arg enforcement_generation "${enforcement_generation}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson prompt_revision "${prompt_revision}" '
      {
        ts:100,
        agent_type:"quality-planner",
        description:"publish the exact plan",
        lifecycle_dispatch_id:$lifecycle,
        edit_revision:0,
        code_revision:0,
        doc_revision:0,
        bash_revision:0,
        ui_revision:0,
        plan_revision:$plan_revision,
        objective_prompt_ts:100,
        objective_prompt_revision:$prompt_revision,
        objective_cycle_id:1,
        ulw_enforcement_generation:$enforcement_generation,
        review_dispatch_causality_version:1,
        review_revision:$plan_revision,
        native_agent_id:$native
      }
    ')"
  printf '%s\n' "${row}" >"$(session_file "pending_agents.jsonl")"
  printf '%s\n' "${row}" >"$(session_file "agent_dispatch_starts.jsonl")"
  jq -nc --arg native "${native_id}" --arg lifecycle "${lifecycle_id}" '
    {native_agent_id:$native,agent_type:"quality-planner",
     review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
     objective_cycle_id:1,ts:100}
  ' >"$(session_file "native_agent_bindings.jsonl")"
}

seed_ordinary_dispatch() {
  local sid="$1" agent="$2" native_id="$3" lifecycle_id="$4" row
  export SESSION_ID="${sid}"
  row="$(jq -nc \
    --arg agent "${agent}" --arg native "${native_id}" \
    --arg lifecycle "${lifecycle_id}" '
      {
        ts:100,agent_type:$agent,description:"ordinary exact completion",
        lifecycle_dispatch_id:$lifecycle,
        edit_revision:0,code_revision:0,doc_revision:0,bash_revision:0,
        ui_revision:0,plan_revision:0,review_revision:0,
        objective_prompt_ts:100,objective_prompt_revision:1,
        objective_cycle_id:1,ulw_enforcement_generation:"1",
        native_agent_id:$native
      }
    ')"
  printf '%s\n' "${row}" >"$(session_file "pending_agents.jsonl")"
  : >"$(session_file "agent_dispatch_starts.jsonl")"
  jq -nc --arg native "${native_id}" --arg agent "${agent}" \
      --arg lifecycle "${lifecycle_id}" '
    {native_agent_id:$native,agent_type:$agent,review_dispatch_id:"",
     lifecycle_dispatch_id:$lifecycle,objective_cycle_id:1,ts:100}
  ' >"$(session_file "native_agent_bindings.jsonl")"
}

plan_payload() {
  local sid="$1" native_id="$2" message="$3"
  agent_payload "${sid}" "quality-planner" "${native_id}" "${message}"
}

agent_payload() {
  local sid="$1" agent="$2" native_id="$3" message="$4"
  jq -nc \
    --arg sid "${sid}" \
    --arg agent "${agent}" \
    --arg native "${native_id}" \
    --arg message "${message}" '
      {
        session_id:$sid,
        agent_type:$agent,
        agent_id:$native,
        last_assistant_message:$message,
        stop_hook_active:false
      }
    '
}

run_plan() {
  local sid="$1" native_id="$2" message="$3"
  local kill_at="${4:-}" fail_at="${5:-}" recover_only="${6:-0}"
  local rc
  set +e
  plan_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_PLAN_TXN_KILL_AT="${kill_at}" \
      OMC_TEST_PLAN_TXN_FAIL_AT="${fail_at}" \
      OMC_TEST_PLAN_TXN_RECOVER_ONLY="${recover_only}" \
      OMC_TEST_PLAN_HISTORY_TAIL_FAULT="${OMC_TEST_PLAN_HISTORY_TAIL_FAULT:-0}" \
      OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE="${OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE:-0}" \
      bash "${HOOK_DIR}/record-plan.sh" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

# Simulate a callback that already passed the ordinary entry recovery barrier,
# then lost the race for the publication lock. Inject the sibling's exact
# waiter and receipt only after the publisher exposes its deterministic
# post-barrier pause; no environment flag bypasses production recovery.
run_plan_after_entry_recovery() {
  local sid="$1" native_id="$2" message="$3"
  local waiter="$4" receipt="$5" dir ready release child_pid
  local attempts=0 rc=0 ready_seen=0
  dir="${TEST_STATE_ROOT}/${sid}"
  ready="${dir}/.test-plan-txn-pause-ready"
  release="${dir}/.test-plan-txn-pause-release"
  rm -f "${ready}" "${release}"
  set +e
  (
    plan_payload "${sid}" "${native_id}" "${message}" \
      | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
        OMC_TEST_PLAN_TXN_PAUSE_AT=after-entry-recovery \
        bash "${HOOK_DIR}/record-plan.sh" >/dev/null 2>&1
  ) &
  child_pid=$!
  while [[ ! -e "${ready}" && "${attempts}" -lt 1000 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [[ -f "${ready}" && ! -L "${ready}" ]]; then
    ready_seen=1
    printf '%s\n' "${waiter}" >"${dir}/plan_summary_waiters.jsonl"
    printf '%s\n' "${receipt}" >"${dir}/plan_publication_outcomes.jsonl"
  fi
  : >"${release}"
  wait "${child_pid}"
  rc=$?
  [[ "${ready_seen}" -eq 1 ]] || rc=97
  set -e
  printf '%s' "${rc}"
}

run_summary() {
  local sid="$1" native_id="$2" message="$3"
  local wal_wait_attempts="${4:-120}"
  plan_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_SUMMARY_PLAN_WAL_WAIT_ATTEMPTS="${wal_wait_attempts}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" \
      >/dev/null 2>&1 || true
}

run_summary_output() {
  local sid="$1" native_id="$2" message="$3"
  local wal_wait_attempts="${4:-120}"
  plan_payload "${sid}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_SUMMARY_PLAN_WAL_WAIT_ATTEMPTS="${wal_wait_attempts}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" 2>/dev/null || true
}

run_agent_summary_rc() {
  local sid="$1" agent="$2" native_id="$3" message="$4"
  local kill_after_finalize="${5:-0}" plan_kill_after_finalize="${6:-0}" rc
  set +e
  agent_payload "${sid}" "${agent}" "${native_id}" "${message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_SUMMARY_KILL_AFTER_FINALIZE="${kill_after_finalize}" \
      OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE="${plan_kill_after_finalize}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

printf 'Planner publication rejects NUL-normalized hook authority\n'
sid="plan-nul-hook-envelope"
native="native-plan-nul-hook-envelope"
lifecycle="dispatch-plannulhookenvelope"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0
dir="${TEST_STATE_ROOT}/${sid}"
nul_plan_payload="$(jq -nc --arg sid "${sid}" --arg native "${native}" '
  {session_id:$sid,agent_type:"quality-planner",agent_id:$native,
   last_assistant_message:("1. Publish safely.\nVERDICT: PLAN_READY" + "\u0000"),
   stop_hook_active:false}')"
printf '%s' "${nul_plan_payload}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-plan.sh" >/dev/null 2>&1 || true
printf '%s' "${nul_plan_payload}" \
  | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1 || true
assert_eq "NUL-tailed PLAN_READY leaves pending owner intact" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "NUL-tailed PLAN_READY leaves start owner intact" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "NUL-tailed PLAN_READY publishes no plan receipt" "0" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"
assert_eq "NUL-tailed PLAN_READY publishes no universal summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "NUL-tailed PLAN_READY cannot change verdict" "OLD" \
  "$(read_state "plan_verdict")"
assert_eq "NUL-tailed PLAN_READY cannot replace plan bytes" \
  "old-plan-${sid}" "$(tr -d '\n' <"${dir}/current_plan.md")"

printf 'Planner migration ledger rejects NUL-normalized persisted role\n'
sid="plan-nul-migration-ledger"
reset_session "${sid}" 0
seed_dispatch "${sid}" "native-plan-nul-migration" \
  "dispatch-plannulmigration" 0
dir="${TEST_STATE_ROOT}/${sid}"
write_state "native_agent_id_tracking_version" ""
rm -f "${dir}/native_agent_bindings.jsonl"
for ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  jq -c 'del(.native_agent_id) | .agent_type += "\u0000"' \
    "${dir}/${ledger}" >"${dir}/${ledger}.tmp"
  mv "${dir}/${ledger}.tmp" "${dir}/${ledger}"
  cp "${dir}/${ledger}" "${dir}/${ledger}.before"
done
plan_nul_migration_rc="$(run_plan "${sid}" "" \
  $'Publish only the exact plan.\nVERDICT: PLAN_READY')"
assert_nonzero "NUL-tailed migration planner row fails closed" \
  "${plan_nul_migration_rc}"
for ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  assert_eq "NUL migration planner preserves ${ledger}" "yes" \
    "$(cmp -s "${dir}/${ledger}.before" "${dir}/${ledger}" \
      && printf yes || printf no)"
done
assert_eq "NUL migration planner publishes no receipt" "0" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"

test_migrated_ordinary_claim_compact_race() {
printf 'Universal summary: migrated objective claim fences compact then settles\n'
sid="ordinary-summary-migrated-compact-race"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
# Pre-cycle sessions have only last_user_prompt_ts. Pending dispatches created
# in that migration shape bind to it, so a claim owner must resolve the same
# fallback at every later state-lock acquisition.
jq 'del(.review_cycle_prompt_ts)' "${dir}/session_state.json" \
  >"${dir}/session_state.json.tmp"
mv "${dir}/session_state.json.tmp" "${dir}/session_state.json"
seed_ordinary_dispatch "${sid}" "librarian" \
  "native-migrated-librarian" "dispatch-migratedlibrarian"
ordinary_claim_sibling_row="$(jq -c '
  .agent_type = "quality-researcher"
  | .native_agent_id = "native-migrated-researcher"
  | .lifecycle_dispatch_id = "dispatch-migratedresearcher"
  | .description = "retain through compact handoff"
' "${dir}/pending_agents.jsonl")"
printf '%s\n' "${ordinary_claim_sibling_row}" \
  >>"${dir}/pending_agents.jsonl"

ordinary_claim_ready="${TEST_HOME}/ordinary-claim-ready"
ordinary_claim_release="${TEST_HOME}/ordinary-claim-release"
ordinary_claim_rc_file="${TEST_HOME}/ordinary-claim-rc"
ordinary_claim_message="Migrated ordinary completion is settled exactly."
(
  set +e
  agent_payload "${sid}" "librarian" "native-migrated-librarian" \
      "${ordinary_claim_message}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_SUMMARY_CLAIM_READY_FILE="${ordinary_claim_ready}" \
      OMC_TEST_SUMMARY_CLAIM_RELEASE_FILE="${ordinary_claim_release}" \
      bash "${HOOK_DIR}/record-subagent-summary.sh" >/dev/null 2>&1
  printf '%s\n' "$?" >"${ordinary_claim_rc_file}"
) &
ordinary_claim_pid=$!
for ordinary_claim_wait in $(seq 1 500); do
  [[ -e "${ordinary_claim_ready}" ]] && break
  kill -0 "${ordinary_claim_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "ordinary claim reaches pre-effects barrier" "1" \
  "$([[ -e "${ordinary_claim_ready}" ]] && printf 1 || printf 0)"
assert_eq "ordinary claim is durable before effects" "false" \
  "$(jq -r 'select(.agent_type == "librarian")
      | if has("completion_claim_effects_complete") then
          (.completion_claim_effects_complete | tostring)
        else "missing" end' \
    "${dir}/pending_agents.jsonl")"

set +e
ordinary_claim_compact_output="$(run_precompact_output "${sid}")"
ordinary_claim_compact_rc=$?
set -e
assert_nonzero "PreCompact is fenced while ordinary claim is live" \
  "${ordinary_claim_compact_rc}"
assert_eq "fenced PreCompact emits no payload" "" \
  "${ordinary_claim_compact_output}"
assert_eq "fenced PreCompact publishes no snapshot" "0" \
  "$([[ -e "${dir}/precompact_snapshot.md" \
        || -L "${dir}/precompact_snapshot.md" ]] \
    && printf 1 || printf 0)"

touch "${ordinary_claim_release}"
wait "${ordinary_claim_pid}"
assert_eq "ordinary claim owner completes" "0" \
  "$(<"${ordinary_claim_rc_file}")"
assert_eq "ordinary claim settles exact librarian row" "0" \
  "$(jq -Rsr '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch {})
        | select(.agent_type == "librarian")] | length
    ' "${dir}/pending_agents.jsonl")"
assert_eq "ordinary settlement retains sibling specialist" "1" \
  "$(jq -Rsr '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch {})
        | select(.agent_type == "quality-researcher")] | length
    ' "${dir}/pending_agents.jsonl")"
assert_eq "ordinary settlement leaves no completion claim" "0" \
  "$(jq -Rsr '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch {})
        | select((.completion_claim_id // "") != "")] | length
    ' "${dir}/pending_agents.jsonl")"

ordinary_postsettle_compact_rc=0
ordinary_postsettle_compact_output="$(run_precompact_output "${sid}")" \
  || ordinary_postsettle_compact_rc=$?
assert_eq "PreCompact resumes after ordinary settlement" "0" \
  "${ordinary_postsettle_compact_rc}"
assert_eq "settled PreCompact emits no inline payload" "" \
  "${ordinary_postsettle_compact_output}"
assert_eq "settled compact snapshot retains sibling" "1" \
  "$(grep -q 'quality-researcher' "${dir}/precompact_snapshot.md" \
    && printf 1 || printf 0)"
assert_eq "settled compact snapshot drops completed role" "0" \
  "$(awk '
      /^## Pending Specialists/ { in_pending = 1; next }
      /^## / && in_pending { exit }
      in_pending { print }
    ' "${dir}/precompact_snapshot.md" | grep -q 'librarian' \
    && printf 1 || printf 0)"
rm -f "${ordinary_claim_ready}" "${ordinary_claim_release}" \
  "${ordinary_claim_rc_file}"
}

run_router_rc() {
  local sid="$1" prompt="$2" payload rc
  payload="$(jq -nc --arg sid "${sid}" --arg prompt "${prompt}" \
    '{session_id:$sid,prompt:$prompt,transcript_path:"/tmp/none.jsonl"}')"
  set +e
  printf '%s' "${payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_DEFINITION_OF_EXCELLENT=adaptive \
      OMC_QUALITY_CONSTITUTION=off OMC_EXEMPLIFYING_SCOPE_GATE=off \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      >/dev/null 2>&1
  rc=$?
  set -e
  printf '%s' "${rc}"
}

run_router() {
  local sid="$1" prompt="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg prompt "${prompt}" \
    '{session_id:$sid,prompt:$prompt,transcript_path:"/tmp/none.jsonl"}')"
  printf '%s' "${payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_DEFINITION_OF_EXCELLENT=adaptive \
      OMC_QUALITY_CONSTITUTION=off OMC_EXEMPLIFYING_SCOPE_GATE=off \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      >/dev/null 2>&1
}

run_router_output() {
  local sid="$1" prompt="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg prompt "${prompt}" \
    '{session_id:$sid,prompt:$prompt,transcript_path:"/tmp/none.jsonl"}')"
  printf '%s' "${payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_DEFINITION_OF_EXCELLENT=adaptive \
      OMC_QUALITY_CONSTITUTION=off OMC_EXEMPLIFYING_SCOPE_GATE=off \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      2>/dev/null || true
}

run_pretool_output() {
  local sid="$1" path="$2"
  jq -nc --arg sid "${sid}" --arg path "${path}" '
      {session_id:$sid,tool_name:"Write",tool_input:{file_path:$path,
       content:"mutation must be denied"}}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${HOOK_DIR}/pretool-intent-guard.sh" 2>/dev/null || true
}

run_precompact_output() {
  local sid="$1"
  jq -nc --arg sid "${sid}" '
      {session_id:$sid,trigger:"manual",custom_instructions:"",
       cwd:"/tmp",hook_event_name:"PreCompact"}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/pre-compact-snapshot.sh" \
      2>/dev/null
}

run_postcompact_output() {
  local sid="$1"
  jq -nc --arg sid "${sid}" '
      {session_id:$sid,trigger:"manual",compact_summary:"native summary",
       hook_event_name:"PostCompact"}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/post-compact-summary.sh" \
      2>/dev/null
}

run_compact_start_output() {
  local sid="$1"
  jq -nc --arg sid "${sid}" '
      {session_id:$sid,source:"compact",hook_event_name:"SessionStart"}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh" \
      2>/dev/null
}

run_resume_start_output() {
  local sid="$1" source_sid="$2"
  jq -nc --arg sid "${sid}" \
      --arg transcript "/tmp/${source_sid}.jsonl" '
      {session_id:$sid,source:"resume",transcript_path:$transcript,
       hook_event_name:"SessionStart"}
    ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-resume-handoff.sh" \
      2>/dev/null
}

definition_v1() {
  jq -nc '
    def criterion($id;$axis;$kind;$tool;$command;$artifact): {
      id:$id,class:"must",axis:$axis,
      claim:("The " + $axis + " result is complete and causally verified for " + $id + "."),
      rationale:("The requested quality bar requires concrete " + $axis + " evidence."),
      surfaces:[($axis + " surface")],
      evidence_policy:{
        allowed_kinds:[$kind],minimum:1,requires_empirical:true,
        requires_independent_review:true
      },
      proof_method:("Run and inspect the exact " + $id + " proof against the settled artifact."),
      proof_spec:{
        tool_names:[$tool],receipt_kinds:[$kind],
        command_contains:[$command,$id],artifact_contains:$artifact
      },
      failure_signal:("The exact " + $id + " proof is absent or fails."),
      tradeoff_boundary:"Convenience never weakens causal proof."
    };
    {
      north_star:"Ship a deliberate, distinctive, coherent, visionary, and complete command workflow.",
      audience:"Developers relying on the command workflow for consequential daily work.",
      stakes:"A generic or incomplete result would undermine trust in the workflow.",
      ambition_boundary:"Prefer a coherent product-level improvement over decorative novelty.",
      axes:{
        deliberate:"Every behavior has an explicit user-grounded reason.",
        distinctive:"The workflow has a recognizable point of view.",
        coherent:"Every surface expresses one consistent mental model.",
        visionary:"The workflow materially improves on the baseline.",
        complete:"All promised paths, failures, tests, and handoff are finished."
      },
      standards:[{
        kind:"user",reference:"explicit perfectionist quality mandate",
        rationale:"The user explicitly requested comprehensive completion."
      }],
      anti_goals:["Do not substitute decorative novelty for verified user value."],
      criteria:[
        criterion("Q-001";"deliberate";"test";"Bash";"tests/criterion-q001-deliberate-test.sh";[]),
        criterion("Q-002";"distinctive";"comparison";"Bash";"tests/test-quality-contract.sh comparison";[]),
        criterion("Q-003";"coherent";"inspection";"Grep";"definition_v1";["tests/test-plan-publication-transaction.sh"]),
        criterion("Q-004";"visionary";"comparison";"Bash";"tests/test-definition-of-excellent-e2e.sh comparison";[]),
        criterion("Q-005";"complete";"test";"Bash";"tests/criterion-q005-complete-test.sh";[])
      ]
    }
  '
}

definition_v2() {
  local base="$1"
  jq -c '
    .criteria += [{
      id:"Q-006",class:"must",axis:"complete",
      claim:"Crash recovery restores one complete plan publication generation.",
      rationale:"Atomic quality publication is mandatory for trustworthy recovery.",
      surfaces:["planner crash recovery"],
      evidence_policy:{
        allowed_kinds:["test"],minimum:1,requires_empirical:true,
        requires_independent_review:true
      },
      proof_method:"Kill every plan publication boundary and compare the recovered generation.",
      proof_spec:{
        tool_names:["Bash"],receipt_kinds:["test"],
        command_contains:["tests/criterion-q006-publication-recovery-test.sh","Q-006"],artifact_contains:[]
      },
      failure_signal:"Any recovered artifact belongs to a different generation.",
      tradeoff_boundary:"Recovery correctness outranks publication speed."
    }]
  ' <<<"${base}"
}

definition_message() {
  local definition="$1"
  printf '1. Freeze the exact quality bar.\n2. Verify every publication boundary.\nQUALITY_CONTRACT_JSON: %s\nVERDICT: PLAN_READY' \
    "${definition}"
}

assert_old_generation() {
  local label="$1" sid="$2" state_before="$3" pending_before="$4"
  local starts_before="$5" plan_before="$6" dir
  dir="${TEST_STATE_ROOT}/${sid}"
  assert_eq "${label}: state restored byte-for-byte" \
    "${state_before}" "$(<"${dir}/session_state.json")"
  assert_eq "${label}: pending restored byte-for-byte" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${label}: start restored byte-for-byte" \
    "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${label}: plan restored byte-for-byte" \
    "${plan_before}" "$(<"${dir}/current_plan.md")"
  assert_eq "${label}: no mixed receipt survives rollback" "0" \
    "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"
  assert_eq "${label}: fixed active WAL is retired" "0" \
    "$([[ -e "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
}

test_migrated_ordinary_claim_compact_race

printf 'Planner WAL: every ordinary publication boundary\n'
ordinary_message=$'1. Publish the new plan.\nVERDICT: PLAN_READY'

printf 'Publication recovery rejects persisted NUL-bearing replay messages\n'
sid="plan-persisted-nul-claim"
native="native-plan-persisted-nul-claim"
lifecycle="dispatch-planpersistednulclaim"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "persisted planner fixture publishes its durable receipt" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
persisted_claim_digest="$(_omc_token_digest "${ordinary_message}")"
jq -c --arg digest "${persisted_claim_digest}" \
    --arg message "${ordinary_message}" '
  . + {
    completion_claim_id:"completion-plan-persisted-nul-claim",
    completion_claim_ts:1,
    completion_claim_effects_complete:true,
    completion_claim_digest:$digest,
    completion_claim_message:($message + "\u0000")
  }
' "${dir}/pending_agents.jsonl" >"${dir}/pending_agents.jsonl.tmp"
mv "${dir}/pending_agents.jsonl.tmp" "${dir}/pending_agents.jsonl"
persisted_recovery_rc=0
omc_recover_active_publication_transactions "${sid}" \
  >/dev/null 2>&1 || persisted_recovery_rc=$?
assert_nonzero "persisted planner NUL claim fails closed" \
  "${persisted_recovery_rc}"
assert_eq "persisted planner NUL claim remains fenced" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "persisted planner NUL claim replays no summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "persisted planner NUL claim publishes no parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"

sid="generic-persisted-nul-claim"
agent="frontend-developer"
native="native-generic-persisted-nul-claim"
lifecycle="dispatch-genericpersistednulclaim"
generic_message=$'Completed the exact work.\nVERDICT: DELIVERED'
reset_session "${sid}" 0
seed_ordinary_dispatch "${sid}" "${agent}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
persisted_claim_digest="$(_omc_token_digest "${generic_message}")"
jq -c --arg digest "${persisted_claim_digest}" \
    --arg message "${generic_message}" '
  . + {
    completion_claim_id:"completion-generic-persisted-nul-claim",
    completion_claim_ts:1,
    completion_claim_effects_complete:true,
    completion_claim_digest:$digest,
    completion_claim_message:($message + "\u0000")
  }
' "${dir}/pending_agents.jsonl" >"${dir}/pending_agents.jsonl.tmp"
mv "${dir}/pending_agents.jsonl.tmp" "${dir}/pending_agents.jsonl"
persisted_recovery_rc=0
omc_recover_active_publication_transactions "${sid}" \
  >/dev/null 2>&1 || persisted_recovery_rc=$?
assert_nonzero "persisted generic NUL claim fails closed" \
  "${persisted_recovery_rc}"
assert_eq "persisted generic NUL claim remains fenced" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "persisted generic NUL claim replays no summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "persisted generic NUL claim publishes no parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"

printf 'Planner causality: native binding and start identities are exact\n'
for binding_case in native agent lifecycle review cycle legacy duplicate malformed; do
  sid="plan-binding-${binding_case}"
  native="native-plan-binding-${binding_case}"
  lifecycle="dispatch-planbinding${binding_case}1234"
  reset_session "${sid}" 0
  seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
  dir="${TEST_STATE_ROOT}/${sid}"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  case "${binding_case}" in
    native) jq -c '.native_agent_id="foreign-native"' \
      "${dir}/native_agent_bindings.jsonl" >"${dir}/binding.tmp" ;;
    agent) jq -c '.agent_type="foreign-planner"' \
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
  run_plan "${sid}" "${native}" "${ordinary_message}" >/dev/null
  assert_eq "${binding_case} binding: plan remains unpublished" \
    "old-plan-${sid}" "$(<"${dir}/current_plan.md")"
  assert_eq "${binding_case} binding: pending authority is retained" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${binding_case} binding: start authority is retained" \
    "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${binding_case} binding: no receipt is forged" "0" \
    "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"
done

sid="plan-binding-missing-pending"
native="native-plan-binding-missing-pending"
lifecycle="dispatch-planbindingmissingpending1234"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
: >"${dir}/pending_agents.jsonl"
run_plan "${sid}" "${native}" "${ordinary_message}" >/dev/null
assert_eq "missing pending: plan remains unpublished" \
  "old-plan-${sid}" "$(<"${dir}/current_plan.md")"
assert_eq "missing pending: absent authority is not reconstructed" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "missing pending: start authority is retained" \
  "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "missing pending: no receipt is forged" "0" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"

sid="plan-binding-frozen-mismatch"
native="native-plan-binding-frozen-mismatch"
lifecycle="dispatch-planbindingfrozenmismatch1234"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
jq -c '.description="mutated pending description"' \
  "${dir}/pending_agents.jsonl" >"${dir}/pending.tmp"
mv -f "${dir}/pending.tmp" "${dir}/pending_agents.jsonl"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
run_plan "${sid}" "${native}" "${ordinary_message}" >/dev/null
assert_eq "frozen mismatch: plan remains unpublished" \
  "old-plan-${sid}" "$(<"${dir}/current_plan.md")"
assert_eq "frozen mismatch: pending authority is retained" \
  "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
assert_eq "frozen mismatch: start authority is retained" \
  "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "frozen mismatch: no receipt is forged" "0" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"

sid="plan-duplicate-start-candidate"
native="native-plan-duplicate-start"
lifecycle="dispatch-planduplicatestart1234"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
cat "${dir}/agent_dispatch_starts.jsonl" \
  >>"${dir}/agent_dispatch_starts.jsonl.duplicate"
cat "${dir}/agent_dispatch_starts.jsonl" \
  >>"${dir}/agent_dispatch_starts.jsonl.duplicate"
mv "${dir}/agent_dispatch_starts.jsonl.duplicate" \
  "${dir}/agent_dispatch_starts.jsonl"
run_plan "${sid}" "${native}" "${ordinary_message}" >/dev/null
assert_eq "duplicate planner start: no plan is published" \
  "old-plan-${sid}" "$(<"${dir}/current_plan.md")"
assert_eq "duplicate planner start: both ambiguous rows remain" "2" \
  "$(jq -s 'length' "${dir}/agent_dispatch_starts.jsonl")"

sid="summary-duplicate-pending-candidate"
agent="frontend-developer"
native="native-summary-duplicate-pending"
lifecycle="dispatch-summaryduplicatepending1234"
reset_session "${sid}" 0
seed_ordinary_dispatch "${sid}" "${agent}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
cat "${dir}/pending_agents.jsonl" >>"${dir}/pending_agents.jsonl.duplicate"
cat "${dir}/pending_agents.jsonl" >>"${dir}/pending_agents.jsonl.duplicate"
mv "${dir}/pending_agents.jsonl.duplicate" "${dir}/pending_agents.jsonl"
run_agent_summary_rc "${sid}" "${agent}" "${native}" \
  $'Completed exact work.\nVERDICT: DELIVERED' >/dev/null
assert_eq "duplicate summary pending: no summary is published" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "duplicate summary pending: no outcome is published" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "duplicate summary pending: ambiguous rows remain" "2" \
  "$(jq -s 'length' "${dir}/pending_agents.jsonl")"

sid="summary-binding-lifecycle-mismatch"
agent="frontend-developer"
native="native-summary-binding-mismatch"
lifecycle="dispatch-summarybindingmismatch1234"
reset_session "${sid}" 0
seed_ordinary_dispatch "${sid}" "${agent}" "${native}" "${lifecycle}"
dir="${TEST_STATE_ROOT}/${sid}"
jq -c '.lifecycle_dispatch_id="dispatch-foreignsummarybinding1234"' \
  "${dir}/native_agent_bindings.jsonl" \
  >"${dir}/native_agent_bindings.jsonl.tmp"
mv "${dir}/native_agent_bindings.jsonl.tmp" \
  "${dir}/native_agent_bindings.jsonl"
run_agent_summary_rc "${sid}" "${agent}" "${native}" \
  $'Completed exact work.\nVERDICT: DELIVERED' >/dev/null
assert_eq "summary binding mismatch: no summary is published" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary binding mismatch: no outcome is published" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary binding mismatch: pending authority remains" "1" \
  "$(jq -s 'length' "${dir}/pending_agents.jsonl")"

# A pre-fix/migration ledger may contain a phantom stateful start for an
# arbitrary namespaced lookalike. Even an echoed legacy dispatch ID cannot let
# the real quality-planner hook claim that row and publish on its behalf.
sid="plan-namespaced-lookalike"
native=""
lifecycle="dispatch-plannamespacedlookalike"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
# Exercise the echoed-ID compatibility branch used by an in-flight session
# created before native SubagentStart tracking was armed.
write_state "native_agent_id_tracking_version" ""
for lookalike_file in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  jq -c '.agent_type="custom:quality-planner"
    | .review_dispatch_id="phantom-plan"
    | .native_agent_id=""' "${dir}/${lookalike_file}" \
    >"${dir}/${lookalike_file}.tmp"
  mv -f "${dir}/${lookalike_file}.tmp" "${dir}/${lookalike_file}"
done
lookalike_message=$'A plan from the configured planner hook.\nREVIEW_DISPATCH_ID: phantom-plan\nVERDICT: PLAN_READY'
assert_eq "namespaced lookalike: planner hook handles rejection" "0" \
  "$(run_plan "${sid}" "${native}" "${lookalike_message}")"
assert_eq "namespaced lookalike: cannot publish plan generation" "0" \
  "$(jq -r '.plan_revision' "${dir}/session_state.json")"
assert_eq "namespaced lookalike: phantom start remains unconsumed" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "namespaced lookalike: no publication receipt is forged" "0" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"

sid="plan-stage-death"
native="native-plan-stage-death"
lifecycle="dispatch-planstagedeathabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
stage_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" before-journal-activate)"
assert_nonzero "pre-activation death is observable" "${stage_kill_rc}"
assert_eq "pre-activation death publishes no active WAL" "0" \
  "$([[ -e "${dir}/.plan-txn.active" \
      || -L "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
assert_eq "pre-activation death leaves one inert stage" "1" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.stage.*' \
    | wc -l | tr -d ' ')"
assert_eq "pre-activation death leaves canonical plan generation old" "0" \
  "$(jq -r '.plan_revision' "${dir}/session_state.json")"
assert_eq "pre-activation replay cleans stage and publishes" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "pre-activation replay retires inert stages" "0" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.stage.*' \
    | wc -l | tr -d ' ')"
assert_eq "pre-activation replay publishes one complete generation" \
  "1:PLAN_READY:accepted" \
  "$(jq -r '(.plan_revision | tostring) + ":" + .plan_verdict' \
    "${dir}/session_state.json"):$(jq -r '.status' \
      "${dir}/plan_publication_outcomes.jsonl")"

ordinary_boundaries='after-journal-activate after-start-consume after-plan-publish after-state-publish after-receipt-publish'
index=0
for boundary in ${ordinary_boundaries}; do
  index=$((index + 1))
  sid="plan-wal-${index}"
  native="native-plan-wal-${index}"
  lifecycle="dispatch-planwal${index}abcdefgh"
  reset_session "${sid}" 0
  seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
  dir="${TEST_STATE_ROOT}/${sid}"
  state_before="$(<"${dir}/session_state.json")"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  plan_before="$(<"${dir}/current_plan.md")"
  kill_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" "${boundary}")"
  assert_nonzero "${boundary}: injected process death is observable" "${kill_rc}"
  assert_eq "${boundary}: active WAL survives process death" "1" \
    "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
  run_summary "${sid}" "${native}" "${ordinary_message}" 1
  assert_eq "${boundary}: provisional state creates no summary" "0" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${boundary}: provisional state creates no parent outcome" "0" \
    "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${boundary}: provisional state preserves pending" "1" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  assert_eq "${boundary}: recovery-only callback succeeds" "0" \
    "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
  assert_old_generation "${boundary}" "${sid}" "${state_before}" \
    "${pending_before}" "${starts_before}" "${plan_before}"
done

sid="plan-wal-retry-temp"
native="native-plan-wal-retry-temp"
lifecycle="dispatch-planwalretrytemp"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
plan_before="$(<"${dir}/current_plan.md")"
kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "plan retry temp: fixture process death is observable" \
  "${kill_rc}"
printf '1\n' >"${dir}/.plan-txn.active/.summary-retry-count.ABC123"
assert_eq "plan retry temp: recovery accepts exact staged counter temp" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_old_generation "plan retry temp" "${sid}" "${state_before}" \
  "${pending_before}" "${starts_before}" "${plan_before}"
assert_eq "plan retry temp: no inert recovered directory remains" "0" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.recovered.*' \
    | wc -l | tr -d ' ')"

sid="plan-recovery-commit-death"
native="native-plan-recovery-commit-death"
lifecycle="dispatch-planrecoverycommitdeath"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
plan_before="$(<"${dir}/current_plan.md")"
kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "recovery-commit fixture death is observable" "${kill_rc}"
recovery_commit_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-recovery-commit '' 1)"
assert_nonzero "recovery-commit death is observable" \
  "${recovery_commit_kill_rc}"
assert_old_generation "recovery-commit death" "${sid}" "${state_before}" \
  "${pending_before}" "${starts_before}" "${plan_before}"
assert_eq "recovery-commit death leaves one inert recovered snapshot" "1" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.recovered.*' \
    | wc -l | tr -d ' ')"
assert_eq "recovery-commit retry cleans inert snapshot" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_eq "recovery-commit retry retires recovered snapshot" "0" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.recovered.*' \
    | wc -l | tr -d ' ')"

printf 'Planner WAL: summary-first pending-claim cleanup boundary\n'
sid="plan-wal-pending"
native="native-plan-wal-pending"
lifecycle="dispatch-planwalpendingabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
pending_file="$(session_file "pending_agents.jsonl")"
pending_tmp="${pending_file}.tmp"
ordinary_digest="$(_omc_token_digest "${ordinary_message}")"
jq -c --arg digest "${ordinary_digest}" --arg message "${ordinary_message}" \
  --arg claim_ts "$(now_epoch)" '
  . + {
    completion_claim_id:"completion-summary-first-claim",
    completion_claim_ts:($claim_ts | tonumber),
    completion_claim_effects_complete:true,
    completion_claim_digest:$digest,
    completion_claim_message:$message
  }
' "${pending_file}" >"${pending_tmp}"
mv "${pending_tmp}" "${pending_file}"
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
plan_before="$(<"${dir}/current_plan.md")"
kill_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" \
  after-pending-consume)"
assert_nonzero "pending-consume: injected process death is observable" "${kill_rc}"
run_summary "${sid}" "${native}" "${ordinary_message}" 1
assert_eq "pending-consume: provisional state creates no summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "pending-consume: provisional state creates no parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "pending-consume: recovery-only callback succeeds" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_old_generation "pending-consume" "${sid}" "${state_before}" \
  "${pending_before}" "${starts_before}" "${plan_before}"

printf 'Planner WAL: failed write and interrupted recovery are idempotent\n'
sid="plan-wal-return-failure"
native="native-plan-return-failure"
lifecycle="dispatch-planreturnfailure"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
plan_before="$(<"${dir}/current_plan.md")"
fail_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" '' \
  after-plan-publish)"
assert_nonzero "return failure propagates after automatic rollback" "${fail_rc}"
assert_old_generation "return failure" "${sid}" "${state_before}" \
  "${pending_before}" "${starts_before}" "${plan_before}"

sid="plan-wal-recovery-retry"
native="native-plan-recovery-retry"
lifecycle="dispatch-planrecoveryretry"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
plan_before="$(<"${dir}/current_plan.md")"
initial_recovery_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "recovery-retry fixture process death is observable" \
  "${initial_recovery_kill_rc}"
recover_kill_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" \
  after-recover-current_plan.md '' 1)"
assert_nonzero "recovery itself may be interrupted" "${recover_kill_rc}"
assert_eq "interrupted recovery retains active WAL" "1" \
  "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
assert_eq "second recovery converges" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_old_generation "recovery retry" "${sid}" "${state_before}" \
  "${pending_before}" "${starts_before}" "${plan_before}"

printf 'Planner WAL: SubagentStop self-heals one killed exact callback\n'
sid="plan-wal-native-self-heal"
native="native-plan-wal-native-self-heal"
lifecycle="dispatch-plannativeselfheal"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
self_heal_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-receipt-publish)"
assert_nonzero "self-heal fixture process death is observable" \
  "${self_heal_kill_rc}"
self_heal_context="$(run_summary_output \
  "${sid}" "${native}" "${ordinary_message}" 1)"
assert_eq "persistent valid WAL returns SubagentStop context" \
  "SubagentStop" \
  "$(jq -r '.hookSpecificOutput.hookEventName // empty' \
    <<<"${self_heal_context}")"
assert_eq "recovery context asks exact planner to return same plan" "1" \
  "$([[ "$(jq -r '.hookSpecificOutput.additionalContext // empty' \
      <<<"${self_heal_context}")" == *'same complete self-contained plan'* ]] \
    && printf 1 || printf 0)"
assert_eq "self-heal request publishes no provisional summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "self-heal request publishes no provisional outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "same-native rerun recovers then publishes" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "same-native rerun retires active WAL" "0" \
  "$([[ -e "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
run_summary "${sid}" "${native}" "${ordinary_message}" 1
assert_eq "same-native convergence publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "same-native convergence publishes accepted outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "same-native convergence consumes pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

sid="plan-wal-native-self-heal-bounded"
native="native-plan-wal-native-self-heal-bounded"
lifecycle="dispatch-plannativeselfhealbounded"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
bounded_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "bounded self-heal fixture process death is observable" \
  "${bounded_kill_rc}"
first_recovery_context="$(run_summary_output \
  "${sid}" "${native}" "${ordinary_message}" 1)"
second_recovery_context="$(run_summary_output \
  "${sid}" "${native}" "${ordinary_message}" 1)"
assert_eq "first persistent callback receives one recovery continuation" \
  "SubagentStop" \
  "$(jq -r '.hookSpecificOutput.hookEventName // empty' \
    <<<"${first_recovery_context}")"
assert_eq "second persistent callback does not loop continuation" "" \
  "${second_recovery_context}"
assert_eq "bounded recovery retires fixed WAL before continuation" "0" \
  "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
assert_eq "bounded recovery notice records one exact continuation" "true" \
  "$(jq -r 'select(.owner.lifecycle_dispatch_id ==
      "dispatch-plannativeselfhealbounded") | .retry_issued' \
    "${dir}/plan_recovery_notices.jsonl")"
assert_eq "bounded exhaustion still publishes no outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"

printf 'Planner WAL: exact owner prevents foreign retry continuations\n'
sid="plan-wal-owner-normal"
native_a="native-plan-owner-normal-a"
native_b="native-plan-owner-normal-b"
lifecycle_a="dispatch-planownernormala"
lifecycle_b="dispatch-planownernormalb"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native_a}" "${lifecycle_a}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
row_b="$(jq -c --arg native "${native_b}" --arg lifecycle "${lifecycle_b}" '
  .native_agent_id = $native | .lifecycle_dispatch_id = $lifecycle
' "${dir}/pending_agents.jsonl")"
printf '%s\n' "${row_b}" >>"${dir}/pending_agents.jsonl"
printf '%s\n' "${row_b}" >>"${dir}/agent_dispatch_starts.jsonl"
jq -nc --arg native "${native_b}" --arg lifecycle "${lifecycle_b}" \
  '{native_agent_id:$native,agent_type:"quality-planner",
    review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
    objective_cycle_id:1,ts:100}' \
  >>"${dir}/native_agent_bindings.jsonl"
OMC_TEST_PLAN_TXN_PAUSE_AT=after-journal-activate \
  run_plan "${sid}" "${native_a}" "${ordinary_message}" \
  >"${dir}/normal-a.rc" &
normal_a_pid=$!
for _wait in $(seq 1 500); do
  [[ -e "${dir}/.test-plan-txn-pause-ready" ]] && break
  sleep 0.01
done
assert_eq "normal publisher exposes exact owner before canonical writes" \
  "${lifecycle_a}" \
  "$(jq -r '.owner.lifecycle_dispatch_id // empty' \
    "${dir}/.plan-txn.active/.ready")"
run_summary_output "${sid}" "${native_b}" "${ordinary_message}" 1 \
  >"${dir}/normal-b.summary" &
normal_b_pid=$!
sleep 0.1
: >"${dir}/.test-plan-txn-pause-release"
wait "${normal_a_pid}"
wait "${normal_b_pid}"
assert_eq "normal owner commits successfully" "0" \
  "$(<"${dir}/normal-a.rc")"
assert_eq "foreign summary receives no false rollback continuation" "" \
  "$(<"${dir}/normal-b.summary")"
assert_eq "normal commit creates no rollback notice" "0" \
  "$(jsonl_count "${dir}/plan_recovery_notices.jsonl")"
assert_eq "foreign planner waits on its own receipt" "1" \
  "$(jq -s --arg lifecycle "${lifecycle_b}" \
    '[.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length' \
    "${dir}/plan_summary_waiters.jsonl")"

sid="plan-wal-owner-killed"
native_a="native-plan-owner-killed-a"
native_b="native-plan-owner-killed-b"
lifecycle_a="dispatch-planownerkilleda"
lifecycle_b="dispatch-planownerkilledb"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native_a}" "${lifecycle_a}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
row_b="$(jq -c --arg native "${native_b}" --arg lifecycle "${lifecycle_b}" '
  .native_agent_id = $native | .lifecycle_dispatch_id = $lifecycle
' "${dir}/pending_agents.jsonl")"
printf '%s\n' "${row_b}" >>"${dir}/pending_agents.jsonl"
printf '%s\n' "${row_b}" >>"${dir}/agent_dispatch_starts.jsonl"
jq -nc --arg native "${native_b}" --arg lifecycle "${lifecycle_b}" \
  '{native_agent_id:$native,agent_type:"quality-planner",
    review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
    objective_cycle_id:1,ts:100}' \
  >>"${dir}/native_agent_bindings.jsonl"
killed_owner_rc="$(run_plan "${sid}" "${native_a}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "killed exact-owner fixture is observable" "${killed_owner_rc}"
foreign_recovery_context="$(run_summary_output \
  "${sid}" "${native_b}" "${ordinary_message}" 1)"
assert_eq "foreign callback performs rollback without claiming retry" "" \
  "${foreign_recovery_context}"
assert_eq "foreign callback leaves owner notice unconsumed" "false" \
  "$(jq -r --arg lifecycle "${lifecycle_a}" \
    'select(.owner.lifecycle_dispatch_id == $lifecycle) | .retry_issued' \
    "${dir}/plan_recovery_notices.jsonl")"
owner_recovery_context="$(run_summary_output \
  "${sid}" "${native_a}" "${ordinary_message}" 1)"
assert_eq "only killed owner receives the rollback continuation" "1" \
  "$([[ "${owner_recovery_context}" == *'same complete self-contained plan'* ]] \
    && printf 1 || printf 0)"
assert_eq "owner notice is consumed once" "true" \
  "$(jq -r --arg lifecycle "${lifecycle_a}" \
    'select(.owner.lifecycle_dispatch_id == $lifecycle) | .retry_issued' \
    "${dir}/plan_recovery_notices.jsonl")"

printf 'Planner WAL: the commit point leaves one complete new generation\n'
sid="plan-wal-committed"
native="native-plan-wal-committed"
lifecycle="dispatch-planwalcommitted"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
commit_kill_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" \
  after-transaction-commit)"
assert_nonzero "post-commit process death is observable" "${commit_kill_rc}"
assert_eq "post-commit has no active rollback authority" "0" \
  "$([[ -e "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
assert_eq "post-commit plan generation is new" "1" \
  "$(jq -r '.plan_revision' "${dir}/session_state.json")"
assert_eq "post-commit plan verdict is new" "PLAN_READY" \
  "$(jq -r '.plan_verdict' "${dir}/session_state.json")"
assert_eq "post-commit start is consumed" "0" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "post-commit pending waits for summary" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "post-commit exact receipt exists" "accepted" \
  "$(jq -r '.status' "${dir}/plan_publication_outcomes.jsonl")"
assert_eq "post-commit death leaves one inert committed snapshot" "1" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.committed.*' \
    | wc -l | tr -d ' ')"
assert_eq "post-commit recovery-only cleanup preserves new generation" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_eq "post-commit recovery-only cleanup retires inert snapshot" "0" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.plan-txn.committed.*' \
    | wc -l | tr -d ' ')"
run_summary "${sid}" "${native}" "${ordinary_message}" 1
assert_eq "post-commit cleanup does not block summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "post-commit receipt authorizes accepted outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"

printf 'Planner WAL: rollback snapshots are kind/size/hash sealed\n'
sid="plan-wal-seal-tamper"
native="native-plan-wal-seal-tamper"
lifecycle="dispatch-planwalsealtamper"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
seal_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "snapshot seal fixture death is observable" "${seal_kill_rc}"
assert_eq "snapshot journal uses the sealed descriptor schema" "2" \
  "$(jq -r '.schema_version' "${dir}/.plan-txn.active/.ready")"
assert_eq "snapshot descriptor binds file kind, byte size, and sha256" "true" \
  "$(jq -r '
    [.artifacts[] | select(.name == "current_plan.md")][0]
    | .kind == "file"
      and (.seals | length) == 1
      and (.seals[0].size | type) == "number"
      and (.seals[0].sha256 | test("^[A-Fa-f0-9]{64}$"))
  ' "${dir}/.plan-txn.active/.ready")"
tamper_state_before="$(<"${dir}/session_state.json")"
tamper_pending_before="$(<"${dir}/pending_agents.jsonl")"
tamper_starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
tamper_plan_before="$(<"${dir}/current_plan.md")"
printf 'tampered rollback bytes\n' \
  >>"${dir}/.plan-txn.active/current_plan.md.file"
tamper_recovery_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" '' '' 1)"
assert_nonzero "hash-mismatched rollback snapshot refuses recovery" \
  "${tamper_recovery_rc}"
assert_eq "snapshot mismatch mutates no canonical state" \
  "${tamper_state_before}" "$(<"${dir}/session_state.json")"
assert_eq "snapshot mismatch mutates no canonical pending ledger" \
  "${tamper_pending_before}" "$(<"${dir}/pending_agents.jsonl")"
assert_eq "snapshot mismatch mutates no canonical start ledger" \
  "${tamper_starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "snapshot mismatch mutates no canonical plan" \
  "${tamper_plan_before}" "$(<"${dir}/current_plan.md")"
assert_eq "mismatched rollback authority remains visible" "1" \
  "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"

printf 'Planner WAL: corrupt active authority fails closed\n'
sid="plan-wal-corrupt"
native="native-plan-wal-corrupt"
lifecycle="dispatch-planwalcorruptabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
state_before="$(<"${dir}/session_state.json")"
pending_before="$(<"${dir}/pending_agents.jsonl")"
mkdir "${dir}/.plan-txn.active"
printf '{"schema_version":999}\n' >"${dir}/.plan-txn.active/.ready"
printf 'unrelated-sentinel\n' >"${dir}/unrelated.txt"
corrupt_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_nonzero "corrupt active journal refuses recovery" "${corrupt_rc}"
assert_eq "corrupt journal preserves unrelated state" "unrelated-sentinel" \
  "$(<"${dir}/unrelated.txt")"
assert_eq "corrupt journal preserves canonical state" "${state_before}" \
  "$(<"${dir}/session_state.json")"
assert_eq "corrupt journal preserves exact pending bytes" "${pending_before}" \
  "$(<"${dir}/pending_agents.jsonl")"
assert_eq "corrupt authority remains visible for repair" "1" \
  "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"

printf 'Planner rendezvous: hostile target shapes fail closed\n'
sid="plan-receipt-symlink"
native="native-plan-receipt-symlink"
lifecycle="dispatch-planreceiptsymlink"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
external_receipt="${TEST_HOME}/external-plan-receipt.jsonl"
printf 'external-receipt-sentinel\n' >"${external_receipt}"
ln -s "${external_receipt}" "${dir}/plan_publication_outcomes.jsonl"
receipt_symlink_rc="$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_nonzero "symlinked receipt target rejects planner publication" \
  "${receipt_symlink_rc}"
assert_eq "symlinked receipt target preserves external bytes" \
  "external-receipt-sentinel" "$(<"${external_receipt}")"
assert_eq "symlinked receipt target preserves causal start" "1" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"

sid="plan-waiter-symlink"
native="native-plan-waiter-symlink"
lifecycle="dispatch-planwaitersymlink"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
external_waiter="${TEST_HOME}/external-plan-waiter.jsonl"
printf 'external-waiter-sentinel\n' >"${external_waiter}"
ln -s "${external_waiter}" "${dir}/plan_summary_waiters.jsonl"
run_summary "${sid}" "${native}" "${ordinary_message}" 1
assert_eq "symlinked waiter target preserves external bytes" \
  "external-waiter-sentinel" "$(<"${external_waiter}")"
assert_eq "symlinked waiter target creates no summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "symlinked waiter target creates no parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "symlinked waiter target preserves pending" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

printf 'Planner recovery: waiter messages are content-bound and NUL-safe\n'
for waiter_corruption in modified nul; do
  sid="plan-waiter-integrity-${waiter_corruption}"
  native="native-plan-waiter-integrity-${waiter_corruption}"
  lifecycle="dispatch-planwaiterintegrity${waiter_corruption}"
  reset_session "${sid}" 0
  seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
  dir="${TEST_STATE_ROOT}/${sid}"
  run_summary "${sid}" "${native}" "${ordinary_message}"
  waiter_digest="$(jq -r '.completion_digest' \
    "${dir}/plan_summary_waiters.jsonl")"
  jq -nc --arg lifecycle "${lifecycle}" --arg native "${native}" \
      --arg digest "${waiter_digest}" '
    {schema_version:1,decided_at:101,lifecycle_dispatch_id:$lifecycle,
     agent_type:"quality-planner",native_agent_id:$native,
     completion_digest:$digest,status:"accepted",reason:"",
     verdict:"PLAN_READY",start_plan_revision:0,result_plan_revision:1}
  ' >"${dir}/plan_publication_outcomes.jsonl"
  if [[ "${waiter_corruption}" == "modified" ]]; then
    jq -c '.message += " tampered"' \
      "${dir}/plan_summary_waiters.jsonl" \
      >"${dir}/plan_summary_waiters.jsonl.tmp"
  else
    jq -c '.message += "\u0000"' \
      "${dir}/plan_summary_waiters.jsonl" \
      >"${dir}/plan_summary_waiters.jsonl.tmp"
  fi
  mv -f "${dir}/plan_summary_waiters.jsonl.tmp" \
    "${dir}/plan_summary_waiters.jsonl"
  waiter_before="$(<"${dir}/plan_summary_waiters.jsonl")"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  receipt_before="$(<"${dir}/plan_publication_outcomes.jsonl")"
  waiter_recovery_rc="$(run_plan \
    "${sid}" "${native}" "${ordinary_message}")"
  assert_nonzero "${waiter_corruption} waiter: recovery fails closed" \
    "${waiter_recovery_rc}"
  assert_eq "${waiter_corruption} waiter: authority stays unconsumed" \
    "${waiter_before}" "$(<"${dir}/plan_summary_waiters.jsonl")"
  assert_eq "${waiter_corruption} waiter: pending stays byte-exact" \
    "${pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "${waiter_corruption} waiter: start stays byte-exact" \
    "${starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${waiter_corruption} waiter: receipt stays byte-exact" \
    "${receipt_before}" "$(<"${dir}/plan_publication_outcomes.jsonl")"
  assert_eq "${waiter_corruption} waiter: no summary is replayed" "0" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${waiter_corruption} waiter: no parent outcome is published" \
    "0" "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
done

printf 'Planner/summary rendezvous: both hook orders and rejection\n'
sid="plan-rendezvous-summary-first"
native="native-plan-summary-first"
lifecycle="dispatch-plansummaryfirst"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${ordinary_message}"
summary_first_waiter="$(<"${dir}/plan_summary_waiters.jsonl")"
assert_eq "summary-first leaves one durable waiter" "1" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"
assert_eq "summary-first publishes no provisional summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary-first publishes no provisional parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first leaves plan generation unchanged" "0" \
  "$(jq -r '.plan_revision' "${dir}/session_state.json")"
assert_eq "plan hook accepts and replays the waiter" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "summary-first replay publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary-first replay publishes one accepted outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first replay consumes pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "summary-first replay consumes start" "0" \
  "$(jsonl_count "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "summary-first replay settles waiter" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

# Delivery receipts retain the consumed compact parent outcome at top level.
# A plan recovery pass can therefore settle an orphaned post-commit waiter even
# after foreground/background notification correlation removed the causal FIFO
# row, without repeating the plan publication.
printf '%s\n' "${summary_first_waiter}" \
  >"${dir}/plan_summary_waiters.jsonl"
jq -c '. as $outcome | $outcome + {
    notification_receipt:true,notification_kind:"task-notification",
    notification_key:"planner|orphan-receipt|completed",
    notification_agent_type:.agent_type,
    notification_status:"completed",
    notification_rejected_reason:"",
    notification_rebind_id:"",
    notification_retry_exhausted:false,
    notification_current_pending_preserved:false,
    completion_outcome:$outcome
  }' "${dir}/agent_completion_outcomes.jsonl" \
  >"${dir}/agent_completion_outcomes.receipt.jsonl"
mv -f "${dir}/agent_completion_outcomes.receipt.jsonl" \
  "${dir}/agent_completion_outcomes.jsonl"
assert_eq "receipt outcome: plan recovery succeeds" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}" '' '' 1)"
assert_eq "receipt outcome: plan orphan waiter settles" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"
assert_eq "receipt outcome: plan revision remains singular" "1" \
  "$(jq -r '.plan_revision' "${dir}/session_state.json")"

# Lifecycle/role/native/status alone are not a causal outcome. The strict
# producer parser must reject the fragment and leave the waiter untouched.
printf '%s\n' "${summary_first_waiter}" \
  >"${dir}/plan_summary_waiters.jsonl"
jq -nc --arg lifecycle "$(jq -r '.lifecycle_dispatch_id' \
    <<<"${summary_first_waiter}")" \
    --arg agent "$(jq -r '.agent_type' <<<"${summary_first_waiter}")" \
    --arg native "$(jq -r '.native_agent_id' <<<"${summary_first_waiter}")" '
      {lifecycle_dispatch_id:$lifecycle,agent_type:$agent,
       native_agent_id:$native,status:"accepted"}
    ' >"${dir}/agent_completion_outcomes.jsonl"
partial_outcome_rc=0
omc_causal_completion_outcomes_json_unlocked \
  "${dir}/agent_completion_outcomes.jsonl" >/dev/null 2>&1 \
  || partial_outcome_rc=$?
assert_nonzero "partial outcome: planner cleanup authority is rejected" \
  "${partial_outcome_rc}"
assert_eq "partial outcome: planner waiter remains protected" "1" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

sid="plan-rendezvous-summary-first-pending-noise"
native="native-plan-summary-first-pending-noise"
lifecycle="dispatch-plansummaryfirstnoise"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${ordinary_message}"
printf '%s\n' 'legacy-malformed-pending-noise' \
  >>"${dir}/pending_agents.jsonl"
assert_eq "pending noise: plan hook still accepts and replays" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "pending noise: exact pair publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "pending noise: exact pair publishes accepted outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "pending noise: exact valid pending row is consumed" "0" \
  "$(jq -Rsr '[split("\n")[] | select(length > 0)
      | (try fromjson catch null) | select(type == "object")] | length' \
    "${dir}/pending_agents.jsonl")"
assert_eq "pending noise: unrelated raw line is preserved" "1" \
  "$(grep -Fxc 'legacy-malformed-pending-noise' \
    "${dir}/pending_agents.jsonl" || true)"
assert_eq "pending noise: plan waiter is settled" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

sid="plan-rendezvous-plan-first"
native="native-plan-plan-first"
lifecycle="dispatch-planplanfirstabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "plan-first publication succeeds" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "plan-first creates no summary before universal hook" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
run_summary "${sid}" "${native}" "${ordinary_message}"
assert_eq "plan-first exact receipt authorizes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "plan-first exact receipt authorizes one outcome" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"

sid="plan-rendezvous-rejected"
native="native-plan-rejected"
lifecycle="dispatch-planrejectedabcd"
reset_session "${sid}" 1
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "stale plan rejection is a handled decision" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "rejected receipt records exact reason" "plan_generation_changed" \
  "$(jq -r '.reason' "${dir}/plan_publication_outcomes.jsonl")"
run_summary "${sid}" "${native}" "${ordinary_message}"
assert_eq "rejected plan creates no universal summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "rejected plan creates one ignored outcome" "ignored" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "rejected plan retires exact pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

sid="plan-rendezvous-rejected-summary-first"
native="native-plan-rejected-summary-first"
lifecycle="dispatch-planrejectsummary"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${ordinary_message}"
write_state "plan_revision" "1"
assert_eq "summary-first stale plan rejection is handled" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
assert_eq "rejected replay never publishes summary" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "rejected replay publishes ignored outcome" "ignored" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "rejected replay settles waiter" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

sid="plan-rendezvous-digest-mismatch"
native="native-plan-digest-mismatch"
lifecycle="dispatch-plandigestmismatch"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "digest fixture plan publishes" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
forged_message=$'1. Different replayed plan.\nVERDICT: PLAN_READY'
run_summary "${sid}" "${native}" "${forged_message}"
assert_eq "different message cannot reuse lifecycle receipt" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "authority mismatch publishes no misleading outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "authority mismatch preserves pending for repair" "1" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

sid="plan-rendezvous-secret-redaction"
native="native-plan-secret-redaction"
lifecycle="dispatch-plansecretredact"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
secret_token='sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX'
secret_message="Use ${secret_token} only in the private source, never persisted."$'\nVERDICT: PLAN_READY'
run_summary "${sid}" "${native}" "${secret_message}"
waiter_message="$(jq -r '.message' "${dir}/plan_summary_waiters.jsonl")"
assert_eq "summary-first waiter redacts provider secret" "0" \
  "$([[ "${waiter_message}" == *"${secret_token}"* ]] && printf 1 || printf 0)"
assert_eq "summary-first waiter records an explicit redaction" "1" \
  "$([[ "${waiter_message}" == *'<redacted-secret>'* ]] && printf 1 || printf 0)"
assert_eq "redacted digest still rendezvous-matches original callback" "0" \
  "$(run_plan "${sid}" "${native}" "${secret_message}")"
assert_eq "accepted deferred summary remains redacted" "0" \
  "$([[ "$(jq -r '.message' "${dir}/subagent_summaries.jsonl")" \
      == *"${secret_token}"* ]] && printf 1 || printf 0)"

printf 'Planner/summary rendezvous: outcome-gap crash recovery\n'
sid="plan-outcome-gap-summary-first"
native="native-plan-outcome-gap-summary-first"
lifecycle="dispatch-planoutcomegapsummary"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${ordinary_message}"
OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE=1
summary_first_gap_rc="$(run_plan \
  "${sid}" "${native}" "${ordinary_message}")"
unset OMC_TEST_PLAN_SUMMARY_KILL_AFTER_FINALIZE
assert_eq "summary-first replay kill leaves plan hook handled" "0" \
  "${summary_first_gap_rc}"
assert_eq "summary-first crash leaves effects-complete claim" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
assert_eq "summary-first crash leaves exact waiter" "1" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"
assert_eq "summary-first crash leaves exact receipt" "accepted" \
  "$(jq -r '.status' "${dir}/plan_publication_outcomes.jsonl")"
assert_eq "summary-first crash precedes parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
write_state "outcome_gap_probe" "summary-first"
assert_eq "next mutation replays summary-first outcome gap" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "summary-first recovery publishes one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "summary-first recovery settles pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "summary-first recovery settles waiter" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

sid="plan-outcome-gap-plan-first"
native="native-plan-outcome-gap-plan-first"
lifecycle="dispatch-planoutcomegapplanfirst"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "plan-first outcome-gap plan publishes" "0" \
  "$(run_plan "${sid}" "${native}" "${ordinary_message}")"
plan_first_gap_rc="$(run_agent_summary_rc "${sid}" "quality-planner" \
  "${native}" "${ordinary_message}" 0 1)"
assert_nonzero "plan-first summary kill is observable" "${plan_first_gap_rc}"
assert_eq "plan-first crash leaves effects-complete claim" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${dir}/pending_agents.jsonl")"
assert_eq "plan-first crash precedes parent outcome" "0" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
write_state "outcome_gap_probe" "plan-first"
assert_eq "next mutation replays plan-first outcome gap" "accepted" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "plan-first recovery keeps one summary" "1" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "plan-first recovery settles pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "plan-first recovery settles waiter" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"

printf 'Planner WAL and rendezvous: Definition publication boundaries\n'
definition1="$(definition_v1)"
definition2="$(definition_v2 "${definition1}")"
definition_message1="$(definition_message "${definition1}")"
definition_message2="$(definition_message "${definition2}")"

printf 'Planner scope transition: addition cap preserves idempotence authority\n'
sid="plan-scope-transition-cap"
native="native-plan-scope-cap-v1"
lifecycle="dispatch-planscopecapv1"
reset_session "${sid}" 0
write_state_batch \
  "quality_contract_required" "1" \
  "quality_contract_tracking_version" "1" \
  "quality_contract_prompt_revision" "1" \
  "quality_constitution_status" "disabled" \
  "quality_constitution_blocking_ids" "" \
  "current_objective" "Ship the exact planner publication transaction"
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "scope-cap base Definition publishes" "0" \
  "$(run_plan "${sid}" "${native}" "${definition_message1}")"
assert_eq "scope-cap base Definition artifact exists" "1" \
  "$([[ -f "${dir}/quality_contract.json" \
        && ! -L "${dir}/quality_contract.json" ]] \
      && printf 1 || printf 0)"
run_summary "${sid}" "${native}" "${definition_message1}" 1
scope_cap_prior_id="$(jq -r '.contract_id' \
  "${dir}/quality_contract.json" 2>/dev/null || true)"
write_state "quality_contract_scope_addition_digests" "dead-beef"
for scope_index in $(seq 1 20); do
  run_router "${sid}" \
    "continue and also add bounded migration stage ${scope_index} with rollback proof ${scope_index}"
done
scope_cap_transition_before="$(jq -r \
  '.quality_contract_scope_transition // empty' "${dir}/session_state.json")"
scope_cap_objective_before="$(jq -r '.current_objective' \
  "${dir}/session_state.json")"
scope_cap_ledger_before="$(jq -r \
  '.quality_contract_scope_addition_digests // empty' \
  "${dir}/session_state.json")"
assert_eq "20 admitted additions retain one anchored transition" "1" \
  "$(jq -r 'if type == "object" then 1 else 0 end' \
    <<<"${scope_cap_transition_before}")"
assert_eq "addition cap retains exact prior contract identity" \
  "${scope_cap_prior_id}" \
  "$(jq -r '.prior_contract_id' <<<"${scope_cap_transition_before}")"
assert_eq "addition cap binds latest merged objective" \
  "$(_quality_contract_digest "${scope_cap_objective_before}")" \
  "$(jq -r '.merged_objective_digest' \
    <<<"${scope_cap_transition_before}")"
assert_eq "transition retains every admitted addition at cap" "20" \
  "$(jq -r '.addition_digests | length' \
    <<<"${scope_cap_transition_before}")"
assert_eq "idempotence ledger retains every addition at cap" "20" \
  "$(jq -r '.quality_contract_scope_addition_digests | split(",") | length' \
    "${dir}/session_state.json")"
assert_eq "non-hex poisoned digest is ignored" "0" \
  "$([[ "$(jq -r '.quality_contract_scope_addition_digests' \
      "${dir}/session_state.json")" == *'dead-beef'* ]] \
    && printf 1 || printf 0)"
for retained_scope_index in 1 10 20; do
  assert_eq "exact merged objective retains scope marker ${retained_scope_index}" \
    "1" \
    "$([[ "${scope_cap_objective_before}" \
        == *"bounded migration stage ${retained_scope_index} with rollback proof ${retained_scope_index}"* ]] \
      && printf 1 || printf 0)"
done
scope_cap_router_output="$(run_router_output "${sid}" \
  "continue and also add bounded migration stage 21 with rollback proof 21")"
assert_eq "21st distinct addition leaves objective byte-for-byte unchanged" \
  "${scope_cap_objective_before}" "$(read_state "current_objective")"
assert_eq "21st distinct addition leaves digest ledger unchanged" \
  "${scope_cap_ledger_before}" \
  "$(read_state "quality_contract_scope_addition_digests")"
assert_eq "21st distinct addition leaves transition byte-for-byte unchanged" \
  "${scope_cap_transition_before}" \
  "$(read_state "quality_contract_scope_transition")"
assert_eq "21st distinct addition records idempotence-cap reason" \
  "scope-addition-idempotence-cap" \
  "$(jq -r '.quality_contract_scope_overflow | fromjson | .reason' \
    "${dir}/session_state.json")"
assert_eq "21st distinct addition records complete admitted count" "20" \
  "$(jq -r \
    '.quality_contract_scope_overflow | fromjson | .admitted_count' \
    "${dir}/session_state.json")"
assert_eq "addition-cap router asks for a fresh condensed replacement" "1" \
  "$([[ "${scope_cap_router_output}" \
      == *'fresh condensed objective that replaces the accumulated scope'* ]] \
    && printf 1 || printf 0)"

# A retry of the oldest accepted addition must remain a no-op even after the
# set is full. This is the authority property the former FIFO rollover lost.
run_router "${sid}" \
  "continue and also add bounded migration stage 1 with rollback proof 1"
assert_eq "oldest accepted retry leaves objective unchanged at cap" \
  "${scope_cap_objective_before}" "$(read_state "current_objective")"
assert_eq "oldest accepted retry leaves digest ledger unchanged at cap" \
  "${scope_cap_ledger_before}" \
  "$(read_state "quality_contract_scope_addition_digests")"
assert_eq "oldest accepted retry leaves transition unchanged at cap" \
  "${scope_cap_transition_before}" \
  "$(read_state "quality_contract_scope_transition")"
assert_eq "oldest accepted retry preserves fail-closed cap status" \
  "scope-overflow" "$(read_state "quality_contract_status")"

printf 'Planner scope transition: exact aggregate overflow fails closed\n'
overflow_base="$(printf '%118000s' '' | tr ' ' x)"
overflow_base="Ship the exact retained aggregate objective: ${overflow_base}"
overflow_ledger_before="$(_omc_authority_digest \
  'accepted-scope-ledger-entry')"
write_state_batch \
  "current_objective" "${overflow_base}" \
  "quality_contract_scope_addition_digests" "${overflow_ledger_before}" \
  "quality_contract_scope_transition" "" \
  "quality_contract_scope_overflow" ""
overflow_objective_before="$(read_state "current_objective")"
overflow_addition_body="$(printf '%10000s' '' | tr ' ' y)"
overflow_router_output="$(run_router_output "${sid}" \
  "continue and also add this exact overflow requirement ${overflow_addition_body}")"
assert_eq "overflow leaves authoritative objective byte-for-byte unchanged" \
  "${overflow_objective_before}" "$(read_state "current_objective")"
assert_eq "overflow leaves admitted digest ledger unchanged" \
  "${overflow_ledger_before}" \
  "$(read_state "quality_contract_scope_addition_digests")"
assert_eq "overflow records compact exact reason" \
  "aggregate-scope-bytes-exceeded" \
  "$(jq -r '.quality_contract_scope_overflow | fromjson | .reason' \
    "${dir}/session_state.json")"
assert_eq "overflow records fixed exact-scope ceiling" "122880" \
  "$(jq -r '.quality_contract_scope_overflow | fromjson | .limit_bytes' \
    "${dir}/session_state.json")"
assert_eq "overflow attempted bytes exceed ceiling" "1" \
  "$(jq -r '(.quality_contract_scope_overflow | fromjson)
      | if .attempted_bytes > .limit_bytes then 1 else 0 end' \
    "${dir}/session_state.json")"
assert_eq "overflow router asks for fresh condensed replacement" "1" \
  "$([[ "${overflow_router_output}" \
      == *'fresh condensed objective that replaces the accumulated scope'* ]] \
    && printf 1 || printf 0)"
overflow_plan_revision="$(read_state "plan_revision")"
overflow_prompt_revision="$(read_state "prompt_revision")"
overflow_generation="$(read_state "ulw_enforcement_generation")"
native="native-plan-scope-overflow"
lifecycle="dispatch-planscopeoverflowabcd"
seed_dispatch "${sid}" "${native}" "${lifecycle}" \
  "${overflow_plan_revision}" "${overflow_prompt_revision}" \
  "${overflow_generation}"
assert_eq "PLAN_READY is handled as an overflow rejection" "0" \
  "$(run_plan "${sid}" "${native}" "${definition_message2}")"
assert_eq "PLAN_READY overflow receipt has exact reason" \
  "quality_contract_scope_overflow" \
  "$(jq -r --arg lifecycle "${lifecycle}" \
    'select(.lifecycle_dispatch_id == $lifecycle) | .reason' \
    "${dir}/plan_publication_outcomes.jsonl")"
run_summary "${sid}" "${native}" "${definition_message2}" 1
overflow_pretool="$(run_pretool_output "${sid}" \
  "${TEST_HOME}/overflow-mutation.txt")"
assert_eq "overflow blocks mutation before planner retry" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' \
    <<<"${overflow_pretool}")"
assert_eq "overflow mutation block explains aggregate ceiling" "1" \
  "$([[ "${overflow_pretool}" == *'aggregate exact-scope ceiling'* ]] \
    && printf 1 || printf 0)"
fresh_scope_prompt="Replace the accumulated work with one concise objective: ship a compact verified planner transaction."
run_router "${sid}" "${fresh_scope_prompt}"
assert_eq "fresh replacement objective clears overflow tuple" "" \
  "$(read_state "quality_contract_scope_overflow")"
assert_eq "fresh replacement objective becomes authoritative" "1" \
  "$([[ "$(read_state "current_objective")" \
      == *'ship a compact verified planner transaction'* ]] \
    && printf 1 || printf 0)"

quality_index=0
for boundary in after-contract-publish after-quality-evidence-clear \
    after-quality-frontier-clear; do
  quality_index=$((quality_index + 1))
  sid="plan-quality-wal-${quality_index}"
  native="native-plan-quality-${quality_index}"
  lifecycle="dispatch-planquality${quality_index}abcd"
  reset_session "${sid}" 0
  write_state_batch \
    "quality_contract_required" "1" \
    "quality_contract_prompt_revision" "1" \
    "quality_constitution_status" "disabled" \
    "quality_constitution_blocking_ids" "" \
    "current_objective" "Ship the exact planner publication transaction"
  seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
  dir="${TEST_STATE_ROOT}/${sid}"
  printf '{"old":"evidence"}\n' >"${dir}/quality_evidence.jsonl"
  printf '{"old":"frontier"}\n' >"${dir}/quality_frontier.json"
  state_before="$(<"${dir}/session_state.json")"
  pending_before="$(<"${dir}/pending_agents.jsonl")"
  starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  plan_before="$(<"${dir}/current_plan.md")"
  kill_rc="$(run_plan "${sid}" "${native}" "${definition_message1}" \
    "${boundary}")"
  assert_nonzero "${boundary}: Definition process death is observable" \
    "${kill_rc}"
  run_summary "${sid}" "${native}" "${definition_message1}" 1
  assert_eq "${boundary}: provisional Definition creates no summary" "0" \
    "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
  assert_eq "${boundary}: provisional Definition creates no outcome" "0" \
    "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
  assert_eq "${boundary}: Definition recovery succeeds" "0" \
    "$(run_plan "${sid}" "${native}" "${definition_message1}" '' '' 1)"
  assert_old_generation "${boundary}" "${sid}" "${state_before}" \
    "${pending_before}" "${starts_before}" "${plan_before}"
  assert_eq "${boundary}: old evidence restored" '{"old":"evidence"}' \
    "$(<"${dir}/quality_evidence.jsonl")"
  assert_eq "${boundary}: old frontier restored" '{"old":"frontier"}' \
    "$(<"${dir}/quality_frontier.json")"
done

sid="plan-quality-history"
native="native-plan-quality-history-v1"
lifecycle="dispatch-planqualityhistory1"
reset_session "${sid}" 0
write_state_batch \
  "quality_contract_scope_transition" '{"transient":"scope"}' \
  "quality_contract_required" "1" \
  "quality_contract_prompt_revision" "1" \
  "quality_constitution_status" "disabled" \
  "quality_constitution_blocking_ids" "" \
  "current_objective" "Ship the exact planner publication transaction"
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
assert_eq "base Definition publishes for history fixture" "0" \
  "$(run_plan "${sid}" "${native}" "${definition_message1}")"
assert_eq "accepted Definition publication clears one-use transition" "" \
  "$(read_state "quality_contract_scope_transition")"
run_summary "${sid}" "${native}" "${definition_message1}"
dir="${TEST_STATE_ROOT}/${sid}"
base_contract="$(<"${dir}/quality_contract.json")"
base_state="$(<"${dir}/session_state.json")"
base_plan="$(<"${dir}/current_plan.md")"
base_summary_count="$(jsonl_count "${dir}/subagent_summaries.jsonl")"
base_outcome_count="$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
native="native-plan-quality-history-v2"
lifecycle="dispatch-planqualityhistory2"
seed_dispatch "${sid}" "${native}" "${lifecycle}" 1 1
pending_before="$(<"${dir}/pending_agents.jsonl")"
starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
history_kill_rc="$(run_plan "${sid}" "${native}" "${definition_message2}" \
  after-contract-history-publish)"
assert_nonzero "contract history process death is observable" \
  "${history_kill_rc}"
run_summary "${sid}" "${native}" "${definition_message2}" 1
assert_eq "provisional history publication creates no new summary" \
  "${base_summary_count}" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "provisional history publication creates no new outcome" \
  "${base_outcome_count}" \
  "$(jsonl_count "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "contract history recovery succeeds" "0" \
  "$(run_plan "${sid}" "${native}" "${definition_message2}" '' '' 1)"
assert_eq "contract history restores prior state" "${base_state}" \
  "$(<"${dir}/session_state.json")"
assert_eq "contract history restores prior plan" "${base_plan}" \
  "$(<"${dir}/current_plan.md")"
assert_eq "contract history restores prior contract" "${base_contract}" \
  "$(<"${dir}/quality_contract.json")"
assert_eq "contract history removes partial archive" "0" \
  "$(jsonl_count "${dir}/quality_contract_history.jsonl")"
assert_eq "contract history restores second pending" "${pending_before}" \
  "$(<"${dir}/pending_agents.jsonl")"
assert_eq "contract history restores second start" "${starts_before}" \
  "$(<"${dir}/agent_dispatch_starts.jsonl")"

# A bounded archive read failure must roll back every earlier publication in
# this second planner generation and preserve the source ledger byte-for-byte.
: >"${dir}/quality_contract_history.jsonl"
tail_state_before="$(<"${dir}/session_state.json")"
tail_plan_before="$(<"${dir}/current_plan.md")"
tail_contract_before="$(<"${dir}/quality_contract.json")"
tail_pending_before="$(<"${dir}/pending_agents.jsonl")"
tail_starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
set +e
history_tail_rc="$(OMC_TEST_PLAN_HISTORY_TAIL_FAULT=1 \
  run_plan "${sid}" "${native}" "${definition_message2}")"
set -e
assert_nonzero "contract history tail: read failure propagates" \
  "${history_tail_rc}"
assert_eq "contract history tail: state is byte-identical" \
  "${tail_state_before}" "$(<"${dir}/session_state.json")"
assert_eq "contract history tail: plan is byte-identical" \
  "${tail_plan_before}" "$(<"${dir}/current_plan.md")"
assert_eq "contract history tail: contract is byte-identical" \
  "${tail_contract_before}" "$(<"${dir}/quality_contract.json")"
assert_eq "contract history tail: pending authority is byte-identical" \
  "${tail_pending_before}" "$(<"${dir}/pending_agents.jsonl")"
assert_eq "contract history tail: start authority is byte-identical" \
  "${tail_starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
assert_eq "contract history tail: source ledger is not truncated" "0" \
  "$(wc -c <"${dir}/quality_contract_history.jsonl" | tr -d '[:space:]')"
assert_eq "contract history tail: active transaction is retired" "0" \
  "$([[ -e "${dir}/.plan-txn.active" \
      || -L "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"

for history_invalid_shape in malformed missing-final-newline; do
  case "${history_invalid_shape}" in
    malformed)
      printf '%s\n' '{"malformed_history":true}' \
        >"${dir}/quality_contract_history.jsonl"
      ;;
    missing-final-newline)
      jq -c '. + {archived_at:999,archive_reason:"contract-revision"}' \
        <<<"${tail_contract_before}" \
        | tr -d '\n' >"${dir}/quality_contract_history.jsonl"
      ;;
  esac
  invalid_history_state_before="$(<"${dir}/session_state.json")"
  invalid_history_plan_before="$(<"${dir}/current_plan.md")"
  invalid_history_contract_before="$(<"${dir}/quality_contract.json")"
  invalid_history_pending_before="$(<"${dir}/pending_agents.jsonl")"
  invalid_history_starts_before="$(<"${dir}/agent_dispatch_starts.jsonl")"
  invalid_history_source_before="$(shasum -a 256 \
    "${dir}/quality_contract_history.jsonl" | awk '{print $1}')"
  invalid_history_rc="$(run_plan \
    "${sid}" "${native}" "${definition_message2}")"
  assert_nonzero "contract history ${history_invalid_shape}: publication fails closed" \
    "${invalid_history_rc}"
  assert_eq "contract history ${history_invalid_shape}: state remains exact" \
    "${invalid_history_state_before}" "$(<"${dir}/session_state.json")"
  assert_eq "contract history ${history_invalid_shape}: plan remains exact" \
    "${invalid_history_plan_before}" "$(<"${dir}/current_plan.md")"
  assert_eq "contract history ${history_invalid_shape}: contract remains exact" \
    "${invalid_history_contract_before}" "$(<"${dir}/quality_contract.json")"
  assert_eq "contract history ${history_invalid_shape}: pending remains exact" \
    "${invalid_history_pending_before}" "$(<"${dir}/pending_agents.jsonl")"
  assert_eq "contract history ${history_invalid_shape}: start remains exact" \
    "${invalid_history_starts_before}" "$(<"${dir}/agent_dispatch_starts.jsonl")"
  assert_eq "contract history ${history_invalid_shape}: source bytes remain exact" \
    "${invalid_history_source_before}" \
    "$(shasum -a 256 "${dir}/quality_contract_history.jsonl" | awk '{print $1}')"
done

printf 'Planner/summary rendezvous: quality prompt revision rejection\n'
sid="plan-quality-prompt-rejected"
native="native-plan-quality-prompt-rejected"
lifecycle="dispatch-planqualityprompt"
reset_session "${sid}" 0
write_state_batch \
  "quality_contract_required" "1" \
  "quality_contract_prompt_revision" "2" \
  "quality_constitution_status" "disabled" \
  "quality_constitution_blocking_ids" "" \
  "current_objective" "Ship the exact planner publication transaction"
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
assert_eq "quality prompt mismatch is a handled rejection" "0" \
  "$(run_plan "${sid}" "${native}" "${definition_message1}")"
assert_eq "quality prompt mismatch has exact receipt reason" \
  "quality_contract_prompt_changed" \
  "$(jq -r '.reason' "${dir}/plan_publication_outcomes.jsonl")"
run_summary "${sid}" "${native}" "${definition_message1}"
assert_eq "quality prompt rejection creates no summary side effect" "0" \
  "$(jsonl_count "${dir}/subagent_summaries.jsonl")"
assert_eq "quality prompt rejection creates ignored outcome" "ignored" \
  "$(jq -r '.status' "${dir}/agent_completion_outcomes.jsonl")"
assert_eq "quality prompt rejection retires pending" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"

printf 'Dispatch admission recovery: compact/resume lifecycle fences\n'
sid="dispatch-admission-compact-fence"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' 'UNSAFE-PRECOMPACT-DISPATCH-BYTES' \
  >"${dir}/precompact_snapshot.md"
printf '%s\n' 'UNSAFE-COMPACT-HANDOFF-DISPATCH-BYTES' \
  >"${dir}/compact_handoff.md"
printf '%s\n' 'UNSAFE-COMPACT-DEBUG-DISPATCH-BYTES' \
  >"${dir}/compact_debug.log"
mkdir "${dir}/.dispatch-txn.interrupted"
touch "${dir}/.dispatch-txn.interrupted/.ready"
printf '%s\n' 'quality-reviewer' \
  >"${dir}/.dispatch-txn.interrupted/attempted-agent-type"
dispatch_compact_state_before="$(<"${dir}/session_state.json")"
set +e
dispatch_precompact_output="$(run_precompact_output "${sid}")"
dispatch_precompact_rc=$?
set -e
assert_nonzero "armed dispatch journal aborts PreCompact" \
  "${dispatch_precompact_rc}"
assert_eq "armed dispatch PreCompact emits no payload" "" \
  "${dispatch_precompact_output}"
assert_eq "armed dispatch PreCompact preserves prior snapshot" \
  "UNSAFE-PRECOMPACT-DISPATCH-BYTES" \
  "$(<"${dir}/precompact_snapshot.md")"
assert_eq "armed dispatch PreCompact preserves state bytes" \
  "${dispatch_compact_state_before}" "$(<"${dir}/session_state.json")"
set +e
dispatch_postcompact_output="$(run_postcompact_output "${sid}")"
dispatch_postcompact_rc=$?
set -e
assert_nonzero "armed dispatch journal aborts PostCompact" \
  "${dispatch_postcompact_rc}"
assert_eq "armed dispatch PostCompact emits no payload" "" \
  "${dispatch_postcompact_output}"
assert_eq "armed dispatch PostCompact preserves prior handoff" \
  "UNSAFE-COMPACT-HANDOFF-DISPATCH-BYTES" \
  "$(<"${dir}/compact_handoff.md")"
assert_eq "armed dispatch PostCompact preserves state bytes" \
  "${dispatch_compact_state_before}" "$(<"${dir}/session_state.json")"
dispatch_compact_output="$(run_compact_start_output "${sid}")"
assert_eq "compact SessionStart pauses on armed dispatch" "1" \
  "$([[ "${dispatch_compact_output}" \
      == *'Compact continuation paused because a prior Agent authorization was interrupted'* ]] \
    && printf 1 || printf 0)"
assert_eq "compact SessionStart does not inject unsafe snapshot" "0" \
  "$([[ "${dispatch_compact_output}" \
      == *'UNSAFE-PRECOMPACT-DISPATCH-BYTES'* ]] \
    && printf 1 || printf 0)"
dispatch_resume_output="$(run_resume_start_output "${sid}" "${sid}")"
assert_eq "resume-in-place pauses on armed dispatch" "1" \
  "$([[ "${dispatch_resume_output}" \
      == *'Resume paused because a prior Agent authorization was interrupted'* ]] \
    && printf 1 || printf 0)"
assert_eq "compact/resume fence retains armed journal" "1" \
  "$([[ -e "${dir}/.dispatch-txn.interrupted/.ready" ]] \
    && printf 1 || printf 0)"
dispatch_compact_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || dispatch_compact_reset_rc=$?
assert_eq "exact reset converges compact dispatch fence" "0" \
  "${dispatch_compact_reset_rc}"
for compact_artifact in precompact_snapshot.md compact_handoff.md \
    compact_debug.log; do
  assert_eq "exact reset removes stale ${compact_artifact}" "0" \
    "$([[ -e "${dir}/${compact_artifact}" \
          || -L "${dir}/${compact_artifact}" ]] \
      && printf 1 || printf 0)"
done
assert_eq "compact reset taints attempted dispatch identity" "1" \
  "$(grep -Fxc 'quality-reviewer' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
for tracking_key in subagent_dispatch_tracking_version \
    review_dispatch_tracking_version plan_dispatch_tracking_version \
    native_agent_id_tracking_version; do
  assert_eq "compact reset stamps ${tracking_key}" "1" \
    "$(jq -r --arg key "${tracking_key}" '.[$key] // empty' \
      "${dir}/session_state.json")"
done
dispatch_post_reset_start="$(run_compact_start_output "${sid}")"
assert_eq "post-reset SessionStart cannot inject stale compact bytes" "0" \
  "$([[ "${dispatch_post_reset_start}" \
      == *'UNSAFE-'* ]] && printf 1 || printf 0)"

printf 'Planner cold recovery: PreCompact handoff survives restart paths\n'
sid="plan-cold-precompact-compact"
native="native-plan-cold-precompact-compact"
lifecycle="dispatch-plancoldcompactabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
run_summary "${sid}" "${native}" "${ordinary_message}" 1
printf '%s\n' 'legacy-malformed-cold-pending-noise' \
  >>"${dir}/pending_agents.jsonl"
cold_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "cold compact fixture planner death is observable" \
  "${cold_kill_rc}"
set +e
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_PLAN_TXN_KILL_AT=after-cold-pending-tombstone \
  bash "${HOOK_DIR}/record-plan.sh" --recover-cold-resume "${sid}" \
  >/dev/null 2>&1
cold_tombstone_kill_rc=$?
set -e
assert_nonzero "cold pending-tombstone process death is observable" \
  "${cold_tombstone_kill_rc}"
assert_eq "cold pending-tombstone death retains rollback WAL" "1" \
  "$([[ -d "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
precompact_output="$(run_precompact_output "${sid}")"
assert_eq "PreCompact cold recovery returns no hook payload" "" \
  "${precompact_output}"
assert_eq "PreCompact retires fixed planner WAL" "0" \
  "$([[ -e "${dir}/.plan-txn.active" ]] && printf 1 || printf 0)"
assert_eq "PreCompact preserves one rollback-authenticated handoff" "1" \
  "$([[ -f "${dir}/plan_cold_recovery_handoff.json" ]] \
    && printf 1 || printf 0)"
cold_token="$(jq -r '.rebind_id' \
  "${dir}/plan_cold_recovery_handoff.json")"
cold_handoff_original="$(<"${dir}/plan_cold_recovery_handoff.json")"
cold_handoff_numeric="$(jq -c '.created_at = 1' \
  "${dir}/plan_cold_recovery_handoff.json")"
cold_handoff_prefix="${cold_handoff_numeric%%\"created_at\":1*}"
cold_handoff_suffix="${cold_handoff_numeric#*\"created_at\":1}"
printf '%s"created_at":1\0%s\n' \
  "${cold_handoff_prefix}" "${cold_handoff_suffix}" \
  >"${dir}/plan_cold_recovery_handoff.json"
cold_handoff_raw_rc=0
omc_read_plan_cold_recovery_handoff "${sid}" \
  >/dev/null 2>&1 || cold_handoff_raw_rc=$?
assert_nonzero "cold handoff rejects raw-NUL timestamp authority" \
  "${cold_handoff_raw_rc}"
printf '%s\n' "${cold_handoff_original}" \
  >"${dir}/plan_cold_recovery_handoff.json"
assert_eq "cold rollback tombstones exact pending" "true" \
  "$(jq -Rsr --arg lifecycle "${lifecycle}" '
      [split("\n")[] | select(length > 0)
        | (try fromjson catch null) | select(type == "object")
        | select(.lifecycle_dispatch_id == $lifecycle)]
      | if length == 1 then (.[0].review_dispatch_abandoned // false)
        else false end
    ' "${dir}/pending_agents.jsonl")"
assert_eq "cold rollback preserves unrelated pending noise" "1" \
  "$(grep -Fxc 'legacy-malformed-cold-pending-noise' \
    "${dir}/pending_agents.jsonl" || true)"
assert_eq "cold rollback tombstones exact start" "true" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${dir}/agent_dispatch_starts.jsonl")"
assert_eq "cold rollback removes summary-first waiter" "0" \
  "$(jsonl_count "${dir}/plan_summary_waiters.jsonl")"
compact_recovery_output="$(run_compact_start_output "${sid}")"
assert_eq "compact restart surfaces exact cold rebind token" "1" \
  "$([[ "${compact_recovery_output}" == *"[review-rebind:${cold_token}]"* ]] \
    && printf 1 || printf 0)"
assert_eq "first compact delivery keeps unregistered handoff" "1" \
  "$([[ -f "${dir}/plan_cold_recovery_handoff.json" ]] \
    && printf 1 || printf 0)"
printf '%s\tregistered-test-dispatch\n' "${cold_token}" \
  >"${dir}/dispatch_rebind_ids.log"
run_precompact_output "${sid}" >/dev/null
second_compact_output="$(run_compact_start_output "${sid}")"
assert_eq "registered cold token is not emitted twice" "0" \
  "$([[ "${second_compact_output}" == *"[review-rebind:${cold_token}]"* ]] \
    && printf 1 || printf 0)"
assert_eq "registered compact handoff is retired" "0" \
  "$([[ -e "${dir}/plan_cold_recovery_handoff.json" ]] \
    && printf 1 || printf 0)"
assert_eq "second compact uses a fresh manifest" "0" \
  "$([[ "${second_compact_output}" == *'pre-recovery compact manifest was deliberately omitted'* ]] \
    && printf 1 || printf 0)"

# Each cold-recovery publication boundary must leave a self-validating WAL.
# This includes both causal tombstones, the handoff publication, and the
# subtle window where `.ready` authorizes the candidate seal but the marker
# still contains the old bytes.
for cold_boundary in \
    after-cold-start-tombstone \
    after-cold-handoff-stage \
    after-cold-pending-ready-seal-before-marker-rename; do
  cold_slug="${cold_boundary//[^A-Za-z0-9]/-}"
  sid="plan-cold-boundary-${cold_slug}"
  native="native-${cold_slug}"
  lifecycle="dispatch-${cold_slug}"
  reset_session "${sid}" 0
  seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
  dir="${TEST_STATE_ROOT}/${sid}"
  run_summary "${sid}" "${native}" "${ordinary_message}" 1
  cold_fixture_rc="$(run_plan "${sid}" "${native}" \
    "${ordinary_message}" after-plan-publish)"
  assert_nonzero "${cold_boundary}: planner fixture death is observable" \
    "${cold_fixture_rc}"
  set +e
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_TEST_PLAN_TXN_KILL_AT="${cold_boundary}" \
    bash "${HOOK_DIR}/record-plan.sh" --recover-cold-resume "${sid}" \
    >/dev/null 2>&1
  cold_boundary_rc=$?
  set -e
  assert_nonzero "${cold_boundary}: injected cold recovery death is observable" \
    "${cold_boundary_rc}"
  assert_eq "${cold_boundary}: fixed rollback WAL remains authoritative" "1" \
    "$([[ -d "${dir}/.plan-txn.active" \
          && ! -L "${dir}/.plan-txn.active" ]] \
      && printf 1 || printf 0)"
  run_precompact_output "${sid}" >/dev/null
  assert_eq "${cold_boundary}: retry retires the fixed WAL" "0" \
    "$([[ -e "${dir}/.plan-txn.active" \
          || -L "${dir}/.plan-txn.active" ]] \
      && printf 1 || printf 0)"
  assert_eq "${cold_boundary}: retry publishes one valid handoff" "true" \
    "$(jq -r '
      .schema_version == 1 and .status == "pending"
      and (.rebind_id
        | test("^rebind-resume-([A-Fa-f0-9]{24}|[A-Fa-f0-9]{20}-[1-9])$"))
    ' "${dir}/plan_cold_recovery_handoff.json")"
  assert_eq "${cold_boundary}: retry tombstones exact pending row" "true" \
    "$(jq -r '.review_dispatch_abandoned // false' \
      "${dir}/pending_agents.jsonl")"
  assert_eq "${cold_boundary}: retry tombstones exact start row" "true" \
    "$(jq -r '.review_dispatch_abandoned // false' \
      "${dir}/agent_dispatch_starts.jsonl")"
done

sid="plan-cold-precompact-resume"
native="native-plan-cold-precompact-resume"
lifecycle="dispatch-plancoldresumeabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
resume_cold_kill_rc="$(run_plan "${sid}" "${native}" \
  "${ordinary_message}" after-plan-publish)"
assert_nonzero "cold resume fixture planner death is observable" \
  "${resume_cold_kill_rc}"
run_precompact_output "${sid}" >/dev/null
resume_cold_token="$(jq -r '.rebind_id' \
  "${dir}/plan_cold_recovery_handoff.json")"
resume_recovery_output="$(run_resume_start_output "${sid}" "${sid}")"
assert_eq "resume without compact callback surfaces cold token" "1" \
  "$([[ "${resume_recovery_output}" \
      == *"[review-rebind:${resume_cold_token}]"* ]] \
    && printf 1 || printf 0)"
assert_eq "first resume keeps unregistered handoff" "1" \
  "$([[ -f "${dir}/plan_cold_recovery_handoff.json" ]] \
    && printf 1 || printf 0)"
printf '%s\tregistered-test-dispatch\n' "${resume_cold_token}" \
  >"${dir}/dispatch_rebind_ids.log"
second_resume_output="$(run_resume_start_output "${sid}" "${sid}")"
assert_eq "registered resume token is not emitted twice" "0" \
  "$([[ "${second_resume_output}" \
      == *"[review-rebind:${resume_cold_token}]"* ]] \
    && printf 1 || printf 0)"
assert_eq "registered resume handoff is retired" "0" \
  "$([[ -e "${dir}/plan_cold_recovery_handoff.json" ]] \
    && printf 1 || printf 0)"

printf 'Planner resume: dormant receipt-only source converges before copy\n'
source_sid="plan-resume-receipt-source"
source_native="native-plan-resume-receipt-source"
source_lifecycle="dispatch-planresumereceiptsrc"
reset_session "${source_sid}" 0
seed_dispatch "${source_sid}" "${source_native}" \
  "${source_lifecycle}" 0 1
source_dir="${TEST_STATE_ROOT}/${source_sid}"
assert_eq "receipt-only source plan publishes" "0" \
  "$(run_plan "${source_sid}" "${source_native}" "${ordinary_message}")"
source_summary_kill_rc="$(run_agent_summary_rc "${source_sid}" \
  "quality-planner" "${source_native}" "${ordinary_message}" 0 1)"
assert_nonzero "receipt-only source summary death is observable" \
  "${source_summary_kill_rc}"
assert_eq "receipt-only source starts unresolved" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "${source_dir}/pending_agents.jsonl")"
target_sid="plan-resume-receipt-target"
reset_session "${target_sid}" 0
target_dir="${TEST_STATE_ROOT}/${target_sid}"
resume_receipt_output="$(run_resume_start_output \
  "${target_sid}" "${source_sid}")"
assert_eq "source recovery settles receipt-only pending" "0" \
  "$(jsonl_count "${source_dir}/pending_agents.jsonl")"
assert_eq "source recovery settles receipt-only waiter" "0" \
  "$(jsonl_count "${source_dir}/plan_summary_waiters.jsonl")"
assert_eq "source recovery commits accepted parent outcome" "accepted" \
  "$(jq -r '.status' "${source_dir}/agent_completion_outcomes.jsonl")"
assert_eq "resume target inherits one settled summary" "1" \
  "$(jsonl_count "${target_dir}/subagent_summaries.jsonl")"
assert_eq "resume source did not emit ownership conflict" "0" \
  "$([[ "${resume_receipt_output}" == *'source session remains authoritative'* ]] \
    && printf 1 || printf 0)"

printf 'Planner receipts: waiter-only recovery authority survives lock race\n'
sid="plan-receipt-waiter-lock-race"
native="native-plan-receipt-waiter-race"
lifecycle="dispatch-planreceiptwaiterrace"
old_lifecycle="dispatch-planreceiptwaiterold1"
old_native="native-plan-receipt-waiter-old"
old_digest="$(_omc_token_digest "old planner summary")"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
old_waiter="$(jq -nc --arg lifecycle "${old_lifecycle}" \
    --arg native "${old_native}" \
    --arg digest "${old_digest}" --arg message "old planner summary" '
  {schema_version:1,created_at:100,lifecycle_dispatch_id:$lifecycle,
   agent_type:"quality-planner",native_agent_id:$native,
   completion_digest:$digest,message:$message}
')"
old_receipt="$(jq -nc --arg lifecycle "${old_lifecycle}" \
    --arg native "${old_native}" \
    --arg digest "${old_digest}" '
  {schema_version:1,decided_at:100,lifecycle_dispatch_id:$lifecycle,
   agent_type:"quality-planner",native_agent_id:$native,
   completion_digest:$digest,status:"accepted",reason:"",verdict:"PLAN_READY",
   start_plan_revision:0,result_plan_revision:1}
')"
assert_eq "waiter lock race: sibling planner publication succeeds" "0" \
  "$(run_plan_after_entry_recovery \
    "${sid}" "${native}" "${ordinary_message}" \
    "${old_waiter}" "${old_receipt}")"
assert_eq "waiter lock race: protected and current receipts remain" "2" \
  "$(jsonl_count "${dir}/plan_publication_outcomes.jsonl")"
assert_eq "waiter lock race: orphan receipt remains recoverable" "1" \
  "$(jq -s --arg lifecycle "${old_lifecycle}" '
      [.[] | select(.lifecycle_dispatch_id == $lifecycle)] | length
    ' "${dir}/plan_publication_outcomes.jsonl")"

printf 'Dispatch admission recovery: pre-ready and ready process deaths\n'
for dispatch_kill_at in after-intent after-ready; do
  sid="dispatch-kill-${dispatch_kill_at}"
  reset_session "${sid}" 0
  dir="${TEST_STATE_ROOT}/${sid}"
  printf '%s\n' '1' >"${dir}/.ulw_active"
  dispatch_kill_payload="$(jq -nc --arg sid "${sid}" '
    {session_id:$sid,tool_name:"Agent",
     tool_input:{subagent_type:"general-purpose",
       description:"exercise interrupted admission recovery",
       prompt:"inspect the exact lifecycle"}}
  ')"
  set +e
  printf '%s' "${dispatch_kill_payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_DISPATCH_KILL_AT="${dispatch_kill_at}" \
      bash "${HOOK_DIR}/record-pending-agent.sh" >/dev/null 2>&1
  dispatch_kill_rc=$?
  set -e
  assert_nonzero "${dispatch_kill_at} process death is observable" \
    "${dispatch_kill_rc}"
  dispatch_txn_count="$(find "${dir}" -maxdepth 1 -type d \
    -name '.dispatch-txn.*' | wc -l | tr -d '[:space:]')"
  assert_eq "${dispatch_kill_at} retains one dispatch intent" "1" \
    "${dispatch_txn_count}"
  dispatch_txn_path="$(find "${dir}" -maxdepth 1 -type d \
    -name '.dispatch-txn.*' | head -n 1)"
  assert_eq "${dispatch_kill_at} records attempted identity first" \
    "general-purpose" "$({ cat "${dispatch_txn_path}/attempted-agent-type" \
      2>/dev/null || true; })"
  dispatch_ready_expected=0
  [[ "${dispatch_kill_at}" == "after-ready" ]] && dispatch_ready_expected=1
  assert_eq "${dispatch_kill_at} ready marker matches crash boundary" \
    "${dispatch_ready_expected}" \
    "$([[ -e "${dispatch_txn_path}/.ready" ]] && printf 1 || printf 0)"
  assert_eq "${dispatch_kill_at} intent globally requires recovery" "0" \
    "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
         printf 0
       else
         printf 1
       fi)"

  dispatch_kill_reset_rc=0
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
    >/dev/null 2>&1 || dispatch_kill_reset_rc=$?
  assert_eq "${dispatch_kill_at} exact reset converges" "0" \
    "${dispatch_kill_reset_rc}"
  assert_eq "${dispatch_kill_at} reset retires transaction" "0" \
    "$(find "${dir}" -maxdepth 1 \
      \( -name '.dispatch-txn.*' -o -name '.deactivate-txn.*' \) \
      | wc -l | tr -d '[:space:]')"
  assert_eq "${dispatch_kill_at} reset taints attempted identity" "1" \
    "$(grep -Fxc 'general-purpose' \
      "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
  for tracking_key in subagent_dispatch_tracking_version \
      review_dispatch_tracking_version plan_dispatch_tracking_version \
      native_agent_id_tracking_version; do
    assert_eq "${dispatch_kill_at} reset stamps ${tracking_key}" "1" \
      "$(jq -r --arg key "${tracking_key}" '.[$key] // empty' \
        "${dir}/session_state.json")"
  done
done

printf 'Dispatch admission retirement: settled deaths are inert\n'
for dispatch_settled_shape in success compensated; do
  sid="dispatch-settled-${dispatch_settled_shape}"
  reset_session "${sid}" 0
  dir="${TEST_STATE_ROOT}/${sid}"
  printf '%s\n' '1' >"${dir}/.ulw_active"
  dispatch_settled_agent="general-purpose"
  dispatch_body_fault=""
  if [[ "${dispatch_settled_shape}" == "compensated" ]]; then
    dispatch_body_fault="after-publish"
    dispatch_compensated_before="$(state_artifact_manifest "${dir}" \
      session_state.json pending_agents.jsonl agent_dispatch_starts.jsonl \
      council_dispatches.jsonl council_coverage.json \
      dispatch_tainted_identities.log dispatch_rebind_ids.log)"
  fi
  dispatch_settled_payload="$(jq -nc --arg sid "${sid}" \
    --arg agent "${dispatch_settled_agent}" '
      {session_id:$sid,tool_name:"Agent",
       tool_input:{subagent_type:$agent,
         description:"exercise atomic settled retirement",prompt:"inspect"}}
  ')"
  dispatch_settled_output="${TEST_HOME}/${sid}.out"
  set +e
  printf '%s' "${dispatch_settled_payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_TEST_DISPATCH_BODY_FAULT="${dispatch_body_fault}" \
      OMC_TEST_DISPATCH_KILL_AT=after-settled \
      bash "${HOOK_DIR}/record-pending-agent.sh" \
      >"${dispatch_settled_output}" 2>/dev/null
  dispatch_settled_rc=$?
  set -e
  assert_nonzero "${dispatch_settled_shape} settled death is observable" \
    "${dispatch_settled_rc}"
  assert_eq "${dispatch_settled_shape} leaves no active dispatch journal" "0" \
    "$(find "${dir}" -maxdepth 1 -name '.dispatch-txn.*' \
      | wc -l | tr -d '[:space:]')"
  assert_eq "${dispatch_settled_shape} leaves one inert settled journal" "1" \
    "$(find "${dir}" -maxdepth 1 -type d -name '.dispatch-settled.*' \
      | wc -l | tr -d '[:space:]')"
  assert_eq "${dispatch_settled_shape} settled journal does not fence tools" "1" \
    "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
         printf 0
       else
         printf 1
       fi)"
  if [[ "${dispatch_settled_shape}" == "compensated" ]]; then
    assert_eq "compensated retirement occurs only after deny response" "deny" \
      "$(jq -r '.hookSpecificOutput.permissionDecision // empty' \
        "${dispatch_settled_output}" 2>/dev/null || true)"
    assert_eq "compensated retirement restores every snapshotted artifact byte" \
      "${dispatch_compensated_before}" \
      "$(state_artifact_manifest "${dir}" \
        session_state.json pending_agents.jsonl agent_dispatch_starts.jsonl \
        council_dispatches.jsonl council_coverage.json \
        dispatch_tainted_identities.log dispatch_rebind_ids.log)"
  fi
  dispatch_expected_pending=1
  [[ "${dispatch_settled_shape}" != "compensated" ]] \
    || dispatch_expected_pending=0
  assert_eq "${dispatch_settled_shape} preserves exact causal admission state" \
    "${dispatch_expected_pending}" \
    "$(jsonl_count "${dir}/pending_agents.jsonl")"
  jq -nc --arg sid "${sid}" '
    {session_id:$sid,tool_name:"Agent",
     tool_input:{subagent_type:"frontend-developer",
       description:"clean prior inert retirement",prompt:"inspect"}}
  ' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/record-pending-agent.sh" >/dev/null 2>&1
  assert_eq "${dispatch_settled_shape} next admission reaps inert journal" "0" \
    "$(find "${dir}" -maxdepth 1 -name '.dispatch-settled.*' \
      | wc -l | tr -d '[:space:]')"
done

printf 'Dispatch admission retirement: pre-deny death remains fenced\n'
sid="dispatch-denial-before-retirement"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
jq -nc --arg sid "${sid}" '
  {session_id:$sid,tool_name:"Agent",
   tool_input:{subagent_type:"quality-reviewer",
     description:"seed the duplicate denial fixture",prompt:"inspect"}}
' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/record-pending-agent.sh" >/dev/null 2>&1
dispatch_pre_deny_output="${TEST_HOME}/${sid}.out"
set +e
jq -nc --arg sid "${sid}" '
  {session_id:$sid,tool_name:"Agent",
   tool_input:{subagent_type:"quality-reviewer",
     description:"deny before retirement",prompt:"inspect"}}
' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_DISPATCH_KILL_AT=after-deny-output \
  bash "${HOOK_DIR}/record-pending-agent.sh" \
  >"${dispatch_pre_deny_output}" 2>/dev/null
dispatch_pre_deny_rc=$?
set -e
assert_nonzero "pre-retirement denial death is observable" \
  "${dispatch_pre_deny_rc}"
assert_eq "pre-retirement death already emitted complete deny response" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' \
    "${dispatch_pre_deny_output}" 2>/dev/null || true)"
assert_eq "pre-retirement denial retains active launch-uncertainty fence" "1" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.dispatch-txn.*' \
    | wc -l | tr -d '[:space:]')"
assert_eq "pre-retirement denial globally fences native binding" "0" \
  "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
       printf 0
     else
       printf 1
     fi)"
assert_eq "pre-retirement denial preserves original unbound row" "" \
  "$(jq -r '.native_agent_id // empty' "${dir}/pending_agents.jsonl")"
dispatch_pre_deny_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || dispatch_pre_deny_reset_rc=$?
assert_eq "pre-retirement denial exact reset converges" "0" \
  "${dispatch_pre_deny_reset_rc}"
assert_eq "pre-retirement denial reset retires fence" "0" \
  "$(find "${dir}" -maxdepth 1 \
    \( -name '.dispatch-txn.*' -o -name '.deactivate-txn.*' \) \
    | wc -l | tr -d '[:space:]')"

printf 'Dispatch admission recovery: setup failure stays fenced until deny\n'
sid="dispatch-setup-failure-before-retirement"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
dispatch_setup_output="${TEST_HOME}/${sid}.out"
set +e
jq -nc --arg sid "${sid}" '
  {session_id:$sid,tool_name:"Agent",
   tool_input:{subagent_type:"general-purpose",
     description:"fail snapshot setup",prompt:"inspect"}}
' | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_DISPATCH_SETUP_FAULT=snapshot-copy \
  OMC_TEST_DISPATCH_KILL_AT=after-deny-output \
  bash "${HOOK_DIR}/record-pending-agent.sh" \
  >"${dispatch_setup_output}" 2>/dev/null
dispatch_setup_rc=$?
set -e
assert_nonzero "setup failure pre-retirement death is observable" \
  "${dispatch_setup_rc}"
assert_eq "setup failure emits complete deny before retirement" "deny" \
  "$(jq -r '.hookSpecificOutput.permissionDecision // empty' \
    "${dispatch_setup_output}" 2>/dev/null || true)"
assert_eq "setup failure retains active admission intent" "1" \
  "$(find "${dir}" -maxdepth 1 -type d -name '.dispatch-txn.*' \
    | wc -l | tr -d '[:space:]')"
assert_eq "setup failure publishes no causal pending row" "0" \
  "$(jsonl_count "${dir}/pending_agents.jsonl")"
assert_eq "setup failure globally fences later hooks" "0" \
  "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
       printf 0
     else
       printf 1
     fi)"
dispatch_setup_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || dispatch_setup_reset_rc=$?
assert_eq "setup failure exact reset converges" "0" \
  "${dispatch_setup_reset_rc}"
assert_eq "setup failure reset taints attempted identity" "1" \
  "$(grep -Fxc 'general-purpose' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"

printf 'Dispatch admission recovery: exact reset survives provisional state loss\n'
for dispatch_state_shape in off malformed missing; do
  sid="dispatch-reset-state-${dispatch_state_shape}"
  reset_session "${sid}" 0
  dir="${TEST_STATE_ROOT}/${sid}"
  printf '%s\n' '1' >"${dir}/.ulw_active"
  mkdir "${dir}/.dispatch-txn.interrupted"
  printf '%s\n' "state-${dispatch_state_shape}-agent" \
    >"${dir}/.dispatch-txn.interrupted/attempted-agent-type"
  case "${dispatch_state_shape}" in
    off)
      jq '.workflow_mode="" | .ulw_enforcement_active="0"' \
        "${dir}/session_state.json" >"${dir}/session_state.json.tmp"
      mv "${dir}/session_state.json.tmp" "${dir}/session_state.json"
      ;;
    malformed)
      printf '%s\n' 'not-json-reset-fixture' >"${dir}/session_state.json"
      ;;
    missing)
      rm -f "${dir}/session_state.json"
      ;;
  esac
  dispatch_state_reset_rc=0
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
    >/dev/null 2>&1 || dispatch_state_reset_rc=$?
  assert_eq "${dispatch_state_shape} state exact reset converges" "0" \
    "${dispatch_state_reset_rc}"
  assert_eq "${dispatch_state_shape} state reset publishes valid JSON" "0" \
    "$(jq empty "${dir}/session_state.json" >/dev/null 2>&1; printf $?)"
  assert_eq "${dispatch_state_shape} state reset closes enforcement" "0" \
    "$(jq -r '.ulw_enforcement_active // empty' \
      "${dir}/session_state.json")"
  assert_eq "${dispatch_state_shape} state reset retires direct intent" "0" \
    "$([[ -e "${dir}/.dispatch-txn.interrupted" \
          || -L "${dir}/.dispatch-txn.interrupted" ]] \
      && printf 1 || printf 0)"
  assert_eq "${dispatch_state_shape} state reset taints identity" "1" \
    "$(grep -Fxc "state-${dispatch_state_shape}-agent" \
      "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
done

printf 'Dispatch recovery: interrupted exact reset retains its fence\n'
sid="dispatch-deactivate-crash-recovery"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
mkdir "${dir}/.dispatch-txn.interrupted"
touch "${dir}/.dispatch-txn.interrupted/.ready"
printf '%s\n' 'quality-reviewer' \
  >"${dir}/.dispatch-txn.interrupted/attempted-agent-type"
set +e
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_DEACTIVATE_KILL_AT=after-journal-stage \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1
deactivate_kill_rc=$?
set -e
assert_nonzero "deactivation process death is observable" \
  "${deactivate_kill_rc}"
assert_eq "deactivation death keeps state active" "1" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "deactivation death moved direct journal into quarantine" "0" \
  "$([[ -e "${dir}/.dispatch-txn.interrupted" ]] \
    && printf 1 || printf 0)"
assert_eq "mid-reset quarantine remains a global dispatch fence" "0" \
  "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
       printf 0
     else
       printf 1
     fi)"
deactivate_retry_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || deactivate_retry_rc=$?
assert_eq "exact reset retry converges interrupted quarantine" "0" \
  "${deactivate_retry_rc}"
assert_eq "reset retry closes enforcement" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "reset retry removes every deactivation quarantine" "0" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    -type d | wc -l | tr -d '[:space:]')"
assert_eq "reset retry removes armed dispatch journal" "0" \
  "$([[ -e "${dir}/.dispatch-txn.interrupted" ]] \
    && printf 1 || printf 0)"
assert_eq "reset retry taints interrupted attempted identity" "1" \
  "$(grep -Fxc 'quality-reviewer' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"

printf 'Dispatch recovery: duplicate quarantine basenames remain convergent\n'
sid="dispatch-deactivate-duplicate-basename"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
mkdir -p "${dir}/.deactivate-txn.recovered/journals/.dispatch-txn.same" \
  "${dir}/.dispatch-txn.same"
printf '%s\n' '1' \
  >"${dir}/.deactivate-txn.recovered/.enforcement-generation"
printf '%s\n' 'prior-quarantined-agent' \
  >"${dir}/.deactivate-txn.recovered/journals/.dispatch-txn.same/attempted-agent-type"
printf '%s\n' 'direct-colliding-agent' \
  >"${dir}/.dispatch-txn.same/attempted-agent-type"
duplicate_basename_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || duplicate_basename_reset_rc=$?
assert_eq "duplicate journal basenames do not wedge exact reset" "0" \
  "${duplicate_basename_reset_rc}"
assert_eq "duplicate-basename reset closes enforcement" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "duplicate-basename reset retires all quarantine" "0" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    | wc -l | tr -d '[:space:]')"
assert_eq "duplicate-basename reset taints prior identity" "1" \
  "$(grep -Fxc 'prior-quarantined-agent' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
assert_eq "duplicate-basename reset taints direct identity" "1" \
  "$(grep -Fxc 'direct-colliding-agent' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"

printf 'Dispatch recovery: duplicate transient basenames remain convergent\n'
sid="dispatch-deactivate-duplicate-transient"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
mkdir -p "${dir}/.deactivate-txn.recovered/journals"
printf '%s\n' '1' \
  >"${dir}/.deactivate-txn.recovered/.enforcement-generation"
jq -nc '{agent_type:"prior-quarantined-specialist",
  lifecycle_dispatch_id:"prior-quarantined-lifecycle",ts:1,
  review_dispatch_abandoned:false}' \
  >"${dir}/.deactivate-txn.recovered/pending_agents.jsonl"
jq -nc '{agent_type:"recreated-live-specialist",
  lifecycle_dispatch_id:"recreated-live-lifecycle",ts:2,
  review_dispatch_abandoned:false}' \
  >"${dir}/pending_agents.jsonl"
duplicate_transient_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || duplicate_transient_reset_rc=$?
assert_eq "duplicate transient basenames do not wedge exact reset" "0" \
  "${duplicate_transient_reset_rc}"
assert_eq "duplicate-transient reset closes enforcement" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "duplicate-transient reset retires all quarantine" "0" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    | wc -l | tr -d '[:space:]')"
assert_eq "duplicate-transient reset taints quarantined identity" "1" \
  "$(grep -Fxc 'prior-quarantined-specialist' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
assert_eq "duplicate-transient reset taints recreated live identity" "1" \
  "$(grep -Fxc 'recreated-live-specialist' \
    "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"

printf 'Dispatch recovery: inactive exact reset reaps settled snapshots\n'
sid="dispatch-deactivate-inactive-settled"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
write_state_batch "workflow_mode" "" "ulw_enforcement_active" "0"
mkdir "${dir}/.dispatch-settled.one" \
  "${dir}/.native-bind-settled.two" \
  "${dir}/.plan-txn.stage.three" \
  "${dir}/.plan-txn.committed.four" \
  "${dir}/.plan-txn.recovered.five" \
  "${dir}/.reviewer-transaction.prepare.six" \
  "${dir}/.reviewer-transaction.committed.seven" \
  "${dir}/.plan-txn.active" \
  "${dir}/.reviewer-transaction.wal"
printf '%s\n' 'quality-reviewer' \
  >"${dir}/.dispatch-settled.one/attempted-agent-type"
printf '%s\n' '{"schema_version":1,"status":"settled"}' \
  >"${dir}/.dispatch-settled.one/.ready"
cp "${dir}/session_state.json" \
  "${dir}/.native-bind-settled.two/session_state.json.file"
: >"${dir}/.native-bind-settled.two/pending_agents.jsonl.absent"
: >"${dir}/.native-bind-settled.two/agent_dispatch_starts.jsonl.absent"
: >"${dir}/.native-bind-settled.two/native_agent_bindings.jsonl.absent"
printf '%s\n' 'staged planner snapshot' \
  >"${dir}/.plan-txn.stage.three/current_plan.md"
printf '%s\n' '{"schema_version":1,"phase":"committed"}' \
  >"${dir}/.plan-txn.committed.four/.ready"
printf '%s\n' '{"schema_version":1,"phase":"recovered"}' \
  >"${dir}/.plan-txn.recovered.five/.ready"
printf '%s\n' '{"schema_version":1,"phase":"prepare"}' \
  >"${dir}/.reviewer-transaction.prepare.six/manifest.json"
printf '%s\n' '{"schema_version":1,"phase":"committed"}' \
  >"${dir}/.reviewer-transaction.committed.seven/manifest.json"
printf '%s\n' '{"schema_version":1,"phase":"active"}' \
  >"${dir}/.plan-txn.active/.ready"
printf '%s\n' '{"schema_version":1,"phase":"active"}' \
  >"${dir}/.reviewer-transaction.wal/.ready"
inactive_settled_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || inactive_settled_reset_rc=$?
assert_eq "inactive exact reset accepts inert settled cleanup" "0" \
  "${inactive_settled_reset_rc}"
assert_eq "inactive exact reset reaps dispatch settled residue" "0" \
  "$([[ -e "${dir}/.dispatch-settled.one" \
        || -L "${dir}/.dispatch-settled.one" ]] \
      && printf 1 || printf 0)"
assert_eq "inactive exact reset reaps native-bind settled residue" "0" \
  "$([[ -e "${dir}/.native-bind-settled.two" \
        || -L "${dir}/.native-bind-settled.two" ]] \
      && printf 1 || printf 0)"
assert_eq "inactive exact reset reaps every publication retirement shape" "0" \
  "$(find "${dir}" -maxdepth 1 \
    \( -name '.plan-txn.*' -o -name '.reviewer-transaction.*' \) \
    | wc -l | tr -d '[:space:]')"

sid="dispatch-deactivate-transient-crash"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"reset-race-native",
  lifecycle_dispatch_id:"dispatch-reset-race",ts:1,
  review_dispatch_abandoned:false}' >"${dir}/pending_agents.jsonl"
set +e
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_DEACTIVATE_KILL_AT=after-transient-stage \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1
deactivate_transient_kill_rc=$?
set -e
assert_nonzero "transient-stage deactivation death is observable" \
  "${deactivate_transient_kill_rc}"
assert_eq "transient-stage death keeps state active" "1" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "transient-stage death removes no authority without a fence" "0" \
  "$([[ -e "${dir}/pending_agents.jsonl" ]] && printf 1 || printf 0)"
assert_eq "transient-stage death removes live session marker" "0" \
  "$([[ -e "${dir}/.ulw_active" || -L "${dir}/.ulw_active" ]] \
    && printf 1 || printf 0)"
assert_eq "transient-stage death quarantines session marker" "1" \
  "$(find "${dir}" -path '*/.deactivate-txn.*/.ulw_active' \
    | wc -l | tr -d '[:space:]')"
assert_eq "staged transient authority remains a global recovery fence" "0" \
  "$(if omc_interrupted_dispatch_transaction_present "${sid}"; then
       printf 0
     else
       printf 1
     fi)"
deactivate_transient_retry_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || deactivate_transient_retry_rc=$?
assert_eq "transient-stage reset retry converges" "0" \
  "${deactivate_transient_retry_rc}"
assert_eq "transient-stage reset retry closes enforcement" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "transient-stage reset retry removes quarantine" "0" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    -type d | wc -l | tr -d '[:space:]')"

sid="dispatch-deactivate-postcommit-crash"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
set +e
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  OMC_TEST_DEACTIVATE_KILL_AT=after-state-commit \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1
deactivate_postcommit_kill_rc=$?
set -e
assert_nonzero "post-commit deactivation death is observable" \
  "${deactivate_postcommit_kill_rc}"
assert_eq "post-commit death leaves state inactive" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "post-commit death leaves no live session marker" "0" \
  "$([[ -e "${dir}/.ulw_active" || -L "${dir}/.ulw_active" ]] \
    && printf 1 || printf 0)"
assert_eq "post-commit death retains inert cleanup residue" "1" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    | wc -l | tr -d '[:space:]')"
deactivate_postcommit_retry_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || deactivate_postcommit_retry_rc=$?
assert_eq "exact reset cleans post-commit residue while already inactive" "0" \
  "${deactivate_postcommit_retry_rc}"
assert_eq "post-commit reset retry retires quarantine" "0" \
  "$(find "${dir}" -maxdepth 1 -name '.deactivate-txn.*' \
    | wc -l | tr -d '[:space:]')"

printf 'Dispatch recovery: concurrent reactivation keeps its new marker\n'
sid="dispatch-deactivate-reactivation-race"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
deactivate_retire_ready="${TEST_HOME}/deactivate-retire-ready"
deactivate_retire_release="${TEST_HOME}/deactivate-retire-release"
deactivate_retire_rc_file="${TEST_HOME}/deactivate-retire-rc"
reactivate_rc_file="${TEST_HOME}/reactivate-rc"
(
  deactivate_retire_rc=0
  HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
    OMC_TEST_DEACTIVATE_RETIRE_READY_FILE="${deactivate_retire_ready}" \
    OMC_TEST_DEACTIVATE_RETIRE_RELEASE_FILE="${deactivate_retire_release}" \
    bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
    >/dev/null 2>&1 || deactivate_retire_rc=$?
  printf '%s\n' "${deactivate_retire_rc}" >"${deactivate_retire_rc_file}"
) &
deactivate_retire_pid=$!
for deactivate_retire_wait in $(seq 1 500); do
  [[ -e "${deactivate_retire_ready}" ]] && break
  kill -0 "${deactivate_retire_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "deactivation reaches in-lock retirement barrier" "1" \
  "$([[ -e "${deactivate_retire_ready}" ]] && printf 1 || printf 0)"
assert_eq "retirement barrier observes inactive state" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "retirement barrier observes old marker quarantined" "0" \
  "$([[ -e "${dir}/.ulw_active" || -L "${dir}/.ulw_active" ]] \
    && printf 1 || printf 0)"

_reactivate_after_reset_unlocked() {
  local generation marker marker_tmp
  generation="$(read_state "ulw_enforcement_generation" 2>/dev/null || true)"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
  generation=$((generation + 1))
  _write_state_batch_unlocked \
    "workflow_mode" "ultrawork" \
    "ulw_enforcement_active" "1" \
    "ulw_enforcement_generation" "${generation}" || return 1
  marker="$(session_file ".ulw_active")"
  marker_tmp="$(mktemp "${marker}.XXXXXX")" || return 1
  if printf '%s\n' "${generation}" >"${marker_tmp}" \
      && mv -f -- "${marker_tmp}" "${marker}"; then
    return 0
  fi
  rm -f -- "${marker_tmp}" 2>/dev/null || true
  return 1
}
(
  export SESSION_ID="${sid}"
  reactivate_rc=0
  with_state_lock _reactivate_after_reset_unlocked \
    >/dev/null 2>&1 || reactivate_rc=$?
  printf '%s\n' "${reactivate_rc}" >"${reactivate_rc_file}"
) &
reactivate_pid=$!
for reactivate_wait in $(seq 1 500); do
  reactivate_claim_count="$(find "${dir}" -maxdepth 1 \
    -name '.state.lock.owner.claim.*' -type f 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  [[ "${reactivate_claim_count:-0}" -ge 2 ]] && break
  kill -0 "${reactivate_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "reactivation waits behind reset mutex" "1" \
  "$([[ "${reactivate_claim_count:-0}" -ge 2 ]] && printf 1 || printf 0)"
touch "${deactivate_retire_release}"
wait "${deactivate_retire_pid}"
wait "${reactivate_pid}"
assert_eq "deactivation race completes" "0" \
  "$(<"${deactivate_retire_rc_file}")"
assert_eq "queued reactivation completes" "0" \
  "$(<"${reactivate_rc_file}")"
assert_eq "queued reactivation owns active state" "1" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "queued reactivation advances generation" "2" \
  "$(jq -r '.ulw_enforcement_generation // empty' \
    "${dir}/session_state.json")"
assert_eq "old reset cannot delete new activation marker" "2" \
  "$(<"${dir}/.ulw_active")"
rm -f "${deactivate_retire_ready}" "${deactivate_retire_release}" \
  "${deactivate_retire_rc_file}" "${reactivate_rc_file}"

printf 'Dispatch recovery: real router cannot publish after exact reset\n'
sid="dispatch-router-reset-race"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
jq '.workflow_mode="" | .ulw_enforcement_active="0"' \
  "${dir}/session_state.json" >"${dir}/session_state.json.tmp"
mv "${dir}/session_state.json.tmp" "${dir}/session_state.json"
rm -f "${dir}/.ulw_active"
router_activation_ready="${TEST_HOME}/router-activation-ready"
router_activation_release="${TEST_HOME}/router-activation-release"
router_activation_rc_file="${TEST_HOME}/router-activation-rc"
router_activation_output="${TEST_HOME}/router-activation-output"
router_activation_payload="$(jq -nc --arg sid "${sid}" '
  {session_id:$sid,prompt:"/ulw implement the exact reset race safely",
   transcript_path:"/tmp/none.jsonl",cwd:"/tmp"}
')"
(
  router_activation_rc=0
  printf '%s' "${router_activation_payload}" \
    | HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
      OMC_DEFINITION_OF_EXCELLENT=off OMC_QUALITY_CONSTITUTION=off \
      OMC_EXEMPLIFYING_SCOPE_GATE=off \
      OMC_TEST_ROUTER_ACTIVATION_READY_FILE="${router_activation_ready}" \
      OMC_TEST_ROUTER_ACTIVATION_RELEASE_FILE="${router_activation_release}" \
      bash "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh" \
      >"${router_activation_output}" 2>/dev/null \
      || router_activation_rc=$?
  printf '%s\n' "${router_activation_rc}" >"${router_activation_rc_file}"
) &
router_activation_pid=$!
for router_activation_wait in $(seq 1 500); do
  [[ -e "${router_activation_ready}" ]] && break
  kill -0 "${router_activation_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "real router reaches post-activation barrier" "1" \
  "$([[ -e "${router_activation_ready}" ]] && printf 1 || printf 0)"
assert_eq "real router atomically activates state" "1" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
router_race_generation="$(jq -r '.ulw_enforcement_generation // empty' \
  "${dir}/session_state.json")"
assert_eq "real router atomically publishes matching marker" \
  "${router_race_generation}" "$(<"${dir}/.ulw_active")"

router_race_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || router_race_reset_rc=$?
assert_eq "exact reset wins while real router is paused" "0" \
  "${router_race_reset_rc}"
assert_eq "router-race reset closes authority" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "router-race reset retires activation marker" "0" \
  "$([[ -e "${dir}/.ulw_active" || -L "${dir}/.ulw_active" ]] \
    && printf 1 || printf 0)"
touch "${router_activation_release}"
wait "${router_activation_pid}"
assert_nonzero "stale real router aborts on interval fence" \
  "$(<"${router_activation_rc_file}")"
assert_eq "stale real router emits no ULW-on context" "" \
  "$(<"${router_activation_output}")"
assert_eq "stale real router cannot republish session marker" "0" \
  "$([[ -e "${dir}/.ulw_active" || -L "${dir}/.ulw_active" ]] \
    && printf 1 || printf 0)"
assert_eq "stale real router cannot write post-reset task domain" "" \
  "$(jq -r '.task_domain // empty' "${dir}/session_state.json")"
rm -f "${router_activation_ready}" "${router_activation_release}" \
  "${router_activation_rc_file}" "${router_activation_output}"

sid="dispatch-deactivate-stale-quarantine"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
write_state "ulw_enforcement_generation" "2"
mkdir -p \
  "${dir}/.deactivate-txn.old/journals/.dispatch-txn.interrupted"
touch \
  "${dir}/.deactivate-txn.old/journals/.dispatch-txn.interrupted/.ready"
printf '%s\n' '1' \
  >"${dir}/.deactivate-txn.old/.enforcement-generation"
stale_deactivate_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || stale_deactivate_rc=$?
assert_eq "new-generation reset accepts inert old quarantine" "0" \
  "${stale_deactivate_rc}"
assert_eq "old quarantine is never restored into live dispatch prefix" "0" \
  "$([[ -e "${dir}/.dispatch-txn.interrupted" ]] \
    && printf 1 || printf 0)"
assert_eq "successful reset cleans inert old quarantine" "0" \
  "$([[ -e "${dir}/.deactivate-txn.old" ]] \
    && printf 1 || printf 0)"

printf 'Dispatch recovery: malformed quarantine and registry nodes converge\n'
sid="dispatch-deactivate-malformed-convergence"
reset_session "${sid}" 0
dir="${TEST_STATE_ROOT}/${sid}"
printf '%s\n' '1' >"${dir}/.ulw_active"
malformed_external="${TEST_HOME}/malformed-reset-external"
mkdir -p \
  "${malformed_external}/journals/.dispatch-txn.foreign"
printf '%s\n' 'external-reviewer' \
  >"${malformed_external}/journals/.dispatch-txn.foreign/attempted-agent-type"
printf '%s\n' '{"agent_type":"external-reviewer"}' \
  >"${malformed_external}/foreign-ledger.jsonl"
printf '%s\n' 'foreign-taint' >"${malformed_external}/foreign-taint.log"
printf '%s\n' 'foreign-rebind' >"${malformed_external}/foreign-rebind.log"
printf '%s\n' 'foreign-native' >"${malformed_external}/foreign-native.jsonl"

mkdir "${dir}/.dispatch-txn.interrupted"
touch "${dir}/.dispatch-txn.interrupted/.ready"
ln -s \
  "${malformed_external}/journals/.dispatch-txn.foreign/attempted-agent-type" \
  "${dir}/.dispatch-txn.interrupted/attempted-agent-type"
printf '%s\n' \
  '{"agent_type":"malformed-lease-agent","completion_claim_id":"claim-bad-ts","completion_claim_ts":"garbage","completion_claim_effects_complete":false}' \
  >"${dir}/pending_agents.jsonl"
ln -s "${malformed_external}/foreign-ledger.jsonl" \
  "${dir}/agent_dispatch_starts.jsonl"
ln -s "${malformed_external}/foreign-taint.log" \
  "${dir}/dispatch_tainted_identities.log"
ln -s "${malformed_external}/foreign-rebind.log" \
  "${dir}/dispatch_rebind_ids.log"
ln -s "${malformed_external}/foreign-native.jsonl" \
  "${dir}/native_agent_bindings.jsonl"

for duplicate_suffix in a b; do
  duplicate_txn="${dir}/.deactivate-txn.duplicate-${duplicate_suffix}"
  mkdir -p "${duplicate_txn}/journals/.dispatch-txn.${duplicate_suffix}"
  printf '%s\n' '1' >"${duplicate_txn}/.enforcement-generation"
  duplicate_agent="quality-planner"
  [[ "${duplicate_suffix}" == "b" ]] && duplicate_agent="quality-reviewer"
  printf '%s\n' "${duplicate_agent}" \
    >"${duplicate_txn}/journals/.dispatch-txn.${duplicate_suffix}/attempted-agent-type"
done
mkdir -p \
  "${dir}/.deactivate-txn.bad-marker/journals/.dispatch-txn.bad-marker"
printf '%s\n' '01' \
  >"${dir}/.deactivate-txn.bad-marker/.enforcement-generation"
printf '%s\n' 'metis' \
  >"${dir}/.deactivate-txn.bad-marker/journals/.dispatch-txn.bad-marker/attempted-agent-type"
mkdir -p "${dir}/.deactivate-txn.markerless/journals"
printf '%s\n' '{"agent_type":"oracle"}' \
  >"${dir}/.deactivate-txn.markerless/pending_agents.jsonl"
mkdir "${dir}/.deactivate-txn.bad-journals"
printf '%s\n' '1' \
  >"${dir}/.deactivate-txn.bad-journals/.enforcement-generation"
ln -s "${malformed_external}/journals" \
  "${dir}/.deactivate-txn.bad-journals/journals"
mkdir -p "${dir}/.deactivate-txn.bad-untrusted/journals"
printf '%s\n' '1' \
  >"${dir}/.deactivate-txn.bad-untrusted/.enforcement-generation"
ln -s "${malformed_external}" \
  "${dir}/.deactivate-txn.bad-untrusted/untrusted"
ln -s "${malformed_external}" "${dir}/.deactivate-txn.symlink"

malformed_reset_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || malformed_reset_rc=$?
assert_eq "malformed quarantine exact reset converges" "0" \
  "${malformed_reset_rc}"
assert_eq "malformed quarantine reset closes enforcement" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dir}/session_state.json")"
assert_eq "malformed quarantine reset retires every authority prefix" "0" \
  "$(find "${dir}" -maxdepth 1 \
    \( -name '.dispatch-txn.*' -o -name '.deactivate-txn.*' \) \
    | wc -l | tr -d '[:space:]')"
for recovered_taint in malformed-lease-agent quality-planner \
    quality-reviewer metis oracle; do
  assert_eq "malformed reset retains conservative taint ${recovered_taint}" \
    "1" "$(grep -Fxc "${recovered_taint}" \
      "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
done
for foreign_taint in external-reviewer foreign-taint; do
  assert_eq "malformed reset never imports foreign ${foreign_taint}" "0" \
    "$(grep -Fxc "${foreign_taint}" \
      "${dir}/dispatch_tainted_identities.log" 2>/dev/null || true)"
done
assert_eq "outer quarantine symlink target survives reset" \
  "external-reviewer" \
  "$(<"${malformed_external}/journals/.dispatch-txn.foreign/attempted-agent-type")"
assert_eq "causal-ledger symlink target survives reset" \
  '{"agent_type":"external-reviewer"}' \
  "$(<"${malformed_external}/foreign-ledger.jsonl")"
assert_eq "taint-registry symlink target survives reset" "foreign-taint" \
  "$(<"${malformed_external}/foreign-taint.log")"
for tracking_key in subagent_dispatch_tracking_version \
    review_dispatch_tracking_version plan_dispatch_tracking_version \
    native_agent_id_tracking_version; do
  assert_eq "malformed reset stamps ${tracking_key}" "1" \
    "$(jq -r --arg key "${tracking_key}" '.[$key] // empty' \
      "${dir}/session_state.json")"
done

printf 'Planner rendezvous: /ulw-off clears transient authority\n'
sid="plan-rendezvous-deactivate"
native="native-plan-rendezvous-deactivate"
lifecycle="dispatch-plandeactivateabcd"
reset_session "${sid}" 0
seed_dispatch "${sid}" "${native}" "${lifecycle}" 0 1
dir="${TEST_STATE_ROOT}/${sid}"
write_state "quality_contract_scope_transition" '{"transient":"scope"}'
printf '%s\n' '{"transient":"waiter"}' >"${dir}/plan_summary_waiters.jsonl"
printf '%s\n' '{"transient":"receipt"}' >"${dir}/plan_publication_outcomes.jsonl"
deactivate_rc=0
HOME="${TEST_HOME}" STATE_ROOT="${TEST_STATE_ROOT}" \
  bash "${HOOK_DIR}/ulw-deactivate.sh" "${sid}" \
  >/dev/null 2>&1 || deactivate_rc=$?
assert_eq "deactivation succeeds with planner rendezvous files" "0" \
  "${deactivate_rc}"
assert_eq "deactivation removes planner waiter authority" "0" \
  "$([[ -e "${dir}/plan_summary_waiters.jsonl" ]] && printf 1 || printf 0)"
assert_eq "deactivation removes planner receipt authority" "0" \
  "$([[ -e "${dir}/plan_publication_outcomes.jsonl" ]] && printf 1 || printf 0)"
assert_eq "deactivation clears one-use scope transition" "" \
  "$(jq -r '.quality_contract_scope_transition // empty' \
    "${dir}/session_state.json")"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  exit 1
fi
