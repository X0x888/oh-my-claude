#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}"
touch "${STATE_ROOT}/.ulw_active"
cd "${TEST_HOME}"

cleanup() {
  cd "${ORIG_PWD}"
  export HOME="${ORIG_HOME}"
  rm -rf "${TEST_HOME}"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then ok; else bad "${name}: missing ${needle}"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then ok; else bad "${name}: unexpectedly contained ${needle}"; fi
}
assert_empty() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then ok; else bad "${name}: expected empty, got ${value}"; fi
}
assert_single_json() {
  local name="$1" value="$2"
  if jq -s -e 'length == 1 and (.[0] | type == "object")' <<<"${value}" >/dev/null 2>&1; then
    ok
  else
    bad "${name}: expected exactly one JSON object, got ${value}"
  fi
}

hook_env() {
  env \
    HOME="${TEST_HOME}" \
    STATE_ROOT="${STATE_ROOT}" \
    OMC_INFERRED_CONTRACT=off \
    OMC_OBJECTIVE_CONTRACT_GATE=off \
    OMC_AGENT_FIRST_GATE=off \
    OMC_NO_DEFER_MODE=off \
    OMC_TIME_TRACKING=off \
    OMC_MODEL_DRIFT_CANARY=off \
    OMC_STOP_FEEDBACK_MODE="${OMC_STOP_FEEDBACK_MODE:-legacy}" \
    "$@"
}

seed_ready() {
  local sid="$1" now state_dir
  now="$(date +%s)"
  state_dir="${STATE_ROOT}/${sid}"
  mkdir -p "${state_dir}"
  touch "${STATE_ROOT}/.ulw_active"
  jq -nc --arg ts "${now}" --arg cwd "${TEST_HOME}" '
    {
      workflow_mode:"ultrawork", task_domain:"coding", task_intent:"execution",
      current_objective:"Implement the complete closeout redesign", cwd:$cwd,
      last_user_prompt_ts:$ts, prompt_revision:"1",
      review_cycle_id:"1", review_cycle_prompt_ts:$ts,
      review_cycle_edit_log_offset:"0", review_cycle_bash_event_base:"0",
      review_cycle_plan_revision_base:"0", review_cycle_findings_signature_base:"absent",
      last_edit_ts:$ts, last_code_edit_ts:$ts,
      edit_revision:"1", last_code_edit_revision:"1", code_edit_count:"1",
      last_verify_ts:$ts, last_verify_cmd:"npm test", last_verify_outcome:"passed",
      last_verify_confidence:"100", last_verify_method:"project_test_command",
      last_verify_code_revision:"1",
      last_review_ts:$ts, review_had_findings:"0",
      dim_bug_hunt_ts:$ts, dim_bug_hunt_revision:"1", dim_bug_hunt_verdict:"CLEAN",
      dim_code_quality_ts:$ts, dim_code_quality_revision:"1", dim_code_quality_verdict:"CLEAN",
      closeout_preflight_required:"1"
    }
  ' >"${state_dir}/session_state.json"
  printf '/src/foo.ts\n' >"${state_dir}/edited_files.log"
}

closeout_message() {
  local detail="${1:-Implemented the full requested behavior.}"
  printf '**Changed.** %s Updated /src/foo.ts.\n\n**Verification.** `npm test` passed all 10 tests.\n\n**Objective coverage.** The whole original objective and every material fact are covered.\n\n**Next.** Done.' "${detail}"
}

stop_payload() {
  local sid="$1" msg="$2" active="${3:-false}"
  jq -nc --arg sid "${sid}" --arg msg "${msg}" --argjson active "${active}" '{
    session_id:$sid, hook_event_name:"Stop", stop_hook_active:$active,
    last_assistant_message:$msg, background_tasks:[], session_crons:[]
  }'
}

run_dispatch() {
  local sid="$1" msg="$2" active="${3:-false}"
  hook_env bash "${HOOK_DIR}/stop-dispatch.sh" <<<"$(stop_payload "${sid}" "${msg}" "${active}")"
}

run_dispatch_payload() {
  local payload="$1"
  hook_env bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${payload}"
}

run_dispatch_with_cap() {
  local sid="$1" msg="$2" cap="$3" active="${4:-true}"
  hook_env CLAUDE_CODE_STOP_HOOK_BLOCK_CAP="${cap}" \
    bash "${HOOK_DIR}/stop-dispatch.sh" \
    <<<"$(stop_payload "${sid}" "${msg}" "${active}")"
}

run_preflight() {
  local sid="$1" payload
  payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid,hook_event_name:"PostToolBatch",tool_calls:[{tool_name:"Agent",tool_input:{subagent_type:"quality-reviewer"},tool_response:"VERDICT: CLEAN"}]}')"
  hook_env bash "${HOOK_DIR}/closeout-preflight.sh" --posttool-batch <<<"${payload}"
}

run_mark_edit() {
  local sid="$1" path="$2" payload
  payload="$(jq -nc --arg sid "${sid}" --arg path "${path}" '{
    session_id:$sid, hook_event_name:"PostToolUse", tool_name:"Edit",
    tool_use_id:($sid + "-edit"), tool_input:{file_path:$path}, tool_response:{}
  }')"
  hook_env bash "${HOOK_DIR}/mark-edit.sh" <<<"${payload}"
}

run_dispatch_auto_version() {
  local sid="$1" msg="$2" version="$3"
  local OMC_STOP_FEEDBACK_MODE="auto"
  export OMC_TEST_CLAUDE_VERSION="${version}"
  claude() { printf '%s (Claude Code)\n' "${OMC_TEST_CLAUDE_VERSION}"; }
  export -f claude
  run_dispatch "${sid}" "${msg}" true
  unset -f claude
  unset OMC_TEST_CLAUDE_VERSION
}

run_finalization_op() {
  local sid="$1" op="$2" claim_id="${3:-}"
  hook_env SESSION_ID="${sid}" bash -c '
    . "$1"
    case "$2" in
      claim) if ! closeout_claim_finalization; then printf denied; fi ;;
      abandon) if closeout_abandon_finalization "$3"; then printf abandoned; else printf denied; fi ;;
      complete) if closeout_complete_finalization "$3"; then printf completed; else printf denied; fi ;;
    esac
  ' -- "${HOOK_DIR}/common.sh" "${op}" "${claim_id}"
}

printf '\nStop dispatcher:\n'

# Stop is the final certification owner. A decoded NUL cannot alias a
# malformed lifecycle identity to a real active session before common.sh is
# even sourced.
seed_ready "nul-stop-target"
nul_stop_payload="$(jq -nc --arg msg "$(closeout_message)" '
  {session_id:("nul-stop-target" + "\u0000"),hook_event_name:"Stop",
   stop_hook_active:false,last_assistant_message:$msg,
   background_tasks:[],session_crons:[]}')"
nul_stop_out="$(run_dispatch_payload "${nul_stop_payload}")"
assert_contains "NUL-bearing Stop identity is rejected as malformed" \
  "malformed lifecycle payload" "${nul_stop_out}"
assert_contains "NUL-bearing Stop identity is blocked" \
  '"decision":"block"' "${nul_stop_out}"

# State generation is imported before common.sh. Reject malformed string
# authority in jq rather than letting Bash erase NUL into a live generation.
seed_ready "nul-stop-state"
jq '.ulw_enforcement_generation=("1" + "\u0000")' \
  "${STATE_ROOT}/nul-stop-state/session_state.json" \
  >"${STATE_ROOT}/nul-stop-state/session_state.json.tmp"
mv "${STATE_ROOT}/nul-stop-state/session_state.json.tmp" \
  "${STATE_ROOT}/nul-stop-state/session_state.json"
nul_stop_state_out="$(run_dispatch "nul-stop-state" "$(closeout_message)")"
assert_contains "NUL-bearing Stop state is rejected before certification" \
  "malformed session authority" "${nul_stop_state_out}"
assert_contains "NUL-bearing Stop state blocks release" \
  '"decision":"block"' "${nul_stop_state_out}"

# Unsealed work gets one compact authoritative continuation. Timing/canary/
# archive finalizers do not leak output, and the full provisional candidate is
# retained privately for the eventual cumulative manifest.
seed_ready blocked
long_detail="$(printf 'Material detail %03d; ' $(seq 1 90)) UNIQUE-BLOCKED-DETAIL"
blocked_msg="$(closeout_message "${long_detail}")"
blocked_out="$(run_dispatch blocked "${blocked_msg}")"
if jq -e '.decision == "block" and (.reason | contains("cumulative replacement"))' <<<"${blocked_out}" >/dev/null; then ok; else bad "legacy continuation schema/wording invalid"; fi
blocked_reason="$(jq -r '.reason // empty' <<<"${blocked_out}")"
assert_contains "continuation recovery embeds the exact payload session" \
  'closeout-preflight.sh" "blocked' "${blocked_reason}"
assert_not_contains "continuation recovery does not leak an unexpanded skill variable" \
  'CLAUDE_SESSION_ID' "${blocked_reason}"
assert_not_contains "compact block hides dual-audience internals" "FOR MODEL" "${blocked_out}"
if (( ${#blocked_out} < 1400 )); then ok; else bad "compact block grew to ${#blocked_out} chars"; fi
[[ -s "${STATE_ROOT}/blocked/provisional_closeouts.jsonl" ]] && ok || bad "blocked provisional closeout was not retained"
[[ "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/blocked/session_state.json")" == "" ]] && ok || bad "blocked dispatcher stamped terminal outcome"

# Modern clients receive non-error Stop feedback instead of a hook error, with
# the same compact cumulative instruction.
seed_ready modern
OMC_STOP_FEEDBACK_MODE=modern modern_out="$(run_dispatch modern "$(closeout_message)" true)"
if jq -e '.hookSpecificOutput.hookEventName == "Stop" and (.hookSpecificOutput.additionalContext | contains("cumulative replacement")) and (has("decision")|not)' <<<"${modern_out}" >/dev/null; then ok; else bad "modern Stop feedback schema invalid"; fi

# stop_hook_active=true still evaluates stale/missing readiness; it cannot
# bypass certification on the continuation retry.
assert_contains "active retry remains blocked" "closeout check" "${modern_out}"

# A wait sentence is a first-class nonterminal state only when the Stop
# payload's level registry proves a future wake exists. This is separate from
# closeout gating: verified waits consume no continuation slot or finalizer,
# while present-empty registries recover immediately instead of promising a
# notification that can never fire.
canonical_wait='⏳ **Waiting on the Wave 3 quality-reviewer to finish its verdict** — running in the background; I'"'"'ll resume automatically when it finishes. Nothing for you to do.'

seed_ready wait_live
wait_live_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_live/session_state.json")"
jq -nc --argjson objective_ts "${wait_live_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"a571",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_live/pending_agents.jsonl"
wait_live_payload="$(jq -nc --arg sid wait_live --arg msg "${canonical_wait}" '{
  session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
  last_assistant_message:$msg,
  background_tasks:[{id:"a571",type:"subagent",status:"running",
    description:"Wave 3 quality-reviewer",agent_type:"quality-reviewer"}],
  session_crons:[]
}')"
wait_live_out="$(run_dispatch_payload "${wait_live_payload}")"
assert_empty "verified live wait emits no Stop continuation" "${wait_live_out}"
assert_empty "verified live wait writes no terminal outcome" \
  "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/wait_live/session_state.json")"
assert_empty "verified live wait consumes no continuation slot" \
  "$(jq -r '.closeout_dispatch_continuations // empty' "${STATE_ROOT}/wait_live/session_state.json")"
[[ ! -e "${STATE_ROOT}/wait_live/provisional_closeouts.jsonl" ]] \
  && ok || bad "verified live wait was recorded as a provisional closeout"
[[ ! -e "${STATE_ROOT}/wait_live/prompt_timing.jsonl" ]] \
  && ok || bad "verified live wait wrote prompt-end timing"

seed_ready wait_dead
wait_dead_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_dead/session_state.json")"
jq -nc --argjson objective_ts "${wait_dead_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"a571",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_dead/pending_agents.jsonl"
wait_dead_payload="$(jq -nc --arg sid wait_dead --arg msg "${canonical_wait}" '{
  session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
  last_assistant_message:$msg,background_tasks:[],session_crons:[]
}')"
OMC_STOP_FEEDBACK_MODE=modern wait_dead_out="$(run_dispatch_payload "${wait_dead_payload}")"
assert_single_json "dead wait emits one recovery object" "${wait_dead_out}"
if jq -e '
    .hookSpecificOutput.hookEventName == "Stop"
    and (.hookSpecificOutput.additionalContext | contains("no live background wake source"))
    and (.hookSpecificOutput.additionalContext | contains("SendMessage"))
    and (.hookSpecificOutput.additionalContext | contains("a571"))
    and (.systemMessage == "oh-my-claude could not find live background work matching this wait and is recovering automatically.")
  ' <<<"${wait_dead_out}" >/dev/null; then
  ok
else
  bad "dead wait recovery did not name the missing wake and retained agent"
fi
assert_not_contains "dead wait does not repeat auto-resume promise" \
  "resume automatically" "${wait_dead_out}"
assert_not_contains "dead wait does not tell user there is nothing to do" \
  "Nothing for you to do" "${wait_dead_out}"
assert_contains "dead wait increments exactly one continuation slot" '"1"' \
  "$(jq -c '.closeout_dispatch_continuations' "${STATE_ROOT}/wait_dead/session_state.json")"
[[ ! -e "${STATE_ROOT}/wait_dead/provisional_closeouts.jsonl" ]] \
  && ok || bad "dead wait prose was retained as a completion candidate"
assert_empty "dead wait keeps the quality interval nonterminal" \
  "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/wait_dead/session_state.json")"

# Dispatch admission is armed before its pending/start/Council writes. A crash
# there outranks the WAIT shortcut: Stop must not clear the background marker,
# record a provisional candidate, consume a continuation, or run certification.
seed_ready wait_dispatch_txn
wait_dispatch_dir="${STATE_ROOT}/wait_dispatch_txn"
jq '.bg_work_dispatched_ts="dispatch-journal-marker"' \
  "${wait_dispatch_dir}/session_state.json" \
  >"${wait_dispatch_dir}/session_state.json.tmp"
mv "${wait_dispatch_dir}/session_state.json.tmp" \
  "${wait_dispatch_dir}/session_state.json"
mkdir "${wait_dispatch_dir}/.dispatch-txn.interrupted"
touch "${wait_dispatch_dir}/.dispatch-txn.interrupted/.ready"
wait_dispatch_before="$(<"${wait_dispatch_dir}/session_state.json")"
wait_dispatch_out="$(run_dispatch_payload "$(jq -nc \
  --arg sid wait_dispatch_txn --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')")"
assert_single_json "dispatch journal Stop emits one response" \
  "${wait_dispatch_out}"
assert_contains "dispatch journal blocks before WAIT recovery" \
  "prior Agent authorization was interrupted" "${wait_dispatch_out}"
assert_contains "dispatch journal preserves exact state bytes" \
  "${wait_dispatch_before}" \
  "$(<"${wait_dispatch_dir}/session_state.json")"
[[ ! -e "${wait_dispatch_dir}/provisional_closeouts.jsonl" ]] \
  && ok || bad "dispatch journal Stop recorded a provisional closeout"

# The dead-wait path may bypass only a live effects-incomplete claim so it can
# explain that the exact callback is still settling.  Fixed planner/reviewer
# journals remain stronger publication authority.  A malformed journal must
# therefore block every false-wait mutation and produce a mutation-free,
# recovery-pending Stop response instead of consuming a continuation slot.
for fixed_wal_kind in reviewer plan; do
  fixed_wal_sid="wait_dead_${fixed_wal_kind}_wal"
  seed_ready "${fixed_wal_sid}"
  fixed_wal_dir="${STATE_ROOT}/${fixed_wal_sid}"
  fixed_wal_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
    "${fixed_wal_dir}/session_state.json")"
  jq '.bg_work_dispatched_ts="fixed-wal-marker"' \
    "${fixed_wal_dir}/session_state.json" \
    >"${fixed_wal_dir}/session_state.json.tmp"
  mv "${fixed_wal_dir}/session_state.json.tmp" \
    "${fixed_wal_dir}/session_state.json"
  jq -nc --argjson objective_ts "${fixed_wal_objective_ts}" '{
    agent_type:"quality-reviewer",native_agent_id:"fixed-wal-native",ts:1,
    review_dispatch_abandoned:false,objective_cycle_id:1,
    objective_prompt_ts:$objective_ts,review_revision:1
  }' >"${fixed_wal_dir}/pending_agents.jsonl"
  if [[ "${fixed_wal_kind}" == "reviewer" ]]; then
    fixed_wal_path="${fixed_wal_dir}/.reviewer-transaction.wal"
  else
    fixed_wal_path="${fixed_wal_dir}/.plan-txn.active"
  fi
  mkdir "${fixed_wal_path}"
  printf '{"schema_version":999}\n' >"${fixed_wal_path}/manifest.json"
  fixed_wal_payload="$(jq -nc --arg sid "${fixed_wal_sid}" \
    --arg msg "${canonical_wait}" '{
      session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
      last_assistant_message:$msg,background_tasks:[],session_crons:[]
    }')"
  OMC_STOP_FEEDBACK_MODE=modern fixed_wal_out="$(run_dispatch_payload \
    "${fixed_wal_payload}")"
  assert_single_json "${fixed_wal_kind} WAL dead wait emits one response" \
    "${fixed_wal_out}"
  assert_contains "${fixed_wal_kind} WAL remains a false-wait fence" \
    "publication transaction still requires recovery" "${fixed_wal_out}"
  assert_empty "${fixed_wal_kind} WAL consumes no continuation slot" \
    "$(jq -r '.closeout_dispatch_continuations // empty' \
      "${fixed_wal_dir}/session_state.json")"
  assert_contains "${fixed_wal_kind} WAL preserves the wait marker" \
    '"bg_work_dispatched_ts": "fixed-wal-marker"' \
    "$(jq . "${fixed_wal_dir}/session_state.json")"
  [[ -d "${fixed_wal_path}" ]] \
    && ok || bad "${fixed_wal_kind} false wait removed corrupt WAL authority"
done

seed_ready wait_claim_settling
claim_now="$(date +%s)"
claim_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_claim_settling/session_state.json")"
jq -nc --argjson ts "${claim_now}" \
  --argjson objective_ts "${claim_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"a571",ts:1,
  review_dispatch_abandoned:false,completion_claim_id:"claim-live",
  completion_claim_ts:$ts,completion_claim_effects_complete:false,
  objective_cycle_id:1,objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_claim_settling/pending_agents.jsonl"
claim_wait_payload="$(jq -nc --arg sid wait_claim_settling \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern claim_wait_out="$(run_dispatch_payload \
  "${claim_wait_payload}")"
assert_contains "fresh completion claim gets settle/re-evaluate recovery" \
  "still publishing its SubagentStop evidence" "${claim_wait_out}"
assert_not_contains "fresh completion claim is not abandoned via SendMessage" \
  "SendMessage" "${claim_wait_out}"
assert_contains "fresh completion claim remains intact" "claim-live" \
  "$(cat "${STATE_ROOT}/wait_claim_settling/pending_agents.jsonl")"

seed_ready wait_claim_effects_complete
effects_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_claim_effects_complete/session_state.json")"
jq -nc --argjson objective_ts "${effects_objective_ts}" \
  --argjson ts "$(date +%s)" '{
  agent_type:"quality-reviewer",native_agent_id:"effects-native",ts:1,
  review_dispatch_abandoned:false,completion_claim_id:"claim-complete",
  completion_claim_ts:$ts,completion_claim_effects_complete:true,
  objective_cycle_id:1,objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_claim_effects_complete/pending_agents.jsonl"
effects_wait_payload="$(jq -nc --arg sid wait_claim_effects_complete \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern effects_wait_out="$(run_dispatch_payload \
  "${effects_wait_payload}")"
assert_contains "malformed effects-complete claim remains publication-fenced" \
  "publication transaction still requires recovery" "${effects_wait_out}"
assert_not_contains "effects-complete dead wait never resumes native task" \
  "SendMessage" "${effects_wait_out}"
assert_not_contains "effects-complete dead wait never rebinds" \
  "explicit rebind" "${effects_wait_out}"

seed_ready wait_claim_expired
expired_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_claim_expired/session_state.json")"
jq -nc --argjson objective_ts "${expired_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"expired-native",ts:1,
  review_dispatch_abandoned:false,completion_claim_id:"claim-expired",
  completion_claim_ts:1,completion_claim_effects_complete:false,
  objective_cycle_id:1,objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_claim_expired/pending_agents.jsonl"
expired_wait_payload="$(jq -nc --arg sid wait_claim_expired \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern expired_wait_out="$(run_dispatch_payload \
  "${expired_wait_payload}")"
assert_contains "malformed expired reviewer claim remains publication-fenced" \
  "publication transaction still requires recovery" "${expired_wait_out}"
assert_not_contains "expired-claim dead wait never resumes native task" \
  "SendMessage" "${expired_wait_out}"
assert_not_contains "expired-claim dead wait cannot invent rebind authority" \
  "explicit rebind" "${expired_wait_out}"

seed_ready wait_unrelated_task
wait_unrelated_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_unrelated_task/session_state.json")"
jq -nc --argjson objective_ts "${wait_unrelated_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"a571",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_unrelated_task/pending_agents.jsonl"
unrelated_wait_payload="$(jq -nc --arg sid wait_unrelated_task \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"bash-1",type:"bash",status:"running",
      description:"development server",command:"npm run dev"}],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern unrelated_wait_out="$(run_dispatch_payload \
  "${unrelated_wait_payload}")"
assert_contains "unrelated live task cannot validate the named reviewer wait" \
  "no live background wake source matching the promised worker" \
  "${unrelated_wait_out}"

seed_ready wait_wrong_same_type
wrong_same_type_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_wrong_same_type/session_state.json")"
jq -nc --argjson objective_ts "${wrong_same_type_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"expected-id",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_wrong_same_type/pending_agents.jsonl"
wrong_same_type_payload="$(jq -nc --arg sid wait_wrong_same_type \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"other-id",type:"subagent",status:"running",
      description:"other quality review",agent_type:"quality-reviewer"}],
    session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern wrong_same_type_out="$(run_dispatch_payload \
  "${wrong_same_type_payload}")"
assert_contains "same-role task with a different native ID cannot validate wait" \
  "no live background wake source matching the promised worker" \
  "${wrong_same_type_out}"

seed_ready wait_legacy_role_only
legacy_role_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_legacy_role_only/session_state.json")"
jq -nc --argjson objective_ts "${legacy_role_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"legacy-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_legacy_role_only/pending_agents.jsonl"
legacy_role_payload="$(jq -nc --arg sid wait_legacy_role_only \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{type:"subagent",status:"running",
      description:"legacy quality review",agent_type:"quality-reviewer"}],
    session_crons:[]
  }')"
legacy_role_out="$(run_dispatch_payload "${legacy_role_payload}")"
assert_empty "legacy role-only task can validate its one current pending wait" \
  "${legacy_role_out}"

seed_ready wait_unrelated_without_pending
unrelated_no_pending_payload="$(jq -nc --arg sid wait_unrelated_without_pending \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"shell-1",type:"shell",status:"running",
      description:"development server",command:"npm run dev"}],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern unrelated_no_pending_out="$(run_dispatch_payload \
  "${unrelated_no_pending_payload}")"
assert_contains "named reviewer wait without a ledger cannot borrow a shell wake" \
  "no live background wake source matching the promised worker" \
  "${unrelated_no_pending_out}"

seed_ready wait_wrong_pending
wrong_pending_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_wrong_pending/session_state.json")"
jq -nc --argjson objective_ts "${wrong_pending_objective_ts}" '{
  agent_type:"excellence-reviewer",native_agent_id:"wrong-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1
}' >"${STATE_ROOT}/wait_wrong_pending/pending_agents.jsonl"
wrong_pending_payload="$(jq -nc --arg sid wait_wrong_pending \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern wrong_pending_out="$(run_dispatch_payload \
  "${wrong_pending_payload}")"
assert_not_contains "dead named wait never resumes an unrelated pending agent" \
  "wrong-native" "${wrong_pending_out}"

seed_ready wait_stale_pending
stale_pending_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_stale_pending/session_state.json")"
jq -nc --argjson objective_ts "${stale_pending_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"stale-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:0
}' >"${STATE_ROOT}/wait_stale_pending/pending_agents.jsonl"
stale_pending_payload="$(jq -nc --arg sid wait_stale_pending \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern stale_pending_out="$(run_dispatch_payload \
  "${stale_pending_payload}")"
assert_not_contains "dead wait never resumes a generation-stale agent" \
  "stale-native" "${stale_pending_out}"

seed_ready wait_prior_objective
jq -nc '{
  agent_type:"quality-reviewer",native_agent_id:"prior-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:2,
  objective_prompt_ts:1,review_revision:1
}' >"${STATE_ROOT}/wait_prior_objective/pending_agents.jsonl"
prior_pending_payload="$(jq -nc --arg sid wait_prior_objective \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"prior-runtime-task",type:"subagent",status:"running",
      description:"Wave 3 quality-reviewer",agent_type:"quality-reviewer"}],
    session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern prior_pending_out="$(run_dispatch_payload \
  "${prior_pending_payload}")"
assert_not_contains "dead wait never resumes a prior-objective agent" \
  "prior-native" "${prior_pending_out}"
assert_contains "prior-objective same-role task cannot validate current wait" \
  "no live background wake source matching the promised worker" \
  "${prior_pending_out}"

seed_ready wait_foreign_interval
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"2"}' \
  "${STATE_ROOT}/wait_foreign_interval/session_state.json" \
  >"${STATE_ROOT}/wait_foreign_interval/session_state.json.tmp"
mv "${STATE_ROOT}/wait_foreign_interval/session_state.json.tmp" \
  "${STATE_ROOT}/wait_foreign_interval/session_state.json"
foreign_interval_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_foreign_interval/session_state.json")"
jq -nc --argjson objective_ts "${foreign_interval_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"old-interval-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1,
  ulw_enforcement_generation:"1"
}' >"${STATE_ROOT}/wait_foreign_interval/pending_agents.jsonl"
foreign_interval_payload="$(jq -nc --arg sid wait_foreign_interval \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"old-interval-native",type:"subagent",
      status:"running",description:"Wave 3 quality-reviewer",
      agent_type:"quality-reviewer"}],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern foreign_interval_out="$(run_dispatch_payload \
  "${foreign_interval_payload}")"
assert_contains "foreign-interval pending row cannot validate a live wait" \
  "no live background wake source matching the promised worker" \
  "${foreign_interval_out}"
assert_not_contains "dead-wait recovery never resumes foreign-interval row" \
  "old-interval-native" "${foreign_interval_out}"

# Freeze a G1 Stop callback, reactivate G2 with the same objective/revision,
# then release the old callback. Both child and parent must honor the original
# generation snapshot: no guard, continuation, outcome, finalizer, or receipt
# from the old payload may touch or describe G2.
seed_ready stop_cross_interval_callback
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1"}' \
  "${STATE_ROOT}/stop_cross_interval_callback/session_state.json" \
  >"${STATE_ROOT}/stop_cross_interval_callback/session_state.json.tmp"
mv "${STATE_ROOT}/stop_cross_interval_callback/session_state.json.tmp" \
  "${STATE_ROOT}/stop_cross_interval_callback/session_state.json"
cross_stop_ready="${TEST_HOME}/cross-stop.ready"
cross_stop_release="${TEST_HOME}/cross-stop.release"
cross_stop_output="${TEST_HOME}/cross-stop.output"
cross_stop_payload="$(stop_payload stop_cross_interval_callback \
  "$(closeout_message 'OLD-G1-CANDIDATE')")"
export OMC_TEST_STOP_CAPTURE_READY_FILE="${cross_stop_ready}"
export OMC_TEST_STOP_CAPTURE_RELEASE_FILE="${cross_stop_release}"
run_dispatch_payload "${cross_stop_payload}" >"${cross_stop_output}" 2>&1 &
cross_stop_pid=$!
for _cross_wait in $(seq 1 200); do
  [[ -f "${cross_stop_ready}" ]] && break
  sleep 0.02
done
if [[ -f "${cross_stop_ready}" ]]; then
  ok
else
  bad "old Stop callback did not reach capture barrier"
fi
jq '.ulw_enforcement_generation="2"
    | .ulw_enforcement_active="1"
    | .session_outcome=""
    | .closeout_dispatch_continuations="0"
    | .stop_guard_attempt_seq="0"
    | .bg_work_dispatched_ts="777"' \
  "${STATE_ROOT}/stop_cross_interval_callback/session_state.json" \
  >"${STATE_ROOT}/stop_cross_interval_callback/session_state.json.tmp"
mv "${STATE_ROOT}/stop_cross_interval_callback/session_state.json.tmp" \
  "${STATE_ROOT}/stop_cross_interval_callback/session_state.json"
touch "${cross_stop_release}"
wait "${cross_stop_pid}"
unset OMC_TEST_STOP_CAPTURE_READY_FILE OMC_TEST_STOP_CAPTURE_RELEASE_FILE
assert_empty "old G1 Stop callback is inert after G2 reactivation" \
  "$(cat "${cross_stop_output}")"
assert_empty "old G1 callback stamps no G2 terminal outcome" \
  "$(jq -r '.session_outcome // empty' \
    "${STATE_ROOT}/stop_cross_interval_callback/session_state.json")"
assert_contains "G2 remains active after old callback exits" \
  '"ulw_enforcement_active": "1"' \
  "$(jq . "${STATE_ROOT}/stop_cross_interval_callback/session_state.json")"
assert_contains "G2 continuation counter remains untouched" \
  '"closeout_dispatch_continuations": "0"' \
  "$(jq . "${STATE_ROOT}/stop_cross_interval_callback/session_state.json")"
assert_contains "old guard increments no G2 Stop attempt sequence" \
  '"stop_guard_attempt_seq": "0"' \
  "$(jq . "${STATE_ROOT}/stop_cross_interval_callback/session_state.json")"
assert_contains "old guard consumes no G2 background marker" \
  '"bg_work_dispatched_ts": "777"' \
  "$(jq . "${STATE_ROOT}/stop_cross_interval_callback/session_state.json")"

# Narrow check/use races still exist after the broad capture barrier: a Stop
# can finish wait correlation or pass the guard, then queue on the state lock
# while a new interval is activated.  The actual mutation helpers must compare
# the frozen generation while holding that lock.
seed_ready wait_mutation_cross_interval
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1",
    bg_work_dispatched_ts:"old-marker"}' \
  "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json" \
  >"${STATE_ROOT}/wait_mutation_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json"
wait_mutation_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json")"
jq -nc --argjson objective_ts "${wait_mutation_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"wait-race-native",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1,
  ulw_enforcement_generation:"1"
}' >"${STATE_ROOT}/wait_mutation_cross_interval/pending_agents.jsonl"
wait_mutation_payload="$(jq -nc --arg sid wait_mutation_cross_interval \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"wait-race-native",type:"subagent",
      status:"running",description:"Wave 3 quality-reviewer",
      agent_type:"quality-reviewer"}],session_crons:[]
  }')"
wait_mutation_ready="${TEST_HOME}/wait-mutation.ready"
wait_mutation_release="${TEST_HOME}/wait-mutation.release"
wait_mutation_output="${TEST_HOME}/wait-mutation.output"
export OMC_TEST_STOP_WAIT_MUTATION_READY_FILE="${wait_mutation_ready}"
export OMC_TEST_STOP_WAIT_MUTATION_RELEASE_FILE="${wait_mutation_release}"
run_dispatch_payload "${wait_mutation_payload}" \
  >"${wait_mutation_output}" 2>&1 &
wait_mutation_pid=$!
for _wait_mutation_count in $(seq 1 200); do
  [[ -f "${wait_mutation_ready}" ]] && break
  sleep 0.02
done
if [[ -f "${wait_mutation_ready}" ]]; then
  ok
else
  bad "old Stop wait callback did not reach mutation barrier"
fi
jq '.ulw_enforcement_generation="2"
    | .ulw_enforcement_active="1"
    | .bg_work_dispatched_ts="new-interval-marker"' \
  "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json" \
  >"${STATE_ROOT}/wait_mutation_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json"
touch "${wait_mutation_release}"
wait "${wait_mutation_pid}"
unset OMC_TEST_STOP_WAIT_MUTATION_READY_FILE \
  OMC_TEST_STOP_WAIT_MUTATION_RELEASE_FILE
assert_empty "old wait callback is inert after lock-time generation change" \
  "$(cat "${wait_mutation_output}")"
assert_contains "old wait callback preserves G2 background marker" \
  '"bg_work_dispatched_ts": "new-interval-marker"' \
  "$(jq . "${STATE_ROOT}/wait_mutation_cross_interval/session_state.json")"

seed_ready auth_clear_remove_failure
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1"}' \
  "${STATE_ROOT}/auth_clear_remove_failure/session_state.json" \
  >"${STATE_ROOT}/auth_clear_remove_failure/session_state.json.tmp"
mv "${STATE_ROOT}/auth_clear_remove_failure/session_state.json.tmp" \
  "${STATE_ROOT}/auth_clear_remove_failure/session_state.json"
run_preflight auth_clear_remove_failure >/dev/null
mkdir "${STATE_ROOT}/auth_clear_remove_failure/quality_constitution_authorization.json"
auth_clear_remove_failure_out="$(run_dispatch auth_clear_remove_failure \
  "$(closeout_message 'Authorization cleanup must be part of accepted Stop.')")"
assert_contains "non-removable authorization blocks accepted Stop" \
  "quality-constitution-authorization" "${auth_clear_remove_failure_out}"
if [[ "$(jq -r '.session_outcome // ""' \
    "${STATE_ROOT}/auth_clear_remove_failure/session_state.json")" == "" \
    && "$(jq -r '.ulw_enforcement_active // ""' \
      "${STATE_ROOT}/auth_clear_remove_failure/session_state.json")" == "1" ]]; then
  ok
else
  bad "authorization removal failure stamped a terminal Stop outcome"
fi
if [[ -d "${STATE_ROOT}/auth_clear_remove_failure/quality_constitution_authorization.json" ]]; then
  ok
else
  bad "authorization removal failure laundered the unsafe node"
fi
rm -rf "${STATE_ROOT}/auth_clear_remove_failure/quality_constitution_authorization.json"

seed_ready auth_clear_cross_interval
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1"}' \
  "${STATE_ROOT}/auth_clear_cross_interval/session_state.json" \
  >"${STATE_ROOT}/auth_clear_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/auth_clear_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/auth_clear_cross_interval/session_state.json"
run_preflight auth_clear_cross_interval >/dev/null
auth_clear_ready="${TEST_HOME}/auth-clear.ready"
auth_clear_release="${TEST_HOME}/auth-clear.release"
auth_clear_output="${TEST_HOME}/auth-clear.output"
auth_clear_payload="$(stop_payload auth_clear_cross_interval \
  "$(closeout_message 'Old interval candidate must not consume a new grant.')")"
export OMC_TEST_STOP_AUTH_CLEAR_READY_FILE="${auth_clear_ready}"
export OMC_TEST_STOP_AUTH_CLEAR_RELEASE_FILE="${auth_clear_release}"
run_dispatch_payload "${auth_clear_payload}" >"${auth_clear_output}" 2>&1 &
auth_clear_pid=$!
for _auth_clear_count in $(seq 1 200); do
  [[ -f "${auth_clear_ready}" ]] && break
  sleep 0.02
done
if [[ -f "${auth_clear_ready}" ]]; then
  ok
else
  bad "old accepted Stop did not reach authorization-clear barrier"
fi
jq '.ulw_enforcement_generation="2"
    | .ulw_enforcement_active="1"
    | .session_outcome=""' \
  "${STATE_ROOT}/auth_clear_cross_interval/session_state.json" \
  >"${STATE_ROOT}/auth_clear_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/auth_clear_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/auth_clear_cross_interval/session_state.json"
printf '%s\n' '{"schema_version":1,"grant":"g2"}' \
  >"${STATE_ROOT}/auth_clear_cross_interval/quality_constitution_authorization.json"
touch "${auth_clear_release}"
wait "${auth_clear_pid}"
unset OMC_TEST_STOP_AUTH_CLEAR_READY_FILE OMC_TEST_STOP_AUTH_CLEAR_RELEASE_FILE
assert_empty "old accepted Stop is inert after G2 authorization issue" \
  "$(cat "${auth_clear_output}")"
if [[ -f "${STATE_ROOT}/auth_clear_cross_interval/quality_constitution_authorization.json" ]]; then
  ok
else
  bad "old accepted Stop deleted the G2 Constitution authorization"
fi

seed_ready continuation_mutation_cross_interval
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1",
    closeout_dispatch_continuations:"0"}' \
  "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json" \
  >"${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json"
continuation_mutation_ready="${TEST_HOME}/continuation-mutation.ready"
continuation_mutation_release="${TEST_HOME}/continuation-mutation.release"
continuation_mutation_output="${TEST_HOME}/continuation-mutation.output"
continuation_mutation_payload="$(stop_payload \
  continuation_mutation_cross_interval \
  "$(closeout_message 'G1 blocked candidate before a G2 prompt.')")"
export OMC_TEST_STOP_CONTINUATION_MUTATION_READY_FILE="${continuation_mutation_ready}"
export OMC_TEST_STOP_CONTINUATION_MUTATION_RELEASE_FILE="${continuation_mutation_release}"
run_dispatch_payload "${continuation_mutation_payload}" \
  >"${continuation_mutation_output}" 2>&1 &
continuation_mutation_pid=$!
for _continuation_mutation_count in $(seq 1 200); do
  [[ -f "${continuation_mutation_ready}" ]] && break
  sleep 0.02
done
if [[ -f "${continuation_mutation_ready}" ]]; then
  ok
else
  bad "old blocked Stop did not reach continuation mutation barrier"
fi
jq '.ulw_enforcement_generation="2"
    | .ulw_enforcement_active="1"
    | .closeout_dispatch_continuations="0"
    | .session_outcome=""' \
  "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json" \
  >"${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json"
touch "${continuation_mutation_release}"
wait "${continuation_mutation_pid}"
unset OMC_TEST_STOP_CONTINUATION_MUTATION_READY_FILE \
  OMC_TEST_STOP_CONTINUATION_MUTATION_RELEASE_FILE
assert_empty "old blocked Stop emits no continuation after G2 rotation" \
  "$(cat "${continuation_mutation_output}")"
assert_contains "old blocked Stop increments no G2 continuation counter" \
  '"closeout_dispatch_continuations": "0"' \
  "$(jq . "${STATE_ROOT}/continuation_mutation_cross_interval/session_state.json")"

seed_ready false_wait_context_cross_interval
jq '. + {ulw_enforcement_active:"1",ulw_enforcement_generation:"1",
    bg_work_dispatched_ts:"g1-wait-marker"}' \
  "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json" \
  >"${STATE_ROOT}/false_wait_context_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json"
false_wait_objective_ts="$(jq -r '.review_cycle_prompt_ts' \
  "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json")"
jq -nc --argjson objective_ts "${false_wait_objective_ts}" '{
  agent_type:"quality-reviewer",native_agent_id:"false-wait-race",ts:1,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:$objective_ts,review_revision:1,
  ulw_enforcement_generation:"1"
}' >"${STATE_ROOT}/false_wait_context_cross_interval/pending_agents.jsonl"
false_wait_payload="$(jq -nc --arg sid false_wait_context_cross_interval \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
false_wait_ready="${TEST_HOME}/false-wait-context.ready"
false_wait_release="${TEST_HOME}/false-wait-context.release"
false_wait_output="${TEST_HOME}/false-wait-context.output"
export OMC_TEST_STOP_FALSE_WAIT_CONTEXT_READY_FILE="${false_wait_ready}"
export OMC_TEST_STOP_FALSE_WAIT_CONTEXT_RELEASE_FILE="${false_wait_release}"
OMC_STOP_FEEDBACK_MODE=modern run_dispatch_payload "${false_wait_payload}" \
  >"${false_wait_output}" 2>&1 &
false_wait_pid=$!
for _false_wait_count in $(seq 1 200); do
  [[ -f "${false_wait_ready}" ]] && break
  sleep 0.02
done
if [[ -f "${false_wait_ready}" ]]; then
  ok
else
  bad "old dead-wait Stop did not reach context barrier"
fi
jq '.ulw_enforcement_generation="2"
    | .ulw_enforcement_active="1"
    | .bg_work_dispatched_ts="g2-wait-marker"' \
  "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json" \
  >"${STATE_ROOT}/false_wait_context_cross_interval/session_state.json.tmp"
mv "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json.tmp" \
  "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json"
touch "${false_wait_release}"
wait "${false_wait_pid}"
unset OMC_TEST_STOP_FALSE_WAIT_CONTEXT_READY_FILE \
  OMC_TEST_STOP_FALSE_WAIT_CONTEXT_RELEASE_FILE
assert_empty "old dead-wait Stop emits no G1 recovery into G2" \
  "$(cat "${false_wait_output}")"
assert_contains "old dead-wait context preserves G2 marker" \
  '"bg_work_dispatched_ts": "g2-wait-marker"' \
  "$(jq . "${STATE_ROOT}/false_wait_context_cross_interval/session_state.json")"

generic_wait='⏳ Waiting on npm test — running in the background; I'"'"'ll resume automatically when it finishes. Nothing for you to do.'
seed_ready wait_generic_live
generic_live_payload="$(jq -nc --arg sid wait_generic_live \
  --arg msg "${generic_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"shell-test",type:"shell",status:"running",
      description:"npm test",command:"npm test"}],session_crons:[]
  }')"
generic_live_out="$(run_dispatch_payload "${generic_live_payload}")"
assert_empty "generic wait correlates to its live shell task" "${generic_live_out}"

seed_ready wait_generic_unrelated
generic_unrelated_payload="$(jq -nc --arg sid wait_generic_unrelated \
  --arg msg "${generic_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"shell-dev",type:"shell",status:"running",
      description:"development server",command:"npm run dev"}],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern generic_unrelated_out="$(run_dispatch_payload \
  "${generic_unrelated_payload}")"
assert_contains "generic wait cannot borrow an unrelated shell task" \
  "no live background wake source matching the promised worker" \
  "${generic_unrelated_out}"

near_collision_wait='⏳ Waiting on the frontend build — running in the background; I'"'"'ll resume automatically when it finishes. Nothing for you to do.'
seed_ready wait_generic_near_collision
near_collision_payload="$(jq -nc --arg sid wait_generic_near_collision \
  --arg msg "${near_collision_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"frontend-dev",type:"shell",status:"running",
      description:"frontend development server",command:"npm run dev"}],
    session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern near_collision_out="$(run_dispatch_payload \
  "${near_collision_payload}")"
assert_contains "one shared task word cannot validate generic wait" \
  "no live background wake source matching the promised worker" \
  "${near_collision_out}"

seed_ready wait_body_role_final_shell
body_role_message=$'quality-reviewer completed earlier.\n'"${generic_wait}"
body_role_payload="$(jq -nc --arg sid wait_body_role_final_shell \
  --arg msg "${body_role_message}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"shell-test",type:"shell",status:"running",
      description:"npm test",command:"npm test"}],session_crons:[]
  }')"
body_role_out="$(run_dispatch_payload "${body_role_payload}")"
assert_empty "body role mention cannot override final shell wait identity" \
  "${body_role_out}"

scheduled_wait='⏳ **Waiting for the scheduled 20-minute fallback check** — this session is scheduled to wake for the next check. Nothing for you to do.'
seed_ready wait_scheduled
scheduled_payload="$(jq -nc --arg sid wait_scheduled --arg msg "${scheduled_wait}" '{
  session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
  last_assistant_message:$msg,background_tasks:[],
  session_crons:[{id:"cron-1",schedule:"*/20 * * * *",recurring:true,
    prompt:"fallback check"}]
}')"
scheduled_out="$(run_dispatch_payload "${scheduled_payload}")"
assert_empty "compatible scheduled wake is a nonterminal wait" "${scheduled_out}"
assert_empty "scheduled wait consumes no continuation slot" \
  "$(jq -r '.closeout_dispatch_continuations // empty' \
    "${STATE_ROOT}/wait_scheduled/session_state.json")"

seed_ready wait_scheduled_empty
scheduled_empty_payload="$(jq -nc --arg sid wait_scheduled_empty \
  --arg msg "${scheduled_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],session_crons:[]
  }')"
OMC_STOP_FEEDBACK_MODE=modern scheduled_empty_out="$(run_dispatch_payload \
  "${scheduled_empty_payload}")"
assert_contains "missing scheduled wake gets schedule-specific recovery" \
  "no scheduled wake matching the promised check" \
  "${scheduled_empty_out}"
assert_not_contains "scheduled recovery never resumes an unrelated worker" \
  "SendMessage" "${scheduled_empty_out}"

seed_ready wait_scheduled_unrelated
scheduled_unrelated_payload="$(jq -nc --arg sid wait_scheduled_unrelated \
  --arg msg "${scheduled_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],
    session_crons:[{id:"weekly-report",schedule:"0 9 * * 1",recurring:true,
      prompt:"publish weekly revenue report"}]
  }')"
OMC_STOP_FEEDBACK_MODE=modern scheduled_unrelated_out="$(run_dispatch_payload \
  "${scheduled_unrelated_payload}")"
assert_contains "unrelated cron cannot validate a scheduled wait" \
  "no scheduled wake matching the promised check" \
  "${scheduled_unrelated_out}"

seed_ready wait_scheduled_near_collision
scheduled_near_payload="$(jq -nc --arg sid wait_scheduled_near_collision \
  --arg msg "${scheduled_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],
    session_crons:[{id:"deploy-fallback",schedule:"*/20 * * * *",
      recurring:true,prompt:"fallback deployment"}]
  }')"
OMC_STOP_FEEDBACK_MODE=modern scheduled_near_out="$(run_dispatch_payload \
  "${scheduled_near_payload}")"
assert_contains "single shared cron word cannot validate scheduled wait" \
  "no scheduled wake matching the promised check" \
  "${scheduled_near_out}"

seed_ready wait_cron_not_task
cron_not_task_payload="$(jq -nc --arg sid wait_cron_not_task \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[],
    session_crons:[{id:"cron-1",schedule:"*/20 * * * *",recurring:true,
      prompt:"fallback check"}]
  }')"
OMC_STOP_FEEDBACK_MODE=modern cron_not_task_out="$(run_dispatch_payload \
  "${cron_not_task_payload}")"
assert_contains "cron cannot validate a background completion promise" \
  "no live background wake source" "${cron_not_task_out}"

# Omitted fields mean old-client/unknown, not authoritative emptiness. The
# normal closeout guard may still continue, but it must not claim the task is
# dead. Conversely, a completion report with live tasks is never a wait claim
# and still traverses the ordinary quality gates.
seed_ready wait_legacy_unknown
legacy_wait_payload="$(jq -nc --arg sid wait_legacy_unknown --arg msg "${canonical_wait}" '{
  session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
  last_assistant_message:$msg
}')"
legacy_wait_out="$(run_dispatch_payload "${legacy_wait_payload}")"
assert_not_contains "absent runtime registry is not asserted dead" \
  "no live background wake source" "${legacy_wait_out}"

seed_ready wait_malformed_unknown
malformed_wait_payload="$(jq -nc --arg sid wait_malformed_unknown \
  --arg msg "${canonical_wait}" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,background_tasks:[{status:null}],session_crons:[]
  }')"
malformed_wait_out="$(run_dispatch_payload "${malformed_wait_payload}")"
assert_not_contains "malformed runtime registry is not asserted dead" \
  "no live background wake source" "${malformed_wait_out}"
assert_not_contains "malformed runtime registry never takes verified WAIT bypass" \
  "verified-live" \
  "$(cat "${STATE_ROOT}/wait_malformed_unknown/gate_events.jsonl" 2>/dev/null || true)"

seed_ready completion_with_live_task
completion_live_payload="$(jq -nc --arg sid completion_with_live_task \
  --arg msg "$(closeout_message)" '{
    session_id:$sid,hook_event_name:"Stop",stop_hook_active:false,
    last_assistant_message:$msg,
    background_tasks:[{id:"shell-1",type:"shell",status:"running",
      description:"npm test",command:"npm test"}],session_crons:[]
  }')"
completion_live_out="$(run_dispatch_payload "${completion_live_payload}")"
assert_contains "live task cannot turn completion prose into a WAIT bypass" \
  "closeout check" "${completion_live_out}"

# Auto mode follows the Claude Code runtime boundary: 2.1.162 needs the
# compatibility decision:block form, while 2.1.163 supports non-error Stop
# feedback through hookSpecificOutput.additionalContext.
seed_ready auto_162
auto_162_out="$(run_dispatch_auto_version auto_162 "$(closeout_message)" 2.1.162)"
assert_single_json "2.1.162 auto feedback emits one JSON object" "${auto_162_out}"
if jq -e '.decision == "block" and (.reason | contains("closeout check")) and (has("hookSpecificOutput") | not)' \
    <<<"${auto_162_out}" >/dev/null; then
  ok
else
  bad "2.1.162 did not use legacy decision:block feedback"
fi

seed_ready auto_163
auto_163_out="$(run_dispatch_auto_version auto_163 "$(closeout_message)" 2.1.163)"
assert_single_json "2.1.163 auto feedback emits one JSON object" "${auto_163_out}"
if jq -e '.hookSpecificOutput.hookEventName == "Stop" and (.hookSpecificOutput.additionalContext | contains("closeout check")) and (has("decision") | not)' \
    <<<"${auto_163_out}" >/dev/null; then
  ok
else
  bad "2.1.163 did not use modern Stop additionalContext feedback"
fi

# The shared .ulw_active marker is only a fast-path hint. An ordinary Stop in
# another concurrent session must not remove it or disable certification for
# the addressed ULW session.
seed_ready multi_ulw
mkdir -p "${STATE_ROOT}/multi_ordinary"
jq -nc '{workflow_mode:"",task_intent:"advisory"}' >"${STATE_ROOT}/multi_ordinary/session_state.json"
touch "${STATE_ROOT}/.ulw_active"
ordinary_stop_out="$(run_dispatch multi_ordinary 'Ordinary answer.')"
assert_empty "ordinary session Stop stays silent" "${ordinary_stop_out}"
[[ -f "${STATE_ROOT}/.ulw_active" ]] && ok || bad "ordinary session Stop removed another session's ULW marker"
multi_ulw_out="$(run_dispatch multi_ulw "$(closeout_message)")"
assert_contains "ULW session remains enforced after ordinary Stop" "closeout check" "${multi_ulw_out}"

# Bootstrap authority uses the same migration semantics as common.sh: numeric
# 1 is active, explicit 0 is inactive, and null/unknown remains fail-closed
# while the legacy interval has no terminal outcome.
seed_ready numeric_authority
jq '.ulw_enforcement_active=1' \
  "${STATE_ROOT}/numeric_authority/session_state.json" \
  >"${STATE_ROOT}/numeric_authority/session_state.json.tmp"
mv "${STATE_ROOT}/numeric_authority/session_state.json.tmp" \
  "${STATE_ROOT}/numeric_authority/session_state.json"
assert_contains "numeric-one authority cannot bypass Stop certification" \
  "closeout check" "$(run_dispatch numeric_authority "$(closeout_message)")"

seed_ready null_authority
jq '.ulw_enforcement_active=null | .session_outcome=""' \
  "${STATE_ROOT}/null_authority/session_state.json" \
  >"${STATE_ROOT}/null_authority/session_state.json.tmp"
mv "${STATE_ROOT}/null_authority/session_state.json.tmp" \
  "${STATE_ROOT}/null_authority/session_state.json"
assert_contains "null migration authority remains fail-closed" \
  "closeout check" "$(run_dispatch null_authority "$(closeout_message)")"

seed_ready zero_authority
jq '.ulw_enforcement_active=0 | .session_outcome=""' \
  "${STATE_ROOT}/zero_authority/session_state.json" \
  >"${STATE_ROOT}/zero_authority/session_state.json.tmp"
mv "${STATE_ROOT}/zero_authority/session_state.json.tmp" \
  "${STATE_ROOT}/zero_authority/session_state.json"
touch "${STATE_ROOT}/zero_authority/.ulw_active"
assert_empty "explicit numeric-zero authority remains inactive" \
  "$(run_dispatch zero_authority "$(closeout_message)")"

# The outer Stop owner must survive dependency failure before common.sh can be
# sourced. Exact per-session authority fails closed without jq; a process-wide
# marker alone never captures an unrelated ordinary Stop.
no_jq_active_sid="no_jq_active"
mkdir -p "${STATE_ROOT}/${no_jq_active_sid}"
touch "${STATE_ROOT}/${no_jq_active_sid}/.ulw_active" "${STATE_ROOT}/.ulw_active"
no_jq_active_payload="$(stop_payload "${no_jq_active_sid}" 'NO-JQ-CANDIDATE')"
no_jq_active_out="$(
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    OMC_TEST_STOP_FORCE_JQ_FAILURE=1 PATH="${TEST_HOME}/path-without-jq" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${no_jq_active_payload}"
)"
assert_single_json "missing jq with exact authority emits one response" "${no_jq_active_out}"
if jq -e '.decision == "block" and (.reason | contains("jq is missing or failed"))' \
    <<<"${no_jq_active_out}" >/dev/null; then
  ok
else
  bad "missing jq did not fail closed for the exact active session"
fi

no_jq_ordinary_payload="$(stop_payload no_jq_ordinary 'ordinary response')"
no_jq_ordinary_out="$(
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    OMC_TEST_STOP_FORCE_JQ_FAILURE=1 PATH="${TEST_HOME}/path-without-jq" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${no_jq_ordinary_payload}"
)"
assert_empty "missing jq plus only a global marker does not capture ordinary Stop" \
  "${no_jq_ordinary_out}"

seed_ready malicious_jq_active
malicious_path="${TEST_HOME}/malicious-path"
mkdir -p "${malicious_path}"
printf '#!/bin/sh\nexit 0\n' >"${malicious_path}/jq"
chmod +x "${malicious_path}/jq"
malicious_jq_payload="$(stop_payload malicious_jq_active "$(closeout_message)")"
malicious_jq_out="$(
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    PATH="${malicious_path}:${PATH}" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${malicious_jq_payload}"
)"
assert_contains "caller-PATH jq cannot bypass active Stop certification" \
  "closeout check" "${malicious_jq_out}"

# Exported Bash functions resolve before PATH.  They must not bypass the same
# trusted-observer boundary merely because the caller exported a jq function.
malicious_jq_function_out="$(
  jq() { return 0; }
  export -f jq
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" PATH="${PATH}" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${malicious_jq_payload}"
)"
assert_contains "caller-function jq cannot bypass active Stop certification" \
  "closeout check" "${malicious_jq_function_out}"

jq_parse_sid="jq_parse_active"
mkdir -p "${STATE_ROOT}/${jq_parse_sid}"
touch "${STATE_ROOT}/${jq_parse_sid}/.ulw_active"
jq_parse_out="$(
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" \
    <<<'{"session_id":"jq_parse_active",BROKEN'
)"
assert_contains "broken jq parse with exact authority fails closed" \
  '"decision":"block"' "${jq_parse_out}"

# Enforcement authority belongs to each addressed session, not the process-wide
# fast hint. Completing A must ignore a late A callback while B remains live and
# continues recording edits under the same global marker.
seed_ready authority_a
seed_ready authority_b
for _authority_sid in authority_a authority_b; do
  jq '.ulw_enforcement_active="1"' "${STATE_ROOT}/${_authority_sid}/session_state.json" \
    >"${STATE_ROOT}/${_authority_sid}/session_state.json.tmp"
  mv "${STATE_ROOT}/${_authority_sid}/session_state.json.tmp" "${STATE_ROOT}/${_authority_sid}/session_state.json"
  touch "${STATE_ROOT}/${_authority_sid}/.ulw_active"
done
run_preflight authority_a >/dev/null
authority_a_release="$(run_dispatch authority_a "$(closeout_message 'Completed session A without closing session B.')")"
assert_contains "session A reaches a certified completion" "quality checks passed" "${authority_a_release}"
[[ "$(jq -r '.ulw_enforcement_active // empty' "${STATE_ROOT}/authority_a/session_state.json")" == "0" ]] \
  && ok || bad "session A did not close its enforcement interval"
[[ -f "${STATE_ROOT}/.ulw_active" && -f "${STATE_ROOT}/authority_b/.ulw_active" ]] \
  && ok || bad "session A completion removed session B authority"
authority_a_revision="$(jq -r '.edit_revision' "${STATE_ROOT}/authority_a/session_state.json")"
run_mark_edit authority_a /src/late-authority-a.ts >/dev/null
if [[ "$(jq -r '.edit_revision' "${STATE_ROOT}/authority_a/session_state.json")" == "${authority_a_revision}" ]] \
    && ! grep -Fxq -- '/src/late-authority-a.ts' "${STATE_ROOT}/authority_a/edited_files.log"; then
  ok
else
  bad "late session A callback mutated completed-session evidence"
fi
authority_b_revision="$(jq -r '.edit_revision' "${STATE_ROOT}/authority_b/session_state.json")"
run_mark_edit authority_b /src/live-authority-b.ts >/dev/null
if [[ "$(jq -r '.edit_revision' "${STATE_ROOT}/authority_b/session_state.json")" == "$((authority_b_revision + 1))" ]] \
    && grep -Fxq -- '/src/live-authority-b.ts' "${STATE_ROOT}/authority_b/edited_files.log"; then
  ok
else
  bad "active session B stopped recording after session A completed"
fi

# Happy path: hidden preflight seals, Stop passes, and the receipt is present
# even with timing disabled/below its historical five-second card threshold.
seed_ready pass
ready_context="$(run_preflight pass)"
assert_contains "preflight ready before pass" "READY" "${ready_context}"
pass_out="$(run_dispatch pass "$(closeout_message 'Implemented the dispatcher, seal, display guard, and cumulative final contract.')")"
if jq -e '.systemMessage | contains("quality checks passed")' <<<"${pass_out}" >/dev/null; then ok; else bad "completed release missing pass receipt"; fi
assert_contains "pass receipt names harness" "oh-my-claude" "${pass_out}"
[[ "$(jq -r '.session_outcome' "${STATE_ROOT}/pass/session_state.json")" == "completed" ]] && ok || bad "pass did not stamp completed"
[[ -n "$(jq -r '.closeout_finalized_token // empty' "${STATE_ROOT}/pass/session_state.json")" ]] && ok || bad "pass did not claim finalization"

# Accepted child publication failure abandons only its exact finalizer claim,
# retains the provisional candidate, and allows a fresh claimant to retry.
seed_ready finalizer_publish_retry
run_preflight finalizer_publish_retry >/dev/null
finalizer_transcript="${TEST_HOME}/finalizer-publish-retry.jsonl"
printf '%s\n' '{"type":"user","message":"retry finalizer"}' \
  >"${finalizer_transcript}"
finalizer_retry_message="$(closeout_message 'Completed with retryable archive publication.')"
finalizer_retry_payload="$(stop_payload finalizer_publish_retry \
  "${finalizer_retry_message}" false \
  | jq --arg transcript "${finalizer_transcript}" \
      '. + {transcript_path:$transcript}')"
OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
  OMC_TEST_TRANSCRIPT_ARCHIVE_PUBLISH_FAIL=1 \
  run_dispatch_payload "${finalizer_retry_payload}" >/dev/null
assert_empty "failed accepted child abandons finalizer status" \
  "$(jq -r '.closeout_finalization_status // empty' \
    "${STATE_ROOT}/finalizer_publish_retry/session_state.json")"
assert_empty "failed accepted child clears its claimant identity" \
  "$(jq -r '.closeout_finalization_claim_id // empty' \
    "${STATE_ROOT}/finalizer_publish_retry/session_state.json")"
[[ -s "${STATE_ROOT}/finalizer_publish_retry/provisional_closeouts.jsonl" ]] \
  && ok || bad "failed accepted child discarded provisional closeout evidence"
OMC_TRANSCRIPT_ARCHIVE=on OMC_STOP_FAILURE_CAPTURE=on \
  run_dispatch_payload "${finalizer_retry_payload}" >/dev/null
[[ "$(jq -r '.closeout_finalization_status // empty' \
    "${STATE_ROOT}/finalizer_publish_retry/session_state.json")" == "complete" ]] \
  && ok || bad "fresh finalizer retry did not complete"
finalizer_archive_count="$(find "${TEST_HOME}/.claude/quality-pack/state" \
  -path '*/finalizer_publish_retry/transcript.json' -type f \
  | wc -l | tr -d '[:space:]')"
[[ "${finalizer_archive_count}" == "1" ]] \
  && ok || bad "fresh finalizer retry did not publish exactly one archive"
[[ ! -s "${STATE_ROOT}/finalizer_publish_retry/provisional_closeouts.jsonl" ]] \
  && ok || bad "successful finalizer retry retained provisional evidence"

# The visible pass receipt is part of accepted-release UX, not a best-effort
# canary/archive side effect. A live/stuck finalizer lease may suppress duplicate
# finalizers, but it must not suppress the proof that the guard accepted Stop.
seed_ready receipt_with_live_lease
run_preflight receipt_with_live_lease >/dev/null
now_lease="$(date +%s)"
jq --arg ts "${now_lease}" '
  .closeout_finalized_token="1:1:completed"
  | .closeout_finalization_status="claimed"
  | .closeout_finalization_claimed_ts=$ts
' "${STATE_ROOT}/receipt_with_live_lease/session_state.json" \
  >"${STATE_ROOT}/receipt_with_live_lease/session_state.json.tmp"
mv "${STATE_ROOT}/receipt_with_live_lease/session_state.json.tmp" \
  "${STATE_ROOT}/receipt_with_live_lease/session_state.json"
lease_receipt_out="$(run_dispatch receipt_with_live_lease "$(closeout_message 'Completed despite an independently owned finalizer lease.')")"
assert_contains "accepted Stop receipt survives a live finalizer lease" \
  "quality checks passed" "${lease_receipt_out}"

# Finalizer ownership is a recoverable lease: one live claimant wins, abandon
# permits retry, completion is terminal for the token, and a stale claim can
# be reclaimed after the 120-second lease window.
seed_ready lease_complete
jq '.session_outcome="completed"' "${STATE_ROOT}/lease_complete/session_state.json" \
  >"${STATE_ROOT}/lease_complete/session_state.json.tmp"
mv "${STATE_ROOT}/lease_complete/session_state.json.tmp" "${STATE_ROOT}/lease_complete/session_state.json"
lease_complete_claim="$(run_finalization_op lease_complete claim)"
[[ "${lease_complete_claim}" =~ ^finalizer-[a-f0-9]{48}$ ]] && ok || bad "initial finalization lease claim failed"
lease_claimed_ts="$(jq -r '.closeout_finalization_claimed_ts // empty' "${STATE_ROOT}/lease_complete/session_state.json")"
[[ "${lease_claimed_ts}" =~ ^[0-9]+$ ]] && ok || bad "initial finalization claim did not stamp a timestamp"
[[ "$(run_finalization_op lease_complete claim)" == "denied" ]] && ok || bad "second live finalization claimant was not denied"
[[ "$(run_finalization_op lease_complete abandon "${lease_complete_claim}")" == "abandoned" ]] && ok || bad "claimed finalization lease could not be abandoned"
assert_empty "abandon clears finalization status" \
  "$(jq -r '.closeout_finalization_status // empty' "${STATE_ROOT}/lease_complete/session_state.json")"
lease_complete_reclaim="$(run_finalization_op lease_complete claim)"
[[ "${lease_complete_reclaim}" =~ ^finalizer-[a-f0-9]{48}$ \
    && "${lease_complete_reclaim}" != "${lease_complete_claim}" ]] \
  && ok || bad "abandoned finalization lease was not reclaimed with fresh identity"
[[ "$(run_finalization_op lease_complete complete "${lease_complete_reclaim}")" == "completed" ]] && ok || bad "claimed finalization lease could not complete"
[[ "$(jq -r '.closeout_finalization_status // empty' "${STATE_ROOT}/lease_complete/session_state.json")" == "complete" ]] \
  && ok || bad "completed finalization lease did not persist terminal status"
[[ "$(run_finalization_op lease_complete claim)" == "denied" ]] && ok || bad "completed finalization token was claimable again"

# Current-token lease timestamps are durable concurrency authority. Oversized
# digit strings must fail closed before Bash arithmetic instead of wrapping to
# an apparently expired value and admitting a second finalizer.
seed_ready lease_malformed_timestamp
jq '.session_outcome="completed"
  | .closeout_finalized_token="1:1:completed"
  | .closeout_finalization_status="claimed"
  | .closeout_finalization_claimed_ts="1000000000000000000000000"
  | .closeout_finalization_claim_id="finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "${STATE_ROOT}/lease_malformed_timestamp/session_state.json" \
  >"${STATE_ROOT}/lease_malformed_timestamp/session_state.json.tmp"
mv "${STATE_ROOT}/lease_malformed_timestamp/session_state.json.tmp" \
  "${STATE_ROOT}/lease_malformed_timestamp/session_state.json"
[[ "$(run_finalization_op lease_malformed_timestamp claim)" == "denied" ]] \
  && ok || bad "oversized current-token lease admitted a replacement claimant"
[[ "$(run_finalization_op lease_malformed_timestamp complete \
    finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == "denied" ]] \
  && ok || bad "oversized lease timestamp authorized finalizer completion"
[[ "$(run_finalization_op lease_malformed_timestamp abandon \
    finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" == "denied" ]] \
  && ok || bad "oversized lease timestamp authorized finalizer abandonment"
[[ "$(jq -r '.closeout_finalization_claim_id // empty' \
    "${STATE_ROOT}/lease_malformed_timestamp/session_state.json")" \
    == "finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] \
  && ok || bad "malformed lease rejection changed claimant authority"

seed_ready lease_future_timestamp
future_claimed_ts="$(( $(date +%s) + 86400 ))"
jq --arg ts "${future_claimed_ts}" '
  .session_outcome="completed"
  | .closeout_finalized_token="1:1:completed"
  | .closeout_finalization_status="claimed"
  | .closeout_finalization_claimed_ts=$ts
  | .closeout_finalization_claim_id="finalizer-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${STATE_ROOT}/lease_future_timestamp/session_state.json" \
  >"${STATE_ROOT}/lease_future_timestamp/session_state.json.tmp"
mv "${STATE_ROOT}/lease_future_timestamp/session_state.json.tmp" \
  "${STATE_ROOT}/lease_future_timestamp/session_state.json"
[[ "$(run_finalization_op lease_future_timestamp claim)" == "denied" ]] \
  && ok || bad "future-dated current-token lease admitted a replacement claimant"

seed_ready lease_stale
jq '.session_outcome="completed"' "${STATE_ROOT}/lease_stale/session_state.json" \
  >"${STATE_ROOT}/lease_stale/session_state.json.tmp"
mv "${STATE_ROOT}/lease_stale/session_state.json.tmp" "${STATE_ROOT}/lease_stale/session_state.json"
stale_claim_a="$(run_finalization_op lease_stale claim)"
[[ "${stale_claim_a}" =~ ^finalizer-[a-f0-9]{48}$ ]] && ok || bad "stale-lease fixture could not claim initially"
stale_floor="$(( $(date +%s) - 121 ))"
jq --arg ts "${stale_floor}" '.closeout_finalization_claimed_ts=$ts' \
  "${STATE_ROOT}/lease_stale/session_state.json" >"${STATE_ROOT}/lease_stale/session_state.json.tmp"
mv "${STATE_ROOT}/lease_stale/session_state.json.tmp" "${STATE_ROOT}/lease_stale/session_state.json"
stale_claim_b="$(run_finalization_op lease_stale claim)"
[[ "${stale_claim_b}" =~ ^finalizer-[a-f0-9]{48}$ \
    && "${stale_claim_b}" != "${stale_claim_a}" ]] \
  && ok || bad "expired finalization lease was not reclaimed with fresh identity"
reclaimed_ts="$(jq -r '.closeout_finalization_claimed_ts // empty' "${STATE_ROOT}/lease_stale/session_state.json")"
if [[ "${reclaimed_ts}" =~ ^[0-9]+$ ]] && (( reclaimed_ts > stale_floor )); then
  ok
else
  bad "stale finalization reclaim did not refresh the lease timestamp"
fi
[[ "$(run_finalization_op lease_stale complete "${stale_claim_a}")" == "denied" ]] \
  && ok || bad "expired claimant completed the replacement lease"
[[ "$(run_finalization_op lease_stale abandon "${stale_claim_a}")" == "denied" ]] \
  && ok || bad "expired claimant abandoned the replacement lease"
[[ "$(jq -r '.closeout_finalization_claim_id // empty' \
    "${STATE_ROOT}/lease_stale/session_state.json")" == "${stale_claim_b}" ]] \
  && ok || bad "stale ABA operations changed the current claimant identity"
[[ "$(run_finalization_op lease_stale complete "${stale_claim_b}")" == "completed" ]] \
  && ok || bad "replacement claimant could not complete its own lease"

# A suppressed rich candidate must not collapse into a thin retry. After a
# fresh seal, final-closure blocks the short delta and names cumulative repair.
run_preflight blocked >/dev/null
thin_msg="$(closeout_message 'Gate fixed.')"
thin_out="$(run_dispatch blocked "${thin_msg}" true)"
assert_contains "thin retry remains blocked" "closeout check" "${thin_out}"
assert_contains "thin retry asks whole replacement" "complete cumulative replacement" "${thin_out}"
[[ "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/blocked/session_state.json")" == "" ]] && ok || bad "thin retry incorrectly completed"

# End explicitly one continuation before Claude Code's eight-block ceiling.
# The seventh response is a visible degraded receipt that preserves the rich
# candidate instead of letting MessageDisplay suppression erase it.
seed_ready continuation_ceiling
ceiling_message="$(closeout_message 'CEILING-UNIQUE-DETAIL remains available for the exhausted replay.')"
for _continuation in 1 2 3 4 5 6; do
  ceiling_block="$(run_dispatch continuation_ceiling "${ceiling_message}" true)"
  if jq -e '.decision == "block" or ((.hookSpecificOutput.additionalContext // "") != "")' \
      <<<"${ceiling_block}" >/dev/null; then
    ok
  else
    bad "continuation ${_continuation} did not remain blocked before the explicit ceiling"
  fi
done
ceiling_out="$(run_dispatch continuation_ceiling "${ceiling_message}" true)"
assert_single_json "seventh continuation emits one explicit receipt" "${ceiling_out}"
if jq -e '.systemMessage | contains("before Claude Code'\''s Stop-continuation ceiling")' \
    <<<"${ceiling_out}" >/dev/null; then
  ok
else
  bad "seventh continuation did not emit the explicit pre-cap receipt"
fi
assert_contains "exhausted continuation replays the rich candidate" "CEILING-UNIQUE-DETAIL" "${ceiling_out}"
assert_contains "exhausted continuation labels candidate uncertified" "UNCERTIFIED CUMULATIVE CANDIDATE" "${ceiling_out}"
[[ "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/continuation_ceiling/session_state.json")" == "exhausted" ]] \
  && ok || bad "seventh continuation did not stamp exhausted outcome"
[[ "$(jq -r '.closeout_dispatch_continuations // empty' "${STATE_ROOT}/continuation_ceiling/session_state.json")" == "7" ]] \
  && ok || bad "continuation counter did not stop at seven"

# Claude Code exposes a configurable continuation cap. End visibly at cap-1,
# not at a hard-coded seventh attempt that the platform may never deliver.
seed_ready lowered_ceiling
lowered_message="$(closeout_message 'LOWERED-CAP-CANDIDATE')"
for _lowered_attempt in 1 2; do
  lowered_block="$(run_dispatch_with_cap lowered_ceiling "${lowered_message}" 4 true)"
  if jq -e '.decision == "block" or .hookSpecificOutput.hookEventName == "Stop"' \
      <<<"${lowered_block}" >/dev/null; then
    ok
  else
    bad "lowered-cap attempt ${_lowered_attempt} did not continue"
  fi
done
lowered_out="$(run_dispatch_with_cap lowered_ceiling "${lowered_message}" 4 true)"
assert_contains "configured cap=4 ends explicitly on attempt 3" \
  "before Claude Code's Stop-continuation ceiling" "${lowered_out}"
assert_contains "configured cap=4 preserves the candidate" \
  "LOWERED-CAP-CANDIDATE" "${lowered_out}"
[[ "$(jq -r '.closeout_dispatch_continuations // empty' "${STATE_ROOT}/lowered_ceiling/session_state.json")" == "3" ]] \
  && ok || bad "configured cap=4 did not terminate at cap-1"

seed_ready single_ceiling
single_out="$(run_dispatch_with_cap single_ceiling "$(closeout_message 'SINGLE-CAP-CANDIDATE')" 1 true)"
assert_contains "configured cap=1 ends visibly on the first attempt" \
  "before Claude Code's Stop-continuation ceiling" "${single_out}"
assert_contains "configured cap=1 preserves the candidate" \
  "SINGLE-CAP-CANDIDATE" "${single_out}"
[[ "$(jq -r '.closeout_dispatch_continuations // empty' "${STATE_ROOT}/single_ceiling/session_state.json")" == "1" ]] \
  && ok || bad "configured cap=1 did not terminate immediately"

# Candidate replay is user-visible terminal output. Preserve readable detail,
# but strip ESC/BEL control bytes before a forced-cap receipt can render it.
seed_ready control_candidate
control_message="$(closeout_message $'CONTROL-CANDIDATE-HEAD \033]0;PWNED\a CONTROL-CANDIDATE-TAIL')"
control_out="$(run_dispatch_with_cap control_candidate "${control_message}" 1 true)"
assert_contains "sanitized degraded replay preserves candidate head" \
  "CONTROL-CANDIDATE-HEAD" "${control_out}"
assert_contains "sanitized degraded replay preserves candidate tail" \
  "CONTROL-CANDIDATE-TAIL" "${control_out}"
if [[ "${control_out}" == *$'\033'* || "${control_out}" == *$'\a'* ]]; then
  bad "degraded candidate replay retained terminal control bytes"
else
  ok
fi

# If common.sh cannot be sourced, the dependency-light outer trap has no
# sanitizer contract. It must omit raw candidate text instead of replaying a
# secret or terminal-control sequence through systemMessage.
seed_ready emergency_source_failure
emergency_dir="${TEST_HOME}/dispatcher-without-common"
mkdir -p "${emergency_dir}"
cp "${HOOK_DIR}/stop-dispatch.sh" "${emergency_dir}/stop-dispatch.sh"
chmod +x "${emergency_dir}/stop-dispatch.sh"
emergency_candidate=$'EMERGENCY-RAW-CANDIDATE sk-ant-ABCDEFGHIJKLMNOPQRSTUV \033]0;PWNED\a'
emergency_out="$(hook_env /bin/bash "${emergency_dir}/stop-dispatch.sh" \
  <<<"$(stop_payload emergency_source_failure "${emergency_candidate}")")"
assert_single_json "source-failure emergency emits one bounded response" "${emergency_out}"
assert_contains "source-failure emergency names omitted replay" \
  "Candidate replay was omitted" "${emergency_out}"
assert_not_contains "source-failure emergency omits raw candidate" \
  "EMERGENCY-RAW-CANDIDATE" "${emergency_out}"
assert_not_contains "source-failure emergency omits raw secret" \
  "sk-ant-ABCDEFGHIJKLMNOPQRSTUV" "${emergency_out}"
if [[ "${emergency_out}" == *$'\033'* || "${emergency_out}" == *$'\a'* ]]; then
  bad "source-failure emergency retained terminal control bytes"
else
  ok
fi

# A failure after common.sh loaded has working sanitizers but still precedes
# the normal continuation renderer. Exercise that narrow emergency branch with
# a set HOOK_JSON value: `${value:-{}}` appends a literal `}` in Bash/zsh and
# would make this otherwise valid payload unparsable, silently omitting the
# candidate.
seed_ready emergency_after_common
after_common_candidate='EMERGENCY-AFTER-COMMON-CANDIDATE sk-ant-ABCDEFGHIJKLMNOPQRSTUV'
after_common_out="$(hook_env OMC_TEST_STOP_FAIL_AFTER_COMMON=1 \
  /bin/bash "${HOOK_DIR}/stop-dispatch.sh" \
  <<<"$(stop_payload emergency_after_common \
    "${after_common_candidate}")")"
assert_single_json "post-common emergency emits one bounded response" \
  "${after_common_out}"
assert_contains "post-common emergency preserves sanitized candidate" \
  "EMERGENCY-AFTER-COMMON-CANDIDATE" "${after_common_out}"
assert_contains "post-common emergency labels uncertified candidate" \
  "UNCERTIFIED CANDIDATE" "${after_common_out}"
assert_not_contains "post-common emergency redacts candidate secret" \
  "sk-ant-ABCDEFGHIJKLMNOPQRSTUV" "${after_common_out}"
assert_not_contains "post-common emergency does not take omitted branch" \
  "Candidate replay was omitted" "${after_common_out}"

nested_source_dir="${TEST_HOME}/dispatcher-without-state-lib"
mkdir -p "${nested_source_dir}/lib"
cp "${HOOK_DIR}/stop-dispatch.sh" "${HOOK_DIR}/common.sh" "${nested_source_dir}/"
cp "${HOOK_DIR}/lib/verification.sh" "${HOOK_DIR}/lib/timing.sh" \
  "${nested_source_dir}/lib/"
nested_source_out="$(hook_env /bin/bash "${nested_source_dir}/stop-dispatch.sh" \
  <<<"$(stop_payload emergency_source_failure "${emergency_candidate}")")"
assert_single_json "missing eager state library emits one bounded response" \
  "${nested_source_out}"
assert_contains "missing eager state library fails closed before source" \
  "Candidate replay was omitted" "${nested_source_out}"
assert_not_contains "missing eager state library omits raw candidate" \
  "EMERGENCY-RAW-CANDIDATE" "${nested_source_out}"

syntax_source_dir="${TEST_HOME}/dispatcher-with-invalid-state-lib"
mkdir -p "${syntax_source_dir}/lib"
cp "${HOOK_DIR}/stop-dispatch.sh" "${HOOK_DIR}/common.sh" "${syntax_source_dir}/"
cp "${HOOK_DIR}/lib/state-io.sh" "${HOOK_DIR}/lib/verification.sh" \
  "${HOOK_DIR}/lib/timing.sh" "${syntax_source_dir}/lib/"
printf '\nif then\n' >>"${syntax_source_dir}/lib/state-io.sh"
syntax_source_out="$(hook_env /bin/bash "${syntax_source_dir}/stop-dispatch.sh" \
  <<<"$(stop_payload emergency_source_failure "${emergency_candidate}")")"
assert_single_json "syntax-broken nested source emits one bounded response" \
  "${syntax_source_out}"
assert_contains "syntax-broken nested source fails closed before source" \
  "Candidate replay was omitted" "${syntax_source_out}"
assert_not_contains "syntax-broken nested source omits raw candidate" \
  "EMERGENCY-RAW-CANDIDATE" "${syntax_source_out}"

# Forced pre-cap exhaustion is a terminal state transition and therefore uses
# the same generation discipline as a clean release. If work/evidence moves
# after the guard result, accounting may advance but authority stays active.
seed_ready exhaustion_generation_race
jq '.closeout_dispatch_continuations="6" | .ulw_enforcement_active="1"' \
  "${STATE_ROOT}/exhaustion_generation_race/session_state.json" \
  >"${STATE_ROOT}/exhaustion_generation_race/session_state.json.tmp"
mv "${STATE_ROOT}/exhaustion_generation_race/session_state.json.tmp" \
  "${STATE_ROOT}/exhaustion_generation_race/session_state.json"
generation_race_result="$(hook_env SESSION_ID=exhaustion_generation_race bash -c '
  . "$1"
  eval "$(sed -n '\''/^_closeout_increment_dispatch_continuations_unlocked()/,/^}/p'\'' "$2")"
  expected="$(closeout_readiness_fingerprint)"
  jq '\''.current_objective="Concurrent mutation after guard"'\'' "$3" >"$3.tmp"
  mv "$3.tmp" "$3"
  with_state_lock _closeout_increment_dispatch_continuations_unlocked 7 8 "${expected}"
' -- "${HOOK_DIR}/common.sh" "${HOOK_DIR}/stop-dispatch.sh" \
  "${STATE_ROOT}/exhaustion_generation_race/session_state.json")"
if [[ "${generation_race_result}" == "7|generation-changed" ]]; then
  ok
else
  bad "forced exhaustion did not reject a changed generation (${generation_race_result})"
fi
assert_empty "generation-raced exhaustion leaves terminal outcome unset" \
  "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/exhaustion_generation_race/session_state.json")"
[[ "$(jq -r '.ulw_enforcement_active // empty' "${STATE_ROOT}/exhaustion_generation_race/session_state.json")" == "1" ]] \
  && ok || bad "generation-raced exhaustion closed active authority"

# The user's original failure shape: summary 1 carries the detail, then later
# Stop retries are thin. Semantic retention must replay the rich first candidate
# at forced exhaustion even after six newer candidates.
seed_ready rich_then_thin_ceiling
rich_first="$(closeout_message "RICH-SUMMARY-ONE-SENTINEL $(awk 'BEGIN { for (i=0; i<2600; i++) printf "d" }') RICH-SUMMARY-ONE-TAIL")"
run_dispatch rich_then_thin_ceiling "${rich_first}" true >/dev/null
for _thin in 2 3 4 5 6; do
  run_dispatch rich_then_thin_ceiling "Thin retry ${_thin}." true >/dev/null
done
rich_then_thin_out="$(run_dispatch rich_then_thin_ceiling 'Thin retry 7.' true)"
assert_contains "exhausted replay retains detailed summary 1 head" \
  "RICH-SUMMARY-ONE-SENTINEL" "${rich_then_thin_out}"
assert_contains "exhausted replay retains detailed summary 1 tail" \
  "RICH-SUMMARY-ONE-TAIL" "${rich_then_thin_out}"

# The pre-cap terminal commit and completion-claim check share one session
# lock. If a SubagentStop publisher owns a fresh claim, the dispatcher ends
# the platform turn visibly but leaves enforcement active for the next prompt.
seed_ready continuation_claim_busy
claim_now="$(date +%s)"
jq -nc --argjson ts "${claim_now}" '{
  agent_type:"quality-reviewer",review_dispatch_id:"busy-claim",
  completion_claim_id:"claim-in-progress",completion_claim_ts:$ts,
  completion_claim_effects_complete:false
}' >"${STATE_ROOT}/continuation_claim_busy/pending_agents.jsonl"
for _continuation in 1 2 3 4 5 6; do
  run_dispatch continuation_claim_busy "$(closeout_message 'CLAIM-BUSY-CANDIDATE')" true >/dev/null
done
claim_busy_out="$(run_dispatch continuation_claim_busy "$(closeout_message 'CLAIM-BUSY-CANDIDATE')" true)"
assert_single_json "seventh continuation with live claim emits one receipt" "${claim_busy_out}"
assert_contains "live completion claim is named at the pre-cap boundary" \
  "subagent completion is still publishing evidence" "${claim_busy_out}"
[[ "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/continuation_claim_busy/session_state.json")" == "" ]] \
  && ok || bad "live completion claim was closed by forced exhaustion"
[[ "$(jq -r '.ulw_enforcement_active // "1"' "${STATE_ROOT}/continuation_claim_busy/session_state.json")" == "1" ]] \
  && ok || bad "live completion claim lost enforcement authority"

# A malformed addressed-session state file cannot turn a Stop into an implicit
# pass when its per-session authority marker still exists. The dispatcher must
# recover what it can and return one explicit fail-closed continuation.
malformed_sid="malformed_authority"
mkdir -p "${STATE_ROOT}/${malformed_sid}"
printf '{malformed\n' >"${STATE_ROOT}/${malformed_sid}/session_state.json"
touch "${STATE_ROOT}/${malformed_sid}/.ulw_active" "${STATE_ROOT}/.ulw_active"
malformed_candidate="MALFORMED-A-CURRENT-CANDIDATE"
malformed_out="$(run_dispatch "${malformed_sid}" "${malformed_candidate}")"
assert_single_json "malformed marked session emits one fail-closed response" "${malformed_out}"
if jq -e '
    (.decision == "block" and ((.reason // "") | contains("not certified")))
    or
    (.hookSpecificOutput.hookEventName == "Stop"
      and ((.hookSpecificOutput.additionalContext // "") | contains("not certified")))
  ' <<<"${malformed_out}" >/dev/null; then
  ok
else
  bad "malformed marked session silently failed open"
fi
assert_contains "malformed-session candidate is retained for retry" "${malformed_candidate}" \
  "$(cat "${STATE_ROOT}/${malformed_sid}/provisional_closeouts.jsonl" 2>/dev/null || true)"

# Recovery can turn corrupt JSON into a valid metadata-only object before the
# next Stop. The exact authority marker must keep that second Stop fail-closed;
# a syntactically valid recovered object is not proof that ULW became ordinary.
recovered_sid="recovered_authority"
mkdir -p "${STATE_ROOT}/${recovered_sid}"
jq -nc --arg cwd "${TEST_HOME}" '{
  recovered_from_corrupt_ts:"123", recovered_archive:"session_state.corrupt.123.json",
  cwd:$cwd
}' >"${STATE_ROOT}/${recovered_sid}/session_state.json"
touch "${STATE_ROOT}/${recovered_sid}/.ulw_active" "${STATE_ROOT}/.ulw_active"
recovered_candidate="RECOVERED-STATE-CURRENT-CANDIDATE"
recovered_out="$(run_dispatch "${recovered_sid}" "${recovered_candidate}")"
assert_single_json "valid recovered state emits one fail-closed response" "${recovered_out}"
assert_contains "valid recovered state cannot silently bypass certification" \
  "not certified" "${recovered_out}"
assert_contains "valid recovered-state candidate is retained" "${recovered_candidate}" \
  "$(cat "${STATE_ROOT}/${recovered_sid}/provisional_closeouts.jsonl" 2>/dev/null || true)"
assert_empty "recovered-state fail-closed path does not stamp an outcome" \
  "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/${recovered_sid}/session_state.json")"

# The exact session marker is the corruption-recovery authority when the JSON
# file is missing altogether. A process-wide marker alone is never enough, but
# an addressed marker must fail closed and recreate only that session state.
missing_state_sid="missing_state_authority"
mkdir -p "${STATE_ROOT}/${missing_state_sid}"
touch "${STATE_ROOT}/${missing_state_sid}/.ulw_active" "${STATE_ROOT}/.ulw_active"
missing_state_out="$(run_dispatch "${missing_state_sid}" 'MISSING-STATE-CANDIDATE')"
assert_single_json "missing state with exact marker emits one fail-closed response" "${missing_state_out}"
assert_contains "missing state with exact marker is not silently released" \
  "not certified" "${missing_state_out}"
[[ -f "${STATE_ROOT}/${missing_state_sid}/session_state.json" ]] \
  && ok || bad "missing addressed state was not recreated for recovery"

# If the continuation counter cannot acquire its session mutex, ending without
# accounting would risk the platform's hard continuation ceiling. Force a live
# lock holder and require one explicit receipt with the current candidate.
# Since the mutex was unavailable, state must remain active rather than being
# overwritten by an unlocked emergency terminal write.
seed_ready continuation_lock_failure
touch "${STATE_ROOT}/continuation_lock_failure/.ulw_active"
mkdir -p "${STATE_ROOT}/continuation_lock_failure/.state.lock"
printf '%s\n' "$$" >"${STATE_ROOT}/continuation_lock_failure/.state.lock/holder.pid"
lock_failure_candidate="$(closeout_message 'LOCK-FAIL-CURRENT-CANDIDATE remains visible.')"
lock_failure_out="$(hook_env \
  OMC_STATE_LOCK_MAX_ATTEMPTS=1 \
  OMC_STATE_LOCK_LONG_WAIT_ATTEMPTS=999 \
  OMC_STATE_LOCK_STALE_SECS=999 \
  bash "${HOOK_DIR}/stop-dispatch.sh" \
  <<<"$(stop_payload continuation_lock_failure "${lock_failure_candidate}")")"
assert_single_json "continuation lock failure emits one explicit receipt" "${lock_failure_out}"
assert_contains "continuation lock failure is named explicitly" "continuation accounting failed" "${lock_failure_out}"
assert_contains "continuation lock failure preserves current candidate" "LOCK-FAIL-CURRENT-CANDIDATE" "${lock_failure_out}"
[[ "$(jq -r '.session_outcome // empty' "${STATE_ROOT}/continuation_lock_failure/session_state.json")" == "" ]] \
  && ok || bad "continuation lock failure wrote a terminal outcome without the mutex"
[[ "$(jq -r '.ulw_enforcement_active // "1"' "${STATE_ROOT}/continuation_lock_failure/session_state.json")" == "1" ]] \
  && ok || bad "continuation lock failure closed enforcement without the mutex"

# An exhausted scorecard can itself be much larger than the 10KB Stop receipt
# budget. Candidate-first merge order must preserve both ends of the current
# uncertified answer before the oversized guard fragment is truncated.
oversized_sid="oversized_scorecard"
oversized_state_dir="${STATE_ROOT}/${oversized_sid}"
mkdir -p "${oversized_state_dir}"
touch "${oversized_state_dir}/.ulw_active" "${STATE_ROOT}/.ulw_active"
oversized_now="$(date +%s)"
oversized_verify_cmd="$(awk 'BEGIN { for (i=0; i<16000; i++) printf "Q" }')"
jq -nc \
  --arg ts "${oversized_now}" \
  --arg cwd "${TEST_HOME}" \
  --arg verify_cmd "${oversized_verify_cmd}" '
    {
      workflow_mode:"ultrawork", ulw_enforcement_active:"1",
      task_domain:"coding", task_intent:"execution",
      current_objective:"Exercise oversized scorecard release", cwd:$cwd,
      last_user_prompt_ts:$ts, prompt_revision:"1",
      last_edit_ts:$ts, last_code_edit_ts:$ts,
      edit_revision:"1", last_code_edit_revision:"1", code_edit_count:"1",
      last_verify_ts:$ts, last_verify_outcome:"passed",
      last_verify_cmd:$verify_cmd, last_verify_confidence:"100",
      last_verify_method:"project_test_command", last_verify_code_revision:"1",
      stop_guard_blocks:"3", closeout_preflight_required:"0",
      closeout_material_activity:"1"
    }
  ' >"${oversized_state_dir}/session_state.json"
printf '/src/foo.ts\n' >"${oversized_state_dir}/edited_files.log"
oversized_candidate=$'**Changed.** OVERSIZED-CANDIDATE-HEAD updated /src/foo.ts.\n\n**Verification.** The available check completed.\n\n**Objective coverage.** The current candidate remains auditable.\n\n**Next.** OVERSIZED-CANDIDATE-TAIL.'
oversized_out="$(hook_env OMC_GUARD_EXHAUSTION_MODE=scorecard \
  bash "${HOOK_DIR}/stop-dispatch.sh" <<<"$(stop_payload "${oversized_sid}" "${oversized_candidate}")")"
assert_single_json "oversized scorecard emits one bounded receipt" "${oversized_out}"
assert_contains "oversized scorecard release remains identified" "QUALITY SCORECARD" "${oversized_out}"
assert_contains "oversized scorecard preserves candidate head" "OVERSIZED-CANDIDATE-HEAD" "${oversized_out}"
assert_contains "oversized scorecard preserves candidate tail" "OVERSIZED-CANDIDATE-TAIL" "${oversized_out}"
[[ "$(jq -r '.session_outcome // empty' "${oversized_state_dir}/session_state.json")" == "exhausted" ]] \
  && ok || bad "oversized scorecard fixture did not exercise exhausted release"
[[ -n "$(jq -r '.project_profile // empty' "${oversized_state_dir}/session_state.json")" ]] \
  && ok || bad "oversized scorecard fixture did not exercise lazy project-profile caching"

# One managed Stop handler must own stdout; settings cannot reintroduce the
# parallel guard/time/canary/archive race.
stop_count="$(jq -r '.hooks.Stop | length' "${REPO_ROOT}/config/settings.patch.json")"
[[ "${stop_count}" == "1" ]] && ok || bad "settings has ${stop_count} managed Stop entries"
stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "${REPO_ROOT}/config/settings.patch.json")"
assert_contains "settings wires dispatcher" "stop-dispatch.sh" "${stop_cmd}"

printf '\nResult: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
