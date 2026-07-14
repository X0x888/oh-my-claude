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
  local payload
  payload="$(jq -nc --arg sid "${sid}" --arg msg "${message}" --arg agent "${agent_type}" \
    '{session_id:$sid, last_assistant_message:$msg}
     + if $agent == "" then {} else {agent_type:$agent} end')"
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
  local sid="$1" agent_type="$2" message="$3"
  jq -nc --arg sid "${sid}" --arg agent "${agent_type}" --arg msg "${message}" \
    '{session_id:$sid,agent_type:$agent,last_assistant_message:$msg}' \
    | HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
      bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
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

# Universal SubagentStop cleanup removes the completed pending row; a fresh
# dispatch at generation 2 is then accepted and atomically stamps the legacy
# review generation plus both standard dimensions.
_drive_subagent_summary "s4e" "quality-reviewer" $'Review completed.\nVERDICT: CLEAN'
fresh_dispatch="$(_drive_agent_dispatch "s4e" "quality-reviewer")"
assert_eq "T4e: fresh post-edit reviewer dispatch is allowed" "" "${fresh_dispatch}"
_drive_record_reviewer "s4e" "standard" $'Fresh review completed.\nVERDICT: CLEAN' "quality-reviewer"
assert_eq "T4e: accepted review stamps legacy code generation" \
  "2" "$(read_state "review_code_revision")"
assert_eq "T4e: accepted review stamps bug_hunt generation" \
  "2" "$(read_state "dim_bug_hunt_revision")"
assert_eq "T4e: accepted review stamps code_quality generation" \
  "2" "$(read_state "dim_code_quality_revision")"

# Same-role duplicate reviews are the one shape SubagentStop cannot identify
# causally (it exposes agent_type but no Agent tool_use_id), so fail closed.
# Different roles still retain the intended parallelism.
reset_session "s4f"
with_state_lock_batch "edit_revision" "1" "last_code_edit_revision" "1"
first_same_role="$(_drive_agent_dispatch "s4f" "quality-reviewer")"
second_same_role="$(_drive_agent_dispatch "s4f" "quality-reviewer")"
different_role="$(_drive_agent_dispatch "s4f" "excellence-reviewer")"
assert_eq "T4f: initial same-role review is allowed" "" "${first_same_role}"
assert_contains "T4f: duplicate in-flight same-role review is denied" \
  '"permissionDecision":"deny"' "${second_same_role}"
assert_eq "T4f: different reviewer role remains parallel" "" "${different_role}"

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
