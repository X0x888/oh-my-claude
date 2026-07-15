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
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg msg "${message}" \
    --arg native_id "${native_agent_id}" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$msg}
     + if $native_id == "" then {} else {agent_id:$native_id} end' \
    | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
      >/dev/null 2>&1 || true
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

# In oh-my-claude's reviewer map, each REVIEWER_TYPE owns its own
# dimension(s). The cross-reviewer-same-dim overlap that cc10x F11
# names exists when third-party code-reviewers (`superpowers:code-reviewer`,
# `feature-dev:code-reviewer`) ALSO dispatch as REVIEWER_TYPE=standard
# alongside quality-reviewer — both cover bug_hunt+code_quality.
#
# Test the SAME REVIEWER_TYPE dispatched twice (e.g., a sibling code-reviewer
# running after quality-reviewer on the same code state).
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
