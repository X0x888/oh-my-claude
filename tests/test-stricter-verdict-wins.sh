#!/usr/bin/env bash
# Regression net for v1.44-pre Port 2 — stricter-verdict-wins invariant.
#
# Covers two mechanisms working together:
#   1. Storage-side: tick_dimensions_with_verdict / set_dimension_verdicts
#      route through _write_stricter_dim_verdicts_unlocked, which preserves
#      the stricter of (current, new) verdict on a CLEAN < FINDINGS < BLOCK
#      severity ladder. Edit-aware: stale FINDINGS (ts < last_code_edit_ts)
#      is replaced by a fresh CLEAN — fix-and-re-review path must clear.
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
  local payload
  payload="$(jq -nc --arg sid "${sid}" --arg msg "${message}" \
    '{session_id:$sid, last_assistant_message:$msg}')"
  HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" "${reviewer_type}" \
    <<<"${payload}" >/dev/null 2>&1 || true
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
