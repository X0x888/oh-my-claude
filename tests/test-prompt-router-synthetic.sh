#!/usr/bin/env bash
# shellcheck disable=SC1090
#
# tests/test-prompt-router-synthetic.sh — Bug A defense regression net.
#
# Verifies `is_synthetic_prompt` (common.sh) and the early-return guard
# in prompt-intent-router.sh: when Claude Code fires UserPromptSubmit
# with a synthetic injection (`<task-notification>`, `<system-reminder>`,
# bash-stdout/stderr wrappers), the router must NOT overwrite the
# active task contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
ROUTER_SH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${STATE_ROOT}"
# .ulw_active sentinel so hooks that fast-path-out on its absence still run
touch "${STATE_ROOT}/.ulw_active"
# The router sources `${HOME}/.claude/skills/autowork/scripts/common.sh`,
# so wire HOME to point at the repo's bundle layout via a symlink tree.
mkdir -p "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${TEST_HOME}/.claude/skills/autowork"
mkdir -p "${TEST_HOME}/.claude/quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${TEST_HOME}/.claude/quality-pack/scripts"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1" cmd="$2"
  if eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — command false: %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_false() {
  local label="$1" cmd="$2"
  if ! eval "${cmd}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — command true (expected false): %s\n' "${label}" "${cmd}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains_text() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — missing %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains_text() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — unexpected %q\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# --- is_synthetic_prompt unit cases -------------------------------------

printf '\n--- is_synthetic_prompt unit cases ---\n'

call_synthetic() {
  ( . "${COMMON_SH}"
    if is_synthetic_prompt "$1"; then echo "yes"; else echo "no"; fi )
}

assert_eq "task-notification anchor"        "yes" "$(call_synthetic '<task-notification>
<task-id>abc</task-id>
<status>completed</status>')"
assert_eq "system-reminder anchor"          "yes" "$(call_synthetic '<system-reminder>
You should ...
</system-reminder>')"
assert_eq "bash-stdout anchor"              "yes" "$(call_synthetic '<bash-stdout>
hello
</bash-stdout>')"
assert_eq "bash-stderr anchor"              "yes" "$(call_synthetic '<bash-stderr>
err
</bash-stderr>')"
assert_eq "command-message anchor"          "yes" "$(call_synthetic '<command-message>commit</command-message>')"
assert_eq "command-name anchor"             "yes" "$(call_synthetic '<command-name>/ulw</command-name>')"
assert_eq "leading whitespace tolerated"    "yes" "$(call_synthetic '   <task-notification>
data
</task-notification>')"

# Negative cases — real user prompts must not be classified as synthetic.
assert_eq "real /ulw prompt"                "no"  "$(call_synthetic '/ulw fix the auth bug')"
assert_eq "plain English prompt"            "no"  "$(call_synthetic 'commit the changes first')"
assert_eq "prompt with inline angle brackets" "no" "$(call_synthetic 'rename function <foo> to <bar>')"
assert_eq "code-fence prompt"               "no"  "$(call_synthetic 'I want this code:
\`\`\`bash
echo hi
\`\`\`')"
assert_eq "empty prompt"                    "no"  "$(call_synthetic '')"
assert_eq "single-char prompt"              "no"  "$(call_synthetic 'x')"
# A user pasting the literal text "<task-notification>" mid-sentence
# does NOT trigger — only an anchored opener does.
assert_eq "<task-notification> mid-sentence is NOT synthetic" "no" \
  "$(call_synthetic 'I saw a <task-notification> tag earlier')"

# --- Router early-return integration -------------------------------------

printf '\n--- Router early-return on synthetic injection ---\n'

run_router() {
  local prompt="$1" sid="$2"
  local input
  input="$(jq -nc --arg sid "${sid}" --arg p "${prompt}" \
    '{session_id: $sid, prompt: $p, transcript_path: "/tmp/none.jsonl"}')"
  printf '%s' "${input}" | bash "${ROUTER_SH}" 2>&1 || true
}

run_agent_dispatch() {
  local dispatch_sid="$1" agent_type="$2" description="$3" payload
  payload="$(jq -nc --arg sid "${dispatch_sid}" --arg agent "${agent_type}" \
    --arg description "${description}" '
      {session_id:$sid,tool_name:"Agent",
       tool_input:{subagent_type:$agent,description:$description,prompt:"review"}}
    ')"
  printf '%s' "${payload}" \
    | bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh" \
      2>/dev/null || true
}

# Agent PreTool transaction creation is durable intent before its first
# causal-ledger mutation; `.ready` says only that snapshot copying completed.
# If that hook dies, every later prompt (including a synthetic task notification)
# must remain inert until the one exact reset grammar runs.
dispatch_router_sid="dispatch-router-recovery"
dispatch_router_dir="${STATE_ROOT}/${dispatch_router_sid}"
mkdir -p "${dispatch_router_dir}/.dispatch-txn.interrupted"
touch "${dispatch_router_dir}/.dispatch-txn.interrupted/.ready"
jq -nc '{
  workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"1",task_intent:"execution",
  current_objective:"preserve interrupted admission objective",
  prompt_revision:"7",review_cycle_id:"3",review_cycle_prompt_ts:"100"
}' >"${dispatch_router_dir}/session_state.json"
dispatch_router_before="$(<"${dispatch_router_dir}/session_state.json")"
dispatch_router_out="$(run_router \
  '/ulw replace the interrupted objective' "${dispatch_router_sid}")"
assert_contains_text "retained dispatch journal blocks objective routing" \
  "DISPATCH RECOVERY REQUIRED" "${dispatch_router_out}"
assert_eq "retained dispatch journal preserves state bytes" \
  "${dispatch_router_before}" \
  "$(<"${dispatch_router_dir}/session_state.json")"
dispatch_router_near_off="$(run_router \
  '/ulw-off now' "${dispatch_router_sid}")"
assert_contains_text "argument-bearing ulw-off is not a reset" \
  "DISPATCH RECOVERY REQUIRED" "${dispatch_router_near_off}"
assert_eq "near reset preserves retained dispatch journal" "1" \
  "$([[ -e "${dispatch_router_dir}/.dispatch-txn.interrupted/.ready" ]] \
    && printf 1 || printf 0)"
# JSON escape decoding happens in jq, after the hook payload reaches Bash.
# Neither an invalid ID nor a NUL-suffixed near-match may normalize into reset
# authority for the valid interrupted session.
dispatch_router_nul_payload="$(jq -nc --arg sid "${dispatch_router_sid}" '
  {session_id:($sid + "\u0000"),prompt:("/ulw-off" + "\u0000"),
   transcript_path:"/tmp/none.jsonl"}')"
dispatch_router_nul_out="$(printf '%s' "${dispatch_router_nul_payload}" \
  | bash "${ROUTER_SH}" 2>&1 || true)"
assert_eq "NUL-bearing reset payload emits no reset authority" "" \
  "${dispatch_router_nul_out}"
assert_eq "NUL-bearing reset preserves interrupted dispatch journal" "1" \
  "$([[ -e "${dispatch_router_dir}/.dispatch-txn.interrupted/.ready" ]] \
    && printf 1 || printf 0)"
assert_eq "NUL-bearing reset preserves enforcement interval" "1" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dispatch_router_dir}/session_state.json")"
dispatch_router_off="$(run_router '  /ulw-off  ' "${dispatch_router_sid}")"
assert_contains_text "exact ulw-off resets interrupted dispatch" \
  "Ultrawork mode was deactivated" "${dispatch_router_off}"
assert_eq "exact reset removes interrupted dispatch journal" "0" \
  "$([[ -e "${dispatch_router_dir}/.dispatch-txn.interrupted" ]] \
    && printf 1 || printf 0)"
assert_eq "exact reset closes enforcement interval" "0" \
  "$(jq -r '.ulw_enforcement_active // empty' \
    "${dispatch_router_dir}/session_state.json")"

# Pre-populate a session with a known contract — synthetic injection
# must NOT overwrite these fields.
sid="bug-a-test"
sdir="${STATE_ROOT}/${sid}"
mkdir -p "${sdir}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  task_domain: "coding",
  current_objective: "fix the auth bug",
  done_contract_primary: "fix the auth bug",
  done_contract_commit_mode: "required",
  last_user_prompt_ts: "1000",
  review_cycle_id: "1",
  review_cycle_prompt_ts: "1000",
  last_code_edit_revision: "3",
  plan_revision: "5",
  has_plan: "true",
  plan_verdict: "PLAN_READY",
  plan_agent: "quality-planner"
}' > "${sdir}/session_state.json"

unbound_notification_out="$(run_router '<task-notification>
<task-id>abc</task-id>
<tool-use-id>toolu_unbound</tool-use-id>
<status>completed</status>
<summary>Agent X completed</summary>
</task-notification>' "${sid}")"
assert_eq "unbound task notification is inert" "" \
  "${unbound_notification_out}"

# Contract must be preserved.
assert_eq "task-notification: current_objective unchanged" "fix the auth bug" \
  "$(jq -r '.current_objective // ""' "${sdir}/session_state.json")"
assert_eq "task-notification: task_intent unchanged" "execution" \
  "$(jq -r '.task_intent // ""' "${sdir}/session_state.json")"
assert_eq "task-notification: commit_mode unchanged" "required" \
  "$(jq -r '.done_contract_commit_mode // ""' "${sdir}/session_state.json")"

# Binding/pending ledgers are shell-facing durable authority. Reject decoded
# NUL before jq -r/read can normalize a poisoned field into an exact bundled
# role, and reject duplicate exact native bindings instead of choosing last.
for authority_case in binding-nul pending-nul duplicate-binding; do
  authority_sid="task-notification-authority-${authority_case}"
  authority_dir="${STATE_ROOT}/${authority_sid}"
  mkdir -p "${authority_dir}"
  jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
    ulw_enforcement_generation:"migration",task_intent:"execution",
    current_objective:"preserve authority bytes",review_cycle_id:"1",
    review_cycle_prompt_ts:"1000",last_code_edit_revision:"3"}' \
    >"${authority_dir}/session_state.json"
  jq -nc --arg case "${authority_case}" \
    '{native_agent_id:"a-byte-authority",
      agent_type:(if $case == "binding-nul"
        then ("quality-reviewer" + "\u0000") else "quality-reviewer" end),
      review_dispatch_id:"",ts:1001}' \
    >"${authority_dir}/native_agent_bindings.jsonl"
  if [[ "${authority_case}" == "duplicate-binding" ]]; then
    jq -nc '{native_agent_id:"a-byte-authority",
      agent_type:"quality-reviewer",review_dispatch_id:"",ts:1002}' \
      >>"${authority_dir}/native_agent_bindings.jsonl"
  fi
  jq -nc --arg case "${authority_case}" \
    '{agent_type:(if $case == "pending-nul"
        then ("quality-reviewer" + "\u0000") else "quality-reviewer" end),
      native_agent_id:"a-byte-authority",ts:1001,
      review_dispatch_abandoned:false,objective_cycle_id:1,
      objective_prompt_ts:1000,review_revision:3,
      ulw_enforcement_generation:"migration"}' \
    >"${authority_dir}/pending_agents.jsonl"
  authority_binding_before="$(<"${authority_dir}/native_agent_bindings.jsonl")"
  authority_pending_before="$(<"${authority_dir}/pending_agents.jsonl")"
  authority_out="$(run_router '<task-notification>
<task-id>a-byte-authority</task-id>
<tool-use-id>toolu_byte_authority</tool-use-id>
<status>completed</status>
<summary>Untrusted completion.</summary>
</task-notification>' "${authority_sid}")"
  assert_contains_text "${authority_case}: recovery fails closed" \
    "BACKGROUND RECOVERY DEGRADED" "${authority_out}"
  assert_eq "${authority_case}: binding ledger is byte-identical" \
    "${authority_binding_before}" \
    "$(<"${authority_dir}/native_agent_bindings.jsonl")"
  assert_eq "${authority_case}: pending ledger is byte-identical" \
    "${authority_pending_before}" \
    "$(<"${authority_dir}/pending_agents.jsonl")"
  assert_eq "${authority_case}: no completion receipt is published" "0" \
    "$([[ -e "${authority_dir}/agent_completion_outcomes.jsonl" ]] \
      && printf 1 || printf 0)"
done

# Background Agent completion arrives as a synthetic UserPromptSubmit, not a
# second PostToolUse:Agent. If a max-turn return left an exact current pending
# reviewer without a causal outcome, this event must wake the parent with that
# retained native ID while still preserving the user's active contract.
jq -nc '{native_agent_id:"a-recover",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1001}' >"${sdir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-recover",ts:1001,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3}' \
  >"${sdir}/pending_agents.jsonl"
recovery_notification_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_background_review</tool-use-id>
<output-file>/tmp/tasks/a-recover.output</output-file>
<status>completed</status>
<summary>Agent "Wave 3 quality-reviewer" finished</summary>
<note>A task-notification fires each time this agent stops.</note>
<result>Tests pass. Let me typecheck…</result>
<usage><subagent_tokens>123</subagent_tokens><tool_uses>8</tool_uses><duration_ms>5000</duration_ms></usage>
</task-notification>' "${sid}")"
recovery_notification_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${recovery_notification_out}" 2>/dev/null || true)"
assert_contains_text "background partial notification wakes parent" \
  "BACKGROUND REVIEW RECOVERY" "${recovery_notification_context}"
assert_contains_text "background partial recovery names retained native ID" \
  "a-recover" "${recovery_notification_context}"
assert_contains_text "background partial recovery forbids passive waiting" \
  "Do not wait" "${recovery_notification_context}"
assert_eq "background recovery leaves active objective unchanged" \
  "fix the auth bug" \
  "$(jq -r '.current_objective // ""' "${sdir}/session_state.json")"
replayed_recovery_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_background_review</tool-use-id>
<status>completed</status>
<summary>Agent "Wave 3 quality-reviewer" finished</summary>
<result>Tests pass. Let me typecheck…</result>
</task-notification>' "${sid}")"
replayed_recovery_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${replayed_recovery_out}" 2>/dev/null || true)"
assert_contains_text "exact notification replay is recognized" \
  "DUPLICATE BACKGROUND NOTIFICATION" "${replayed_recovery_context}"
assert_not_contains_text "exact replay does not resume twice" \
  "Resume that exact call" "${replayed_recovery_context}"
second_recovery_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_background_review_2</tool-use-id>
<status>completed</status>
<summary>The resumed reviewer hit another hard limit.</summary>
</task-notification>' "${sid}")"
second_recovery_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${second_recovery_out}" 2>/dev/null || true)"
assert_contains_text "second background hard limit still resumes exact call" \
  "Resume that exact call now" "${second_recovery_context}"
third_recovery_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_background_review_3</tool-use-id>
<status>completed</status>
<summary>The reviewer hit the bounded hard limit again.</summary>
</task-notification>' "${sid}")"
third_recovery_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${third_recovery_out}" 2>/dev/null || true)"
assert_contains_text "third background hard limit retires native call" \
  "bounded parent-recovery budget is exhausted" "${third_recovery_context}"
assert_contains_text "background exhaustion supplies exact rebind token" \
  "[review-rebind:task-end-" "${third_recovery_context}"
assert_not_contains_text "background exhaustion never resumes old call" \
  "Resume that exact call now" "${third_recovery_context}"

# Runtime cancellation is terminal, not another invitation to resume. Retire
# the exact pending row with the canonical abandonment fields and steer the
# parent toward the current gate instead of SendMessage on a dead task.
jq -nc '{native_agent_id:"a-stopped",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1001}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-stopped",ts:1001,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3}' \
  >>"${sdir}/pending_agents.jsonl"
jq -nc '{ts:1001,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-stopped",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
stopped_notification_out="$(run_router '<task-notification>
<task-id>a-stopped</task-id>
<tool-use-id>toolu_stopped_review</tool-use-id>
<status>stopped</status>
<summary>Task was stopped by the runtime.</summary>
</task-notification>' "${sid}")"
stopped_notification_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${stopped_notification_out}" 2>/dev/null || true)"
assert_contains_text "stopped background task is explicitly rejected" \
  "BACKGROUND RESULT REJECTED" "${stopped_notification_context}"
assert_contains_text "stopped task preserves terminal reason" \
  "task-stopped" "${stopped_notification_context}"
assert_not_contains_text "stopped task is never resumed" \
  "Resume that exact call" "${stopped_notification_context}"
assert_not_contains_text "stopped task never suggests SendMessage" \
  "SendMessage" "${stopped_notification_context}"
assert_eq "stopped pending row is tombstoned" "true" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "a-stopped")][0]
    .review_dispatch_abandoned' "${sdir}/pending_agents.jsonl")"
assert_eq "stopped tombstone records canonical reason" \
  "task-stopped-notification" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "a-stopped")][0]
    .review_dispatch_abandonment_reason' "${sdir}/pending_agents.jsonl")"
assert_true "stopped tombstone records abandonment timestamp" \
  "jq -se '[.[] | select(.native_agent_id == \"a-stopped\")][0]
    .review_dispatch_abandoned_ts | type == \"number\"' \
    \"${sdir}/pending_agents.jsonl\" >/dev/null"
assert_eq "stopped notification consumes one same-native FIFO outcome" "0" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-stopped" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"

# A valid background completion outcome is consumed by the exact notification
# task/native ID. One native task may notify again after SendMessage, so FIFO
# consumes one outcome per notification rather than deleting later resumptions.
# The accepted first return is silent; the later exhausted return recovers.
rm -f "${sdir}/pending_agents.jsonl"
jq -nc '{ts:1002,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-recover",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >"${sdir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:1003,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-recover",
  objective_cycle_id:1,objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:1004,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-other",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
accepted_notification_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_accepted_review</tool-use-id>
<status>completed</status>
<summary>Review complete.</summary>
</task-notification>' "${sid}")"
assert_eq "accepted background notification needs no recovery directive" "" \
  "${accepted_notification_out}"
assert_eq "first same-native notification leaves later and other outcomes" "2" \
  "$(jq -s '[.[] | select((.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"
assert_eq "background receipt preserves nested accepted outcome" "CLEAN" \
  "$(jq -s -r '[.[] | select(
      (.notification_receipt // false) == true
      and (.notification_kind // "") == "task-notification"
      and (.notification_key // "")
        == "a-recover|toolu_accepted_review|completed")][0]
    | .completion_outcome.verdict // empty' \
    "${sdir}/agent_completion_outcomes.jsonl")"
assert_eq "background receipt projects outcome for orphan settlement" \
  "accepted" "$(jq -s -r '[.[] | select(
      (.notification_receipt // false) == true
      and (.notification_key // "")
        == "a-recover|toolu_accepted_review|completed")][0]
    | .status // empty' "${sdir}/agent_completion_outcomes.jsonl")"
assert_eq "later same-native outcome remains ordered for next notification" \
  "terminal-contract-retry-exhausted" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "a-recover" and
      (.notification_receipt // false) != true)][0].reason' \
    "${sdir}/agent_completion_outcomes.jsonl")"
accepted_replay_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_accepted_review</tool-use-id>
<status>completed</status>
<summary>Review complete.</summary>
</task-notification>' "${sid}")"
accepted_replay_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${accepted_replay_out}" 2>/dev/null || true)"
assert_contains_text "accepted notification replay uses its receipt" \
  "DUPLICATE BACKGROUND NOTIFICATION" "${accepted_replay_context}"
assert_eq "accepted replay does not consume the next same-native outcome" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-recover" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"
accepted_receipt_row="$(jq -sc '[.[] | select(
    (.notification_receipt // false) == true
    and (.notification_key // "")
      == "a-recover|toolu_accepted_review|completed")][0]' \
  "${sdir}/agent_completion_outcomes.jsonl")"
printf '%s\n' "${accepted_receipt_row}" \
  >>"${sdir}/agent_completion_outcomes.jsonl"
accepted_ambiguous_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_accepted_review</tool-use-id>
<status>completed</status>
<summary>Review complete.</summary>
</task-notification>' "${sid}")"
accepted_ambiguous_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${accepted_ambiguous_out}" 2>/dev/null || true)"
assert_contains_text "duplicate exact notification receipts fail closed" \
  "BACKGROUND RECOVERY DEGRADED" "${accepted_ambiguous_context}"
assert_eq "ambiguous receipt cannot consume next same-native outcome" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-recover" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"

# Task wakes use the same global key contract as foreground Agent PostTool.
# One malformed or foreign-coordinate claim reserves the key fail-closed; it
# cannot suppress the legitimate outcome as a duplicate or permit a second
# receipt to be minted.
for task_claim_case in coordinate flag kind schema status outcome nested \
    projection extra; do
  task_claim_sid="task-notification-key-${task_claim_case}"
  task_claim_dir="${STATE_ROOT}/${task_claim_sid}"
  task_claim_native="a-task-key-${task_claim_case}"
  task_claim_tool="toolu_task_key_${task_claim_case}"
  task_claim_key="${task_claim_native}|${task_claim_tool}|completed"
  mkdir -p "${task_claim_dir}"
  jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
    review_cycle_prompt_ts:"1000",last_user_prompt_ts:"1000",
    last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
    >"${task_claim_dir}/session_state.json"
  jq -nc --arg native "${task_claim_native}" \
    '{native_agent_id:$native,agent_type:"quality-reviewer",
      review_dispatch_id:"",ts:1000}' \
    >"${task_claim_dir}/native_agent_bindings.jsonl"
  jq -nc --arg native "${task_claim_native}" '
    {ts:1000,agent_type:"quality-reviewer",status:"accepted",reason:"",
     verdict:"CLEAN",findings_count:0,finding_ids:"none",
     native_agent_id:$native,objective_cycle_id:1,
     objective_prompt_ts:1000,review_revision:3,
     ulw_enforcement_generation:"migration"}' \
    >"${task_claim_dir}/agent_completion_outcomes.jsonl"
  jq -nc --arg key "${task_claim_key}" \
      --arg native "${task_claim_native}" \
      --arg case "${task_claim_case}" '
    {ts:999,agent_type:"quality-reviewer",status:"accepted",reason:"",
     verdict:"CLEAN",findings_count:0,finding_ids:"none",
     native_agent_id:$native,objective_cycle_id:1,
     objective_prompt_ts:1000,review_revision:3,
     ulw_enforcement_generation:"migration"} as $outcome
    | $outcome +
    {ts:(if $case == "schema" then "bad" else 1000 end),
     notification_receipt:(if $case == "flag" then "true" else true end),
     notification_kind:(if $case == "kind" then "foreign" else
       "task-notification" end),notification_key:$key,
     notification_agent_type:"quality-reviewer",
     native_agent_id:(if $case == "coordinate" then "foreign-native"
       else $native end),notification_status:"completed",
     notification_rejected_reason:"",notification_rebind_id:"",
     notification_retry_exhausted:false,
     notification_current_pending_preserved:false,
     completion_outcome:$outcome}
    | if $case == "status" then del(.notification_status)
      elif $case == "outcome" then del(.completion_outcome)
      elif $case == "nested" then
        .completion_outcome = {status:"accepted"}
      elif $case == "projection" then .verdict = "BLOCK (1)"
      elif $case == "extra" then .forged_recovery_authority = true
      else . end
  ' >>"${task_claim_dir}/agent_completion_outcomes.jsonl"
  task_claim_out="$(run_router "<task-notification>
<task-id>${task_claim_native}</task-id>
<tool-use-id>${task_claim_tool}</tool-use-id>
<status>completed</status>
<summary>Malformed same-key receipt authority.</summary>
</task-notification>" "${task_claim_sid}")"
  task_claim_context="$(jq -r \
    '.hookSpecificOutput.additionalContext // ""' \
    <<<"${task_claim_out}" 2>/dev/null || true)"
  assert_contains_text \
    "task key ${task_claim_case}: malformed claim fails closed" \
    "BACKGROUND RECOVERY DEGRADED" "${task_claim_context}"
  assert_eq "task key ${task_claim_case}: causal outcome is preserved" "1" \
    "$(jq -s --arg native "${task_claim_native}" '[.[] | select(
      (.native_agent_id // "") == $native
      and (has("notification_key") | not))] | length' \
      "${task_claim_dir}/agent_completion_outcomes.jsonl")"
  assert_eq "task key ${task_claim_case}: no second key claim is minted" "1" \
    "$(jq -s --arg key "${task_claim_key}" '[.[] | select(
      (.notification_key // "") == $key)] | length' \
      "${task_claim_dir}/agent_completion_outcomes.jsonl")"
done

# Third-party code reviewers own a real record-reviewer publisher but do not
# adopt OMC's forced terminal-vocabulary contract. Background recovery must
# recognize either authority; otherwise their task notification leaves the
# exact accepted outcome stranded for a later unrelated foreground callback.
jq -nc '{native_agent_id:"a-code-recover",
  agent_type:"superpowers:code-reviewer",review_dispatch_id:"",ts:1002}' \
  >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1002,agent_type:"superpowers:code-reviewer",
  status:"accepted",reason:"",verdict:"CLEAN",findings_count:0,
  finding_ids:"none",native_agent_id:"a-code-recover",
  objective_cycle_id:1,objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
code_notification_out="$(run_router '<task-notification>
<task-id>a-code-recover</task-id>
<tool-use-id>toolu_code_recover</tool-use-id>
<status>completed</status>
<summary>Third-party code review complete.</summary>
</task-notification>' "${sid}")"
assert_eq "code-reviewer notification accepts dedicated publisher" "" \
  "${code_notification_out}"
assert_eq "code-reviewer notification consumes exact causal outcome" "0" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-code-recover" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"
assert_eq "code-reviewer notification preserves accepted receipt" "accepted" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "a-code-recover" and
      (.notification_receipt // false) == true)][0].status // empty' \
    "${sdir}/agent_completion_outcomes.jsonl")"

# After the bounded retry cap, the exact background notification consumes the
# ignored outcome and tells the parent to make a fresh dispatch, not to resume
# the retired call. Simulate a producer killed immediately after its journal
# rename: both exact causal rows still exist and must be rolled forward before
# the notification receipt or replacement guidance is published.
background_crash_row="$(jq -nc '{ts:1003,agent_type:"quality-reviewer",
  description:"background crashed cleanup",edit_revision:3,
  lifecycle_dispatch_id:"dispatch-background-recover",
  code_revision:3,doc_revision:0,bash_revision:0,ui_revision:0,
  plan_revision:0,review_revision:3,objective_prompt_ts:1000,
  objective_prompt_revision:4,objective_cycle_id:1,
  ulw_enforcement_generation:"migration",native_agent_id:"a-recover"}')"
printf '%s\n' "${background_crash_row}" >"${sdir}/pending_agents.jsonl"
printf '%s\n' "${background_crash_row}" \
  >"${sdir}/agent_dispatch_starts.jsonl"
background_crash_fp="$(
  . "${COMMON_SH}"
  _omc_token_digest "${background_crash_row}"
)"
jq -c --arg fp "${background_crash_fp}" '
  if (.native_agent_id // "") == "a-recover"
      and (.reason // "") == "terminal-contract-retry-exhausted"
      and (.notification_receipt // false) != true
  then . + {cleanup_journal_version:2,
             lifecycle_dispatch_id:"dispatch-background-recover",
             cleanup_lifecycle_dispatch_id:
               "dispatch-background-recover",
             cleanup_pending_fingerprint:$fp,
             cleanup_start_fingerprint:$fp}
  else . end
' "${sdir}/agent_completion_outcomes.jsonl" \
  >"${sdir}/agent_completion_outcomes.jsonl.tmp"
mv "${sdir}/agent_completion_outcomes.jsonl.tmp" \
  "${sdir}/agent_completion_outcomes.jsonl"
exhausted_notification_out="$(run_router '<task-notification>
<task-id>a-recover</task-id>
<tool-use-id>toolu_exhausted_review</tool-use-id>
<status>completed</status>
<summary>Still checking…</summary>
</task-notification>' "${sid}")"
exhausted_notification_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${exhausted_notification_out}" 2>/dev/null || true)"
assert_contains_text "exhausted background call triggers fresh dispatch" \
  "Dispatch a fresh equivalent now" "${exhausted_notification_context}"
assert_contains_text "exhausted background call is not resumed" \
  "Do not wait for or resume that call" "${exhausted_notification_context}"
assert_eq "exhausted same-native outcome is retired exactly once" "0" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-recover" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"
assert_eq "background crash journal retires exact pending row" "0" \
  "$(jq -s 'length' "${sdir}/pending_agents.jsonl")"
assert_eq "background crash journal retires exact start row" "0" \
  "$(jq -s 'length' "${sdir}/agent_dispatch_starts.jsonl")"
assert_eq "different native same-role outcome remains untouched" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-other" and
      (.notification_receipt // false) != true)] | length' \
    "${sdir}/agent_completion_outcomes.jsonl")"

# Modern task notifications carry tool-use-id. The compatibility fallback
# hashes the complete body: an exact replay dedupes, while a genuinely distinct
# wake for the same resumed native task consumes the next FIFO outcome.
jq -nc '{native_agent_id:"a-no-tool-id",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1004}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1004,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-no-tool-id",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:1004,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-no-tool-id",
  objective_cycle_id:1,objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
no_id_body='<task-notification>
<task-id>a-no-tool-id</task-id>
<status>completed</status>
<summary>First completion without a tool ID.</summary>
</task-notification>'
no_id_first_out="$(run_router "${no_id_body}" "${sid}")"
assert_eq "no-tool-id first accepted wake is silent" "" "${no_id_first_out}"
no_id_replay_out="$(run_router "${no_id_body}" "${sid}")"
no_id_replay_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${no_id_replay_out}" 2>/dev/null || true)"
assert_contains_text "no-tool-id exact-body replay dedupes" \
  "DUPLICATE BACKGROUND NOTIFICATION" "${no_id_replay_context}"
no_id_second_out="$(run_router '<task-notification>
<task-id>a-no-tool-id</task-id>
<status>completed</status>
<summary>Second completion after native resume.</summary>
</task-notification>' "${sid}")"
no_id_second_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${no_id_second_out}" 2>/dev/null || true)"
assert_contains_text "distinct no-tool-id body consumes next FIFO outcome" \
  "Dispatch a fresh equivalent now" "${no_id_second_context}"

# A failed runtime wake is terminal even if a completion hook already produced
# an outcome and removed the pending row. Reject it without emitting an empty
# rebind token; no tombstone means a plain fresh dispatch is already admissible.
jq -nc '{native_agent_id:"a-failed-outcome",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1004}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1004,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-failed-outcome",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
failed_outcome_out="$(run_router '<task-notification>
<task-id>a-failed-outcome</task-id>
<tool-use-id>toolu_failed_outcome</tool-use-id>
<status>failed</status>
<summary>Runtime marked this task failed.</summary>
</task-notification>' "${sid}")"
failed_outcome_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${failed_outcome_out}" 2>/dev/null || true)"
assert_contains_text "failed wake with selected outcome is rejected" \
  "native call a-failed-outcome failed" "${failed_outcome_context}"
assert_not_contains_text "failed wake never emits an empty rebind token" \
  "[review-rebind:]" "${failed_outcome_context}"
assert_not_contains_text "failed wake never tells parent to resume" \
  "Resume that exact call" "${failed_outcome_context}"

# A max-turn notification with an exact bound row from an older code
# generation must reject the raw result; it may not resume or accept evidence.
jq -nc '{native_agent_id:"a-stale",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1005}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-stale",ts:1005,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:2}' \
  >"${sdir}/pending_agents.jsonl"
stale_notification_out="$(run_router '<task-notification>
<task-id>a-stale</task-id>
<tool-use-id>toolu_stale_review</tool-use-id>
<status>completed</status>
<summary>Agent "stale quality-reviewer" finished</summary>
<result>VERDICT: CLEAN</result>
</task-notification>' "${sid}")"
stale_notification_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${stale_notification_out}" 2>/dev/null || true)"
assert_contains_text "stale background result is explicitly rejected" \
  "BACKGROUND RESULT REJECTED" "${stale_notification_context}"
assert_contains_text "stale rejection names generation change" \
  "review-generation-changed" "${stale_notification_context}"
assert_not_contains_text "stale background result is never resumed" \
  "Resume that exact call" "${stale_notification_context}"

# Ignored outcomes other than retry exhaustion also need an explicit rejection
# directive so the parent cannot treat raw notification prose as accepted.
jq -nc '{native_agent_id:"a-ignored",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1006}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1006,agent_type:"quality-reviewer",status:"ignored",
  reason:"prior-objective-completion",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-ignored",
  objective_cycle_id:0,objective_prompt_ts:1,review_revision:2,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
ignored_notification_out="$(run_router '<task-notification>
<task-id>a-ignored</task-id>
<tool-use-id>toolu_ignored_review</tool-use-id>
<status>completed</status>
<summary>Agent "old quality-reviewer" finished</summary>
<result>VERDICT: CLEAN</result>
</task-notification>' "${sid}")"
ignored_notification_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${ignored_notification_out}" 2>/dev/null || true)"
assert_contains_text "ignored background outcome is explicitly rejected" \
  "BACKGROUND RESULT REJECTED" "${ignored_notification_context}"
assert_contains_text "ignored rejection preserves causal reason" \
  "prior-objective-completion" "${ignored_notification_context}"

jq -nc '{native_agent_id:"a-accepted-stale",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:1007}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1007,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-accepted-stale",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:2,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
accepted_stale_out="$(run_router '<task-notification>
<task-id>a-accepted-stale</task-id>
<tool-use-id>toolu_accepted_stale</tool-use-id>
<status>completed</status>
<summary>Agent "stale accepted quality-reviewer" finished</summary>
<result>VERDICT: CLEAN</result>
</task-notification>' "${sid}")"
accepted_stale_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${accepted_stale_out}" 2>/dev/null || true)"
assert_contains_text "accepted-but-stale outcome is explicitly rejected" \
  "BACKGROUND RESULT REJECTED" "${accepted_stale_context}"
assert_contains_text "accepted-but-stale rejection names currentness" \
  "no longer matches the current objective" "${accepted_stale_context}"

# Event receipts are platform identities, not enforcement-interval identities.
# A queued replay after /ulw-off -> /ulw must not consume a current-generation
# outcome, while a new wake for the resumed native task may consume it.
generation_sid="task-notification-generation"
generation_dir="${STATE_ROOT}/${generation_sid}"
mkdir -p "${generation_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"1",review_cycle_id:"1",
  review_cycle_prompt_ts:"3000",last_user_prompt_ts:"3000",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${generation_dir}/session_state.json"
jq -nc '{native_agent_id:"a-generation",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:3000}' \
  >"${generation_dir}/native_agent_bindings.jsonl"
jq -nc '{ts:3000,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-generation",objective_cycle_id:1,
  objective_prompt_ts:3000,review_revision:3,
  ulw_enforcement_generation:"1"}' \
  >"${generation_dir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:3001,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-generation",
  objective_cycle_id:1,objective_prompt_ts:3000,review_revision:3,
  ulw_enforcement_generation:"2"}' \
  >>"${generation_dir}/agent_completion_outcomes.jsonl"
generation_event='<task-notification>
<task-id>a-generation</task-id>
<tool-use-id>toolu_generation_event</tool-use-id>
<status>completed</status>
<summary>Generation-one completion.</summary>
</task-notification>'
assert_eq "generation-one accepted wake is silent" "" \
  "$(run_router "${generation_event}" "${generation_sid}")"
jq '.ulw_enforcement_generation = "2"' \
  "${generation_dir}/session_state.json" \
  >"${generation_dir}/session_state.json.tmp"
mv "${generation_dir}/session_state.json.tmp" \
  "${generation_dir}/session_state.json"
generation_replay_out="$(run_router "${generation_event}" \
  "${generation_sid}")"
generation_replay_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${generation_replay_out}" 2>/dev/null || true)"
assert_contains_text "cross-generation replay remains a duplicate" \
  "DUPLICATE BACKGROUND NOTIFICATION" "${generation_replay_context}"
assert_eq "cross-generation replay leaves current outcome unconsumed" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "a-generation" and
      (.notification_receipt // false) != true)] | length' \
    "${generation_dir}/agent_completion_outcomes.jsonl")"
generation_second_out="$(run_router '<task-notification>
<task-id>a-generation</task-id>
<tool-use-id>toolu_generation_event_2</tool-use-id>
<status>completed</status>
<summary>Generation-two completion.</summary>
</task-notification>' "${generation_sid}")"
generation_second_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${generation_second_out}" 2>/dev/null || true)"
assert_contains_text "new generation wake consumes current FIFO outcome" \
  "Dispatch a fresh equivalent now" "${generation_second_context}"

# More adversarial ordering: the generation-one event is delivered for the
# first time only after generation two is active and has already produced a
# later same-native outcome. FIFO must consume/reject the old row, never steal
# the newer outcome merely because it matches the captured generation.
delayed_sid="task-notification-delayed-first-delivery"
delayed_dir="${STATE_ROOT}/${delayed_sid}"
mkdir -p "${delayed_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"2",review_cycle_id:"1",
  review_cycle_prompt_ts:"3100",last_user_prompt_ts:"3100",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${delayed_dir}/session_state.json"
jq -nc '{native_agent_id:"a-delayed",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:3100}' \
  >"${delayed_dir}/native_agent_bindings.jsonl"
jq -nc '{ts:3099,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-delayed",objective_cycle_id:1,
  objective_prompt_ts:3100,review_revision:3,
  ulw_enforcement_generation:"1"}' \
  >"${delayed_dir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:3100,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-delayed",
  objective_cycle_id:1,objective_prompt_ts:3100,review_revision:3,
  ulw_enforcement_generation:"2"}' \
  >>"${delayed_dir}/agent_completion_outcomes.jsonl"
delayed_first_out="$(run_router '<task-notification>
<task-id>a-delayed</task-id>
<tool-use-id>toolu_delayed_gen1</tool-use-id>
<status>completed</status>
<summary>Delayed generation-one notification.</summary>
</task-notification>' "${delayed_sid}")"
delayed_first_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${delayed_first_out}" 2>/dev/null || true)"
assert_contains_text "delayed old first delivery is rejected" \
  "closed oh-my-claude enforcement interval" "${delayed_first_context}"
assert_eq "delayed old wake leaves only generation-two outcome" "2" \
  "$(jq -s -r '[.[] | select((.notification_receipt // false) != true)][0]
    .ulw_enforcement_generation' \
    "${delayed_dir}/agent_completion_outcomes.jsonl")"
delayed_second_out="$(run_router '<task-notification>
<task-id>a-delayed</task-id>
<tool-use-id>toolu_delayed_gen2</tool-use-id>
<status>completed</status>
<summary>Generation-two notification.</summary>
</task-notification>' "${delayed_sid}")"
delayed_second_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${delayed_second_out}" 2>/dev/null || true)"
assert_contains_text "next distinct wake consumes generation-two outcome" \
  "Dispatch a fresh equivalent now" "${delayed_second_context}"

# If that delayed old wake arrives while a validated current same-native row is
# live, preserve it and forbid a duplicate dispatch based on the stale event.
preserved_sid="task-notification-preserved-current"
preserved_dir="${STATE_ROOT}/${preserved_sid}"
mkdir -p "${preserved_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"2",review_cycle_id:"1",
  review_cycle_prompt_ts:"3200",last_user_prompt_ts:"3200",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${preserved_dir}/session_state.json"
jq -nc '{native_agent_id:"a-preserved",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:3200}' \
  >"${preserved_dir}/native_agent_bindings.jsonl"
jq -nc '{ts:3199,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-preserved",objective_cycle_id:1,
  objective_prompt_ts:3200,review_revision:3,
  ulw_enforcement_generation:"1"}' \
  >"${preserved_dir}/agent_completion_outcomes.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-preserved",
  ts:3200,review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:3200,review_revision:3,
  ulw_enforcement_generation:"2"}' \
  >"${preserved_dir}/pending_agents.jsonl"
preserved_out="$(run_router '<task-notification>
<task-id>a-preserved</task-id>
<tool-use-id>toolu_preserved_old</tool-use-id>
<status>completed</status>
<summary>Delayed old wake while resumed task is current.</summary>
</task-notification>' "${preserved_sid}")"
preserved_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${preserved_out}" 2>/dev/null || true)"
assert_contains_text "delayed wake preserves current native task" \
  "current-interval row for that same native task remains pending" \
  "${preserved_context}"
assert_contains_text "delayed wake forbids duplicate dispatch" \
  "Do not integrate the old result, rebind, or dispatch a duplicate" \
  "${preserved_context}"
assert_eq "current same-native pending row remains live" "false" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${preserved_dir}/pending_agents.jsonl")"

# The preservation branch is deliberately after every validity check. An
# abandoned, revision-stale, or actively settling current-generation row may
# share the native ID, but none may be advertised as a validated live task.
for invalid_kind in abandoned stale claimed expired overflow effects; do
  invalid_sid="task-notification-invalid-current-${invalid_kind}"
  invalid_dir="${STATE_ROOT}/${invalid_sid}"
  mkdir -p "${invalid_dir}"
  jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
    ulw_enforcement_generation:"2",review_cycle_id:"1",
    review_cycle_prompt_ts:"3250",last_user_prompt_ts:"3250",
    prompt_revision:"1",
    last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
    >"${invalid_dir}/session_state.json"
  jq -nc --arg id "a-invalid-${invalid_kind}" \
    '{native_agent_id:$id,agent_type:"quality-reviewer",
      review_dispatch_id:"",ts:3250}' \
    >"${invalid_dir}/native_agent_bindings.jsonl"
  jq -nc --arg id "a-invalid-${invalid_kind}" \
    '{ts:3249,agent_type:"quality-reviewer",status:"accepted",
      reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
      native_agent_id:$id,objective_cycle_id:1,
      objective_prompt_ts:3250,review_revision:3,
      ulw_enforcement_generation:"1"}' \
    >"${invalid_dir}/agent_completion_outcomes.jsonl"
  invalid_claim_message="Completed current reviewer callback.\nVERDICT: CLEAN"
  invalid_claim_digest="$(printf '%s' "${invalid_claim_message}" \
    | shasum -a 256 | awk '{print substr($1,1,24)}')"
  jq -nc --arg id "a-invalid-${invalid_kind}" --arg kind "${invalid_kind}" \
    --arg lifecycle "dispatch-invalid-${invalid_kind}-current" \
    --arg claim_message "${invalid_claim_message}" \
    --arg claim_digest "${invalid_claim_digest}" \
    --argjson claim_now "$(date +%s)" '
    {agent_type:"quality-reviewer",native_agent_id:$id,ts:3250,
     lifecycle_dispatch_id:$lifecycle,
     review_dispatch_abandoned:($kind == "abandoned"),
     objective_cycle_id:1,objective_prompt_ts:3250,
     objective_prompt_revision:1,
     review_revision:(if $kind == "stale" then 2 else 3 end),
     ulw_enforcement_generation:"2"}
     + if ($kind == "claimed" or $kind == "expired" or $kind == "overflow"
         or $kind == "effects") then {
        completion_claim_id:("completion-invalid-" + $kind),
        completion_claim_ts:(if $kind == "expired" then 1
          elif $kind == "overflow" then "999999999999999999999999999999"
          else $claim_now end),
        completion_claim_effects_complete:($kind == "effects"),
        completion_claim_message:$claim_message,
        completion_claim_digest:$claim_digest
      } else {} end
  ' >"${invalid_dir}/pending_agents.jsonl"
  invalid_out="$(run_router "<task-notification>
<task-id>a-invalid-${invalid_kind}</task-id>
<tool-use-id>toolu_invalid_${invalid_kind}</tool-use-id>
<status>completed</status>
<summary>Delayed old wake beside invalid current row.</summary>
</task-notification>" "${invalid_sid}")"
  invalid_context="$(jq -r \
    '.hookSpecificOutput.additionalContext // ""' \
    <<<"${invalid_out}" 2>/dev/null || true)"
  assert_not_contains_text "${invalid_kind} row is never called validated current" \
    "separately validated current-interval row" "${invalid_context}"
  if [[ "${invalid_kind}" == "claimed" ]]; then
    assert_contains_text "settling claim forbids a duplicate dispatch" \
      "Do not integrate the old result, resume, rebind, or dispatch a duplicate" \
      "${invalid_context}"
  elif [[ "${invalid_kind}" == "expired" \
      || "${invalid_kind}" == "overflow" ]]; then
    assert_contains_text "${invalid_kind} claim is not described as settling" \
      "expired incomplete completion claim" "${invalid_context}"
  elif [[ "${invalid_kind}" == "effects" ]]; then
    assert_contains_text "effects-complete claim is not described as settling" \
      "completion effects were already recorded" "${invalid_context}"
  else
    assert_contains_text "${invalid_kind} current row produces rejection" \
      "BACKGROUND RESULT REJECTED" "${invalid_context}"
  fi
  case "${invalid_kind}" in
    abandoned|stale|expired|overflow)
      invalid_rebind_id="$(printf '%s' "${invalid_context}" \
        | sed -n 's/.*\[review-rebind:\([^]]*\)\].*/\1/p')"
      assert_true "${invalid_kind} rejection exposes a rebind ID" \
        "[[ -n \"${invalid_rebind_id}\" ]]"
      assert_eq "${invalid_kind} exact rebound dispatch is admitted" "" \
        "$(run_agent_dispatch "${invalid_sid}" "quality-reviewer" \
          "[review-rebind:${invalid_rebind_id}] replace invalid current row")"
      ;;
  esac
done

# The same exact task-wake capability covers planners. It is not a broad
# native-ID exemption: a digest mismatch keeps the universal recovery fence.
planner_claim_message="Current planner callback is publishing.
VERDICT: PLAN_READY"
planner_claim_digest="$(printf '%s' "${planner_claim_message}" \
  | shasum -a 256 | awk '{print substr($1,1,24)}')"
for planner_claim_case in exact malformed; do
  planner_claim_sid="task-notification-planner-claim-${planner_claim_case}"
  planner_claim_dir="${STATE_ROOT}/${planner_claim_sid}"
  planner_claim_native="a-planner-claim-${planner_claim_case}"
  mkdir -p "${planner_claim_dir}"
  jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
    ulw_enforcement_generation:"2",review_cycle_id:"1",
    review_cycle_prompt_ts:"4150",last_user_prompt_ts:"4150",
    prompt_revision:"1",edit_revision:"3",plan_revision:"0"}' \
    >"${planner_claim_dir}/session_state.json"
  jq -nc --arg id "${planner_claim_native}" \
    '{native_agent_id:$id,agent_type:"quality-planner",
      review_dispatch_id:"",ts:4150}' \
    >"${planner_claim_dir}/native_agent_bindings.jsonl"
  jq -nc --arg id "${planner_claim_native}" '
    {ts:4149,agent_type:"quality-planner",status:"accepted",reason:"",
     verdict:"PLAN_READY",findings_count:0,finding_ids:"none",
     native_agent_id:$id,objective_cycle_id:1,
     objective_prompt_ts:4150,review_revision:0,
     ulw_enforcement_generation:"1"}
  ' >"${planner_claim_dir}/agent_completion_outcomes.jsonl"
  jq -nc --arg id "${planner_claim_native}" \
    --arg message "${planner_claim_message}" \
    --arg digest "${planner_claim_digest}" \
    --arg case_name "${planner_claim_case}" \
    --argjson claim_now "$(date +%s)" '
      {agent_type:"quality-planner",native_agent_id:$id,ts:4150,
       lifecycle_dispatch_id:("dispatch-planner-claim-" + $case_name),
       review_dispatch_abandoned:false,objective_cycle_id:1,
       objective_prompt_ts:4150,objective_prompt_revision:1,
       review_revision:0,plan_revision:0,ulw_enforcement_generation:"2",
       completion_claim_id:("completion-planner-claim-" + $case_name),
       completion_claim_ts:$claim_now,completion_claim_effects_complete:false,
       completion_claim_message:$message,
       completion_claim_digest:(if $case_name == "exact" then $digest
         else "000000000000000000000000" end)}
    ' >"${planner_claim_dir}/pending_agents.jsonl"
  planner_claim_out="$(run_router "<task-notification>
<task-id>${planner_claim_native}</task-id>
<tool-use-id>toolu_planner_claim_${planner_claim_case}</tool-use-id>
<status>completed</status>
<summary>Planner wake beside a publishing claim.</summary>
</task-notification>" "${planner_claim_sid}")"
  if [[ "${planner_claim_case}" == "exact" ]]; then
    assert_contains_text "exact planner wake reports settling without mutation" \
      "validated current completion claim is still settling" \
      "${planner_claim_out}"
    assert_eq "exact planner wake preserves the live claim" "false" \
      "$(jq -r '.completion_claim_effects_complete' \
        "${planner_claim_dir}/pending_agents.jsonl")"
    planner_claim_nested_tag_out="$(run_router "<task-notification>
<task-id>${planner_claim_native}</task-id>
<tool-use-id>toolu_planner_claim_exact_nested_tag</tool-use-id>
<status>completed</status>
<summary>Untrusted summary text contains a later <task-id>decoy-native</task-id> tag.</summary>
</task-notification>" "${planner_claim_sid}")"
    assert_contains_text \
      "task-wake capability uses the same leftmost ID as notification parsing" \
      "validated current completion claim is still settling" \
      "${planner_claim_nested_tag_out}"
  else
    assert_contains_text "malformed planner claim remains recovery-fenced" \
      "OH-MY-CLAUDE RECOVERY REQUIRED" "${planner_claim_out}"
  fi
done

# Row-only crashes precede both dedicated WAL/receipt publishers. Once the
# exact universal claim lease expires, the publication barrier must retire the
# planner/reviewer pending+start pair through the ignored-outcome journal before
# admitting a newer real prompt. No dedicated verdict/plan effect is inferred.
for orphan_kind in reviewer planner; do
  orphan_sid="orphaned-dedicated-${orphan_kind}"
  orphan_dir="${STATE_ROOT}/${orphan_sid}"
  orphan_native="a-orphaned-${orphan_kind}"
  orphan_lifecycle="dispatch-orphaned-${orphan_kind}-claim"
  if [[ "${orphan_kind}" == "reviewer" ]]; then
    orphan_agent="quality-reviewer"
    orphan_message="Recovered reviewer callback was never authoritative.
VERDICT: CLEAN"
    orphan_review_revision=3
    orphan_effects=false
  else
    orphan_agent="quality-planner"
    orphan_message="Recovered planner callback was never authoritative.
VERDICT: PLAN_READY"
    orphan_review_revision=0
    orphan_effects=true
  fi
  orphan_digest="$(printf '%s' "${orphan_message}" \
    | shasum -a 256 | awk '{print substr($1,1,24)}')"
  mkdir -p "${orphan_dir}"
  jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
    ulw_enforcement_generation:"2",native_agent_id_tracking_version:"1",
    review_dispatch_tracking_version:"1",subagent_dispatch_tracking_version:"1",
    review_cycle_id:"1",review_cycle_prompt_ts:"4250",
    last_user_prompt_ts:"4250",prompt_revision:"1",
    last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
    >"${orphan_dir}/session_state.json"
  jq -nc --arg native "${orphan_native}" --arg agent "${orphan_agent}" \
    --arg lifecycle "${orphan_lifecycle}" \
    '{native_agent_id:$native,agent_type:$agent,
      review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
      objective_cycle_id:1,ts:4250}' \
    >"${orphan_dir}/native_agent_bindings.jsonl"
  jq -nc --arg native "${orphan_native}" --arg agent "${orphan_agent}" \
    --arg lifecycle "${orphan_lifecycle}" \
    --arg message "${orphan_message}" --arg digest "${orphan_digest}" \
    --argjson revision "${orphan_review_revision}" \
    --argjson effects "${orphan_effects}" '
      {ts:4250,agent_type:$agent,native_agent_id:$native,
       lifecycle_dispatch_id:$lifecycle,review_dispatch_id:"",
       review_dispatch_causality_version:1,review_dispatch_abandoned:false,
       objective_cycle_id:1,objective_prompt_ts:4250,
       objective_prompt_revision:1,review_revision:$revision,
       edit_revision:3,code_revision:3,doc_revision:0,bash_revision:0,
       ui_revision:0,plan_revision:0,ulw_enforcement_generation:"2",
       completion_claim_id:("completion-orphaned-" + $agent),
       completion_claim_ts:1,completion_claim_effects_complete:$effects,
       completion_claim_message:$message,completion_claim_digest:$digest}
    ' >"${orphan_dir}/pending_agents.jsonl"
  cp "${orphan_dir}/pending_agents.jsonl" \
    "${orphan_dir}/agent_dispatch_starts.jsonl"
  orphan_out="$(run_router "/ulw continue after ${orphan_kind} crash" \
    "${orphan_sid}")"
  assert_not_contains_text "${orphan_kind} orphan converges before real prompt" \
    "RECOVERY REQUIRED" "${orphan_out}"
  assert_eq "${orphan_kind} orphan pending row is retired" "0" \
    "$(jq -s 'length' "${orphan_dir}/pending_agents.jsonl")"
  assert_eq "${orphan_kind} orphan start row is retired" "0" \
    "$(jq -s 'length' "${orphan_dir}/agent_dispatch_starts.jsonl")"
  assert_eq "${orphan_kind} orphan has one ignored roll-forward outcome" \
    "ignored:orphaned-dedicated-publication" \
    "$(jq -s -r '[.[] | select(
        .lifecycle_dispatch_id == "'"${orphan_lifecycle}"'")]
      | if length == 1 then .[0].status + ":" + .[0].reason else "" end' \
      "${orphan_dir}/agent_completion_outcomes.jsonl")"
  assert_contains_text "${orphan_kind} prompt advances only after retirement" \
    "continue after ${orphan_kind} crash" \
    "$(jq -r '.current_objective // ""' \
      "${orphan_dir}/session_state.json")"
done

# A hard-cap return can have no outcome because SubagentStop never fired. An
# exact old-interval pending row must still reject the raw notification rather
# than disappearing as unrelated input or being resumed in the new interval.
jq -nc '{native_agent_id:"a-foreign-pending",
  agent_type:"quality-reviewer",review_dispatch_id:"",ts:3002}' \
  >>"${generation_dir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-foreign-pending",
  ts:3002,review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:3000,review_revision:3,
  ulw_enforcement_generation:"1"}' \
  >"${generation_dir}/pending_agents.jsonl"
foreign_pending_out="$(run_router '<task-notification>
<task-id>a-foreign-pending</task-id>
<tool-use-id>toolu_foreign_pending</tool-use-id>
<status>completed</status>
<summary>Late old-interval max-turn return.</summary>
</task-notification>' "${generation_sid}")"
foreign_pending_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${foreign_pending_out}" 2>/dev/null || true)"
assert_contains_text "foreign-generation pending return is rejected" \
  "BACKGROUND RESULT REJECTED" "${foreign_pending_context}"
assert_contains_text "foreign pending rejection names interval change" \
  "enforcement-interval-changed" "${foreign_pending_context}"
assert_not_contains_text "foreign pending return is never resumed" \
  "Resume that exact call" "${foreign_pending_context}"
assert_eq "foreign pending row becomes an audit tombstone" "true" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${generation_dir}/pending_agents.jsonl")"
assert_eq "foreign tombstone records interval-ended reason" \
  "enforcement-interval-task-ended" \
  "$(jq -r '.review_dispatch_abandonment_reason // ""' \
    "${generation_dir}/pending_agents.jsonl")"
foreign_rebind_id="$(printf '%s' "${foreign_pending_context}" \
  | sed -n 's/.*\[review-rebind:\([^]]*\)\].*/\1/p')"
assert_true "foreign pending rejection exposes a parseable rebind ID" \
  "[[ -n \"${foreign_rebind_id}\" ]]"
assert_eq "foreign pending exact rebound dispatch is admitted" "" \
  "$(run_agent_dispatch "${generation_sid}" "quality-reviewer" \
    "[review-rebind:${foreign_rebind_id}] replace ended old interval")"
assert_eq "rebound dispatch targets current enforcement generation" "2" \
  "$(jq -s -r '[.[] | select(
      (.review_dispatch_abandoned // false) != true)][0]
      .ulw_enforcement_generation' \
    "${generation_dir}/pending_agents.jsonl")"

# Once enforcement is inactive, a late notification is wholly inert and must
# not consume the outcome that belongs to the closed interval.
inactive_sid="task-notification-inactive"
inactive_dir="${STATE_ROOT}/${inactive_sid}"
mkdir -p "${inactive_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"0",
  ulw_enforcement_generation:"7",session_outcome:"released",
  review_cycle_id:"1",review_cycle_prompt_ts:"4000",
  last_user_prompt_ts:"4000",last_code_edit_revision:"3"}' \
  >"${inactive_dir}/session_state.json"
jq -nc '{native_agent_id:"a-inactive",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:4000}' \
  >"${inactive_dir}/native_agent_bindings.jsonl"
jq -nc '{ts:4000,agent_type:"quality-reviewer",status:"ignored",
  reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
  findings_count:0,finding_ids:"none",native_agent_id:"a-inactive",
  objective_cycle_id:1,objective_prompt_ts:4000,review_revision:3,
  ulw_enforcement_generation:"7"}' \
  >"${inactive_dir}/agent_completion_outcomes.jsonl"
inactive_out="$(run_router '<task-notification>
<task-id>a-inactive</task-id>
<tool-use-id>toolu_inactive</tool-use-id>
<status>completed</status>
<summary>Late completion after release.</summary>
</task-notification>' "${inactive_sid}")"
assert_eq "inactive-interval notification is inert" "" "${inactive_out}"
assert_eq "inactive notification does not consume closed-interval outcome" \
  "1" "$(jq -s 'length' \
    "${inactive_dir}/agent_completion_outcomes.jsonl")"

# Pending retry/retirement and the one-shot outcome receipt publish as one
# recoverable transaction. A receipt-stage failure restores the exact pending
# bytes and still gives the parent conservative no-wait guidance.
receipt_fail_sid="task-notification-receipt-failure"
receipt_fail_dir="${STATE_ROOT}/${receipt_fail_sid}"
mkdir -p "${receipt_fail_dir}"
jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
  review_cycle_prompt_ts:"4100",last_user_prompt_ts:"4100",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${receipt_fail_dir}/session_state.json"
jq -nc '{native_agent_id:"a-receipt-fail",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:4100}' \
  >"${receipt_fail_dir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-receipt-fail",
  ts:4100,review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:4100,review_revision:3}' \
  >"${receipt_fail_dir}/pending_agents.jsonl"
export OMC_TEST_TASK_NOTIFICATION_FAIL_RECEIPT=1
receipt_fail_out="$(run_router '<task-notification>
<task-id>a-receipt-fail</task-id>
<tool-use-id>toolu_receipt_fail</tool-use-id>
<status>completed</status>
<summary>Hard-limit completion whose receipt publication fails.</summary>
</task-notification>' "${receipt_fail_sid}")"
unset OMC_TEST_TASK_NOTIFICATION_FAIL_RECEIPT
receipt_fail_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${receipt_fail_out}" 2>/dev/null || true)"
assert_contains_text "receipt failure surfaces conservative recovery" \
  "BACKGROUND RECOVERY DEGRADED" "${receipt_fail_context}"
assert_contains_text "receipt failure forbids passive wait" \
  "Do not integrate the raw result or wait for another copy" \
  "${receipt_fail_context}"
assert_eq "receipt failure rolls back retry counter" "0" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "${receipt_fail_dir}/pending_agents.jsonl")"
assert_eq "receipt failure keeps exact pending row live" "false" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${receipt_fail_dir}/pending_agents.jsonl")"
assert_false "receipt failure commits no receipt ledger" \
  "[[ -e \"${receipt_fail_dir}/agent_completion_outcomes.jsonl\" ]]"

# Process death after the pending retry write but before the receipt rename
# must not spend the bounded native-resume budget twice. The stable wake key
# on the row is the roll-forward marker for exact redelivery.
receipt_kill_sid="task-notification-receipt-kill"
receipt_kill_dir="${STATE_ROOT}/${receipt_kill_sid}"
mkdir -p "${receipt_kill_dir}"
jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
  review_cycle_prompt_ts:"4200",last_user_prompt_ts:"4200",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${receipt_kill_dir}/session_state.json"
jq -nc '{native_agent_id:"a-receipt-kill",agent_type:"quality-reviewer",
  review_dispatch_id:"",ts:4200}' \
  >"${receipt_kill_dir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",native_agent_id:"a-receipt-kill",
  ts:4200,review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:4200,review_revision:3}' \
  >"${receipt_kill_dir}/pending_agents.jsonl"
receipt_kill_prompt='<task-notification>
<task-id>a-receipt-kill</task-id>
<tool-use-id>toolu_receipt_kill</tool-use-id>
<status>completed</status>
<summary>Hard-limit completion interrupted after pending publication.</summary>
</task-notification>'
export OMC_TEST_TASK_NOTIFICATION_KILL_AFTER_PENDING=1
run_router "${receipt_kill_prompt}" "${receipt_kill_sid}" >/dev/null
unset OMC_TEST_TASK_NOTIFICATION_KILL_AFTER_PENDING
assert_eq "receipt kill spends one retry before process death" "1" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "${receipt_kill_dir}/pending_agents.jsonl")"
assert_false "receipt kill precedes durable notification receipt" \
  "[[ -e \"${receipt_kill_dir}/agent_completion_outcomes.jsonl\" ]]"
receipt_kill_replay_out="$(run_router \
  "${receipt_kill_prompt}" "${receipt_kill_sid}")"
receipt_kill_replay_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${receipt_kill_replay_out}" 2>/dev/null || true)"
assert_eq "exact notification replay spends no second retry" "1" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "${receipt_kill_dir}/pending_agents.jsonl")"
assert_eq "exact notification replay commits one receipt" "1" \
  "$(jq -s '[.[] | select(.notification_receipt == true)] | length' \
    "${receipt_kill_dir}/agent_completion_outcomes.jsonl")"
assert_contains_text "exact notification replay retains resume guidance" \
  "Resume that exact call now" "${receipt_kill_replay_context}"

# A malformed completion ledger must fence the notification transaction. The
# receipt rewrite may not silently filter an unrelated malformed row while
# consuming a valid same-native outcome.
malformed_sid="task-notification-malformed-outcomes"
malformed_dir="${STATE_ROOT}/${malformed_sid}"
mkdir -p "${malformed_dir}"
jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
  review_cycle_prompt_ts:"4250",last_user_prompt_ts:"4250",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${malformed_dir}/session_state.json"
jq -nc '{native_agent_id:"a-malformed-outcome",
  agent_type:"quality-reviewer",review_dispatch_id:"",ts:4250}' \
  >"${malformed_dir}/native_agent_bindings.jsonl"
jq -nc '{ts:4250,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-malformed-outcome",objective_cycle_id:1,
  objective_prompt_ts:4250,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >"${malformed_dir}/agent_completion_outcomes.jsonl"
# Valid JSON is still corrupt authority when it is only a causal-looking
# fragment rather than the complete producer contract.
printf '%s\n' \
  '{"status":"accepted","native_agent_id":"a-malformed-outcome"}' \
  >>"${malformed_dir}/agent_completion_outcomes.jsonl"
malformed_before="$(cksum \
  <"${malformed_dir}/agent_completion_outcomes.jsonl")"
malformed_out="$(run_router '<task-notification>
<task-id>a-malformed-outcome</task-id>
<tool-use-id>toolu_malformed_outcome</tool-use-id>
<status>completed</status>
<summary>Completion with an unrelated malformed ledger row.</summary>
</task-notification>' "${malformed_sid}")"
malformed_context="$(jq -r '.hookSpecificOutput.additionalContext // ""' \
  <<<"${malformed_out}" 2>/dev/null || true)"
assert_contains_text "malformed outcome ledger fails notification closed" \
  "BACKGROUND RECOVERY DEGRADED" "${malformed_context}"
assert_eq "malformed outcome ledger remains byte-identical" \
  "${malformed_before}" \
  "$(cksum <"${malformed_dir}/agent_completion_outcomes.jsonl")"

# The newest-128 delivery-receipt cap is history retention, not permission to
# discard a receipt that is still the accepted-outcome authority for an exact
# summary-first waiter. Preserve the live lifecycle and prune older unrelated
# history instead.
protected_sid="task-notification-protected-receipt"
protected_dir="${STATE_ROOT}/${protected_sid}"
mkdir -p "${protected_dir}"
jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
  review_cycle_prompt_ts:"4275",last_user_prompt_ts:"4275",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${protected_dir}/session_state.json"
jq -nc '{native_agent_id:"a-protected-new",
  agent_type:"quality-reviewer",review_dispatch_id:"",ts:4275}' \
  >"${protected_dir}/native_agent_bindings.jsonl"
protected_plan_ready_digest="$(
  . "${COMMON_SH}"
  _omc_token_digest "VERDICT: PLAN_READY"
)"
jq -nc --arg digest "${protected_plan_ready_digest}" \
  '{schema_version:1,created_at:4275,
  lifecycle_dispatch_id:"dispatch-protected-receipt-0001",
  agent_type:"quality-planner",native_agent_id:"a-protected-old",
  completion_digest:$digest,message:"VERDICT: PLAN_READY"}' \
  >"${protected_dir}/plan_summary_waiters.jsonl"
jq -nc '{notification_receipt:true,notification_kind:"agent-posttool",
  notification_key:"protected-old",notification_agent_type:"quality-planner",
  lifecycle_dispatch_id:"dispatch-protected-receipt-0001",
  agent_type:"quality-planner",native_agent_id:"a-protected-old",
  status:"accepted",completion_outcome:{status:"accepted"}}' \
  >"${protected_dir}/agent_completion_outcomes.jsonl"
jq -nc 'range(0;127) as $i | {
  notification_receipt:true,notification_kind:"task-notification",
  notification_key:("history-" + ($i|tostring)),
  notification_agent_type:"quality-reviewer",
  native_agent_id:("history-native-" + ($i|tostring)),
  completion_outcome:null}' \
  >>"${protected_dir}/agent_completion_outcomes.jsonl"
jq -nc '{ts:4275,agent_type:"quality-reviewer",status:"accepted",
  reason:"",verdict:"CLEAN",findings_count:0,finding_ids:"none",
  native_agent_id:"a-protected-new",objective_cycle_id:1,
  objective_prompt_ts:4275,review_revision:3,
  ulw_enforcement_generation:"migration"}' \
  >>"${protected_dir}/agent_completion_outcomes.jsonl"
protected_out="$(run_router '<task-notification>
<task-id>a-protected-new</task-id>
<tool-use-id>toolu_protected_new</tool-use-id>
<status>completed</status>
<summary>New accepted completion at the receipt cap.</summary>
</task-notification>' "${protected_sid}")"
assert_eq "protected receipt notification remains silent" "" \
  "${protected_out}"
assert_eq "delivery receipt cap remains bounded" "128" \
  "$(jq -s 'length' \
    "${protected_dir}/agent_completion_outcomes.jsonl")"
assert_eq "live waiter receipt survives history pruning" "1" \
  "$(jq -s '[.[] | select(.lifecycle_dispatch_id ==
      "dispatch-protected-receipt-0001")] | length' \
    "${protected_dir}/agent_completion_outcomes.jsonl")"
assert_eq "oldest unrelated receipt is pruned first" "0" \
  "$(jq -s '[.[] | select(.notification_key == "history-0")] | length' \
    "${protected_dir}/agent_completion_outcomes.jsonl")"
assert_eq "new delivery receipt is retained" "1" \
  "$(jq -s '[.[] | select(.notification_key ==
      "a-protected-new|toolu_protected_new|completed")] | length' \
    "${protected_dir}/agent_completion_outcomes.jsonl")"

# The pending tombstone and delivery receipt commit before hook output. If the
# process dies after the receipt rename, exact notification replay must recover
# the same persisted replacement token instead of degrading to a token-less
# generic duplicate.
terminal_receipt_sid="task-notification-terminal-receipt-kill"
terminal_receipt_dir="${STATE_ROOT}/${terminal_receipt_sid}"
mkdir -p "${terminal_receipt_dir}"
jq -nc '{workflow_mode:"ultrawork",review_cycle_id:"1",
  review_cycle_prompt_ts:"4290",last_user_prompt_ts:"4290",
  last_code_edit_revision:"3",edit_revision:"3",plan_revision:"0"}' \
  >"${terminal_receipt_dir}/session_state.json"
jq -nc '{native_agent_id:"a-terminal-receipt",
  agent_type:"quality-reviewer",review_dispatch_id:"",ts:4290}' \
  >"${terminal_receipt_dir}/native_agent_bindings.jsonl"
jq -nc '{agent_type:"quality-reviewer",
  native_agent_id:"a-terminal-receipt",ts:4290,
  review_dispatch_abandoned:false,objective_cycle_id:1,
  objective_prompt_ts:4290,review_revision:3,
  terminal_contract_retry_count:2}' \
  >"${terminal_receipt_dir}/pending_agents.jsonl"
terminal_receipt_prompt='<task-notification>
<task-id>a-terminal-receipt</task-id>
<tool-use-id>toolu_terminal_receipt</tool-use-id>
<status>completed</status>
<summary>Third hard-limit completion interrupted after its receipt.</summary>
</task-notification>'
export OMC_TEST_TASK_NOTIFICATION_KILL_AFTER_RECEIPT=1
run_router "${terminal_receipt_prompt}" "${terminal_receipt_sid}" >/dev/null
unset OMC_TEST_TASK_NOTIFICATION_KILL_AFTER_RECEIPT
terminal_rebind_id="$(jq -r '.terminal_contract_rebind_id // empty' \
  "${terminal_receipt_dir}/pending_agents.jsonl")"
assert_true "terminal receipt kill persists a valid rebind token" \
  "[[ \"${terminal_rebind_id}\" =~ ^task-end-[A-Fa-f0-9]{16}$ ]]"
assert_eq "terminal delivery receipt preserves the same rebind token" \
  "${terminal_rebind_id}" \
  "$(jq -s -r '[.[] | select(.notification_key ==
      "a-terminal-receipt|toolu_terminal_receipt|completed")][0]
    .notification_rebind_id // empty' \
    "${terminal_receipt_dir}/agent_completion_outcomes.jsonl")"
terminal_receipt_replay_out="$(run_router \
  "${terminal_receipt_prompt}" "${terminal_receipt_sid}")"
terminal_receipt_replay_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${terminal_receipt_replay_out}" 2>/dev/null || true)"
assert_contains_text "terminal receipt replay retains exhaustion guidance" \
  "bounded parent-recovery budget is exhausted" \
  "${terminal_receipt_replay_context}"
assert_contains_text "terminal receipt replay reuses exact token" \
  "[review-rebind:${terminal_rebind_id}]" \
  "${terminal_receipt_replay_context}"
assert_not_contains_text "terminal receipt replay never resumes old call" \
  "Resume that exact call now" "${terminal_receipt_replay_context}"

# PLAN_READY is the one accepted outcome whose dedicated recorder advances its
# own freshness generation: dispatch N publishes plan revision N+1. The task
# notification is current only when the committed plan state proves that exact
# transition and agent.
jq -nc '{native_agent_id:"a-plan-ready",agent_type:"quality-planner",
  review_dispatch_id:"",ts:1008}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1008,agent_type:"quality-planner",status:"accepted",
  reason:"",verdict:"PLAN_READY",findings_count:0,finding_ids:"none",
  native_agent_id:"a-plan-ready",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:4,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
plan_ready_notification_out="$(run_router '<task-notification>
<task-id>a-plan-ready</task-id>
<tool-use-id>toolu_plan_ready</tool-use-id>
<status>completed</status>
<summary>Agent "quality-planner" finished</summary>
<result>VERDICT: PLAN_READY</result>
</task-notification>' "${sid}")"
assert_eq "committed PLAN_READY N-to-N+1 notification is current" "" \
  "${plan_ready_notification_out}"

jq -nc '{native_agent_id:"a-plan-unpublished",agent_type:"quality-planner",
  review_dispatch_id:"",ts:1009}' >>"${sdir}/native_agent_bindings.jsonl"
jq -nc '{ts:1009,agent_type:"quality-planner",status:"accepted",
  reason:"",verdict:"PLAN_READY",findings_count:0,finding_ids:"none",
  native_agent_id:"a-plan-unpublished",objective_cycle_id:1,
  objective_prompt_ts:1000,review_revision:5,
  ulw_enforcement_generation:"migration"}' \
  >>"${sdir}/agent_completion_outcomes.jsonl"
plan_unpublished_out="$(run_router '<task-notification>
<task-id>a-plan-unpublished</task-id>
<tool-use-id>toolu_plan_unpublished</tool-use-id>
<status>completed</status>
<summary>Agent "quality-planner" finished</summary>
<result>VERDICT: PLAN_READY</result>
</task-notification>' "${sid}")"
plan_unpublished_context="$(jq -r \
  '.hookSpecificOutput.additionalContext // ""' \
  <<<"${plan_unpublished_out}" 2>/dev/null || true)"
assert_contains_text "unpublished PLAN_READY outcome is rejected" \
  "BACKGROUND RESULT REJECTED" "${plan_unpublished_context}"

# A real user prompt re-fired must update — verify the contrast with
# the synthetic case above. Set workflow_mode so the router's ULW
# code path activates fully (consistent with how an in-progress ULW
# session looks at PromptSubmit time).
sid2="real-user-prompt"
sdir2="${STATE_ROOT}/${sid2}"
mkdir -p "${sdir2}"
jq -nc '{workflow_mode:"ultrawork",
  external_edit_event_count:"9",
  external_doc_edit_event_count:"3",
  external_ui_edit_event_count:"2",
  external_native_edit_event_count:"1",
  external_unknown_edit_event_count:"3"}' > "${sdir2}/session_state.json"
printf '%s\n' \
  '{"_v":1,"legacy":true}' \
  '{malformed legacy receipt' \
  >"${sdir2}/verification_receipts.jsonl"
run_router '/ulw fix the payment refund' "${sid2}" >/dev/null
real_intent="$(jq -r '.task_intent // ""' "${sdir2}/session_state.json")"
real_objective="$(jq -r '.current_objective // ""' "${sdir2}/session_state.json")"
assert_true "real prompt: task_intent populated" \
  "[[ -n \"${real_intent}\" ]]"
assert_true "real prompt: current_objective updated" \
  "[[ \"${real_objective}\" == *'payment refund'* ]]"
assert_false "fresh objective clears the entire live verification receipt ledger" \
  "[[ -e \"${sdir2}/verification_receipts.jsonl\" ]]"
assert_eq "fresh objective snapshots aggregate connector baseline" "9" \
  "$(jq -r '.review_cycle_external_event_base // ""' "${sdir2}/session_state.json")"
assert_eq "fresh objective snapshots document connector baseline" "3" \
  "$(jq -r '.review_cycle_external_doc_event_base // ""' "${sdir2}/session_state.json")"
assert_eq "fresh objective snapshots UI connector baseline" "2" \
  "$(jq -r '.review_cycle_external_ui_event_base // ""' "${sdir2}/session_state.json")"
assert_eq "fresh objective snapshots native connector baseline" "1" \
  "$(jq -r '.review_cycle_external_native_event_base // ""' "${sdir2}/session_state.json")"
assert_eq "fresh objective snapshots unknown connector baseline" "3" \
  "$(jq -r '.review_cycle_external_unknown_event_base // ""' "${sdir2}/session_state.json")"

# Constitution curation is a session-management turn. Even mutation-shaped
# grammar must preserve the active objective lifecycle and all causal proof
# artifacts while still returning the exact authorization guidance.
constitution_sid="constitution-lifecycle-inert"
constitution_dir="${STATE_ROOT}/${constitution_sid}"
mkdir -p "${constitution_dir}"
jq -nc '{
  workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"4",task_intent:"execution",
  prompt_classified_intent:"execution",prompt_revision:"7",
  last_meta_request:"prior status request",
  current_objective:"finish the active exporter",task_domain:"coding",
  task_risk_tier:"high",review_cycle_id:"11",
  review_cycle_prompt_ts:"7000",review_cycle_edit_log_offset:"2",
  first_mutation_ts:"7100",first_mutation_tool:"Edit",
  quality_contract_tracking_version:"1",quality_contract_required:"1",
  quality_contract_id:"qc-active-contract",quality_contract_revision:"2",
  quality_contract_status:"current",quality_frontier_status:"open",
  quality_evidence_current_count:"2",dimension_guard_blocks:"3",
  exemplifying_scope_required:""
}' >"${constitution_dir}/session_state.json"
printf '%s\n' '{"contract_id":"qc-active-contract","sentinel":"contract"}' \
  >"${constitution_dir}/quality_contract.json"
printf '%s\n' '{"criterion_id":"criterion-1","sentinel":"evidence"}' \
  >"${constitution_dir}/quality_evidence.jsonl"
printf '%s\n' '{"status":"open","sentinel":"frontier"}' \
  >"${constitution_dir}/quality_frontier.json"
printf '%s\n' '{"contract_id":"qc-active-contract","sentinel":"floor"}' \
  >"${constitution_dir}/quality_contract_floor.json"
printf '%s\n' '{"_v":2,"sentinel":"receipt"}' \
  >"${constitution_dir}/verification_receipts.jsonl"
printf '%s\n' '{"agent_type":"quality-reviewer","sentinel":"pending"}' \
  >"${constitution_dir}/pending_agents.jsonl"
constitution_state_before="$(jq -c '{
  current_objective,last_meta_request,review_cycle_id,review_cycle_prompt_ts,
  review_cycle_edit_log_offset,first_mutation_ts,first_mutation_tool,
  quality_contract_tracking_version,quality_contract_required,
  quality_contract_id,quality_contract_revision,quality_contract_status,
  quality_frontier_status,quality_evidence_current_count,
  dimension_guard_blocks,exemplifying_scope_required
}' "${constitution_dir}/session_state.json")"
constitution_artifacts_before="$(
  cksum \
    "${constitution_dir}/quality_contract.json" \
    "${constitution_dir}/quality_evidence.jsonl" \
    "${constitution_dir}/quality_frontier.json" \
    "${constitution_dir}/quality_contract_floor.json" \
    "${constitution_dir}/verification_receipts.jsonl" \
    "${constitution_dir}/pending_agents.jsonl"
)"
export OMC_PROMPT_PERSIST=off
constitution_output="$(run_router \
  '/quality-constitution remember Prefer causal evidence such as runnable proof over vague assurance' \
  "${constitution_sid}")"
unset OMC_PROMPT_PERSIST
constitution_state_after="$(jq -c '{
  current_objective,last_meta_request,review_cycle_id,review_cycle_prompt_ts,
  review_cycle_edit_log_offset,first_mutation_ts,first_mutation_tool,
  quality_contract_tracking_version,quality_contract_required,
  quality_contract_id,quality_contract_revision,quality_contract_status,
  quality_frontier_status,quality_evidence_current_count,
  dimension_guard_blocks,exemplifying_scope_required
}' "${constitution_dir}/session_state.json")"
constitution_artifacts_after="$(
  cksum \
    "${constitution_dir}/quality_contract.json" \
    "${constitution_dir}/quality_evidence.jsonl" \
    "${constitution_dir}/quality_frontier.json" \
    "${constitution_dir}/quality_contract_floor.json" \
    "${constitution_dir}/verification_receipts.jsonl" \
    "${constitution_dir}/pending_agents.jsonl"
)"
assert_eq "Constitution command preserves active lifecycle state" \
  "${constitution_state_before}" "${constitution_state_after}"
assert_eq "Constitution command preserves live contract/proof/pending artifacts" \
  "${constitution_artifacts_before}" "${constitution_artifacts_after}"
assert_eq "Constitution command is normalized to session management" \
  "session_management" \
  "$(jq -r '.task_intent // ""' "${constitution_dir}/session_state.json")"
assert_false "Constitution command does not persist raw slash payload when prompt persistence is off" \
  "grep -Fq 'Prefer causal evidence such as runnable proof over vague assurance' \
    \"${constitution_dir}/session_state.json\""
assert_contains_text "Constitution command still emits exact authorization guidance" \
  "QUALITY CONSTITUTION — EXACT USER AUTHORIZATION" "${constitution_output}"

# Monotonic objective identity is produced in the same locked transition that
# tombstones prior live dispatches. Freeze the router epoch to prove two genuinely
# fresh prompts in one epoch second still receive distinct cycle IDs, while a
# true continuation preserves both the ID and its current live row.
run_router_same_second() {
  local prompt="$1" cycle_sid="$2" input
  input="$(jq -nc --arg sid "${cycle_sid}" --arg p "${prompt}" \
    '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
  printf '%s' "${input}" \
    | OMC_TEST_ROUTER_NOW_EPOCH=424242 bash "${ROUTER_SH}" 2>&1 || true
}
cycle_sid="review-cycle-producer"
cycle_dir="${STATE_ROOT}/${cycle_sid}"
mkdir -p "${cycle_dir}"
jq -nc '{workflow_mode:"ultrawork",task_intent:"execution",
  current_objective:"old objective",review_cycle_id:"4",
  review_cycle_prompt_ts:"424242",
  closeout_finalized_token:"4:9:completed",
  closeout_finalization_status:"claimed",
  closeout_finalization_claimed_ts:"424242",
  closeout_finalization_claim_id:
    "finalizer-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
  >"${cycle_dir}/session_state.json"
jq -nc '{ts:424242,agent_type:"old-cycle-worker",objective_cycle_id:4,
  review_dispatch_abandoned:false}' >"${cycle_dir}/pending_agents.jsonl"
run_router_same_second '/ulw implement the new export path completely' \
  "${cycle_sid}" >/dev/null
assert_eq "fresh producer increments the monotonic review cycle" "5" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "fresh producer keeps the frozen same-second timestamp diagnostic" \
  "424242" \
  "$(jq -r '.review_cycle_prompt_ts // ""' "${cycle_dir}/session_state.json")"
assert_eq "fresh producer clears the prior closeout claimant identity" "" \
  "$(jq -r '.closeout_finalization_claim_id // ""' \
    "${cycle_dir}/session_state.json")"
assert_eq "cycle publication atomically tombstones the prior live row" "true" \
  "$(jq -s -r '[.[] | select(.agent_type == "old-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"
jq -nc '{ts:424242,agent_type:"current-cycle-worker",objective_cycle_id:5,
  review_dispatch_abandoned:false}' >>"${cycle_dir}/pending_agents.jsonl"
run_router_same_second 'continue' "${cycle_sid}" >/dev/null
assert_eq "true continuation preserves the review cycle" "5" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "true continuation does not retombstone current live work" "false" \
  "$(jq -s -r '[.[] | select(.agent_type == "current-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"
run_router_same_second '/ulw implement a separate audit-log exporter' \
  "${cycle_sid}" >/dev/null
assert_eq "second fresh same-second prompt receives a new cycle" "6" \
  "$(jq -r '.review_cycle_id // ""' "${cycle_dir}/session_state.json")"
assert_eq "second fresh transition tombstones former current work" "true" \
  "$(jq -s -r '[.[] | select(.agent_type == "current-cycle-worker")][0].review_dispatch_abandoned' \
    "${cycle_dir}/pending_agents.jsonl")"

# The cycle ID is the publication point for a fresh objective. A failed
# pending-ledger rewrite must not be masked merely because the following start
# ledger is absent and the function's caller is inside an `if ! ...` context
# (which suppresses Bash errexit inside the call tree). Inject a targeted
# ledger rewrite failure after taint staging and prove the transition fails
# closed without weakening the hook's observer PATH.
failure_sid="review-cycle-rewrite-failure"
failure_dir="${STATE_ROOT}/${failure_sid}"
mkdir -p "${failure_dir}"
jq -nc '{workflow_mode:"ultrawork",task_intent:"execution",
  current_objective:"old objective",review_cycle_id:"9",
  review_cycle_prompt_ts:"424242"}' >"${failure_dir}/session_state.json"
jq -nc '{ts:424242,agent_type:"rewrite-failure-worker",objective_cycle_id:9,
  review_dispatch_abandoned:false}' >"${failure_dir}/pending_agents.jsonl"
failure_input="$(jq -nc --arg sid "${failure_sid}" \
  --arg p '/ulw implement the separate failed-transition exporter' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
printf '%s' "${failure_input}" \
  | OMC_TEST_FAIL_OBJECTIVE_LEDGER_REWRITE=1 \
    bash "${ROUTER_SH}" >/dev/null 2>&1
failure_rc=$?
set -e
assert_true "ledger rewrite failure rejects fresh objective transition" \
  "[[ ${failure_rc} -ne 0 ]]"
assert_eq "ledger rewrite failure does not publish a new review cycle" "9" \
  "$(jq -r '.review_cycle_id // ""' "${failure_dir}/session_state.json")"
assert_eq "ledger rewrite failure leaves prior row live for a safe retry" "false" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "${failure_dir}/pending_agents.jsonl")"

# Numeric state is untrusted input to Bash arithmetic. Causal counters fail
# closed instead of wrapping/restarting their identities; advisory timestamps
# and the explicit epoch seam fall back without suppressing current routing.
numeric_prompt_sid="router-numeric-prompt-revision"
numeric_prompt_dir="${STATE_ROOT}/${numeric_prompt_sid}"
mkdir -p "${numeric_prompt_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"1",prompt_revision:"999999999999999",
  review_cycle_id:"2",current_objective:"preserve numeric objective"}' \
  >"${numeric_prompt_dir}/session_state.json"
numeric_prompt_input="$(jq -nc --arg sid "${numeric_prompt_sid}" \
  --arg p 'continue' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
printf '%s' "${numeric_prompt_input}" \
  | bash "${ROUTER_SH}" >/dev/null 2>&1
numeric_prompt_rc=$?
set -e
assert_true "maximum prompt revision fails closed before wrap" \
  "[[ ${numeric_prompt_rc} -ne 0 ]]"
assert_eq "maximum prompt revision remains unchanged" "999999999999999" \
  "$(jq -r '.prompt_revision // ""' \
    "${numeric_prompt_dir}/session_state.json")"
assert_eq "prompt revision failure preserves objective" \
  "preserve numeric objective" \
  "$(jq -r '.current_objective // ""' \
    "${numeric_prompt_dir}/session_state.json")"

numeric_cycle_sid="router-numeric-review-cycle"
numeric_cycle_dir="${STATE_ROOT}/${numeric_cycle_sid}"
mkdir -p "${numeric_cycle_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"1",prompt_revision:"1",
  review_cycle_id:"999999999999999",current_objective:"old cycle"}' \
  >"${numeric_cycle_dir}/session_state.json"
numeric_cycle_input="$(jq -nc --arg sid "${numeric_cycle_sid}" \
  --arg p '/ulw implement the bounded counter path' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
printf '%s' "${numeric_cycle_input}" \
  | OMC_TEST_ROUTER_NOW_EPOCH=424242 \
    bash "${ROUTER_SH}" >/dev/null 2>&1
numeric_cycle_rc=$?
set -e
assert_true "maximum review cycle fails closed before wrap" \
  "[[ ${numeric_cycle_rc} -ne 0 ]]"
assert_eq "maximum review cycle is never reset or wrapped" \
  "999999999999999" \
  "$(jq -r '.review_cycle_id // ""' \
    "${numeric_cycle_dir}/session_state.json")"

numeric_generation_sid="router-numeric-generation"
numeric_generation_dir="${STATE_ROOT}/${numeric_generation_sid}"
mkdir -p "${numeric_generation_dir}"
jq -nc '{workflow_mode:"",ulw_enforcement_active:"0",
  ulw_enforcement_generation:"999999999999999",prompt_revision:"1",
  review_cycle_id:"1",current_objective:"old generation"}' \
  >"${numeric_generation_dir}/session_state.json"
numeric_generation_input="$(jq -nc --arg sid "${numeric_generation_sid}" \
  --arg p '/ulw implement the bounded generation path' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
printf '%s' "${numeric_generation_input}" \
  | OMC_TEST_ROUTER_NOW_EPOCH=424242 \
    bash "${ROUTER_SH}" >/dev/null 2>&1
numeric_generation_rc=$?
set -e
assert_true "maximum enforcement generation fails closed before wrap" \
  "[[ ${numeric_generation_rc} -ne 0 ]]"
assert_eq "maximum enforcement generation remains unchanged" \
  "999999999999999" \
  "$(jq -r '.ulw_enforcement_generation // ""' \
    "${numeric_generation_dir}/session_state.json")"
assert_eq "failed generation increment never activates interval" "0" \
  "$(jq -r '.ulw_enforcement_active // ""' \
    "${numeric_generation_dir}/session_state.json")"

numeric_time_sid="router-numeric-time-fallbacks"
numeric_time_dir="${STATE_ROOT}/${numeric_time_sid}"
mkdir -p "${numeric_time_dir}"
jq -nc '{workflow_mode:"ultrawork",ulw_enforcement_active:"1",
  ulw_enforcement_generation:"1",prompt_revision:"2",review_cycle_id:"2",
  review_cycle_prompt_ts:"420000",current_objective:"continue bounded work",
  last_user_prompt_ts:"420000",midsession_checkpoint_last_fired_ts:
    "999999999999999999999999999999",
  directive_context_last_full_ts:"999999999999999999999999999999"}' \
  >"${numeric_time_dir}/session_state.json"
numeric_time_input="$(jq -nc --arg sid "${numeric_time_sid}" \
  --arg p 'continue' \
  '{session_id:$sid,prompt:$p,transcript_path:"/tmp/none.jsonl"}')"
set +e
numeric_time_output="$(printf '%s' "${numeric_time_input}" \
  | OMC_TEST_ROUTER_NOW_EPOCH=999999999999999999999999999999 \
    OMC_MID_SESSION_IDLE_THRESHOLD_SECS=999999999999999999999999999999 \
    bash "${ROUTER_SH}" 2>&1)"
numeric_time_rc=$?
set -e
assert_eq "oversized epoch/cache/checkpoint metadata falls back safely" "0" \
  "${numeric_time_rc}"
assert_contains_text "invalid threshold falls back and stale throttle is ignored" \
  "MID-SESSION CHECKPOINT" "${numeric_time_output}"
numeric_time_recorded="$(jq -r '.last_user_prompt_ts // ""' \
  "${numeric_time_dir}/session_state.json")"
assert_true "fallback epoch is canonical and bounded" \
  "[[ \"${numeric_time_recorded}\" =~ ^[1-9][0-9]{0,14}$ ]]"
assert_not_contains_text "invalid future checkpoint timestamp cannot throttle" \
  "999999999999999999999999999999" \
  "$(jq -r '.midsession_checkpoint_last_fired_ts // ""' \
    "${numeric_time_dir}/session_state.json")"

# A bash-stdout injection must also be skipped.
sid3="bash-stdout-test"
sdir3="${STATE_ROOT}/${sid3}"
mkdir -p "${sdir3}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  current_objective: "untouched objective"
}' > "${sdir3}/session_state.json"

run_router '<bash-stdout>
output line one
output line two
</bash-stdout>' "${sid3}" >/dev/null
assert_eq "bash-stdout: current_objective unchanged" "untouched objective" \
  "$(jq -r '.current_objective // ""' "${sdir3}/session_state.json")"

# v1.34.1: end-to-end regression for the <system-reminder> anchor
# specifically. Claude Code injects <system-reminder>...</system-reminder>
# wrappers around several flavors of synthetic content; if a future
# refactor drops `system-reminder` from the anchor list in
# is_synthetic_prompt, this test catches it before release.
sid4="system-reminder-test"
sdir4="${STATE_ROOT}/${sid4}"
mkdir -p "${sdir4}"
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  task_domain: "coding",
  current_objective: "v1.34.1 anchor regression target",
  done_contract_commit_mode: "required",
  last_user_prompt_ts: "2000"
}' > "${sdir4}/session_state.json"

run_router '<system-reminder>
This is a notice about something the model should know.
Multiple lines of synthetic content here.
</system-reminder>' "${sid4}" >/dev/null

assert_eq "system-reminder: current_objective preserved" "v1.34.1 anchor regression target" \
  "$(jq -r '.current_objective // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: task_intent preserved" "execution" \
  "$(jq -r '.task_intent // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: commit_mode preserved" "required" \
  "$(jq -r '.done_contract_commit_mode // ""' "${sdir4}/session_state.json")"
assert_eq "system-reminder: last_user_prompt_ts not bumped" "2000" \
  "$(jq -r '.last_user_prompt_ts // ""' "${sdir4}/session_state.json")"

# --- Quality-first model-routing directive ---
# The router renders common.sh's authoritative resolver decision. Verify every
# tier surfaces the live decision and the expected shipped-Sonnet class.
sid5="model-tier-test"
sdir5="${STATE_ROOT}/${sid5}"

for tier in quality economy balanced; do
  mkdir -p "${sdir5}"
  echo '{"workflow_mode":"ultrawork"}' > "${sdir5}/session_state.json"
  _omc_conf_loaded=0
  export OMC_MODEL_TIER="${tier}"
  output="$(run_router '/ulw test the model tier' "${sid5}")"
  context="$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
  has_directive="no"
  if [[ "${context}" == *"SUBAGENT MODEL ROUTING"* ]]; then
    has_directive="yes"
  fi
  assert_eq "model_tier=${tier}: routing directive present" "yes" "${has_directive}"
  case "${tier}" in
    quality)
      assert_contains_text "quality: shipped-Sonnet class resolves opus" \
        'pass `model: "opus"`' "${context}"
      ;;
    balanced|economy)
      assert_contains_text "${tier}: ordinary shipped-Sonnet class resolves sonnet" \
        'pass `model: "sonnet"`' "${context}"
      ;;
  esac
  if [[ "${tier}" == "economy" ]]; then
    assert_contains_text "model_tier=economy low-risk inherit class stays sonnet" \
      'For shipped inherit deliberators (quality-planner' "${context}"
    assert_contains_text "model_tier=economy low-risk inherit instruction" \
      'chief-of-staff), pass `model: "sonnet"`' "${context}"
  else
    assert_contains_text "model_tier=${tier}: inherit is represented by omission" \
      'chief-of-staff), OMIT the `model` parameter' "${context}"
  fi
  rm -rf "${sdir5}"
done
unset OMC_MODEL_TIER

# Invalid explicit environment values are one effective Balanced posture on
# every surface: rendered directive, persisted turn snapshot, and cache key.
sid5_invalid="model-tier-invalid"
sdir5_invalid="${STATE_ROOT}/${sid5_invalid}"
mkdir -p "${sdir5_invalid}"
echo '{"workflow_mode":"ultrawork"}' > "${sdir5_invalid}/session_state.json"
printf 'model_tier=quality\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
_omc_conf_loaded=0
export OMC_MODEL_TIER="not-a-model"
invalid_output="$(run_router '/ulw test invalid model tier normalization' "${sid5_invalid}")"
invalid_context="$(printf '%s' "${invalid_output}" \
  | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
assert_contains_text "invalid env tier preserves saved quality" \
  'tier=`quality`' "${invalid_context}"
assert_not_contains_text "invalid model tier never reaches directive metadata" \
  'not-a-model' "${invalid_context}"
assert_eq "invalid env tier snapshot preserves quality" "quality" \
  "$(jq -r '.model_routing_tier // ""' "${sdir5_invalid}/session_state.json")"
unset OMC_MODEL_TIER
rm -rf "${sdir5_invalid}"
rm -f "${TEST_HOME}/.claude/oh-my-claude.conf"

# The model-routing directive is domain-neutral: it must not inject coding
# specialists into writing/operations prompts merely to illustrate the tier.
model_routing_for_prompt() {
  local prompt="$1" sid="$2" output directive
  mkdir -p "${STATE_ROOT}/${sid}"
  echo '{"workflow_mode":"ultrawork"}' > "${STATE_ROOT}/${sid}/session_state.json"
  export OMC_MODEL_TIER="balanced"
  output="$(run_router "${prompt}" "${sid}")"
  directive="$(printf '%s' "${output}" \
    | jq -r '.hookSpecificOutput.additionalContext // ""' \
    | awk '/^SUBAGENT MODEL ROUTING / { print; exit }')"
  printf '%s' "${directive}"
  rm -rf "${STATE_ROOT:?}/${sid}"
}

writing_route="$(model_routing_for_prompt \
  '/ulw draft an executive memo for the board' 'model-tier-writing')"
operations_route="$(model_routing_for_prompt \
  '/ulw create a rollout schedule with owners, deadlines, and action items' 'model-tier-operations')"
assert_not_contains_text "balanced writing route does not inject frontend agent" \
  "frontend-developer" "${writing_route}"
assert_not_contains_text "balanced operations route does not inject backend agent" \
  "backend-api-developer" "${operations_route}"
assert_contains_text "balanced writing route retains override precedence" \
  "explicit user/env override > Council deep" "${writing_route}"
assert_contains_text "balanced operations route retains unknown/custom fallback" \
  "unknown/custom agents" "${operations_route}"
unset OMC_MODEL_TIER

# Test-portfolio reflection is part of the real coding directive, not only an
# agent-description promise. A maintenance-shaped prompt should receive the
# owner-first and affected-first guidance without requiring a separate mode.
sid6="test-portfolio-routing"
mkdir -p "${STATE_ROOT}/${sid6}"
echo '{"workflow_mode":"ultrawork"}' > "${STATE_ROOT}/${sid6}/session_state.json"
portfolio_output="$(run_router '/ulw consolidate stale redundant flaky tests in tests/test-router.sh' "${sid6}")"
portfolio_context="$(printf '%s' "${portfolio_output}" \
  | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
assert_contains_text "test portfolio route includes consolidation/retirement" \
  "portfolio consolidation or retirement" "${portfolio_context}"
assert_contains_text "test portfolio route inspects existing owners" \
  "inspect existing test owners before adding another" "${portfolio_context}"
assert_contains_text "test portfolio route runs affected proof" \
  "run affected proof after edits" "${portfolio_context}"
rm -rf "${STATE_ROOT:?}/${sid6}"

# --- Result -------------------------------------------------------------

printf '\n=== Synthetic-Prompt Filter Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
