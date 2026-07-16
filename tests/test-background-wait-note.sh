#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
#
# tests/test-background-wait-note.sh — v1.46-pre background-dispatch
# waiting-state awareness.
#
# Fixes the UX defect where the agent dispatches background work, yields to
# wait for the completion notification, and the turn-end reads as a STOP
# (and the stop-guard's "quality checks haven't run" block is misleading
# when the checks are running in the background).
#
# Three layers under test:
#   1. posttool-timing.sh detects a run_in_background dispatch (the
#      "running in background with ID:" tool_response marker) and sets
#      bg_work_dispatched_ts.
#   2. format_gate_block_dual appends a conditional waiting note when
#      _OMC_BG_WORK_PENDING_NOTE is set.
#   3. stop-guard consumes the marker single-shot and emits the note only when
#      the Stop registry still reports live work (or the field is omitted by
#      an old client). Present-empty is authoritative and cannot promise a
#      notification. The note remains message-only, never a gate bypass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

TEST_HOME="$(mktemp -d)"
export HOME="${TEST_HOME}"
export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
export SESSION_ID="bgwait-test"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
touch "${STATE_ROOT}/.ulw_active"
mkdir -p "${TEST_HOME}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${TEST_HOME}/.claude/skills/autowork"

cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT

# shellcheck source=/dev/null
. "${COMMON_SH}"

# is_ultrawork_mode() checks workflow_mode in state (not just the .ulw_active
# sentinel) — the stop-guard's ULW-gated blocks require it.
write_state workflow_mode "ultrawork"

pass=0
fail=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=  %q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}
state_get() { jq -r --arg k "$1" '.[$k] // ""' "${STATE_ROOT}/${SESSION_ID}/session_state.json" 2>/dev/null || printf ''; }

# --- Layer 2: format_gate_block_dual note injection ----------------------
printf '\n--- format_gate_block_dual waiting note ---\n'
unset _OMC_BG_WORK_PENDING_NOTE

# --- Runtime registry: absent is not empty; terminal rows are not live -----
printf '\n--- Stop runtime registry classification ---\n'
assert_eq "runtime field omitted -> unknown/absent" "absent" \
  "$(omc_stop_runtime_array_state '{}' 'background_tasks')"
assert_eq "present empty registry -> authoritative empty" "empty" \
  "$(omc_stop_runtime_array_state '{"background_tasks":[]}' 'background_tasks')"
assert_eq "running task -> live" "live" \
  "$(omc_stop_runtime_array_state \
    '{"background_tasks":[{"id":"a","status":"running"}]}' \
    'background_tasks')"
assert_eq "terminal task rows -> empty" "empty" \
  "$(omc_stop_runtime_array_state \
    '{"background_tasks":[{"id":"a","status":"completed"}]}' \
    'background_tasks')"
assert_eq "killed task row -> empty" "empty" \
  "$(omc_stop_runtime_array_state \
    '{"background_tasks":[{"id":"a","status":"killed"}]}' \
    'background_tasks')"
assert_eq "malformed registry remains unknown" "malformed" \
  "$(omc_stop_runtime_array_state '{"background_tasks":null}' 'background_tasks')"
assert_eq "object without task status remains unknown" "malformed" \
  "$(omc_stop_runtime_array_state '{"background_tasks":[{}]}' 'background_tasks')"
assert_eq "null task status remains unknown" "malformed" \
  "$(omc_stop_runtime_array_state \
    '{"background_tasks":[{"id":"a","status":null}]}' \
    'background_tasks')"

canonical_wait_line="⏳ Waiting on the quality-reviewer — running in the background; I'll resume automatically when it finishes. Nothing for you to do."
assert_eq "structural final auto-resume line -> background wait" "background" \
  "$(omc_stop_wait_claim_kind "${canonical_wait_line}")"
assert_eq "quoted wait example followed by ordinary prose -> not a wait" "" \
  "$(omc_stop_wait_claim_kind \
    $'> ⏳ Waiting on example — I\'ll resume automatically. Nothing for you to do.\nThis documentation update is complete.' 2>/dev/null || true)"
assert_eq "auto-resume words in report body -> not a wait" "" \
  "$(omc_stop_wait_claim_kind \
    $'The worker said it would resume automatically in the background.\nVerification is complete.' 2>/dev/null || true)"
assert_eq "progress-only waiting line -> not a promised wake" "" \
  "$(omc_stop_wait_claim_kind '⏳ Waiting on review evidence.' 2>/dev/null || true)"
assert_eq "scheduled-wake shape remains distinct" "scheduled" \
  "$(omc_stop_wait_claim_kind \
    '⏳ Waiting for the scheduled fallback — this session will wake for the next check. Nothing for you to do.')"
assert_eq "final blockquoted wait example -> not a wait" "" \
  "$(omc_stop_wait_claim_kind \
    "> ${canonical_wait_line}" 2>/dev/null || true)"
assert_eq "unknown namespaced reviewer keeps custom behavior" "" \
  "$(omc_enforced_terminal_contract_kind \
    'thirdparty:quality-reviewer' 2>/dev/null || true)"
assert_eq "official plugin reviewer keeps its own output contract" "" \
  "$(omc_enforced_terminal_contract_kind \
    'feature-dev:code-reviewer' 2>/dev/null || true)"
assert_eq "no flag -> no note" "0" \
  "$(format_gate_block_dual "you stopped" "do X" | grep -c 'this block is expected' || true)"
_OMC_BG_WORK_PENDING_NOTE=1
assert_eq "flag -> note appended (dual form)" "1" \
  "$(format_gate_block_dual "you stopped" "do X" | grep -c 'this block is expected' || true)"
assert_eq "flag -> FOR YOU/FOR MODEL preserved" "1" \
  "$(format_gate_block_dual "you stopped" "do X" | grep -c 'FOR MODEL' || true)"
assert_eq "flag -> note on prose-only form too" "1" \
  "$(format_gate_block_dual "" "do X" | grep -c 'this block is expected' || true)"
unset _OMC_BG_WORK_PENDING_NOTE

# --- Layer 1: posttool-timing detection ----------------------------------
printf '\n--- posttool-timing background-dispatch detection ---\n'
write_state bg_work_dispatched_ts ""
printf '%s' '{"session_id":"bgwait-test","tool_name":"Bash","tool_use_id":"a","tool_response":"Command running in background with ID: zzz9. Output is being written to: /tmp/x"}' \
  | bash "${HOOK_DIR}/posttool-timing.sh" 2>/dev/null || true
assert_eq "bg dispatch sets marker" "1" "$([[ -n "$(state_get bg_work_dispatched_ts)" ]] && echo 1 || echo 0)"

write_state bg_work_dispatched_ts ""
printf '%s' '{"session_id":"bgwait-test","tool_name":"Read","tool_use_id":"b","tool_response":"ordinary file contents, no marker"}' \
  | bash "${HOOK_DIR}/posttool-timing.sh" 2>/dev/null || true
assert_eq "normal tool leaves marker empty" "" "$(state_get bg_work_dispatched_ts)"

# time_tracking=off short-circuits the whole hook (detection included)
write_state bg_work_dispatched_ts ""
printf '%s' '{"session_id":"bgwait-test","tool_name":"Bash","tool_use_id":"c","tool_response":"Command running in background with ID: q. Output: /tmp/y"}' \
  | OMC_TIME_TRACKING=off bash "${HOOK_DIR}/posttool-timing.sh" 2>/dev/null || true
assert_eq "time_tracking=off skips detection" "" "$(state_get bg_work_dispatched_ts)"

# --- Layer 3: stop-guard single-shot consume + message-only --------------
printf '\n--- stop-guard: note on block, decision unchanged, single-shot ---\n'
# A permission-coded continuation ask reliably trips the handoff block; the
# note rides any block path (shared formatter). Set the bg marker first.
write_state task_intent "execution"
write_state current_objective "ship it"
write_state last_user_prompt_ts "100"
write_state last_edit_ts "200"
write_state bg_work_dispatched_ts "150"
_blockmsg='Next. If you want Wave 7-9 shipped in this session, I can continue -- say "keep going" and name which to prioritize. Otherwise this is a clean stopping point.'
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${_blockmsg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg,
    background_tasks:[{id:"bg-1",type:"bash",status:"running"}],session_crons:[]}' \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_eq "block STILL fires with bg marker (decision unchanged)" "1" \
  "$(printf '%s' "${out}" | grep -c '"decision":"block"' || true)"
assert_eq "block message carries the waiting note" "1" \
  "$(printf '%s' "${out}" | grep -c 'this block is expected' || true)"
assert_eq "bg marker consumed single-shot" "" "$(state_get bg_work_dispatched_ts)"

# A stale dispatch marker plus a present-empty level registry must not make the
# exact promise implicated in the incident.
write_state bg_work_dispatched_ts "151"
empty_runtime_out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${_blockmsg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg,
    background_tasks:[],session_crons:[]}' \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_eq "authoritative empty registry suppresses waiting note" "0" \
  "$(printf '%s' "${empty_runtime_out}" | grep -c 'this block is expected' || true)"
assert_eq "empty-registry marker still consumed" "" "$(state_get bg_work_dispatched_ts)"

# Second Stop, marker now empty (consumed): same block, NO note -> proves
# the note cannot stale into a later, unrelated block.
out2="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${_blockmsg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_eq "block still fires on 2nd stop" "1" \
  "$(printf '%s' "${out2}" | grep -c '"decision":"block"' || true)"
assert_eq "no stale note after consume" "0" \
  "$(printf '%s' "${out2}" | grep -c 'this block is expected' || true)"

# --- F1 leak-path guard: consume runs BEFORE early-return exits ----------
# The marker must be consumed even when stop-guard takes an early exit
# (stop_hook_active=true), otherwise it leaks and a later, unrelated block
# carries a stale "waiting" note (the bug quality-reviewer reproduced; the
# consume was moved ahead of every early-return path to fix it).
printf '\n--- F1: single-shot consume runs before early-return paths ---\n'
write_state bg_work_dispatched_ts "150"
printf '%s' '{"session_id":"bgwait-test","stop_hook_active":true,"last_assistant_message":"x"}' \
  | bash "${HOOK_DIR}/stop-guard.sh" >/dev/null 2>&1 || true
assert_eq "marker consumed on stop_hook_active early-exit" "" "$(state_get bg_work_dispatched_ts)"
# A later, UNRELATED block must NOT carry a stale waiting note now.
_leak_out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${_blockmsg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>/dev/null || true)"
assert_eq "no stale note after early-exit consume" "0" \
  "$(printf '%s' "${_leak_out}" | grep -c 'this block is expected' || true)"

printf '\n=== test-background-wait-note.sh: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
