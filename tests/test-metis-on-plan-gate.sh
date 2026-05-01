#!/usr/bin/env bash
# Tests for the v1.19.0 metis-on-plan stop-guard gate (Check 6).
#
# Gate semantics:
#   Fires when OMC_METIS_ON_PLAN_GATE=on AND a complex plan exists
#   (plan_complexity_high=1, has_plan=true) AND metis has not run since
#   the plan was recorded (last_metis_review_ts < plan_ts) AND the
#   per-plan block cap (1) is not exhausted.
#
#   Block cap resets on every fresh plan because record-plan.sh writes
#   metis_gate_blocks="" alongside the new plan_ts. This makes the gate
#   reusable across plan iterations within a single session.
#
# This test sandboxes HOME so the stop-guard's `${HOME}/.claude/...`
# source paths resolve to the dev tree, then synthesizes prior state in
# session_state.json and drives the stop-guard end-to-end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_test_home="$(mktemp -d -t metis-gate-home-XXXXXX)"
_test_state_root="${_test_home}/state"
mkdir -p "${_test_home}/.claude/quality-pack" "${_test_state_root}"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills" "${_test_home}/.claude/skills"
# Symlink only the read-only subdirs (scripts, memory) so cross-session
# telemetry files (agent-metrics.json, gate-skips.jsonl) write into the
# per-test home rather than leaking into the dev tree.
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${_test_home}/.claude/quality-pack/scripts"
ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/memory" "${_test_home}/.claude/quality-pack/memory"

ORIG_HOME="${HOME}"
export HOME="${_test_home}"
export STATE_ROOT="${_test_state_root}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

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
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  FAIL: %s\n    unexpected needle=%q in haystack\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

_cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${_test_home}"
}
trap _cleanup EXIT

# Synthesize a session state that satisfies all the prior gates (review
# clock current, verification clock current) and lets us focus the test
# on the metis-on-plan gate. The "all gates pass" path is the one that
# reaches Check 6.
_setup_session() {
  local sid="$1"
  local plan_complexity_high="$2"
  local plan_ts="$3"
  local last_metis_review_ts="$4"
  local metis_gate_blocks="${5:-}"

  local sdir="${_test_state_root}/${sid}"
  mkdir -p "${sdir}"

  local now last_edit
  now="$(date +%s)"
  last_edit=$((now - 60))

  jq -nc \
    --arg has_plan "true" \
    --arg pch "${plan_complexity_high}" \
    --arg pts "${plan_ts}" \
    --arg pcs "steps=8,files=5,waves=3,keywords=migration" \
    --arg lmrt "${last_metis_review_ts}" \
    --arg mgb "${metis_gate_blocks}" \
    --arg lrt "${last_edit}" \
    --arg lvt "${last_edit}" \
    --arg lvc "70" \
    --arg led "${last_edit}" \
    --arg lect "${last_edit}" \
    --arg wfm "ultrawork" \
    --arg ti "execution" \
    '{
      has_plan: $has_plan,
      plan_complexity_high: $pch,
      plan_ts: $pts,
      plan_complexity_signals: $pcs,
      last_metis_review_ts: $lmrt,
      metis_gate_blocks: $mgb,
      last_review_ts: $lrt,
      last_verify_ts: $lvt,
      last_verify_outcome: "passed",
      last_verify_confidence: $lvc,
      last_edit_ts: $led,
      last_excellence_review_ts: $lect,
      review_had_findings: "false",
      workflow_mode: $wfm,
      task_intent: $ti,
      task_domain: "coding"
    }' >"${sdir}/session_state.json"

  # Pretend at least one file was edited so the various edit-count
  # checks exit predictably.
  printf 'fake/file.sh\n' >"${sdir}/edited_files.log"
}

_run_stop_guard() {
  local sid="$1"
  shift
  local env_args=("$@")

  local hook_json
  hook_json="$(jq -nc --arg sid "${sid}" '{session_id:$sid}')"

  HOME="${_test_home}" \
    STATE_ROOT="${_test_state_root}" \
    env ${env_args[@]+"${env_args[@]}"} \
    bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh" \
    <<<"${hook_json}" 2>/dev/null \
    || true
}

_read_state() {
  local sid="$1" key="$2"
  local sf="${_test_state_root}/${sid}/session_state.json"
  [[ -f "${sf}" ]] || { printf ''; return; }
  jq -r --arg k "${key}" '.[$k] // ""' "${sf}" 2>/dev/null || true
}

# ----------------------------------------------------------------------
printf 'Test 1: gate OFF — no metis block emitted\n'
sid="t1-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" ""
out="$(_run_stop_guard "${sid}")"
assert_not_contains "no metis block when flag off" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: gate ON + complex plan + no metis → block fires\n'
sid="t2-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_contains "metis block fires" "Metis-on-plan gate" "${out}"
assert_contains "block names complexity" "high-complexity" "${out}"
assert_contains "block names metis"    "metis"            "${out}"
assert_eq "metis_gate_blocks incremented" "1" "$(_read_state "${sid}" "metis_gate_blocks")"

# ----------------------------------------------------------------------
printf 'Test 3: gate ON + simple plan → no block\n'
sid="t3-${RANDOM}"
_setup_session "${sid}" "" "1000" "" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_not_contains "no block on simple plan" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: gate ON + complex plan + metis ran AFTER plan_ts → no block\n'
sid="t4-${RANDOM}"
# plan_ts=1000, metis_ts=2000 (after) → satisfied, no block
_setup_session "${sid}" "1" "1000" "2000" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_not_contains "no block when metis ran after plan" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: gate ON + complex plan + metis ran BEFORE plan_ts → block (stale)\n'
sid="t5-${RANDOM}"
# plan_ts=2000, metis_ts=1000 (before) → stale, must re-run metis
_setup_session "${sid}" "1" "2000" "1000" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_contains "block on stale metis" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: gate ON + complex plan + metis_gate_blocks=1 → no block (cap reached)\n'
sid="t6-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" "1"
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_not_contains "no block when cap reached" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7: gate ON + complex plan + /ulw-skip flag → no block (gate-skip wins)\n'
sid="t7-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" ""
# Inject the gate-skip token. Both the reason AND a gate_skip_edit_ts
# >= last_edit_ts are required — stop-guard invalidates the skip if
# any edits happened after the user pressed /ulw-skip.
sdir="${_test_state_root}/${sid}"
last_edit_ts="$(_read_state "${sid}" "last_edit_ts")"
jq --arg le "${last_edit_ts}" '. + {gate_skip_reason: "intentionally simple plan", gate_skip_edit_ts: $le}' \
  "${sdir}/session_state.json" >"${sdir}/session_state.json.new" \
  && mv "${sdir}/session_state.json.new" "${sdir}/session_state.json"
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_not_contains "no block on /ulw-skip" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: record-reviewer.sh writes last_metis_review_ts on stress_test reviewer\n'
# Touch the live ulw_active sentinel so record-reviewer.sh does not exit on
# its fast-path.
sentinel_dir="${_test_home}/.claude/quality-pack/state"
mkdir -p "${sentinel_dir}"
touch "${sentinel_dir}/.ulw_active"
sid="t8-${RANDOM}"
sdir="${_test_state_root}/${sid}"
mkdir -p "${sdir}"
jq -nc --arg wfm "ultrawork" '{workflow_mode: $wfm}' >"${sdir}/session_state.json"

reviewer_payload="$(jq -nc \
  --arg sid "${sid}" \
  --arg msg 'Plan stress-test complete. Found 3 hidden assumptions worth flagging.

VERDICT: CLEAN' \
  '{session_id:$sid, last_assistant_message:$msg, agent_type:"metis"}')"

HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" stress_test \
  <<<"${reviewer_payload}" >/dev/null 2>&1 || true

assert_contains "last_metis_review_ts present" \
  "$(date +%s | head -c 4)" \
  "$(_read_state "${sid}" "last_metis_review_ts")"
rm -f "${sentinel_dir}/.ulw_active"

# ----------------------------------------------------------------------
printf 'Test 9: record-plan.sh resets metis_gate_blocks on new plan\n'
sid="t9-${RANDOM}"
sdir="${_test_state_root}/${sid}"
mkdir -p "${sdir}"
# Pre-seed metis_gate_blocks=1 from a prior plan cycle.
printf '{"metis_gate_blocks":"1"}' >"${sdir}/session_state.json"

plan_payload="$(jq -nc \
  --arg sid "${sid}" \
  --arg msg "1. Step one
2. Step two
3. Step three
4. Step four
5. Step five
6. Step six

VERDICT: PLAN_READY" \
  '{session_id:$sid, last_assistant_message:$msg, agent_type:"quality-planner"}')"

HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh" \
  <<<"${plan_payload}" >/dev/null 2>&1 || true

assert_eq "metis_gate_blocks reset on new plan" "" "$(_read_state "${sid}" "metis_gate_blocks")"
assert_eq "plan_complexity_high set"            "1" "$(_read_state "${sid}" "plan_complexity_high")"

# ----------------------------------------------------------------------
printf 'Test 10: independent of OMC_GATE_LEVEL — fires on basic level\n'
sid="t10-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on" "OMC_GATE_LEVEL=basic")"
assert_contains "metis fires on basic gate level" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 11: last_metis_review_ts == plan_ts → block (treated as stale)\n'
# Reviewer-flagged equality case: metis at the same epoch second as the
# plan is either a same-second race or a metis run on a prior plan
# whose ts happens to match. Either way, require a fresh metis run.
sid="t11-${RANDOM}"
_setup_session "${sid}" "1" "1000" "1000" ""
out="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_contains "block when metis_ts == plan_ts" "Metis-on-plan gate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 12: full lifecycle — block → run metis → re-stop passes\n'
# End-to-end chain that test 6 only stubs in pieces. Drives:
#   1. fresh complex plan, no metis → stop blocks (cap goes 0→1)
#   2. metis stress_test review fires → last_metis_review_ts written
#   3. second stop attempt → metis fresh, gate releases
sentinel_dir2="${_test_home}/.claude/quality-pack/state"
mkdir -p "${sentinel_dir2}"
touch "${sentinel_dir2}/.ulw_active"
sid="t12-${RANDOM}"
_setup_session "${sid}" "1" "1000" "" ""
out1="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_contains "lifecycle step 1 blocks" "Metis-on-plan gate" "${out1}"
assert_eq "lifecycle step 1 increments cap" "1" "$(_read_state "${sid}" "metis_gate_blocks")"

# Run a metis stress_test review in the same session.
metis_payload="$(jq -nc \
  --arg sid "${sid}" \
  --arg msg 'Stress-tested the plan.

VERDICT: CLEAN' \
  '{session_id:$sid, last_assistant_message:$msg, agent_type:"metis"}')"
HOME="${_test_home}" \
  STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-reviewer.sh" stress_test \
  <<<"${metis_payload}" >/dev/null 2>&1 || true

# last_metis_review_ts should now be > plan_ts (1000)
metis_ts="$(_read_state "${sid}" "last_metis_review_ts")"
[[ -n "${metis_ts}" && "${metis_ts}" -gt 1000 ]] && \
  pass=$((pass + 1)) || \
  { printf '  FAIL: lifecycle metis_ts not > plan_ts (got=%q)\n' "${metis_ts}" >&2; fail=$((fail + 1)); }

# Re-stop — gate should release. The cap is also at 1, but with
# metis_stale_or_missing=0, the gate condition is false regardless.
out2="$(_run_stop_guard "${sid}" "OMC_METIS_ON_PLAN_GATE=on")"
assert_not_contains "lifecycle step 3 passes" "Metis-on-plan gate" "${out2}"
rm -f "${sentinel_dir2}/.ulw_active"

# ----------------------------------------------------------------------
printf 'Test 13: soft-nudge handoff — record-plan sets pending flag, reflect-after-agent surfaces it as PostToolUse additionalContext, then clears it (one-shot)\n'
# Regression net for the SubagentStop additionalContext silent-drop bug:
# record-plan.sh used to emit `hookSpecificOutput.additionalContext` from
# a SubagentStop hook (which Claude Code drops silently). The fix moves
# the soft nudge to a state handoff: record-plan sets
# plan_complexity_nudge_pending="1", and reflect-after-agent.sh (a
# PostToolUse Agent hook where additionalContext IS supported) reads
# the flag, surfaces the notice, and clears the flag. One-shot per
# high-complexity plan.

sid="su13-handoff"
sdir13="${_test_state_root}/${sid}"
mkdir -p "${sdir13}"

# Sentinel for reflect-after-agent.sh's fast-path check.
mkdir -p "${_test_home}/.claude/quality-pack/state"
touch "${_test_home}/.claude/quality-pack/state/.ulw_active"

# Synthesize a high-complexity plan body so _compute_plan_complexity sets
# _plan_complexity_high="1". Eight numbered steps, five files, two waves.
plan_body='# Plan
1. Read src/foo.ts
2. Update src/bar.tsx
3. Test src/baz.js
4. Refactor src/qux.py
5. Validate src/zap.go
6. Document docs/note.md
7. Wave 1/2: ship
8. Wave 2/2: verify'

# Pre-create session_state.json with workflow_mode=ultrawork (record-plan
# uses with_state_lock_batch which expects the file to exist).
jq -nc '{
  workflow_mode: "ultrawork",
  task_intent: "execution",
  task_domain: "coding"
}' >"${sdir13}/session_state.json"

# Drive record-plan.sh
HOOK_JSON="$(jq -nc --arg sid "${sid}" --arg agent "quality-planner" --arg msg "${plan_body}" \
  '{session_id:$sid, agent_type:$agent, last_assistant_message:$msg}')"
HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh" \
  <<<"${HOOK_JSON}" >/dev/null 2>&1 || true

# State assertion: nudge flag set, plan high
assert_eq "T13: plan_complexity_high=1 after record-plan" "1" "$(_read_state "${sid}" "plan_complexity_high")"
assert_eq "T13: plan_complexity_nudge_pending=1 after record-plan" "1" "$(_read_state "${sid}" "plan_complexity_nudge_pending")"

# Drive reflect-after-agent.sh
RA_PAYLOAD="$(jq -nc --arg sid "${sid}" '{session_id:$sid, tool_name:"Agent"}')"
ra_out1="$(HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/reflect-after-agent.sh" \
  <<<"${RA_PAYLOAD}" 2>/dev/null || true)"

assert_contains "T13: reflect-after-agent surfaces PLAN COMPLEXITY NOTICE" "PLAN COMPLEXITY NOTICE" "${ra_out1}"
assert_contains "T13: notice carries the signals string" "steps=8" "${ra_out1}"
assert_contains "T13: notice goes via additionalContext (PostToolUse-supported field)" "additionalContext" "${ra_out1}"
assert_eq "T13: plan_complexity_nudge_pending cleared after emission" "" "$(_read_state "${sid}" "plan_complexity_nudge_pending")"

# Run reflect-after-agent.sh AGAIN — no nudge should appear (one-shot).
ra_out2="$(HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/reflect-after-agent.sh" \
  <<<"${RA_PAYLOAD}" 2>/dev/null || true)"
assert_not_contains "T13: second reflect-after-agent does NOT re-emit the notice" "PLAN COMPLEXITY NOTICE" "${ra_out2}"

# Schema-regression net: record-plan must NOT use the silently-dropped
# hookSpecificOutput schema. (It now writes state only — no JSON to stdout.)
record_plan_stdout="$(HOME="${_test_home}" STATE_ROOT="${_test_state_root}" \
  bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-plan.sh" \
  <<<"${HOOK_JSON}" 2>/dev/null || true)"
assert_not_contains "T13: record-plan does NOT emit dropped Stop/SubagentStop additionalContext" "hookSpecificOutput" "${record_plan_stdout}"

rm -f "${_test_home}/.claude/quality-pack/state/.ulw_active"

# ----------------------------------------------------------------------
printf '\n'
printf 'Result: %d passed, %d failed\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
