#!/usr/bin/env bash
#
# test-mark-deferred.sh — regression coverage for mark-deferred.sh.
#
# v1.16.0 added /mark-deferred to give users a structured verb for the
# "I have consciously decided not to ship these advisory findings" path.
# Without this script the discovered-scope gate forced users to either
# address each finding inline in the summary or hit the block cap and
# release silently — both of which the gate's design treats as
# anti-patterns.
#
# Coverage:
#   1. Empty / whitespace-only reason rejected (exit 2)
#   2. Missing SESSION_ID + no discoverable session rejected (exit 2)
#   2b. SESSION_ID unset but session discoverable → fallback works (exit 0)
#   3. Missing scope file rejected (exit 2)
#   4. No pending rows is a no-op (exit 0)
#   5. Pending rows flipped to deferred with reason + ts_updated
#   6. Already-deferred rows preserved (reason untouched)
#   7. Shipped/in_progress/rejected rows preserved
#   8. Read-pending-scope-count returns 0 after the bulk defer (the
#      property the gate actually checks)
#   9. Atomic replace — the file is never half-written

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"
MARK_DEFERRED="${SCRIPTS_DIR}/mark-deferred.sh"

# Export STATE_ROOT BEFORE sourcing common.sh so the lib's source-time
# defaulting (`STATE_ROOT="${STATE_ROOT:-...}"`) picks up the test path
# rather than the user's real one. Today nothing in common.sh's
# source-time code performs I/O against STATE_ROOT, but a future
# refactor adding a startup sweep would silently touch the user's real
# state from this test if the export came after.
TEST_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${STATE_ROOT}"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${SCRIPTS_DIR}/common.sh"

pass=0
fail=0

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  rm -rf "${TEST_ROOT}"
}
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
    printf '  FAIL: %s\n    needle=%s\n    haystack=%s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

setup_session() {
  export SESSION_ID="$1"
  ensure_session_dir
  local file
  file="$(session_file "discovered_scope.jsonl")"
  rm -f "${file}"
  printf '%s' "$2" > "${file}"
}

# ===========================================================================
# Test 1: empty reason rejected
# ===========================================================================
printf 'empty reason rejected:\n'
export SESSION_ID="test-empty-reason"
ensure_session_dir
set +e
out="$(bash "${MARK_DEFERRED}" "" 2>&1)"; rc=$?
set -e
assert_eq "exit code 2" "2" "${rc}"
assert_contains "usage hint emitted" "non-empty reason" "${out}"

# ===========================================================================
# Test 2: whitespace-only reason rejected
# ===========================================================================
printf 'whitespace-only reason rejected:\n'
set +e
out="$(bash "${MARK_DEFERRED}" "    " 2>&1)"; rc=$?
set -e
assert_eq "whitespace exit 2" "2" "${rc}"

# ===========================================================================
# Test 3: missing SESSION_ID AND no discoverable session → rejected
# Uses an empty STATE_ROOT so discover_latest_session returns empty.
# ===========================================================================
printf 'missing SESSION_ID + no discoverable session rejected:\n'
EMPTY_STATE="$(mktemp -d)"
set +e
out="$(env -u SESSION_ID STATE_ROOT="${EMPTY_STATE}" bash "${MARK_DEFERRED}" "requires separate specialist review" 2>&1)"; rc=$?
set -e
rm -rf "${EMPTY_STATE}"
assert_eq "missing session exit 2" "2" "${rc}"
assert_contains "session_id message" "no active session" "${out}"

# ===========================================================================
# Test 3b: SESSION_ID unset but session discoverable → fallback succeeds
# Proves the discover_latest_session fallback introduced for the /mark-deferred
# skill invocation path (where hooks don't inject SESSION_ID via env).
# ===========================================================================
printf 'SESSION_ID unset but session discoverable — fallback works:\n'
export SESSION_ID="test-discover-fallback"
ensure_session_dir
scope_fb="$(session_file "discovered_scope.jsonl")"
printf '%s\n' '{"id":"fb00001","source":"metis","summary":"fallback test","severity":"high","status":"pending","reason":"","ts":"100"}' > "${scope_fb}"
set +e
out="$(env -u SESSION_ID bash "${MARK_DEFERRED}" "requires specialist — testing discover_latest_session fallback" 2>&1)"; rc=$?
set -e
assert_eq "discover fallback exit 0" "0" "${rc}"
assert_contains "discover fallback: row deferred" "Deferred 1 pending finding" "${out}"
post_status_fb="$(jq -r '.status' "${scope_fb}")"
assert_eq "discover fallback: row flipped to deferred" "deferred" "${post_status_fb}"

# ===========================================================================
# Test 4: missing scope file rejected (exit 2 — nothing to do)
# ===========================================================================
printf 'missing scope file rejected:\n'
export SESSION_ID="test-no-scope-file"
ensure_session_dir
set +e
out="$(bash "${MARK_DEFERRED}" "requires separate specialist review" 2>&1)"; rc=$?
set -e
assert_eq "no scope file exit 2" "2" "${rc}"
assert_contains "scope-missing message" "no discovered_scope.jsonl" "${out}"

# ===========================================================================
# Test 5: scope file with no pending rows → no-op (exit 0)
# ===========================================================================
printf 'no pending rows is a no-op:\n'
setup_session "test-no-pending" '{"id":"abc12345","source":"metis","summary":"already shipped","severity":"low","status":"shipped","reason":"done","ts":"100"}
'
set +e
out="$(bash "${MARK_DEFERRED}" "requires separate specialist review" 2>&1)"; rc=$?
set -e
assert_eq "no pending exit 0" "0" "${rc}"
assert_contains "no-op message" "No pending findings" "${out}"

# ===========================================================================
# Test 6: pending rows are flipped to deferred with reason
# ===========================================================================
printf 'pending rows flipped to deferred:\n'
setup_session "test-flip-pending" '{"id":"abc12345","source":"metis","summary":"finding A","severity":"high","status":"pending","reason":"","ts":"100"}
{"id":"def67890","source":"council/security-lens","summary":"finding B","severity":"medium","status":"pending","reason":"","ts":"101"}
{"id":"ghi11122","source":"council/data-lens","summary":"finding C","severity":"low","status":"shipped","reason":"fixed in commit","ts":"102"}
{"id":"jkl33344","source":"metis","summary":"finding D","severity":"medium","status":"deferred","reason":"prior defer","ts":"103"}
'
# v1.23.0: reason must include a named WHY clause (no bare "out of
# scope" / "not in scope" / "follow-up"). The SKILL.md acceptable
# shapes include 'requires <X>' and 'pending wave N'. The fixture
# below uses an explicit 'requires <X>, pending wave N' reason.
out="$(bash "${MARK_DEFERRED}" "requires database migration outside this session's surface, pending wave 5" 2>&1)"
assert_contains "deferred-count message" "Deferred 2 pending finding" "${out}"
assert_contains "gate-pass UX line" "Discovered-scope gate will pass" "${out}"

scope_file="$(session_file "discovered_scope.jsonl")"
# The two pending rows must now be deferred with the new reason and a ts_updated.
flipped="$(jq -r 'select(.id=="abc12345" or .id=="def67890") | "\(.status)|\(.reason)|\(has("ts_updated"))"' "${scope_file}" | sort -u)"
assert_eq "both flipped rows have status=deferred + reason + ts_updated" \
  "deferred|requires database migration outside this session's surface, pending wave 5|true" "${flipped}"

# ===========================================================================
# Test 7: pre-existing deferred rows are preserved (reason untouched)
# ===========================================================================
printf 'pre-existing deferred rows preserved:\n'
prior_reason="$(jq -r 'select(.id=="jkl33344") | .reason' "${scope_file}")"
assert_eq "prior deferred reason untouched" "prior defer" "${prior_reason}"
prior_ts_updated="$(jq -r 'select(.id=="jkl33344") | has("ts_updated")' "${scope_file}")"
assert_eq "prior deferred has no ts_updated" "false" "${prior_ts_updated}"

# ===========================================================================
# Test 8: shipped rows preserved
# ===========================================================================
printf 'shipped rows preserved:\n'
shipped_status="$(jq -r 'select(.id=="ghi11122") | .status' "${scope_file}")"
assert_eq "shipped row still shipped" "shipped" "${shipped_status}"
shipped_reason="$(jq -r 'select(.id=="ghi11122") | .reason' "${scope_file}")"
assert_eq "shipped reason untouched" "fixed in commit" "${shipped_reason}"

# ===========================================================================
# Test 9: gate-relevant property — read_pending_scope_count == 0
# This is the property the discovered-scope gate (stop-guard.sh) actually
# checks. If this fails the skill is technically broken regardless of
# what the per-row state shows.
#
# Re-export SESSION_ID explicitly here so this assertion stays bound to
# the test-flip-pending fixture even if a future test inserts a step
# that mutates SESSION_ID between Test 6 and Test 9.
# ===========================================================================
printf 'pending count is zero post-defer:\n'
export SESSION_ID="test-flip-pending"
post_pending="$(read_pending_scope_count)"
assert_eq "read_pending_scope_count returns 0" "0" "${post_pending}"

# Total row count must be unchanged (4 in, 4 out).
total_rows="$(wc -l < "${scope_file}" | tr -d '[:space:]')"
assert_eq "row count preserved" "4" "${total_rows}"

# ===========================================================================
# Test 10: in_progress and rejected rows preserved on a separate fixture
# (those statuses also count as non-pending in the gate's view).
# ===========================================================================
printf 'in_progress and rejected rows preserved:\n'
setup_session "test-other-statuses" '{"id":"aaa11111","source":"metis","summary":"in progress","severity":"high","status":"in_progress","reason":"","ts":"100"}
{"id":"bbb22222","source":"metis","summary":"rejected","severity":"medium","status":"rejected","reason":"not a defect","ts":"101"}
{"id":"ccc33333","source":"metis","summary":"pending","severity":"low","status":"pending","reason":"","ts":"102"}
'
bash "${MARK_DEFERRED}" "rolling into v1.17 — pending feature flag flip" >/dev/null

scope_file="$(session_file "discovered_scope.jsonl")"
ip_status="$(jq -r 'select(.id=="aaa11111") | .status' "${scope_file}")"
assert_eq "in_progress preserved" "in_progress" "${ip_status}"
rj_status="$(jq -r 'select(.id=="bbb22222") | .status' "${scope_file}")"
assert_eq "rejected preserved" "rejected" "${rj_status}"
new_def="$(jq -r 'select(.id=="ccc33333") | .status' "${scope_file}")"
assert_eq "previously-pending now deferred" "deferred" "${new_def}"

# ===========================================================================
# Test 11: tmp file is cleaned up across ALL sessions touched by the
# test run — not just the one we last edited. Atomic-replace
# correctness: a failed mv must rm the tmp; a successful mv must
# consume it; an interrupt mid-loop must rm the tmp via the trap. This
# wider sweep catches leaks from earlier test blocks that the
# previous "check current session only" assertion missed.
# ===========================================================================
printf 'tmp files are cleaned up (across all sessions):\n'
all_sessions_leftover="$(find "${STATE_ROOT}" -name 'discovered_scope.jsonl.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "no leftover tmp files in any session dir" "0" "${all_sessions_leftover}"

# ===========================================================================
# Test 12: corrupt JSONL row → script reports the failure honestly.
# Regression for the v1.16.0-Tier-1-quality-reviewer finding: previously
# a jq-transform failure on a pending row was counted as "preserved" and
# the script unconditionally claimed "0 pending remain", lying to the
# user about whether the discovered-scope gate would clear. The fix
# splits the counter (xform_failed vs non_pending_preserved) and emits
# a WARNING line instead of the success line when xform_failed > 0.
# ===========================================================================
printf 'corrupt JSONL surfaces honest WARNING:\n'
setup_session "test-corrupt-jsonl" '{"id":"good1234","source":"metis","summary":"valid pending","severity":"high","status":"pending","reason":"","ts":"100"}
this is not valid json — should fail jq transform
{"id":"good5678","source":"metis","summary":"valid shipped","severity":"low","status":"shipped","reason":"done","ts":"102"}
'
out="$(bash "${MARK_DEFERRED}" "deferring corrupt-fixture batch — requires upstream cleanup" 2>&1)"
# The valid pending row gets transformed.
assert_contains "valid pending row deferred" "Deferred 1 pending finding" "${out}"
# The invalid row is NOT silently preserved as "non_pending_preserved";
# it must surface as xform_failed and trigger the WARNING block, NOT
# the "gate will pass" success line. Both checks together prevent the
# regression — without the split-counter fix, the success line would
# still print and this assertion pair would fail.
assert_contains "WARNING line emitted" "WARNING: 1 row(s) failed" "${out}"
# Negative assertion: the success line MUST NOT appear when xform_failed > 0.
if [[ "${out}" == *"Discovered-scope gate will pass on the next stop attempt"* ]]; then
  printf '  FAIL: success line printed despite jq transform failure\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ===========================================================================
# Wave 3 (v1.23.0) — require-WHY validation tests
#
# The skill rejects low-information reasons that have historically been
# used as silent-skip escape hatches ("out of scope", "not in scope",
# "follow-up", "separate task", "later"). Reasons must contain a WHY
# keyword (requires/blocked/superseded/awaiting/pending/etc.) OR be a
# self-explanatory single token from the allowlist (duplicate / obsolete /
# superseded / wontfix / invalid / not applicable / n/a / not a bug).
# OMC_MARK_DEFERRED_STRICT=off provides an opt-out.
# ===========================================================================

# Test V1: bare "out of scope" rejected
printf '\nrequire-WHY rejects bare "out of scope":\n'
setup_session "test-why-out-of-scope" '{"id":"why00001","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
set +e
out="$(bash "${MARK_DEFERRED}" "out of scope" 2>&1)"; rc=$?
set -e
assert_eq "out of scope: exit 2" "2" "${rc}"
assert_contains "out of scope: error names the rule" "must name a concrete WHY" "${out}"
assert_contains "out of scope: error lists acceptable shapes" "requires <named context>" "${out}"
# Row must remain pending (rejection happens before any state mutation).
scope_file="$(session_file "discovered_scope.jsonl")"
post_status="$(jq -r '.status' "${scope_file}")"
assert_eq "out of scope: row left untouched (still pending)" "pending" "${post_status}"

# Test V2: "not in scope" rejected
printf '\nrequire-WHY rejects "not in scope":\n'
set +e
out="$(bash "${MARK_DEFERRED}" "not in scope" 2>&1)"; rc=$?
set -e
assert_eq "not in scope: exit 2" "2" "${rc}"
assert_contains "not in scope: error names rule" "must name a concrete WHY" "${out}"

# Test V3: bare "follow-up" rejected
printf '\nrequire-WHY rejects bare "follow-up":\n'
set +e
out="$(bash "${MARK_DEFERRED}" "follow-up" 2>&1)"; rc=$?
set -e
assert_eq "follow-up: exit 2" "2" "${rc}"
assert_contains "follow-up: error names rule" "must name a concrete WHY" "${out}"

# Test V4: "later" rejected
printf '\nrequire-WHY rejects "later":\n'
set +e
out="$(bash "${MARK_DEFERRED}" "later" 2>&1)"; rc=$?
set -e
assert_eq "later: exit 2" "2" "${rc}"

# Test V5: "low priority" rejected (rank, not reason)
printf '\nrequire-WHY rejects "low priority":\n'
set +e
out="$(bash "${MARK_DEFERRED}" "low priority" 2>&1)"; rc=$?
set -e
assert_eq "low priority: exit 2" "2" "${rc}"

# Test V6: "separate task" rejected
printf '\nrequire-WHY rejects bare "separate task":\n'
set +e
out="$(bash "${MARK_DEFERRED}" "separate task" 2>&1)"; rc=$?
set -e
assert_eq "separate task: exit 2" "2" "${rc}"

# Test V7: ACCEPT — "requires X" form
printf '\nrequire-WHY accepts "requires X":\n'
out="$(bash "${MARK_DEFERRED}" "requires database migration outside this surface" 2>&1)"
assert_contains "requires X: success" "Deferred 1 pending finding" "${out}"
post_status="$(jq -r '.status' "${scope_file}")"
assert_eq "requires X: row flipped to deferred" "deferred" "${post_status}"

# Test V8: ACCEPT — "blocked by F-NNN" form
printf '\nrequire-WHY accepts "blocked by F-NNN":\n'
setup_session "test-why-blocked" '{"id":"why00002","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(bash "${MARK_DEFERRED}" "blocked by F-042 fix shipping first" 2>&1)"
assert_contains "blocked by F-NNN: success" "Deferred 1 pending finding" "${out}"

# Test V9: ACCEPT — "awaiting <event>" form
printf '\nrequire-WHY accepts "awaiting <event>":\n'
setup_session "test-why-awaiting" '{"id":"why00003","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(bash "${MARK_DEFERRED}" "awaiting telemetry from canary" 2>&1)"
assert_contains "awaiting X: success" "Deferred 1 pending finding" "${out}"

# Test V10: ACCEPT — single-token allowlist "duplicate"
printf '\nrequire-WHY accepts allowlist token "duplicate":\n'
setup_session "test-why-duplicate" '{"id":"why00004","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(bash "${MARK_DEFERRED}" "duplicate" 2>&1)"
assert_contains "duplicate: success" "Deferred 1 pending finding" "${out}"

# Test V11: ACCEPT — allowlist token with trailing punctuation
printf '\nrequire-WHY accepts "Duplicate." (case + punctuation):\n'
setup_session "test-why-dup-punct" '{"id":"why00005","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(bash "${MARK_DEFERRED}" "Duplicate." 2>&1)"
assert_contains "Duplicate.: success" "Deferred 1 pending finding" "${out}"

# Test V12: ACCEPT — issue/wave reference shape
printf '\nrequire-WHY accepts "pending #847":\n'
setup_session "test-why-issueref" '{"id":"why00006","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(bash "${MARK_DEFERRED}" "pending #847" 2>&1)"
assert_contains "pending #N: success" "Deferred 1 pending finding" "${out}"

# Test V13: kill switch — OMC_MARK_DEFERRED_STRICT=off bypasses validation
printf '\nrequire-WHY kill switch (OMC_MARK_DEFERRED_STRICT=off):\n'
setup_session "test-why-killswitch" '{"id":"why00007","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
out="$(OMC_MARK_DEFERRED_STRICT=off bash "${MARK_DEFERRED}" "out of scope" 2>&1)"
assert_contains "kill-switch: bare reason accepted" "Deferred 1 pending finding" "${out}"
scope_file_kill="$(session_file "discovered_scope.jsonl")"
post_status_kill="$(jq -r '.status' "${scope_file_kill}")"
assert_eq "kill-switch: row flipped to deferred" "deferred" "${post_status_kill}"

# Test V14: rejection error message lists wave-append as alternative
printf '\nrejection message points to wave-append alternative:\n'
setup_session "test-why-points-wave" '{"id":"why00008","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
set +e
out="$(bash "${MARK_DEFERRED}" "out of scope" 2>&1)"; rc=$?
set -e
assert_contains "rejection: mentions wave-append alternative" "wave-append" "${out}"

# ===========================================================================
# Test V15: kill-switch bypass emits an audit gate-event so /ulw-report
# can surface the user's bypass count. The error message at line 62 of
# mark-deferred.sh promises "audited" — without this row, the promise
# was aspirational. Closes F-003 from the v1.23.x follow-up wave.
# ===========================================================================
printf '\nstrict-bypass emits an audit gate-event row:\n'
setup_session "test-why-bypass-audit" '{"id":"why00009","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
events_file="$(session_file "gate_events.jsonl")"
rm -f "${events_file}"
out="$(OMC_MARK_DEFERRED_STRICT=off bash "${MARK_DEFERRED}" "out of scope" 2>&1)"
assert_contains "bypass: deferral landed" "Deferred 1 pending finding" "${out}"
events="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "bypass: gate=mark-deferred row written" '"gate":"mark-deferred"' "${events}"
assert_contains "bypass: event=strict-bypass row written" '"event":"strict-bypass"' "${events}"
assert_contains "bypass: reason captured for audit" "out of scope" "${events}"

# Test V16: kill-switch path with VALID reason — strict-bypass row must
# NOT fire (the validator would have accepted under strict=on anyway,
# so the bypass had no effect; emitting the row would inflate the count
# and mislead /ulw-report).
printf '\nstrict-bypass row absent when reason would have passed validation:\n'
setup_session "test-why-bypass-valid" '{"id":"why00010","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
events_file2="$(session_file "gate_events.jsonl")"
rm -f "${events_file2}"
out="$(OMC_MARK_DEFERRED_STRICT=off bash "${MARK_DEFERRED}" "requires database migration" 2>&1)"
assert_contains "valid-bypass: deferral landed" "Deferred 1 pending finding" "${out}"
events2="$(cat "${events_file2}" 2>/dev/null || echo '')"
case "${events2}" in
  *strict-bypass*)
    printf '  FAIL: V16: strict-bypass row should NOT fire for valid reason\n    actual: %s\n' "${events2}" >&2
    fail=$((fail + 1)) ;;
  *)
    pass=$((pass + 1)) ;;
esac

# ===========================================================================
# Wave 4 (v1.35.0) — effort-excuse rejection tests
#
# v1.35.0 extended the validator's silent-skip defense to catch reasons
# that lexically pass the WHY-keyword check but name the WORK COST
# instead of an EXTERNAL blocker. Without this regression net, a future
# softening of the deny-list could regress the protection.
#
# Test corpus: 26 attack reasons that MUST reject (work-cost excuses)
# and 22 legitimate reasons that MUST pass (external-blocker WHYs +
# allowlist phrases). Empirically verified during v1.35.0 implementation.
# ===========================================================================

# Helper: assert that a reason rejects under strict mode.
# Uses an in-process call to omc_reason_has_concrete_why because we
# already source common.sh at line 43; no need to spawn mark-deferred.sh
# subshells per assertion.
assert_validator_rejects() {
  local label="$1" reason="$2"
  if omc_reason_has_concrete_why "${reason}"; then
    printf '  FAIL: %s\n    reason should REJECT but PASSED: %s\n' "${label}" "${reason}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

assert_validator_passes() {
  local label="$1" reason="$2"
  if omc_reason_has_concrete_why "${reason}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    reason should PASS but REJECTED: %s\n' "${label}" "${reason}" >&2
    fail=$((fail + 1))
  fi
}

# 26 effort-excuse attack reasons — every one MUST reject.
# Failure mode the user named verbatim: "the agent defers a task simply
# because a task is big and may take efforts". Each entry below is a
# concrete shape that lexically passed the v1.34.x validator but named
# the WORK COST, not an external blocker.
printf '\n=== v1.35.0 — effort-excuse attack patterns must REJECT ===\n'
assert_validator_rejects "V17 requires significant effort" "requires significant effort"
assert_validator_rejects "V18 requires too much rework"     "requires too much rework"
assert_validator_rejects "V19 requires more time"           "requires more time than available"
assert_validator_rejects "V20 requires more focus"          "requires more focus than this session has"
assert_validator_rejects "V21 blocked by complexity"        "blocked by complexity"
assert_validator_rejects "V22 blocked by context budget"    "blocked by my context budget"
assert_validator_rejects "V23 needs a refactor first"       "needs a refactor first"
assert_validator_rejects "V24 needs more time"              "needs more time"
assert_validator_rejects "V25 needs significant work"       "needs significant work"
assert_validator_rejects "V26 needs deep investigation"     "needs deep investigation"
assert_validator_rejects "V27 awaiting more focus"          "awaiting more focus"
assert_validator_rejects "V28 pending future session"       "pending future session"
assert_validator_rejects "V29 because too big"              "because too big"
assert_validator_rejects "V30 due to size"                  "due to size"
assert_validator_rejects "V31 superseded by future work"    "superseded by future work"
assert_validator_rejects "V32 substantial changes"          "requires substantial changes outside this surface"
assert_validator_rejects "V33 thinking time"                "blocked by needing more thinking time"
assert_validator_rejects "V34 tracks to future session"     "tracks to a future session"
assert_validator_rejects "V35 tracks to follow-up"          "tracks to follow-up"
assert_validator_rejects "V36 needs additional thinking"    "needs additional thinking"
assert_validator_rejects "V37 requires more attention"      "requires more attention"
assert_validator_rejects "V38 blocked by bandwidth"         "blocked by bandwidth"
assert_validator_rejects "V39 awaiting capacity"            "awaiting capacity"
assert_validator_rejects "V40 effort required"              "due to effort required"
assert_validator_rejects "V41 requires major refactor"      "requires major refactor"
assert_validator_rejects "V42 needs the refactor"           "needs the refactor"

# 22 legitimate reasons — every one MUST pass.
# These name an EXTERNAL blocker (named domain object, ID reference,
# allowlist phrase) and represent real-world deferral patterns the
# validator must NOT over-reject. Drawn from production usage.
printf '\n=== v1.35.0 — legitimate reasons must PASS ===\n'
assert_validator_passes "V43 requires database migration"   "requires database migration that would take 2 weeks to plan"
assert_validator_passes "V44 refactor superseded by F-051"  "requires major refactor — superseded by F-051"
assert_validator_passes "V45 UI refactor pending design"    "requires UI refactor — pending design review"
assert_validator_passes "V46 auth module refactor"          "requires auth module refactor"
assert_validator_passes "V47 rewriting test harness"        "requires rewriting the test harness for adversarial fixtures"
assert_validator_passes "V48 dependency upgrade"            "blocked by upstream dependency upgrade requiring 3 days investigation"
assert_validator_passes "V49 awaiting telemetry"            "awaiting telemetry from canary"
assert_validator_passes "V50 requires legal review"         "requires legal review"
assert_validator_passes "V51 blocked by F-042"              "blocked by F-042 fix shipping first"
assert_validator_passes "V52 superseded by F-051"           "superseded by F-051 which covers the same surface"
assert_validator_passes "V53 awaiting stakeholder"          "awaiting stakeholder pricing decision"
assert_validator_passes "V54 pending wave 5"                "pending wave 5"
assert_validator_passes "V55 duplicate single token"        "duplicate"
assert_validator_passes "V56 obsolete single token"         "obsolete"
assert_validator_passes "V57 n/a single token"              "n/a"
assert_validator_passes "V58 not reproducible"              "not reproducible"
assert_validator_passes "V59 false positive"                "false positive"
assert_validator_passes "V60 by design"                     "by design"
assert_validator_passes "V61 working as intended"           "working as intended"
assert_validator_passes "V62 migration plus wave"           "requires database migration outside this session — pending wave 3"
assert_validator_passes "V63 upstream API"                  "blocked by upstream API redesign"
assert_validator_passes "V64 compliance approval"           "awaiting compliance approval"

# v1.35.0 — adjacent-token attack patterns surfaced by excellence-reviewer.
# These are the same effort-shaped failure mode but with vocabulary the
# initial deny-list missed: "next sprint/quarter/iteration", "future
# iteration/sprint/quarter", "deeper dive", "more analysis/review/work/
# thought/consideration", "non-trivial", "large-scale". Every one was
# empirically observed to PASS the v1.35.0-rev0 validator before this
# extension; pinning the rejections so a future regex edit cannot
# silently regress the protection.
printf '\n=== v1.35.0 — adjacent attack tokens (excellence-reviewer F-1) ===\n'
assert_validator_rejects "V65 next sprint planning"     "requires next sprint planning"
assert_validator_rejects "V66 next quarter"             "tracks to next quarter"
assert_validator_rejects "V67 next iteration"           "tracks to next iteration"
assert_validator_rejects "V68 future iteration"         "tracks to future iteration"
assert_validator_rejects "V69 future sprint"            "blocked by future sprint capacity"
assert_validator_rejects "V70 future quarter"           "tracks to future quarter"
assert_validator_rejects "V71 deeper dive needed"       "deeper dive needed before fix"
assert_validator_rejects "V72 blocked by deeper dive"   "blocked by deeper dive"
assert_validator_rejects "V73 more analysis required"   "more analysis required"
assert_validator_rejects "V74 needs more thought"       "needs more thought"
assert_validator_rejects "V75 needs more consideration" "needs more consideration"
assert_validator_rejects "V76 needs more work"          "needs more work"
assert_validator_rejects "V77 needs more review"        "needs more review"
assert_validator_rejects "V78 non-trivial change"       "requires non-trivial change"
assert_validator_rejects "V79 non trivial change"       "requires non trivial change"
assert_validator_rejects "V80 large-scale change"       "requires large-scale change"
assert_validator_rejects "V81 significant change"       "requires significant change"
assert_validator_rejects "V82 substantial change"       "requires substantial change"

# v1.35.0 — adjacent-token PASSES (the deny-list extension must NOT
# over-reject when the work-cost word is paired with a real external
# blocker noun). These pin the false-positive guard.
printf '\n=== v1.35.0 — adjacent legit reasons must PASS ===\n'
assert_validator_passes "V83 analysis from data team"   "needs analysis from data team"
assert_validator_passes "V84 review by legal"           "needs review by legal team"
assert_validator_passes "V85 next sprint w/ stakeholder" "tracks to next sprint after stakeholder approval"
assert_validator_passes "V86 large-scale + dependency"  "requires large-scale dependency upgrade"

# v1.35.0 — bare ID-only must REJECT (excellence-reviewer F-2).
# Until rev0 of v1.35.0 the validator had OR semantics: WHY-keyword OR
# ID-reference was enough to pass. That made bare 'F-001' pass while
# bare '#847' rejected (the # gets stripped by the trim regex), an
# inconsistent shape. The fix requires has_why=1 always; pair the ID
# with a successor verb (see/blocked by/tracks to/pending/etc.).
printf '\n=== v1.35.0 — bare ID-only must REJECT (excellence-reviewer F-2) ===\n'
assert_validator_rejects "V87 bare F-001"   "F-001"
assert_validator_rejects "V88 bare f-001"   "f-001"
assert_validator_rejects "V89 bare S-005"   "S-005"
assert_validator_rejects "V90 bare wave 3"  "wave 3"
assert_validator_rejects "V91 bare PR-12"   "PR-12"

# v1.35.0 — ID paired with WHY-prefix verb still passes (no regression
# on the documented legitimate shape).
printf '\n=== v1.35.0 — ID + WHY-prefix verb still passes ===\n'
assert_validator_passes "V92 see F-001"          "see F-001"
assert_validator_passes "V93 blocked by F-001"   "blocked by F-001"
assert_validator_passes "V94 superseded by F-051" "superseded by F-051"
assert_validator_passes "V95 tracks to F-001"    "tracks to F-001"
assert_validator_passes "V96 pending #847"       "pending #847"
assert_validator_passes "V97 awaiting wave 3"    "awaiting wave 3"

# End-to-end: an effort excuse via the full mark-deferred.sh CLI rejects
# with exit code 2 AND a useful error message. This catches breakage
# in the script wiring (env propagation, args, error formatting) that
# the in-process tests above don't exercise.
printf '\n=== v1.35.0 — effort excuse rejected end-to-end via mark-deferred.sh ===\n'
setup_session "test-effort-e2e" '{"id":"effort01","source":"metis","summary":"finding","severity":"high","status":"pending","reason":"","ts":"100"}
'
set +e
out="$(bash "${MARK_DEFERRED}" "requires significant effort" 2>&1)"; rc=$?
set -e
assert_eq "effort excuse: exit 2"                       "2" "${rc}"
assert_contains "effort excuse: error names rule"       "must name a concrete WHY" "${out}"
assert_contains "effort excuse: error mentions external" "external blocker" "${out}"
assert_contains "effort excuse: error lists e.g."       "requires <named context>" "${out}"
# The new message must enumerate effort excuses explicitly so the
# model sees the rejected pattern without scrolling to docs.
assert_contains "effort excuse: error names effort"     "requires significant effort" "${out}"
# Pending row stays pending (rejection precedes any state mutation).
post_status="$(jq -r '.status' "$(session_file "discovered_scope.jsonl")")"
assert_eq "effort excuse: row stays pending"            "pending" "${post_status}"

# ===========================================================================
printf '\nResults: pass=%d fail=%d\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
