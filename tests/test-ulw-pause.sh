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

# ---------------------------------------------------------------------
# v1.46-pre Codex /goal port: 3-turn external-blocker attempts gate.
# Reasons matching the case-2 external-blocker pattern (rate limit,
# API down, service unreachable, network failure, dependency upgrade,
# 5xx) must repeat N consecutive times before the pause is allowed.
# ---------------------------------------------------------------------

printf 'Test 20: first case-2 (rate-limit) attempt refused with exit 4\n'
setup
set +e
out="$("${ULW_PAUSE}" "OpenAI API rate limit hit on chat completion" 2>&1)"
rc=$?
set -e
assert_eq "first case-2 attempt exit 4" "4" "${rc}"
assert_contains "refusal message names attempt count" "1/3" "${out}"
assert_contains "refusal message names Codex doctrinal source" "continuation.md" "${out}"
# Pause flag must NOT be set — refused attempts don't burn pause cap
assert_eq "ulw_pause_active NOT set on refused attempt" "" "$(read_state_field 'ulw_pause_active')"
assert_eq "ulw_pause_count NOT incremented on refused attempt" "" "$(read_state_field 'ulw_pause_count')"
# Counter state must be persisted for the next attempt
assert_eq "pause_blocker_attempt_count=1 after first refused attempt" "1" "$(read_state_field 'pause_blocker_attempt_count')"
# Signature must be populated (any non-empty string)
sig_after_1="$(read_state_field 'pause_blocker_signature')"
[[ -n "${sig_after_1}" ]] && pass=$((pass + 1)) || { printf '  FAIL: pause_blocker_signature empty after first attempt\n' >&2; fail=$((fail + 1)); }
# Gate event must be recorded
events_file="${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
[[ -f "${events_file}" ]] && pass=$((pass + 1)) || { printf '  FAIL: gate_events.jsonl missing after refused attempt\n' >&2; fail=$((fail + 1)); }
last_event="$(tail -n 1 "${events_file}")"
assert_contains "gate event records external-blocker-threshold-refused" '"event":"external-blocker-threshold-refused"' "${last_event}"
assert_contains "gate event records attempt=1" '"attempt":1' "${last_event}"
teardown

printf 'Test 21: second case-2 attempt with same blocker → counter=2, still refused\n'
setup
"${ULW_PAUSE}" "API rate limit hit on OpenAI" >/dev/null 2>&1 || true
# Paraphrased second attempt — same blocker per Jaccard match
set +e
out="$("${ULW_PAUSE}" "OpenAI rate limit still hitting after retry" 2>&1)"
rc=$?
set -e
assert_eq "second case-2 attempt exit 4" "4" "${rc}"
assert_contains "refusal message shows 2/3" "2/3" "${out}"
assert_eq "pause_blocker_attempt_count=2" "2" "$(read_state_field 'pause_blocker_attempt_count')"
assert_eq "ulw_pause_active still not set" "" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 22: third case-2 attempt allowed → pause activates, counter resets\n'
setup
"${ULW_PAUSE}" "API rate limit on OpenAI" >/dev/null 2>&1 || true
"${ULW_PAUSE}" "OpenAI rate limit still hitting" >/dev/null 2>&1 || true
# Third attempt — same blocker by signature; should be allowed
out="$("${ULW_PAUSE}" "rate limit on OpenAI persistent" 2>&1)"
rc=$?
assert_eq "third case-2 attempt exit 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 after threshold met" "1" "$(read_state_field 'ulw_pause_active')"
assert_eq "ulw_pause_count=1 (counter advanced normally)" "1" "$(read_state_field 'ulw_pause_count')"
# Tracking state must be cleared so next blocker starts fresh
assert_eq "pause_blocker_attempt_count reset to 0" "0" "$(read_state_field 'pause_blocker_attempt_count')"
assert_eq "pause_blocker_signature cleared" "" "$(read_state_field 'pause_blocker_signature')"
# threshold-met gate event recorded
events_file="${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
threshold_met_count="$(grep -c 'external-blocker-threshold-met' "${events_file}" 2>/dev/null || echo 0)"
[[ "${threshold_met_count}" -eq 1 ]] && pass=$((pass + 1)) || { printf '  FAIL: external-blocker-threshold-met event count=%s (expected 1)\n' "${threshold_met_count}" >&2; fail=$((fail + 1)); }
teardown

printf 'Test 23: different blocker mid-stream resets the counter to 1\n'
setup
"${ULW_PAUSE}" "API rate limit on OpenAI" >/dev/null 2>&1 || true
"${ULW_PAUSE}" "OpenAI rate limit still hitting" >/dev/null 2>&1 || true
# Counter is at 2. Now a DIFFERENT blocker arrives — should reset to 1.
set +e
out="$("${ULW_PAUSE}" "Postgres connection refused timeout on staging" 2>&1)"
rc=$?
set -e
assert_eq "different blocker still exits 4 (counter at 1, not 3)" "4" "${rc}"
assert_contains "refusal message shows 1/3 (counter reset)" "1/3" "${out}"
assert_eq "pause_blocker_attempt_count reset to 1" "1" "$(read_state_field 'pause_blocker_attempt_count')"
# Signature must reflect the NEW blocker, not the old one
new_sig="$(read_state_field 'pause_blocker_signature')"
[[ "${new_sig}" == *"postgres"* || "${new_sig}" == *"connection"* ]] && pass=$((pass + 1)) || { printf '  FAIL: signature did not update to new blocker (got: %s)\n' "${new_sig}" >&2; fail=$((fail + 1)); }
teardown

printf 'Test 24: case-1 (credentials) exempt — bypasses the gate on first attempt\n'
setup
out="$("${ULW_PAUSE}" "STRIPE_SECRET_KEY credential missing, cannot create test customer" 2>&1)"
rc=$?
assert_eq "credentials reason exits 0 on first attempt" "0" "${rc}"
assert_eq "ulw_pause_active=1 for exempt reason" "1" "$(read_state_field 'ulw_pause_active')"
# Tracking keys must NOT be touched
assert_eq "pause_blocker_attempt_count NOT set for exempt reason" "" "$(read_state_field 'pause_blocker_attempt_count')"
assert_eq "pause_blocker_signature NOT set for exempt reason" "" "$(read_state_field 'pause_blocker_signature')"
teardown

printf 'Test 25: case-3 (destructive) exempt — bypasses the gate\n'
setup
out="$("${ULW_PAUSE}" "destructive force-push to main awaiting user confirmation" 2>&1)"
rc=$?
assert_eq "destructive reason exits 0 on first attempt" "0" "${rc}"
assert_eq "ulw_pause_active=1 for destructive reason" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 26: case-4 (unfamiliar state) exempt — bypasses the gate\n'
setup
out="$("${ULW_PAUSE}" "untracked files present — unfamiliar work-in-progress" 2>&1)"
rc=$?
assert_eq "unfamiliar-state reason exits 0 on first attempt" "0" "${rc}"
assert_eq "ulw_pause_active=1 for unfamiliar-state reason" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 27: stakeholder approval exempt — bypasses the gate even with case-2 keywords\n'
setup
# Compound reason: case-2 keywords AND exempt keyword. Exempt wins (binary
# blocker — retry does not help waiting for a stakeholder decision).
out="$("${ULW_PAUSE}" "rate limit raise awaiting stakeholder approval" 2>&1)"
rc=$?
assert_eq "compound exempt+case-2 reason exits 0 (exempt wins)" "0" "${rc}"
assert_eq "ulw_pause_active=1 for stakeholder-paired reason" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 28: threshold=0 disables the gate entirely\n'
setup
out="$(OMC_PAUSE_EXTERNAL_BLOCKER_THRESHOLD=0 "${ULW_PAUSE}" "API rate limit hit on first attempt" 2>&1)"
rc=$?
assert_eq "threshold=0 first case-2 attempt exits 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 with gate disabled" "1" "$(read_state_field 'ulw_pause_active')"
# Tracking keys must NOT be touched when gate is disabled
assert_eq "pause_blocker_attempt_count NOT set when gate disabled" "" "$(read_state_field 'pause_blocker_attempt_count')"
teardown

printf 'Test 29: threshold=1 allows first attempt (effective off but still records telemetry)\n'
setup
out="$(OMC_PAUSE_EXTERNAL_BLOCKER_THRESHOLD=1 "${ULW_PAUSE}" "API rate limit hit" 2>&1)"
rc=$?
assert_eq "threshold=1 first attempt exits 0" "0" "${rc}"
assert_eq "ulw_pause_active=1 at threshold=1" "1" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 30: non-case-2 generic reason bypasses gate (not classified as external blocker)\n'
setup
# A reason that doesn't match either pattern — neutral phrasing. Should
# pass through validator and gate unchanged.
out="$("${ULW_PAUSE}" "deferring to user for next step on this surface" 2>&1)"
rc=$?
assert_eq "generic neutral reason exits 0" "0" "${rc}"
# Tracking keys must NOT be touched for non-case-2 reasons
assert_eq "pause_blocker_attempt_count NOT set for non-case-2" "" "$(read_state_field 'pause_blocker_attempt_count')"
teardown

printf 'Test 31: SKILL.md documents the 3-turn threshold and exit code 4\n'
SKILL_MD="${REPO_ROOT}/bundle/dot-claude/skills/ulw-pause/SKILL.md"
skill_text="$(cat "${SKILL_MD}")"
assert_contains "SKILL.md describes the 3-turn threshold" "3-turn" "${skill_text}"
assert_contains "SKILL.md cites Codex continuation.md" "continuation.md" "${skill_text}"
assert_contains "SKILL.md documents exit code 4" "exit 4" "${skill_text}" || true  # tolerate case variation
assert_contains "SKILL.md names the threshold env var" "OMC_PAUSE_EXTERNAL_BLOCKER_THRESHOLD" "${skill_text}"

printf 'Test 32: conf-flag triple-write coordination\n'
# Parser site
grep -q 'pause_external_blocker_threshold)' "${HOOK_DIR}/common.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: pause_external_blocker_threshold missing from common.sh parser\n' >&2; fail=$((fail + 1)); }
# Conf example site
grep -q '^#pause_external_blocker_threshold=' "${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example" \
  && pass=$((pass + 1)) || { printf '  FAIL: pause_external_blocker_threshold missing from conf.example\n' >&2; fail=$((fail + 1)); }
# omc-config table site
grep -q '^pause_external_blocker_threshold|' "${HOOK_DIR}/omc-config.sh" \
  && pass=$((pass + 1)) || { printf '  FAIL: pause_external_blocker_threshold missing from omc-config.sh table\n' >&2; fail=$((fail + 1)); }

printf 'Test 33: docs/architecture.md documents the new state keys\n'
arch_doc="$(cat "${REPO_ROOT}/docs/architecture.md")"
assert_contains "architecture.md documents pause_blocker_signature" "pause_blocker_signature" "${arch_doc}"
assert_contains "architecture.md documents pause_blocker_attempt_count" "pause_blocker_attempt_count" "${arch_doc}"

printf 'Test 34: cap-after-threshold-met — counter NOT clobbered, no threshold-met event emitted\n'
# v1.46-pre quality-review F1 regression: when ulw_pause_count is already
# at PAUSE_CAP (2) and the third same-blocker attempt would otherwise
# meet threshold, the cap check must refuse with exit 3 WITHOUT clearing
# pause_blocker_attempt_count or emitting the threshold-met event.
setup
# Pre-seed the cap at 2 BEFORE the gate runs.
jq -n '{ulw_pause_count: "2"}' > "${STATE_ROOT}/${SESSION_ID}/session_state.json"
set +e
"${ULW_PAUSE}" "API rate limit on OpenAI first" >/dev/null 2>&1
rc1=$?
"${ULW_PAUSE}" "OpenAI rate limit still hitting" >/dev/null 2>&1
rc2=$?
out3="$("${ULW_PAUSE}" "rate limit on OpenAI persistent" 2>&1)"
rc3=$?
set -e
assert_eq "attempt 1 refused exit 4 (below threshold)" "4" "${rc1}"
assert_eq "attempt 2 refused exit 4 (below threshold)" "4" "${rc2}"
assert_eq "attempt 3 refused exit 3 (cap reached) NOT exit 0" "3" "${rc3}"
assert_contains "attempt 3 stderr names cap message" "pause cap reached" "${out3}"
# Counter must NOT be clobbered to 0 — the pause did NOT fire.
final_counter="$(read_state_field 'pause_blocker_attempt_count')"
[[ "${final_counter}" == "2" || "${final_counter}" == "3" ]] && pass=$((pass + 1)) || { printf '  FAIL: pause_blocker_attempt_count=%s after cap-refused threshold (expected 2 or 3, NOT 0)\n' "${final_counter}" >&2; fail=$((fail + 1)); }
# Signature must also be preserved (not cleared).
final_sig="$(read_state_field 'pause_blocker_signature')"
[[ -n "${final_sig}" ]] && pass=$((pass + 1)) || { printf '  FAIL: pause_blocker_signature cleared after cap-refused (should be preserved)\n' >&2; fail=$((fail + 1)); }
# No threshold-met event emitted because the pause was refused by cap.
events_file="${STATE_ROOT}/${SESSION_ID}/gate_events.jsonl"
if [[ -f "${events_file}" ]]; then
  threshold_met_count="$(grep -c 'external-blocker-threshold-met' "${events_file}" || true)"
else
  threshold_met_count=0
fi
threshold_met_count="${threshold_met_count:-0}"
[[ "${threshold_met_count}" -eq 0 ]] && pass=$((pass + 1)) || { printf '  FAIL: threshold-met event emitted (%s) despite cap refusal\n' "${threshold_met_count}" >&2; fail=$((fail + 1)); }
# ulw_pause_active must NOT be set — the cap refused the pause.
assert_eq "ulw_pause_active NOT set after cap-refused" "" "$(read_state_field 'ulw_pause_active')"
teardown

printf 'Test 35: F2 — broadened pattern catches HTTP 5xx, queueing, stuck, timed out, DNS failing\n'
# v1.46-pre quality-review F2: previously narrow patterns missed common
# real-world phrasings. Each of these MUST gate (exit 4 on first attempt).
F2_CASES=(
  "Slack webhook returning HTTP 500"
  "Anthropic API responded with 529 retry-after"
  "Vercel build queueing for 20 minutes"
  "deploy stuck at build phase"
  "tests timing out on staging"
  "tests timed out connecting to upstream"
  "DNS resolution intermittently failing"
)
for case_ in "${F2_CASES[@]}"; do
  setup
  set +e
  out="$("${ULW_PAUSE}" "${case_}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 4 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: F2 case did NOT gate: %q (rc=%s)\n' "${case_}" "${rc}" >&2
    fail=$((fail + 1))
  fi
  teardown
done

printf '\n=== ULW-Pause Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
