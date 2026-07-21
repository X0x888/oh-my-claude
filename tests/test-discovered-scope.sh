#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="scope-test-session"
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

assert_ge() {
  local label="$1" floor="$2" actual="$3"
  if [[ "${actual}" -ge "${floor}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected >= %s actual=%s\n' "${label}" "${floor}" "${actual}" >&2
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

reset_scope() {
  rm -f "$(session_file "discovered_scope.jsonl")"
  rm -f "$(session_file "findings.json")"
  rm -f "$(session_file "${STATE_JSON}")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

# ----------------------------------------------------------------------
# Inline simulation of the discovered-scope stop-guard gate.
# Mirrors the block in stop-guard.sh — keep in sync if that gate changes.
# Returns one of: block:<n>/<cap>, allow:no_pending, allow:cap_reached,
# allow:flag_off, allow:non_execution, allow:no_file
#
# Mirrors stop-guard.sh wave-aware cap: when findings.json declares N waves,
# cap = N+1; otherwise cap = 2.
# ----------------------------------------------------------------------
run_scope_gate() {
  local task_intent="$1"
  if [[ "${OMC_DISCOVERED_SCOPE}" != "on" ]]; then
    printf 'allow:flag_off'; return
  fi
  if ! is_execution_intent_value "${task_intent}"; then
    printf 'allow:non_execution'; return
  fi
  local scope_file
  scope_file="$(session_file "discovered_scope.jsonl")"
  if [[ ! -f "${scope_file}" ]]; then
    printf 'allow:no_file'; return
  fi
  local pending blocks wave_total cap
  pending="$(read_pending_scope_count)"
  blocks="$(read_state "discovered_scope_blocks")"
  blocks="${blocks:-0}"
  wave_total="$(read_active_wave_total)"
  if [[ "${wave_total}" -gt 0 ]]; then
    cap=$((wave_total + 1))
  else
    cap=2
  fi
  if [[ "${pending}" -gt 0 && "${blocks}" -lt "${cap}" ]]; then
    write_state "discovered_scope_blocks" "$((blocks + 1))"
    printf 'block:%s/%s' "$((blocks + 1))" "${cap}"
    return
  fi
  if [[ "${pending}" -gt 0 ]]; then
    printf 'allow:cap_reached'; return
  fi
  printf 'allow:no_pending'
}

# Helper: write a minimal findings.json with N waves so tests can simulate
# an active wave plan without invoking record-finding-list.sh.
fake_wave_plan() {
  local n="$1"
  local waves_json findings_json
  waves_json="$(seq 1 "${n}" | jq -R -s '
    split("\n") | map(select(length>0)) | map({
      index: tonumber, total: '"${n}"', surface: ("wave-"+.),
      finding_ids: [], status: "pending", commit_sha: "", ts: 0
    })')"
  findings_json="$(jq -nc --argjson waves "${waves_json}" \
    '{version:1, created_ts:0, updated_ts:0, findings:[], waves:$waves}')"
  printf '%s\n' "${findings_json}" > "$(session_file "findings.json")"
}

clear_wave_plan() {
  rm -f "$(session_file "findings.json")"
}

# Test fixtures
SECURITY_LENS_OUTPUT='## Security Assessment

The codebase shows reasonable hygiene but has gaps.

### Critical Findings

1. **Unauthenticated admin endpoint** — The `/admin/users` route lacks any auth check. High risk if deployed.
2. **Database credentials in env vars** — Plaintext credentials sit in `.env` checked into the repo. Critical exposure.
3. **No rate limiting on login** — Bruteforce attempts unbounded.

### Top 3 Security Recommendations

1. **Adopt JWT middleware** for all admin routes immediately.
2. **Move secrets to a vault** like AWS Secrets Manager or Doppler.
3. **Add per-IP rate limit** on auth endpoints (10/min).

### Unknown Unknowns

- Dependency CVE scanning is not configured in CI.

VERDICT: FINDINGS (3)'

METIS_OUTPUT='## Plan Stress-Test

I read the proposed migration plan. Findings first, ordered by severity.

1. **Race condition between backfill and dual-write** — The plan assumes a quiet write window that does not exist for this table.
2. **No rollback procedure for the v2 schema** — If the cutover fails after the rename, there is no documented unwind path.
3. **Index creation under load** — The CREATE INDEX is non-concurrent, which will lock the table on production traffic.

VERDICT: FINDINGS (3)'

GARBAGE_OUTPUT='Just some prose about the project. Nothing structured here.

It mentions some things, in passing, but no list.'

CODE_FENCED_OUTPUT='Here is some code that uses numbered logic:

```python
def compute():
    1. validate
    2. process
    3. emit
```

This is not a finding list.'

# ----------------------------------------------------------------------
printf 'Test 1: extract security-lens output (3 findings + 3 recs + 1 unknown)\n'
reset_scope
rows="$(extract_discovered_findings "security-lens" "${SECURITY_LENS_OUTPUT}" || true)"
row_count="$(printf '%s\n' "${rows}" | grep -c '"id"' 2>/dev/null || true)"
row_count="${row_count:-0}"
# Should capture at least 6 (findings + recs); exact number can vary if the
# extractor is liberal with section anchors. Anything in 6..10 is fine.
assert_ge "captures security-lens findings" 6 "${row_count}"

# Severity heuristic: at least one row should be 'high' (we used "Critical" wording)
high_count="$(printf '%s\n' "${rows}" | grep -c '"severity":"high"' 2>/dev/null || true)"
high_count="${high_count:-0}"
assert_ge "at least one high-severity row" 1 "${high_count}"

# All rows have status:pending
pending_in_rows="$(printf '%s\n' "${rows}" | grep -c '"status":"pending"' 2>/dev/null || true)"
pending_in_rows="${pending_in_rows:-0}"
assert_eq "all rows are pending" "${row_count}" "${pending_in_rows}"

# Source is correctly stamped
src_count="$(printf '%s\n' "${rows}" | grep -c '"source":"security-lens"' 2>/dev/null || true)"
src_count="${src_count:-0}"
assert_eq "all rows source=security-lens" "${row_count}" "${src_count}"

# ----------------------------------------------------------------------
printf 'Test 2: extract metis findings (3 numbered, anchor=findings)\n'
rows="$(extract_discovered_findings "metis" "${METIS_OUTPUT}" || true)"
row_count="$(printf '%s\n' "${rows}" | grep -c '"id"' 2>/dev/null || true)"
row_count="${row_count:-0}"
assert_ge "captures metis findings" 3 "${row_count}"

# ----------------------------------------------------------------------
printf 'Test 3: extract on garbage prose (no list) — empty\n'
rows="$(extract_discovered_findings "metis" "${GARBAGE_OUTPUT}" || true)"
row_count="$(printf '%s' "${rows}" | grep -c '"id"' 2>/dev/null || true)"
row_count="${row_count:-0}"
assert_eq "no rows extracted from garbage" "0" "${row_count}"

# ----------------------------------------------------------------------
printf 'Test 4: code-fenced numbered list NOT captured\n'
rows="$(extract_discovered_findings "metis" "${CODE_FENCED_OUTPUT}" || true)"
row_count="$(printf '%s' "${rows}" | grep -c '"id"' 2>/dev/null || true)"
row_count="${row_count:-0}"
assert_eq "code-fenced list not captured" "0" "${row_count}"

# ----------------------------------------------------------------------
printf 'Test 5: empty input — empty output\n'
rows="$(extract_discovered_findings "metis" "" || true)"
row_count="$(printf '%s' "${rows}" | grep -c '"id"' 2>/dev/null || true)"
row_count="${row_count:-0}"
assert_eq "empty input → empty output" "0" "${row_count}"

# ----------------------------------------------------------------------
printf 'Test 6: append_discovered_scope writes rows\n'
reset_scope
rows="$(extract_discovered_findings "metis" "${METIS_OUTPUT}")"
append_discovered_scope "metis" "${rows}"
file="$(session_file "discovered_scope.jsonl")"
written_count=0
if [[ -f "${file}" ]]; then
  written_count="$(wc -l < "${file}" | tr -d '[:space:]')"
fi
assert_ge "rows written to jsonl" 3 "${written_count}"

# ----------------------------------------------------------------------
printf 'Test 7: append idempotent (dedup by id)\n'
# Second append of same content should not add new rows
append_discovered_scope "metis" "${rows}"
written_count2=0
if [[ -f "${file}" ]]; then
  written_count2="$(wc -l < "${file}" | tr -d '[:space:]')"
fi
assert_eq "second append no-op (dedup)" "${written_count}" "${written_count2}"

# Gate-relevant discovered scope must fail closed on a hostile target shape.
# The universal summary claim may only become effects-complete after this
# append succeeds; following a symlink would both corrupt external bytes and
# falsely certify that all findings were recorded.
reset_scope
external_scope="${TEST_STATE_ROOT}/external-scope.jsonl"
printf 'external-scope-sentinel\n' >"${external_scope}"
ln -s "${external_scope}" "${file}"
set +e
append_discovered_scope "metis" "${rows}" >/dev/null 2>&1
scope_symlink_rc=$?
set -e
assert_eq "symlinked discovered-scope target fails closed" "1" \
  "$([[ "${scope_symlink_rc}" -ne 0 ]] && printf 1 || printf 0)"
assert_eq "symlinked discovered-scope target preserves external bytes" \
  "external-scope-sentinel" "$(<"${external_scope}")"
rm -f "${file}"
append_discovered_scope "metis" "${rows}"

# ----------------------------------------------------------------------
printf 'Test 8: read_pending_scope_count\n'
pending="$(read_pending_scope_count)"
assert_eq "pending count matches written" "${written_count}" "${pending}"

# ----------------------------------------------------------------------
printf 'Test 9: build_discovered_scope_scorecard returns lines\n'
sc="$(build_discovered_scope_scorecard 5 || true)"
sc_lines="$(printf '%s' "${sc}" | wc -l | tr -d '[:space:]')"
# Some non-zero number of lines expected
assert_ge "scorecard has lines" 1 "$((sc_lines + 1))"
assert_contains "scorecard mentions metis" "metis" "${sc}"

# ----------------------------------------------------------------------
printf 'Test 10: stop-guard fires on pending rows in execution\n'
reset_scope
append_discovered_scope "metis" "${rows}"
verdict="$(run_scope_gate "execution")"
assert_contains "execution gate blocks" "block:1/2" "${verdict}"

# Second stop attempt also blocks
verdict="$(run_scope_gate "execution")"
assert_contains "execution gate blocks again" "block:2/2" "${verdict}"

# Third stop attempt allows (cap reached)
verdict="$(run_scope_gate "execution")"
assert_contains "cap reached releases" "allow:cap_reached" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 11: stop-guard allows on advisory intent\n'
reset_scope
append_discovered_scope "metis" "${rows}"
verdict="$(run_scope_gate "advisory")"
assert_contains "advisory bypasses gate" "allow:non_execution" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 12: stop-guard allows when no scope file exists\n'
reset_scope
verdict="$(run_scope_gate "execution")"
assert_contains "no file → allow" "allow:no_file" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 13: OMC_DISCOVERED_SCOPE=off bypasses gate\n'
reset_scope
append_discovered_scope "metis" "${rows}"
OLD_FLAG="${OMC_DISCOVERED_SCOPE}"
OMC_DISCOVERED_SCOPE="off"
verdict="$(run_scope_gate "execution")"
assert_contains "flag off bypasses" "allow:flag_off" "${verdict}"
OMC_DISCOVERED_SCOPE="${OLD_FLAG}"

# ----------------------------------------------------------------------
printf 'Test 14: update_scope_status flips pending → shipped (full id)\n'
reset_scope
append_discovered_scope "metis" "${rows}"
first_id="$(jq -r '.id' < "${file}" | head -1)"
update_scope_status "${first_id}" "shipped" "addressed in commit abc123"
status_after="$(jq -r --arg id "${first_id}" 'select(.id == $id) | .status' < "${file}")"
assert_eq "status updated to shipped" "shipped" "${status_after}"

# Pending count decremented
new_pending="$(read_pending_scope_count)"
assert_eq "pending decremented" "$((written_count - 1))" "${new_pending}"

# Short prefix is rejected (defensive against silent wrong-row updates)
prev_status="$(jq -r 'select(.status=="pending") | .id' < "${file}" | head -1)"
prev_id="${prev_status}"
update_scope_status "abc" "shipped" "should not happen" 2>/dev/null || true
unchanged_status="$(jq -r --arg id "${prev_id}" 'select(.id == $id) | .status' < "${file}")"
assert_eq "short prefix rejected, status unchanged" "pending" "${unchanged_status}"

# ----------------------------------------------------------------------
printf 'Test 15: capture_targets includes all advisory specialists\n'
targets="$(discovered_scope_capture_targets | tr '\n' ' ')"
# v1.27.0 (F-006): added oracle and abstraction-critic. quality-researcher
# was deliberately excluded — its output is research/recommendations, not
# severity-anchored findings, and the fallback regex would over-fire on
# its numbered next-step lists. Implementation specialists remain excluded
# (they describe what was built, not what was discovered).
for expected in metis briefing-analyst oracle abstraction-critic security-lens data-lens product-lens growth-lens sre-lens design-lens visual-craft-lens; do
  assert_contains "target list includes ${expected}" "${expected}" "${targets}"
done
assert_not_contains "quality-researcher excluded (research reports, not findings)" "quality-researcher" "${targets}"

# ----------------------------------------------------------------------
printf 'Test 16: capture_targets EXCLUDES verifiers (excellence-reviewer, quality-reviewer)\n'
assert_not_contains "no excellence-reviewer in capture" "excellence-reviewer" "${targets}"
assert_not_contains "no quality-reviewer in capture" "quality-reviewer" "${targets}"

# ----------------------------------------------------------------------
printf 'Test 17: severity heuristic maps keywords correctly\n'
sev_high="$(_severity_from_bullet "Critical issue: race condition in handler")"
assert_eq "critical → high" "high" "${sev_high}"
sev_med="$(_severity_from_bullet "Medium concern: stale comment")"
assert_eq "medium → medium" "medium" "${sev_med}"
sev_low="$(_severity_from_bullet "Stylistic nit in formatter")"
assert_eq "default → low" "low" "${sev_low}"

# ----------------------------------------------------------------------
printf 'Test 18a: malformed JSONL row does not silently disable the gate\n'
reset_scope
append_discovered_scope "metis" "${rows}"
# Inject a malformed line in the middle — historically jq -s slurp would
# fail entirely and `read_pending_scope_count` would return 0, hiding all
# pending findings from the gate.
{
  head -1 "${file}"
  printf 'this is not valid json\n'
  tail -n +2 "${file}"
} > "${file}.poisoned"
mv "${file}.poisoned" "${file}"
pending_after_poison="$(read_pending_scope_count)"
# Expected: equals written_count (3 valid metis rows). Bug repro: 0.
assert_eq "malformed row skipped, parseable rows still counted" "${written_count}" "${pending_after_poison}"

# Scorecard still emits valid lines (does not blow up on the corrupt row)
sc_post_poison="$(build_discovered_scope_scorecard 5 || true)"
assert_contains "scorecard works post-poison" "metis" "${sc_post_poison}"

# ----------------------------------------------------------------------
printf 'Test 18b: fallback does NOT fire on plain step-by-step instructions\n'
INSTRUCTIONS_OUTPUT='## Plan Summary

Here is how to ship this:

1. Run the migration script in staging
2. Verify with smoke tests
3. Deploy to production

That is all.'
inst_rows="$(extract_discovered_findings "metis" "${INSTRUCTIONS_OUTPUT}" || true)"
inst_count="$(printf '%s' "${inst_rows}" | grep -c '"id"' 2>/dev/null || true)"
inst_count="${inst_count:-0}"
assert_eq "instructions not captured as findings" "0" "${inst_count}"

# But: same numbered list with finding-language present DOES trigger fallback
INSTRUCTIONS_WITH_RISK='## Migration Plan

Here are some risks to address before the cutover:

1. Race condition between backfill and cutover
2. No rollback path documented
3. Index rebuild under load'
risk_rows="$(extract_discovered_findings "metis" "${INSTRUCTIONS_WITH_RISK}" || true)"
risk_count="$(printf '%s' "${risk_rows}" | grep -c '"id"' 2>/dev/null || true)"
risk_count="${risk_count:-0}"
assert_ge "risk-language list captured via fallback" 3 "${risk_count}"

# ----------------------------------------------------------------------
printf 'Test 18c: /ulw-skip clears discovered_scope_blocks counter\n'
reset_scope
append_discovered_scope "metis" "${rows}"
# Block twice then assert third release is the cap path (not skip)
verdict="$(run_scope_gate "execution")"
assert_contains "first block" "block:1/2" "${verdict}"
# Now simulate skip: clear the counter as ulw-skip-register would
write_state "discovered_scope_blocks" "0"
verdict="$(run_scope_gate "execution")"
assert_contains "skip-cleared counter blocks fresh" "block:1/2" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 18d: within-batch dedup (same content emitted twice in one batch)\n'
reset_scope
dup_rows="${rows}
${rows}"
append_discovered_scope "metis" "${dup_rows}"
batch_count=0
if [[ -f "${file}" ]]; then
  batch_count="$(wc -l < "${file}" | tr -d '[:space:]')"
fi
# Should be the original count, not double it
assert_eq "within-batch duplicates deduped" "${written_count}" "${batch_count}"

# ----------------------------------------------------------------------
printf 'Test 18e: dash bullets under anchored heading ARE captured\n'
DASH_LENS_OUTPUT='## Security Assessment

### Critical Findings

- **Unauthenticated admin endpoint** — `/admin/users` lacks any auth check
- **Database credentials in env vars** — plaintext checked into repo
- **No rate limiting on login** — bruteforce unbounded

### Recommendations

- Adopt JWT middleware for all admin routes
- Move secrets to a vault'
dash_rows="$(extract_discovered_findings "security-lens" "${DASH_LENS_OUTPUT}" || true)"
dash_count="$(printf '%s' "${dash_rows}" | grep -c '"id"' 2>/dev/null || true)"
dash_count="${dash_count:-0}"
assert_ge "dash bullets captured under anchored heading" 5 "${dash_count}"

# Star bullets too
STAR_OUTPUT='## Risk Assessment

### Risks

* **Race condition** — backfill vs cutover
* **No rollback** — undocumented unwind
* **Index under load** — locks table'
star_rows="$(extract_discovered_findings "metis" "${STAR_OUTPUT}" || true)"
star_count="$(printf '%s' "${star_rows}" | grep -c '"id"' 2>/dev/null || true)"
star_count="${star_count:-0}"
assert_ge "star bullets captured under anchored heading" 3 "${star_count}"

# But dash bullets WITHOUT anchored heading and without finding-language are NOT captured
DASH_INSTRUCTIONS='## Plan

Things to do:

- Run migration
- Verify tests
- Deploy'
nf_rows="$(extract_discovered_findings "metis" "${DASH_INSTRUCTIONS}" || true)"
nf_count="$(printf '%s' "${nf_rows}" | grep -c '"id"' 2>/dev/null || true)"
nf_count="${nf_count:-0}"
assert_eq "dash instructions w/o anchor not captured" "0" "${nf_count}"

# ----------------------------------------------------------------------
printf 'Test 19: append handles 200-row cap (FIFO trim)\n'
reset_scope
# Generate 250 unique rows
big_rows=""
for i in $(seq 1 250); do
  row="$(jq -nc \
    --arg id "fake$(printf '%08d' "${i}")" \
    --arg src "metis" \
    --arg sum "Synthetic finding ${i}" \
    --arg sev "low" \
    --arg ts "1700000000" \
    '{id:$id, source:$src, summary:$sum, severity:$sev, status:"pending", reason:"", ts:$ts}')"
  big_rows="${big_rows}${row}
"
done
append_discovered_scope "metis" "${big_rows}"
final_count=0
if [[ -f "${file}" ]]; then
  final_count="$(wc -l < "${file}" | tr -d '[:space:]')"
fi
assert_eq "200-row cap enforced" "200" "${final_count}"

# ----------------------------------------------------------------------
printf 'Test 20: wave plan raises cap from 2 to N+1\n'
reset_scope
clear_wave_plan
# Seed pending findings
rows="$(extract_discovered_findings "metis" "${METIS_OUTPUT}")"
append_discovered_scope "metis" "${rows}"
# Without wave plan: cap=2
verdict="$(run_scope_gate "execution")"
assert_eq "no wave plan: first block cap=2" "block:1/2" "${verdict}"
verdict="$(run_scope_gate "execution")"
assert_eq "no wave plan: second block cap=2" "block:2/2" "${verdict}"
verdict="$(run_scope_gate "execution")"
assert_eq "no wave plan: third invocation releases" "allow:cap_reached" "${verdict}"

# Reset and seed a 5-wave plan
reset_scope
append_discovered_scope "metis" "${rows}"
fake_wave_plan 5
# With 5 waves: cap=6
for i in 1 2 3 4 5 6; do
  verdict="$(run_scope_gate "execution")"
  assert_eq "5-wave plan: block ${i}/6" "block:${i}/6" "${verdict}"
done
verdict="$(run_scope_gate "execution")"
assert_eq "5-wave plan: 7th invocation releases" "allow:cap_reached" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 21: read_active_wave_total returns 0 when findings.json missing\n'
clear_wave_plan
total="$(read_active_wave_total)"
assert_eq "no findings.json → 0" "0" "${total}"

fake_wave_plan 3
total="$(read_active_wave_total)"
assert_eq "3-wave plan → 3" "3" "${total}"

# ----------------------------------------------------------------------
printf 'Test 22: malformed findings.json fails open (returns 0)\n'
clear_wave_plan
printf 'not valid json {{{' > "$(session_file "findings.json")"
total="$(read_active_wave_total)"
assert_eq "malformed json → 0" "0" "${total}"

# ----------------------------------------------------------------------
printf 'Test 23: read_active_waves_completed counts completed waves\n'
clear_wave_plan
fake_wave_plan 3
done_count="$(read_active_waves_completed)"
assert_eq "fresh plan → 0 completed" "0" "${done_count}"

# Mark wave 1 completed
findings_file="$(session_file "findings.json")"
jq '.waves = (.waves | map(if .index == 1 then .status = "completed" else . end))' \
  "${findings_file}" > "${findings_file}.tmp" && mv "${findings_file}.tmp" "${findings_file}"
done_count="$(read_active_waves_completed)"
assert_eq "wave 1 completed → 1" "1" "${done_count}"

# ----------------------------------------------------------------------
printf 'Test 24: wave plan with 1 wave → cap=2 (smallest valid plan)\n'
# Boundary: cap matches no-plan numerically (2) but via the wave-aware
# code path. Catches off-by-one in the formula `cap = wave_total + 1`.
reset_scope
fake_wave_plan 1
append_discovered_scope "metis" "${rows}"
verdict="$(run_scope_gate "execution")"
assert_eq "1-wave plan: first block cap=2" "block:1/2" "${verdict}"
verdict="$(run_scope_gate "execution")"
assert_eq "1-wave plan: second block cap=2" "block:2/2" "${verdict}"
verdict="$(run_scope_gate "execution")"
assert_eq "1-wave plan: third invocation releases" "allow:cap_reached" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 25: wave plan with 10 waves → cap=11 (large plan stays useful)\n'
# High-end boundary: cap formula must scale linearly without truncation.
reset_scope
fake_wave_plan 10
append_discovered_scope "metis" "${rows}"
for i in $(seq 1 11); do
  verdict="$(run_scope_gate "execution")"
  assert_eq "10-wave plan: block ${i}/11" "block:${i}/11" "${verdict}"
done
verdict="$(run_scope_gate "execution")"
assert_eq "10-wave plan: 12th invocation releases" "allow:cap_reached" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 26: read_active_waves_completed counts non-contiguous completions\n'
# Verifies the helper counts by status field, not by position. A plan with
# waves 1, 2, 4 marked completed (skipping 3) must report 3.
clear_wave_plan
fake_wave_plan 5
findings_file="$(session_file "findings.json")"
jq '.waves = (.waves | map(if .index == 1 or .index == 2 or .index == 4 then .status = "completed" else . end))' \
  "${findings_file}" > "${findings_file}.tmp" && mv "${findings_file}.tmp" "${findings_file}"
done_count="$(read_active_waves_completed)"
assert_eq "non-contiguous: 3 of 5 completed → 3" "3" "${done_count}"

# wave_total reflects declared total, not completed count
total_after="$(read_active_wave_total)"
assert_eq "wave_total unchanged by completion status" "5" "${total_after}"

# ----------------------------------------------------------------------
printf 'Test 27: cap formula uses wave_total, not waves_remaining\n'
# When some waves are already complete, the cap must still be wave_total+1
# (not (remaining+1)). Documents the design intent: discovered_scope_blocks
# is incremented per stop attempt, not per completed wave, so the cap is a
# function of the plan size, not progress.
reset_scope
fake_wave_plan 5
findings_file="$(session_file "findings.json")"
jq '.waves = (.waves | map(if .index <= 3 then .status = "completed" else . end))' \
  "${findings_file}" > "${findings_file}.tmp" && mv "${findings_file}.tmp" "${findings_file}"
append_discovered_scope "metis" "${rows}"
verdict="$(run_scope_gate "execution")"
assert_eq "3 of 5 waves done: cap still 6" "block:1/6" "${verdict}"

# ----------------------------------------------------------------------
printf 'Test 28: gate recovery text mentions record-serendipity.sh\n'
# v1.18.0 — the discovered-scope gate's recovery line names every
# affordance the model can invoke at the moment of need: /mark-deferred
# for bulk deferral, /ulw-skip for one-shot bypass, AND record-serendipity.sh
# for adjacent-defect logging. The Serendipity Rule was previously only in
# static memory (core.md), invisible at the gate firing — this assertion
# locks the surfacing in place so the rule can't drift back to invisible.
gate_script="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/stop-guard.sh"
gate_text="$(cat "${gate_script}")"
assert_contains "stop-guard recovery line names /mark-deferred" \
  "/mark-deferred" "${gate_text}"
assert_contains "stop-guard recovery line names /ulw-skip" \
  "/ulw-skip" "${gate_text}"
assert_contains "stop-guard recovery line names record-serendipity.sh" \
  "record-serendipity.sh" "${gate_text}"

# ----------------------------------------------------------------------
printf 'Test 29: prompt-intent-router coding-domain block names Serendipity Rule\n'
# The router's coding-domain context block is the proactive surface — it
# fires on every coding-execution prompt and tells the model to watch for
# adjacent defects. Without it, the rule lives only in static memory and
# in the post-hoc gate text, never in the working context at edit time.
router_script="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
router_text="$(cat "${router_script}")"
assert_contains "router coding block names Serendipity Rule" \
  "Serendipity Rule" "${router_text}"
assert_contains "router coding block names record-serendipity.sh" \
  "record-serendipity.sh" "${router_text}"

# ----------------------------------------------------------------------
printf 'Test 30: zero_capture telemetry fires on long whitelisted-agent output with no findings (v1.27.0 F-007)\n'
# Set up: synthesize a SubagentStop event for `metis` with a long
# message body that has no findings structure (no anchored heading, no
# numbered list with finding-keyword + severity, etc.). The
# record-subagent-summary.sh hook should:
#   1. Try to extract findings — get nothing.
#   2. Detect that the message is >500 chars (the new threshold).
#   3. Emit a `gate=discovered-scope event=zero_capture` row.
zc_session_root="$(mktemp -d)"
zc_session_id="zc-test-$$"
zc_state_dir="${zc_session_root}/${zc_session_id}"
mkdir -p "${zc_state_dir}"
# Activate ULW mode in the synthetic session so is_ultrawork_mode returns true.
printf '{"workflow_mode":"ultrawork"}\n' > "${zc_state_dir}/session_state.json"

# Build a >500-char message body that has no findings shape at all —
# pure prose with no numbered list, no heading anchors. Use a
# python/awk-portable string repeat to avoid yes|head SIGPIPE.
long_prose=""
for _ in 1 2 3 4 5 6 7; do
  long_prose+="This is a long prose paragraph that summarizes my analysis without any structured findings list. "
done
zc_payload="$(jq -nc \
  --arg sid "${zc_session_id}" \
  --arg msg "${long_prose}" \
  '{session_id: $sid, agent_type: "metis", message: $msg, last_assistant_message: $msg}')"

OMC_DISCOVERED_SCOPE=on \
SESSION_ID="${zc_session_id}" \
STATE_ROOT="${zc_session_root}" \
HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${zc_payload}" >/dev/null 2>&1 || true

zc_events="${zc_state_dir}/gate_events.jsonl"
if [[ -f "${zc_events}" ]]; then
  zc_zero="$(grep '"event":"zero_capture"' "${zc_events}" 2>/dev/null | head -1)"
  assert_contains "zero_capture row written for long-no-findings metis output" \
    '"gate":"discovered-scope"' "${zc_zero}"
  assert_contains "zero_capture row carries agent name in details" \
    '"agent":"metis"' "${zc_zero}"
  # The msg_len should be a number, not a string, in the details.
  zc_len="$(printf '%s' "${zc_zero}" | jq -r '.details.msg_len // empty' 2>/dev/null)"
  assert_eq "msg_len present in details" "$(printf '%s' "${long_prose}" | wc -c | tr -d ' ')" "${zc_len}"
else
  printf '  FAIL: gate_events.jsonl was not written; zero_capture telemetry missing\n' >&2
  fail=$((fail + 3))
fi

# Short message (<= 500 chars) should NOT trigger zero_capture telemetry —
# threshold gates noise.
short_session_id="zc-short-$$"
short_state_dir="${zc_session_root}/${short_session_id}"
mkdir -p "${short_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${short_state_dir}/session_state.json"
short_payload="$(jq -nc \
  --arg sid "${short_session_id}" \
  '{session_id: $sid, agent_type: "metis", message: "Quick note.", last_assistant_message: "Quick note."}')"
OMC_DISCOVERED_SCOPE=on \
SESSION_ID="${short_session_id}" \
STATE_ROOT="${zc_session_root}" \
HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${short_payload}" >/dev/null 2>&1 || true
short_events="${short_state_dir}/gate_events.jsonl"
# Tightened (per Wave 2 review): treat both "no file" and "file with
# zero matches" as the not-fired case. grep -c emits "0" (not empty)
# when the file exists but has no matches, so the prior assertion
# could pass for the wrong reason if the file got created but stayed
# empty.
if [[ -f "${short_events}" ]]; then
  short_zc_count="$(grep -c '"event":"zero_capture"' "${short_events}" 2>/dev/null || printf 0)"
  short_zc_count="${short_zc_count:-0}"
else
  short_zc_count=0
fi
assert_eq "zero_capture not fired below 500 char threshold" "0" "${short_zc_count}"

# A custom/non-prefixed Council specialist can participate safely by emitting
# the deterministic FINDINGS_JSON contract. Prose heuristics stay allowlisted.
custom_session_id="zc-custom-$$"
custom_state_dir="${zc_session_root}/${custom_session_id}"
mkdir -p "${custom_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${custom_state_dir}/session_state.json"
custom_message='FINDINGS_JSON: [{"severity":"high","category":"security","file":"src/auth.ts","line":9,"claim":"Custom specialist found an auth bypass","evidence":"guard omitted","recommended_fix":"enforce guard"}]'$'\n''VERDICT: FINDINGS (1)'
custom_payload="$(jq -nc --arg sid "${custom_session_id}" --arg msg "${custom_message}" \
  '{session_id:$sid,agent_type:"custom-trust-auditor",message:$msg,last_assistant_message:$msg}')"
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_payload}" >/dev/null 2>&1 || true
custom_scope="${custom_state_dir}/discovered_scope.jsonl"
assert_eq "custom structured specialist finding is captured" "custom-trust-auditor" \
  "$(jq -r '.source // empty' "${custom_scope}" 2>/dev/null | head -1)"

custom_prose_session_id="zc-custom-prose-$$"
custom_prose_state_dir="${zc_session_root}/${custom_prose_session_id}"
mkdir -p "${custom_prose_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${custom_prose_state_dir}/session_state.json"
custom_prose=$'### Findings\n1. High: prose-only custom finding'
custom_prose_payload="$(jq -nc --arg sid "${custom_prose_session_id}" --arg msg "${custom_prose}" \
  '{session_id:$sid,agent_type:"custom-trust-auditor",message:$msg,last_assistant_message:$msg}')"
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_prose_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_prose_payload}" >/dev/null 2>&1 || true
if [[ -f "${custom_prose_state_dir}/discovered_scope.jsonl" ]]; then
  custom_prose_count="$(wc -l < "${custom_prose_state_dir}/discovered_scope.jsonl" | tr -d ' ')"
else
custom_prose_count=0
fi
assert_eq "custom prose-only output is not heuristic-scraped" "0" "${custom_prose_count}"

custom_council_native_id="native-custom-trust-auditor"
seed_current_custom_council_dispatch() {
  local state_dir="$1" ts="$2"
  local lifecycle="dispatch-customcouncil-${ts}-abcdefgh"

  # Model a real current Council dispatch. Current sessions bind every
  # completion to the immutable lifecycle/native/objective/enforcement tuple;
  # a bare legacy pending row is intentionally not publication authority.
  jq '. + {
      ulw_enforcement_active:"1",ulw_enforcement_generation:"1",
      subagent_dispatch_tracking_version:"1",
      native_agent_id_tracking_version:"1",
      last_user_prompt_ts:100,prompt_revision:1,
      review_cycle_prompt_ts:100,review_cycle_id:1
    }' "${state_dir}/session_state.json" \
    > "${state_dir}/session_state.json.tmp"
  mv "${state_dir}/session_state.json.tmp" \
    "${state_dir}/session_state.json"
  printf '%s\n' \
    '{"objective_prompt_ts":100,"objective_prompt_revision":1,"objective_cycle_id":1}' \
    > "${state_dir}/council_coverage.json"
  jq -nc \
    --arg native "${custom_council_native_id}" \
    --arg lifecycle "${lifecycle}" \
    --argjson ts "${ts}" \
    '{ts:$ts,agent_type:"custom-trust-auditor",
      description:"[council:primary] trust audit",
      lifecycle_dispatch_id:$lifecycle,native_agent_id:$native,
      edit_revision:0,code_revision:0,doc_revision:0,bash_revision:0,
      ui_revision:0,plan_revision:0,review_revision:0,
      objective_prompt_ts:100,objective_prompt_revision:1,
      objective_cycle_id:1,ulw_enforcement_generation:"1",
      purpose:"council",council_phase:"primary",
      council_selection_agent:"custom-trust-auditor",
      council_objective_prompt_ts:100,council_objective_prompt_revision:1,
      council_ledger_generation:1}' \
    > "${state_dir}/pending_agents.jsonl"
  jq -nc \
    --arg native "${custom_council_native_id}" \
    --arg lifecycle "${lifecycle}" \
    '{native_agent_id:$native,agent_type:"custom-trust-auditor",
      review_dispatch_id:"",lifecycle_dispatch_id:$lifecycle,
      objective_cycle_id:1,ts:100}' \
    > "${state_dir}/native_agent_bindings.jsonl"
}

custom_missing_session_id="zc-custom-missing-json-$$"
custom_missing_state_dir="${zc_session_root}/${custom_missing_session_id}"
mkdir -p "${custom_missing_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${custom_missing_state_dir}/session_state.json"
seed_current_custom_council_dispatch "${custom_missing_state_dir}" 1
custom_missing=$'I found an issue but used my native prose format.\nVERDICT: FINDINGS (1)'
custom_missing_payload="$(jq -nc --arg sid "${custom_missing_session_id}" \
  --arg native "${custom_council_native_id}" --arg msg "${custom_missing}" \
  '{session_id:$sid,agent_type:"custom-trust-auditor",agent_id:$native,
    message:$msg,last_assistant_message:$msg}')"
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_missing_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_missing_payload}" >/dev/null 2>&1 || true
assert_contains "custom findings verdict without JSON creates actionable placeholder" \
  "omitted the required FINDINGS_JSON" \
  "$(jq -r '.summary // empty' "${custom_missing_state_dir}/discovered_scope.jsonl" 2>/dev/null | head -1)"

# Resolving one malformed return must not deduplicate a later malformed
# Council return from the same custom agent.
jq '(.status)="shipped" | (.reason)="specialist rerun requested"' \
  "${custom_missing_state_dir}/discovered_scope.jsonl" \
  > "${custom_missing_state_dir}/discovered_scope.jsonl.tmp"
mv "${custom_missing_state_dir}/discovered_scope.jsonl.tmp" \
  "${custom_missing_state_dir}/discovered_scope.jsonl"
seed_current_custom_council_dispatch "${custom_missing_state_dir}" 2
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_missing_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_missing_payload}" >/dev/null 2>&1 || true
assert_eq "repeat malformed Council return gets a distinct pending placeholder" "2:1" \
  "$(jq -s -r '[length, ([.[] | select(.status == "pending")] | length)] | map(tostring) | join(":")' \
      "${custom_missing_state_dir}/discovered_scope.jsonl" 2>/dev/null)"

# Legacy Council rows without a lifecycle ID use the persisted violation
# sequence as their dedupe identity. Oversized decimal text must fail closed
# before Bash arithmetic can wrap it into a reused event ID.
legacy_seq_session_id="zc-custom-legacy-seq-$$"
legacy_seq_state_dir="${zc_session_root}/${legacy_seq_session_id}"
legacy_seq_value="999999999999999999999999999999999999"
mkdir -p "${legacy_seq_state_dir}"
jq -nc --arg seq "${legacy_seq_value}" '{
  workflow_mode:"ultrawork",last_user_prompt_ts:"100",
  review_cycle_prompt_ts:"100",prompt_revision:"1",review_cycle_id:"1",
  scope_contract_violation_seq:$seq
}' >"${legacy_seq_state_dir}/session_state.json"
printf '%s\n' \
  '{"objective_prompt_ts":100,"objective_prompt_revision":1,"objective_cycle_id":1}' \
  >"${legacy_seq_state_dir}/council_coverage.json"
jq -nc '{
  ts:3,agent_type:"custom-trust-auditor",
  description:"[council:primary] legacy trust audit",
  edit_revision:0,code_revision:0,doc_revision:0,bash_revision:0,
  ui_revision:0,plan_revision:0,review_revision:0,
  objective_prompt_ts:100,objective_prompt_revision:1,objective_cycle_id:1,
  ulw_enforcement_generation:"migration",purpose:"council",
  council_phase:"primary",council_selection_agent:"custom-trust-auditor",
  council_objective_prompt_ts:100,council_objective_prompt_revision:1,
  council_ledger_generation:1
}' >"${legacy_seq_state_dir}/pending_agents.jsonl"
legacy_seq_payload="$(jq -nc \
  --arg sid "${legacy_seq_session_id}" --arg msg "${custom_missing}" '
    {session_id:$sid,agent_type:"custom-trust-auditor",
     message:$msg,last_assistant_message:$msg}
  ')"
legacy_seq_rc=0
OMC_DISCOVERED_SCOPE=on \
SESSION_ID="${legacy_seq_session_id}" \
STATE_ROOT="${zc_session_root}" \
HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${legacy_seq_payload}" >/dev/null 2>&1 || legacy_seq_rc=$?
assert_eq "oversized legacy sequence fails the summary publication" "1" \
  "$([[ "${legacy_seq_rc}" -ne 0 ]] && printf 1 || printf 0)"
assert_eq "oversized legacy sequence remains unchanged" \
  "${legacy_seq_value}" \
  "$(jq -r '.scope_contract_violation_seq' \
    "${legacy_seq_state_dir}/session_state.json")"
assert_eq "oversized legacy sequence cannot mint an aliased placeholder" "0" \
  "$([[ -f "${legacy_seq_state_dir}/discovered_scope.jsonl" ]] \
    && wc -l <"${legacy_seq_state_dir}/discovered_scope.jsonl" \
      | tr -d ' ' || printf 0)"
assert_eq "oversized legacy sequence publishes no parent outcome" "0" \
  "$([[ -f "${legacy_seq_state_dir}/agent_completion_outcomes.jsonl" ]] \
    && wc -l <"${legacy_seq_state_dir}/agent_completion_outcomes.jsonl" \
      | tr -d ' ' || printf 0)"

# Last authoritative verdict wins and fenced examples do not arm the contract.
custom_clean_session_id="zc-custom-clean-$$"
custom_clean_state_dir="${zc_session_root}/${custom_clean_session_id}"
mkdir -p "${custom_clean_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${custom_clean_state_dir}/session_state.json"
seed_current_custom_council_dispatch "${custom_clean_state_dir}" 1
custom_clean=$'Earlier draft:\n```text\nVERDICT: FINDINGS (2)\n```\nVERDICT: FINDINGS (1)\nEvidence resolved on recheck.\nVERDICT: CLEAN'
custom_clean_payload="$(jq -nc --arg sid "${custom_clean_session_id}" \
  --arg native "${custom_council_native_id}" --arg msg "${custom_clean}" \
  '{session_id:$sid,agent_type:"custom-trust-auditor",agent_id:$native,
    message:$msg,last_assistant_message:$msg}')"
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_clean_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_clean_payload}" >/dev/null 2>&1 || true
assert_eq "final CLEAN suppresses earlier/example findings placeholder" "0" \
  "$([[ -f "${custom_clean_state_dir}/discovered_scope.jsonl" ]] && wc -l < "${custom_clean_state_dir}/discovered_scope.jsonl" | tr -d ' ' || printf 0)"

# Untagged/manual agents were never given Council's structured contract.
custom_manual_session_id="zc-custom-manual-$$"
custom_manual_state_dir="${zc_session_root}/${custom_manual_session_id}"
mkdir -p "${custom_manual_state_dir}"
printf '{"workflow_mode":"ultrawork"}\n' > "${custom_manual_state_dir}/session_state.json"
custom_manual_payload="$(jq -nc --arg sid "${custom_manual_session_id}" --arg msg "${custom_missing}" \
  '{session_id:$sid,agent_type:"custom-trust-auditor",message:$msg,last_assistant_message:$msg}')"
OMC_DISCOVERED_SCOPE=on SESSION_ID="${custom_manual_session_id}" STATE_ROOT="${zc_session_root}" HOME="${zc_session_root}" \
bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-subagent-summary.sh" \
  <<<"${custom_manual_payload}" >/dev/null 2>&1 || true
assert_eq "manual custom findings verdict without Council tag does not hard-block" "0" \
  "$([[ -f "${custom_manual_state_dir}/discovered_scope.jsonl" ]] && wc -l < "${custom_manual_state_dir}/discovered_scope.jsonl" | tr -d ' ' || printf 0)"

rm -rf "${zc_session_root}"

printf '\n=== Discovered-Scope Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
