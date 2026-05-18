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
}

teardown() {
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

# FP guards: must NOT match (block storms would otherwise fire on common
# non-handoff prose)
printf 'FP guards: legitimate non-handoff prose must NOT match\n'
for phrase in "The next pass through the loop normalizes the data." \
              "I have a follow-up question about that." \
              "The job is queued behind the request." \
              "We addressed all findings this iteration." \
              "The continuation classifier treats keep going as a continuation prompt." \
              "If you want, I can continue explaining the tradeoffs."; do
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
        *) return 1 ;;
      esac
      [[ -n "${text}" ]] || return 1
      local len="${#text}"
      if [[ "${len}" -lt 200 ]]; then
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
# Sentinel: every coordination rule met (file existence + bundle wiring)
# ===========================================================================
printf '\n=== Coordination sentinel: bundle wiring sanity ===\n'

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

printf '\n=== Stop-Guard Bypass Surface: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
