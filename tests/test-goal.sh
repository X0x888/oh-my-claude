#!/usr/bin/env bash
# Regression net for the /goal relentless-driver feature (Codex /goal port,
# the user-facing VOLUNTARY sibling of the objective-contract gate).
#
# Four surfaces:
#   1. goal.sh lifecycle (real script): set / status / pause / resume /
#      clear / done / empty-reject / forgiving bare-objective path / redact.
#   2. A faithful inline simulation of the stop-guard GOAL driver decision
#      (the stuck-wall hazard proof). KEEP IN SYNC with the goal branch in
#      stop-guard.sh and the has_closeout_label coverage pattern.
#   3. Lockstep grep: stop-guard.sh's has_closeout_label coverage pattern
#      accepts the **Goal achieved.** alias (has_closeout_label lives in
#      stop-guard.sh, not common.sh, so it cannot be called directly here —
#      same approach test-objective-contract.sh uses for its drift guard).
#   4. End-to-end through the REAL stop-guard.sh (OMC_GATE_LEVEL=basic, the
#      F-014 pattern): the goal driver blocks relentlessly, releases on
#      coverage+fresh-audit, stays inert when paused / ulw-paused, surfaces-
#      and-releases at the stuck-wall, keeps blocking while progress is made,
#      and takes precedence over the substantive arm (no double-fire).
#      Negative cases assert the GOAL gate specifically did not fire
#      ("Persistent goal active" absent) rather than "no block at all",
#      because the minimal test message can legitimately trip a downstream
#      closure gate unrelated to the goal driver.
#
# Hermeticity: every real-script drive isolates HOME (not just STATE_ROOT) to
# a temp tree. goal.sh / stop-guard.sh source common.sh, whose cross-session
# locks + writes live under ~/.claude/quality-pack/ (HOME-based). Isolating
# HOME keeps this test immune to a live session or a parallel test run
# touching the real ~/.claude concurrently.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
# shellcheck disable=SC1091
source "${HOOK_DIR}/common.sh"

GOAL_SH="${HOOK_DIR}/goal.sh"
STOP_GUARD="${HOOK_DIR}/stop-guard.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }

# ===========================================================================
# Section 1 — goal.sh lifecycle (real script drive)
# ===========================================================================
printf -- '-- Section 1: goal.sh lifecycle --\n'

s1_root="$(mktemp -d)"
run_goal() { HOME="${s1_root}" STATE_ROOT="${s1_root}" SESSION_ID="goal-test-s1" bash "${GOAL_SH}" "$@" 2>&1; }
goal_state() {
  python3 -c "import json,glob; f=glob.glob('${s1_root}/*/session_state.json'); d=json.load(open(f[0])) if f else {}; print(d.get('$1',''))"
}

run_goal set "migrate the auth layer to OAuth2 and make all tests pass" >/dev/null
[[ "$(goal_state goal_mode_active)" == "1" ]] && pass || fail "S1: set did not arm goal_mode_active"
[[ "$(goal_state goal_objective)" == "migrate the auth layer to OAuth2 and make all tests pass" ]] && pass || fail "S1: objective not stored"
# Counters stored as STRINGS (read_state_keys returns empty for raw JSON numbers).
[[ "$(goal_state goal_blocks)" == "0" ]] && pass || fail "S1: goal_blocks not seeded to string 0"

run_goal pause >/dev/null
[[ "$(goal_state goal_paused)" == "1" ]] && pass || fail "S1: pause did not set goal_paused"
run_goal resume >/dev/null
[[ "$(goal_state goal_paused)" == "" ]] && pass || fail "S1: resume did not clear goal_paused"

# Capture-then-match (NOT `run_goal status | grep -q`): goal.sh status prints
# 3 lines; a `| grep -q` consumer exits on the first match and closes the pipe,
# so goal.sh's next printf takes SIGPIPE → exits 141, and `set -o pipefail`
# fails the pipeline DESPITE the match. That race flaked this line ~64% under
# tight-loop timing. Matching a captured string has no live pipe to break.
_s1_status="$(run_goal status)"; _s1_rc=$?
case "${_s1_status}" in
  *ARMED*) [[ "${_s1_rc}" -eq 0 ]] && pass || fail "S1: status reported ARMED but exited rc=${_s1_rc}" ;;
  *) fail "S1: status did not report ARMED (rc=${_s1_rc})" ;;
esac

run_goal clear >/dev/null
[[ "$(goal_state goal_mode_active)" == "" ]] && pass || fail "S1: clear did not wipe goal_mode_active"

# done clears too + records achievement ("done" quoted: it's a bash keyword).
run_goal set "ship it" >/dev/null
# Capture-then-match (same SIGPIPE+pipefail race as the status check above).
_s1_done="$(run_goal "done" "all green")"; _s1_done_rc=$?
case "${_s1_done}" in
  *ACHIEVED*) [[ "${_s1_done_rc}" -eq 0 ]] && pass || fail "S1: done reported ACHIEVED but exited rc=${_s1_done_rc}" ;;
  *) fail "S1: done did not report ACHIEVED (rc=${_s1_done_rc})" ;;
esac
[[ "$(goal_state goal_mode_active)" == "" ]] && pass || fail "S1: done did not wipe goal state"

# empty objective rejected (exit 2).
HOME="${s1_root}" STATE_ROOT="${s1_root}" SESSION_ID="goal-test-s1" bash "${GOAL_SH}" set "   " >/dev/null 2>&1 && rc=0 || rc=$?
[[ "${rc}" -eq 2 ]] && pass || fail "S1: empty set not rejected with exit 2 (got ${rc})"

# forgiving bare-objective path (no explicit 'set' verb).
run_goal "build the dashboard" >/dev/null
[[ "$(goal_state goal_objective)" == "build the dashboard" ]] && pass || fail "S1: bare-objective forgiving path did not set"
run_goal clear >/dev/null

# pause with no active goal → exit 2.
HOME="${s1_root}" STATE_ROOT="${s1_root}" SESSION_ID="goal-test-s1" bash "${GOAL_SH}" pause >/dev/null 2>&1 && rc=0 || rc=$?
[[ "${rc}" -eq 2 ]] && pass || fail "S1: pause with no goal should exit 2 (got ${rc})"

# secret redaction in the objective.
run_goal set "deploy with --api-key sk-ant-abcdefghijklmnop1234567890 now" >/dev/null
case "$(goal_state goal_objective)" in
  *redacted*) pass ;;
  *) fail "S1: objective secret not redacted" ;;
esac
rm -rf "${s1_root}"

# ===========================================================================
# Section 2 — inline faithful GOAL-driver simulation (stuck-wall hazard proof)
# KEEP IN SYNC with the goal branch in stop-guard.sh.
# ===========================================================================
printf -- '-- Section 2: goal-driver decision simulation --\n'

# Mirror has_closeout_label coverage (with the **Goal achieved.** alias).
_goal_coverage_present() {
  printf '%s' "$1" | grep -Eiq '\*\*(Objective (coverage|audit)|Goal achieved)(\.)?\*\*'
}

# Echoes: inert | release | wall | block
# Args: prompt_ts last_edit_ts audited_ts goal_obj coverage_msg fresh_audit_ts
#       stuck_in last_block_edit_ts threshold paused ulw_pause
run_goal_driver() {
  local prompt_ts="$1" last_edit_ts="$2" audited_ts="$3" goal_obj="$4"
  local coverage_msg="$5" fresh_audit_ts="$6" stuck_in="$7"
  local last_block_edit_ts="$8" threshold="$9" paused="${10}" ulw_pause="${11}"
  [[ -n "${goal_obj}" ]] || { echo inert; return; }
  [[ "${paused}" != "1" ]] || { echo inert; return; }
  [[ "${ulw_pause}" != "1" ]] || { echo inert; return; }
  [[ "${prompt_ts}" -gt 0 ]] || { echo inert; return; }
  [[ "${last_edit_ts}" -gt "${prompt_ts}" ]] || { echo inert; return; }
  [[ "${audited_ts}" -le "${prompt_ts}" ]] || { echo inert; return; }
  if _goal_coverage_present "${coverage_msg}" && [[ "${fresh_audit_ts}" -gt "${prompt_ts}" ]]; then
    echo release; return
  fi
  local stuck="${stuck_in}"
  if [[ "${last_edit_ts}" -gt "${last_block_edit_ts}" ]]; then
    stuck=0
  else
    stuck=$((stuck + 1))
  fi
  if [[ "${threshold}" -gt 0 && "${stuck}" -ge "${threshold}" ]]; then
    echo wall; return
  fi
  echo block
}

[[ "$(run_goal_driver 100 200 0 "goal" "" 0 0 0 3 "" "")" == "block" ]] && pass || fail "S2: armed-no-coverage should block"
[[ "$(run_goal_driver 100 200 0 "goal" "**Goal achieved.**" 300 0 0 3 "" "")" == "release" ]] && pass || fail "S2: goal-achieved+audit should release"
[[ "$(run_goal_driver 100 200 0 "goal" "**Objective coverage.**" 300 0 0 3 "" "")" == "release" ]] && pass || fail "S2: objective-coverage alias should release"
[[ "$(run_goal_driver 100 200 0 "goal" "**Goal achieved.**" 50 0 0 3 "" "")" == "block" ]] && pass || fail "S2: coverage-without-fresh-audit should block"
[[ "$(run_goal_driver 100 200 0 "goal" "**Goal achieved.**" 100 0 0 3 "" "")" == "block" ]] && pass || fail "S2: self-attestation alone (audit==prompt) should not release"
# STUCK-WALL: 2 prior no-progress blocks + another no-progress stop = 3 → wall.
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 2 200 3 "" "")" == "wall" ]] && pass || fail "S2: 3 consecutive no-progress should hit stuck-wall"
# PROGRESS resets the stuck counter — a grinding model is NEVER released by cap.
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 2 150 3 "" "")" == "block" ]] && pass || fail "S2: progress between blocks should reset stuck counter (block, not wall)"
# threshold=0 disables the wall (uncapped relentless until done).
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 99 200 0 "" "")" == "block" ]] && pass || fail "S2: threshold=0 should never wall"
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 0 0 3 "1" "")" == "inert" ]] && pass || fail "S2: paused goal should be inert"
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 0 0 3 "" "1")" == "inert" ]] && pass || fail "S2: ulw_pause should make goal inert"
[[ "$(run_goal_driver 100 100 0 "goal" "" 0 0 0 3 "" "")" == "inert" ]] && pass || fail "S2: no-work-this-cycle should be inert"

# ===========================================================================
# Section 3 — lockstep grep: stop-guard has_closeout_label accepts the alias.
# ===========================================================================
printf -- '-- Section 3: stop-guard coverage-pattern lockstep --\n'
grep -q 'Objective (coverage|audit)|Goal achieved' "${STOP_GUARD}" && pass || fail "S3: stop-guard coverage pattern missing the **Goal achieved.** alias"
grep -q 'Goal achieved' "${STOP_GUARD}" && pass || fail "S3: **Goal achieved.** not present in stop-guard.sh"

# ===========================================================================
# Section 4 — end-to-end through the REAL stop-guard.sh (OMC_GATE_LEVEL=basic).
# ===========================================================================
printf -- '-- Section 4: e2e real stop-guard goal driver --\n'

E2E_ROOT=""; E2E_SID="goal-e2e"
write_state_field() {
  local k="$1" v="$2" f="${STATE_ROOT}/${E2E_SID}/session_state.json"
  jq --arg k "${k}" --arg v "${v}" '.[$k]=$v' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
}

e2e_seed() {
  write_state_field "task_intent" "execution"
  write_state_field "prompt_classified_intent" "execution"
  write_state_field "last_user_prompt_ts" "100"
  write_state_field "last_edit_ts" "200"
  write_state_field "last_code_edit_ts" "150"
  write_state_field "last_review_ts" "300"
  write_state_field "last_verify_ts" "300"
  write_state_field "last_verify_outcome" "passed"
  write_state_field "last_verify_confidence" "80"
  # code_edit_count=1 is NOT substantive (default min_files=4) — proves the
  # goal arm fires UNCONDITIONALLY (user-armed), not via the volume arm.
  write_state_field "code_edit_count" "1"
  write_state_field "doc_edit_count" "0"
  write_state_field "objective_contract_edit_baseline" "0"
  write_state_field "objective_contract_prompt_ts" "100"
  write_state_field "objective_contract_audited_ts" ""
  write_state_field "objective_contract_blocks" "0"
}

# drive_goal <setup_fn> <assistant_msg> → echoes the stop-guard output.
# Full HOME isolation (see header) + deterministic SESSION_ID.
drive_goal() {
  local setup_fn="$1" msg="${2:-Done. Wired the handler.}"
  E2E_ROOT="$(mktemp -d)"
  export HOME="${E2E_ROOT}"
  export STATE_ROOT="${E2E_ROOT}/.claude/quality-pack/state" SESSION_ID="${E2E_SID}"
  mkdir -p "${STATE_ROOT}/${E2E_SID}"
  printf '{"workflow_mode":"ultrawork"}\n' > "${STATE_ROOT}/${E2E_SID}/session_state.json"
  e2e_seed
  "${setup_fn}"
  jq -n --arg sid "${E2E_SID}" --arg msg "${msg}" \
    '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
    | OMC_GATE_LEVEL=basic bash "${STOP_GUARD}" 2>/dev/null || true
  rm -rf "${E2E_ROOT}"
}

is_block() { printf '%s' "$1" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; }
fired_goal() { printf '%s' "$1" | grep -q 'Persistent goal active'; }

# Goal armed, work this cycle, NO coverage → relentless block (unconditional arm).
gb_block() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the entire auth subsystem to OAuth2 across all services"
}
out="$(drive_goal gb_block "Done. Wired one handler.")"
is_block "${out}" && pass || fail "S4: goal driver did not block (unconditional arm) on missing coverage"
fired_goal "${out}" && pass || fail "S4: goal block message missing 'Persistent goal active'"

# Goal armed + **Goal achieved.** + fresh audit → goal gate releases (does NOT
# fire). A downstream closure gate may still block the minimal message, so we
# assert the GOAL gate specifically did not fire.
gb_release() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the entire auth subsystem to OAuth2 across all services"
  write_state_field "last_excellence_review_ts" "350"
}
out="$(drive_goal gb_release "All services migrated, suite green. **Goal achieved.**")"
fired_goal "${out}" && fail "S4: goal gate still fired despite **Goal achieved.** + fresh audit" || pass

# Paused goal → goal gate inert.
gb_paused() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_paused" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
}
out="$(drive_goal gb_paused "Done. one handler.")"
fired_goal "${out}" && fail "S4: paused goal gate still fired" || pass

# ulw_pause_active → goal gate inert (operational pause beats relentlessness).
gb_ulwpause() {
  write_state_field "goal_mode_active" "1"
  write_state_field "ulw_pause_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
}
out="$(drive_goal gb_ulwpause "Done. one handler.")"
fired_goal "${out}" && fail "S4: ulw-paused goal gate still fired" || pass

# STUCK-WALL e2e: 2 prior no-progress blocks + this no-progress stop → surface
# + release (NOT a decision:block; the goal branch exits 0 after surfacing).
gb_stuckwall() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "goal_stuck_blocks" "2"
  write_state_field "goal_last_block_edit_ts" "200"
}
out="$(drive_goal gb_stuckwall "Still stuck, no edits this round.")"
is_block "${out}" && fail "S4: stuck-wall should release (surface), not block" || pass
printf '%s' "${out}" | grep -qi 'stuck-wall' && pass || fail "S4: stuck-wall surface message not emitted"

# PROGRESS between blocks keeps blocking (never released by cap while grinding).
gb_progress() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "goal_stuck_blocks" "2"
  write_state_field "goal_last_block_edit_ts" "150"
}
out="$(drive_goal gb_progress "Made progress, edited another file.")"
is_block "${out}" && pass || fail "S4: progress-since-last-block should keep blocking (relentless)"
fired_goal "${out}" && pass || fail "S4: progress block should be the goal gate"

# NO-DOUBLE-FIRE: goal + substantive both true → goal precedence (one block,
# the goal message, not the objective-contract message).
gb_precedence() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "current_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "plan_complexity_high" "1"
}
out="$(drive_goal gb_precedence "Done. one handler.")"
if is_block "${out}" && fired_goal "${out}" \
  && ! printf '%s' "${out}" | grep -q 'Objective-contract gate'; then
  pass
else
  fail "S4: goal+substantive should fire ONE goal block (precedence), not the objective-contract block"
fi

# ---------------------------------------------------------------------------
printf '\n== test-goal: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
