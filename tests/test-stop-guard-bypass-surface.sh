#!/usr/bin/env bash
# test-stop-guard-bypass-surface.sh — umbrella regression net for the
# v1.42.x stop-guard bypass closure work.
#
# Each bypass surface gets a passing test per defense. Future regressions
# in any single defense surface immediately fail this test, even if the
# per-surface test files (test-mark-deferred, test-ulw-pause,
# test-common-utilities) drift or skip the regression case.
#
# Bypass surfaces covered:
#   F-001: has_unfinished_session_handoff — expanded noun/adj slots,
#          follow-up idioms, permission-coded continuation asks (v1.42.x)
#   F-003: ulw-pause reason validator — technical-judgment deny-list
#   F-005: ulw-correct mid-turn execution-intent downgrade refusal
#   F-008: advisory-no-findings gate — specialist dispatch w/o findings
#   F-010: rejected-finding validator — subjective bare-token tightening
#   F-010b: final-closure label closing-region restriction
#   F-011: ulw-skip refusal on unremediated post-edit gates
#   F-014: objective-completion contract gate (substantive arm)
#   F-015: /goal relentless driver (user-armed arm + stuck-wall escape)
#
# Each block runs its defense as a black-box: invoke the script with the
# bypass shape, assert exit code + telemetry side effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

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
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

_ORIG_PWD="$(pwd)"

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
  export SESSION_ID="bypass-surface-test"
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  # workflow_mode=ultrawork is what is_ultrawork_mode() checks.
  printf '{"workflow_mode":"ultrawork"}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
  # The sentinel file is read at the top of mark-edit / record-pending-agent
  # to fast-path-skip non-ULW sessions. Recreate it for tests that exercise
  # those hooks.
  touch "${STATE_ROOT}/.ulw_active"
  # v1.43+ (F-013 follow-up): cd into TEST_HOME so the conf walk-up in
  # common.sh's load_conf doesn't traverse into the real user's
  # ~/.claude/oh-my-claude.conf (which lives at a level above the
  # repo's CWD). Without this, sub-shells sourcing common.sh would
  # classify the real user conf as a "project" conf and the new
  # security flag restriction would log rejections to stderr.
  cd "${TEST_HOME}"
}

teardown() {
  cd "${_ORIG_PWD}"
  rm -rf "${TEST_HOME}"
  # Keep HOME set across teardowns — sub-shells that source common.sh
  # require it under `set -u`. STATE_ROOT and SESSION_ID are session-
  # specific and safe to unset; HOME persists for non-session sub-tests.
  unset STATE_ROOT SESSION_ID
}

# Make sure HOME is set before any sub-shell sources common.sh — bypass
# tests run helpers OUTSIDE setup/teardown blocks and would otherwise hit
# `HOME: unbound variable` under set -u.
if [[ -z "${HOME:-}" ]]; then
  _bypass_fallback_home="$(mktemp -d)"
  export HOME="${_bypass_fallback_home}"
fi

write_state_field() {
  local key="$1" value="$2"
  local state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
  jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" > "${state_file}.tmp" \
    && mv "${state_file}.tmp" "${state_file}"
}

write_state_int() {
  local key="$1" value="$2"
  local state_file="${STATE_ROOT}/${SESSION_ID}/session_state.json"
  jq --arg k "${key}" --argjson v "${value}" '.[$k] = $v' "${state_file}" > "${state_file}.tmp" \
    && mv "${state_file}.tmp" "${state_file}"
}

read_state_field() {
  local field="$1"
  jq -r --arg k "${field}" '.[$k] // empty' \
    "${STATE_ROOT}/${SESSION_ID}/session_state.json" 2>/dev/null
}

# v1.42.x audit-symmetry helper: jq-scan the per-session gate_events.jsonl
# for a row whose .gate and .event match the supplied tokens. Empty
# match returns empty string; caller uses assert_eq / assert_contains.
gate_event_exists() {
  local gate="$1" event="$2"
  local file="${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
  # Normalize the no-file case to "0" — some scripts never write any
  # gate event on their happy path (e.g. ulw-correct-record when no
  # downgrade is attempted), and the test's assert_eq needs a stable
  # comparable value rather than an empty string.
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -rs --arg gate "${gate}" --arg event "${event}" \
    'map(select(.gate == $gate and .event == $event)) | length' \
    "${file}" 2>/dev/null
}

# ===========================================================================
# F-001: handoff regex (v1.42.x expanded slots + idioms)
# ===========================================================================
printf '=== F-001: has_unfinished_session_handoff bypass closure ===\n'

# Source the function from common.sh. Need to disable the lazy-load opt-out
# guards by entering through a fresh shell.
detect_handoff() {
  OMC_HANDOFF_TEST_PHRASE="$1" bash -c '
    set -e
    SCRIPT_DIR="'"${HOOK_DIR}"'"
    . "${SCRIPT_DIR}/common.sh"
    has_unfinished_session_handoff "${OMC_HANDOFF_TEST_PHRASE}"
  '
}

# v1.42.x noun-slot expansions
printf 'noun-slot: pass / iteration / cycle / sprint / commit / PR\n'
for phrase in "Leave the broader refactor for the next pass." \
              "Additional polish remains for a future iteration." \
              "Deferring to a subsequent cycle." \
              "Flagging these for the next sprint." \
              "Save the rest for a follow-up commit." \
              "I'll address that in the next PR."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches: ${phrase}" "0" "${rc}"
done

# v1.42.x adjective-slot expansions
printf 'adjective-slot: subsequent / dedicated / follow-on / follow-up\n'
for phrase in "Leave the broader refactor for a dedicated pass." \
              "Earmarked for follow-on work." \
              "Deferring to a subsequent cycle."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches: ${phrase}" "0" "${rc}"
done

# v1.42.x follow-up idioms
printf 'idioms: as-known / queued-for / parked-for / noted-for / earmarked-for\n'
for phrase in "Documented as a known follow-up." \
              "Leaving as a known limitation." \
              "The deeper architectural work is queued for later." \
              "Parking this for follow-up — too complex this turn." \
              "Earmarked for the future." \
              "Noted for later attention." \
              "These are flagged for follow-up review."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches: ${phrase}" "0" "${rc}"
done

printf 'v1.42.x-newer noun-slot: phase / revision / audit / refactor + adj upcoming\n'
for phrase in "Deferred to a separate refactor next sprint." \
              "Save these for a follow-up audit." \
              "Will tackle in a future revision." \
              "Leaving the broader work for an upcoming cycle." \
              "Deferring this to a later phase of the project."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches: ${phrase}" "0" "${rc}"
done

printf 'permission-coded continuation asks: if-you-want / say-keep-going / clean-stopping-point\n'
for phrase in 'Next. If you want Wave 7-9 shipped in this session, I can continue -- say "keep going" and name which of the above to prioritize. Otherwise this is a clean stopping point for v33 with a documented v34 entry plan.' \
              'Say "keep going" and I will handle the remaining waves.' \
              "Otherwise this is a clean stopping point for v33 with a documented v34 entry plan."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches: ${phrase}" "0" "${rc}"
done

setup
write_state_field "task_intent" "execution"
write_state_field "current_objective" "ship all waves"
write_state_int "last_user_prompt_ts" 100
write_state_int "last_edit_ts" 200
handoff_msg='Next. If you want Wave 7-9 shipped in this session, I can continue -- say "keep going" and name which of the above to prioritize. Otherwise this is a clean stopping point for v33 with a documented v34 entry plan.'
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${handoff_msg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | "${HOOK_DIR}/stop-guard.sh")"
assert_contains "stop-guard blocks permission-coded continuation ask" '"decision":"block"' "${out}"
assert_contains "stop-guard recovery names say keep going" "say keep going" "${out}"
teardown

# v1.44 quote-stripping FP closure: handoff phrases inside backtick-fenced
# spans, ASCII double-quotes, or ASCII single-quotes MUST NOT match. True
# handoff announcements are never quoted — a model writing
# `"pushing tasks to next session"` is REPORTING the user's complaint,
# not announcing a handoff. Same for inline-code phrasings used to discuss
# the gate's own regex.
printf 'v1.44 quote-stripping: quoted handoff phrases must NOT match\n'
for phrase in 'The user-named failure mode ("still pushing tasks to next session") is now closed.' \
              "The user-named failure mode ('still pushing tasks to next session') is now closed." \
              'The gate catches phrases like `for next session` or `in your next prompt`.' \
              'The deny list includes "tracks to a future session" and "in a future session" as effort excuses.' \
              'CHANGELOG entry: "deferring to next session is no longer a category".' \
              'Quoted anti-pattern: `"next wave" / "next phase" / "for next session"`.'; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "no-match (quoted): ${phrase}" "1" "${rc}"
done

# v1.44 quote-stripping: unquoted handoff prose MUST still match even when
# adjacent quoted text exists. The regex strips quotes before matching, so
# a sentence with BOTH quoted reference AND unquoted handoff announcement
# still trips on the unquoted half.
printf 'v1.44 quote-stripping: unquoted handoff MUST still match (mixed)\n'
for phrase in 'The user said "do not stop" but I will pick this up in a future session.' \
              'The gate catches phrases like `for next session` — and I will pick this up in your next prompt.'; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "matches (mixed): ${phrase}" "0" "${rc}"
done

# FP guards: must NOT match (block storms would otherwise fire on common
# non-handoff prose)
printf 'FP guards: legitimate non-handoff prose must NOT match\n'
for phrase in "The next pass through the loop normalizes the data." \
              "I have a follow-up question about that." \
              "The job is queued behind the request." \
              "We addressed all findings this iteration." \
              "The continuation classifier treats keep going as a continuation prompt." \
              "If you want, I can continue explaining the tradeoffs." \
              "Treat this as a fresh session for safety." \
              "Do not treat as a fresh session." \
              "The job was queued for execution by the scheduler." \
              "These bullets are flagged for review by the linter." \
              "Each refactor lives on its own branch in this project." \
              "The audit log records every commit independently."; do
  set +e
  detect_handoff "${phrase}"
  rc=$?
  set -e
  assert_eq "no-match: ${phrase}" "1" "${rc}"
done

# ===========================================================================
# F-003: ulw-pause technical-judgment validator
# ===========================================================================
printf '\n=== F-003: ulw-pause judgment-token validator ===\n'

setup
set +e
out="$("${HOOK_DIR}/ulw-pause.sh" "user must pick library A vs B" 2>&1)"
rc=$?
set -e
assert_eq "library A vs B bare reason exits 2" "2" "${rc}"
assert_contains "rejection message names operational-only" "operational-only" "${out}"
assert_eq "ulw_pause_active NOT set after rejection" "" "$(read_state_field 'ulw_pause_active')"
teardown

setup
out="$("${HOOK_DIR}/ulw-pause.sh" "library choice — blocked by stakeholder approval on license terms" 2>&1)"
rc=$?
assert_eq "paired (library + stakeholder approval) exits 0" "0" "${rc}"
teardown

setup
out="$(OMC_ULW_PAUSE_FORCE=1 "${HOOK_DIR}/ulw-pause.sh" "user must pick copy A vs B" 2>&1)"
rc=$?
assert_eq "OMC_ULW_PAUSE_FORCE=1 overrides validator" "0" "${rc}"
# v1.42.x audit symmetry: distinct force-bypass event MUST be logged
# when the force flag flips a would-be rejection into a pass. Without
# this, the override is silent and routine misuse cannot be detected
# by /ulw-report cross-session aggregation.
assert_eq "ulw-pause FORCE emits force-bypass event" "1" "$(gate_event_exists 'ulw-pause' 'force-bypass')"
assert_eq "ulw_pause_force_count incremented" "1" "$(read_state_field 'ulw_pause_force_count')"
teardown

# FORCE on a reason that wasn't a judgment call → no force-bypass
# event (validator would have allowed it; no bypass occurred).
setup
out="$(OMC_ULW_PAUSE_FORCE=1 "${HOOK_DIR}/ulw-pause.sh" "credentials missing — awaiting login token" 2>&1)"
rc=$?
assert_eq "FORCE on operational reason exits 0" "0" "${rc}"
assert_eq "no force-bypass event when validator would have passed" "0" "$(gate_event_exists 'ulw-pause' 'force-bypass')"
assert_eq "ulw_pause_force_count NOT incremented when no bypass occurred" "" "$(read_state_field 'ulw_pause_force_count')"
teardown

# ===========================================================================
# F-005: ulw-correct mid-turn execution downgrade refusal
# ===========================================================================
printf '\n=== F-005: ulw-correct mid-turn downgrade refusal ===\n'

# Case A: legitimate user correction at start of turn — last_edit_ts =
# last_user_prompt_ts (no edits yet). Downgrade allowed.
setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "1000"
write_state_int "last_edit_ts" "1000"
set +e
out="$("${HOOK_DIR}/ulw-correct-record.sh" "actually advisory intent=advisory" 2>&1)"
rc=$?
set -e
assert_eq "downgrade allowed when no edits this turn exit 0" "0" "${rc}"
assert_eq "task_intent flipped to advisory" "advisory" "$(read_state_field 'task_intent')"
teardown

# Case B: agent self-issue mid-turn — last_edit_ts > last_user_prompt_ts.
# Downgrade refused.
setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "1000"
write_state_int "last_edit_ts" "2000"
set +e
out="$("${HOOK_DIR}/ulw-correct-record.sh" "actually advisory intent=advisory" 2>&1)"
rc=$?
set -e
assert_eq "mid-turn downgrade exits 4 (refused)" "4" "${rc}"
assert_eq "task_intent stays execution" "execution" "$(read_state_field 'task_intent')"
assert_contains "rejection names the timing signal" "edit has occurred" "${out}"
teardown

# Case C: continuation is NOT a downgrade — allowed
setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "1000"
write_state_int "last_edit_ts" "2000"
set +e
out="$("${HOOK_DIR}/ulw-correct-record.sh" "this is continuation intent=continuation" 2>&1)"
rc=$?
set -e
assert_eq "continuation mid-turn allowed (exit 0)" "0" "${rc}"
assert_eq "task_intent flipped to continuation" "continuation" "$(read_state_field 'task_intent')"
teardown

# Case D: OMC_ULW_CORRECT_FORCE=1 overrides — for tests + user override
setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "1000"
write_state_int "last_edit_ts" "2000"
set +e
out="$(OMC_ULW_CORRECT_FORCE=1 "${HOOK_DIR}/ulw-correct-record.sh" "actually advisory intent=advisory" 2>&1)"
rc=$?
set -e
assert_eq "FORCE override exits 0" "0" "${rc}"
assert_eq "task_intent flipped under FORCE" "advisory" "$(read_state_field 'task_intent')"
# v1.42.x audit symmetry: same as ulw-pause — when the FORCE flips
# the mid-turn downgrade-block into a pass, the override MUST be
# audited via a distinct event AND a per-session counter increment.
assert_eq "ulw-correct FORCE emits force-bypass event" "1" "$(gate_event_exists 'intent-downgrade-blocked' 'force-bypass')"
assert_eq "ulw_correct_force_count incremented" "1" "$(read_state_field 'ulw_correct_force_count')"
teardown

# Case E (parity negative): FORCE set, but no mid-turn condition
# (last_edit_ts <= last_user_prompt_ts → downgrade legitimately
# allowed). No bypass occurred, so NO force-bypass event AND NO
# counter increment. Mirror of the ulw-pause negative test above.
setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "2000"
write_state_int "last_edit_ts" "1000"
out="$(OMC_ULW_CORRECT_FORCE=1 "${HOOK_DIR}/ulw-correct-record.sh" "actually advisory intent=advisory" 2>&1)"
rc=$?
assert_eq "FORCE on no-mid-turn downgrade exits 0" "0" "${rc}"
assert_eq "no force-bypass event when no rejection occurred" "0" "$(gate_event_exists 'intent-downgrade-blocked' 'force-bypass')"
assert_eq "ulw_correct_force_count NOT incremented" "" "$(read_state_field 'ulw_correct_force_count')"
teardown

# ===========================================================================
# F-008: advisory-no-findings counter increments correctly
# ===========================================================================
printf '\n=== F-008: advisory-specialist dispatch counter ===\n'

setup
# Simulate a council dispatch via record-pending-agent.sh
for agent in metis oracle product-lens; do
  echo "{\"session_id\":\"${SESSION_ID}\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"${agent}\",\"description\":\"test\"}}" \
    | "${HOOK_DIR}/record-pending-agent.sh"
done
adv_count="$(read_state_field 'advisory_specialist_dispatch_count')"
assert_eq "3 advisory dispatches counted" "3" "${adv_count}"
subagent_count="$(read_state_field 'subagent_dispatch_count')"
assert_eq "3 total dispatches counted" "3" "${subagent_count}"
teardown

# Non-advisory dispatch does NOT increment advisory counter
setup
echo "{\"session_id\":\"${SESSION_ID}\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"frontend-developer\",\"description\":\"test\"}}" \
  | "${HOOK_DIR}/record-pending-agent.sh"
adv_count="$(read_state_field 'advisory_specialist_dispatch_count')"
subagent_count="$(read_state_field 'subagent_dispatch_count')"
assert_eq "non-advisory NOT in advisory counter" "" "${adv_count}"
assert_eq "non-advisory IS in subagent total" "1" "${subagent_count}"
teardown

# ===========================================================================
# F-010: rejected-finding validator — subjective bare tokens rejected
# ===========================================================================
printf '\n=== F-010: rejected-finding validator subjective-token tightening ===\n'

validator_check() {
  bash -c '
    SCRIPT_DIR="'"${HOOK_DIR}"'"
    . "${SCRIPT_DIR}/common.sh"
    omc_reason_has_concrete_why "'"$1"'"
  '
}

# Pre-v1.42.x bypass paths (must REJECT now)
for reason in "by design" "wontfix" "working as intended" "won't fix"; do
  set +e
  validator_check "${reason}"
  rc=$?
  set -e
  assert_eq "bare '${reason}' rejected" "1" "${rc}"
done

# Verifiable bare tokens (still PASS)
for reason in "duplicate" "obsolete" "not reproducible" "false positive" "n/a"; do
  set +e
  validator_check "${reason}"
  rc=$?
  set -e
  assert_eq "bare '${reason}' passes" "0" "${rc}"
done

# Subjective tokens paired with concrete WHY (PASS)
for reason in "by design because the contract specifies it" \
              "wontfix — superseded by F-051" \
              "working as intended because the security spec requires it"; do
  set +e
  validator_check "${reason}"
  rc=$?
  set -e
  assert_eq "paired '${reason}' passes" "0" "${rc}"
done

# ===========================================================================
# F-010b: final-closure label closing-region restriction
# ===========================================================================
printf '\n=== F-010b: final-closure closing-region scan ===\n'

closeout_check() {
  bash -c '
    SCRIPT_DIR="'"${HOOK_DIR}"'"
    . "${SCRIPT_DIR}/common.sh"
    # Source stop-guard helpers — has_closeout_label is defined there at
    # top-level so a fresh shell with common.sh loaded then stop-guard
    # sourced inline provides the function.
    # We inline the closeout function definition for test isolation since
    # stop-guard.sh runs hook logic eagerly on load.
    has_closeout_label() {
      local kind="$1"
      local text="${2:-}"
      local pattern=""
      case "${kind}" in
        changed)      pattern="\*\*(Changed|Shipped)(\.)?\*\*" ;;
        verification) pattern="\*\*Verification(\.)?\*\*" ;;
        risks)        pattern="\*\*Risks(\.)?\*\*" ;;
        next)         pattern="\*\*Next(\.)?\*\*" ;;
        coverage)     pattern="\*\*Objective (coverage|audit)(\.)?\*\*" ;;
        *) return 1 ;;
      esac
      [[ -n "${text}" ]] || return 1
      # v1.43+: threshold synced with stop-guard.sh has_closeout_label
      # (200 → 400). The fixtures below pad to >600 chars so the
      # closing-region branch is still exercised by long_meta /
      # long_closure; short_close at 36 chars trivially hits full scan.
      local len="${#text}"
      if [[ "${len}" -lt 400 ]]; then
        printf "%s" "${text}" | grep -Eiq "${pattern}"
        return $?
      fi
      local closing_start=$((len * 6 / 10))
      local closing_region="${text:${closing_start}}"
      printf "%s" "${closing_region}" | grep -Eiq "${pattern}"
    }
    has_closeout_label "'"$1"'" "'"$2"'"
  '
}

# Meta-mention earlier in body — must NOT satisfy gate (long message)
# Build a long message (>200 chars) where the bolded label appears only
# in the FIRST 40%. Pad with non-label content to push the label out of
# the closing region.
filler="This is a long body of text discussing what should happen. To pass the closure gate the message would need to write **Changed.** explicitly, but right now I am still mid-investigation and haven't actually closed out the work. There is more to do here. We need to verify and address findings."
padding="The investigation continues. I am not done yet. Several more steps remain before the work is complete."
long_meta="${filler}${padding}${padding}${padding}${padding}"

set +e
closeout_check changed "${long_meta}"
rc=$?
set -e
assert_eq "meta-mention in body region does NOT match (long msg)" "1" "${rc}"

# Legitimate close at the end of a long message — must match
long_closure="${padding}${padding}${padding}${padding}**Changed.** Foo updated. **Verification.** Tests pass. **Next.** Done."
set +e
closeout_check changed "${long_closure}"
rc=$?
set -e
assert_eq "legitimate close in closing region matches" "0" "${rc}"

# Short message — entire body IS the closing region, full scan
short_close="**Changed.** Bug fixed. **Next.** Done."
set +e
closeout_check changed "${short_close}"
rc=$?
set -e
assert_eq "short message full-scan matches" "0" "${rc}"

# v1.46-pre objective-contract: the `coverage` closeout kind requires the
# "Objective" prefix. A bare **Coverage.** (test/review coverage) must NOT
# match — else a test-coverage wrap-up would falsely clear the objective-
# completion gate (quality-reviewer F-1). Closing-region scan, F-010 family.
set +e
closeout_check coverage "All parts done. **Objective coverage.** api/ui/tests shipped."
rc=$?
set -e
assert_eq "coverage kind matches **Objective coverage.**" "0" "${rc}"
set +e
closeout_check coverage "Done. **Coverage.** Test suite now at 95% line coverage."
rc=$?
set -e
assert_eq "coverage kind does NOT match bare **Coverage.** (test coverage)" "1" "${rc}"

# ===========================================================================
# F-011: ulw-skip refusal on unremediated post-edit gates
# ===========================================================================
printf '\n=== F-011: ulw-skip post-edit unremediated refusal ===\n'

setup
write_state_field "review_had_findings" "true"
write_state_int "last_review_ts" "1000"
write_state_int "last_edit_ts" "2000"
set +e
out="$("${HOOK_DIR}/ulw-skip-register.sh" "release shipped — CI is the real gate" 2>&1)"
rc=$?
set -e
assert_eq "unremediated post-edit skip exits 4 (refused)" "4" "${rc}"
assert_contains "rejection names the recovery path" "Re-run the reviewer" "${out}"
# State must NOT have been mutated
assert_eq "gate_skip_reason NOT set after refusal" "" "$(read_state_field 'gate_skip_reason')"
teardown

# OMC_ULW_SKIP_FORCE=1 overrides (audited)
setup
write_state_field "review_had_findings" "true"
write_state_int "last_review_ts" "1000"
write_state_int "last_edit_ts" "2000"
out="$(OMC_ULW_SKIP_FORCE=1 "${HOOK_DIR}/ulw-skip-register.sh" "force override for unblocked CI" 2>&1)"
rc=$?
assert_eq "FORCE override exits 0" "0" "${rc}"
assert_contains "skip registered after force" "force override for unblocked CI" "$(read_state_field 'gate_skip_reason')"
# v1.42.x audit symmetry: ulw-skip already logged the force-bypass
# event; the missing piece was the per-session counter. With
# ulw_skip_force_count surfaced in /ulw-status, routine misuse of
# the escape valve becomes visible at-a-glance.
assert_eq "ulw-skip FORCE emits force-bypass event" "1" "$(gate_event_exists 'ulw-skip' 'force-bypass')"
assert_eq "ulw_skip_force_count incremented" "1" "$(read_state_field 'ulw_skip_force_count')"
teardown

# No findings → skip works as expected (not gated)
setup
write_state_int "last_edit_ts" "2000"
out="$("${HOOK_DIR}/ulw-skip-register.sh" "false-positive gate" 2>&1)"
rc=$?
assert_eq "skip with no review_had_findings exits 0" "0" "${rc}"
teardown

# ===========================================================================
# v1.42.x quality-reviewer F-1: prompt_classified_intent IS written by the
# router. Pre-fix the backstop at stop-guard.sh was dead code because
# nothing wrote the key. This test grep-checks the router script for the
# write so a future refactor that removes it fails this assertion.
# ===========================================================================
printf '\n=== F-1: router writes prompt_classified_intent (backstop wiring) ===\n'

ROUTER_PATH="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
if grep -q '"prompt_classified_intent" "${TASK_INTENT}"' "${ROUTER_PATH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: router does not write prompt_classified_intent — F-005 backstop is dead code\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# v1.42.x quality-reviewer F-2: empty-notes-on-rejected refusal
# ===========================================================================
printf '\n=== F-2: record-finding-list rejected with empty notes refused ===\n'

setup
RFL="${HOOK_DIR}/record-finding-list.sh"
FINDINGS_FILE="${STATE_ROOT}/${SESSION_ID}/findings.json"
cat > "${FINDINGS_FILE}" <<EOF
{
  "schema_v": 1,
  "ts": 1000,
  "updated_ts": 1000,
  "findings": [
    {"id":"F-001","summary":"test","severity":"low","surface":"x","status":"pending","commit_sha":"","notes":""}
  ]
}
EOF
set +e
out="$("${RFL}" status F-001 rejected aaaa "" 2>&1)"
rc=$?
set -e
assert_eq "empty-notes rejected refuses exit 2" "2" "${rc}"
assert_contains "refusal names the bypass shape" "empty notes" "${out}"

out="$("${RFL}" status F-001 rejected aaaa "duplicate" 2>&1)"
rc=$?
assert_eq "concrete notes rejected passes" "0" "${rc}"

cat > "${FINDINGS_FILE}" <<EOF
{
  "schema_v": 1,
  "ts": 1000,
  "updated_ts": 1000,
  "findings": [
    {"id":"F-002","summary":"test","severity":"low","surface":"x","status":"pending","commit_sha":"","notes":""}
  ]
}
EOF
set +e
out="$("${RFL}" status F-002 rejected aaaa "by design" 2>&1)"
rc=$?
set -e
assert_eq "bare 'by design' on rejected refuses" "2" "${rc}"
teardown

# ===========================================================================
# v1.42.x quality-reviewer F-3: advisory-no-findings threshold is 2
# ===========================================================================
printf '\n=== F-3: advisory-no-findings threshold lowered to 2 ===\n'

grep -q '^OMC_ADVISORY_NO_FINDINGS_THRESHOLD="\${OMC_ADVISORY_NO_FINDINGS_THRESHOLD:-2}"' "${HOOK_DIR}/common.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: common.sh default not 2\n'; fail=$((fail + 1)); }
grep -q '^#advisory_no_findings_threshold=2' "${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example" \
  && pass=$((pass + 1)) || { printf '  FAIL: conf example default not 2\n'; fail=$((fail + 1)); }
grep -q '^advisory_no_findings_threshold|int|2|' "${HOOK_DIR}/omc-config.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: omc-config default not 2\n'; fail=$((fail + 1)); }

# ===========================================================================
# v1.42.x quality-reviewer F-5: pause validator requires externalizing verb
# ===========================================================================
printf '\n=== F-5: pause validator requires externalizing verb with judgment-token ===\n'

setup
set +e
out="$("${HOOK_DIR}/ulw-pause.sh" "library choice — needs user input" 2>&1)"
rc=$?
set -e
assert_eq "user-input without externalizing verb refuses" "2" "${rc}"
teardown

setup
out="$("${HOOK_DIR}/ulw-pause.sh" "library choice — blocked by stakeholder approval" 2>&1)"
rc=$?
assert_eq "judgment+operational+externalizing verb passes" "0" "${rc}"
teardown

# ===========================================================================
# v1.42.x quality-reviewer F-7: cross-product F-001 + F-005
# ===========================================================================
printf '\n=== F-7: cross-product handoff regex + intent-flip in same fixture ===\n'

setup
write_state_field "task_intent" "execution"
write_state_int "last_user_prompt_ts" "1000"
write_state_int "last_edit_ts" "2000"
set +e
out="$("${HOOK_DIR}/ulw-correct-record.sh" "actually advisory intent=advisory — for a follow-up commit" 2>&1)"
rc=$?
set -e
assert_eq "cross-product: intent-flip refused" "4" "${rc}"
set +e
bash -c '
  SCRIPT_DIR="'"${HOOK_DIR}"'"
  . "${SCRIPT_DIR}/common.sh"
  has_unfinished_session_handoff "actually advisory intent=advisory — for a follow-up commit"
'
rc=$?
set -e
assert_eq "cross-product: handoff regex also catches" "0" "${rc}"
teardown

# ===========================================================================
# F-012: agent-first-gate opt-in (v1.43+) — Stop backstop must respect the
# new flag at all three surfaces: (a) silent when state-at-mutation was
# `off`, (b) fires when state-at-mutation was `on`, (c) lockstep grep
# that stop-guard.sh reads the recorded state, not the live env var.
# Defense rationale: when the PreTool block becomes opt-in, the Stop
# backstop must NOT silently fire under default-off — that would
# defeat the opt-out at a different surface. Mirrors the per-surface
# tests in test-pretool-intent-guard.sh (T_aff_off_*) but at the Stop
# layer where the umbrella is the only regression net (no dedicated
# Stop-time per-surface test exists for this flag).
# Closes excellence-reviewer F1 (release-readiness gap).
# ===========================================================================
printf '\n=== F-012: agent-first-gate opt-in Stop backstop semantics ===\n'

# (a) state-at-mutation=off → backstop silent.
# Set up a state where first_mutation_ts is recorded but
# agent_first_gate_state is "off" (the default-off opt-out path).
# Stop hook should NOT block.
setup
write_state_field "task_intent" "execution"
write_state_int "first_mutation_ts" "1000"
write_state_field "first_mutation_tool" "Edit"
write_state_field "agent_first_gate_state" "off"
# Run stop-guard and capture its exit code + output. The backstop reads
# agent_first_gate_state; with "off", it should fall through without
# emitting a block payload at the agent-first surface.
out_a="$(printf '%s' "$(jq -nc --arg s "${SESSION_ID}" '{session_id:$s,hook_event_name:"Stop"}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>&1 || true)"
# Backstop block payload contains "/ulw work mutated before any fresh-context specialist"
if [[ "${out_a}" == *"/ulw work mutated before any fresh-context specialist"* ]]; then
  printf '  FAIL: F-012a: agent_first_gate_state=off must NOT fire backstop (got block)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown

# (b) state-at-mutation=on + no specialist → backstop FIRES.
setup
write_state_field "task_intent" "execution"
write_state_int "first_mutation_ts" "1000"
write_state_field "first_mutation_tool" "Edit"
write_state_field "agent_first_gate_state" "on"
# No agent_first_specialist_ts set → backstop fires.
out_b="$(printf '%s' "$(jq -nc --arg s "${SESSION_ID}" '{session_id:$s,hook_event_name:"Stop"}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>&1 || true)"
if [[ "${out_b}" == *"/ulw work mutated before any fresh-context specialist"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-012b: agent_first_gate_state=on (no specialist) must fire backstop (got: %s)\n' "${out_b}" >&2
  fail=$((fail + 1))
fi
teardown

# (c) state-at-mutation=on + specialist ran → backstop silent.
setup
write_state_field "task_intent" "execution"
write_state_int "first_mutation_ts" "1000"
write_state_field "first_mutation_tool" "Edit"
write_state_field "agent_first_gate_state" "on"
write_state_int "agent_first_specialist_ts" "1500"
out_c="$(printf '%s' "$(jq -nc --arg s "${SESSION_ID}" '{session_id:$s,hook_event_name:"Stop"}')" \
  | bash "${HOOK_DIR}/stop-guard.sh" 2>&1 || true)"
if [[ "${out_c}" == *"/ulw work mutated before any fresh-context specialist"* ]]; then
  printf '  FAIL: F-012c: gate=on + specialist returned must NOT fire backstop (got block)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
teardown

# (d) Lockstep grep — stop-guard.sh must read the state field, not the
# live env var. Future refactor that flipped this back to OMC_AGENT_FIRST_GATE
# would re-introduce the toggle-flip footgun.
if grep -q 'gate_state_at_mutation=.*read_state.*"agent_first_gate_state"' "${HOOK_DIR}/stop-guard.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-012d: stop-guard.sh must read agent_first_gate_state from state, not OMC_AGENT_FIRST_GATE\n' >&2
  fail=$((fail + 1))
fi

# (e) Lockstep grep — both writers (pretool-intent-guard.sh, mark-edit.sh)
# must stamp agent_first_gate_state. A refactor that dropped the field
# from either writer would leave Stop backstop silent for that path.
for writer in pretool-intent-guard.sh mark-edit.sh; do
  if grep -q '"agent_first_gate_state"' "${HOOK_DIR}/${writer}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: F-012e: %s must stamp agent_first_gate_state on first_mutation_ts capture\n' "${writer}" >&2
    fail=$((fail + 1))
  fi
done

# ===========================================================================
# F-013: project-conf security flag deny-list (v1.43+ security-lens P1).
# A malicious or unfamiliar repo's `.claude/oh-my-claude.conf` must NOT
# be able to disable security-load-bearing gates the user opted into
# via their user-level `${HOME}/.claude/oh-my-claude.conf`. The deny-
# list is narrow: pretool_intent_guard, bg_spawn_gate, agent_first_gate,
# no_defer_mode. All other flags can still be project-overridden.
# ===========================================================================
printf '\n=== F-013: project-conf security flag deny-list ===\n'

# (a) _parse_conf_file must accept a `level` argument and refuse
# security flags when level=project. Grep anchors on the closing `)`
# (case-statement marker) so a refactor that removed the actual
# case-statement while leaving the bare comment block would NOT pass
# this regression (quality-reviewer Wave 2 F3 follow-up).
if grep -q 'pretool_intent_guard|bg_spawn_gate|agent_first_gate|no_defer_mode)' "${HOOK_DIR}/common.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-013a: common.sh case-statement must restrict pretool_intent_guard/bg_spawn_gate/agent_first_gate/no_defer_mode from project conf\n' >&2
  fail=$((fail + 1))
fi

# (b) load_conf must pass "project" when calling _parse_conf_file for
# the walk-up path.
if grep -q '_parse_conf_file "\${_dir}/.claude/oh-my-claude.conf" "project"' "${HOOK_DIR}/common.sh"; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-013b: load_conf must pass level=project when parsing the project conf\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# F-014: objective-completion contract gate (v1.46-pre Codex /goal port).
# A new hard-block-capable gate is a bypass surface by definition — the
# model will try to route around it (intent-flip = the F-005 surface). This
# section asserts (a) it actually blocks a substantive unaudited execution
# cycle end-to-end, (b) intent-flip to advisory cannot bypass it (reuses the
# F-005 _effective_intent override), and (c) an explicit objective-coverage
# attestation clears it. Coordination rule: a relaxation of any of these
# must update this section consciously.
# ===========================================================================
printf '\n=== F-014: objective-completion contract gate ===\n'

# Reach the clean block (after review/verify) on a SUBSTANTIVE objective-cycle:
# review+verify clocks past the code edit, no findings, 6 unique files this
# cycle (>= default min_files=4), unaudited. GATE_LEVEL=basic skips the
# full-only review-coverage/excellence gates so the objective-contract gate
# is the one that fires.
_oc_reach_gate_state() {
  # All numeric clocks/counters are stored as STRINGS — production write_state
  # stringifies every value (`jq --arg`), and the bulk read_state_keys reader
  # the stop-guard uses returns empty for raw JSON numbers (it expects the
  # string form). write_state_int would store real numbers and silently
  # misframe the bulk read, releasing before the gate. (Confirmed via od -c.)
  write_state_field "task_intent" "$1"
  write_state_field "prompt_classified_intent" "execution"
  write_state_field "current_objective" "ship the big multi-part feature end to end across api, ui, and tests"
  write_state_field "last_user_prompt_ts" "100"
  write_state_field "last_edit_ts" "200"
  write_state_field "last_code_edit_ts" "150"
  write_state_field "last_review_ts" "300"
  write_state_field "last_verify_ts" "300"
  write_state_field "last_verify_outcome" "passed"
  write_state_field "last_verify_confidence" "80"
  write_state_field "code_edit_count" "6"
  write_state_field "doc_edit_count" "0"
  write_state_field "objective_contract_edit_baseline" "0"
  write_state_field "objective_contract_prompt_ts" "100"
  write_state_field "objective_contract_audited_ts" ""
  write_state_field "objective_contract_blocks" "0"
}

# (a) blocks a substantive unaudited execution cycle + re-anchors the objective
setup
_oc_reach_gate_state "execution"
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "Done. Wired the API handler and added a test." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_contains "F-014a: blocks substantive unaudited cycle" '"decision":"block"' "${out}"
assert_contains "F-014a: names the objective-contract gate" "Objective-contract gate" "${out}"
assert_contains "F-014a: re-anchors the verbatim original objective" "ship the big multi-part feature" "${out}"
teardown

# (b) intent-flip resistance: task_intent downgraded to advisory mid-turn, but
# prompt_classified_intent=execution AND edits landed after the prompt, so the
# F-005 _effective_intent override keeps the gate armed.
setup
_oc_reach_gate_state "advisory"
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "Done. Wired the handler." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_contains "F-014b: intent-flip to advisory cannot bypass (effective_intent override)" "Objective-contract gate" "${out}"
teardown

# (c) coverage attestation + a RECORDED fresh-context audit this cycle
# (last_excellence_review_ts > prompt_ts) clears the gate.
setup
_oc_reach_gate_state "execution"
write_state_field "last_excellence_review_ts" "350"   # fresh audit, > prompt_ts=100
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "All parts done.

**Objective coverage.** api: shipped; ui: shipped; tests: shipped; fresh excellence-review found no cost/risk-deferred omissions." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_not_contains "F-014c: coverage attestation + fresh audit clears the gate" "Objective-contract gate" "${out}"
teardown

# (g) v1.46 would_have_armed telemetry: a NON-substantive open-mandate cycle
# (open_mandate flag set, real edits this cycle, but code_edit_count < min_files
# and no planner -> is_substantive false) does NOT block (telemetry-only) but
# DOES emit a would_have_armed gate event — the tiny-subset blind-spot rate the
# gate's own decline names as the precondition for ever arming on the detector.
_oc_wha_state() {
  write_state_field "task_intent" "execution"
  write_state_field "prompt_classified_intent" "execution"
  write_state_field "current_objective" "make it better"
  write_state_field "last_user_prompt_ts" "100"
  write_state_field "last_edit_ts" "200"
  write_state_field "last_code_edit_ts" "150"
  write_state_field "last_review_ts" "300"
  write_state_field "last_verify_ts" "300"
  write_state_field "last_verify_outcome" "passed"
  write_state_field "last_verify_confidence" "80"
  write_state_field "code_edit_count" "2"   # < min_files=4 -> NOT substantive
  write_state_field "doc_edit_count" "0"
  write_state_field "objective_contract_edit_baseline" "0"
  write_state_field "objective_contract_prompt_ts" "100"
  write_state_field "objective_contract_audited_ts" ""
  write_state_field "objective_contract_blocks" "0"
}
setup
_oc_wha_state
write_state_field "objective_contract_open_mandate" "1"
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "Shipped a small fix." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_not_contains "F-014g: would_have_armed does NOT block (telemetry-only)" "Objective-contract gate" "${out}"
assert_eq "F-014g: would_have_armed event emitted on the tiny-subset open-mandate cycle" "1" "$(gate_event_exists "objective-contract" "would_have_armed")"
teardown

# control: the SAME tiny cycle WITHOUT the open_mandate flag emits NO event.
setup
_oc_wha_state
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "Shipped a small fix." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_eq "F-014g-control: no would_have_armed without the open_mandate flag" "0" "$(gate_event_exists "objective-contract" "would_have_armed")"
teardown

# (f) MANUFACTURED-FINISH-LINE FIX: a coverage attestation WITHOUT a recorded
# fresh-context audit this cycle must NOT clear — self-attestation by the
# drifted model is the corrupt witness the gate now refuses. This is the
# bypass-relevant invariant: the model cannot self-attest past the gate.
setup
_oc_reach_gate_state "execution"   # note: NO last_excellence_review_ts set
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "All parts done.

**Objective coverage.** api: shipped; ui: shipped; tests: shipped." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_contains "F-014f: attestation WITHOUT a fresh audit does NOT clear (still blocks)" "Objective-contract gate" "${out}"
teardown
# (f2) a STALE prior-cycle audit (ts <= prompt_ts) also does not clear.
setup
_oc_reach_gate_state "execution"
write_state_field "last_excellence_review_ts" "50"    # stale, < prompt_ts=100
out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "All parts done.

**Objective coverage.** all shipped." \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | OMC_GATE_LEVEL=basic "${HOOK_DIR}/stop-guard.sh")"
assert_contains "F-014f2: stale prior-cycle audit does NOT clear (still blocks)" "Objective-contract gate" "${out}"
teardown

# (d) self-disarm wiring: the router must stamp objective_contract_prompt_ts
# ONLY on fresh execution intent (so non-execution follow-up turns are inert).
if grep -q 'objective_contract_prompt_ts' "${ROUTER_PATH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-014d: router does not stamp objective_contract_prompt_ts — self-disarm wiring missing\n' >&2
  fail=$((fail + 1))
fi
# (e) intent-flip resistance wiring: the gate must key on _effective_intent
# (the F-005 override), not raw task_intent.
if grep -q 'is_execution_intent_value "${_effective_intent}"' "${HOOK_DIR}/stop-guard.sh" \
  && grep -A40 'Objective-completion contract gate' "${HOOK_DIR}/stop-guard.sh" | grep -q '_effective_intent'; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-014e: objective-contract gate must key on _effective_intent (intent-flip resistance)\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Sentinel: every coordination rule met (file existence + bundle wiring)
# ===========================================================================
printf '\n=== Coordination sentinel: bundle wiring sanity ===\n'

# objective_contract_gate present in all three conf sites (v1.46-pre)
grep -q '^#objective_contract_gate=on' "${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example" \
  && pass=$((pass + 1)) || { printf '  FAIL: objective_contract_gate not in conf example\n'; fail=$((fail + 1)); }
grep -q 'objective_contract_gate)' "${HOOK_DIR}/common.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: objective_contract_gate not in parser\n'; fail=$((fail + 1)); }
grep -q '^objective_contract_gate|' "${HOOK_DIR}/omc-config.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: objective_contract_gate not in omc-config\n'; fail=$((fail + 1)); }

# Conf example documents both new flags
grep -q '^#advisory_no_findings_gate=on' "${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example" \
  && pass=$((pass + 1)) || { printf '  FAIL: advisory_no_findings_gate not in conf example\n'; fail=$((fail + 1)); }
grep -q '^#ulw_pause_validator=on' "${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example" \
  && pass=$((pass + 1)) || { printf '  FAIL: ulw_pause_validator not in conf example\n'; fail=$((fail + 1)); }

# Parser case handles the new flags
grep -q 'advisory_no_findings_gate)' "${HOOK_DIR}/common.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: advisory_no_findings_gate not in parser\n'; fail=$((fail + 1)); }
grep -q 'ulw_pause_validator)' "${HOOK_DIR}/common.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: ulw_pause_validator not in parser\n'; fail=$((fail + 1)); }

# omc-config table has the new flags
grep -q '^advisory_no_findings_gate|' "${HOOK_DIR}/omc-config.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: advisory_no_findings_gate not in omc-config\n'; fail=$((fail + 1)); }
grep -q '^ulw_pause_validator|' "${HOOK_DIR}/omc-config.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: ulw_pause_validator not in omc-config\n'; fail=$((fail + 1)); }

# v1.43 oracle Wave 4: standalone bypass-taxonomy doc must exist + name all four categories.
BYPASS_DOC="${REPO_ROOT}/docs/bypass-taxonomy.md"
[[ -f "${BYPASS_DOC}" ]] \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: docs/bypass-taxonomy.md (standalone bypass-surface field guide) missing\n'; fail=$((fail + 1)); }
if [[ -f "${BYPASS_DOC}" ]]; then
  for cat in 'state-predicate' 'prose-pattern' 'single-call-flip' 'classifier-misroute'; do
    grep -q "${cat}" "${BYPASS_DOC}" \
      && pass=$((pass + 1)) \
      || { printf '  FAIL: docs/bypass-taxonomy.md missing category %q\n' "${cat}"; fail=$((fail + 1)); }
  done
fi
# AGENTS.md must cross-reference the standalone doc (lift, not orphan).
grep -q 'docs/bypass-taxonomy.md' "${REPO_ROOT}/AGENTS.md" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: AGENTS.md no longer cross-references docs/bypass-taxonomy.md\n'; fail=$((fail + 1)); }
# README must surface the doc in its docs index.
grep -q 'docs/bypass-taxonomy.md' "${REPO_ROOT}/README.md" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: README.md docs index no longer links to bypass-taxonomy.md\n'; fail=$((fail + 1)); }

# v1.46-pre: the background-dispatch waiting note (bg_work_dispatched_ts ->
# format_gate_block_dual) is MESSAGE-ONLY and must NOT become a bypass
# vector. A block that would fire MUST still fire when the bg marker is set
# (decision unchanged); the note is purely additive. Full behavioral
# coverage in tests/test-background-wait-note.sh — this is the cross-cutting
# invariant the umbrella owns: dispatching background work cannot suppress a
# gate. If a future edit lets the note path short-circuit a block, this fails.
printf '\n=== v1.46-pre: bg-dispatch note is message-only (not a bypass) ===\n'
setup
write_state_field "task_intent" "execution"
write_state_field "current_objective" "ship it"
write_state_int "last_user_prompt_ts" 100
write_state_int "last_edit_ts" 200
write_state_field "bg_work_dispatched_ts" "150"
_bg_block_msg='Next. If you want Wave 7-9 shipped in this session, I can continue -- say "keep going" and name which to prioritize.'
_bg_out="$(jq -n --arg sid "${SESSION_ID}" --arg msg "${_bg_block_msg}" \
  '{session_id:$sid, stop_hook_active:false, last_assistant_message:$msg}' \
  | "${HOOK_DIR}/stop-guard.sh")"
assert_contains "bg marker does NOT suppress the block (decision unchanged)" '"decision":"block"' "${_bg_out}"
assert_contains "bg block carries the additive waiting note" 'this block is expected' "${_bg_out}"
teardown

printf '\n=== Stop-Guard Bypass Surface: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
