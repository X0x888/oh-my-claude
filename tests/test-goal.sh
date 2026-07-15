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

# Interrupt hygiene: every section mktemp-roots its own tree and rm -rf's it
# inline; the trap covers the kill/ctrl-C window so no temp trees leak.
trap 'rm -rf "${s1_root:-}" "${s7_root:-}" "${E2E_ROOT:-}" "${S8_ROOT:-}"' EXIT

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

# v1.47 dormancy honesty: status reports ARMED only inside ultrawork mode.
# Arm the mode in this fixture (mirrors a real /goal session — the command
# itself is a ULW activation trigger now); the dormant path is Section 7.
_s1_state="${s1_root}/goal-test-s1/session_state.json"
jq '.workflow_mode="ultrawork"' "${_s1_state}" > "${_s1_state}.tmp" && mv "${_s1_state}.tmp" "${_s1_state}"

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
[[ "$(goal_state goal_last_block_edit_revision)" == "" ]] && pass || fail "S1: clear did not wipe goal progress revision"

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
  printf '%s\n' "$1" | grep -Eiq \
    '^[[:space:]]{0,3}\*\*(Objective (coverage|audit)|Goal achieved)(\.)?\*\*[[:space:]]*'
}

# Echoes: inert | release | wall | block
# Args: prompt_ts last_edit_ts audited_ts goal_obj coverage_msg fresh_audit_ts
#       stuck_in last_block_edit_ts threshold paused ulw_pause
#       [edit_revision edit_revision_base last_block_revision
#        completeness_verdict completeness_revision]
run_goal_driver() {
  local prompt_ts="$1" last_edit_ts="$2" audited_ts="$3" goal_obj="$4"
  local coverage_msg="$5" fresh_audit_ts="$6" stuck_in="$7"
  local last_block_edit_ts="$8" threshold="$9" paused="${10}" ulw_pause="${11}"
  local edit_revision="${12:-}" edit_revision_base="${13:-}"
  local last_block_revision="${14:-}" completeness_verdict="${15:-}"
  local completeness_revision="${16:-}" work_this_cycle=0 fresh_clean_audit=0
  [[ -n "${goal_obj}" ]] || { echo inert; return; }
  [[ "${paused}" != "1" ]] || { echo inert; return; }
  [[ "${ulw_pause}" != "1" ]] || { echo inert; return; }
  [[ "${prompt_ts}" -gt 0 ]] || { echo inert; return; }
  if [[ "${edit_revision}" =~ ^[0-9]+$ ]] \
      && [[ "${edit_revision_base}" =~ ^[0-9]+$ ]]; then
    (( edit_revision > edit_revision_base )) && work_this_cycle=1
  elif [[ "${last_edit_ts}" -gt "${prompt_ts}" ]]; then
    work_this_cycle=1
  fi
  [[ "${work_this_cycle}" -eq 1 ]] || { echo inert; return; }
  [[ "${audited_ts}" -le "${prompt_ts}" ]] || { echo inert; return; }
  case "${completeness_verdict}" in
    CLEAN|SHIP)
      if [[ "${edit_revision}" =~ ^[0-9]+$ ]] \
          && [[ "${edit_revision_base}" =~ ^[0-9]+$ ]] \
          && [[ "${completeness_revision}" =~ ^[0-9]+$ ]] \
          && (( completeness_revision >= edit_revision )) \
          && (( completeness_revision > edit_revision_base )); then
        fresh_clean_audit=1
      elif [[ ! "${edit_revision}" =~ ^[0-9]+$ ]] \
          && [[ "${fresh_audit_ts}" -gt "${prompt_ts}" ]]; then
        fresh_clean_audit=1
      fi
      ;;
  esac
  if _goal_coverage_present "${coverage_msg}" && [[ "${fresh_clean_audit}" -eq 1 ]]; then
    echo release; return
  fi
  local stuck="${stuck_in}"
  if [[ "${edit_revision}" =~ ^[0-9]+$ ]] \
      && [[ "${last_block_revision}" =~ ^[0-9]+$ ]]; then
    if (( edit_revision > last_block_revision )); then
      stuck=0
    else
      stuck=$((stuck + 1))
    fi
  elif [[ "${last_edit_ts}" -gt "${last_block_edit_ts}" ]]; then
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
[[ "$(run_goal_driver 100 200 0 "goal" "**Goal achieved.**" 300 0 0 3 "" "" 1 0 "" CLEAN 1)" == "release" ]] && pass || fail "S2: goal-achieved+clean-audit should release"
[[ "$(run_goal_driver 100 200 0 "goal" "**Objective coverage.**" 300 0 0 3 "" "" 1 0 "" SHIP 1)" == "release" ]] && pass || fail "S2: objective-coverage+ship-audit alias should release"
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
[[ "$(run_goal_driver 100 100 0 "goal" "" 0 0 0 3 "" "" 1 0)" == "block" ]] && pass || fail "S2: same-second work arms via revision"
[[ "$(run_goal_driver 100 200 0 "goal" "" 0 2 200 3 "" "" 2 0 1)" == "block" ]] && pass || fail "S2: same-second progress resets via revision"
[[ "$(run_goal_driver 100 200 0 "goal" "**Goal achieved.**" 300 0 0 3 "" "" 1 0 "" FINDINGS 1)" == "block" ]] && pass || fail "S2: current FINDINGS audit does not release"

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
  write_state_field "objective_contract_edit_revision_base" "0"
  write_state_field "objective_contract_prompt_ts" "100"
  write_state_field "edit_revision" "1"
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
  write_state_field "dim_completeness_ts" "350"
  write_state_field "dim_completeness_revision" "1"
  write_state_field "dim_completeness_verdict" "CLEAN"
}
out="$(drive_goal gb_release $'All services migrated, suite green.\n\n**Goal achieved.**')"
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
  write_state_field "goal_last_block_edit_revision" "1"
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
  write_state_field "goal_last_block_edit_revision" "0"
}
out="$(drive_goal gb_progress "Made progress, edited another file.")"
is_block "${out}" && pass || fail "S4: progress-since-last-block should keep blocking (relentless)"
fired_goal "${out}" && pass || fail "S4: progress block should be the goal gate"

# Same-second objective arming and goal progress use revisions, not wall time.
gb_same_second_arm() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "last_edit_ts" "100"
}
out="$(drive_goal gb_same_second_arm "Same-second edit landed.")"
is_block "${out}" && pass || fail "S4: same-second edit should arm goal via revision"
fired_goal "${out}" && pass || fail "S4: same-second revision arm should be the goal gate"

gb_same_second_progress() {
  write_state_field "goal_mode_active" "1"
  write_state_field "goal_objective" "Migrate the auth subsystem to OAuth2"
  write_state_field "goal_stuck_blocks" "2"
  write_state_field "goal_last_block_edit_ts" "200"
  write_state_field "goal_last_block_edit_revision" "0"
}
out="$(drive_goal gb_same_second_progress "Made a same-second follow-up edit.")"
is_block "${out}" && pass || fail "S4: same-second revision progress should reset stuck count and keep driving"
fired_goal "${out}" && pass || fail "S4: same-second progress should not trip stuck-wall"

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

# ===========================================================================
# Section 5 — is_goal_set_invocation (v1.47 single-entrance embed: the /goal
# COMMAND is a ULW activation trigger). Raw typed form only — the
# <command-name> tag form reaches UserPromptSubmit solely as a synthetic
# re-injection that is_synthetic_prompt drops (metis B1 / Bug A defense).
# ===========================================================================
printf -- '-- Section 5: is_goal_set_invocation matrix --\n'

s5_yes() {
  if is_goal_set_invocation "$1"; then pass; else fail "S5: should be a set-invocation: $1"; fi
}
s5_no() {
  if is_goal_set_invocation "$1"; then fail "S5: should NOT be a set-invocation: $1"; else pass; fi
}

s5_yes "/goal migrate billing to Stripe v2"
s5_yes "  /goal harden the installer"
s5_yes "/goal set ship v2"
s5_yes "/goal proceed with the migration"
s5_no  "/goal"
s5_no  "/goal pause"
s5_no  "/goal resume"
s5_no  "/goal clear"
s5_no  "/goal status"
s5_no  "/goal done finished it"
# Lifecycle first-token wins even with trailing prose — mirrors goal.sh's
# own subcommand parsing (a user typing "/goal pause ..." means pause).
s5_no  "/goal pause the queue consumer until drained"
# Prose mentions and prefix-collisions never activate.
s5_no  "how does /goal work?"
s5_no  "tell me about /goal please"
s5_no  "/goalie save"
s5_no  ""

# ===========================================================================
# Section 6 — is_goal_declaration_prompt (v1.47 auto-arm predicate).
# Precision-first: arms a BLOCK, so every line in the negative half is a
# documented collision class (metis B2 third-party-subject strings, the
# imperative-mood system-spec genre, doc-mentions, open-mandate prose).
# ===========================================================================
printf -- '-- Section 6: is_goal_declaration_prompt matrix --\n'

s6_yes() {
  if is_goal_declaration_prompt "$1"; then pass; else fail "S6: should declare a goal: $1"; fi
}
s6_no() {
  if is_goal_declaration_prompt "$1"; then fail "S6: false-positive declaration: $1"; else pass; fi
}

s6_yes "your goal is to migrate billing and make tests pass"
s6_yes "/ulw your goal is to fix the parser"
s6_yes "don't stop until the suite passes"
s6_yes "don’t stop until tests are green"
s6_yes "do not stop before the suite passes"
s6_yes "keep going until it's green"
s6_yes "fix the parser, then keep iterating until tests pass"
s6_yes "goal: ship v2 with green CI"
s6_yes "/ulw goal: harden the installer"
s6_yes "migrate the schema without stopping until every table is converted"
s6_yes "never stop until CI is green"
s6_yes "Refactor X. Don't stop until done"
s6_yes "ulw refactor the auth module and keep working until all tests pass"
# excellence F1 recall expansion (safe half of the cluster).
s6_yes "keep at it until it's green"
s6_yes "don't quit until the build is green"
s6_yes "do not give up until every test passes"
s6_yes "fix the loop, then keep at it until CI is green"
# metis B2 false-positive class: third-party SUBJECT descriptions.
s6_no  "the watchdog should never stop until killed by launchd"
s6_no  "the loop should keep going until the queue drains"
s6_no  "the daemon should stop only when SIGTERM arrives"
s6_no  "update the docstring that says 'your goal is X' to be clearer"
# Imperative-mood system-spec genre — why the stop-only arm was DROPPED.
s6_no  "Implement graceful shutdown. Stop only when connections drain"
# Open-mandate ambition prose stays a nudge (abstraction-critic ruling).
s6_no  "make it excellent"
s6_no  "improve the code"
s6_no  "audit everything"
# Mid-prompt goal: token (repos discussing goal-named code).
s6_no  "fix the goal: status output"
# do/don't arm requires a persistence suffix + literal do/don't.
s6_no  "don't stop the server"
s6_no  "the service should not stop until drained"
s6_no  "make sure the cron does not stop until drained"
s6_no  "what is the goal of this function?"
# excellence F1: the EXCLUDED fuzzy half of the recall cluster — spec
# reading indistinguishable from mandate reading, sequencing, spec-genre.
s6_no  "implement a CI gate that blocks merges until all tests pass"
s6_no  "flush the cache before stopping the server"
s6_no  "the worker shouldn't quit until the queue is drained"
s6_no  "the solver should keep at it until convergence"

# ===========================================================================
# Section 7 — goal.sh dormancy honesty (v1.47): outside ultrawork mode the
# driver structurally cannot run (stop-guard exits before any gate), so
# status must say DORMANT, not "ARMED (driver active)" — the pre-fix lie.
# Priority: paused → dormant → gate-off → ARMED.
# ===========================================================================
printf -- '-- Section 7: dormancy honesty --\n'

s7_root="$(mktemp -d)"
run_goal7() { HOME="${s7_root}" STATE_ROOT="${s7_root}" SESSION_ID="goal-test-s7" bash "${GOAL_SH}" "$@" 2>&1; }
_s7_state="${s7_root}/goal-test-s7/session_state.json"

# set in a vanilla session (no workflow_mode) → DORMANT note on the banner.
_s7_set="$(run_goal7 set "migrate the parser and keep tests green")"
case "${_s7_set}" in
  *DORMANT*) pass ;;
  *) fail "S7: set outside ULW did not print the DORMANT note" ;;
esac

# status in a vanilla session → SET but DORMANT, never ARMED.
_s7_status="$(run_goal7 status)"
case "${_s7_status}" in
  *"SET but DORMANT"*) pass ;;
  *) fail "S7: status outside ULW did not report DORMANT (got: ${_s7_status})" ;;
esac
case "${_s7_status}" in
  *"ARMED (driver active"*) fail "S7: status outside ULW still claims the driver is active" ;;
  *) pass ;;
esac

# arm ultrawork mode → ARMED again, no dormant note.
jq '.workflow_mode="ultrawork"' "${_s7_state}" > "${_s7_state}.tmp" && mv "${_s7_state}.tmp" "${_s7_state}"
_s7_armed="$(run_goal7 status)"
case "${_s7_armed}" in
  *"ARMED (driver active"*) pass ;;
  *) fail "S7: status inside ULW did not report ARMED (got: ${_s7_armed})" ;;
esac

# paused beats dormant (explicit user choice is the most specific state).
jq 'del(.workflow_mode)' "${_s7_state}" > "${_s7_state}.tmp" && mv "${_s7_state}.tmp" "${_s7_state}"
run_goal7 pause >/dev/null
_s7_paused="$(run_goal7 status)"
case "${_s7_paused}" in
  *PAUSED*) pass ;;
  *) fail "S7: paused+dormant should report PAUSED first (got: ${_s7_paused})" ;;
esac
rm -rf "${s7_root}"

# ===========================================================================
# Section 8 — end-to-end through the REAL prompt-intent-router.sh
# (symlinked-HOME pattern from test-prompt-router-synthetic.sh): the
# single-entrance embed's router half. Each case gets a fresh HOME tree.
# ===========================================================================
printf -- '-- Section 8: e2e real router (activation + auto-arm) --\n'

ROUTER_SH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
S8_ROOT=""

s8_setup() {
  S8_ROOT="$(mktemp -d)"
  export HOME="${S8_ROOT}"
  export STATE_ROOT="${S8_ROOT}/.claude/quality-pack/state"
  mkdir -p "${STATE_ROOT}"
  mkdir -p "${S8_ROOT}/.claude/skills" "${S8_ROOT}/.claude/quality-pack"
  ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${S8_ROOT}/.claude/skills/autowork"
  ln -s "${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts" "${S8_ROOT}/.claude/quality-pack/scripts"
}

s8_router() { # <sid> <prompt> → router stdout (additionalContext JSON)
  jq -n --arg sid "$1" --arg p "$2" '{session_id:$sid, prompt:$p}' \
    | bash "${ROUTER_SH}" 2>/dev/null || true
}

s8_state() { # <sid> <key>
  python3 -c "
import json, sys
try:
    d = json.load(open('${STATE_ROOT}/' + sys.argv[1] + '/session_state.json'))
    print(d.get(sys.argv[2], ''))
except Exception:
    print('')
" "$1" "$2" 2>/dev/null || true
}

# Case A: /goal <objective> activates ultrawork mode (the entrance half).
s8_setup
out="$(s8_router s8a "/goal migrate the parser and make all tests pass")"
[[ "$(s8_state s8a workflow_mode)" == "ultrawork" ]] && pass || fail "S8: /goal set-invocation did not activate ultrawork mode"
case "${out}" in
  *"ULW ACTIVATED BY /goal"*) pass ;;
  *) fail "S8: goal_command_entrance directive missing from router output" ;;
esac
rm -rf "${S8_ROOT}"

# Case B: lifecycle verb does NOT activate.
s8_setup
s8_router s8b "/goal pause" >/dev/null
[[ "$(s8_state s8b workflow_mode)" == "" ]] && pass || fail "S8: /goal pause wrongly activated ultrawork mode"
rm -rf "${S8_ROOT}"

# Case C: prose MENTION does NOT activate.
s8_setup
s8_router s8c "how does /goal work?" >/dev/null
[[ "$(s8_state s8c workflow_mode)" == "" ]] && pass || fail "S8: prose mention of /goal wrongly activated ultrawork mode"
rm -rf "${S8_ROOT}"

# Case D: explicit goal declaration on a fresh /ulw execution prompt
# auto-arms the driver (the auto-arm half) + announces via directive.
s8_setup
out="$(s8_router s8d "/ulw migrate the billing module and don't stop until the test suite passes")"
[[ "$(s8_state s8d goal_mode_active)" == "1" ]] && pass || fail "S8: declaration prompt did not auto-arm the goal"
[[ -n "$(s8_state s8d goal_objective)" ]] && pass || fail "S8: auto-arm stored an empty goal_objective"
case "${out}" in
  *"PERSISTENT GOAL AUTO-ARMED"*) pass ;;
  *) fail "S8: goal_auto_armed announce directive missing from router output" ;;
esac
rm -rf "${S8_ROOT}"

# Case E: plain /ulw execution prompt does NOT auto-arm.
s8_setup
s8_router s8e "/ulw fix the typo in the README" >/dev/null
[[ "$(s8_state s8e workflow_mode)" == "ultrawork" ]] && pass || fail "S8: plain /ulw prompt did not activate ultrawork mode"
[[ "$(s8_state s8e goal_mode_active)" == "" ]] && pass || fail "S8: plain /ulw prompt wrongly auto-armed a goal"
[[ "$(s8_state s8e objective_contract_edit_revision_base)" == "0" ]] && pass || fail "S8: fresh execution did not snapshot objective edit revision"
rm -rf "${S8_ROOT}"

# Case F: continuation prompt with declaration phrasing does NOT stale-arm
# (metis S3 — current_objective is overwritten with the PREVIOUS objective
# on the continuation path, so arming there would lock the goal to stale
# text; the auto-arm is fresh-execution-only by design).
s8_setup
s8_router s8f "/ulw refactor the parser module in lib/parse.sh" >/dev/null
s8_router s8f "continue, and don't stop until the tests pass" >/dev/null
[[ "$(s8_state s8f goal_mode_active)" == "" ]] && pass || fail "S8: continuation prompt wrongly auto-armed (stale-objective hazard)"
rm -rf "${S8_ROOT}"

# Case G: goal_auto_arm=off disables the auto-arm (flag escape hatch).
s8_setup
out="$(jq -n --arg sid s8g --arg p "/ulw migrate the billing module and don't stop until the test suite passes" '{session_id:$sid, prompt:$p}' \
  | OMC_GOAL_AUTO_ARM=off bash "${ROUTER_SH}" 2>/dev/null || true)"
[[ "$(s8_state s8g goal_mode_active)" == "" ]] && pass || fail "S8: goal_auto_arm=off did not disable the auto-arm"
rm -rf "${S8_ROOT}"

# Case H (excellence F2): a set-shaped /goal carrying a continuation token
# ("/goal continue hardening X") must NOT take the continuation branch —
# that branch pins current_objective to the PREVIOUS objective, leaving the
# objective-contract gate anchored to stale text while the goal driver
# tracks the fresh goal. A /goal command always declares a NEW objective.
s8_setup
s8_router s8h "/ulw refactor the parser module in lib/parse.sh" >/dev/null
s8_router s8h "/goal continue hardening the auth path until done" >/dev/null
case "$(s8_state s8h current_objective)" in
  *"hardening the auth path"*) pass ;;
  *) fail "S8: /goal continue-token prompt pinned current_objective to stale text (got: $(s8_state s8h current_objective))" ;;
esac
rm -rf "${S8_ROOT}"

# ---------------------------------------------------------------------------
printf '\n== test-goal: %d passed, %d failed ==\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
