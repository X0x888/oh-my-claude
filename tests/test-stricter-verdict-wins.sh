#!/usr/bin/env bash
# Regression net for v1.44-pre Port 2 — stricter-verdict-wins invariant.
#
# Covers two mechanisms working together:
#   1. Storage-side: tick_dimensions_with_verdict / set_dimension_verdicts
#      route through _write_stricter_dim_verdicts_unlocked, which preserves
#      the stricter of (current, new) verdict on a CLEAN < FINDINGS < BLOCK
#      severity ladder. Edit-aware: a FINDINGS verdict that predates its
#      dimension-specific freshness clock is replaced by a fresh CLEAN.
#   2. Gate-side: stop-guard's stricter-verdict-wins gate scans required
#      dim verdicts and blocks Stop on any fresh FINDINGS*/BLOCK*.
#
# Closes cc10x F11 — "for contradictory verdicts across agents, treat the
# stricter verdict as authoritative; never average or reconcile." Before
# this wave, oh-my-claude's implicit semantics was "last-reviewer-wins"
# (dim_<dim>_verdict overwritten by whichever reviewer wrote last), and
# stop-guard only consumed dim ts (not verdict) for the review-coverage
# gate — so a sibling reviewer's FINDINGS could be silently dropped.
#
# Cross-ref: AGENTS.md "Stricter-verdict-wins invariant (v1.44-pre)";
# common.sh:_stricter_verdict, _write_stricter_dim_verdicts_unlocked;
# stop-guard.sh stricter-verdict-wins gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t stricter-verdict-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

# Activate ULW for the whole test — record-reviewer.sh fast-exits on
# missing .ulw_active sentinel + on is_ultrawork_mode() returning false.
# Both must hold for the dim helpers to be reached via the real call path.
mkdir -p "${_test_home}/.claude/quality-pack/state"
touch "${_test_home}/.claude/quality-pack/state/.ulw_active"

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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected=%q\n    haystack=%q\n' \
      "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

_cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup EXIT

reset_session() {
  local sid="$1"
  export SESSION_ID="${sid}"
  # _state_validated is a process-local cache from a prior session; the
  # write helpers skip _ensure_valid_state when it's 1, leaving a fresh
  # session_state.json uncreated. Reset it so each per-session call path
  # initializes from a clean slate.
  _state_validated=0
  ensure_session_dir
  # Pre-create the JSON file with workflow_mode=ultrawork so the dim
  # helpers' callers (record-reviewer.sh etc.) reach the verdict-write
  # path. is_ultrawork_mode() reads this key.
  printf '{"workflow_mode":"ultrawork"}\n' >"$(session_file "session_state.json")"
}

# ---------------------------------------------------------------------------
# Block 1: _stricter_verdict helper unit tests
# ---------------------------------------------------------------------------
printf '\n_stricter_verdict unit tests\n'

assert_eq "T1a: empty current → new wins" "FINDINGS" "$(_stricter_verdict '' 'FINDINGS')"
assert_eq "T1b: empty new → current wins" "FINDINGS" "$(_stricter_verdict 'FINDINGS' '')"
assert_eq "T1c: CLEAN vs FINDINGS → FINDINGS" "FINDINGS" "$(_stricter_verdict 'CLEAN' 'FINDINGS')"
assert_eq "T1d: FINDINGS vs CLEAN → FINDINGS" "FINDINGS" "$(_stricter_verdict 'FINDINGS' 'CLEAN')"
assert_eq "T1e: SHIP vs CLEAN → SHIP (tie at rank 0, current wins)" "SHIP" "$(_stricter_verdict 'SHIP' 'CLEAN')"
assert_eq "T1f: FINDINGS (3) preserved over CLEAN" "FINDINGS (3)" "$(_stricter_verdict 'FINDINGS (3)' 'CLEAN')"
assert_eq "T1g: BLOCK beats FINDINGS" "BLOCK (2)" "$(_stricter_verdict 'FINDINGS (1)' 'BLOCK (2)')"
assert_eq "T1h: BLOCK preserved over CLEAN" "BLOCK (1)" "$(_stricter_verdict 'BLOCK (1)' 'CLEAN')"

# ---------------------------------------------------------------------------
# Block 2: storage stricter-wins via the dim helpers (no edit boundary)
# ---------------------------------------------------------------------------
printf '\nStorage-side stricter-wins (same code state)\n'

# Scenario: CLEAN reviewer runs first, then FINDINGS reviewer.
reset_session "s2a"
write_state "last_code_edit_ts" "100"
tick_dimensions_with_verdict "CLEAN" "110" "bug_hunt"
set_dimension_verdicts "FINDINGS" "bug_hunt"
assert_eq "T2a: CLEAN-then-FINDINGS → final verdict is FINDINGS (stricter wins)" \
  "FINDINGS" "$(read_state "dim_bug_hunt_verdict")"

# Scenario: FINDINGS reviewer runs first, then CLEAN reviewer (same code state).
reset_session "s2b"
write_state "last_code_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "bug_hunt"
tick_dimensions_with_verdict "CLEAN" "120" "bug_hunt"
assert_eq "T2b: FINDINGS-then-CLEAN (no edit between) → final verdict is FINDINGS (stricter preserved)" \
  "FINDINGS" "$(read_state "dim_bug_hunt_verdict")"

# Scenario: CLEAN twice — last write wins on a tie, but verdict stays CLEAN.
reset_session "s2c"
write_state "last_code_edit_ts" "100"
tick_dimensions_with_verdict "CLEAN" "110" "bug_hunt"
tick_dimensions_with_verdict "CLEAN" "120" "bug_hunt"
assert_eq "T2c: CLEAN-then-CLEAN → verdict stays CLEAN" \
  "CLEAN" "$(read_state "dim_bug_hunt_verdict")"
assert_eq "T2c: CLEAN-then-CLEAN → ts updated to second write" \
  "120" "$(read_state "dim_bug_hunt_ts")"

# Scenario: parity — set_dimension_verdicts now also stamps ts (was missing pre-v1.44-pre)
reset_session "s2d"
write_state "last_code_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "stress_test"
assert_eq "T2d: set_dimension_verdicts now stamps ts (parity with tick_dimensions_with_verdict)" \
  "1" "$([[ -n "$(read_state "dim_stress_test_ts")" ]] && echo 1 || echo 0)"
assert_eq "T2d: set_dimension_verdicts writes the verdict" \
  "FINDINGS" "$(read_state "dim_stress_test_verdict")"

# ---------------------------------------------------------------------------
# Block 3: edit-aware override (fix-and-re-review path must clear FINDINGS)
# ---------------------------------------------------------------------------
printf '\nEdit-aware override (post-fix re-review clears FINDINGS)\n'

reset_session "s3a"
write_state "last_code_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "bug_hunt"
# set_dimension_verdicts stamps ts via now_epoch — read it back, then
# advance last_code_edit_ts past it to simulate a real code edit after
# the FINDINGS review.
findings_ts="$(read_state "dim_bug_hunt_ts")"
write_state "last_code_edit_ts" "$((findings_ts + 100))"
# Fresh CLEAN run AFTER the edit.
tick_dimensions_with_verdict "CLEAN" "$((findings_ts + 200))" "bug_hunt"
assert_eq "T3a: FINDINGS, EDIT, fresh CLEAN → CLEAN wins (FINDINGS was stale)" \
  "CLEAN" "$(read_state "dim_bug_hunt_verdict")"
assert_eq "T3a: ts updated to post-edit CLEAN" "$((findings_ts + 200))" "$(read_state "dim_bug_hunt_ts")"

# Prose follows document edits, not implementation edits. A doc fix permits a
# fresh CLEAN to replace FINDINGS; an unrelated code edit does not.
reset_session "s3b"
write_state "last_doc_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "prose"
prose_findings_ts="$(read_state "dim_prose_ts")"
write_state "last_doc_edit_ts" "$((prose_findings_ts + 100))"
tick_dimensions_with_verdict "CLEAN" "$((prose_findings_ts + 200))" "prose"
assert_eq "T3b: prose FINDINGS, DOC EDIT, fresh CLEAN → CLEAN" \
  "CLEAN" "$(read_state "dim_prose_verdict")"

reset_session "s3c"
write_state "last_doc_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "prose"
prose_findings_ts="$(read_state "dim_prose_ts")"
write_state "last_code_edit_ts" "$((prose_findings_ts + 100))"
tick_dimensions_with_verdict "CLEAN" "$((prose_findings_ts + 200))" "prose"
assert_eq "T3c: unrelated CODE EDIT does not erase prose FINDINGS" \
  "FINDINGS" "$(read_state "dim_prose_verdict")"

# Completeness and traceability cover the whole objective. A document edit is
# therefore enough to stale their earlier findings and allow a clean re-review.
reset_session "s3d"
write_state "last_edit_ts" "100"
set_dimension_verdicts "FINDINGS" "completeness" "traceability"
aggregate_findings_ts="$(read_state "dim_completeness_ts")"
write_state "last_doc_edit_ts" "$((aggregate_findings_ts + 100))"
write_state "last_edit_ts" "$((aggregate_findings_ts + 100))"
tick_dimensions_with_verdict "CLEAN" "$((aggregate_findings_ts + 200))" \
  "completeness" "traceability"
assert_eq "T3d: doc edit invalidates completeness FINDINGS" \
  "CLEAN" "$(read_state "dim_completeness_verdict")"
assert_eq "T3d: doc edit invalidates traceability FINDINGS" \
  "CLEAN" "$(read_state "dim_traceability_verdict")"

# Stress-test findings belong to the plan. Implementation edits do not make
# them stale; recording a newer plan does.
reset_session "s3e"
write_state "plan_ts" "100"
set_dimension_verdicts "FINDINGS" "stress_test"
stress_findings_ts="$(read_state "dim_stress_test_ts")"
write_state "last_code_edit_ts" "$((stress_findings_ts + 100))"
write_state "last_edit_ts" "$((stress_findings_ts + 100))"
tick_dimensions_with_verdict "CLEAN" "$((stress_findings_ts + 200))" "stress_test"
assert_eq "T3e: implementation edit does not erase stress-test FINDINGS" \
  "FINDINGS" "$(read_state "dim_stress_test_verdict")"
write_state "plan_ts" "$((stress_findings_ts + 300))"
tick_dimensions_with_verdict "CLEAN" "$((stress_findings_ts + 400))" "stress_test"
assert_eq "T3e: a newer plan lets fresh stress-test CLEAN replace FINDINGS" \
  "CLEAN" "$(read_state "dim_stress_test_verdict")"

# ---------------------------------------------------------------------------
# Block 4: end-to-end through record-reviewer.sh (real call path)
# ---------------------------------------------------------------------------
printf '\nEnd-to-end via record-reviewer.sh\n'

# Helper: drive record-reviewer.sh with a synthesized SubagentStop payload.
# Mirrors how Claude Code invokes the hook in production: positional
# REVIEWER_TYPE arg controls which dimension(s) tick. quality-reviewer
# is REVIEWER_TYPE="standard" (default); excellence-reviewer is
# REVIEWER_TYPE="excellence".
_drive_record_reviewer() {
  local sid="$1" reviewer_type="$2" message="$3"
  local agent_type="${4:-}"
  local native_agent_id="${5:-}"
  local payload
  payload="$(jq -nc --arg sid "${sid}" --arg msg "${message}" --arg agent "${agent_type}" \
    --arg native_id "${native_agent_id}" \
    '{session_id:$sid, last_assistant_message:$msg}
     + if $agent == "" then {} else {agent_type:$agent} end
     + if $native_id == "" then {} else {agent_id:$native_id} end')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" "${reviewer_type}" \
    <<<"${payload}" >/dev/null 2>&1 || true
}

_drive_agent_dispatch() {
  local sid="$1" agent_type="$2" description="${3:-review current work}"
  local payload
  payload="$(jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg desc "${description}" '
    {session_id:$sid,tool_name:"Agent",tool_input:{subagent_type:$agent,description:$desc,prompt:"review"}}')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh" \
    <<<"${payload}" 2>/dev/null || true
}

_drive_subagent_summary() {
  local sid="$1" agent_type="$2" message="$3" native_agent_id="${4:-}"
  _drive_subagent_summary_out "${sid}" "${agent_type}" "${message}" \
    "${native_agent_id}" >/dev/null 2>&1 || true
}

_drive_subagent_summary_out() {
  local sid="$1" agent_type="$2" message="$3" native_agent_id="${4:-}"
  local stop_hook_active="${5:-false}"
  local fail_after_outcome_stage="${6:-0}"
  local fail_outcome_build="${7:-0}"
  local kill_after_outcome_stage="${8:-0}"
  local kill_after_start_cleanup="${9:-0}"
  local kill_after_pending_cleanup="${10:-0}"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg msg "${message}" \
    --arg native_id "${native_agent_id}" --argjson active "${stop_hook_active}" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$msg}
     + {stop_hook_active:$active}
     + if $native_id == "" then {} else {agent_id:$native_id} end' \
    | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      OMC_TEST_SUMMARY_FAIL_AFTER_OUTCOME_STAGE="${fail_after_outcome_stage}" \
      OMC_TEST_SUMMARY_FAIL_OUTCOME_BUILD="${fail_outcome_build}" \
      OMC_TEST_SUMMARY_KILL_AFTER_OUTCOME_STAGE="${kill_after_outcome_stage}" \
      OMC_TEST_SUMMARY_KILL_AFTER_START_CLEANUP="${kill_after_start_cleanup}" \
      OMC_TEST_SUMMARY_KILL_AFTER_PENDING_CLEANUP="${kill_after_pending_cleanup}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
      2>/dev/null || true
}

_jsonl_count() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    jq -s 'length' "${path}"
  else
    printf '0'
  fi
}

_drive_agent_start() {
  local sid="$1" agent_type="$2" native_agent_id="$3"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg native_id "${native_agent_id}" \
    '{session_id:$sid,agent_type:$agent,agent_id:$native_id}' \
    | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-pending-agent.sh" start \
      >/dev/null 2>&1
}

_drive_record_plan() {
  local sid="$1" agent_type="$2" message="$3" native_agent_id="${4:-}"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg msg "${message}" \
    --arg native_id "${native_agent_id}" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$msg}
     + if $native_id == "" then {} else {agent_id:$native_id} end' \
    | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh" \
      >/dev/null 2>&1 || true
}

_drive_reflect_after_agent() {
  local sid="$1" agent_type="$2" run_in_background="${3:-false}"
  local response_status="${4:-}" native_agent_id="${5:-}"
  local response_is_async="${6:-false}"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" \
    --argjson background "${run_in_background}" \
    --arg response_status "${response_status}" \
    --arg native_id "${native_agent_id}" \
    --argjson is_async "${response_is_async}" '
    {session_id:$sid,tool_name:"Agent",
     tool_input:{subagent_type:$agent,description:"review current work",
       run_in_background:$background}}
    + if $response_status == "" and $native_id == "" then {}
      else {tool_response:
        ((if $response_status == "" then {} else {status:$response_status} end)
         + (if $is_async then {isAsync:true} else {} end)
         + (if $native_id == "" then {} else {agentId:$native_id} end))}
      end
  ' | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/reflect-after-agent.sh" \
    2>/dev/null || true
}

# In oh-my-claude's reviewer map, each REVIEWER_TYPE owns its own
# dimension(s). The cross-reviewer-same-dim overlap that cc10x F11
# names exists when third-party code-reviewers (`superpowers:code-reviewer`,
# `feature-dev:code-reviewer`) ALSO dispatch as REVIEWER_TYPE=standard
# alongside quality-reviewer — both cover bug_hunt+code_quality.
#
# Test the SAME REVIEWER_TYPE dispatched twice (e.g., a sibling code-reviewer
# running after quality-reviewer on the same code state).
reset_session "s4_external_contract"
with_state_lock_batch \
  "edit_revision" "1" "last_code_edit_revision" "1" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "99" \
  "last_user_prompt_ts" "99" "prompt_revision" "1"
_drive_agent_dispatch "s4_external_contract" \
  "feature-dev:code-reviewer" >/dev/null
_drive_agent_start "s4_external_contract" \
  "feature-dev:code-reviewer" "native-feature-review"
_drive_record_reviewer "s4_external_contract" "standard" \
  "The implementation looks clean with no issues." \
  "feature-dev:code-reviewer" "native-feature-review"
assert_eq "T4-external: plugin review keeps its own prose contract" "false" \
  "$(read_state "review_had_findings")"
assert_eq "T4-external: plugin prose can tick standard review" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"

reset_session "s4a"
write_state "last_code_edit_ts" "100"
_drive_record_reviewer "s4a" "standard" "Looks clean.

VERDICT: CLEAN"
assert_eq "T4a: first standard CLEAN → bug_hunt verdict is CLEAN" \
  "CLEAN" "$(read_state "dim_bug_hunt_verdict")"
_drive_record_reviewer "s4a" "standard" "Found a defect on the same code.

VERDICT: FINDINGS (1)"
# Stricter-wins: even though both reviewers were REVIEWER_TYPE=standard,
# the second FINDINGS must preserve over the first CLEAN.
assert_eq "T4a: standard CLEAN-then-FINDINGS → bug_hunt stays FINDINGS" \
  "FINDINGS" "$(read_state "dim_bug_hunt_verdict")"
assert_eq "T4a: standard CLEAN-then-FINDINGS → code_quality stays FINDINGS" \
  "FINDINGS" "$(read_state "dim_code_quality_verdict")"

# Reverse order — FINDINGS first, then CLEAN. Stricter-wins preserves
# the FINDINGS in storage; review_had_findings reflects the LATEST
# reviewer's outcome (CLEAN here) per record-reviewer.sh's standard
# branch — but the dim_verdict carries the stricter signal.
reset_session "s4b"
write_state "last_code_edit_ts" "100"
_drive_record_reviewer "s4b" "standard" "Found a defect.

VERDICT: FINDINGS (1)"
_drive_record_reviewer "s4b" "standard" "Looks clean.

VERDICT: CLEAN"
assert_eq "T4b: standard FINDINGS-then-CLEAN → bug_hunt stays FINDINGS (stricter preserved)" \
  "FINDINGS" "$(read_state "dim_bug_hunt_verdict")"
# Last-writer-wins on review_had_findings (the latest reviewer cleared);
# stricter-wins on dim_verdict (the prior FINDINGS preserved).
assert_eq "T4b: review_had_findings reflects latest reviewer (CLEAN)" \
  "false" "$(read_state "review_had_findings")"

# Specialist reviewer state is role-isolated. Specialists may tick their own
# dimensions, but they must neither manufacture a universal review clock nor
# clear a standard quality review's findings.
reset_session "s4c"
write_state "last_code_edit_ts" "100"
write_state "last_doc_edit_ts" "100"
write_state "last_edit_ts" "100"
write_state "plan_ts" "100"
for specialist in excellence prose stress_test traceability design_quality release; do
  _drive_record_reviewer "s4c" "${specialist}" "Specialist pass is clean.

VERDICT: CLEAN"
done
assert_eq "T4c: specialists before standard do not set last_review_ts" \
  "" "$(read_state "last_review_ts")"
assert_eq "T4c: specialists before standard do not set review_had_findings" \
  "" "$(read_state "review_had_findings")"

reset_session "s4d"
write_state "last_code_edit_ts" "100"
write_state "last_doc_edit_ts" "100"
write_state "last_edit_ts" "100"
write_state "plan_ts" "100"
_drive_record_reviewer "s4d" "standard" "A blocking defect remains.

VERDICT: FINDINGS (1)"
standard_findings_ts="$(read_state "last_review_ts")"
for specialist in excellence prose stress_test traceability design_quality release; do
  _drive_record_reviewer "s4d" "${specialist}" "Specialist pass is clean.

VERDICT: CLEAN"
done
assert_eq "T4d: specialist CLEAN does not clear standard review_had_findings" \
  "true" "$(read_state "review_had_findings")"
assert_eq "T4d: specialist CLEAN does not replace standard last_review_ts" \
  "${standard_findings_ts}" "$(read_state "last_review_ts")"

# Review evidence is causal: the accepted generation is captured when Agent
# starts, not when SubagentStop arrives. An edit during the review invalidates
# the result without advancing either metadata or dimension state.
reset_session "s4e"
with_state_lock_batch \
  "edit_revision" "1" \
  "last_code_edit_revision" "1" \
  "last_code_edit_ts" "100"
first_dispatch="$(_drive_agent_dispatch "s4e" "quality-reviewer")"
assert_eq "T4e: first gate-reviewer dispatch is allowed" "" "${first_dispatch}"
with_state_lock_batch \
  "edit_revision" "2" \
  "last_code_edit_revision" "2" \
  "last_code_edit_ts" "101"
_drive_record_reviewer "s4e" "standard" $'Review completed.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4e: edit-during-review does not advance last_review_ts" \
  "" "$(read_state "last_review_ts")"
assert_eq "T4e: edit-during-review does not tick bug_hunt" \
  "" "$(read_state "dim_bug_hunt_ts")"
assert_eq "T4e: stale diagnostic preserves dispatch generation" \
  "1" "$(read_state "last_stale_reviewer_start_revision")"
assert_eq "T4e: stale diagnostic records completion generation" \
  "2" "$(read_state "last_stale_reviewer_current_revision")"
_stale_history_count=0
if [[ -f "$(session_file "review_history.jsonl")" ]]; then
  _stale_history_count="$(jq -s 'length' "$(session_file "review_history.jsonl")")"
fi
assert_eq "T4e: stale review creates no remediation history" \
  "0" "${_stale_history_count}"

# Universal SubagentStop cleanup removes the completed pending row, but must
# independently preserve the same generation rejection. It may not publish an
# apparently accepted summary/capsule after the reviewer hook rejects the
# evidence. A fresh dispatch at generation 2 is then accepted and atomically
# stamps the legacy review generation plus both standard dimensions.
_drive_subagent_summary "s4e" "quality-reviewer" $'Review completed.\nVERDICT: CLEAN'
assert_eq "T4e: stale reviewer creates no universal summary" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then
      jq -s 'length' "$(session_file "subagent_summaries.jsonl")"
    else printf 0; fi)"
assert_eq "T4e: stale reviewer completion is explicitly ignored" "ignored" \
  "$(tail -n 1 "$(session_file "agent_completion_outcomes.jsonl")" \
    | jq -r '.status')"
assert_eq "T4e: stale reviewer capsule names its generation rejection" \
  "review-generation-changed" \
  "$(tail -n 1 "$(session_file "agent_completion_outcomes.jsonl")" \
    | jq -r '.reason')"
fresh_dispatch="$(_drive_agent_dispatch "s4e" "quality-reviewer")"
assert_eq "T4e: fresh post-edit reviewer dispatch is allowed" "" "${fresh_dispatch}"
_drive_record_reviewer "s4e" "standard" $'Fresh review completed.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4e: accepted review stamps legacy code generation" \
  "2" "$(read_state "review_code_revision")"
assert_eq "T4e: accepted review stamps bug_hunt generation" \
  "2" "$(read_state "dim_bug_hunt_revision")"
assert_eq "T4e: accepted review stamps code_quality generation" \
  "2" "$(read_state "dim_code_quality_revision")"
assert_eq "T4e: accepted review records bounded history revision" \
  "2" "$(tail -n 1 "$(session_file "review_history.jsonl")" | jq -r '.revision')"

# Exercise the opposite hook order on a reviewer whose structured findings
# normally feed discovered scope. Summary runs first after a plan edit. The
# stale Metis response must create neither an accepted capsule nor a generic
# remediation obligation before record-reviewer.sh gets its own turn.
reset_session "s4e_summary_first"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "405" \
  "last_user_prompt_ts" "405" "prompt_revision" "4" \
  "plan_revision" "1"
_drive_agent_dispatch "s4e_summary_first" "metis" >/dev/null
with_state_lock_batch "plan_revision" "2"
stale_metis_message=$'FINDINGS_JSON: [{"severity":"medium","category":"completeness","file":"plan","line":1,"claim":"The old plan misses a rollback step","evidence":"The frozen plan had no rollback section","recommended_fix":"Add and re-review a rollback step"}]\nVERDICT: FINDINGS (1)'
_drive_subagent_summary "s4e_summary_first" "metis" "${stale_metis_message}"
assert_eq "T4e-summary-first: stale Metis creates no universal summary" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then
      jq -s 'length' "$(session_file "subagent_summaries.jsonl")"
    else printf 0; fi)"
assert_eq "T4e-summary-first: stale Metis creates no discovered-scope debt" "0" \
  "$(if [[ -f "$(session_file "discovered_scope.jsonl")" ]]; then
      jq -s 'length' "$(session_file "discovered_scope.jsonl")"
    else printf 0; fi)"
assert_eq "T4e-summary-first: stale Metis outcome is ignored" "ignored" \
  "$(tail -n 1 "$(session_file "agent_completion_outcomes.jsonl")" \
    | jq -r '.status')"
assert_eq "T4e-summary-first: stale Metis reason is generation-bound" \
  "review-generation-changed" \
  "$(tail -n 1 "$(session_file "agent_completion_outcomes.jsonl")" \
    | jq -r '.reason')"
_drive_record_reviewer "s4e_summary_first" "stress_test" \
  "${stale_metis_message}" "metis"
assert_eq "T4e-summary-first: role hook also rejects stale Metis" "" \
  "$(read_state "dim_stress_test_ts")"

# PreToolUse runs before the native SubagentStart agent_id exists, so one exact
# identity at a time makes the subsequent bind unique. Different roles retain
# the intended parallelism.
reset_session "s4f"
with_state_lock_batch "edit_revision" "1" "last_code_edit_revision" "1"
first_same_role="$(_drive_agent_dispatch "s4f" "quality-reviewer")"
second_same_role="$(_drive_agent_dispatch "s4f" "quality-reviewer")"
different_role="$(_drive_agent_dispatch "s4f" "excellence-reviewer")"
assert_eq "T4f: initial same-role review is allowed" "" "${first_same_role}"
assert_contains "T4f: duplicate in-flight same-role review is denied" \
  '"permissionDecision":"deny"' "${second_same_role}"
assert_contains "T4f: active denial offers explicit killed-call recovery" \
  '[review-rebind:' "${second_same_role}"
assert_contains "T4f: recovery token is conditional on confirmed interruption" \
  'confirmed this call was killed or interrupted' "${second_same_role}"
assert_eq "T4f: different reviewer role remains parallel" "" "${different_role}"

# A killed reviewer can be retried after the abandonment TTL, but only through
# an explicit dispatch binding. The bound retry may finish first; a late
# unlabelled completion must consume/reject the abandoned row, never the retry.
reset_session "s4f_rebind"
with_state_lock_batch "edit_revision" "1" "last_code_edit_revision" "1"
abandoned_dispatch="$(_drive_agent_dispatch "s4f_rebind" "quality-reviewer")"
assert_eq "T4f-rebind: initial reviewer dispatch is allowed" "" "${abandoned_dispatch}"
abandoned_ts="$(( $(date +%s) - 7201 ))"
for ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  ledger_path="$(session_file "${ledger}")"
  jq -c --argjson stale "${abandoned_ts}" '.ts=$stale' \
    "${ledger_path}" >"${ledger_path}.tmp"
  mv "${ledger_path}.tmp" "${ledger_path}"
done
unbound_retry="$(_drive_agent_dispatch "s4f_rebind" "quality-reviewer")"
assert_contains "T4f-rebind: stale reviewer retry requires explicit binding" \
  '[review-rebind:' "${unbound_retry}"
bound_retry="$(_drive_agent_dispatch "s4f_rebind" "quality-reviewer" \
  '[review-rebind:retry-1] Review current work; emit REVIEW_DISPATCH_ID: retry-1 immediately before VERDICT')"
assert_eq "T4f-rebind: explicitly bound retry is allowed" "" "${bound_retry}"
collision_retry="$(_drive_agent_dispatch "s4f_rebind" "quality-reviewer" \
  '[review-rebind:retry-1] duplicate recovery ID')"
assert_contains "T4f-rebind: duplicate recovery ID is denied as a collision" \
  'already present' "${collision_retry}"
assert_eq "T4f-rebind: old start is marked abandoned" "true" \
  "$(head -n 1 "$(session_file "agent_dispatch_starts.jsonl")" | jq -r '.review_dispatch_abandoned')"
assert_eq "T4f-rebind: retry start carries its unique ID" "retry-1" \
  "$(tail -n 1 "$(session_file "agent_dispatch_starts.jsonl")" | jq -r '.review_dispatch_id')"
bound_message=$'Bound retry completed.\nREVIEW_DISPATCH_ID: retry-1\nVERDICT: CLEAN'
_drive_record_reviewer "s4f_rebind" "standard" "${bound_message}" "quality-reviewer"
_drive_subagent_summary "s4f_rebind" "quality-reviewer" "${bound_message}"
assert_eq "T4f-rebind: bound retry is accepted" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"
late_message=$'Late abandoned review claims a defect.\nVERDICT: FINDINGS (1)'
_drive_record_reviewer "s4f_rebind" "standard" "${late_message}" "quality-reviewer"
_drive_subagent_summary "s4f_rebind" "quality-reviewer" "${late_message}"
assert_eq "T4f-rebind: late old completion is explicitly rejected" \
  "abandoned_dispatch_completion" "$(read_state "last_stale_reviewer_reason")"
assert_eq "T4f-rebind: late old findings cannot overwrite bound CLEAN" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"
assert_eq "T4f-rebind: both completion paths clear only their own pending row" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4f-rebind: abandoned late return creates no extra summary" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"

# Explicit recovery is immediate when the user has confirmed interruption; it
# does not require waiting for the automatic freeze TTL. Exercise the opposite
# completion order (old first, then new) and a bound result that omits its ID.
reset_session "s4f_immediate"
with_state_lock_batch "edit_revision" "2" "last_code_edit_revision" "2"
assert_eq "T4f-immediate: original active dispatch is allowed" "" \
  "$(_drive_agent_dispatch "s4f_immediate" "quality-reviewer")"
immediate_retry="$(_drive_agent_dispatch "s4f_immediate" "quality-reviewer" \
  '[review-rebind:immediate-1] confirmed interrupted; emit REVIEW_DISPATCH_ID: immediate-1 immediately before VERDICT')"
assert_eq "T4f-immediate: confirmed killed call can rebind before TTL" "" \
  "${immediate_retry}"
_drive_record_reviewer "s4f_immediate" "standard" \
  $'Old call returned first.\nVERDICT: FINDINGS (1)' "quality-reviewer"
_drive_subagent_summary "s4f_immediate" "quality-reviewer" \
  $'Old call returned first.\nVERDICT: FINDINGS (1)'
assert_eq "T4f-immediate: old-first result is rejected as abandoned" \
  "abandoned_dispatch_completion" "$(read_state "last_stale_reviewer_reason")"
immediate_message=$'Replacement completed.\nREVIEW_DISPATCH_ID: immediate-1\nVERDICT: CLEAN'
_drive_record_reviewer "s4f_immediate" "standard" "${immediate_message}" "quality-reviewer"
_drive_subagent_summary "s4f_immediate" "quality-reviewer" "${immediate_message}"
assert_eq "T4f-immediate: new-after-old bound result is accepted" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"

reset_session "s4f_missing_id"
with_state_lock_batch "edit_revision" "3" "last_code_edit_revision" "3"
_drive_agent_dispatch "s4f_missing_id" "quality-reviewer" >/dev/null
_drive_agent_dispatch "s4f_missing_id" "quality-reviewer" \
  '[review-rebind:missing-id-1] confirmed interrupted; emit REVIEW_DISPATCH_ID: missing-id-1 immediately before VERDICT' \
  >/dev/null
missing_id_message=$'Replacement forgot its dispatch binding.\nVERDICT: CLEAN'
_drive_record_reviewer "s4f_missing_id" "standard" "${missing_id_message}" "quality-reviewer"
_drive_subagent_summary "s4f_missing_id" "quality-reviewer" "${missing_id_message}"
assert_eq "T4f-missing-id: unlabelled completion cannot tick the bound retry" "" \
  "$(read_state "dim_code_quality_ts")"
assert_eq "T4f-missing-id: bound retry remains pending after missing ID" \
  "missing-id-1" \
  "$(jq -s -r 'map(select(.review_dispatch_id == "missing-id-1"))[0].review_dispatch_id // ""' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4f-missing-id: suppressed completion writes no summary" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"

# Versioned reviewer tracking fails closed if its causal start row is lost or
# malformed. The state marker survives the row itself, so queue truncation,
# deactivation/replay, or manual corruption cannot turn a current completion
# into completion-time evidence. Unversioned sessions retain one explicit
# legacy migration path.
reset_session "s4g"
with_state_lock_batch \
  "edit_revision" "3" \
  "last_code_edit_revision" "3" \
  "last_code_edit_ts" "103"
tracked_dispatch="$(_drive_agent_dispatch "s4g" "quality-reviewer")"
assert_eq "T4g: tracked reviewer dispatch is allowed" "" "${tracked_dispatch}"
assert_eq "T4g: dispatch arms reviewer causality version" \
  "1" "$(read_state "review_dispatch_tracking_version")"
rm -f "$(session_file "agent_dispatch_starts.jsonl")"
_drive_record_reviewer "s4g" "standard" $'Lost-start review.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4g: missing tracked start does not tick bug_hunt" \
  "" "$(read_state "dim_bug_hunt_ts")"
assert_eq "T4g: missing tracked start records deterministic reason" \
  "missing_start_snapshot" "$(read_state "last_stale_reviewer_reason")"

reset_session "s4h"
with_state_lock_batch \
  "edit_revision" "4" \
  "last_code_edit_revision" "4" \
  "last_code_edit_ts" "104" \
  "review_dispatch_tracking_version" "1"
printf '%s\n' \
  '{"agent_type":"quality-reviewer","review_dispatch_causality_version":1,"review_revision":"broken"}' \
  >"$(session_file "agent_dispatch_starts.jsonl")"
_drive_record_reviewer "s4h" "standard" $'Malformed-start review.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4h: malformed tracked start does not tick code_quality" \
  "" "$(read_state "dim_code_quality_ts")"
assert_eq "T4h: malformed tracked start records deterministic reason" \
  "invalid_start_snapshot" "$(read_state "last_stale_reviewer_reason")"

reset_session "s4i"
write_state "last_code_edit_ts" "100"
_drive_record_reviewer "s4i" "standard" $'Legacy review.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4i: unversioned legacy session still accepts completion" \
  "CLEAN" "$(read_state "dim_bug_hunt_verdict")"
assert_eq "T4i: legacy migration does not synthesize tracking marker" \
  "" "$(read_state "review_dispatch_tracking_version")"

# Design freshness canonically falls back to the code generation when a
# session has not recorded a UI-specific revision. The start row must capture
# five here, not zero, and the unchanged completion must be accepted.
reset_session "s4j"
with_state_lock_batch \
  "edit_revision" "5" \
  "last_code_edit_revision" "5" \
  "last_code_edit_ts" "105"
design_dispatch="$(_drive_agent_dispatch "s4j" "design-reviewer")"
assert_eq "T4j: design reviewer dispatch is allowed" "" "${design_dispatch}"
design_start_file="$(session_file "agent_dispatch_starts.jsonl")"
assert_eq "T4j: design row snapshots canonical fallback revision" \
  "5" "$(jq -r '.review_revision' "${design_start_file}")"
assert_eq "T4j: design row preserves canonical UI audit field" \
  "5" "$(jq -r '.ui_revision' "${design_start_file}")"
_drive_record_reviewer "s4j" "design_quality" \
  $'Design review completed.\nVERDICT: CLEAN' "design-reviewer"
assert_eq "T4j: unchanged design review ticks code fallback generation" \
  "5" "$(read_state "dim_design_quality_revision")"
assert_eq "T4j: unchanged design review is not rejected stale" \
  "" "$(read_state "last_stale_reviewer_reason")"

# Accepted findings preserve structured remediation anchors for a targeted
# second pass. The history is evidence only: its FINDINGS verdict remains the
# ordinary dimension verdict and cannot satisfy a later clean review.
reset_session "s4k"
with_state_lock_batch \
  "edit_revision" "6" \
  "last_code_edit_revision" "6" \
  "last_code_edit_ts" "106"
findings_dispatch="$(_drive_agent_dispatch "s4k" "quality-reviewer")"
assert_eq "T4k: findings reviewer dispatch is allowed" "" "${findings_dispatch}"
_drive_record_reviewer "s4k" "standard" \
  $'Found an unchecked boundary.\nFINDINGS_JSON: [{"severity":"high","category":"bug","file":"src/x.ts","line":7,"claim":"Missing bounds check","evidence":"Index can exceed the array length.","recommended_fix":"Guard index at src/x.ts:7."}]\nVERDICT: FINDINGS (1)' \
  "quality-reviewer"
history_file="$(session_file "review_history.jsonl")"
assert_eq "T4k: findings history records one structured anchor" \
  "1" "$(tail -n 1 "${history_file}" | jq '.findings | length')"
assert_eq "T4k: remediation anchor preserves claim" \
  "Missing bounds check" "$(tail -n 1 "${history_file}" | jq -r '.findings[0].claim')"
assert_eq "T4k: history verdict remains findings" \
  "FINDINGS" "$(tail -n 1 "${history_file}" | jq -r '.verdict')"
assert_eq "T4k: remediation anchor records objective-cycle identity" \
  "0" "$(tail -n 1 "${history_file}" | jq -r '.objective_prompt_ts')"

# Reviewer evidence is objective-causal even when no edit occurred. A fresh
# objective invalidates the old return; a true continuation advances the raw
# prompt revision while retaining review_cycle_prompt_ts and remains valid.
reset_session "s4l_objective_changed"
with_state_lock_batch \
  "edit_revision" "7" \
  "last_code_edit_revision" "7" \
  "review_cycle_prompt_ts" "700" \
  "last_user_prompt_ts" "700" \
  "prompt_revision" "10"
assert_eq "T4l: objective-A reviewer dispatch is allowed" "" \
  "$(_drive_agent_dispatch "s4l_objective_changed" "quality-reviewer")"
with_state_lock_batch \
  "review_cycle_prompt_ts" "701" \
  "last_user_prompt_ts" "701" \
  "prompt_revision" "11"
_drive_record_reviewer "s4l_objective_changed" "standard" \
  $'Late objective-A review.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4l: no-edit fresh objective rejects prior reviewer evidence" \
  "review_objective_changed" "$(read_state "last_stale_reviewer_reason")"
assert_eq "T4l: rejected prior-objective review ticks no dimension" "" \
  "$(read_state "dim_code_quality_ts")"
assert_eq "T4l: rejected prior-objective review writes no history" "0" \
  "$(if [[ -f "$(session_file "review_history.jsonl")" ]]; then jq -s 'length' "$(session_file "review_history.jsonl")"; else printf 0; fi)"

reset_session "s4m_continuation"
with_state_lock_batch \
  "edit_revision" "8" \
  "last_code_edit_revision" "8" \
  "review_cycle_prompt_ts" "800" \
  "last_user_prompt_ts" "800" \
  "prompt_revision" "20"
assert_eq "T4m: continuation reviewer dispatch is allowed" "" \
  "$(_drive_agent_dispatch "s4m_continuation" "quality-reviewer")"
with_state_lock_batch \
  "last_user_prompt_ts" "801" \
  "prompt_revision" "21"
_drive_record_reviewer "s4m_continuation" "standard" \
  $'Same-objective continuation review.\nVERDICT: CLEAN' "quality-reviewer"
continuation_history="$(session_file "review_history.jsonl")"
assert_eq "T4m: raw continuation revision does not stale reviewer evidence" \
  "CLEAN" "$(read_state "dim_code_quality_verdict")"
assert_eq "T4m: history uses consumed start objective timestamp" "800" \
  "$(tail -n 1 "${continuation_history}" | jq -r '.objective_prompt_ts')"
assert_eq "T4m: history retains consumed start prompt revision" "20" \
  "$(tail -n 1 "${continuation_history}" | jq -r '.objective_prompt_revision')"

reset_session "s4n_summary_objective"
with_state_lock_batch \
  "task_intent" "execution" \
  "review_cycle_prompt_ts" "900" \
  "last_user_prompt_ts" "900" \
  "prompt_revision" "30"
assert_eq "T4n: ordinary specialist dispatch on objective A is allowed" "" \
  "$(_drive_agent_dispatch "s4n_summary_objective" "frontend-developer" "implement objective A")"
with_state_lock_batch \
  "review_cycle_prompt_ts" "901" \
  "last_user_prompt_ts" "901" \
  "prompt_revision" "31"
_drive_subagent_summary "s4n_summary_objective" "frontend-developer" \
  $'Late objective-A implementation.\nVERDICT: SHIP'
assert_eq "T4n: prior-objective ordinary return writes no summary" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"
assert_eq "T4n: prior-objective ordinary return cannot satisfy agent-first" "" \
  "$(read_state "agent_first_specialist_ts")"
assert_eq "T4n: prior-objective ordinary row is cleanup-only" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

# Both SubagentStop hook orders converge on one consumed reviewer/pending pair.
reset_session "s4o_summary_first"
with_state_lock_batch \
  "edit_revision" "9" \
  "last_code_edit_revision" "9" \
  "review_cycle_prompt_ts" "1000" \
  "last_user_prompt_ts" "1000" \
  "prompt_revision" "40"
_drive_agent_dispatch "s4o_summary_first" "quality-reviewer" >/dev/null
_drive_subagent_summary "s4o_summary_first" "quality-reviewer" \
  $'Summary hook first.\nVERDICT: CLEAN'
assert_eq "T4o: summary-first leaves one effects-complete claim for reviewer" \
  "true" "$(jq -r '.completion_claim_effects_complete // false' "$(session_file "pending_agents.jsonl")")"
_drive_record_reviewer "s4o_summary_first" "standard" \
  $'Summary hook first.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4o: reviewer-second consumes effects-complete pending claim" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4o: summary-first order still records reviewer verdict" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"

reset_session "s4p_reviewer_first"
with_state_lock_batch \
  "edit_revision" "10" \
  "last_code_edit_revision" "10" \
  "review_cycle_prompt_ts" "1100" \
  "last_user_prompt_ts" "1100" \
  "prompt_revision" "41"
_drive_agent_dispatch "s4p_reviewer_first" "quality-reviewer" >/dev/null
_drive_record_reviewer "s4p_reviewer_first" "standard" \
  $'Reviewer hook first.\nVERDICT: CLEAN' "quality-reviewer"
_drive_subagent_summary "s4p_reviewer_first" "quality-reviewer" \
  $'Reviewer hook first.\nVERDICT: CLEAN'
assert_eq "T4p: summary-second consumes pending after reviewer start" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4p: reviewer-first order records exactly one summary" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"

# The session-level marker survives bounded pending-row loss. An evicted or
# /ulw-off-deleted tracked completion cannot become trusted legacy output.
reset_session "s4q_evicted_pending"
with_state_lock_batch \
  "task_intent" "execution" \
  "review_cycle_prompt_ts" "1200" \
  "last_user_prompt_ts" "1200" \
  "prompt_revision" "50"
_drive_agent_dispatch "s4q_evicted_pending" "frontend-developer" \
  "tracked target that will be evicted" >/dev/null
assert_eq "T4q: ordinary dispatch arms durable tracking marker" "1" \
  "$(read_state "subagent_dispatch_tracking_version")"
for eviction_i in $(seq 1 32); do
  append_limited_state "pending_agents.jsonl" \
    "$(jq -nc --arg i "${eviction_i}" \
      '{ts:1,agent_type:("eviction-fill-"+$i),objective_prompt_ts:1200}')" "32"
done
assert_eq "T4q: bounded ledger evicts original exact identity" "0" \
  "$(jq -s '[.[] | select(.agent_type == "frontend-developer")] | length' "$(session_file "pending_agents.jsonl")")"
_drive_subagent_summary "s4q_evicted_pending" "frontend-developer" \
  $'Late evicted tracked result.\nVERDICT: SHIP'
assert_eq "T4q: evicted tracked return writes no authoritative summary" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"
assert_eq "T4q: evicted tracked return records ignored causal outcome" \
  "missing-pending-dispatch" \
  "$(tail -n 1 "$(session_file "agent_completion_outcomes.jsonl")" | jq -r '.reason')"

# A crashed ordinary summary claim is recoverable after the bounded lease only
# through an explicit ID. This avoids appending a same-agent unbound result
# behind the stale FIFO claim and suppressing the replacement repeatedly.
reset_session "s4r_ordinary_stale_claim"
with_state_lock_batch \
  "review_cycle_prompt_ts" "1300" \
  "last_user_prompt_ts" "1300" \
  "prompt_revision" "60"
_drive_agent_dispatch "s4r_ordinary_stale_claim" "frontend-developer" \
  "ordinary claim crash" >/dev/null
ordinary_pending="$(session_file "pending_agents.jsonl")"
ordinary_expired="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${ordinary_expired}" '
  . + {completion_claim_id:"crashed-ordinary",completion_claim_ts:$expired,
       completion_claim_effects_complete:false}
' "${ordinary_pending}" >"${ordinary_pending}.tmp"
mv "${ordinary_pending}.tmp" "${ordinary_pending}"
ordinary_unbound="$(_drive_agent_dispatch "s4r_ordinary_stale_claim" \
  "frontend-developer" "retry crashed ordinary claim")"
assert_contains "T4r: stale ordinary claim requires explicit recovery ID" \
  '[review-rebind:' "${ordinary_unbound}"
ordinary_bound="$(_drive_agent_dispatch "s4r_ordinary_stale_claim" \
  "frontend-developer" \
  '[review-rebind:ordinary-recovery] recover claim; emit REVIEW_DISPATCH_ID: ordinary-recovery immediately before VERDICT')"
assert_eq "T4r: ID-bound ordinary stale-claim recovery is allowed" "" \
  "${ordinary_bound}"
assert_eq "T4r: expired ordinary claim becomes suppression tombstone" "true" \
  "$(head -n 1 "${ordinary_pending}" | jq -r '.review_dispatch_abandoned')"
_drive_subagent_summary "s4r_ordinary_stale_claim" "frontend-developer" \
  $'Recovered result.\nREVIEW_DISPATCH_ID: ordinary-recovery\nVERDICT: SHIP'
assert_eq "T4r: recovered ordinary completion is authoritative once" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"
_drive_subagent_summary "s4r_ordinary_stale_claim" "frontend-developer" \
  $'Late crashed result.\nVERDICT: SHIP'
assert_eq "T4r: late crashed ordinary completion adds no summary" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"

# Claude Code 2.0.43+ exposes a platform-issued agent_id across
# SubagentStart and SubagentStop. The start hook binds that identifier to both
# causal ledgers, and every completion hook prefers it over model-authored text.
printf '\nNative SubagentStart/SubagentStop identity causality\n'

reset_session "s4s_native_summary_first"
with_state_lock_batch \
  "edit_revision" "11" "last_code_edit_revision" "11" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1400" \
  "last_user_prompt_ts" "1400" "prompt_revision" "70"
assert_eq "T4s: native reviewer dispatch is allowed" "" \
  "$(_drive_agent_dispatch "s4s_native_summary_first" "quality-reviewer")"
_drive_agent_start "s4s_native_summary_first" "quality-reviewer" "native-review-a"
assert_eq "T4s: SubagentStart binds pending native ID" "native-review-a" \
  "$(jq -r '.native_agent_id // empty' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4s: SubagentStart binds reviewer-start native ID" "native-review-a" \
  "$(jq -r '.native_agent_id // empty' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4s: native binding commit marker is singular" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "native-review-a")] | length' \
    "$(session_file "native_agent_bindings.jsonl")")"
_drive_subagent_summary "s4s_native_summary_first" "quality-reviewer" \
  $'Native summary first.\nVERDICT: CLEAN' "native-review-a"
assert_eq "T4s: summary-first native claim waits for reviewer hook" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "$(session_file "pending_agents.jsonl")")"
accepted_reviewer_parent_out="$(_drive_reflect_after_agent \
  "s4s_native_summary_first" "quality-reviewer" false \
  "completed" "native-review-a")"
assert_contains "T4s: accepted reviewer outcome reaches parent" \
  "verdict=CLEAN" "${accepted_reviewer_parent_out}"
assert_eq "T4s: accepted outcome consumption preserves pending claim" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4s: accepted outcome consumption preserves reviewer start" "1" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
_drive_record_reviewer "s4s_native_summary_first" "standard" \
  $'Native summary first.\nVERDICT: CLEAN' "quality-reviewer" "native-review-a"
assert_eq "T4s: reviewer consumes the same native start" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"
assert_eq "T4s: summary-first native pair fully settles" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

reset_session "s4t_native_reviewer_first"
with_state_lock_batch \
  "edit_revision" "12" "last_code_edit_revision" "12" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1500" \
  "last_user_prompt_ts" "1500" "prompt_revision" "71"
_drive_agent_dispatch "s4t_native_reviewer_first" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_native_reviewer_first" "quality-reviewer" "native-review-b"
_drive_record_reviewer "s4t_native_reviewer_first" "standard" \
  $'Native reviewer first.\nVERDICT: CLEAN' "quality-reviewer" "native-review-b"
_drive_subagent_summary "s4t_native_reviewer_first" "quality-reviewer" \
  $'Native reviewer first.\nVERDICT: CLEAN' "native-review-b"
assert_eq "T4t: reviewer-first native pair records one summary" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"
assert_eq "T4t: reviewer-first native pair fully settles" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

# A terminal-looking native callback that ends at an intermediate checkpoint
# is not a reviewer completion. Before this regression fix the dedicated hook
# consumed agent_dispatch_starts, stamped last_review_ts, and the universal
# hook accepted an UNREPORTED summary—leaving no notification or resume handle.
reset_session "s4t_partial_summary_first"
with_state_lock_batch \
  "edit_revision" "13" "last_code_edit_revision" "13" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1550" \
  "last_user_prompt_ts" "1550" "prompt_revision" "72"
_drive_agent_dispatch "s4t_partial_summary_first" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_partial_summary_first" "quality-reviewer" "native-partial-a"
partial_out="$(_drive_subagent_summary_out "s4t_partial_summary_first" \
  "quality-reviewer" 'Tests pass. Let me typecheck…' "native-partial-a")"
_drive_record_reviewer "s4t_partial_summary_first" "standard" \
  'Tests pass. Let me typecheck…' "quality-reviewer" "native-partial-a"
assert_contains "T4t-partial: universal hook continues the same subagent" \
  '"hookEventName":"SubagentStop"' "${partial_out}"
assert_contains "T4t-partial: continuation names intermediate checkpoint" \
  "intermediate checkpoint" "${partial_out}"
assert_not_contains "T4t-partial: ordinary reviewer is not assigned a JSON envelope" \
  "structural JSON" "${partial_out}"
assert_eq "T4t-partial: pending native row is retained" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "native-partial-a")] | length' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-partial: reviewer start is retained" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "native-partial-a")] | length' \
    "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-partial: no completion claim is created" "" \
  "$(jq -r '.completion_claim_id // empty' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-partial: no review clock is stamped" "" \
  "$(read_state "last_review_ts")"
assert_eq "T4t-partial: no dimension is ticked" "" \
  "$(read_state "dim_code_quality_verdict")"
assert_eq "T4t-partial: no summary is accepted" "0" \
  "$(_jsonl_count "$(session_file "subagent_summaries.jsonl")")"
assert_eq "T4t-partial: no completion outcome is recorded" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"

# Empty and malformed/non-final retries remain idempotent; neither hook order
# can consume the causal rows before the exact same native call returns valid.
empty_retry_out="$(_drive_subagent_summary_out "s4t_partial_summary_first" \
  "quality-reviewer" '' "native-partial-a")"
assert_contains "T4t-partial: empty callback also continues" \
  '"hookEventName":"SubagentStop"' "${empty_retry_out}"
assert_eq "T4t-partial: repeated retry stays one pending row" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

_drive_record_reviewer "s4t_partial_summary_first" "standard" \
  $'Typecheck passes; complete review follows.\nVERDICT: CLEAN' \
  "quality-reviewer" "native-partial-a"
_drive_subagent_summary "s4t_partial_summary_first" "quality-reviewer" \
  $'Typecheck passes; complete review follows.\nVERDICT: CLEAN' "native-partial-a"
assert_eq "T4t-partial: resumed same native call records CLEAN" "CLEAN" \
  "$(read_state "dim_code_quality_verdict")"
assert_eq "T4t-partial: resumed call fully settles pending" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-partial: resumed call fully settles start" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-partial: resumed call records exactly one summary" "1" \
  "$(_jsonl_count "$(session_file "subagent_summaries.jsonl")")"
assert_eq "T4t-partial: resumed call records exactly one accepted outcome" "1" \
  "$(jq -s '[.[] | select(.status == "accepted")] | length' \
    "$(session_file "agent_completion_outcomes.jsonl")")"

reset_session "s4t_partial_reviewer_first"
with_state_lock_batch \
  "edit_revision" "14" "last_code_edit_revision" "14" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1575" \
  "last_user_prompt_ts" "1575" "prompt_revision" "73"
_drive_agent_dispatch "s4t_partial_reviewer_first" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_partial_reviewer_first" "quality-reviewer" "native-partial-b"
_drive_record_reviewer "s4t_partial_reviewer_first" "standard" \
  $'VERDICT: CLEAN\nTests pass. Let me typecheck…' \
  "quality-reviewer" "native-partial-b"
partial_out="$(_drive_subagent_summary_out "s4t_partial_reviewer_first" \
  "quality-reviewer" $'VERDICT: CLEAN\nTests pass. Let me typecheck…' \
  "native-partial-b")"
assert_contains "T4t-partial-order: non-final verdict continues" \
  "intermediate checkpoint" "${partial_out}"
assert_eq "T4t-partial-order: opposite hook order retains both rows" "2" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"

reset_session "s4t_partial_stale"
with_state_lock_batch \
  "edit_revision" "15" "last_code_edit_revision" "15" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1580" \
  "last_user_prompt_ts" "1580" "prompt_revision" "74"
_drive_agent_dispatch "s4t_partial_stale" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_partial_stale" "quality-reviewer" "native-partial-stale"
write_state "last_code_edit_revision" "16"
_drive_record_reviewer "s4t_partial_stale" "standard" \
  'Tests pass. Let me typecheck…' "quality-reviewer" "native-partial-stale"
stale_partial_out="$(_drive_subagent_summary_out "s4t_partial_stale" \
  "quality-reviewer" 'Tests pass. Let me typecheck…' "native-partial-stale")"
assert_eq "T4t-partial-stale: stale partial is not revived" "" \
  "${stale_partial_out}"
assert_eq "T4t-partial-stale: stale pending row is cleaned" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-partial-stale: stale reviewer start is cleaned" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-partial-stale: fresh same-role review is admitted" "" \
  "$(_drive_agent_dispatch "s4t_partial_stale" "quality-reviewer")"

# Repeated malformed returns are bounded before Claude Code's own continuation
# ceiling. The third return reaches the parent with a one-shot ignored outcome,
# and PostToolUse immediately tells the parent to resume/rebind instead of wait.
reset_session "s4t_partial_retry_cap"
with_state_lock_batch \
  "edit_revision" "17" "last_code_edit_revision" "17" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1585" \
  "last_user_prompt_ts" "1585" "prompt_revision" "75"
_drive_agent_dispatch "s4t_partial_retry_cap" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_partial_retry_cap" "quality-reviewer" "native-partial-cap"
cap_out_1="$(_drive_subagent_summary_out "s4t_partial_retry_cap" \
  "quality-reviewer" 'VERDICT: PLAN_READY' "native-partial-cap" false)"
cap_out_2="$(_drive_subagent_summary_out "s4t_partial_retry_cap" \
  "quality-reviewer" 'Still checking…' "native-partial-cap" true)"
cap_out_3="$(_drive_subagent_summary_out "s4t_partial_retry_cap" \
  "quality-reviewer" 'Still checking again…' "native-partial-cap" true)"
assert_contains "T4t-retry-cap: wrong-role verdict is continued" \
  '"hookEventName":"SubagentStop"' "${cap_out_1}"
assert_contains "T4t-retry-cap: active retry is continued below cap" \
  '"hookEventName":"SubagentStop"' "${cap_out_2}"
assert_eq "T4t-retry-cap: third malformed return reaches parent" "" \
  "${cap_out_3}"
assert_eq "T4t-retry-cap: exhausted return is ignored, not accepted" \
  "terminal-contract-retry-exhausted" \
  "$(jq -r 'select(.status == "ignored") | .reason' \
    "$(session_file "agent_completion_outcomes.jsonl")")"
cap_parent_out="$(_drive_reflect_after_agent \
  "s4t_partial_retry_cap" "quality-reviewer")"
assert_contains "T4t-retry-cap: parent receives explicit recovery" \
  "TERMINAL CONTRACT RECOVERY" "${cap_parent_out}"
assert_contains "T4t-retry-cap: parent recovery names retired native ID" \
  "native-partial-cap" "${cap_parent_out}"
assert_contains "T4t-retry-cap: parent is told not to wait" \
  "Do not wait" "${cap_parent_out}"
assert_contains "T4t-retry-cap: parent is told not to resume exhausted call" \
  "Do not wait for another notification or resume that call" "${cap_parent_out}"
assert_eq "T4t-retry-cap: exhausted pending row is retired" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-retry-cap: exhausted start row is retired" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-retry-cap: fresh same-role dispatch is admitted" "" \
  "$(_drive_agent_dispatch "s4t_partial_retry_cap" "quality-reviewer")"

# Outcome publication is the cleanup transaction's durable commit point. A
# pre-commit build failure retains both rows and publishes nothing. Any failure
# after the outcome rename leaves that versioned fingerprint journal in place;
# a consumer rolls the exact start/pending pair forward before recovery prose.
reset_session "s4t_retry_transaction_stage_fail"
with_state_lock_batch \
  "edit_revision" "18" "last_code_edit_revision" "18" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1586" \
  "last_user_prompt_ts" "1586" "prompt_revision" "76"
_drive_agent_dispatch "s4t_retry_transaction_stage_fail" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4t_retry_transaction_stage_fail" \
  "quality-reviewer" "native-stage-fail"
_drive_subagent_summary_out "s4t_retry_transaction_stage_fail" \
  "quality-reviewer" 'Still checking one…' "native-stage-fail" false \
  >/dev/null
_drive_subagent_summary_out "s4t_retry_transaction_stage_fail" \
  "quality-reviewer" 'Still checking two…' "native-stage-fail" true \
  >/dev/null
_drive_subagent_summary_out "s4t_retry_transaction_stage_fail" \
  "quality-reviewer" 'Still checking three…' "native-stage-fail" true 1 \
  >/dev/null
assert_eq "T4t-retry-transaction: stage failure retains pending row" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-retry-transaction: stage failure restores start row" "1" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-retry-transaction: post-commit failure retains journal" "1" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-retry-transaction: journal is versioned" "2" \
  "$(jq -r '.cleanup_journal_version // 0' \
    "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-retry-transaction: journal freezes both causal rows" "2" \
  "$(jq -r '[.cleanup_pending_fingerprint,.cleanup_start_fingerprint]
      | map(select(type == "string" and length > 0)) | length' \
    "$(session_file "agent_completion_outcomes.jsonl")")"
stage_fail_parent_out="$(_drive_reflect_after_agent \
  "s4t_retry_transaction_stage_fail" "quality-reviewer" false \
  "completed" "native-stage-fail")"
assert_contains "T4t-retry-transaction: consumer emits recovery after convergence" \
  "TERMINAL CONTRACT RECOVERY" "${stage_fail_parent_out}"
assert_eq "T4t-retry-transaction: consumer removes exact pending row" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-retry-transaction: consumer removes exact start row" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-retry-transaction: journal is consumed once" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-retry-transaction: converged replacement is admitted" "" \
  "$(_drive_agent_dispatch "s4t_retry_transaction_stage_fail" \
    "quality-reviewer")"

reset_session "s4t_retry_transaction_build_fail"
with_state_lock_batch \
  "edit_revision" "19" "last_code_edit_revision" "19" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1587" \
  "last_user_prompt_ts" "1587" "prompt_revision" "77"
_drive_agent_dispatch "s4t_retry_transaction_build_fail" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4t_retry_transaction_build_fail" \
  "quality-reviewer" "native-build-fail"
_drive_subagent_summary_out "s4t_retry_transaction_build_fail" \
  "quality-reviewer" 'Still checking one…' "native-build-fail" false \
  >/dev/null
_drive_subagent_summary_out "s4t_retry_transaction_build_fail" \
  "quality-reviewer" 'Still checking two…' "native-build-fail" true \
  >/dev/null
_drive_subagent_summary_out "s4t_retry_transaction_build_fail" \
  "quality-reviewer" 'Still checking three…' "native-build-fail" true 0 1 \
  >/dev/null
assert_eq "T4t-retry-transaction: build failure retains pending row" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-retry-transaction: build failure retains start row" "1" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-retry-transaction: build failure publishes no outcome" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"

_prepare_cleanup_crash_window() {
  local sid="$1" native_id="$2" edit_revision="$3" objective_ts="$4"
  reset_session "${sid}"
  with_state_lock_batch \
    "edit_revision" "${edit_revision}" \
    "last_code_edit_revision" "${edit_revision}" \
    "review_cycle_id" "1" "review_cycle_prompt_ts" "${objective_ts}" \
    "last_user_prompt_ts" "${objective_ts}" "prompt_revision" "78"
  _drive_agent_dispatch "${sid}" "quality-reviewer" >/dev/null
  _drive_agent_start "${sid}" "quality-reviewer" "${native_id}"
  _drive_subagent_summary_out "${sid}" "quality-reviewer" \
    'Still checking one…' "${native_id}" false >/dev/null
  _drive_subagent_summary_out "${sid}" "quality-reviewer" \
    'Still checking two…' "${native_id}" true >/dev/null
}

_assert_cleanup_crash_converges() {
  local sid="$1" native_id="$2" label="$3" parent_out
  assert_eq "${label}: durable journal survives kill" "1" \
    "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
  parent_out="$(_drive_reflect_after_agent "${sid}" "quality-reviewer" \
    false "completed" "${native_id}")"
  assert_contains "${label}: foreground consumer recovers explicitly" \
    "TERMINAL CONTRACT RECOVERY" "${parent_out}"
  assert_eq "${label}: exact pending row converges" "0" \
    "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
  assert_eq "${label}: exact start row converges" "0" \
    "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
  assert_eq "${label}: journal consumes once" "0" \
    "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
  assert_eq "${label}: fresh reviewer is admitted" "" \
    "$(_drive_agent_dispatch "${sid}" "quality-reviewer")"
}

# Real process death at each post-commit rename boundary must converge to the
# same state. The journal is never rolled back after it becomes visible.
_prepare_cleanup_crash_window \
  "s4t_kill_after_outcome" "native-kill-outcome" "20" "1588"
_drive_subagent_summary_out "s4t_kill_after_outcome" "quality-reviewer" \
  'Still checking three…' "native-kill-outcome" true 0 0 1 0 0 \
  >/dev/null 2>&1
assert_eq "T4t-kill-outcome: both rows precede roll-forward" "2" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
_assert_cleanup_crash_converges "s4t_kill_after_outcome" \
  "native-kill-outcome" "T4t-kill-outcome"

_prepare_cleanup_crash_window \
  "s4t_kill_after_start" "native-kill-start" "21" "1589"
_drive_subagent_summary_out "s4t_kill_after_start" "quality-reviewer" \
  'Still checking three…' "native-kill-start" true 0 0 0 1 0 \
  >/dev/null 2>&1
assert_eq "T4t-kill-start: only pending remains before roll-forward" "1" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
_assert_cleanup_crash_converges "s4t_kill_after_start" \
  "native-kill-start" "T4t-kill-start"

_prepare_cleanup_crash_window \
  "s4t_kill_after_pending" "native-kill-pending" "22" "1590"
_drive_subagent_summary_out "s4t_kill_after_pending" "quality-reviewer" \
  'Still checking three…' "native-kill-pending" true 0 0 0 0 1 \
  >/dev/null 2>&1
assert_eq "T4t-kill-pending: both rows already retired" "0" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
_assert_cleanup_crash_converges "s4t_kill_after_pending" \
  "native-kill-pending" "T4t-kill-pending"

# Two start rows can be field-identical except for the harness lifecycle ID.
# Cleanup must fingerprint/remove only the start paired to the selected pending
# row and preserve the unrelated lifecycle, even though every legacy frozen
# coordinate collides.
_prepare_cleanup_crash_window \
  "s4t_start_lifecycle_collision" "native-start-target" "23" "1591"
collision_starts="$(session_file "agent_dispatch_starts.jsonl")"
unrelated_collision_start="$(jq -c \
  '.lifecycle_dispatch_id = "dispatch-unrelated-start"' \
  "${collision_starts}")"
printf '%s\n' "${unrelated_collision_start}" >>"${collision_starts}"
_drive_subagent_summary_out "s4t_start_lifecycle_collision" \
  "quality-reviewer" 'Still checking three…' "native-start-target" true \
  >/dev/null
assert_eq "T4t-start-lifecycle: target pending retires" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-start-lifecycle: cleanup journal publishes" "1" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-start-lifecycle: unrelated start is preserved" \
  "dispatch-unrelated-start" \
  "$(jq -s -r 'map(.lifecycle_dispatch_id) | join(",")' \
    "${collision_starts}")"
_drive_reflect_after_agent "s4t_start_lifecycle_collision" \
  "quality-reviewer" false "completed" "native-start-target" >/dev/null
assert_eq "T4t-start-lifecycle: outcome consumer preserves unrelated start" \
  "dispatch-unrelated-start" \
  "$(jq -s -r 'map(.lifecycle_dispatch_id) | join(",")' \
    "${collision_starts}")"

# A ledger mutator may legitimately add abandonment metadata after journal
# commit. Raw bytes then differ, but the immutable harness lifecycle ID must
# still identify and retire exactly that old pair.
_prepare_cleanup_crash_window \
  "s4t_mutated_after_journal" "native-mutated-journal" "23" "1591"
_drive_subagent_summary_out "s4t_mutated_after_journal" \
  "quality-reviewer" 'Still checking three…' "native-mutated-journal" \
  true 0 0 1 0 0 >/dev/null 2>&1
for mutated_ledger in pending_agents.jsonl agent_dispatch_starts.jsonl; do
  jq -c '. + {review_dispatch_abandoned:true,
               review_dispatch_abandonment_reason:"concurrent-rewrite",
               review_dispatch_abandoned_ts:999}' \
    "$(session_file "${mutated_ledger}")" \
    >"$(session_file "${mutated_ledger}").mutated"
  mv "$(session_file "${mutated_ledger}").mutated" \
    "$(session_file "${mutated_ledger}")"
done
mutated_journal_out="$(_drive_reflect_after_agent \
  "s4t_mutated_after_journal" "quality-reviewer" false \
  "completed" "native-mutated-journal")"
assert_contains "T4t-mutated-journal: immutable ID recovers rewritten row" \
  "TERMINAL CONTRACT RECOVERY" "${mutated_journal_out}"
assert_eq "T4t-mutated-journal: rewritten pair converges" "0" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
assert_eq "T4t-mutated-journal: journal consumes once" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"

# Admission can race ahead of the old parent wake after a crash. It must roll
# the journal forward before duplicate checks, admit exactly one replacement,
# leave the journal for its one-shot consumer, and preserve that replacement
# when the old recovery capsule is finally rendered.
_prepare_cleanup_crash_window \
  "s4t_admission_first_recovery" "native-admission-old" "23" "1591"
_drive_subagent_summary_out "s4t_admission_first_recovery" \
  "quality-reviewer" 'Still checking three…' "native-admission-old" \
  true 0 0 1 0 0 >/dev/null 2>&1
admission_first_out="$(_drive_agent_dispatch \
  "s4t_admission_first_recovery" "quality-reviewer" \
  "replacement admitted before old wake")"
assert_eq "T4t-admission-first: replacement is admitted after convergence" \
  "" "${admission_first_out}"
assert_eq "T4t-admission-first: only replacement pending row remains" \
  "replacement admitted before old wake" \
  "$(jq -s -r 'map(.description) | join(",")' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-admission-first: only replacement start row remains" \
  "replacement admitted before old wake" \
  "$(jq -s -r 'map(.description) | join(",")' \
    "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-admission-first: old journal remains one-shot" "1" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
admission_first_parent_out="$(_drive_reflect_after_agent \
  "s4t_admission_first_recovery" "quality-reviewer" false \
  "completed" "native-admission-old")"
assert_contains "T4t-admission-first: old wake warns against duplication" \
  "replacement is already tracked" "${admission_first_parent_out}"
assert_eq "T4t-admission-first: old wake preserves replacement pending" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-admission-first: old wake preserves replacement start" "1" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
assert_eq "T4t-admission-first: old journal then consumes" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"

# An ambiguous exact target is a fail-closed state, not permission to resume
# the retired transcript or discard its journal. Once the artifact is repaired,
# the next callback converges and consumes the same one-shot outcome.
_prepare_cleanup_crash_window \
  "s4t_reconcile_failure" "native-reconcile-failure" "24" "1592"
_drive_subagent_summary_out "s4t_reconcile_failure" "quality-reviewer" \
  'Still checking three…' "native-reconcile-failure" true 0 0 1 0 0 \
  >/dev/null 2>&1
reconcile_pending="$(session_file "pending_agents.jsonl")"
head -n 1 "${reconcile_pending}" >>"${reconcile_pending}"
reconcile_outcomes="$(session_file "agent_completion_outcomes.jsonl")"
jq -c '.ts = 1' "${reconcile_outcomes}" \
  >"${reconcile_outcomes}.aged"
mv "${reconcile_outcomes}.aged" "${reconcile_outcomes}"
reconcile_failure_out="$(_drive_reflect_after_agent \
  "s4t_reconcile_failure" "quality-reviewer" false \
  "completed" "native-reconcile-failure")"
assert_contains "T4t-reconcile-failure: degraded recovery is explicit" \
  "LIFECYCLE RECOVERY DEGRADED" "${reconcile_failure_out}"
assert_not_contains "T4t-reconcile-failure: retired call is never resumed" \
  "Resume that exact call" "${reconcile_failure_out}"
assert_not_contains "T4t-reconcile-failure: duplicate target gets no replacement" \
  "Dispatch a fresh equivalent now" "${reconcile_failure_out}"
assert_eq "T4t-reconcile-failure: journal remains unconsumed" "1" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-reconcile-failure: ambiguous pending rows remain" "2" \
  "$(jq -s 'length' "${reconcile_pending}")"
_drive_subagent_summary_out "s4t_reconcile_failure" "quality-reviewer" \
  'Replayed while cleanup is unresolved.' "native-reconcile-failure" true \
  >/dev/null
assert_eq "T4t-reconcile-failure: replay appends no generic outcome" "1" \
  "$(_jsonl_count "${reconcile_outcomes}")"
assert_eq "T4t-reconcile-failure: aged unresolved WAL is retained" \
  "terminal-contract-retry-exhausted" \
  "$(jq -r '.reason' "${reconcile_outcomes}")"
head -n 1 "${reconcile_pending}" >"${reconcile_pending}.repair"
mv "${reconcile_pending}.repair" "${reconcile_pending}"
reconcile_repaired_out="$(_drive_reflect_after_agent \
  "s4t_reconcile_failure" "quality-reviewer" false \
  "completed" "native-reconcile-failure")"
assert_contains "T4t-reconcile-failure: repaired target recovers" \
  "TERMINAL CONTRACT RECOVERY" "${reconcile_repaired_out}"
assert_eq "T4t-reconcile-failure: repaired pending/start converge" "0" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
assert_eq "T4t-reconcile-failure: repaired journal consumes once" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"

# A pre-native legacy call has neither causal ID. Dual exact fingerprints still
# let the outcome journal recover it without broad same-role deletion.
reset_session "s4t_kill_legacy_no_id"
with_state_lock_batch \
  "edit_revision" "23" "last_code_edit_revision" "23" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1591" \
  "last_user_prompt_ts" "1591" "prompt_revision" "79"
_drive_agent_dispatch "s4t_kill_legacy_no_id" "quality-reviewer" >/dev/null
_drive_subagent_summary_out "s4t_kill_legacy_no_id" "quality-reviewer" \
  'Still checking one…' "" false >/dev/null
_drive_subagent_summary_out "s4t_kill_legacy_no_id" "quality-reviewer" \
  'Still checking two…' "" true >/dev/null
_drive_subagent_summary_out "s4t_kill_legacy_no_id" "quality-reviewer" \
  'Still checking three…' "" true 0 0 1 0 0 >/dev/null 2>&1
legacy_kill_parent_out="$(_drive_reflect_after_agent \
  "s4t_kill_legacy_no_id" "quality-reviewer")"
assert_contains "T4t-kill-legacy: exact no-ID journal recovers" \
  "TERMINAL CONTRACT RECOVERY" "${legacy_kill_parent_out}"
assert_eq "T4t-kill-legacy: pending and start both converge" "0" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
assert_eq "T4t-kill-legacy: fresh same-role dispatch is admitted" "" \
  "$(_drive_agent_dispatch "s4t_kill_legacy_no_id" "quality-reviewer")"

# Multiple pre-native no-ID outcomes are intentionally unattributable to one
# PostTool callback. Retiring that ambiguous outcome set must first reconcile
# each exact fingerprinted pair and preserve an unrelated current no-ID row.
reset_session "s4t_ambiguous_legacy_journals"
with_state_lock_batch \
  "edit_revision" "24" "last_code_edit_revision" "24" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1592" \
  "last_user_prompt_ts" "1592" "prompt_revision" "80"
legacy_row_a="$(jq -nc '{ts:101,agent_type:"quality-reviewer",
  description:"retired legacy A",lifecycle_dispatch_id:"dispatch-legacy-a",
  edit_revision:24,code_revision:24,
  doc_revision:0,bash_revision:0,ui_revision:0,plan_revision:0,
  review_revision:24,objective_prompt_ts:1592,
  objective_prompt_revision:80,objective_cycle_id:1,
  ulw_enforcement_generation:"migration"}')"
legacy_row_b="$(jq -nc '{ts:102,agent_type:"quality-reviewer",
  description:"retired legacy B",lifecycle_dispatch_id:"dispatch-legacy-b",
  edit_revision:24,code_revision:24,
  doc_revision:0,bash_revision:0,ui_revision:0,plan_revision:0,
  review_revision:24,objective_prompt_ts:1592,
  objective_prompt_revision:80,objective_cycle_id:1,
  ulw_enforcement_generation:"migration"}')"
legacy_row_current="$(jq -nc '{ts:103,agent_type:"quality-reviewer",
  description:"current legacy C",lifecycle_dispatch_id:"dispatch-legacy-c",
  edit_revision:24,code_revision:24,
  doc_revision:0,bash_revision:0,ui_revision:0,plan_revision:0,
  review_revision:24,objective_prompt_ts:1592,
  objective_prompt_revision:80,objective_cycle_id:1,
  ulw_enforcement_generation:"migration"}')"
printf '%s\n%s\n%s\n' "${legacy_row_a}" "${legacy_row_b}" \
  "${legacy_row_current}" >"$(session_file "pending_agents.jsonl")"
printf '%s\n%s\n%s\n' "${legacy_row_a}" "${legacy_row_b}" \
  "${legacy_row_current}" >"$(session_file "agent_dispatch_starts.jsonl")"
for legacy_cleanup_row in "${legacy_row_a}" "${legacy_row_b}"; do
  legacy_cleanup_fp="$(_omc_token_digest "${legacy_cleanup_row}")"
  legacy_cleanup_id="$(jq -r '.lifecycle_dispatch_id' \
    <<<"${legacy_cleanup_row}")"
  jq -nc --arg fp "${legacy_cleanup_fp}" \
    --arg lifecycle_id "${legacy_cleanup_id}" \
    --argjson ts "$(date +%s)" '{
    ts:$ts,agent_type:"quality-reviewer",status:"ignored",
    reason:"terminal-contract-retry-exhausted",verdict:"UNREPORTED",
    findings_count:0,finding_ids:"none",objective_cycle_id:1,
    objective_prompt_ts:1592,review_revision:24,
    ulw_enforcement_generation:"migration",cleanup_journal_version:2,
    cleanup_lifecycle_dispatch_id:$lifecycle_id,
    cleanup_pending_fingerprint:$fp,cleanup_start_fingerprint:$fp
  }' >>"$(session_file "agent_completion_outcomes.jsonl")"
done
_drive_reflect_after_agent "s4t_ambiguous_legacy_journals" \
  "quality-reviewer" >/dev/null
assert_eq "T4t-legacy-ambiguous: both cleanup journals consume" "0" \
  "$(_jsonl_count "$(session_file "agent_completion_outcomes.jsonl")")"
assert_eq "T4t-legacy-ambiguous: only unrelated pending row survives" \
  "current legacy C" \
  "$(jq -s -r 'map(.description) | join(",")' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-legacy-ambiguous: only unrelated start row survives" \
  "current legacy C" \
  "$(jq -s -r 'map(.description) | join(",")' \
    "$(session_file "agent_dispatch_starts.jsonl")")"

# A foreground Agent hard-limit exit can occur before SubagentStop. Its
# synchronous PostToolUse carries the native agentId, sees the exact current
# retained pending row, and wakes the parent.
reset_session "s4t_partial_hard_cap"
with_state_lock_batch \
  "edit_revision" "18" "last_code_edit_revision" "18" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1587" \
  "last_user_prompt_ts" "1587" "prompt_revision" "76"
_drive_agent_dispatch "s4t_partial_hard_cap" "quality-reviewer" >/dev/null
_drive_agent_start "s4t_partial_hard_cap" "quality-reviewer" "native-hard-cap"
wrong_hard_cap_parent_out="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "completed" "different-native")"
assert_not_contains "T4t-hard-cap: wrong native completion cannot borrow pending row" \
  "TERMINAL CONTRACT RECOVERY" "${wrong_hard_cap_parent_out}"
hard_cap_parent_out="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "completed" "native-hard-cap")"
assert_contains "T4t-hard-cap: no-outcome return triggers parent recovery" \
  "TERMINAL CONTRACT RECOVERY" "${hard_cap_parent_out}"
assert_contains "T4t-hard-cap: recovery resumes exact retained transcript" \
  "native-hard-cap" "${hard_cap_parent_out}"
assert_eq "T4t-hard-cap: parent recovery preserves pending handle" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-hard-cap: first parent recovery spends one bounded retry" "1" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "$(session_file "pending_agents.jsonl")")"
hard_cap_parent_out_2="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "completed" "native-hard-cap")"
assert_contains "T4t-hard-cap: second no-outcome return still resumes" \
  "Resume that exact call now" "${hard_cap_parent_out_2}"
hard_cap_parent_out_3="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "completed" "native-hard-cap")"
assert_contains "T4t-hard-cap: third no-outcome return retires call" \
  "bounded parent-recovery budget is exhausted" "${hard_cap_parent_out_3}"
assert_contains "T4t-hard-cap: exhausted return supplies exact rebind token" \
  "[review-rebind:hard-limit-" "${hard_cap_parent_out_3}"
assert_not_contains "T4t-hard-cap: exhausted return never resumes old call" \
  "Resume that exact call now" "${hard_cap_parent_out_3}"
assert_eq "T4t-hard-cap: exhausted pending row becomes tombstone" "true" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "$(session_file "pending_agents.jsonl")")"
hard_cap_background_out="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" true)"
if [[ "${hard_cap_background_out}" != *"TERMINAL CONTRACT RECOVERY"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4t-hard-cap: background launch was mistaken for a terminal return\n' >&2
  fail=$((fail + 1))
fi
hard_cap_is_async_out="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "" "native-hard-cap" true)"
if [[ "${hard_cap_is_async_out}" != *"TERMINAL CONTRACT RECOVERY"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4t-hard-cap: isAsync response was mistaken for a terminal return\n' >&2
  fail=$((fail + 1))
fi
hard_cap_async_status_out="$(_drive_reflect_after_agent \
  "s4t_partial_hard_cap" "quality-reviewer" false \
  "async_launched" "native-hard-cap")"
if [[ "${hard_cap_async_status_out}" != *"TERMINAL CONTRACT RECOVERY"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4t-hard-cap: async response status was mistaken for a terminal return\n' >&2
  fail=$((fail + 1))
fi
hard_cap_rebind_id="$(printf '%s' "${hard_cap_parent_out_3}" \
  | sed -n 's/.*\[review-rebind:\([^]]*\)\].*/\1/p')"
if [[ -n "${hard_cap_rebind_id}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4t-hard-cap: recovery exposes a parseable rebind ID\n' >&2
  fail=$((fail + 1))
fi
assert_eq "T4t-hard-cap: exact rebound replacement is admitted" "" \
  "$(_drive_agent_dispatch "s4t_partial_hard_cap" "quality-reviewer" \
    "[review-rebind:${hard_cap_rebind_id}] replace exhausted review")"

# A retained completion claim is not a malformed terminal contract. Foreground
# PostTool replay must distinguish active settlement, committed effects, and an
# expired incomplete owner without incrementing/resuming the wrong call.
reset_session "s4t_hard_cap_claim_settling"
with_state_lock_batch \
  "edit_revision" "22" "last_code_edit_revision" "22" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1595" \
  "last_user_prompt_ts" "1595" "prompt_revision" "78"
_drive_agent_dispatch "s4t_hard_cap_claim_settling" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4t_hard_cap_claim_settling" \
  "quality-reviewer" "native-claim-settling"
claim_now="$(date +%s)"
jq -c --argjson now "${claim_now}" '
  .completion_claim_id="claim-settling"
  | .completion_claim_ts=$now
  | .completion_claim_effects_complete=false
' "$(session_file "pending_agents.jsonl")" \
  >"$(session_file "pending_agents.jsonl").tmp"
mv "$(session_file "pending_agents.jsonl").tmp" \
  "$(session_file "pending_agents.jsonl")"
claim_settling_out="$(_drive_reflect_after_agent \
  "s4t_hard_cap_claim_settling" "quality-reviewer" false \
  "completed" "native-claim-settling")"
assert_contains "T4t-hard-cap-claim: fresh claim is settling" \
  "COMPLETION SETTLING" "${claim_settling_out}"
assert_not_contains "T4t-hard-cap-claim: fresh claim is never resumed" \
  "Resume that exact call" "${claim_settling_out}"
assert_eq "T4t-hard-cap-claim: settling claim spends no retry" "0" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "$(session_file "pending_agents.jsonl")")"

reset_session "s4t_hard_cap_effects_complete"
with_state_lock_batch \
  "edit_revision" "23" "last_code_edit_revision" "23" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1596" \
  "last_user_prompt_ts" "1596" "prompt_revision" "79"
_drive_agent_dispatch "s4t_hard_cap_effects_complete" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4t_hard_cap_effects_complete" \
  "quality-reviewer" "native-effects-complete"
jq -c --argjson now "$(date +%s)" '
  .completion_claim_id="claim-complete"
  | .completion_claim_ts=$now
  | .completion_claim_effects_complete=true
' "$(session_file "pending_agents.jsonl")" \
  >"$(session_file "pending_agents.jsonl").tmp"
mv "$(session_file "pending_agents.jsonl").tmp" \
  "$(session_file "pending_agents.jsonl")"
effects_complete_out="$(_drive_reflect_after_agent \
  "s4t_hard_cap_effects_complete" "quality-reviewer" false \
  "completed" "native-effects-complete")"
assert_contains "T4t-hard-cap-claim: effects-complete replay is recognized" \
  "COMPLETION ALREADY RECORDED" "${effects_complete_out}"
assert_not_contains "T4t-hard-cap-claim: completed call is never resumed" \
  "Resume that exact call" "${effects_complete_out}"
assert_eq "T4t-hard-cap-claim: effects-complete spends no retry" "0" \
  "$(jq -r '.terminal_contract_retry_count // 0' \
    "$(session_file "pending_agents.jsonl")")"

reset_session "s4t_hard_cap_expired_claim"
with_state_lock_batch \
  "edit_revision" "24" "last_code_edit_revision" "24" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1597" \
  "last_user_prompt_ts" "1597" "prompt_revision" "80"
_drive_agent_dispatch "s4t_hard_cap_expired_claim" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4t_hard_cap_expired_claim" \
  "quality-reviewer" "native-expired-claim"
jq -c '
  .completion_claim_id="claim-expired"
  | .completion_claim_ts=1
  | .completion_claim_effects_complete=false
' "$(session_file "pending_agents.jsonl")" \
  >"$(session_file "pending_agents.jsonl").tmp"
mv "$(session_file "pending_agents.jsonl").tmp" \
  "$(session_file "pending_agents.jsonl")"
expired_claim_out="$(_drive_reflect_after_agent \
  "s4t_hard_cap_expired_claim" "quality-reviewer" false \
  "completed" "native-expired-claim")"
assert_contains "T4t-hard-cap-claim: expired owner is retired" \
  "expired incomplete completion claim" "${expired_claim_out}"
assert_contains "T4t-hard-cap-claim: expired owner supplies rebind token" \
  "[review-rebind:hard-limit-" "${expired_claim_out}"
assert_not_contains "T4t-hard-cap-claim: expired owner is never resumed" \
  "Resume that exact call" "${expired_claim_out}"
assert_eq "T4t-hard-cap-claim: expired owner becomes tombstone" "true" \
  "$(jq -r '.review_dispatch_abandoned // false' \
    "$(session_file "pending_agents.jsonl")")"

# Modern Agent PostTool schema supplies agentId on both async launch and
# synchronous completion. Launch must consume nothing; completion selects the
# exact native row. A legacy no-ID synchronous completion may consume one
# unambiguous same-role outcome, but retires multiple candidates without
# attribution rather than binding the oldest verdict to the current call.
reset_session "s4t_outcome_native_correlation"
outcome_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-outcome-a","review_dispatch_id":"","status":"accepted","verdict":"FINDINGS (1)","findings_count":1,"finding_ids":"AAAA"}' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-outcome-b","review_dispatch_id":"","status":"accepted","verdict":"CLEAN","findings_count":0,"finding_ids":"none"}' \
  >"${outcome_file}"
printf '%s\n' \
  '{"ts":1,"agent_type":"quality-reviewer","message":"Historical review.\nVERDICT: CLEAN"}' \
  >"$(session_file "subagent_summaries.jsonl")"
outcome_launch_out="$(_drive_reflect_after_agent \
  "s4t_outcome_native_correlation" "quality-reviewer" false \
  "async_launched" "native-outcome-b")"
assert_eq "T4t-outcome-correlation: async launch consumes no outcome" "2" \
  "$(_jsonl_count "${outcome_file}")"
if [[ "${outcome_launch_out}" != *"verdict=CLEAN"* \
    && "${outcome_launch_out}" != *"verdict=FINDINGS"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4t-outcome-correlation: async launch emitted a completion capsule\n' >&2
  fail=$((fail + 1))
fi
assert_not_contains "T4t-outcome-correlation: async launch ignores historical summary" \
  "agent=quality-reviewer; verdict=CLEAN" "${outcome_launch_out}"
outcome_complete_out="$(_drive_reflect_after_agent \
  "s4t_outcome_native_correlation" "quality-reviewer" false \
  "completed" "native-outcome-b")"
assert_contains "T4t-outcome-correlation: sync native B gets B capsule" \
  "verdict=CLEAN" "${outcome_complete_out}"
assert_not_contains "T4t-outcome-correlation: sync native B does not get A capsule" \
  "verdict=FINDINGS" "${outcome_complete_out}"
assert_eq "T4t-outcome-correlation: exact sync completion leaves only native A" "1" \
  "$(_jsonl_count "${outcome_file}")"
assert_eq "T4t-outcome-correlation: unmatched native A remains" \
  "native-outcome-a" "$(jq -r '.native_agent_id' "${outcome_file}")"

reset_session "s4t_outcome_legacy_ambiguous"
legacy_ambiguous_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-legacy-a","review_dispatch_id":"","status":"accepted","verdict":"FINDINGS (1)","findings_count":1,"finding_ids":"AAAA"}' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-legacy-b","review_dispatch_id":"","status":"accepted","verdict":"CLEAN","findings_count":0,"finding_ids":"none"}' \
  >"${legacy_ambiguous_file}"
legacy_ambiguous_out="$(_drive_reflect_after_agent \
  "s4t_outcome_legacy_ambiguous" "quality-reviewer" false "completed")"
assert_not_contains "T4t-outcome-correlation: legacy ambiguity emits no clean capsule" \
  "verdict=CLEAN" "${legacy_ambiguous_out}"
assert_not_contains "T4t-outcome-correlation: legacy ambiguity emits no findings capsule" \
  "verdict=FINDINGS" "${legacy_ambiguous_out}"
assert_eq "T4t-outcome-correlation: legacy ambiguous outcomes are retired" "0" \
  "$(_jsonl_count "${legacy_ambiguous_file}")"

reset_session "s4t_outcome_single_sync"
single_outcome_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-sync","review_dispatch_id":"","status":"accepted","verdict":"CLEAN","findings_count":0,"finding_ids":"none"}' \
  >"${single_outcome_file}"
single_sync_out="$(_drive_reflect_after_agent \
  "s4t_outcome_single_sync" "quality-reviewer" false "completed")"
assert_contains "T4t-outcome-correlation: unambiguous sync completion gets capsule" \
  "verdict=CLEAN" "${single_sync_out}"
assert_eq "T4t-outcome-correlation: unambiguous sync outcome is one-shot" "0" \
  "$(_jsonl_count "${single_outcome_file}")"

# A delayed old-interval PostTool event must consume the earliest exact-native
# outcome and explicitly reject its parent-visible raw result. It cannot skip
# forward to the newer current-interval outcome for that resumed native task.
reset_session "s4t_outcome_cross_interval_fifo"
with_state_lock_batch \
  "ulw_enforcement_active" "1" "ulw_enforcement_generation" "2" \
  "edit_revision" "21" "last_code_edit_revision" "21" \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1600" \
  "last_user_prompt_ts" "1600" "prompt_revision" "80"
cross_interval_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-cross","review_dispatch_id":"","status":"accepted","verdict":"CLEAN","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1600,"review_revision":21,"ulw_enforcement_generation":"1"}' \
  '{"agent_type":"quality-reviewer","native_agent_id":"native-cross","review_dispatch_id":"","status":"accepted","verdict":"CLEAN","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1600,"review_revision":21,"ulw_enforcement_generation":"2"}' \
  >"${cross_interval_file}"
cross_interval_old_out="$(_drive_reflect_after_agent \
  "s4t_outcome_cross_interval_fifo" "quality-reviewer" false \
  "completed" "native-cross")"
assert_contains "T4t-outcome-cross-interval: old event is explicit IGNORED" \
  "verdict=IGNORED" "${cross_interval_old_out}"
assert_contains "T4t-outcome-cross-interval: old raw result is rejected" \
  "STALE AGENT RETURN REJECTED" "${cross_interval_old_out}"
assert_not_contains "T4t-outcome-cross-interval: old event never gets CLEAN capsule" \
  "agent=quality-reviewer; verdict=CLEAN" "${cross_interval_old_out}"
assert_eq "T4t-outcome-cross-interval: newer outcome remains after old event" \
  "2" "$(jq -r '.ulw_enforcement_generation' "${cross_interval_file}")"
cross_interval_current_out="$(_drive_reflect_after_agent \
  "s4t_outcome_cross_interval_fifo" "quality-reviewer" false \
  "completed" "native-cross")"
assert_contains "T4t-outcome-cross-interval: next event gets current CLEAN" \
  "agent=quality-reviewer; verdict=CLEAN" "${cross_interval_current_out}"
assert_eq "T4t-outcome-cross-interval: current outcome is one-shot" "0" \
  "$(_jsonl_count "${cross_interval_file}")"

# Planner outcomes are accepted only after the dedicated record-plan state is
# visibly committed. Revision equality alone cannot publish a non-ready plan.
reset_session "s4t_outcome_unpublished_nonready_plan"
with_state_lock_batch \
  "ulw_enforcement_active" "1" "ulw_enforcement_generation" "2" \
  "plan_revision" "5" "has_plan" "false" "plan_verdict" "" \
  "plan_agent" "" "review_cycle_id" "1" \
  "review_cycle_prompt_ts" "1601" "last_user_prompt_ts" "1601"
unpublished_plan_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-planner","native_agent_id":"native-plan-unpublished","review_dispatch_id":"","status":"accepted","verdict":"NEEDS_CLARIFICATION","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1601,"review_revision":5,"ulw_enforcement_generation":"2"}' \
  >"${unpublished_plan_file}"
unpublished_plan_out="$(_drive_reflect_after_agent \
  "s4t_outcome_unpublished_nonready_plan" "quality-planner" false \
  "completed" "native-plan-unpublished")"
assert_contains "T4t-plan-outcome: unpublished non-ready plan is rejected" \
  "reason=plan-generation-changed" "${unpublished_plan_out}"
assert_not_contains "T4t-plan-outcome: unpublished plan is never accepted" \
  "verdict=NEEDS_CLARIFICATION" "${unpublished_plan_out}"

reset_session "s4t_outcome_published_nonready_plan"
with_state_lock_batch \
  "ulw_enforcement_active" "1" "ulw_enforcement_generation" "2" \
  "plan_revision" "5" "has_plan" "false" "plan_verdict" "BLOCKED" \
  "plan_agent" "quality-planner" "review_cycle_id" "1" \
  "review_cycle_prompt_ts" "1602" "last_user_prompt_ts" "1602"
published_plan_file="$(session_file "agent_completion_outcomes.jsonl")"
printf '%s\n' \
  '{"agent_type":"quality-planner","native_agent_id":"native-plan-published","review_dispatch_id":"","status":"accepted","verdict":"BLOCKED","findings_count":0,"finding_ids":"none","objective_cycle_id":1,"objective_prompt_ts":1602,"review_revision":5,"ulw_enforcement_generation":"2"}' \
  >"${published_plan_file}"
published_plan_out="$(_drive_reflect_after_agent \
  "s4t_outcome_published_nonready_plan" "quality-planner" false \
  "completed" "native-plan-published")"
assert_contains "T4t-plan-outcome: committed non-ready plan is accepted" \
  "verdict=BLOCKED" "${published_plan_out}"

# Planner publication is the sibling state-changing terminal contract. A
# tracked partial planner cannot consume its start or publish current_plan.md;
# the same native call resumes and publishes once after PLAN_READY.
reset_session "s4t_partial_planner"
with_state_lock_batch \
  "plan_revision" "4" "review_cycle_id" "1" \
  "review_cycle_prompt_ts" "1590" "last_user_prompt_ts" "1590" \
  "prompt_revision" "74"
_drive_agent_dispatch "s4t_partial_planner" "quality-planner" >/dev/null
_drive_agent_start "s4t_partial_planner" "quality-planner" "native-plan-partial"
_drive_record_plan "s4t_partial_planner" "quality-planner" \
  'VERDICT: CLEAN' \
  "native-plan-partial"
planner_partial_out="$(_drive_subagent_summary_out "s4t_partial_planner" \
  "quality-planner" 'VERDICT: CLEAN' \
  "native-plan-partial")"
assert_contains "T4t-plan-partial: wrong-role planner verdict is continued" \
  '"hookEventName":"SubagentStop"' "${planner_partial_out}"
assert_eq "T4t-plan-partial: plan artifact is not published" "0" \
  "$([[ -e "$(session_file "current_plan.md")" ]] && echo 1 || echo 0)"
assert_eq "T4t-plan-partial: plan state is not stamped" "" \
  "$(read_state "plan_verdict")"
assert_eq "T4t-plan-partial: both causal rows remain" "2" \
  "$(( $(jq -s 'length' "$(session_file "pending_agents.jsonl")") \
      + $(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")") ))"
valid_plan=$'1. Implement the recovery.\n2. Run focused and full verification.\n\nVERDICT: PLAN_READY'
_drive_record_plan "s4t_partial_planner" "quality-planner" \
  "${valid_plan}" "native-plan-partial"
_drive_subagent_summary "s4t_partial_planner" "quality-planner" \
  "${valid_plan}" "native-plan-partial"
assert_eq "T4t-plan-partial: resumed planner publishes PLAN_READY" \
  "PLAN_READY" "$(read_state "plan_verdict")"
assert_eq "T4t-plan-partial: resumed planner fully settles pending" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-plan-partial: resumed planner fully settles start" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"

reset_session "s4t_partial_planner_stale"
with_state_lock_batch \
  "plan_revision" "8" "review_cycle_id" "1" \
  "review_cycle_prompt_ts" "1592" "last_user_prompt_ts" "1592" \
  "prompt_revision" "75"
_drive_agent_dispatch "s4t_partial_planner_stale" "quality-planner" >/dev/null
_drive_agent_start "s4t_partial_planner_stale" "quality-planner" \
  "native-plan-stale"
write_state "plan_revision" "9"
_drive_record_plan "s4t_partial_planner_stale" "quality-planner" \
  'I mapped the old plan. Let me finish…' "native-plan-stale"
stale_plan_out="$(_drive_subagent_summary_out \
  "s4t_partial_planner_stale" "quality-planner" \
  'I mapped the old plan. Let me finish…' "native-plan-stale")"
assert_eq "T4t-plan-stale: stale partial planner is not revived" "" \
  "${stale_plan_out}"
assert_eq "T4t-plan-stale: stale planner pending is cleaned" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4t-plan-stale: stale planner start is cleaned" "0" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"

reset_session "s4t_empty_informational"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1595" \
  "last_user_prompt_ts" "1595" "prompt_revision" "75"
_drive_agent_dispatch "s4t_empty_informational" "frontend-developer" >/dev/null
_drive_agent_start "s4t_empty_informational" "frontend-developer" \
  "native-empty-informational"
informational_empty_out="$(_drive_subagent_summary_out \
  "s4t_empty_informational" "frontend-developer" '' \
  "native-empty-informational")"
assert_eq "T4t-empty-info: non-enforced empty callback remains silent" "" \
  "${informational_empty_out}"
assert_eq "T4t-empty-info: legacy empty behavior leaves pending intact" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

reset_session "s4u_native_parallel"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1600" \
  "last_user_prompt_ts" "1600" "prompt_revision" "72"
_drive_agent_dispatch "s4u_native_parallel" "quality-reviewer" >/dev/null
_drive_agent_dispatch "s4u_native_parallel" "excellence-reviewer" >/dev/null
_drive_agent_start "s4u_native_parallel" "quality-reviewer" "native-parallel-quality"
_drive_agent_start "s4u_native_parallel" "excellence-reviewer" "native-parallel-excellence"
assert_eq "T4u: distinct reviewer identities remain parallel and bound" "2" \
  "$(jq -s '[.[] | select((.native_agent_id // "") != "")] | length' \
    "$(session_file "pending_agents.jsonl")")"

reset_session "s4v_ordinary_duplicate"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1700" \
  "last_user_prompt_ts" "1700" "prompt_revision" "73"
assert_eq "T4v: first ordinary exact identity is allowed" "" \
  "$(_drive_agent_dispatch "s4v_ordinary_duplicate" "frontend-developer")"
ordinary_before_duplicate="$(cksum "$(session_file "pending_agents.jsonl")" | awk '{print $1 ":" $2}')"
ordinary_duplicate="$(_drive_agent_dispatch "s4v_ordinary_duplicate" "frontend-developer")"
assert_contains "T4v: active ordinary duplicate is denied generically" \
  "[Dispatch causality]" "${ordinary_duplicate}"
assert_contains "T4v: ordinary denial names exact-identity causality" \
  "already has an active call" "${ordinary_duplicate}"
assert_eq "T4v: duplicate denial leaves one pending row" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4v: unconfirmed duplicate leaves pending bytes unchanged" \
  "${ordinary_before_duplicate}" \
  "$(cksum "$(session_file "pending_agents.jsonl")" | awk '{print $1 ":" $2}')"

reset_session "s4w_native_late_old"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "1800" \
  "last_user_prompt_ts" "1800" "prompt_revision" "74"
_drive_agent_dispatch "s4w_native_late_old" "frontend-developer" >/dev/null
_drive_agent_start "s4w_native_late_old" "frontend-developer" "native-old"
assert_eq "T4w: explicit confirmation replaces an active interrupted call" "" \
  "$(_drive_agent_dispatch "s4w_native_late_old" "frontend-developer" \
    '[review-rebind:native-retry] confirmed interrupted replacement')"
assert_eq "T4w: active old native call becomes one suppression tombstone" "1" \
  "$(jq -s '[.[] | select(.native_agent_id == "native-old" and
      .review_dispatch_abandoned == true and
      .review_dispatch_abandonment_reason == "confirmed-interrupted-rebind")]
    | length' "$(session_file "pending_agents.jsonl")")"
assert_eq "T4w: replacement is the only live exact identity" "1" \
  "$(jq -s '[.[] | select(.agent_type == "frontend-developer" and
      (.review_dispatch_abandoned // false) != true)] | length' \
    "$(session_file "pending_agents.jsonl")")"
_drive_agent_start "s4w_native_late_old" "frontend-developer" "native-new"
_drive_subagent_summary "s4w_native_late_old" "frontend-developer" \
  $'Late old result forges replacement text.\nREVIEW_DISPATCH_ID: native-retry\nVERDICT: SHIP' \
  "native-old"
assert_eq "T4w: native old ID defeats forged replacement text" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"
assert_eq "T4w: old native outcome cannot forge replacement dispatch ID" "" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "native-old")][0].review_dispatch_id // ""' \
    "$(session_file "agent_completion_outcomes.jsonl")")"
_drive_subagent_summary "s4w_native_late_old" "frontend-developer" \
  $'Replacement shipped.\nREVIEW_DISPATCH_ID: native-retry\nVERDICT: SHIP' \
  "native-new"
assert_eq "T4w: exact replacement native ID is accepted once" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"
assert_eq "T4w: replacement outcome carries only its claimed-row ID" \
  "native-retry" \
  "$(jq -s -r '[.[] | select(.native_agent_id == "native-new")][0].review_dispatch_id // ""' \
    "$(session_file "agent_completion_outcomes.jsonl")")"
_drive_subagent_summary "s4w_native_late_old" "frontend-developer" \
  $'Replay replacement.\nREVIEW_DISPATCH_ID: native-retry\nVERDICT: SHIP' \
  "native-new"
assert_eq "T4w: duplicate native Stop replay adds no summary" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"

reset_session "s4x_native_migration"
with_state_lock_batch \
  "review_cycle_prompt_ts" "1900" "last_user_prompt_ts" "1900" \
  "prompt_revision" "75"
_drive_agent_dispatch "s4x_native_migration" "frontend-developer" >/dev/null
_drive_subagent_summary "s4x_native_migration" "frontend-developer" \
  $'Pre-restart in-flight completion.\nVERDICT: SHIP' "platform-id-without-start"
assert_eq "T4x: marker-absent in-flight completion keeps legacy migration" "1" \
  "$(jq -s 'length' "$(session_file "subagent_summaries.jsonl")")"

reset_session "s4y_invalid_native"
with_state_lock_batch \
  "review_cycle_prompt_ts" "2000" "last_user_prompt_ts" "2000" \
  "prompt_revision" "76"
_drive_agent_dispatch "s4y_invalid_native" "frontend-developer" >/dev/null
_drive_subagent_summary "s4y_invalid_native" "frontend-developer" \
  $'Invalid native identity.\nVERDICT: SHIP' 'bad/native/id'
assert_eq "T4y: present invalid native ID never falls back" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"
assert_eq "T4y: invalid native ID leaves causal pending row" "1" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

reset_session "s4z_untracked_start"
_drive_agent_start "s4z_untracked_start" "frontend-developer" "untracked-native"
assert_eq "T4z: no matching pending row does not arm native tracking" "" \
  "$(read_state "native_agent_id_tracking_version")"

reset_session "s4za_native_plan_first"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2100" \
  "last_user_prompt_ts" "2100" "prompt_revision" "77" \
  "plan_revision" "0"
_drive_agent_dispatch "s4za_native_plan_first" "quality-planner" >/dev/null
_drive_agent_start "s4za_native_plan_first" "quality-planner" "native-plan-a"
_drive_record_plan "s4za_native_plan_first" "quality-planner" \
  $'1. Inspect src/a.ts.\n2. Implement src/b.ts.\nVERDICT: PLAN_READY' "native-plan-a"
assert_eq "T4za: planner-first native result publishes ready plan" "true" \
  "$(read_state "has_plan")"
assert_eq "T4za: ready native plan advances generation once" "1" \
  "$(read_state "plan_revision")"
_drive_subagent_summary "s4za_native_plan_first" "quality-planner" \
  $'1. Inspect src/a.ts.\n2. Implement src/b.ts.\nVERDICT: PLAN_READY' "native-plan-a"
assert_eq "T4za: planner-first native pair settles pending" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

reset_session "s4zb_native_plan_summary_first"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2200" \
  "last_user_prompt_ts" "2200" "prompt_revision" "78" \
  "plan_revision" "0"
_drive_agent_dispatch "s4zb_native_plan_summary_first" "prometheus" >/dev/null
_drive_agent_start "s4zb_native_plan_summary_first" "prometheus" "native-plan-b"
_drive_subagent_summary "s4zb_native_plan_summary_first" "prometheus" \
  $'Decision-complete plan.\nVERDICT: PLAN_READY' "native-plan-b"
assert_eq "T4zb: summary-first planner claim waits for plan hook" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "$(session_file "pending_agents.jsonl")")"
accepted_planner_parent_out="$(_drive_reflect_after_agent \
  "s4zb_native_plan_summary_first" "prometheus" false \
  "completed" "native-plan-b")"
assert_contains "T4zb: unpublished accepted planner is rejected, not cleaned" \
  "STALE AGENT RETURN REJECTED" "${accepted_planner_parent_out}"
assert_eq "T4zb: accepted planner outcome preserves pending claim" "true" \
  "$(jq -r '.completion_claim_effects_complete // false' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4zb: accepted planner outcome preserves plan start" "1" \
  "$(jq -s 'length' "$(session_file "agent_dispatch_starts.jsonl")")"
_drive_record_plan "s4zb_native_plan_summary_first" "prometheus" \
  $'Decision-complete plan.\nVERDICT: PLAN_READY' "native-plan-b"
assert_eq "T4zb: summary-first native planner publishes plan" "PLAN_READY" \
  "$(read_state "plan_verdict")"
assert_eq "T4zb: summary-first native planner settles pending" "0" \
  "$(jq -s 'length' "$(session_file "pending_agents.jsonl")")"

reset_session "s4zc_native_plan_nonready"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2300" \
  "last_user_prompt_ts" "2300" "prompt_revision" "79" \
  "plan_revision" "4" "metis_gate_blocks" "2"
_drive_agent_dispatch "s4zc_native_plan_nonready" "quality-planner" >/dev/null
planner_cross_duplicate="$(_drive_agent_dispatch "s4zc_native_plan_nonready" "prometheus")"
assert_contains "T4zc: both planner roles share one publication slot" \
  "permissionDecision" "${planner_cross_duplicate}"
_drive_agent_start "s4zc_native_plan_nonready" "quality-planner" "native-plan-c"
_drive_record_plan "s4zc_native_plan_nonready" "quality-planner" \
  $'Need the retention-policy decision before planning.\nVERDICT: NEEDS_CLARIFICATION' \
  "native-plan-c"
assert_eq "T4zc: non-ready plan is visible but not executable" "false" \
  "$(read_state "has_plan")"
assert_eq "T4zc: non-ready plan does not advance freshness" "4" \
  "$(read_state "plan_revision")"
assert_eq "T4zc: non-ready plan does not buy a complexity nudge" "" \
  "$(read_state "plan_complexity_nudge_pending")"
assert_eq "T4zc: non-ready plan does not reset Metis economics" "2" \
  "$(read_state "metis_gate_blocks")"

reset_session "s4zd_native_plan_wrong_cycle"
with_state_lock_batch \
  "review_cycle_id" "7" "review_cycle_prompt_ts" "2400" \
  "last_user_prompt_ts" "2400" "prompt_revision" "80" \
  "plan_revision" "0"
_drive_agent_dispatch "s4zd_native_plan_wrong_cycle" "quality-planner" >/dev/null
_drive_agent_start "s4zd_native_plan_wrong_cycle" "quality-planner" "native-plan-cycle"
# Same epoch second, different monotonic objective: timestamp-only causality
# would accept this stale result.
with_state_lock_batch "review_cycle_id" "8" \
  "review_cycle_prompt_ts" "2400" "last_user_prompt_ts" "2400"
_drive_record_plan "s4zd_native_plan_wrong_cycle" "quality-planner" \
  $'Stale prior-objective plan.\nVERDICT: PLAN_READY' "native-plan-cycle"
assert_eq "T4zd: same-second wrong-cycle plan is rejected" "" \
  "$(read_state "plan_verdict")"
assert_eq "T4zd: wrong-cycle plan does not advance generation" "0" \
  "$(read_state "plan_revision")"

reset_session "s4zda_native_summary_wrong_cycle"
with_state_lock_batch \
  "review_cycle_id" "7" "review_cycle_prompt_ts" "2401" \
  "last_user_prompt_ts" "2401" "prompt_revision" "80" \
  "model_routing_uncertainty" "1"
_drive_agent_dispatch "s4zda_native_summary_wrong_cycle" "oracle" >/dev/null
_drive_agent_start "s4zda_native_summary_wrong_cycle" "oracle" \
  "native-summary-cycle"
with_state_lock_batch "review_cycle_id" "8" \
  "review_cycle_prompt_ts" "2401" "last_user_prompt_ts" "2401"
_drive_subagent_summary "s4zda_native_summary_wrong_cycle" "oracle" \
  $'Old objective root cause.\nVERDICT: RESOLVED' "native-summary-cycle"
assert_eq "T4zda: same-second wrong-cycle summary is rejected" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then
      jq -s 'length' "$(session_file "subagent_summaries.jsonl")"
    else printf 0; fi)"
assert_eq "T4zda: stale summary cannot buy uncertainty deliberation" "" \
  "$(read_state "model_uncertainty_deliberator_type")"
assert_eq "T4zda: stale summary cannot stamp the current cycle" "" \
  "$(read_state "model_uncertainty_deliberator_cycle_id")"

reset_session "s4zdb_native_reviewer_wrong_cycle"
with_state_lock_batch \
  "review_cycle_id" "7" "review_cycle_prompt_ts" "2402" \
  "last_user_prompt_ts" "2402" "prompt_revision" "80" \
  "edit_revision" "16" "last_code_edit_revision" "16"
_drive_agent_dispatch "s4zdb_native_reviewer_wrong_cycle" \
  "quality-reviewer" >/dev/null
_drive_agent_start "s4zdb_native_reviewer_wrong_cycle" "quality-reviewer" \
  "native-reviewer-cycle"
with_state_lock_batch "review_cycle_id" "8" \
  "review_cycle_prompt_ts" "2402" "last_user_prompt_ts" "2402"
_drive_record_reviewer "s4zdb_native_reviewer_wrong_cycle" "standard" \
  $'Old objective review.\nVERDICT: CLEAN' "quality-reviewer" \
  "native-reviewer-cycle"
assert_eq "T4zdb: same-second wrong-cycle reviewer is rejected" "" \
  "$(read_state "last_review_ts")"
assert_eq "T4zdb: wrong-cycle reviewer ticks no code dimension" "" \
  "$(read_state "dim_code_quality_verdict")"

reset_session "s4ze_native_plan_redaction"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2500" \
  "last_user_prompt_ts" "2500" "prompt_revision" "81" \
  "plan_revision" "0"
_drive_agent_dispatch "s4ze_native_plan_redaction" "quality-planner" >/dev/null
_drive_agent_start "s4ze_native_plan_redaction" "quality-planner" "native-plan-secret"
plan_secret_message=$'Use token sk-proj-ABC\x1bDEF1234567890 while inspecting.\nVERDICT: PLAN_READY'
_drive_record_plan "s4ze_native_plan_redaction" "quality-planner" \
  "${plan_secret_message}" "native-plan-secret"
plan_artifact="$(session_file "current_plan.md")"
if LC_ALL=C grep -q $'\x1b' "${plan_artifact}"; then
  assert_eq "T4ze: plan artifact strips controls before persistence" "no-control" "control-present"
else
  assert_eq "T4ze: plan artifact strips controls before persistence" "no-control" "no-control"
fi
assert_contains "T4ze: reconstructed secret is redacted" "<redacted-secret>" \
  "$(<"${plan_artifact}")"
assert_eq "T4ze: reconstructed secret never persists" "0" \
  "$(grep -c 'sk-proj-ABCDEF1234567890' "${plan_artifact}" || true)"

printf '\nDispatch-ledger capacity and permanent identity registries\n'

reset_session "s4zf_live_33"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2600" \
  "last_user_prompt_ts" "2600" "prompt_revision" "82"
for live_i in $(seq 1 33); do
  _drive_agent_dispatch "s4zf_live_33" "live-worker-${live_i}" \
    "parallel worker ${live_i}" >/dev/null
done
live_33_count="$(jq -s \
  '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
  "$(session_file "pending_agents.jsonl")")"
assert_eq "T4zf: all 33 paid live rows survive beyond the old cap" "33" \
  "${live_33_count}"
_drive_subagent_summary "s4zf_live_33" "live-worker-1" \
  $'First of 33 returned.\nVERDICT: SHIP'
assert_eq "T4zf: first row beyond old cap remains completable" "0" \
  "$(jq -s '[.[] | select(.agent_type == "live-worker-1")] | length' \
    "$(session_file "pending_agents.jsonl")")"
assert_eq "T4zf: completing first leaves the other 32 live" "32" \
  "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
    "$(session_file "pending_agents.jsonl")")"

reset_session "s4zg_live_64"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2700" \
  "last_user_prompt_ts" "2700" "prompt_revision" "83"
for live_i in $(seq 1 64); do
  _drive_agent_dispatch "s4zg_live_64" "cap-worker-${live_i}" \
    "capacity worker ${live_i}" >/dev/null
done
cap_pending="$(session_file "pending_agents.jsonl")"
assert_eq "T4zg: 64th live dispatch is admitted" "64" \
  "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
    "${cap_pending}")"
expired_claim="$(( $(date +%s) - 121 ))"
jq -c --argjson expired "${expired_claim}" '
  if .agent_type == "cap-worker-1" then
    . + {completion_claim_id:"expired-cap-claim",completion_claim_ts:$expired,
         completion_claim_effects_complete:false}
  else . end
' "${cap_pending}" >"${cap_pending}.tmp"
mv "${cap_pending}.tmp" "${cap_pending}"
assert_eq "T4zg: one confirmed-dead slot can rebind at capacity" "" \
  "$(_drive_agent_dispatch "s4zg_live_64" "cap-worker-1" \
    '[review-rebind:cap-recovery] recover expired capacity slot')"
assert_eq "T4zg: rebind keeps exactly 64 live calls" "64" \
  "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
    "${cap_pending}")"
pending_before_65="$(cksum "${cap_pending}" | awk '{print $1 ":" $2}')"
state_before_65="$(jq -cS '
  del(.last_any_gate_block_ts, .last_any_gate_block_name)
' "$(session_file "session_state.json")")"
call_65="$(_drive_agent_dispatch "s4zg_live_64" "cap-worker-65" "over capacity")"
assert_contains "T4zg: unrelated 65th live call is denied" \
  "[Dispatch capacity]" "${call_65}"
assert_eq "T4zg: cap denial leaves pending bytes unchanged" "${pending_before_65}" \
  "$(cksum "${cap_pending}" | awk '{print $1 ":" $2}')"
assert_eq "T4zg: cap denial rolls lifecycle state back exactly" \
  "${state_before_65}" \
  "$(jq -cS 'del(.last_any_gate_block_ts, .last_any_gate_block_name)' \
    "$(session_file "session_state.json")")"
assert_eq "T4zg: cap denial retains only generic block telemetry" \
  "subagent-dispatch-causality" "$(read_state "last_any_gate_block_name")"

reset_session "s4zh_tombstone_rotation"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2800" \
  "last_user_prompt_ts" "2800" "prompt_revision" "84"
for live_i in $(seq 1 33); do
  _drive_agent_dispatch "s4zh_tombstone_rotation" "rotation-live-${live_i}" >/dev/null
done
rotation_pending="$(session_file "pending_agents.jsonl")"
for tomb_i in $(seq 1 40); do
  jq -nc --arg i "${tomb_i}" \
    '{ts:1,agent_type:("rotation-tomb-"+$i),review_dispatch_abandoned:true}' \
    >>"${rotation_pending}"
done
_drive_agent_dispatch "s4zh_tombstone_rotation" "rotation-live-34" >/dev/null
assert_eq "T4zh: tombstone rotation preserves every live row" "34" \
  "$(jq -s '[.[] | select((.review_dispatch_abandoned // false) != true)] | length' \
    "${rotation_pending}")"
assert_eq "T4zh: only newest 32 redundant tombstones remain" "32" \
  "$(jq -s '[.[] | select(.review_dispatch_abandoned == true)] | length' \
    "${rotation_pending}")"
assert_eq "T4zh: oldest live row is never displaced by tombstones" "1" \
  "$(jq -s '[.[] | select(.agent_type == "rotation-live-1")] | length' \
    "${rotation_pending}")"

reset_session "s4zi_start_rotation"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "2900" \
  "last_user_prompt_ts" "2900" "prompt_revision" "85"
start_rotation="$(session_file "agent_dispatch_starts.jsonl")"
for tomb_i in $(seq 1 40); do
  jq -nc --arg i "${tomb_i}" \
    '{ts:1,agent_type:("start-tomb-"+$i),review_dispatch_abandoned:true}' \
    >>"${start_rotation}"
done
_drive_agent_dispatch "s4zi_start_rotation" "quality-reviewer" >/dev/null
assert_eq "T4zi: reviewer-start ledger retains its live row" "1" \
  "$(jq -s '[.[] | select(.agent_type == "quality-reviewer" and
      (.review_dispatch_abandoned // false) != true)] | length' "${start_rotation}")"
assert_eq "T4zi: reviewer-start history rotates only tombstones" "32" \
  "$(jq -s '[.[] | select(.review_dispatch_abandoned == true)] | length' \
    "${start_rotation}")"

reset_session "s4zj_permanent_taint"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "3000" \
  "last_user_prompt_ts" "3000" "prompt_revision" "86"
taint_pending="$(session_file "pending_agents.jsonl")"
jq -nc '{ts:1,agent_type:"tainted-worker",review_dispatch_abandoned:true}' \
  >"${taint_pending}"
for tomb_i in $(seq 1 40); do
  jq -nc --arg i "${tomb_i}" \
    '{ts:1,agent_type:("taint-tomb-"+$i),review_dispatch_abandoned:true}' \
    >>"${taint_pending}"
done
printf '%s\n' 'tainted-worker' >"$(session_file "dispatch_tainted_identities.log")"
_drive_agent_dispatch "s4zj_permanent_taint" "rotation-trigger" >/dev/null
assert_eq "T4zj: oldest taint tombstone can rotate away" "0" \
  "$(jq -s '[.[] | select(.agent_type == "tainted-worker")] | length' \
    "${taint_pending}")"
taint_unbound="$(_drive_agent_dispatch "s4zj_permanent_taint" "tainted-worker")"
assert_contains "T4zj: durable taint still denies unbound reuse" \
  "[review-rebind:" "${taint_unbound}"
assert_eq "T4zj: a fresh bound reuse remains convenient" "" \
  "$(_drive_agent_dispatch "s4zj_permanent_taint" "tainted-worker" \
    '[review-rebind:durable-taint-id] safe replacement')"
_drive_subagent_summary "s4zj_permanent_taint" "tainted-worker" \
  $'Bound replacement.\nREVIEW_DISPATCH_ID: durable-taint-id\nVERDICT: SHIP'
reused_id="$(_drive_agent_dispatch "s4zj_permanent_taint" "tainted-worker" \
  '[review-rebind:durable-taint-id] reused ID')"
assert_contains "T4zj: accepted recovery IDs are never reusable" \
  "already present" "${reused_id}"

reset_session "s4zk_native_registry_cap"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "3100" \
  "last_user_prompt_ts" "3100" "prompt_revision" "87"
_drive_agent_dispatch "s4zk_native_registry_cap" "long-live-worker" >/dev/null
_drive_agent_start "s4zk_native_registry_cap" "long-live-worker" "native-long-live"
bindings_cap="$(session_file "native_agent_bindings.jsonl")"
for history_i in $(seq 1 140); do
  jq -nc --arg i "${history_i}" \
    '{native_agent_id:("native-history-"+$i),agent_type:"historical-worker",
      review_dispatch_id:"",objective_cycle_id:0,ts:1}' >>"${bindings_cap}"
done
_drive_agent_dispatch "s4zk_native_registry_cap" "new-live-worker" >/dev/null
_drive_agent_start "s4zk_native_registry_cap" "new-live-worker" "native-new-live"
assert_eq "T4zk: binding registry preserves every live native ID" "2" \
  "$(jq -s '[.[] | select(.native_agent_id == "native-long-live" or
      .native_agent_id == "native-new-live")] | length' "${bindings_cap}")"
assert_eq "T4zk: native registry keeps at most 128 historical markers" "130" \
  "$(jq -s 'length' "${bindings_cap}")"

reset_session "s4zl_native_registry_symlink"
with_state_lock_batch \
  "review_cycle_id" "1" "review_cycle_prompt_ts" "3200" \
  "last_user_prompt_ts" "3200" "prompt_revision" "88"
_drive_agent_dispatch "s4zl_native_registry_symlink" "frontend-developer" >/dev/null
external_registry="${_test_home}/foreign-native-bindings.jsonl"
: >"${external_registry}"
ln -s "${external_registry}" "$(session_file "native_agent_bindings.jsonl")"
if _drive_agent_start "s4zl_native_registry_symlink" "frontend-developer" "native-symlink"; then
  assert_eq "T4zl: symlink registry makes native bind fail closed" "failure" "success"
else
  assert_eq "T4zl: symlink registry makes native bind fail closed" "failure" "failure"
fi
_drive_subagent_summary "s4zl_native_registry_symlink" "frontend-developer" \
  $'Must not trust symlinked commit marker.\nVERDICT: SHIP' "native-symlink"
assert_eq "T4zl: symlinked registry cannot authorize a completion" "0" \
  "$(if [[ -f "$(session_file "subagent_summaries.jsonl")" ]]; then jq -s 'length' "$(session_file "subagent_summaries.jsonl")"; else printf 0; fi)"

# ---------------------------------------------------------------------------
# Block 5: stop-guard's stricter-verdict-wins gate actually blocks
# ---------------------------------------------------------------------------
printf '\nStop-guard stricter-verdict-wins gate\n'

# ULW already active (sentinel created at test setup); stop-guard reaches
# the gate path. Synthesize a session where the review-coverage gate would
# have passed but a dim verdict is fresh FINDINGS — the new gate should fire.

# Synthesize a session where the review-coverage gate would have passed
# (all required dims ticked + valid) but a dim verdict is FINDINGS.
_drive_stop_guard() {
  local sid="$1"
  local payload
  payload="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" OMC_GATE_LEVEL=full \
    OMC_NO_DEFER_MODE=off \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" \
    <<<"${payload}" 2>/dev/null || true
}

reset_session "s5a"
# Set up: complex task (3+ files edited), all required dims ticked, the
# latest reviewer was CLEAN (review_had_findings=false so the old
# quality gate doesn't fire), BUT a prior sibling reviewer's FINDINGS
# verdict on bug_hunt is still fresh. Our new gate must fire here.
edited_log="$(session_file "edited_files.log")"
printf 'file1\nfile2\nfile3\n' >"${edited_log}"
now="$(now_epoch)"
with_state_lock_batch \
  "workflow_mode" "ultrawork" \
  "last_user_prompt" "implement feature X" \
  "task_intent" "execution" \
  "task_domain" "coding" \
  "last_code_edit_ts" "$((now - 100))" \
  "last_review_ts" "${now}" \
  "review_had_findings" "false" \
  "last_verify_ts" "${now}" \
  "last_verify_outcome" "passed" \
  "last_verify_confidence" "60" \
  "code_edit_count" "3" \
  "last_edit_ts" "$((now - 100))" \
  "dim_bug_hunt_ts" "${now}" \
  "dim_bug_hunt_verdict" "FINDINGS (2)" \
  "dim_code_quality_ts" "${now}" \
  "dim_code_quality_verdict" "CLEAN" \
  "dim_stress_test_ts" "${now}" \
  "dim_stress_test_verdict" "CLEAN" \
  "dim_traceability_ts" "${now}" \
  "dim_traceability_verdict" "CLEAN" \
  "dim_completeness_ts" "${now}" \
  "dim_completeness_verdict" "CLEAN" \
  "last_excellence_review_ts" "${now}" \
  "last_metis_review_ts" "${now}"

stop_out="$(_drive_stop_guard "s5a")"
assert_contains "T5a: stop-guard blocks on fresh FINDINGS verdict" "Stricter-verdict-wins" "${stop_out}"
assert_contains "T5a: block message names the offending dim" "bug_hunt" "${stop_out}"

# Scenario: same setup, but FINDINGS is STALE (ts < last_code_edit_ts).
# The gate must NOT block — the reviewer ran on pre-edit code.
reset_session "s5b"
printf 'file1\nfile2\nfile3\n' >"${edited_log}"
with_state_lock_batch \
  "workflow_mode" "ultrawork" \
  "last_user_prompt" "implement feature X" \
  "task_intent" "execution" \
  "task_domain" "coding" \
  "last_code_edit_ts" "$((now + 50))" \
  "last_review_ts" "${now}" \
  "review_had_findings" "false" \
  "last_verify_ts" "$((now + 60))" \
  "last_verify_outcome" "passed" \
  "last_verify_confidence" "60" \
  "code_edit_count" "3" \
  "last_edit_ts" "$((now + 50))" \
  "dim_bug_hunt_ts" "$((now - 10))" \
  "dim_bug_hunt_verdict" "FINDINGS (2)" \
  "dim_code_quality_ts" "${now}" \
  "dim_code_quality_verdict" "CLEAN" \
  "dim_stress_test_ts" "${now}" \
  "dim_stress_test_verdict" "CLEAN" \
  "dim_traceability_ts" "${now}" \
  "dim_traceability_verdict" "CLEAN" \
  "dim_completeness_ts" "${now}" \
  "dim_completeness_verdict" "CLEAN" \
  "last_excellence_review_ts" "${now}" \
  "last_metis_review_ts" "${now}"

stop_out_stale="$(_drive_stop_guard "s5b")"
# The gate must NOT have fired (verdict is stale — pre-edit). Some other
# gate might still block (review-coverage, since bug_hunt ts is stale),
# but it should NOT be our gate.
if [[ "${stop_out_stale}" == *"Stricter-verdict-wins"* ]]; then
  printf '  FAIL: T5b: gate fired on STALE FINDINGS (ts pre-dates last_code_edit_ts)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------------
# Block 6: AGENTS.md doc presence (regression net against the doc drifting)
# ---------------------------------------------------------------------------
printf '\nAGENTS.md doc presence\n'

if grep -q "Stricter-verdict-wins invariant" "${REPO_ROOT}/AGENTS.md"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: AGENTS.md missing "Stricter-verdict-wins invariant" section\n' >&2
  fail=$((fail + 1))
fi

if grep -q "stricter-wins" "${REPO_ROOT}/AGENTS.md" && grep -q "F11" "${REPO_ROOT}/AGENTS.md"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: AGENTS.md missing stricter-wins / F11 cross-reference\n' >&2
  fail=$((fail + 1))
fi

printf '\n'
printf 'test-stricter-verdict-wins: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
