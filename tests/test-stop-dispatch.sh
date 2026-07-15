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
  local sid="$1" op="$2"
  hook_env SESSION_ID="${sid}" bash -c '
    . "$1"
    case "$2" in
      claim) if closeout_claim_finalization; then printf claimed; else printf denied; fi ;;
      abandon) if closeout_abandon_finalization; then printf abandoned; else printf denied; fi ;;
      complete) if closeout_complete_finalization; then printf completed; else printf denied; fi ;;
    esac
  ' -- "${HOOK_DIR}/common.sh" "${op}"
}

printf '\nStop dispatcher:\n'

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
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" PATH="${TEST_HOME}/path-without-jq" \
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
  HOME="${TEST_HOME}" STATE_ROOT="${STATE_ROOT}" PATH="${TEST_HOME}/path-without-jq" \
    /bin/bash "${HOOK_DIR}/stop-dispatch.sh" <<<"${no_jq_ordinary_payload}"
)"
assert_empty "missing jq plus only a global marker does not capture ordinary Stop" \
  "${no_jq_ordinary_out}"

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
[[ "$(run_finalization_op lease_complete claim)" == "claimed" ]] && ok || bad "initial finalization lease claim failed"
lease_claimed_ts="$(jq -r '.closeout_finalization_claimed_ts // empty' "${STATE_ROOT}/lease_complete/session_state.json")"
[[ "${lease_claimed_ts}" =~ ^[0-9]+$ ]] && ok || bad "initial finalization claim did not stamp a timestamp"
[[ "$(run_finalization_op lease_complete claim)" == "denied" ]] && ok || bad "second live finalization claimant was not denied"
[[ "$(run_finalization_op lease_complete abandon)" == "abandoned" ]] && ok || bad "claimed finalization lease could not be abandoned"
assert_empty "abandon clears finalization status" \
  "$(jq -r '.closeout_finalization_status // empty' "${STATE_ROOT}/lease_complete/session_state.json")"
[[ "$(run_finalization_op lease_complete claim)" == "claimed" ]] && ok || bad "abandoned finalization lease was not reclaimable"
[[ "$(run_finalization_op lease_complete complete)" == "completed" ]] && ok || bad "claimed finalization lease could not complete"
[[ "$(jq -r '.closeout_finalization_status // empty' "${STATE_ROOT}/lease_complete/session_state.json")" == "complete" ]] \
  && ok || bad "completed finalization lease did not persist terminal status"
[[ "$(run_finalization_op lease_complete claim)" == "denied" ]] && ok || bad "completed finalization token was claimable again"

seed_ready lease_stale
jq '.session_outcome="completed"' "${STATE_ROOT}/lease_stale/session_state.json" \
  >"${STATE_ROOT}/lease_stale/session_state.json.tmp"
mv "${STATE_ROOT}/lease_stale/session_state.json.tmp" "${STATE_ROOT}/lease_stale/session_state.json"
[[ "$(run_finalization_op lease_stale claim)" == "claimed" ]] && ok || bad "stale-lease fixture could not claim initially"
stale_floor="$(( $(date +%s) - 121 ))"
jq --arg ts "${stale_floor}" '.closeout_finalization_claimed_ts=$ts' \
  "${STATE_ROOT}/lease_stale/session_state.json" >"${STATE_ROOT}/lease_stale/session_state.json.tmp"
mv "${STATE_ROOT}/lease_stale/session_state.json.tmp" "${STATE_ROOT}/lease_stale/session_state.json"
[[ "$(run_finalization_op lease_stale claim)" == "claimed" ]] && ok || bad "expired finalization lease was not reclaimable"
reclaimed_ts="$(jq -r '.closeout_finalization_claimed_ts // empty' "${STATE_ROOT}/lease_stale/session_state.json")"
if [[ "${reclaimed_ts}" =~ ^[0-9]+$ ]] && (( reclaimed_ts > stale_floor )); then
  ok
else
  bad "stale finalization reclaim did not refresh the lease timestamp"
fi

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
