#!/usr/bin/env bash
set -euo pipefail

# test-objective-contract.sh — objective-completion contract gate
# (v1.46-pre Codex /goal port, the anti-premature-STOP sibling of the
# /ulw-pause 3-turn anti-premature-give-up gate).
#
# Two layers:
#   1. REAL unit tests of the common.sh arming primitives
#      (objective_contract_cycle_edit_count, objective_contract_is_substantive)
#      — these are sourced and called directly, no simulation.
#   2. A faithful inline simulation of the stop-guard decision block
#      (run_objective_contract_gate) for the scenario matrix the design
#      stress-test (metis) prioritized: the "fix our failure mode" arming
#      probe, the turn-2-advisory false-positive probe, the self-disarm
#      probe, and the coverage-attestation clear probe. KEEP IN SYNC with
#      the gate block in stop-guard.sh ("Objective-completion contract gate").

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="objective-contract-test-session"
ensure_session_dir

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Reset to a clean per-cycle baseline.
reset_state() {
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

# now-ish anchors (avoid Date.now-style flakiness — fixed offsets)
T_PROMPT=1000
T_EDIT=2000        # > T_PROMPT: work happened this cycle
T_PRE=500          # < T_PROMPT: stale edit from a prior cycle

# Replicates has_closeout_label coverage detection from stop-guard.sh.
# KEEP IN SYNC with the `coverage)` case there.
_coverage_label_present() {
  printf '%s' "${1:-}" | grep -Eiq '\*\*Objective (coverage|audit)(\.)?\*\*'
}

# Faithful inline simulation of the stop-guard objective-contract gate.
# Returns: allow:flag_off | allow:non_execution | allow:no_cycle |
#          allow:no_work_this_cycle | allow:already_audited |
#          allow:no_objective | allow:not_substantive | allow:audited |
#          block:<n>/<cap> | allow:cap_reached
run_objective_contract_gate() {
  local effective_intent="$1" last_msg="${2:-}"
  if [[ "${OMC_OBJECTIVE_CONTRACT_GATE:-on}" != "on" ]]; then
    printf 'allow:flag_off'; return
  fi
  if ! is_execution_intent_value "${effective_intent}"; then
    printf 'allow:non_execution'; return
  fi
  local prompt_ts audited_ts last_edit_ts
  prompt_ts="$(read_state "objective_contract_prompt_ts")"; prompt_ts="${prompt_ts:-0}"
  audited_ts="$(read_state "objective_contract_audited_ts")"; audited_ts="${audited_ts:-0}"
  last_edit_ts="$(read_state "last_edit_ts")"; last_edit_ts="${last_edit_ts:-0}"
  [[ "${prompt_ts}" =~ ^[0-9]+$ ]] || prompt_ts=0
  [[ "${audited_ts}" =~ ^[0-9]+$ ]] || audited_ts=0
  [[ "${last_edit_ts}" =~ ^[0-9]+$ ]] || last_edit_ts=0

  [[ "${prompt_ts}" -gt 0 ]] || { printf 'allow:no_cycle'; return; }
  [[ "${last_edit_ts}" -gt "${prompt_ts}" ]] || { printf 'allow:no_work_this_cycle'; return; }
  [[ "${audited_ts}" -le "${prompt_ts}" ]] || { printf 'allow:already_audited'; return; }
  [[ -n "$(read_state "current_objective")" ]] || { printf 'allow:no_objective'; return; }
  objective_contract_is_substantive || { printf 'allow:not_substantive'; return; }

  # v1.46-pre+ (manufactured-finish-line fix): release requires BOTH the
  # coverage attestation AND a RECORDED fresh-context completeness audit
  # (excellence-reviewer) this cycle. KEEP IN SYNC with stop-guard.sh.
  local fresh_audit_ts
  fresh_audit_ts="$(read_state "last_excellence_review_ts")"; fresh_audit_ts="${fresh_audit_ts:-0}"
  [[ "${fresh_audit_ts}" =~ ^[0-9]+$ ]] || fresh_audit_ts=0
  if _coverage_label_present "${last_msg}" && [[ "${fresh_audit_ts}" -gt "${prompt_ts}" ]]; then
    write_state "objective_contract_audited_ts" "$((prompt_ts + 5000))"
    printf 'allow:audited'; return
  fi
  local blocks cap
  blocks="$(read_state "objective_contract_blocks")"; blocks="${blocks:-0}"
  [[ "${blocks}" =~ ^[0-9]+$ ]] || blocks=0
  cap=2
  if [[ "${blocks}" -lt "${cap}" ]]; then
    write_state "objective_contract_blocks" "$((blocks + 1))"
    printf 'block:%s/%s' "$((blocks + 1))" "${cap}"; return
  fi
  printf 'allow:cap_reached'
}

# Arm a fresh substantive execution cycle (volume arm: 8 files edited).
arm_substantive_cycle() {
  reset_state
  write_state_batch \
    "current_objective" "fix our failure mode" \
    "objective_contract_prompt_ts" "${T_PROMPT}" \
    "objective_contract_edit_baseline" "0" \
    "objective_contract_audited_ts" "" \
    "objective_contract_blocks" "0" \
    "last_edit_ts" "${T_EDIT}" \
    "code_edit_count" "8" \
    "doc_edit_count" "0" \
    "plan_complexity_high" ""
}

# =====================================================================
printf '## objective-contract — common.sh arming primitives (real)\n'

# --- objective_contract_cycle_edit_count: per-cycle delta off baseline ---
reset_state
write_state_batch "code_edit_count" "10" "doc_edit_count" "2" "objective_contract_edit_baseline" "5"
assert_eq "cycle edit count = (code+doc) - baseline" "7" "$(objective_contract_cycle_edit_count)"

reset_state
write_state_batch "code_edit_count" "3" "doc_edit_count" "0" "objective_contract_edit_baseline" "9"
assert_eq "cycle edit count clamps to 0 (baseline > total)" "0" "$(objective_contract_cycle_edit_count)"

reset_state
assert_eq "cycle edit count = 0 on empty state" "0" "$(objective_contract_cycle_edit_count)"

# Unknown Bash scope is not a unique-file count, but a Bash edit in the
# current objective cycle must still arm the completion audit.
reset_state
write_state_batch \
  "current_objective" "short ask" \
  "objective_contract_prompt_ts" "${T_PROMPT}" \
  "last_bash_edit_ts" "${T_EDIT}" \
  "code_edit_count" "0" \
  "doc_edit_count" "0"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "substantive via current-cycle unknown Bash edit" "yes" "yes" \
  || assert_eq "substantive via current-cycle unknown Bash edit" "yes" "no"

reset_state
write_state_batch \
  "current_objective" "short ask" \
  "objective_contract_prompt_ts" "${T_PROMPT}" \
  "last_bash_edit_ts" "${T_PRE}" \
  "code_edit_count" "0" \
  "doc_edit_count" "0"
if OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive; then
  assert_eq "stale prior-cycle unknown Bash edit does not arm" "no" "yes"
else
  assert_eq "stale prior-cycle unknown Bash edit does not arm" "no" "no"
fi

# --- objective_contract_is_substantive: the disjunction ---
# VOLUME arm
arm_substantive_cycle
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "substantive via VOLUME (8 edits >= 4)" "yes" "yes" \
  || assert_eq "substantive via VOLUME (8 edits >= 4)" "yes" "no"

# INTENT arm: plan_complexity_high, even with ZERO edits (big ask, thin output)
reset_state
write_state_batch "current_objective" "short ask" "plan_complexity_high" "1" \
  "code_edit_count" "0" "doc_edit_count" "0" "objective_contract_edit_baseline" "0"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "substantive via INTENT (plan_complexity_high, 0 edits)" "yes" "yes" \
  || assert_eq "substantive via INTENT (plan_complexity_high, 0 edits)" "yes" "no"

# INTENT arm: long objective (>= 600 chars)
reset_state
_long="$(printf 'x%.0s' {1..650})"
write_state_batch "current_objective" "${_long}" "plan_complexity_high" "" \
  "code_edit_count" "0" "doc_edit_count" "0" "objective_contract_edit_baseline" "0"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "substantive via INTENT (objective >= 600 chars)" "yes" "yes" \
  || assert_eq "substantive via INTENT (objective >= 600 chars)" "yes" "no"

# NOT substantive: short objective, few edits, no plan complexity
reset_state
write_state_batch "current_objective" "fix typo" "plan_complexity_high" "" \
  "code_edit_count" "1" "doc_edit_count" "0" "objective_contract_edit_baseline" "0"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "NOT substantive (small task stays silent)" "no" "yes" \
  || assert_eq "NOT substantive (small task stays silent)" "no" "no"

# min_files=0 disables the VOLUME arm (intent arms still fire)
reset_state
write_state_batch "current_objective" "short" "plan_complexity_high" "" \
  "code_edit_count" "50" "doc_edit_count" "0" "objective_contract_edit_baseline" "0"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=0 objective_contract_is_substantive \
  && assert_eq "min_files=0 disables VOLUME arm" "no" "yes" \
  || assert_eq "min_files=0 disables VOLUME arm" "no" "no"

# INTENT arm: god-scope bare imperative (v1.47). A bare imperative ("improve it")
# with a TINY first round (1 edit) and a short objective arms via NONE of the
# volume/length/plan signals — only the god-scope INTENT arm. This is the
# high-precision subset of the "ambitious-but-vague prompt stops at round one"
# blind spot. objective_contract_god_scope is stored as a STRING (read_state
# returns empty for raw JSON numbers — the documented e2e gotcha).
reset_state
write_state_batch "current_objective" "improve it" "plan_complexity_high" "" \
  "code_edit_count" "1" "doc_edit_count" "0" "objective_contract_edit_baseline" "0" \
  "objective_contract_god_scope" "1"
OMC_OBJECTIVE_CONTRACT_ARM_ON_GOD_SCOPE=on OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "substantive via INTENT (god-scope bare imperative, 1 edit)" "yes" "yes" \
  || assert_eq "substantive via INTENT (god-scope bare imperative, 1 edit)" "yes" "no"

# flag off → the god-scope arm does NOT fire (reverts to volume/length/plan only)
OMC_OBJECTIVE_CONTRACT_ARM_ON_GOD_SCOPE=off OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "god-scope arm OFF → not substantive" "no" "yes" \
  || assert_eq "god-scope arm OFF → not substantive" "no" "no"

# no god-scope signal + tiny task → still silent (the arm does not over-fire on
# ordinary small tasks — precision is borrowed from is_bare_imperative_prompt).
reset_state
write_state_batch "current_objective" "fix typo" "plan_complexity_high" "" \
  "code_edit_count" "1" "doc_edit_count" "0" "objective_contract_edit_baseline" "0" \
  "objective_contract_god_scope" ""
OMC_OBJECTIVE_CONTRACT_ARM_ON_GOD_SCOPE=on OMC_OBJECTIVE_CONTRACT_MIN_FILES=4 objective_contract_is_substantive \
  && assert_eq "no god-scope + tiny task stays silent" "no" "yes" \
  || assert_eq "no god-scope + tiny task stays silent" "no" "no"

# =====================================================================
printf '## objective-contract — gate decision (inline simulation, keep in sync)\n'

# PROBE 1 (metis headline): "fix our failure mode" — short prose imperative,
# no enumeration, no bare-imperative god-scope — ARMS via edit fan-out.
# The plan is only credible if the motivating prompt arms the contract.
arm_substantive_cycle
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4
result="$(run_objective_contract_gate execution "working on it")"
assert_contains "PROBE1: 'fix our failure mode' arms (blocks first stop)" "block:1/2" "${result}"

# PROBE 1b (v1.47 god-scope arm — the user-reported headline): a bare-imperative
# god-scope cycle ("harden") with a TINY first round (1 edit, short objective,
# no planner) — the "ambitious-but-vague prompt stops at round one" failure —
# now ARMS and blocks the first stop instead of releasing. Popper falsifier:
# if this cycle is ALLOWED to stop, the relentless loop never engages.
reset_state
write_state_batch \
  "current_objective" "harden" \
  "objective_contract_prompt_ts" "${T_PROMPT}" \
  "objective_contract_edit_baseline" "0" \
  "objective_contract_audited_ts" "" \
  "objective_contract_blocks" "0" \
  "last_edit_ts" "${T_EDIT}" \
  "code_edit_count" "1" "doc_edit_count" "0" \
  "plan_complexity_high" "" \
  "objective_contract_god_scope" "1"
OMC_OBJECTIVE_CONTRACT_MIN_FILES=4
# flag OFF first (exits at not_substantive before any state mutation): the gate
# stays silent, reproducing the pre-v1.47 "stops at round one" behavior.
result="$(OMC_OBJECTIVE_CONTRACT_ARM_ON_GOD_SCOPE=off run_objective_contract_gate execution "did one small thing")"
assert_eq "PROBE1b: god-scope arm OFF → not_substantive (silent, the old bug)" "allow:not_substantive" "${result}"
# flag ON → arms and blocks the first stop (the fix: relentless drive engages).
result="$(OMC_OBJECTIVE_CONTRACT_ARM_ON_GOD_SCOPE=on run_objective_contract_gate execution "did one small thing")"
assert_contains "PROBE1b: god-scope arm ON + tiny round arms (blocks)" "block:1/2" "${result}"

# PROBE 2 (the corrosive false positive): a turn-2 ADVISORY follow-up after a
# completed task must be INERT — current_objective is preserved across turns,
# so without the execution-intent guard this would re-block "thanks, what's
# the test count?". This is the single most important regression.
arm_substantive_cycle
result="$(run_objective_contract_gate advisory "the test count is 47")"
assert_eq "PROBE2: turn-2 advisory follow-up is INERT (no re-block)" "allow:non_execution" "${result}"

# PROBE 3 (clear): a coverage attestation PLUS a RECORDED fresh-context
# completeness audit this cycle (last_excellence_review_ts > prompt_ts)
# clears it. The fresh audit is the load-bearing half — self-attestation
# alone no longer clears (PROBE 3c).
arm_substantive_cycle
write_state "last_excellence_review_ts" "$((T_PROMPT + 1))"
result="$(run_objective_contract_gate execution "Done.

**Objective coverage.** All parts addressed; a fresh excellence-review found no cost/risk-deferred omissions.")"
assert_eq "PROBE3: coverage attestation + fresh audit clears the gate" "allow:audited" "${result}"
# ...and the audit ts is now recorded, so a re-stop stays quiet.
result="$(run_objective_contract_gate execution "stopping now")"
assert_eq "PROBE3: subsequent stop stays quiet (audited this cycle)" "allow:already_audited" "${result}"

# PROBE 3c (manufactured-finish-line fix): a coverage attestation WITHOUT a
# recorded fresh-context audit this cycle must NOT clear — self-attestation by
# the drifted model is the corrupt witness whose silent mandate-narrowing is
# the failure. This is the core regression for the fix.
arm_substantive_cycle
result="$(run_objective_contract_gate execution "Done.

**Objective coverage.** All parts of the objective addressed.")"
assert_contains "PROBE3c: attestation WITHOUT fresh audit does NOT clear (blocks)" "block:1/2" "${result}"
# A STALE audit from a prior cycle (ts <= prompt_ts) also does not count.
arm_substantive_cycle
write_state "last_excellence_review_ts" "${T_PRE}"
result="$(run_objective_contract_gate execution "Done.

**Objective coverage.** addressed.")"
assert_contains "PROBE3c: stale prior-cycle audit does NOT clear (blocks)" "block:1/2" "${result}"

# PROBE 3b (quality-reviewer F-1 regression): a BARE **Coverage.** note (test
# coverage, not objective coverage) must NOT clear the gate — the "Objective"
# prefix is required, else a routine test-coverage wrap-up would falsely clear
# the objective-completion gate without any objective attestation.
arm_substantive_cycle
result="$(run_objective_contract_gate execution "Done.

**Coverage.** Test suite now at 95% line coverage.")"
assert_contains "PROBE3b: bare **Coverage.** (test coverage) does NOT clear the gate" "block:1/2" "${result}"

# PROBE 4 (self-disarm): work that happened BEFORE this cycle's prompt_ts
# (stale edit from a prior cycle) does not arm — last_edit_ts <= prompt_ts.
arm_substantive_cycle
write_state "last_edit_ts" "${T_PRE}"
result="$(run_objective_contract_gate execution "nothing edited this cycle")"
assert_eq "PROBE4: self-disarm when no work happened this cycle" "allow:no_work_this_cycle" "${result}"

# Cap behavior: blocks 1 and 2, then releases (cap reached). The gate's
# own block_cap is independent of guard_exhaustion_mode (whose default
# flipped scorecard→block in v1.48), so this release path holds under
# either default.
arm_substantive_cycle
r1="$(run_objective_contract_gate execution "msg")"
r2="$(run_objective_contract_gate execution "msg")"
r3="$(run_objective_contract_gate execution "msg")"
assert_contains "cap: first block 1/2" "block:1/2" "${r1}"
assert_contains "cap: second block 2/2" "block:2/2" "${r2}"
assert_eq "cap: third stop releases (cap reached)" "allow:cap_reached" "${r3}"

# Off-flag kill switch
arm_substantive_cycle
result="$(OMC_OBJECTIVE_CONTRACT_GATE=off run_objective_contract_gate execution "msg")"
assert_eq "flag off disables the gate" "allow:flag_off" "${result}"

# No objective to re-anchor against → inert (defensive)
reset_state
write_state_batch "current_objective" "" "objective_contract_prompt_ts" "${T_PROMPT}" \
  "last_edit_ts" "${T_EDIT}" "code_edit_count" "8" "doc_edit_count" "0" \
  "objective_contract_edit_baseline" "0"
result="$(run_objective_contract_gate execution "msg")"
assert_eq "no current_objective → inert" "allow:no_objective" "${result}"

# Continuation intent IS execution-class (resumes the same objective) → arms.
arm_substantive_cycle
result="$(run_objective_contract_gate continuation "keep going")"
assert_contains "continuation intent arms (resumes objective)" "block:1/2" "${result}"

# =====================================================================
printf '## objective-contract — real has_closeout_label coverage pattern\n'
# Guard the coverage-label regex this test replicates against the real one
# in stop-guard.sh (so the simulation can't silently drift from the gate).
_sg="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"
if grep -q 'Objective (coverage|audit)' "${_sg}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: stop-guard.sh coverage label regex drifted from this test\n' >&2
  fail=$((fail + 1))
fi

# =====================================================================
printf '## objective-contract — FP observability (real read-path)\n'
_events_file="$(session_file "gate_events.jsonl")"
_count_reprompt() {
  [[ -f "${_events_file}" ]] || { printf '0'; return; }
  jq -rs '[.[] | select(.gate=="objective-contract" and .event=="post-block-reprompt")] | length' "${_events_file}" 2>/dev/null || printf '0'
}

# Recent block (within window) → reprompt event recorded + ts cleared.
reset_state
rm -f "${_events_file}"
write_state "last_objective_contract_block_ts" "$(now_epoch)"
OMC_NO_DEFER_REPROMPT_WINDOW_SECS=60 objective_contract_check_post_block_reprompt
assert_eq "recent block records post-block-reprompt" "1" "$(_count_reprompt)"
assert_eq "reprompt check clears the block ts (single-use)" "" "$(read_state last_objective_contract_block_ts)"

# Stale block (outside window) → no reprompt event, ts still cleared.
reset_state
rm -f "${_events_file}"
write_state "last_objective_contract_block_ts" "1000"   # ancient
OMC_NO_DEFER_REPROMPT_WINDOW_SECS=60 objective_contract_check_post_block_reprompt
assert_eq "stale block records NO reprompt event" "0" "$(_count_reprompt)"
assert_eq "stale block ts still cleared" "" "$(read_state last_objective_contract_block_ts)"

# No block stamped → no-op.
reset_state
rm -f "${_events_file}"
objective_contract_check_post_block_reprompt
assert_eq "no block stamped → no reprompt event" "0" "$(_count_reprompt)"

# =====================================================================
# Excellence-reviewer anti-narrowing axis (the fresh audit's CONTENT).
# The gate's release now requires a fresh excellence-review; that audit is
# only useful if excellence-reviewer asks the sample-vs-ceiling /
# cost-vs-evidence question. Armor that prose — no other net covers it, and
# the manufactured-finish-line fix is inert if the audit reverts to a
# generic "is what shipped good" review.
# =====================================================================
printf '## excellence-reviewer anti-narrowing axis (fresh-audit content)\n'
_ER_MD="$(cd "$(dirname "$0")/.." && pwd)/bundle/dot-claude/agents/excellence-reviewer.md"
if grep -Eiq 'manufactured-finish-line' "${_ER_MD}" \
  && grep -Eiq 'sample of what.s worth doing|not the ceiling|largest worthwhile thing NOT done' "${_ER_MD}" \
  && grep -Eiq 'cost is never|FORBIDDEN deferral grounds|cost-avoidance' "${_ER_MD}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: excellence-reviewer.md missing the anti-narrowing / cost-vs-evidence axis (fix is inert without it)\n' >&2
  fail=$((fail + 1))
fi

# =====================================================================
printf '\n--- objective-contract: %d pass, %d fail ---\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
