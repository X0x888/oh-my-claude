#!/usr/bin/env bash
# Focused tests for show-report.sh — the /ulw-report skill backend.
#
# Validates: argument parsing, exit codes, empty-state rendering, populated
# rendering with synthesized cross-session aggregates, and window selection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"

pass=0
fail=0

# Sandbox HOME so the script reads from a synthesized quality-pack dir.
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "${TEST_HOME}"' EXIT
mkdir -p "${TEST_HOME}/.claude/quality-pack"
QP="${TEST_HOME}/.claude/quality-pack"

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
    printf '  FAIL: %s — needle %q not in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

run_report() {
  HOME="${TEST_HOME}" bash "${SHOW_REPORT}" "$@" 2>&1
}

# ----------------------------------------------------------------------
printf 'Test 1: --help prints usage and exits 0\n'
out="$(run_report --help)"
rc=$?
assert_eq "help exit code" "0" "${rc}"
assert_contains "help mentions modes" "last|week|month|all" "${out}"

# ----------------------------------------------------------------------
printf 'Test 2: unknown mode exits 2\n'
set +e
out="$(run_report bogus 2>&1)"
rc=$?
set -e
assert_eq "unknown-mode exit code" "2" "${rc}"
assert_contains "unknown-mode message" "unknown mode" "${out}"

# ----------------------------------------------------------------------
printf 'Test 3: empty quality-pack renders empty-state messages and exits 0\n'
out="$(run_report week)"
rc=$?
assert_eq "empty-state exit code" "0" "${rc}"
assert_contains "header window label" "last 7 days" "${out}"
assert_contains "no sessions message" "No session_summary rows" "${out}"
assert_contains "no serendipity message" "No Serendipity Rule applications" "${out}"
assert_contains "no archetypes message" "No design archetypes recorded" "${out}"
assert_contains "no misfires message" "No classifier misfires" "${out}"
assert_contains "no reviewer message" "No reviewer activity" "${out}"
assert_contains "no defects message" "No defect patterns" "${out}"

# ----------------------------------------------------------------------
printf 'Test 4: populated session_summary renders summary table\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":12,"verified":true,"reviewed":true,"guard_blocks":2,"dim_blocks":1,"exhausted":false,"dispatches":4,"outcome":"shipped","skip_count":0,"serendipity_count":1,"findings":{"total":5,"shipped":3,"deferred":1,"rejected":0,"in_progress":0,"pending":1},"waves":{"total":2,"completed":1}}
{"session_id":"s2","start_ts":$((NOW - 3600)),"end_ts":$((NOW - 1800)),"domain":"writing","intent":"execution","edit_count":3,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":1,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "renders sessions count" "| Sessions | 2 |" "${out}"
assert_contains "sums edits" "| Files edited | 15 |" "${out}"
assert_contains "sums blocks" "| Quality-gate blocks fired | 3 |" "${out}"
assert_contains "sums skips" "| Skips honored | 1 |" "${out}"
assert_contains "sums serendipity" "| Serendipity Rule applications | 1 |" "${out}"
assert_contains "findings table appears" "Findings tracked | 5" "${out}"
assert_contains "shipped findings" "Shipped | 3" "${out}"

# ----------------------------------------------------------------------
printf 'Test 5: last mode selects only the most recent row\n'
out="$(run_report last)"
assert_contains "last mode header" "most recent session" "${out}"
assert_contains "last mode shows 1 session" "| Sessions | 1 |" "${out}"

# ----------------------------------------------------------------------
printf 'Test 6: window filter excludes rows older than cutoff\n'
# Add a row from 60 days ago — should appear in "all" but not in "month" or "week"
cat >> "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s_old","start_ts":$((NOW - 60 * 86400)),"end_ts":$((NOW - 60 * 86400)),"domain":"coding","intent":"execution","edit_count":99,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out_week="$(run_report week)"
out_month="$(run_report month)"
out_all="$(run_report all)"
assert_contains "week excludes old row (edit count 15)" "Files edited | 15" "${out_week}"
assert_contains "month also excludes old row" "Files edited | 15" "${out_month}"
assert_contains "all includes old row (edit count 114)" "Files edited | 114" "${out_all}"

# ----------------------------------------------------------------------
printf 'Test 7: serendipity rendering with multiple rows\n'
cat > "${QP}/serendipity-log.jsonl" <<EOF
{"ts":"${NOW}","session":"s1","fix":"Fix typo in comment","original_task":"Wave 4 docs","conditions":"verified|same-path|bounded","commit":""}
{"ts":"$((NOW - 7200))","session":"s2","fix":"Repair stale lint rule","original_task":"Wave 1 reliability","conditions":"verified|same-path|bounded","commit":"abc1234"}
EOF
out="$(run_report week)"
assert_contains "serendipity count" "2 catches" "${out}"
assert_contains "serendipity fix line" "Fix typo in comment" "${out}"

# ----------------------------------------------------------------------
printf 'Test 7b: archetype variation aggregation\n'
cat > "${QP}/used-archetypes.jsonl" <<EOF
{"ts":"${NOW}","session":"s1","project_key":"pk_alpha","archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}
{"ts":"$((NOW - 1000))","session":"s1","project_key":"pk_alpha","archetype":"Linear","platform":"web","domain":"devtool","agent":"frontend-developer"}
{"ts":"$((NOW - 2000))","session":"s2","project_key":"pk_beta","archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}
EOF
out="$(run_report week)"
assert_contains "archetype emission count" "3 archetype emissions" "${out}"
assert_contains "archetype unique count" "2 unique archetypes" "${out}"
assert_contains "archetype project count" "2 projects" "${out}"
assert_contains "archetype histogram entry: Stripe x2" "\`Stripe\` × 2" "${out}"
assert_contains "archetype histogram entry: Linear x1" "\`Linear\` × 1" "${out}"

# ----------------------------------------------------------------------
printf 'Test 8: classifier misfires aggregation\n'
cat > "${QP}/classifier_misfires.jsonl" <<EOF
{"misfire":true,"ts":"${NOW}","prior_intent":"advisory","reason":"prior_non_execution_plus_pretool_block","pretool_blocks_in_window":1}
{"misfire":true,"ts":"${NOW}","prior_intent":"advisory","reason":"prior_non_execution_plus_pretool_block","pretool_blocks_in_window":2}
{"misfire":true,"ts":"${NOW}","prior_intent":"checkpoint","reason":"prior_non_execution_plus_affirmation_and_pretool_block","pretool_blocks_in_window":1}
EOF
out="$(run_report week)"
assert_contains "misfire count surfaced" "3 misfire rows" "${out}"
assert_contains "top reason listed" "prior_non_execution_plus_pretool_block" "${out}"

# ----------------------------------------------------------------------
printf 'Test 9: agent-metrics reviewer table\n'
cat > "${QP}/agent-metrics.json" <<EOF
{
  "agents": {
    "quality-reviewer": {"invocations": 12, "clean_verdicts": 8, "finding_verdicts": 4, "avg_confidence": 0.85},
    "excellence-reviewer": {"invocations": 6, "clean_verdicts": 4, "finding_verdicts": 2, "avg_confidence": 0.78}
  }
}
EOF
out="$(run_report week)"
assert_contains "reviewer table header" "Reviewer | Invocations" "${out}"
assert_contains "quality-reviewer row" "quality-reviewer" "${out}"
assert_contains "find rate computed" "33%" "${out}"  # 4/12 = 33

# ----------------------------------------------------------------------
printf 'Test 10: defect patterns histogram\n'
cat > "${QP}/defect-patterns.json" <<EOF
{
  "patterns": {
    "missing_test": {"count": 12},
    "race_condition": {"count": 3},
    "unknown": {"count": 5}
  }
}
EOF
out="$(run_report week)"
assert_contains "defect histogram present" "missing_test" "${out}"
assert_contains "defect count" "× 12" "${out}"

# ----------------------------------------------------------------------
printf 'Test 11: empty dataset renders the v1.17.0 "no patterns" line\n'
# Wipe the test fixtures so the report runs against a clean quality-pack;
# heuristics should report cleanly with no warnings.
rm -rf "${QP}"/*
out="$(run_report week)"
assert_contains "interpretation header present" "Patterns to consider" "${out}"
assert_contains "clean-state interpretation copy" "No clear patterns to call out" "${out}"
# Sanity: heuristic warnings must not appear on an empty dataset.
if [[ "${out}" == *"High gate-fire density"* ]]; then
  printf '  FAIL: empty dataset triggered high-gate heuristic\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 12: high-gate-density heuristic fires when blocks/session ≥ 2.1\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":3,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
{"session_id":"s2","start_ts":$((NOW - 1800)),"end_ts":$((NOW - 900)),"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":3,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "high gate-fire density heuristic fires" "High gate-fire density" "${out}"

# ----------------------------------------------------------------------
printf 'Test 13: skip-rate heuristic fires when skips/blocks >= 40%%\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":2,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":1,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "high skip-rate heuristic fires" "High skip rate" "${out}"

# ----------------------------------------------------------------------
printf 'Test 14: serendipity heuristic fires whenever count > 0\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":2}
EOF
out="$(run_report week)"
assert_contains "serendipity heuristic fires" "Serendipity caught 2 adjacent" "${out}"

# ----------------------------------------------------------------------
printf 'Test 15: archetype convergence heuristic fires when one arch ≥ 3 and unique < 4\n'
NOW="$(date +%s)"
rm -f "${QP}/session_summary.jsonl"
cat > "${QP}/used-archetypes.jsonl" <<EOF
{"ts":"${NOW}","session":"s1","project_key":"abc","archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}
{"ts":"${NOW}","session":"s2","project_key":"abc","archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}
{"ts":"${NOW}","session":"s3","project_key":"abc","archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}
{"ts":"${NOW}","session":"s4","project_key":"abc","archetype":"Linear","platform":"web","domain":"devtool","agent":"frontend-developer"}
EOF
out="$(run_report week)"
assert_contains "archetype convergence heuristic fires" "Archetype convergence" "${out}"

# ----------------------------------------------------------------------
printf 'Test 16: heuristics suppress when thresholds NOT met\n'
NOW="$(date +%s)"
rm -f "${QP}/used-archetypes.jsonl"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
{"session_id":"s2","start_ts":$((NOW - 1800)),"end_ts":$((NOW - 900)),"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# 2 blocks across 2 sessions = 1.0/session, below the 2.1 threshold.
if [[ "${out}" == *"High gate-fire density"* ]]; then
  printf '  FAIL: heuristic mis-fired on 1.0 blocks/session\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# No skips, no serendipity, no archetypes → none of those heuristics either.
assert_contains "clean line surfaces when nothing trips" "No clear patterns to call out" "${out}"

# ----------------------------------------------------------------------
printf 'Test 17: v1.18.0 — user-decision-marked events visible in totals\n'
# Reviewer-found gap: the new user-decision-marked event was filtered
# out by show-report.sh's status-change selector. Synthesize the
# cross-session gate_events.jsonl that show-report reads and assert
# user-decision marks are counted in the per-gate row + totals.
rm -f "${QP}/session_summary.jsonl"
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-ud-session","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-001","finding_status":"shipped","commit_sha":"abc"}}
{"ts":${NOW},"session":"test-ud-session","gate":"finding-status","event":"user-decision-marked","details":{"finding_id":"F-002","decision_reason":"brand voice"}}
{"ts":${NOW},"session":"test-ud-session","gate":"finding-status","event":"user-decision-marked","details":{"finding_id":"F-003","decision_reason":"pricing"}}
{"ts":${NOW},"session":"test-ud-session","gate":"wave-status","event":"wave-status-change","details":{"wave_idx":1,"wave_status":"completed"}}
EOF
# Need a session_summary entry so show-report does not bail to empty-state
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-ud-session","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# Per-gate count column for finding-status: 1 status-change + 2 user-decision = 3 events
assert_contains "show-report: per-gate finding-status count includes user-decision marks" \
  "| \`finding-status\` | 0 | 3 |" "${out}"
# Totals line: 4 status changes (3 finding-status + 1 wave-status), 2 user-decision marks
assert_contains "show-report: totals line includes user-decision marks suffix" \
  "2 user-decision marks" "${out}"
assert_contains "show-report: totals report 4 status changes" \
  "4 status changes" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf '\n=== Show-Report Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
