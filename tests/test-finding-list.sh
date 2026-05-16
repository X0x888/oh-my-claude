#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-finding-list.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_STATE_ROOT}"
mkdir -p "${STATE_ROOT}/finding-list-test-session"

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
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

# ----------------------------------------------------------------------
printf 'Test 1: path command emits absolute path under STATE_ROOT\n'
findings_path="$("${SCRIPT}" path)"
assert_contains "path under STATE_ROOT" "${STATE_ROOT}" "${findings_path}"
assert_contains "path ends with findings.json" "findings.json" "${findings_path}"

# ----------------------------------------------------------------------
printf 'Test 2: init from bare array creates findings.json\n'
echo '[
  {"id":"F-001","summary":"Login error","severity":"critical","surface":"auth","lens":"security-lens","effort":"S"},
  {"id":"F-002","summary":"Cart empty state","severity":"high","surface":"checkout","lens":"design-lens","effort":"M"},
  {"id":"F-003","summary":"Slow search","severity":"medium","surface":"search","lens":"sre-lens","effort":"L"}
]' | "${SCRIPT}" init >/dev/null

assert_eq "findings.json exists" "yes" "$([[ -f "${findings_path}" ]] && echo yes || echo no)"
finding_count="$(jq '.findings|length' "${findings_path}")"
assert_eq "3 findings persisted" "3" "${finding_count}"

# Default values stamped
status_default="$(jq -r '.findings[0].status' "${findings_path}")"
assert_eq "default status=pending" "pending" "${status_default}"
wave_default="$(jq -r '.findings[0].wave' "${findings_path}")"
assert_eq "default wave=null" "null" "${wave_default}"

# ----------------------------------------------------------------------
printf 'Test 3: init from object form { findings: [...] }\n'
rm -f "${findings_path}"
echo '{"findings":[{"id":"F-100","summary":"x","severity":"low","surface":"y"}]}' | "${SCRIPT}" init >/dev/null
finding_count="$(jq '.findings|length' "${findings_path}")"
assert_eq "object form: 1 finding" "1" "${finding_count}"

# ----------------------------------------------------------------------
printf 'Test 4: status command updates finding atomically\n'
# Reset to 3 findings
echo '[
  {"id":"F-001","summary":"a","severity":"critical","surface":"auth"},
  {"id":"F-002","summary":"b","severity":"high","surface":"checkout"},
  {"id":"F-003","summary":"c","severity":"medium","surface":"search"}
]' | "${SCRIPT}" init >/dev/null

"${SCRIPT}" status F-001 shipped abc123def "Returns 400" >/dev/null
status_val="$(jq -r '.findings[] | select(.id=="F-001") | .status' "${findings_path}")"
assert_eq "F-001 status=shipped" "shipped" "${status_val}"
commit_val="$(jq -r '.findings[] | select(.id=="F-001") | .commit_sha' "${findings_path}")"
assert_eq "F-001 commit_sha persisted" "abc123def" "${commit_val}"
notes_val="$(jq -r '.findings[] | select(.id=="F-001") | .notes' "${findings_path}")"
assert_eq "F-001 notes persisted" "Returns 400" "${notes_val}"

# Other findings untouched
status_other="$(jq -r '.findings[] | select(.id=="F-002") | .status' "${findings_path}")"
assert_eq "F-002 untouched" "pending" "${status_other}"

# ----------------------------------------------------------------------
printf 'Test 5: status rejects invalid status\n'
output="$("${SCRIPT}" status F-002 garbage 2>&1 || echo CAUGHT)"
assert_contains "invalid status rejected" "invalid status" "${output}"

# ----------------------------------------------------------------------
printf 'Test 6: assign-wave assigns ids and creates wave entry\n'
"${SCRIPT}" assign-wave 1 2 "auth+checkout" F-001 F-002 >/dev/null
wave1_idx="$(jq -r '.waves[] | select(.index==1) | .index' "${findings_path}")"
assert_eq "wave 1 created" "1" "${wave1_idx}"
wave1_total="$(jq -r '.waves[] | select(.index==1) | .total' "${findings_path}")"
assert_eq "wave 1 total=2" "2" "${wave1_total}"
wave1_ids="$(jq -r '.waves[] | select(.index==1) | .finding_ids | join(",")' "${findings_path}")"
assert_eq "wave 1 ids" "F-001,F-002" "${wave1_ids}"

# Findings get wave attribute
f1_wave="$(jq -r '.findings[] | select(.id=="F-001") | .wave' "${findings_path}")"
assert_eq "F-001 assigned to wave 1" "1" "${f1_wave}"

# ----------------------------------------------------------------------
printf 'Test 7: assign-wave is idempotent (re-assign same wave replaces)\n'
"${SCRIPT}" assign-wave 1 2 "auth+checkout" F-001 F-002 >/dev/null
wave_count="$(jq '.waves | length' "${findings_path}")"
assert_eq "no duplicate wave entries" "1" "${wave_count}"

# ----------------------------------------------------------------------
printf 'Test 8: wave-status updates wave + commit_sha\n'
"${SCRIPT}" wave-status 1 completed deadbeef0123 >/dev/null
wave1_status="$(jq -r '.waves[] | select(.index==1) | .status' "${findings_path}")"
assert_eq "wave 1 completed" "completed" "${wave1_status}"
wave1_sha="$(jq -r '.waves[] | select(.index==1) | .commit_sha' "${findings_path}")"
assert_eq "wave 1 commit_sha" "deadbeef0123" "${wave1_sha}"

# ----------------------------------------------------------------------
printf 'Test 9: counts emits parseable line\n'
"${SCRIPT}" status F-002 deferred "" "needs UX review" >/dev/null
counts_out="$("${SCRIPT}" counts)"
assert_contains "counts has total" "total=3" "${counts_out}"
assert_contains "counts has shipped=1" "shipped=1" "${counts_out}"
assert_contains "counts has deferred=1" "deferred=1" "${counts_out}"
assert_contains "counts has pending=1" "pending=1" "${counts_out}"

# ----------------------------------------------------------------------
printf 'Test 10: summary emits markdown table with status icons\n'
summary_out="$("${SCRIPT}" summary)"
assert_contains "summary has table header" "| ID |" "${summary_out}"
assert_contains "summary has shipped icon" "✓ shipped" "${summary_out}"
assert_contains "summary has deferred icon" "⚠ deferred" "${summary_out}"
assert_contains "summary has pending icon" "○ pending" "${summary_out}"
assert_contains "summary truncates commit to 7 chars" "abc123d" "${summary_out}"
assert_contains "summary has counts footer" "**Counts:**" "${summary_out}"

# ----------------------------------------------------------------------
printf 'Test 11: empty findings file → counts=0\n'
rm -f "${findings_path}"
counts_out="$("${SCRIPT}" counts)"
assert_eq "no file → all zeros" "total=0 shipped=0 deferred=0 rejected=0 in_progress=0 pending=0 user_decision=0" "${counts_out}"

# ----------------------------------------------------------------------
printf 'Test 12: notes with pipe character is escaped in markdown table\n'
echo '[{"id":"F-001","summary":"x","severity":"low","surface":"y"}]' | "${SCRIPT}" init >/dev/null
"${SCRIPT}" status F-001 shipped abc123 "before|after" >/dev/null
summary_out="$("${SCRIPT}" summary)"
assert_contains "pipe escaped in markdown" 'before\|after' "${summary_out}"

# ----------------------------------------------------------------------
printf 'Test 13: init with empty stdin fails\n'
output="$(echo "" | "${SCRIPT}" init 2>&1 || echo CAUGHT)"
assert_contains "empty init rejected" "empty stdin" "${output}"

# ----------------------------------------------------------------------
printf 'Test 14: unknown command emits usage error\n'
output="$("${SCRIPT}" bogus 2>&1 || echo CAUGHT)"
assert_contains "unknown cmd error" "unknown command" "${output}"

# ----------------------------------------------------------------------
printf 'Test 15: status missing id rejected\n'
output="$("${SCRIPT}" status "" shipped 2>&1 || echo CAUGHT)"
assert_contains "missing id rejected" "usage:" "${output}"

# ----------------------------------------------------------------------
printf 'Test 15b: status rejects non-existent id\n'
output="$("${SCRIPT}" status F-NOPE shipped abc123 "typo" 2>&1 || echo CAUGHT)"
assert_contains "non-existent status id rejected" "id F-NOPE not found" "${output}"
noop_count="$(jq '[.findings[] | select(.id=="F-NOPE")] | length' "${findings_path}")"
assert_eq "non-existent status id not created" "0" "${noop_count}"

# ----------------------------------------------------------------------
printf 'Test 16: assign-wave missing surface rejected\n'
output="$("${SCRIPT}" assign-wave 1 2 "" F-001 2>&1 || echo CAUGHT)"
assert_contains "missing surface rejected" "usage:" "${output}"

# ----------------------------------------------------------------------
printf 'Test 16b: assign-wave rejects non-existent ids\n'
output="$("${SCRIPT}" assign-wave 1 1 "typo-surface" F-NOPE 2>&1 || echo CAUGHT)"
assert_contains "non-existent wave id rejected" "id(s) not found: F-NOPE" "${output}"
wave_count_after_reject="$(jq '.waves | length' "${findings_path}")"
assert_eq "non-existent wave id did not create wave" "0" "${wave_count_after_reject}"

# ----------------------------------------------------------------------
printf 'Test 17: concurrent status updates serialize via file lock\n'
echo '[
  {"id":"F-100","summary":"a","severity":"low","surface":"x"},
  {"id":"F-101","summary":"b","severity":"low","surface":"y"},
  {"id":"F-102","summary":"c","severity":"low","surface":"z"}
]' | "${SCRIPT}" init >/dev/null
# Background two concurrent status updates and one wave assignment.
# All three should land cleanly (no lost updates, no JSON corruption).
"${SCRIPT}" status F-100 shipped sha100abc "concurrent-A" &
pid1=$!
"${SCRIPT}" status F-101 deferred "" "blocked by concurrent-B race fixture" &
pid2=$!
"${SCRIPT}" assign-wave 1 1 "concurrency-test" F-100 F-101 F-102 &
pid3=$!
wait "${pid1}" "${pid2}" "${pid3}"

# JSON must still be valid
jq empty "${findings_path}" >/dev/null 2>&1
assert_eq "post-concurrent JSON valid" "yes" "$(jq empty "${findings_path}" 2>/dev/null && echo yes || echo no)"

f100_status="$(jq -r '.findings[] | select(.id=="F-100") | .status' "${findings_path}")"
f101_status="$(jq -r '.findings[] | select(.id=="F-101") | .status' "${findings_path}")"
f102_status="$(jq -r '.findings[] | select(.id=="F-102") | .status' "${findings_path}")"
assert_eq "F-100 status landed" "shipped" "${f100_status}"
assert_eq "F-101 status landed" "deferred" "${f101_status}"
assert_eq "F-102 status default" "pending" "${f102_status}"

# Wave assignment must have landed (and may have raced with status updates;
# both outcomes are acceptable as long as the document is consistent)
wave_count="$(jq '.waves | length' "${findings_path}")"
assert_eq "wave landed" "1" "${wave_count}"

# Lock must be released after all writes
assert_eq "lock dir removed" "no" "$([[ -d "${findings_path}.lock" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 18: init refuses to overwrite an active wave plan\n'
# Prior test left a populated wave (waves[] non-empty); init should refuse.
output="$(echo '[{"id":"F-999","summary":"x","severity":"low","surface":"y"}]' \
  | "${SCRIPT}" init 2>&1 || echo CAUGHT)"
assert_contains "init refuses populated plan" "refusing to overwrite" "${output}"
# Existing F-100 should still be present
remaining="$(jq -r '[.findings[] | select(.id=="F-100")] | length' "${findings_path}")"
assert_eq "F-100 preserved through refused init" "1" "${remaining}"

# ----------------------------------------------------------------------
printf 'Test 19: init --force overwrites an active wave plan\n'
echo '[
  {"id":"F-200","summary":"reset","severity":"critical","surface":"new"}
]' | "${SCRIPT}" init --force >/dev/null
finding_count="$(jq '.findings|length' "${findings_path}")"
assert_eq "init --force replaced findings" "1" "${finding_count}"
wave_count="$(jq '.waves|length' "${findings_path}")"
assert_eq "init --force cleared waves" "0" "${wave_count}"

# ----------------------------------------------------------------------
printf 'Test 20: init refuses populated plan even with garbage stdin\n'
# Re-populate
echo '[{"id":"F-300","summary":"x","severity":"low","surface":"y"}]' \
  | "${SCRIPT}" init --force >/dev/null
"${SCRIPT}" assign-wave 1 1 "test-surface" F-300 >/dev/null
# Now without --force, init should refuse BEFORE reading stdin (stdin should
# never be consumed for the refusal path)
output="$(echo "garbage that would fail jq" | "${SCRIPT}" init 2>&1 || true)"
assert_contains "refusal exits early" "refusing to overwrite" "${output}"

# ----------------------------------------------------------------------
printf 'Test 21: add-finding appends a new finding\n'
"${SCRIPT}" add-finding <<<'{"id":"F-301","summary":"discovered mid-wave","severity":"high","surface":"checkout"}' >/dev/null
total="$(jq '.findings|length' "${findings_path}")"
assert_eq "findings count incremented" "2" "${total}"
status_val="$(jq -r '.findings[] | select(.id=="F-301") | .status' "${findings_path}")"
assert_eq "new finding default status" "pending" "${status_val}"
summary_val="$(jq -r '.findings[] | select(.id=="F-301") | .summary' "${findings_path}")"
assert_eq "new finding summary preserved" "discovered mid-wave" "${summary_val}"

# ----------------------------------------------------------------------
# v1.40.x harness-improvement wave: originating_reviewer captured per
# finding so /ulw-report can compute per-reviewer fix-rate (closes the
# reviewer-feedback loop gap surfaced by agent-metrics.json showing
# 2-11% clean-rates across reviewers but no signal on which findings
# were actually shipped).
printf 'Test 21b: add-finding captures originating_reviewer field\n'
"${SCRIPT}" add-finding <<<'{"id":"F-310","summary":"surfaced by quality-reviewer","severity":"high","surface":"auth","originating_reviewer":"quality-reviewer"}' >/dev/null
reviewer_val="$(jq -r '.findings[] | select(.id=="F-310") | .originating_reviewer' "${findings_path}")"
assert_eq "originating_reviewer preserved on add" "quality-reviewer" "${reviewer_val}"

# Back-compat: add-finding without the field defaults to empty string.
"${SCRIPT}" add-finding <<<'{"id":"F-311","summary":"legacy add — no reviewer field","severity":"low","surface":"docs"}' >/dev/null
reviewer_empty="$(jq -r '.findings[] | select(.id=="F-311") | .originating_reviewer' "${findings_path}")"
assert_eq "originating_reviewer defaults to empty for legacy callers" "" "${reviewer_empty}"

# Status-change event surfaces the reviewer (lookup against findings.json).
# Use the per-session gate_events.jsonl that record_gate_event writes to.
mkdir -p "${STATE_ROOT}/finding-list-test-session"
SESSION_ID="finding-list-test-session" "${SCRIPT}" status "F-310" "shipped" "abc1234" "wave 1 ship" >/dev/null
_gate_event_file="${STATE_ROOT}/finding-list-test-session/gate_events.jsonl"
if [[ -f "${_gate_event_file}" ]]; then
  reviewer_in_event="$(jq -r 'select(.event=="finding-status-change" and .details.finding_id=="F-310") | .details.originating_reviewer' "${_gate_event_file}" 2>/dev/null | head -1)"
  assert_eq "finding-status-change event carries originating_reviewer" "quality-reviewer" "${reviewer_in_event}"
fi

# ----------------------------------------------------------------------
printf 'Test 22: add-finding rejects duplicate id\n'
output="$("${SCRIPT}" add-finding <<<'{"id":"F-301","summary":"dup","severity":"low","surface":"x"}' 2>&1 || echo CAUGHT)"
assert_contains "duplicate rejected" "already exists" "${output}"

# ----------------------------------------------------------------------
printf 'Test 23: add-finding rejects non-object input\n'
output="$("${SCRIPT}" add-finding <<<'[{"id":"F-302"}]' 2>&1 || echo CAUGHT)"
assert_contains "non-object rejected" "must be a JSON object" "${output}"

# ----------------------------------------------------------------------
printf 'Test 24: add-finding rejects object missing id\n'
output="$("${SCRIPT}" add-finding <<<'{"summary":"x","severity":"low","surface":"y"}' 2>&1 || echo CAUGHT)"
assert_contains "missing id rejected" "must be a JSON object with an" "${output}"

# ----------------------------------------------------------------------
printf 'Test 25: add-finding rejects empty stdin\n'
output="$(echo "" | "${SCRIPT}" add-finding 2>&1 || echo CAUGHT)"
assert_contains "empty add-finding rejected" "empty stdin" "${output}"

# ----------------------------------------------------------------------
printf 'Test 26: high-concurrency stress (12 simultaneous status updates)\n'
# Test 17 covered 3 concurrent ops; this stress-tests the file-lock under
# 12 simultaneous status updates targeting distinct findings. All updates
# must land — no lost writes — and the JSON must remain valid after the
# storm. Catches lock-acquisition timeout regressions and any orphaned
# `.lock` directories on the hot path.
init_json='['
for i in $(seq 1 12); do
  id_padded="$(printf '%03d' "${i}")"
  init_json="${init_json}{\"id\":\"F-S${id_padded}\",\"summary\":\"stress ${i}\",\"severity\":\"low\",\"surface\":\"x\"}"
  if [[ "${i}" -lt 12 ]]; then init_json="${init_json},"; fi
done
init_json="${init_json}]"
echo "${init_json}" | "${SCRIPT}" init --force >/dev/null

# Spawn 12 concurrent status updates and collect pids.
pids=()
for i in $(seq 1 12); do
  id_padded="$(printf '%03d' "${i}")"
  "${SCRIPT}" status "F-S${id_padded}" "shipped" "sha-${i}" "stress-${i}" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done

assert_eq "stress: post-concurrent JSON valid" "yes" \
  "$(jq empty "${findings_path}" 2>/dev/null && echo yes || echo no)"

shipped_count="$(jq '[.findings[] | select(.status=="shipped")] | length' "${findings_path}")"
assert_eq "stress: all 12 status updates landed" "12" "${shipped_count}"

sha_count="$(jq '[.findings[] | select(.commit_sha != "" and .commit_sha != null)] | length' "${findings_path}")"
assert_eq "stress: all 12 commit_shas persisted" "12" "${sha_count}"

assert_eq "stress: lock dir removed" "no" \
  "$([[ -d "${findings_path}.lock" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 27: mixed-op concurrency (status + assign-wave + add-finding + wave-status)\n'
# Real-world Phase 8 wave execution interleaves status updates (per
# finding shipped), wave-status (per wave commit), and add-finding (when
# a wave reveals a new finding). This stress test runs all four op types
# concurrently and asserts the final document is consistent: the 3 initial
# findings persisted, all 3 add-finding rows landed, the wave was assigned,
# and the lock cleaned up.
echo '[
  {"id":"F-M001","summary":"mix1","severity":"low","surface":"a"},
  {"id":"F-M002","summary":"mix2","severity":"low","surface":"b"},
  {"id":"F-M003","summary":"mix3","severity":"low","surface":"c"}
]' | "${SCRIPT}" init --force >/dev/null

pids=()
"${SCRIPT}" status F-M001 shipped m1sha "ship1" & pids+=($!)
"${SCRIPT}" status F-M002 shipped m2sha "ship2" & pids+=($!)
"${SCRIPT}" status F-M003 shipped m3sha "ship3" & pids+=($!)
"${SCRIPT}" assign-wave 1 1 "mix-surface" F-M001 F-M002 F-M003 & pids+=($!)
"${SCRIPT}" add-finding <<<'{"id":"F-M004","summary":"mid-flight A","severity":"low","surface":"d"}' & pids+=($!)
"${SCRIPT}" add-finding <<<'{"id":"F-M005","summary":"mid-flight B","severity":"low","surface":"e"}' & pids+=($!)
"${SCRIPT}" add-finding <<<'{"id":"F-M006","summary":"mid-flight C","severity":"low","surface":"f"}' & pids+=($!)
"${SCRIPT}" wave-status 1 in_progress "" & pids+=($!)
for pid in "${pids[@]}"; do
  wait "${pid}"
done

assert_eq "mix-stress: post JSON valid" "yes" \
  "$(jq empty "${findings_path}" 2>/dev/null && echo yes || echo no)"

total="$(jq '.findings | length' "${findings_path}")"
assert_eq "mix-stress: 6 findings (3 initial + 3 added)" "6" "${total}"

# All 3 added findings present with default pending status
added_pending="$(jq '[.findings[] | select(.id == "F-M004" or .id == "F-M005" or .id == "F-M006") | select(.status == "pending")] | length' "${findings_path}")"
assert_eq "mix-stress: 3 added findings present and pending" "3" "${added_pending}"

# Wave landed (assign-wave is idempotent if it ran multiple times, but here it ran once)
wave_count="$(jq '.waves | length' "${findings_path}")"
assert_eq "mix-stress: wave landed" "1" "${wave_count}"

# Lock cleaned up
assert_eq "mix-stress: lock dir removed" "no" \
  "$([[ -d "${findings_path}.lock" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
# v1.18.0 — requires_user_decision schema field + mark-user-decision cmd.
# ----------------------------------------------------------------------
printf '\n=== v1.18.0: user-decision annotation ===\n'

# Reset and init with one finding marked at init-time, another not.
echo '[
  {"id":"F-D001","summary":"taste call","severity":"medium","surface":"copy",
   "requires_user_decision":true,"decision_reason":"brand voice"},
  {"id":"F-D002","summary":"clear bug","severity":"high","surface":"auth"}
]' | "${SCRIPT}" init --force >/dev/null

# Init-time field preserved on F-D001
flag1="$(jq -r '.findings[]|select(.id=="F-D001")|.requires_user_decision' "${findings_path}")"
assert_eq "init: F-D001 requires_user_decision=true preserved" "true" "${flag1}"
reason1="$(jq -r '.findings[]|select(.id=="F-D001")|.decision_reason' "${findings_path}")"
assert_eq "init: F-D001 decision_reason preserved" "brand voice" "${reason1}"

# Default false for F-D002 (not specified at init)
flag2="$(jq -r '.findings[]|select(.id=="F-D002")|.requires_user_decision' "${findings_path}")"
assert_eq "init: F-D002 default requires_user_decision=false" "false" "${flag2}"
reason2="$(jq -r '.findings[]|select(.id=="F-D002")|.decision_reason' "${findings_path}")"
assert_eq "init: F-D002 default decision_reason=empty" "" "${reason2}"

# add-finding default false
"${SCRIPT}" add-finding <<<'{"id":"F-D003","summary":"another bug","severity":"low","surface":"docs"}' >/dev/null
flag3="$(jq -r '.findings[]|select(.id=="F-D003")|.requires_user_decision' "${findings_path}")"
assert_eq "add-finding: F-D003 default requires_user_decision=false" "false" "${flag3}"

# add-finding with requires_user_decision=true
"${SCRIPT}" add-finding <<<'{"id":"F-D004","summary":"pricing call","severity":"medium","surface":"billing","requires_user_decision":true,"decision_reason":"pricing tier"}' >/dev/null
flag4="$(jq -r '.findings[]|select(.id=="F-D004")|.requires_user_decision' "${findings_path}")"
assert_eq "add-finding: F-D004 requires_user_decision=true preserved" "true" "${flag4}"

# mark-user-decision command flips the flag and sets reason
"${SCRIPT}" mark-user-decision F-D003 "feature scope" >/dev/null
flag3_after="$(jq -r '.findings[]|select(.id=="F-D003")|.requires_user_decision' "${findings_path}")"
assert_eq "mark-user-decision: F-D003 flag flipped to true" "true" "${flag3_after}"
reason3_after="$(jq -r '.findings[]|select(.id=="F-D003")|.decision_reason' "${findings_path}")"
assert_eq "mark-user-decision: F-D003 reason set" "feature scope" "${reason3_after}"

# mark-user-decision rejects empty reason
if "${SCRIPT}" mark-user-decision F-D002 "" >/dev/null 2>&1; then
  printf '  FAIL: mark-user-decision should reject empty reason\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# mark-user-decision rejects unknown id (no silent no-op for typos)
if "${SCRIPT}" mark-user-decision F-NOSUCH "reason" >/dev/null 2>&1; then
  printf '  FAIL: mark-user-decision should reject unknown id\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# counts includes user_decision count for pending+in_progress flagged findings
counts_out="$("${SCRIPT}" counts)"
assert_contains "counts: includes user_decision field" "user_decision=" "${counts_out}"
# F-D001, F-D003 (after mark), F-D004 are flagged AND pending → 3
assert_contains "counts: user_decision=3 for three flagged-pending findings" \
  "user_decision=3" "${counts_out}"

# Once a flagged finding is shipped, it leaves the user_decision count
"${SCRIPT}" status F-D001 shipped abc1234 "user picked option B" >/dev/null
counts_out2="$("${SCRIPT}" counts)"
assert_contains "counts: user_decision drops to 2 after F-D001 shipped" \
  "user_decision=2" "${counts_out2}"

# summary surfaces USER-DECISION column AND inline awaiting-decision section
summary_out="$("${SCRIPT}" summary)"
assert_contains "summary: Decision column header present" "Decision" "${summary_out}"
assert_contains "summary: USER-DECISION marker on flagged row" "USER-DECISION" "${summary_out}"
assert_contains "summary: awaiting-user-decision in counts line" \
  "awaiting-user-decision=2" "${summary_out}"
assert_contains "summary: 'Awaiting user decision' section emitted" \
  "Awaiting user decision" "${summary_out}"
assert_contains "summary: F-D003 reason surfaced" "feature scope" "${summary_out}"

# summary section is suppressed when no flagged-pending findings remain
"${SCRIPT}" status F-D003 shipped def5678 "shipped" >/dev/null
"${SCRIPT}" status F-D004 shipped ghi9012 "shipped" >/dev/null
summary_clean="$("${SCRIPT}" summary)"
if [[ "${summary_clean}" == *"Awaiting user decision"* ]]; then
  printf '  FAIL: summary should NOT emit "Awaiting user decision" when count=0\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# But the table-row Decision column still shows historical USER-DECISION marker
assert_contains "summary: USER-DECISION marker still in table even after ship" \
  "USER-DECISION" "${summary_clean}"

# Help text includes mark-user-decision command
help_out="$("${SCRIPT}" --help 2>&1)"
assert_contains "help: mark-user-decision documented" \
  "mark-user-decision" "${help_out}"

# Reviewer F1: mark-user-decision rejects newlines in reason — they
# break the markdown bullet rendering in summary's awaiting section.
echo '[{"id":"F-NL01","summary":"newline test","severity":"low","surface":"x"}]' | "${SCRIPT}" init --force >/dev/null
multiline_reason="$(printf 'line1\nline2')"
if "${SCRIPT}" mark-user-decision F-NL01 "${multiline_reason}" >/dev/null 2>&1; then
  printf '  FAIL: mark-user-decision should reject reason with embedded newline\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# Confirm the flag was NOT flipped — the rejection must precede the write
flag_after_reject="$(jq -r '.findings[]|select(.id=="F-NL01")|.requires_user_decision' "${findings_path}")"
assert_eq "mark-user-decision newline rejection: flag stayed false" \
  "false" "${flag_after_reject}"

# Reviewer F1 (defense in depth): summary `Awaiting user decision` bullet
# survives a multi-line decision_reason set via init payload (since
# mark-user-decision rejects newlines but init payloads may include them).
echo '[
  {"id":"F-NL02","summary":"init multi-line","severity":"low","surface":"x",
   "requires_user_decision":true,"decision_reason":"line1\nline2"}
]' | "${SCRIPT}" init --force >/dev/null
sum_multiline="$("${SCRIPT}" summary)"
# Bullet should contain the reason with newline flattened to space (no orphan line)
assert_contains "summary: multi-line decision_reason flattened to single line" \
  "Reason: line1 line2" "${sum_multiline}"

# Reviewer F4: mark-user-decision rejects on terminal status (shipped/
# deferred/rejected). Marking a past-tense finding creates confusing UX
# where shipped rows look identical to actionable ones in the table.
echo '[
  {"id":"F-T01","summary":"already shipped","severity":"low","surface":"x"},
  {"id":"F-T02","summary":"already deferred","severity":"low","surface":"y"},
  {"id":"F-T03","summary":"already rejected","severity":"low","surface":"z"}
]' | "${SCRIPT}" init --force >/dev/null
"${SCRIPT}" status F-T01 shipped abc1234 "" >/dev/null
"${SCRIPT}" status F-T02 deferred "" "superseded by F-T01 fixture" >/dev/null
"${SCRIPT}" status F-T03 rejected "" "not reproducible" >/dev/null

for terminal_id in F-T01 F-T02 F-T03; do
  if "${SCRIPT}" mark-user-decision "${terminal_id}" "test reason" >/dev/null 2>&1; then
    printf '  FAIL: mark-user-decision should reject %s (terminal status)\n' "${terminal_id}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
  # Confirm the flag is still false (rejection precedes write)
  fl="$(jq -r --arg id "${terminal_id}" '.findings[]|select(.id==$id)|.requires_user_decision' "${findings_path}")"
  assert_eq "mark-user-decision rejected on ${terminal_id}: flag stayed false" \
    "false" "${fl}"
done

# But mark-user-decision still works on pending and in_progress findings
"${SCRIPT}" add-finding <<<'{"id":"F-T04","summary":"pending finding","severity":"low","surface":"x"}' >/dev/null
"${SCRIPT}" status F-T04 in_progress >/dev/null
"${SCRIPT}" mark-user-decision F-T04 "non-terminal" >/dev/null 2>&1
flag_t04="$(jq -r '.findings[]|select(.id=="F-T04")|.requires_user_decision' "${findings_path}")"
assert_eq "mark-user-decision succeeds on in_progress finding" "true" "${flag_t04}"

# ----------------------------------------------------------------------
printf '\n=== status-line subcommand (F-017) ===\n'

# Empty/missing
rm -f "${findings_path}"
status_line="$("${SCRIPT}" status-line)"
assert_contains "no plan reports 'no plan yet'" "no plan yet" "${status_line}"

# Build a substantive plan: 6 findings across 2 waves of 3
echo '[
  {"id":"F-S01","summary":"a","severity":"high","surface":"a"},
  {"id":"F-S02","summary":"b","severity":"high","surface":"a"},
  {"id":"F-S03","summary":"c","severity":"high","surface":"a"},
  {"id":"F-S04","summary":"d","severity":"high","surface":"b"},
  {"id":"F-S05","summary":"e","severity":"high","surface":"b"},
  {"id":"F-S06","summary":"f","severity":"high","surface":"b"}
]' | "${SCRIPT}" init >/dev/null
"${SCRIPT}" assign-wave 1 2 "surface-a" F-S01 F-S02 F-S03 >/dev/null 2>&1
"${SCRIPT}" assign-wave 2 2 "surface-b" F-S04 F-S05 F-S06 >/dev/null 2>&1

status_line="$("${SCRIPT}" status-line)"
assert_contains "0 shipped initially" "0/6 shipped" "${status_line}"
assert_contains "6 pending initially" "6 pending" "${status_line}"
assert_contains "0/2 waves initially" "0/2 waves" "${status_line}"
assert_contains "avg shows when wave plan active" "avg 3/wave" "${status_line}"
# Substantive plan should NOT have under-segmented warning
assert_not_contains_helper() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}
assert_not_contains_helper "no warning on substantive plan" "under-segmented" "${status_line}"

# Ship a couple findings to verify shipped count tracks
"${SCRIPT}" status F-S01 shipped abc1234 >/dev/null
"${SCRIPT}" status F-S02 shipped abc1234 >/dev/null
status_line="$("${SCRIPT}" status-line)"
assert_contains "shipped count updates" "2/6 shipped" "${status_line}"
assert_contains "pending decreases" "4 pending" "${status_line}"

# Build an under-segmented plan: 5 findings × 5 waves of 1 each
rm -f "${findings_path}"
echo '[
  {"id":"F-N01","summary":"a","severity":"high","surface":"a"},
  {"id":"F-N02","summary":"b","severity":"high","surface":"b"},
  {"id":"F-N03","summary":"c","severity":"high","surface":"c"},
  {"id":"F-N04","summary":"d","severity":"high","surface":"d"},
  {"id":"F-N05","summary":"e","severity":"high","surface":"e"}
]' | "${SCRIPT}" init >/dev/null
for i in 1 2 3 4 5; do
  "${SCRIPT}" assign-wave "${i}" 5 "surface-${i}" "F-N0${i}" >/dev/null 2>&1
done

status_line="$("${SCRIPT}" status-line)"
assert_contains "5x1 plan flagged under-segmented" "under-segmented" "${status_line}"
assert_contains "avg=1 reported" "avg 1/wave" "${status_line}"


# ===========================================================================
# v1.35.0 — require-WHY validation on status deferred|rejected
#
# Wave 1 of v1.35.0 wired omc_reason_has_concrete_why into the
# record-finding-list status path so the model can no longer mark
# findings deferred or rejected with weak reasons (parallel to the
# /mark-deferred and record-scope-checklist defenses). Tests below
# pin both the rejection of weak reasons AND the preservation of
# legitimate ones, plus the kill-switch and bypass-audit behaviors.
# ===========================================================================

printf '\n=== v1.35.0 — status deferred|rejected validator ===\n'

# Set up a fresh plan with three pending findings to exercise the validator.
echo '[
  {"id":"F-V01","summary":"a","severity":"high","surface":"x"},
  {"id":"F-V02","summary":"b","severity":"high","surface":"y"},
  {"id":"F-V03","summary":"c","severity":"high","surface":"z"}
]' | "${SCRIPT}" init --force >/dev/null

# Test V1.35-01: weak deferred reason rejected
set +e
out="$("${SCRIPT}" status F-V01 deferred "" "out of scope" 2>&1)"; rc=$?
set -e
assert_eq "deferred 'out of scope': exit 2" "2" "${rc}"
assert_contains "deferred 'out of scope': error names rule" "must name a concrete WHY" "${out}"
# Row stays pending because rejection precedes write.
v01_status="$(jq -r '.findings[]|select(.id=="F-V01")|.status' "${findings_path}")"
assert_eq "deferred 'out of scope': F-V01 stays pending" "pending" "${v01_status}"

# Test V1.35-02: weak rejected reason rejected (rejected status path)
set +e
out="$("${SCRIPT}" status F-V01 rejected "" "later" 2>&1)"; rc=$?
set -e
assert_eq "rejected 'later': exit 2" "2" "${rc}"
assert_contains "rejected 'later': error names rule" "must name a concrete WHY" "${out}"
v01_status="$(jq -r '.findings[]|select(.id=="F-V01")|.status' "${findings_path}")"
assert_eq "rejected 'later': F-V01 stays pending" "pending" "${v01_status}"

# Test V1.35-03: effort excuse rejected on deferred path
set +e
out="$("${SCRIPT}" status F-V01 deferred "" "requires significant effort" 2>&1)"; rc=$?
set -e
assert_eq "deferred 'requires significant effort': exit 2" "2" "${rc}"
assert_contains "effort excuse: error message present" "effort excuse" "${out}"

# Test V1.35-04: legitimate reason passes on deferred path
"${SCRIPT}" status F-V01 deferred "" "blocked by F-V02 fix shipping first" >/dev/null
v01_status="$(jq -r '.findings[]|select(.id=="F-V01")|.status' "${findings_path}")"
v01_notes="$(jq -r '.findings[]|select(.id=="F-V01")|.notes' "${findings_path}")"
assert_eq "deferred legit: F-V01 status=deferred" "deferred" "${v01_status}"
assert_eq "deferred legit: notes preserved" "blocked by F-V02 fix shipping first" "${v01_notes}"

# Test V1.35-05: legitimate rejected reason passes
"${SCRIPT}" status F-V02 rejected "" "false positive" >/dev/null
v02_status="$(jq -r '.findings[]|select(.id=="F-V02")|.status' "${findings_path}")"
assert_eq "rejected 'false positive': F-V02 status=rejected" "rejected" "${v02_status}"

# Test V1.35-06: empty notes on deferred path is permitted (preserves
# prior notes; same backward-compat as v1.34.x). The validator only
# fires when non-empty notes are provided.
"${SCRIPT}" status F-V03 deferred "" "" >/dev/null 2>&1 || true
v03_status="$(jq -r '.findings[]|select(.id=="F-V03")|.status' "${findings_path}")"
assert_eq "deferred empty-notes: F-V03 status=deferred" "deferred" "${v03_status}"

# Test V1.35-07: shipped path unchanged (descriptive notes accepted, no validation)
echo '[
  {"id":"F-S01","summary":"shipped-test","severity":"high","surface":"x"}
]' | "${SCRIPT}" init --force >/dev/null
"${SCRIPT}" status F-S01 shipped abc1234 "this is a descriptive commit summary" >/dev/null
s01_status="$(jq -r '.findings[]|select(.id=="F-S01")|.status' "${findings_path}")"
assert_eq "shipped: F-S01 status=shipped" "shipped" "${s01_status}"

# Test V1.35-08: kill switch — OMC_MARK_DEFERRED_STRICT=off bypasses validator
echo '[
  {"id":"F-K01","summary":"kill-switch-test","severity":"high","surface":"x"}
]' | "${SCRIPT}" init --force >/dev/null
OMC_MARK_DEFERRED_STRICT=off "${SCRIPT}" status F-K01 deferred "" "out of scope" >/dev/null
k01_status="$(jq -r '.findings[]|select(.id=="F-K01")|.status' "${findings_path}")"
assert_eq "kill-switch: F-K01 status=deferred" "deferred" "${k01_status}"

# Test V1.35-09: bypass audit row — when OMC_MARK_DEFERRED_STRICT=off
# AND the reason would have been rejected, gate_events.jsonl gets a
# strict-bypass row. Mirrors the audit shape used by mark-deferred.sh.
# events_file lives in the same session dir as findings.json.
events_file="$(dirname "${findings_path}")/gate_events.jsonl"
events_content="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "bypass audit: gate=finding-status" '"gate":"finding-status"' "${events_content}"
assert_contains "bypass audit: event=strict-bypass" '"event":"strict-bypass"' "${events_content}"
assert_contains "bypass audit: reason captured" "out of scope" "${events_content}"

# Test V1.35-10: bypass row absent when reason would have passed.
# Reset events file and exercise a valid reason via kill-switch.
echo '[
  {"id":"F-K02","summary":"kill-switch-valid-test","severity":"high","surface":"x"}
]' | "${SCRIPT}" init --force >/dev/null
rm -f "${events_file}"
OMC_MARK_DEFERRED_STRICT=off "${SCRIPT}" status F-K02 deferred "" "blocked by F-051 shipping first" >/dev/null
events_after="$(cat "${events_file}" 2>/dev/null || echo '')"
case "${events_after}" in
  *strict-bypass*)
    printf '  FAIL: V1.35-10: strict-bypass row should NOT fire for valid reason\n    actual: %s\n' "${events_after}" >&2
    fail=$((fail + 1)) ;;
  *)
    pass=$((pass + 1)) ;;
esac

printf '\n=== Finding-List Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
