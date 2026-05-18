#!/usr/bin/env bash
# test-ulw-pause.sh — coverage for the /ulw-pause skill (v1.18.0).
#
# Validates the ulw-pause.sh helper script (state writes, cap, validation,
# gate event), the stop-guard.sh carve-out (handoff gate skipped when
# pause active), and the prompt-intent-router clearing the flag at the
# next user prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
ULW_PAUSE="${HOOK_DIR}/ulw-pause.sh"
STOP_GUARD="${HOOK_DIR}/stop-guard.sh"

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
  export SESSION_ID="ulw-pause-test"
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
  printf '{}\n' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
}

teardown() {
  rm -rf "${TEST_HOME}"
  unset HOME STATE_ROOT SESSION_ID
}

read_state_field() {
  local field="$1"
  jq -r --arg k "${field}" '.[$k] // empty' \
    "${STATE_ROOT}/${SESSION_ID}/session_state.json" 2>/dev/null
}

# ---------------------------------------------------------------------
printf 'Test 1: empty reason rejected\n'
setup
set +e
out="$("${ULW_PAUSE}" "" 2>&1)"
rc=$?
set -e
assert_eq "empty reason exit code 2" "2" "${rc}"
assert_contains "empty reason error message" "non-empty reason" "${out}"
# State must NOT have been touched
flag="$(read_state_field "ulw_pause_active")"
assert_eq "empty reason: ulw_pause_active not set" "" "${flag}"
teardown

# ---------------------------------------------------------------------
printf 'Test 2: whitespace-only reason rejected\n'
setup
set +e
out="$("${ULW_PAUSE}" "   " 2>&1)"
rc=$?
set -e
assert_eq "whitespace reason exit code 2" "2" "${rc}"
teardown

# ---------------------------------------------------------------------
printf 'Test 3: newline in reason rejected\n'
setup
set +e
out="$("${ULW_PAUSE}" "$(printf 'line1\nline2')" 2>&1)"
rc=$?
set -e
assert_eq "newline reason exit code 2" "2" "${rc}"
assert_contains "newline reason error" "newlines" "${out}"
teardown

# ---------------------------------------------------------------------
printf 'Test 4: missing SESSION_ID rejected\n'
setup
unset SESSION_ID
set +e
out="$("${ULW_PAUSE}" "valid reason" 2>&1)"
rc=$?
set -e
assert_eq "no session exit code 2" "2" "${rc}"
assert_contains "no session error" "no active session" "${out}"
teardown

# ---------------------------------------------------------------------
printf 'Test 5: first pause sets flag, count=1, records gate event\n'
setup
# v1.42.x stop-guard bypass closure (Bypass-Surface F-003): the v1.40.0
# pause carve-out is operational-only; the pre-v1.42.x test fixture
# "user must pick copy A vs B" is exactly the technical-judgment
# anti-pattern the new validator catches (copy/A-vs-B = brand-voice
# call, the agent's to make under ULW). Replaced with a legitimately-
# operational reason that names a credential / authorization block.
out="$("${ULW_PAUSE}" "awaiting user authorization to push tag to remote" 2>&1)"
rc=$?
assert_eq "first pause exit code 0" "0" "${rc}"
assert_eq "ulw_pause_active=1" "1" "$(read_state_field 'ulw_pause_active')"
assert_eq "ulw_pause_count=1" "1" "$(read_state_field 'ulw_pause_count')"
assert_eq "ulw_pause_reason set" "awaiting user authorization to push tag to remote" "$(read_state_field 'ulw_pause_reason')"
assert_contains "stdout reports 1/2" "1/2" "${out}"

# Gate event recorded
events_file="${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
[[ -f "${events_file}" ]] && pass=$((pass + 1)) || { printf '  FAIL: gate_events.jsonl not created\n' >&2; fail=$((fail + 1)); }
last_event="$(tail -n 1 "${events_file}")"
assert_contains "event has gate=ulw-pause" '"gate":"ulw-pause"' "${last_event}"
assert_contains "event has event=ulw-pause" '"event":"ulw-pause"' "${last_event}"
assert_contains "event records pause_count=1" '"pause_count":1' "${last_event}"
assert_contains "event records reason" '"reason":"awaiting user authorization to push tag to remote"' "${last_event}"
teardown

# ---------------------------------------------------------------------
printf 'Test 6: second pause increments count to 2\n'
setup
"${ULW_PAUSE}" "first pause" >/dev/null
"${ULW_PAUSE}" "second pause" >/dev/null
assert_eq "ulw_pause_count=2 after second pause" "2" "$(read_state_field 'ulw_pause_count')"
assert_eq "ulw_pause_active=1 after second pause" "1" "$(read_state_field 'ulw_pause_active')"
teardown

# ---------------------------------------------------------------------
printf 'Test 7: third pause hits cap, exits 3, no state mutation\n'
setup
"${ULW_PAUSE}" "first pause" >/dev/null
"${ULW_PAUSE}" "second pause" >/dev/null
set +e
out="$("${ULW_PAUSE}" "third pause" 2>&1)"
rc=$?
set -e
assert_eq "third pause exit code 3 (cap reached)" "3" "${rc}"
assert_contains "cap message" "pause cap reached" "${out}"
# v1.18.x — cap-recovery copy now lists three concrete options including
# /ulw-skip as the escape valve. Without this, the cap creates a UX
# dead-end where the user has no path forward.
assert_contains "cap copy: option 1 resume" "Resume the work" "${out}"
assert_contains "cap copy: option 2 ask checkpoint" "checkpoint" "${out}"
assert_contains "cap copy: option 3 names /ulw-skip escape valve" "/ulw-skip" "${out}"
# Count must NOT have incremented
assert_eq "ulw_pause_count stays at 2 after cap" "2" "$(read_state_field 'ulw_pause_count')"
# Reason from prior pause preserved (not overwritten)
assert_eq "reason from second pause preserved" "second pause" "$(read_state_field 'ulw_pause_reason')"
teardown

# ---------------------------------------------------------------------
printf 'Test 8: stop-guard.sh source carries the ulw_pause_active carve-out\n'
# Static check that the pause-aware short-circuit is wired in front of
# the session-handoff gate's block path. A behavioral run-through is
# fragile (requires transcript parsing, intent state, etc.) — locking
# the source structure catches regressions reliably.
gate_text="$(cat "${STOP_GUARD}")"
assert_contains "stop-guard reads ulw_pause_active state" \
  'read_state "ulw_pause_active"' "${gate_text}"
assert_contains "stop-guard short-circuits handoff gate when pause=1" \
  '${ulw_pause_active}" != "1"' "${gate_text}"
# The short-circuit must live in the same conditional as has_unfinished_session_handoff
# so the gate's block path is only entered when pause is not active.
if grep -B 2 -A 4 'has_unfinished_session_handoff' "${STOP_GUARD}" \
    | grep -q 'ulw_pause_active'; then
  pass=$((pass + 1))
else
  printf '  FAIL: ulw_pause_active check not adjacent to has_unfinished_session_handoff\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 9: stop-guard recovery copy mentions /ulw-pause\n'
# The recovery line should name /ulw-pause as the structured affordance
# for legitimate pauses. Without this, users have no way to discover the
# new skill at the moment they need it.
gate_text="$(cat "${STOP_GUARD}")"
assert_contains "stop-guard recovery names /ulw-pause" "/ulw-pause" "${gate_text}"

# ---------------------------------------------------------------------
printf 'Test 10: prompt-intent-router clears ulw_pause_active at next prompt\n'
# Verify the router's write_state_batch includes ulw_pause_active reset
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
router_text="$(cat "${ROUTER}")"
assert_contains "router clears ulw_pause_active" \
  '"ulw_pause_active" ""' "${router_text}"

# ---------------------------------------------------------------------
printf 'Test 11: SKILL.md exists and documents the cap + use cases\n'
SKILL_MD="${REPO_ROOT}/bundle/dot-claude/skills/ulw-pause/SKILL.md"
[[ -f "${SKILL_MD}" ]] && pass=$((pass + 1)) || { printf '  FAIL: SKILL.md missing\n' >&2; fail=$((fail + 1)); }
skill_text="$(cat "${SKILL_MD}")"
assert_contains "SKILL.md describes 2/session cap" "2 pauses per session" "${skill_text}"
assert_contains "SKILL.md distinguishes from /ulw-skip" "/ulw-skip" "${skill_text}"
assert_contains "SKILL.md distinguishes from /mark-deferred" "/mark-deferred" "${skill_text}"
assert_contains "SKILL.md names argument-hint" "argument-hint:" "${skill_text}"

# ---------------------------------------------------------------------
printf 'Test 12: verify.sh and uninstall.sh both register the new skill\n'
verify_text="$(cat "${REPO_ROOT}/verify.sh")"
uninstall_text="$(cat "${REPO_ROOT}/uninstall.sh")"
assert_contains "verify.sh lists ulw-pause SKILL.md" \
  "skills/ulw-pause/SKILL.md" "${verify_text}"
assert_contains "verify.sh lists ulw-pause.sh script" \
  "ulw-pause.sh" "${verify_text}"
assert_contains "uninstall.sh lists ulw-pause skill dir" \
  "skills/ulw-pause" "${uninstall_text}"

# ---------------------------------------------------------------------
printf 'Test 13: skill-list files reference /ulw-pause\n'
SKILLS_MEM="${REPO_ROOT}/bundle/dot-claude/quality-pack/memory/skills.md"
SKILLS_INDEX="${REPO_ROOT}/bundle/dot-claude/skills/skills/SKILL.md"
README_MD="${REPO_ROOT}/README.md"
assert_contains "memory/skills.md mentions /ulw-pause" "/ulw-pause" "$(cat "${SKILLS_MEM}")"
assert_contains "skills/SKILL.md lists /ulw-pause" "/ulw-pause" "$(cat "${SKILLS_INDEX}")"
assert_contains "README.md lists /ulw-pause" "/ulw-pause" "$(cat "${README_MD}")"

# ---------------------------------------------------------------------
printf 'Test 14: show-status surfaces maturity + pause state (v1.18.x F2)\n'
# Reviewer-found gap: /ulw-status cached the new state fields but never
# rendered them. Ship-the-data-without-the-surface anti-pattern.
SHOW_STATUS="${HOOK_DIR}/show-status.sh"
status_text="$(cat "${SHOW_STATUS}")"
assert_contains "show-status reads project_maturity field" \
  "project_maturity" "${status_text}"
assert_contains "show-status reads ulw_pause_active field" \
  "ulw_pause_active" "${status_text}"
assert_contains "show-status reads ulw_pause_count field" \
  "ulw_pause_count" "${status_text}"
assert_contains "show-status reads ulw_pause_reason field" \
  "ulw_pause_reason" "${status_text}"
assert_contains "show-status renders Project maturity row" \
  "Project maturity:" "${status_text}"
assert_contains "show-status renders Pause State section" \
  "Pause State" "${status_text}"

# ---------------------------------------------------------------------
printf 'Test 15: show-report has user-decision queue section (v1.18.x F3)\n'
# Reviewer-found gap: Wave 4 emitted user-decision-marked events
# specifically so /ulw-report could audit the queue, but show-report
# never grew the surface.
SHOW_REPORT="${HOOK_DIR}/show-report.sh"
report_text="$(cat "${SHOW_REPORT}")"
assert_contains "show-report has user-decision queue heading" \
  "## User-decision queue" "${report_text}"
assert_contains "show-report scans findings.json for pending USER-DECISION" \
  "requires_user_decision" "${report_text}"
assert_contains "show-report renders 'Awaiting input now' subsection" \
  "Awaiting input now" "${report_text}"
assert_contains "show-report empty-state names mark-user-decision affordance" \
  "mark-user-decision" "${report_text}"

# ---------------------------------------------------------------------
# v1.42.x stop-guard bypass closure (Bypass-Surface F-003): /ulw-pause
# reason validator. Reject technical-judgment categories the agent OWNS
# under ULW v1.40.0 unless paired with an operational signal.
# ---------------------------------------------------------------------

printf 'Test 16: validator rejects bare technical-judgment reasons\n'
setup
# Bare taste/scope/library/brand reasons must reject (exit 2).
set +e
out="$("${ULW_PAUSE}" "user must pick library A vs B" 2>&1)"
rc=$?
set -e
assert_eq "library choice bare reason exits 2" "2" "${rc}"
assert_contains "rejection message names operational-only contract" "operational-only" "${out}"
assert_contains "rejection message names override env var" "OMC_ULW_PAUSE_FORCE" "${out}"
# State must NOT have changed
assert_eq "ulw_pause_active not set after rejected reason" "" "$(read_state_field 'ulw_pause_active')"
teardown

setup
set +e
out="$("${ULW_PAUSE}" "needs taste decision on color palette" 2>&1)"
rc=$?
set -e
assert_eq "taste/color bare reason exits 2" "2" "${rc}"
teardown

setup
set +e
out="$("${ULW_PAUSE}" "credible-approach split — refactor scope" 2>&1)"
rc=$?
set -e
assert_eq "refactor-scope bare reason exits 2" "2" "${rc}"
teardown

printf 'Test 17: validator accepts technical-judgment reasons paired with operational signal\n'
setup
# When a judgment-token is paired with an operational signal (stakeholder
# approval / credentials / etc.) the validator passes.
out="$("${ULW_PAUSE}" "library choice — blocked by stakeholder approval on license terms" 2>&1)"
rc=$?
assert_eq "paired reason exits 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 after paired reason" "1" "$(read_state_field 'ulw_pause_active')"
teardown

setup
out="$("${ULW_PAUSE}" "refactor scope — awaiting legal review" 2>&1)"
rc=$?
assert_eq "legal-review paired reason exits 0" "0" "${rc}"
teardown

printf 'Test 18: OMC_ULW_PAUSE_FORCE=1 overrides the validator (audited)\n'
setup
out="$(OMC_ULW_PAUSE_FORCE=1 "${ULW_PAUSE}" "library choice — refactor scope unknown" 2>&1)"
rc=$?
assert_eq "force-override exits 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 under force" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 19: ulw_pause_validator=off disables the validator (kill switch)\n'
setup
out="$(OMC_ULW_PAUSE_VALIDATOR=off "${ULW_PAUSE}" "user must pick copy A vs B" 2>&1)"
rc=$?
assert_eq "kill-switch exits 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 under kill switch" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf '\n=== ULW-Pause Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
