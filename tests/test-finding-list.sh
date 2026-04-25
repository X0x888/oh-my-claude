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
assert_eq "no file → all zeros" "total=0 shipped=0 deferred=0 rejected=0 in_progress=0 pending=0" "${counts_out}"

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
printf 'Test 16: assign-wave missing surface rejected\n'
output="$("${SCRIPT}" assign-wave 1 2 "" F-001 2>&1 || echo CAUGHT)"
assert_contains "missing surface rejected" "usage:" "${output}"

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
"${SCRIPT}" status F-101 deferred "" "concurrent-B" &
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

printf '\n=== Finding-List Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
