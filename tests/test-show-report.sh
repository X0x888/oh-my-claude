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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — unexpected needle %q found in output\n' "${label}" "${needle}" >&2
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

# Exercise the real writer -> report reader contract. This caught the v2
# regression where record_agent_metric wrote flat keys while show-report
# only inspected `.agents` and therefore claimed there was no activity.
printf 'Test 9b: record_agent_metric output is visible to report reader\n'
rm -f "${QP}/agent-metrics.json"
HOME="${TEST_HOME}" \
STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
SESSION_ID="metrics-integration" \
bash -c 'set -euo pipefail; mkdir -p "${STATE_ROOT}/${SESSION_ID}"; . "$1"; record_agent_metric "writer-reader-reviewer" "findings"' \
  _ "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
out="$(run_report week)"
assert_contains "writer-reader reviewer row" "writer-reader-reviewer" "${out}"
assert_contains "writer-reader find rate" "100%" "${out}"

printf 'Test 9c: stale-review waste and role/model token economics\n'
cat > "${QP}/timing.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"economics-s1","project_key":"p","walltime_s":2,"prompt_count":1,"stale_reviewer_count":2,"tokens_agent_in":100,"tokens_agent_out":200,"tokens_agent_cache_read":300,"tokens_agent_cache_creation":400,"agent_tokens_by_role":{"quality-reviewer":{"input":100,"output":200,"cache_read":300,"cache_creation":400}},"agent_tokens_by_model":{"claude-sonnet-test":{"input":100,"output":200,"cache_read":300,"cache_creation":400}},"agent_tokens_by_id":{"native-1":{"input":100,"output":200,"cache_read":300,"cache_creation":400}}}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"economics-s1","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"native-1"}}
{"_v":1,"ts":${NOW},"gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard"}}
{"_v":1,"ts":${NOW},"gate":"review-mutation-freeze","event":"block","details":{"reviewers":"quality-reviewer"}}
EOF
out="$(run_report week)"
assert_contains "stale review run surfaced" "Wasted review runs rejected as stale: **2**" "${out}"
assert_contains "mutation freeze avoided retry surfaced" "Mutations blocked while reviewers were in flight: **1**" "${out}"
assert_contains "native stale review tokens are exact" "Exact wasted reviewer tokens: **1.0K** across **1** native-bound stale run" "${out}"
assert_contains "legacy stale review count remains explicit" "**1** legacy/unbound stale run" "${out}"
assert_contains "waste token upper bound labelled" "upper bound; includes successful runs" "${out}"
assert_contains "role token breakdown surfaced" "Sub-agent role breakdown" "${out}"
assert_contains "model token breakdown surfaced" "claude-sonnet-test" "${out}"

printf 'Test 9d: last mode aligns summary, gate-event, and timing session windows\n'
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"old-s","start_ts":$((NOW - 100)),"end_ts":$((NOW - 90)),"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
{"session_id":"latest-s","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":2,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${QP}/timing.jsonl" <<EOF
{"_v":1,"ts":$((NOW - 100)),"session_id":"old-s","stale_reviewer_count":7,"agent_tokens_by_id":{"old":{"output":7000}}}
{"_v":1,"ts":${NOW},"session_id":"latest-s","stale_reviewer_count":2,"agent_tokens_by_id":{"n1":{"output":1000},"n2":{"output":2000}}}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":$((NOW - 100)),"session_id":"old-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"old"}}
{"_v":1,"ts":${NOW},"session_id":"latest-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"n1"}}
{"_v":1,"ts":${NOW},"session_id":"latest-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"n2"}}
EOF
out="$(run_report last)"
assert_contains "last economics uses latest session stale count" \
  "Wasted review runs rejected as stale: **2**" "${out}"
assert_contains "last economics joins every latest-session native run" \
  "Exact wasted reviewer tokens: **3.0K** across **2** native-bound stale run" "${out}"
assert_not_contains "last economics excludes old timing total" \
  "Wasted review runs rejected as stale: **7**" "${out}"
assert_not_contains "last economics does not invent a legacy run" \
  "legacy/unbound stale run" "${out}"

printf 'Test 9e: merge includes external timing ledger for exact joins\n'
: > "${QP}/timing.jsonl"
: > "${QP}/gate_events.jsonl"
EXT_ECON="${TEST_HOME}/economics-external"
mkdir -p "${EXT_ECON}"
cat > "${EXT_ECON}/session_summary.jsonl" <<EOF
{"session_id":"ext-s","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${EXT_ECON}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"ext-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"ext-a"}}
EOF
cat > "${EXT_ECON}/timing.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"ext-s","walltime_s":42,"prompt_count":1,"stale_reviewer_count":1,"agent_tokens_by_id":{"ext-a":{"input":100,"output":200,"cache_read":300,"cache_creation":400}}}
EOF
_ext_timing_before="$(cat "${EXT_ECON}/timing.jsonl")"
out="$(run_report all --merge "${EXT_ECON}")"
assert_contains "merged stale run counted" "Wasted review runs rejected as stale: **1**" "${out}"
assert_contains "merged timing joins exact native tokens" \
  "Exact wasted reviewer tokens: **1.0K** across **1** native-bound stale run" "${out}"
assert_not_contains "merged timing is not reported unavailable" \
  "exact token telemetry was unavailable" "${out}"
assert_contains "merged timing powers the cross-session time panel" \
  "Window: 1 sessions · 1 prompts · 42s walltime" "${out}"
assert_not_contains "merged timing is not contradicted by local-only empty state" \
  "No cross-session timing rows yet" "${out}"
assert_eq "merged external timing source remains read-only" \
  "${_ext_timing_before}" "$(cat "${EXT_ECON}/timing.jsonl")"
rm -rf "${EXT_ECON}"

printf 'Test 9f: stale gate events survive missing timing telemetry\n'
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"missing-s","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":2,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"missing-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"missing-a"}}
{"_v":1,"ts":${NOW},"session_id":"missing-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard"}}
EOF
rm -f "${QP}/timing.jsonl"
out="$(run_report week)"
assert_contains "missing timing does not hide stale run count" \
  "Wasted review runs rejected as stale: **2**" "${out}"
assert_contains "missing native timing is explicit" \
  "Native-bound stale runs: **1**; exact token telemetry was unavailable" "${out}"
assert_contains "missing timing preserves legacy run count" \
  "**1** legacy/unbound stale run" "${out}"

printf 'Test 9g: partial native timing coverage is never overstated\n'
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"missing-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"n1"}}
{"_v":1,"ts":${NOW},"session_id":"missing-s","gate":"reviewer","event":"stale-result-rejected","details":{"type":"standard","agent_id":"n2"}}
EOF
cat > "${QP}/timing.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"missing-s","stale_reviewer_count":2,"agent_tokens_by_id":{"n1":{"input":100,"output":200,"cache_read":300,"cache_creation":400}}}
EOF
out="$(run_report week)"
assert_contains "partial coverage reports exact matched run only" \
  "Exact wasted reviewer tokens: **1.0K** across **1** native-bound stale run" "${out}"
assert_contains "partial coverage reports unmatched native run" \
  "Native-bound stale runs: **1**; exact token telemetry was unavailable" "${out}"
assert_not_contains "partial coverage never claims both runs exact" \
  "Exact wasted reviewer tokens: **1.0K** across **2**" "${out}"

# Key presence, not a positive token sum, defines telemetry availability.
cat > "${QP}/timing.jsonl" <<EOF
{"_v":1,"ts":${NOW},"session_id":"missing-s","stale_reviewer_count":2,"agent_tokens_by_id":{"n1":{"input":100,"output":200,"cache_read":300,"cache_creation":400},"n2":{"input":0,"output":0,"cache_read":0,"cache_creation":0}}}
EOF
out="$(run_report week)"
assert_contains "zero-token bucket still counts as exact telemetry" \
  "Exact wasted reviewer tokens: **1.0K** across **2** native-bound stale run" "${out}"
assert_not_contains "zero-token bucket is not called unavailable" \
  "exact token telemetry was unavailable" "${out}"

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
rm -rf "${QP:?}"/*
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
# Per-gate count column for finding-status: 0 blocks, 0 wave_override,
# 1 status-change + 2 user-decision = 3 events. The "Overrides" column
# was added in v1.21.0 between Blocks and Status changes to surface
# `wave_override` events from the pretool-intent-guard wave-active
# exception; non-pretool gates always show 0 in that column.
assert_contains "show-report: per-gate finding-status count includes user-decision marks" \
  "| \`finding-status\` | 0 | 0 | 3 |" "${out}"
# Totals line: 4 status changes (3 finding-status + 1 wave-status), 2 user-decision marks
assert_contains "show-report: totals line includes user-decision marks suffix" \
  "2 user-decision marks" "${out}"
assert_contains "show-report: totals report 4 status changes" \
  "4 status changes" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 18: v1.21.0 — wave_override events surface in per-gate Overrides column + totals line\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-wo-session","gate":"pretool-intent","event":"block","details":{"intent":"advisory"}}
{"ts":${NOW},"session":"test-wo-session","gate":"pretool-intent","event":"wave_override","details":{"intent":"advisory","denied_segment":"git commit -m wave"}}
{"ts":${NOW},"session":"test-wo-session","gate":"pretool-intent","event":"wave_override","details":{"intent":"session_management","denied_segment":"git commit"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-wo-session","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# Per-gate row for pretool-intent: 1 block, 2 wave_override, 0 status-changes
assert_contains "show-report: per-gate pretool-intent row includes wave_override count" \
  "| \`pretool-intent\` | 1 | 2 | 0 |" "${out}"
# Totals line includes the override count
assert_contains "show-report: totals line surfaces wave-override allow(s)" \
  "2 wave-override allow" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 19: v1.23.0 — prompt_text_override events surface in Overrides column + totals breakdown\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-pt-session","gate":"pretool-intent","event":"block","details":{"intent":"advisory"}}
{"ts":${NOW},"session":"test-pt-session","gate":"pretool-intent","event":"prompt_text_override","details":{"intent":"advisory","denied_segment":"git commit -m wave","prompt_preview":"Implement and commit as needed"}}
{"ts":${NOW},"session":"test-pt-session","gate":"pretool-intent","event":"prompt_text_override","details":{"intent":"advisory","denied_segment":"git push origin","prompt_preview":"push when stable"}}
{"ts":${NOW},"session":"test-pt-session","gate":"pretool-intent","event":"wave_override","details":{"intent":"advisory","denied_segment":"git commit -m wave2"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-pt-session","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# Per-gate row counts BOTH wave_override (1) + prompt_text_override (2) in Overrides column
assert_contains "show-report: per-gate pretool-intent row counts prompt_text_override + wave_override" \
  "| \`pretool-intent\` | 1 | 3 | 0 |" "${out}"
# Totals line breaks down the 3 overrides into wave/prompt-text components
assert_contains "show-report: totals line breaks out wave + prompt-text override counts" \
  "1 wave / 2 prompt-text" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 20: v1.23.0 — bias-defense directive_fired events surface in their own section\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-bd-session","gate":"bias-defense","event":"directive_fired","details":{"directive":"exemplifying"}}
{"ts":${NOW},"session":"test-bd-session","gate":"bias-defense","event":"directive_fired","details":{"directive":"exemplifying"}}
{"ts":${NOW},"session":"test-bd-session","gate":"bias-defense","event":"directive_fired","details":{"directive":"prometheus-suggest"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-bd-session","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# Bias-defense directive section header is present
assert_contains "show-report: bias-defense directives section is rendered" \
  "## Bias-defense directives fired" "${out}"
# Exemplifying directive shows count 2
assert_contains "show-report: exemplifying directive fire-count rendered" \
  "| \`exemplifying\` | 2 |" "${out}"
# prometheus-suggest fire-count rendered
assert_contains "show-report: prometheus-suggest fire-count rendered" \
  "| \`prometheus-suggest\` | 1 |" "${out}"
# intent-verify (zero fires) is NOT rendered (only non-zero entries)
if [[ "${out}" == *"intent-verify"* ]]; then
  printf '  FAIL: zero-count directive should be suppressed but found\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 21: v1.23.0 — bias-defense section shows placeholder when no fires\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-empty-bd","gate":"pretool-intent","event":"block","details":{"intent":"advisory"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-empty-bd","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "show-report: bias-defense placeholder when no fires" \
  "No bias-defense directives fired" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 21b: directive footprint section renders chars and fire counts from timing rollup\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-directive-footprint","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${QP}/timing.jsonl" <<EOF
{"ts":${NOW},"session_id":"test-directive-footprint","project_key":"p1","walltime_s":90,"agent_total_s":30,"tool_total_s":20,"idle_model_s":40,"agent_breakdown":{"quality-reviewer":30},"tool_breakdown":{"Bash":20},"directive_total_chars":420,"directive_count":4,"directive_breakdown":{"domain_routing":180,"ui_design_contract":160,"intent_classification":80},"directive_counts":{"domain_routing":1,"ui_design_contract":1,"intent_classification":2},"prompt_count":1}
EOF
out="$(run_report week)"
assert_contains "show-report: directive footprint header rendered" \
  "## Router directive footprint" "${out}"
assert_contains "show-report: directive footprint total line rendered" \
  "Window total: 4 directive fires, 420 chars" "${out}"
assert_contains "show-report: ui_design_contract row rendered" \
  "| \`ui_design_contract\` | 1 | 160 | 160 |" "${out}"
assert_contains "show-report: intent_classification avg chars rendered" \
  "| \`intent_classification\` | 2 | 80 | 40 |" "${out}"
rm -f "${QP}/timing.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 21b.1: imported timing labels are terminal- and Markdown-safe\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-hostile-timing-labels","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${QP}/timing.jsonl" <<EOF
{"ts":${NOW},"session_id":"test-hostile-timing-labels","walltime_s":9,"agent_total_s":8,"tool_total_s":7,"idle_model_s":2,"agent_breakdown":{"agent\u0007|\u0060bad":4,"agent\n0\trow1\n0\trow2":4},"tool_breakdown":{"tool\u001b]8;;x\u0007|\u0060bad":3,"tool\n0\trow1\n0\trow2":4},"directive_total_chars":9,"directive_count":1,"directive_breakdown":{"directive\u001b[31m|\u0060bad":9},"directive_counts":{"directive\u001b[31m|\u0060bad":1},"prompt_count":1}
EOF
out="$(run_report all)"
assert_contains "show-report: imported directive label is Markdown-safe" \
  '| `directive[31m__bad` | 1 | 9 | 9 |' "${out}"
assert_contains "show-report: imported agent label is Markdown-safe" \
  '- `agent__bad` — 4s' "${out}"
assert_contains "show-report: imported tool label is Markdown-safe" \
  '- `tool]8;;x__bad` — 3s' "${out}"
assert_contains "show-report: newline agent key stays one sanitized row" \
  '- `agent_n0_trow1_n0_trow2` — 4s' "${out}"
assert_contains "show-report: newline tool key stays one sanitized row" \
  '- `tool_n0_trow1_n0_trow2` — 4s' "${out}"
assert_not_contains "show-report: newline key cannot inject a numeric row" \
  $'- `row1` — 0s' "${out}"
if printf '%s' "${out}" | LC_ALL=C grep -q $'\x1b'; then
  printf '  FAIL: imported timing label emitted a terminal escape byte\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if printf '%s' "${out}" | LC_ALL=C grep -q $'\a'; then
  printf '  FAIL: imported timing label emitted a bell byte\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/timing.jsonl" "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 21c: directive-budget suppressions surface in their own section\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-directive-budget","gate":"directive-budget","event":"suppressed","details":{"directive":"defect_watch","reason":"soft_count_cap","mode":"balanced"}}
{"ts":${NOW},"session":"test-directive-budget","gate":"directive-budget","event":"suppressed","details":{"directive":"defect_watch","reason":"soft_count_cap","mode":"balanced"}}
{"ts":${NOW},"session":"test-directive-budget","gate":"directive-budget","event":"suppressed","details":{"directive":"bias_defense_divergent_framing","reason":"soft_char_budget","mode":"minimal"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-directive-budget","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "show-report: directive-budget section header rendered" \
  "## Router directive suppressions" "${out}"
assert_contains "show-report: directive-budget total line rendered" \
  "Window total: 3 suppressed directive(s)." "${out}"
assert_contains "show-report: grouped defect_watch suppression rendered" \
  "| \`defect_watch\` | \`soft_count_cap\` | 2 |" "${out}"
assert_contains "show-report: grouped divergence suppression rendered" \
  "| \`bias_defense_divergent_framing\` | \`soft_char_budget\` | 1 |" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 22: mark-deferred strict-bypass events surface in their own section\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-md-session","gate":"mark-deferred","event":"strict-bypass","details":{"reason":"out of scope"}}
{"ts":${NOW},"session":"test-md-session","gate":"mark-deferred","event":"strict-bypass","details":{"reason":"low priority"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-md-session","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "show-report: mark-deferred bypasses section header" \
  "## Mark-deferred strict-bypasses" "${out}"
assert_contains "show-report: bypass count rendered" \
  "2 reason(s) bypassed the require-WHY validator" "${out}"
assert_contains "show-report: 'out of scope' reason captured" \
  "out of scope" "${out}"
assert_contains "show-report: 'low priority' reason captured" \
  "low priority" "${out}"
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 23: mark-deferred bypasses section is HIDDEN when no bypasses recorded\n'
# The new section is conditional — clean sessions hide it entirely so
# reports stay terse. Verify a session with no strict-bypass rows does
# not render the section header (unlike bias-defense which always shows
# either the table or a placeholder).
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-clean","gate":"pretool-intent","event":"block","details":{"intent":"advisory"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-clean","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
case "${out}" in
  *"Mark-deferred strict-bypasses"*)
    printf '  FAIL: T23: section should be hidden but rendered\n' >&2
    fail=$((fail + 1)) ;;
  *)
    pass=$((pass + 1)) ;;
esac
rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# T24: v1.31.0 Wave 8 — --share emits privacy-safe markdown (no free-text
# leak). Per metis Item 4: "fixture with sensitive prompts → --share
# output → grep for the sensitive substring → assert absent." Load-bearing
# privacy test for the share-card surface.
# ----------------------------------------------------------------------
NOW="$(date +%s)"
SECRET_PROMPT="DELETE FROM users WHERE id=42 -- REDACT-CANARY-PROMPT"
SECRET_REASON="connection string postgres://admin:hunter2@db:5432/prod -- REDACT-CANARY-REASON"
SECRET_FIX="patched the SQL injection at api.py:42 -- REDACT-CANARY-FIX"

cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-share","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"last_user_prompt":"${SECRET_PROMPT}","verified":true,"reviewed":true,"guard_blocks":2,"dim_blocks":3,"exhausted":false,"dispatches":4,"outcome":"shipped","skip_count":0,"serendipity_count":1}
EOF

cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-share","gate":"discovered_scope","event":"block","details":{"reason":"${SECRET_REASON}","prompt_preview":"${SECRET_PROMPT}"}}
{"ts":${NOW},"session":"test-share","gate":"pretool-intent","event":"block","details":{"command":"git push --force","intent":"advisory"}}
EOF

cat > "${QP}/serendipity-log.jsonl" <<EOF
{"ts":${NOW},"session_id":"test-share","fix":"${SECRET_FIX}","original_task":"feature work","conditions":"verified|same-path|bounded","commit":"deadbeef"}
EOF

share_out="$(HOME="${TEST_HOME}" bash "${SHOW_REPORT}" --share week 2>&1 || true)"

# Assert the share output renders structural data.
case "${share_out}" in
  *"oh-my-claude"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T24: --share missing oh-my-claude header\n' >&2; fail=$((fail + 1)) ;;
esac
case "${share_out}" in
  *"Sessions:"*) pass=$((pass + 1)) ;;
  *) printf '  FAIL: T24: --share missing Sessions count\n' >&2; fail=$((fail + 1)) ;;
esac
# v1.31.2 quality-reviewer F-1: --share Quality-gate-blocks count must
# include BOTH guard_blocks AND dim_blocks. Fixture has guard=2 + dim=3
# = 5. Pre-fix the share output reported 2; the fix sums both.
case "${share_out}" in
  *"Quality-gate blocks (caught issues):** 5"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: T24 (F-1 fix): --share blocks should sum guard+dim (=5), got:\n%s\n' "${share_out}" >&2
    fail=$((fail + 1)) ;;
esac

# CRITICAL: assert NONE of the secrets leak into the share output.
case "${share_out}" in
  *"REDACT-CANARY-PROMPT"*)
    printf '  FAIL: T24: prompt text LEAKED into --share output\n%s\n' "${share_out}" >&2
    fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
case "${share_out}" in
  *"REDACT-CANARY-REASON"*)
    printf '  FAIL: T24: gate-event reason LEAKED into --share output\n%s\n' "${share_out}" >&2
    fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
case "${share_out}" in
  *"REDACT-CANARY-FIX"*)
    printf '  FAIL: T24: serendipity fix text LEAKED into --share output\n%s\n' "${share_out}" >&2
    fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac
case "${share_out}" in
  *"hunter2"*)
    printf '  FAIL: T24: password-shaped string LEAKED into --share output\n' >&2
    fail=$((fail + 1)) ;;
  *) pass=$((pass + 1)) ;;
esac

rm -f "${QP}/gate_events.jsonl"
rm -f "${QP}/session_summary.jsonl"
rm -f "${QP}/serendipity-log.jsonl"

# ----------------------------------------------------------------------
# T25: A3 ANSI-escape neutralization in Serendipity render (4-attacker
# security review).
#
# Plant a serendipity-log row whose .fix field carries a JSON-encoded
# ANSI clear-screen + attacker text. After jq -r decodes, the bytes
# would normally render to the user's tty. The render path now pipes
# through `_omc_strip_render_unsafe` (tr) so ESC (0x1b) is removed.
# We verify the report DOES NOT contain a literal 0x1b byte.
printf 'T25: A3 ANSI-escape stripped from Serendipity render\n'
# Encode `` (ESC) inside the .fix JSON value — this is what a
# hostile model would emit through `record-serendipity.sh --arg fix`.
printf '{"ts":%s,"fix":"safe-prefix\\u001b[2J\\u001b[Hattacker-content","original_task":"x","conditions":"verified|same-path|bounded","commit":""}\n' \
  "$(date +%s)" > "${QP}/serendipity-log.jsonl"
out_25="$(run_report week)"
# Assert: literal ESC (0x1b) byte is NOT in the rendered output.
if printf '%s' "${out_25}" | LC_ALL=C grep -q $'\x1b'; then
  printf '  FAIL: T25 — ESC byte (0x1b) leaked into Serendipity render\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# The benign payload bytes (the `[2J[H` tail that follows the
# stripped ESC) DO appear because they're printable. The test wants
# the cursor sequence broken, not the entire string redacted.
case "${out_25}" in
  *"safe-prefix"*) pass=$((pass + 1)) ;;
  *)
    printf '  FAIL: T25 — pre-escape benign bytes missing from render\n' >&2
    fail=$((fail + 1)) ;;
esac
rm -f "${QP}/serendipity-log.jsonl"

# T26: A3 ANSI-escape neutralization in classifier-misfire reason render.
printf 'T26: A3 ANSI-escape stripped from misfire reason render\n'
printf '{"ts":%s,"reason":"reason-prefix\\u001b]0;HACKED\\u0007","intent":"x","domain":"y"}\n' \
  "$(date +%s)" > "${QP}/classifier_misfires.jsonl"
out_26="$(run_report week)"
if printf '%s' "${out_26}" | LC_ALL=C grep -q $'\x1b'; then
  printf '  FAIL: T26 — ESC byte leaked into misfire reason render\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# BEL (0x07) — would drive an audible beep / xterm title escape.
if printf '%s' "${out_26}" | LC_ALL=C grep -q $'\x07'; then
  printf '  FAIL: T26 — BEL byte leaked into misfire reason render\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/classifier_misfires.jsonl"

# ----------------------------------------------------------------------
printf 'Test 27: v1.34.0 — Delivery contract section empty-state\n'
out="$(run_report week)"
assert_contains "T27 — section header rendered" "## Delivery contract fires" "${out}"
assert_contains "T27 — empty-state message" "No delivery-contract blocks in window" "${out}"

# ----------------------------------------------------------------------
printf 'Test 28: v1.34.0 — Delivery contract aggregates rule fires\n'
NOW28="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW28},"gate":"delivery-contract","event":"block","details":{"prompt_blocker_count":"0","inferred_blocker_count":"2","inferred_rules":"R1_missing_tests,R3a_conf_no_parser","commit_mode":"unspecified","prompt_surfaces":"","test_expectation":""}}
{"ts":${NOW28},"gate":"delivery-contract","event":"block","details":{"prompt_blocker_count":"1","inferred_blocker_count":"1","inferred_rules":"R5_code_no_docs","commit_mode":"required","prompt_surfaces":"docs","test_expectation":"verify"}}
{"ts":${NOW28},"gate":"delivery-contract","event":"block","details":{"prompt_blocker_count":"0","inferred_blocker_count":"3","inferred_rules":"R1_missing_tests,R3a_conf_no_parser,R3b_conf_no_config_table","commit_mode":"unspecified","prompt_surfaces":"","test_expectation":""}}
EOF
out="$(run_report week)"
assert_contains "T28 — header line shows totals" "Window total: 3 delivery-contract block(s)" "${out}"
assert_contains "T28 — splits prompt-only vs inferred" "0 prompt-only (v1) + 3 inferred (v2)" "${out}"
assert_contains "T28 — R1 row" "\`R1_missing_tests\`" "${out}"
assert_contains "T28 — R3a row" "\`R3a_conf_no_parser\`" "${out}"
assert_contains "T28 — R3b row" "\`R3b_conf_no_config_table\`" "${out}"
assert_contains "T28 — R5 row" "\`R5_code_no_docs\`" "${out}"
rm -f "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
printf 'Test 29: v1.36.0 — --sweep includes active-session rows in the report\n'
# Setup: synthesize an empty cross-session ledger AND one active session
# dir under STATE_ROOT. --sweep should fold the active session into the
# in-memory view without touching the on-disk ledger.
NOW29="$(date +%s)"
SWEEP_STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
SWEEP_SID="active-session-T29"
mkdir -p "${SWEEP_STATE_ROOT}/${SWEEP_SID}"
cat > "${SWEEP_STATE_ROOT}/${SWEEP_SID}/session_state.json" <<EOF
{
  "session_start_ts": ${NOW29},
  "last_user_prompt_ts": ${NOW29},
  "last_edit_ts": ${NOW29},
  "task_domain": "coding",
  "task_intent": "execution",
  "code_edit_count": "5",
  "doc_edit_count": "1",
  "stop_guard_blocks": "2",
  "dimension_guard_blocks": "1",
  "subagent_dispatch_count": "3",
  "session_outcome": "active",
  "skip_count": "0",
  "serendipity_count": "0",
  "project_key": "test-project"
}
EOF
cat > "${SWEEP_STATE_ROOT}/${SWEEP_SID}/gate_events.jsonl" <<EOF
{"ts":${NOW29},"gate":"stop-guard","event":"block","details":{"reason":"unverified"}}
{"ts":${NOW29},"gate":"discovered-scope","event":"block","details":{"finding_count":"3"}}
EOF

# Empty cross-session ledgers — pre-sweep there's no data.
: > "${QP}/session_summary.jsonl"
: > "${QP}/gate_events.jsonl"

# Without --sweep: report should show empty-state for sessions.
out_no_sweep="$(run_report week)"
assert_contains "T29a — no-sweep shows empty-ledger message" \
  "No session_summary rows in window" "${out_no_sweep}"

# With --sweep: report should fold in the active session.
out_sweep="$(run_report --sweep week)"
assert_contains "T29b — --sweep banner present" "active session(s) in this view" "${out_sweep}"
# F-4 (Wave 3 review): bound the count cell with surrounding pipes
# so a future row reformat that produced "Sessions | 12" cannot
# substring-match a wrong count past the assertion.
assert_contains "T29c — --sweep folds session into Sessions count" "| Sessions | 1 |" "${out_sweep}"
# Gate events from the active session should appear under the gate
# events section.
assert_contains "T29d — --sweep folds gate events" "stop-guard" "${out_sweep}"

# Confirm the on-disk ledger was NOT modified by --sweep.
ledger_lines="$(wc -l < "${QP}/session_summary.jsonl" | tr -d '[:space:]')"
if [[ "${ledger_lines}" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T29e — --sweep wrote %d row(s) to on-disk ledger (must be 0)\n' "${ledger_lines}" >&2
  fail=$((fail + 1))
fi

# Cleanup synthesized active session.
rm -rf "${SWEEP_STATE_ROOT:?}/${SWEEP_SID:?}"
rm -f "${QP}/gate_events.jsonl" "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# Test 30 (v1.40.x W4 follow-up): per-reviewer fix-rate sub-table.
# W4 (89a98a7) shipped the write path (record-finding-list.sh emits
# originating_reviewer in finding-status-change event details) but
# show-report.sh had no read path — the field accumulated as dead
# data. The follow-up closes the loop: when finding-status-change
# events carry originating_reviewer, /ulw-report renders fix-rate
# (shipped/total) per reviewer with a `← below threshold` marker
# for reviewers below 30%. Six rows synthesize two reviewers
# (above-threshold and at-threshold) to lock the rendering shape.
# ----------------------------------------------------------------------
printf 'Test 30: v1.40.x — per-reviewer fix-rate sub-table renders with calibration marker\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-001","finding_status":"shipped","originating_reviewer":"quality-reviewer","commit_sha":"aaa"}}
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-002","finding_status":"shipped","originating_reviewer":"quality-reviewer","commit_sha":"bbb"}}
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-003","finding_status":"rejected","originating_reviewer":"quality-reviewer","commit_sha":"ccc"}}
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-004","finding_status":"rejected","originating_reviewer":"over-eager-reviewer","commit_sha":"ddd"}}
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-005","finding_status":"rejected","originating_reviewer":"over-eager-reviewer","commit_sha":"eee"}}
{"ts":${NOW},"session":"test-rev","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-006","finding_status":"shipped","originating_reviewer":"over-eager-reviewer","commit_sha":"fff"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-rev","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":6,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
assert_contains "T30a: section header rendered" \
  "Per-reviewer fix-rate" "${out}"
# quality-reviewer: 2 shipped / 3 total = 66%
assert_contains "T30b: quality-reviewer row with 66% fix-rate" \
  "| \`quality-reviewer\` | 3 | 2 | 66%" "${out}"
# over-eager-reviewer: 1 shipped / 3 total = 33% (above 30% — no marker)
assert_contains "T30c: over-eager-reviewer row with 33% fix-rate (above threshold)" \
  "| \`over-eager-reviewer\` | 3 | 1 | 33%" "${out}"
# Ascending-by-fix-rate sort: over-eager (33%) appears before quality (66%)
over_eager_line="$(printf '%s' "${out}" | grep -n 'over-eager-reviewer' | head -1 | cut -d: -f1)"
quality_line="$(printf '%s' "${out}" | grep -n '| `quality-reviewer`' | head -1 | cut -d: -f1)"
if [[ -n "${over_eager_line}" ]] && [[ -n "${quality_line}" ]] && [[ "${over_eager_line}" -lt "${quality_line}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T30d — ascending-by-fix-rate sort: over-eager (line %s) should precede quality (line %s)\n' "${over_eager_line}" "${quality_line}" >&2
  fail=$((fail + 1))
fi
rm -f "${QP}/gate_events.jsonl" "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# Test 31 (v1.40.x W4 follow-up): below-threshold marker fires when
# fix-rate drops under 30%. Locks the calibration-signal behavior:
# a reviewer flagging mostly-rejected findings is the failure mode
# the marker exists to surface.
# ----------------------------------------------------------------------
printf 'Test 31: v1.40.x — below-threshold marker renders for reviewers under 30%% fix-rate\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-bad","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-101","finding_status":"rejected","originating_reviewer":"bad-reviewer","commit_sha":"aaa"}}
{"ts":${NOW},"session":"test-bad","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-102","finding_status":"rejected","originating_reviewer":"bad-reviewer","commit_sha":"bbb"}}
{"ts":${NOW},"session":"test-bad","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-103","finding_status":"rejected","originating_reviewer":"bad-reviewer","commit_sha":"ccc"}}
{"ts":${NOW},"session":"test-bad","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-104","finding_status":"rejected","originating_reviewer":"bad-reviewer","commit_sha":"ddd"}}
{"ts":${NOW},"session":"test-bad","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-105","finding_status":"shipped","originating_reviewer":"bad-reviewer","commit_sha":"eee"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-bad","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":5,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# 1 shipped / 5 total = 20% → below-threshold marker fires
assert_contains "T31a: bad-reviewer row with 20% fix-rate and below-threshold marker" \
  "| \`bad-reviewer\` | 5 | 1 | 20% ← below threshold |" "${out}"
rm -f "${QP}/gate_events.jsonl" "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# Test 32 (v1.40.x W4 follow-up): section HIDDEN when no
# originating_reviewer present. Back-compat for legacy
# finding-status-change rows pre-W4 that don't carry the field.
# ----------------------------------------------------------------------
printf 'Test 32: v1.40.x — per-reviewer section HIDDEN when no originating_reviewer rows present\n'
NOW="$(date +%s)"
cat > "${QP}/gate_events.jsonl" <<EOF
{"ts":${NOW},"session":"test-leg","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-201","finding_status":"shipped","commit_sha":"aaa"}}
{"ts":${NOW},"session":"test-leg","gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-202","finding_status":"shipped","originating_reviewer":"","commit_sha":"bbb"}}
EOF
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"test-leg","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":2,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report week)"
# Section header MUST NOT appear when every row has empty/missing reviewer
if [[ "${out}" == *"Per-reviewer fix-rate"* ]]; then
  printf '  FAIL: T32 — Per-reviewer section rendered despite no originating_reviewer rows\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/gate_events.jsonl" "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# Wave 2 — Session duration distribution section
#
# Verifies the new ## Session duration distribution section renders
# correct cohort breakdown (edit/review vs prompt-only vs unlabeled),
# applies the <10s throwaway filter, and handles empty-state cleanly.
# ----------------------------------------------------------------------
printf 'Test 33: v1.41 W2 — duration section empty-state when no rows have end_ts\n'
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"no-end","start_ts":1777000000,"end_ts":null,"end_ts_source":null,"domain":"mixed","intent":"advisory","edit_count":0,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"unclassified_by_sweep","skip_count":0,"serendipity_count":0}
EOF
out="$(run_report all)"
assert_contains "T33 duration empty-state message" "No sessions with measurable wall-clock duration" "${out}"
assert_contains "T33 section heading present" "## Session duration distribution" "${out}"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 34: v1.41 W2 — duration cohort split by end_ts_source\n'
# Fixture: 3 edit-grade (1h, 2h, 3h), 2 review-grade (10m, 30m), 2 prompt-only
# (5m, 1h), 1 throwaway (5s), 1 missing end_ts.
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"edit1","start_ts":1777000000,"end_ts":1777003600,"end_ts_source":"edit","outcome":"completed_inferred","edit_count":3,"reviewed":true,"verified":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"edit2","start_ts":1777010000,"end_ts":1777017200,"end_ts_source":"edit","outcome":"completed_inferred","edit_count":7,"reviewed":true,"verified":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"edit3","start_ts":1777020000,"end_ts":1777030800,"end_ts_source":"edit","outcome":"completed_inferred","edit_count":2,"reviewed":true,"verified":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"rev1","start_ts":1777040000,"end_ts":1777040600,"end_ts_source":"review","outcome":"unclassified_by_sweep","edit_count":0,"reviewed":true,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"rev2","start_ts":1777050000,"end_ts":1777051800,"end_ts_source":"review","outcome":"unclassified_by_sweep","edit_count":0,"reviewed":true,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"pmt1","start_ts":1777060000,"end_ts":1777060300,"end_ts_source":"prompt","outcome":"idle","edit_count":0,"reviewed":false,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"mixed","intent":"advisory"}
{"session_id":"pmt2","start_ts":1777070000,"end_ts":1777073600,"end_ts_source":"prompt","outcome":"idle","edit_count":0,"reviewed":false,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"mixed","intent":"advisory"}
{"session_id":"thrw","start_ts":1777080000,"end_ts":1777080005,"end_ts_source":"edit","outcome":"idle","edit_count":0,"reviewed":false,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"mixed","intent":"execution"}
{"session_id":"noend","start_ts":1777090000,"end_ts":null,"end_ts_source":null,"outcome":"idle","edit_count":0,"reviewed":false,"verified":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"mixed","intent":"advisory"}
EOF
out="$(run_report all)"
assert_contains "T34 section heading"      "## Session duration distribution" "${out}"
# n=7, no low-n annotation; renders because 2+ sub-cohorts populate (edit/review + prompt-only).
assert_contains "T34 all-qualifying row"   "| All qualifying | 7 |" "${out}"
# n=5 exactly — no low-n annotation (threshold is n<5).
assert_contains "T34 edit/review cohort"   "| Edit/review-grade | 5 |" "${out}"
# n=2 — gets the low-n annotation. Assert prefix + count separately so the
# annotation doesn't break the regression net.
assert_contains "T34 prompt-only cohort label" "Prompt-only (advisory)" "${out}"
assert_contains "T34 prompt-only cohort low-n annotation" "Prompt-only (advisory) *(n<5)*" "${out}"
# 2 rows excluded: one with wall=5s (below 10s floor), one with null end_ts.
assert_contains "T34 throwaway disclosure" "Excluded: 2 session(s)" "${out}"
# Sanity — pre-Wave-1 unlabeled row should NOT appear when all rows have a label.
if [[ "${out}" == *"Unlabeled (pre-v1.41 rows)"* ]]; then
  printf '  FAIL: T34 — Unlabeled cohort rendered despite all rows having end_ts_source\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 35: v1.41 W2 — pre-Wave-1 rows render in "Unlabeled" cohort\n'
# Two rows without end_ts_source — simulates pre-fix ledger entries.
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"old1","start_ts":1777000000,"end_ts":1777001800,"outcome":"completed_inferred","edit_count":1,"reviewed":true,"verified":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"old2","start_ts":1777010000,"end_ts":1777013600,"outcome":"completed_inferred","edit_count":2,"reviewed":true,"verified":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
EOF
out="$(run_report all)"
assert_contains "T35 unlabeled cohort rendered" "Unlabeled (pre-v1.41 rows)" "${out}"
assert_contains "T35a unlabeled cohort shows n=2"   "| 2 |" "${out}"
# v1.41 W4 polish (cumulative-review F1): when only ONE sub-cohort has
# rows, the "All qualifying" row would be visually identical — suppress.
if [[ "${out}" == *"All qualifying"* ]]; then
  printf '  FAIL: T35b — All-qualifying row rendered when only one sub-cohort populated (visually redundant)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# v1.41 W4 polish (cumulative-review F3): n<5 annotation
assert_contains "T35c low-n annotation present" "*(n<5)*" "${out}"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 36: v1.41 W2 — --share mode emits median session length bullet\n'
NOW="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"s1","start_ts":${NOW},"end_ts":$((NOW + 1800)),"end_ts_source":"edit","outcome":"completed_inferred","edit_count":2,"reviewed":true,"verified":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
{"session_id":"s2","start_ts":$((NOW - 3600)),"end_ts":$((NOW - 3000)),"end_ts_source":"edit","outcome":"completed_inferred","edit_count":1,"reviewed":true,"verified":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"skip_count":0,"serendipity_count":0,"domain":"coding","intent":"execution"}
EOF
out="$(run_report week --share)"
assert_contains "T36 share-mode duration bullet" "Median session length (wall-clock)" "${out}"
# Share card MUST NOT include per-session data (privacy contract).
# Fixture session IDs (s1/s2) plus structural shapes for prod session
# IDs (UUID-ish) and raw timestamps (10-digit unix). All three must be
# absent — fixture-only literal check would miss leaks in prod data.
if [[ "${out}" == *"s1"* ]] || [[ "${out}" == *"s2"* ]]; then
  printf '  FAIL: T36 — share mode leaked fixture session IDs (s1/s2)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# UUID-shaped session IDs (8-4-4-4-12 hex) — production session shape.
# T36 fixture doesn't use these, but the test asserts the SHAPE never
# leaks regardless of fixture choice. The `LC_ALL=C` keeps grep -E
# locale-stable across BSD/GNU.
if printf '%s' "${out}" | LC_ALL=C grep -Eq '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'; then
  printf '  FAIL: T36 — share mode leaked a UUID-shaped session ID\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
# Raw unix timestamps (10-digit since 2001-09-09, will fail when
# epoch crosses 11 digits in year 2286). The fixture sets start_ts
# to ${NOW} which IS a 10-digit timestamp — a regression that emitted
# raw ts in the share digest would surface here.
if printf '%s' "${out}" | LC_ALL=C grep -Eq '\b1[7-9][0-9]{8}\b'; then
  printf '  FAIL: T36 — share mode leaked a raw unix timestamp\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# F3 (SRE-lens): discovered-scope capture-miss surfaced in the Headline.
# zero_capture events live in gate_events.jsonl, but the per-gate detail
# tables render only `block` events — so without the H5 heuristic the
# dropped-lens-findings signal is invisible in /ulw-report.
printf 'Test 37: discovered-scope capture-miss surfaces when zero_capture >= 5\n'
NOW="$(date +%s)"
: > "${QP}/gate_events.jsonl"
for _i in 1 2 3 4 5 6; do
  printf '{"ts":%s,"gate":"discovered-scope","event":"zero_capture","agent":"product-lens"}\n' "${NOW}" >> "${QP}/gate_events.jsonl"
done
out="$(run_report week)"
assert_contains "T37 — capture-miss headline renders" "Discovered-scope capture misses: 6" "${out}"
# Below threshold (4 < 5) stays quiet — no false alarm on benign single hits.
: > "${QP}/gate_events.jsonl"
for _i in 1 2 3 4; do
  printf '{"ts":%s,"gate":"discovered-scope","event":"zero_capture","agent":"oracle"}\n' "${NOW}" >> "${QP}/gate_events.jsonl"
done
out="$(run_report week)"
if printf '%s' "${out}" | grep -q "Discovered-scope capture misses"; then
  printf '  FAIL: T37 — capture-miss fired below threshold (4 < 5)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
# T38 (v1.47 data-lens #2): goal lifecycle subtype split renders — the
# write-only goal events (set vs auto-armed, achieved, stuck-wall) become
# a visible line, answering the single-entrance auto-arm precision question.
printf 'Test 38: goal lifecycle subtypes render with auto-arm precision cue\n'
NOW="$(date +%s)"
: > "${QP}/gate_events.jsonl"
{
  printf '{"_v":1,"ts":%s,"gate":"goal","event":"goal-auto-armed","details":{}}\n' "${NOW}"
  printf '{"_v":1,"ts":%s,"gate":"goal","event":"goal-auto-armed","details":{}}\n' "${NOW}"
  printf '{"_v":1,"ts":%s,"gate":"goal","event":"goal-achieved","details":{}}\n' "${NOW}"
  printf '{"_v":1,"ts":%s,"gate":"goal","event":"stuck-wall","details":{}}\n' "${NOW}"
} >> "${QP}/gate_events.jsonl"
out="$(run_report week)"
assert_contains "T38 — goal lifecycle line renders" "Goal lifecycle (window)" "${out}"
assert_contains "T38 — auto-armed count surfaces" "Auto-armed goals: 2" "${out}"
rm -f "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
# T39 (v1.47 data-lens #1): uniform per-gate block→reprompt table — gates
# beyond the two dedicated ones get a directional-FP rate once blocks >= 3.
printf 'Test 39: generic per-gate block-reprompt table renders at >=3 blocks\n'
: > "${QP}/gate_events.jsonl"
{
  for _i in 1 2 3 4; do
    printf '{"_v":1,"ts":%s,"gate":"review-coverage","event":"block","details":{}}\n' "${NOW}"
  done
  printf '{"_v":1,"ts":%s,"gate":"review-coverage","event":"post-block-reprompt","details":{"pairing":"generic"}}\n' "${NOW}"
  printf '{"_v":1,"ts":%s,"gate":"review-coverage","event":"post-block-reprompt","details":{"pairing":"generic"}}\n' "${NOW}"
  # a 2-block gate stays noise-suppressed
  printf '{"_v":1,"ts":%s,"gate":"wave-shape","event":"block","details":{}}\n' "${NOW}"
  printf '{"_v":1,"ts":%s,"gate":"wave-shape","event":"block","details":{}}\n' "${NOW}"
} >> "${QP}/gate_events.jsonl"
out="$(run_report week)"
assert_contains "T39 — per-gate reprompt table renders" "Per-gate block→reprompt rates" "${out}"
assert_contains "T39 — review-coverage row with rate" '`review-coverage`: 4 blocks → 2 near-immediate reprompt(s) (50%)' "${out}"
if printf '%s' "${out}" | grep -q '`wave-shape`:'; then
  printf '  FAIL: T39 — 2-block gate should be noise-suppressed (<3 blocks)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
# T40 (v1.47 sre-lens R-2): anomaly-log slice — log_anomaly rows finally
# have a reader. Seed window-fresh [anomaly] rows in hooks.log and assert
# the count + excerpt render; stale rows (older than the window) stay out.
printf 'Test 40: hook anomaly slice renders window-filtered count\n'
_t40_log="${QP}/state/hooks.log"
mkdir -p "${QP}/state"
_t40_now_str="$(date '+%Y-%m-%d %H:%M:%S')"
{
  printf '2020-01-01 00:00:00  [anomaly]  ancient-hook  pre-window row must not count\n'
  printf '%s  [anomaly]  pretool-intent-guard-crash  aborted mid-hook rc=1 (gate failed open)\n' "${_t40_now_str}"
  printf '%s  [anomaly]  write_state  mktemp failed for key foo (FS pressure?)\n' "${_t40_now_str}"
  printf '%s  [debug]  some-hook  debug rows never count\n' "${_t40_now_str}"
} > "${_t40_log}"
out="$(run_report week)"
assert_contains "T40 — anomaly count renders (2 in window)" "2 hook anomalies in window" "${out}"
assert_contains "T40 — recent anomaly excerpt renders" "mktemp failed for key foo" "${out}"
rm -f "${_t40_log}"

# ----------------------------------------------------------------------
printf 'Test 41: --merge folds external machine dirs with host attribution\n'
NOW="$(date +%s)"
_t41_local_host="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')"
_t41_local_host="${_t41_local_host//[^A-Za-z0-9._-]/-}"
# Local ledger: one recent row WITHOUT host (pre-v1.48 shape → backfilled
# with this machine's identity at read time).
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"local1","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
# External #1: extracted-archive shape (root containing .claude/quality-pack);
# one row without host (backfill → dir basename), one WITH host (preserved).
EXT1="${TEST_HOME}/ext/Intel-2019"
mkdir -p "${EXT1}/.claude/quality-pack"
cat > "${EXT1}/.claude/quality-pack/session_summary.jsonl" <<EOF
{"session_id":"e1a","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":2,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}
{"session_id":"e1b","host":"custom-host","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":3,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
printf '{"_v":1,"ts":%s,"gate":"merge-proof-gate","event":"block"}\n' "${NOW}" \
  > "${EXT1}/.claude/quality-pack/gate_events.jsonl"
# External #2: bare quality-pack-dir shape, passed via --merge=<dir>.
EXT2="${TEST_HOME}/ext/mbp-qp"
mkdir -p "${EXT2}"
cat > "${EXT2}/session_summary.jsonl" <<EOF
{"session_id":"e2a","start_ts":${NOW},"end_ts":${NOW},"domain":"coding","intent":"execution","edit_count":4,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
_t41_ext1_before="$(cat "${EXT1}/.claude/quality-pack/session_summary.jsonl")"
out="$(run_report all --merge "${EXT1}" --merge="${EXT2}")"
assert_contains "T41 — merge banner names 2 dirs" "Including 2 external machine dir(s)" "${out}"
assert_contains "T41 — banner lists the Intel-2019 label" "Intel-2019" "${out}"
assert_contains "T41 — sessions count sums local + external" "| Sessions | 4 |" "${out}"
assert_contains "T41 — by-host attribution line renders" "Sessions by host (all merged rows):" "${out}"
assert_contains "T41 — external row backfilled with dir label" "Intel-2019: 1" "${out}"
assert_contains "T41 — preset host preserved (not overwritten)" "custom-host: 1" "${out}"
assert_contains "T41 — bare-dir shape labeled by basename" "mbp-qp: 1" "${out}"
assert_contains "T41 — local row backfilled with this machine" "${_t41_local_host}: 1" "${out}"
assert_contains "T41 — merged gate event surfaces in report" "merge-proof-gate" "${out}"
_t41_ext1_after="$(cat "${EXT1}/.claude/quality-pack/session_summary.jsonl")"
assert_eq "T41 — external source unmodified (read-only)" "${_t41_ext1_before}" "${_t41_ext1_after}"

# ----------------------------------------------------------------------
printf 'Test 42: --merge skips a ledger-less dir gracefully, exit 0\n'
set +e
out="$(run_report all --merge "${TEST_HOME}/no-such-machine-dir")"
rc=$?
set -e
assert_eq "T42 — exit 0 despite bad merge dir" "0" "${rc}"
assert_contains "T42 — skip banner names the dir" "Skipping ${TEST_HOME}/no-such-machine-dir" "${out}"
rm -rf "${TEST_HOME}/ext"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 43: --merge survives malformed rows (fromjson? skip, no truncation)\n'
NOW="$(date +%s)"
_t43_local_host="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')"
_t43_local_host="${_t43_local_host//[^A-Za-z0-9._-]/-}"
# Local ledger: good row, TORN row (simulated rate-limit-kill append), good row.
{
  printf '{"session_id":"l1","start_ts":%s,"end_ts":%s,"domain":"coding","intent":"execution","edit_count":1,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}\n' "${NOW}" "${NOW}"
  printf '{"session_id":"torn","start_ts":%s,"domai\n' "${NOW}"
  printf '{"session_id":"l2","start_ts":%s,"end_ts":%s,"domain":"coding","intent":"execution","edit_count":1,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}\n' "${NOW}" "${NOW}"
} > "${QP}/session_summary.jsonl"
# External ledger with the same corruption shape.
EXT3="${TEST_HOME}/ext3/Corrupt-Machine"
mkdir -p "${EXT3}/.claude/quality-pack"
{
  printf '{"session_id":"c1","start_ts":%s,"end_ts":%s,"domain":"coding","intent":"execution","edit_count":1,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}\n' "${NOW}" "${NOW}"
  printf 'not json at all\n'
  printf '{"session_id":"c2","start_ts":%s,"end_ts":%s,"domain":"coding","intent":"execution","edit_count":1,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"outcome":"shipped","skip_count":0,"serendipity_count":0}\n' "${NOW}" "${NOW}"
} > "${EXT3}/.claude/quality-pack/session_summary.jsonl"
out="$(run_report all --merge "${EXT3}")"
assert_contains "T43 — local rows after torn line survive" "${_t43_local_host}: 2" "${out}"
assert_contains "T43 — external rows after bad line survive" "Corrupt-Machine: 2" "${out}"
rm -rf "${TEST_HOME}/ext3"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
printf 'Test 44: --merge followed by a flag does not swallow it\n'
out="$(run_report all --merge --sweep)"
rc=$?
assert_eq "T44 — exit 0" "0" "${rc}"
assert_contains "T44 — warning names the unconsumed flag" "Missing directory value" "${out}"
assert_contains "T44 — --sweep still took effect" "[--sweep] Including" "${out}"

# ----------------------------------------------------------------------
# v1.48-pre: Auto-tune section (read path for the `auto_tune` conf flag's
# write path — see tests/test-auto-tune.sh for the write-side coverage).
printf 'Test 45: Auto-tune section — empty state names both possible causes\n'
rm -f "${QP}/auto-tune.jsonl"
out="$(run_report week)"
assert_contains "T45a — empty-state message present" "No auto-tune applications in window" "${out}"
assert_contains "T45b — empty-state names the off-by-default flag" "auto_tune=off" "${out}"
assert_contains "T45c — empty-state names the evidence bar" "50% reprompt-rate" "${out}"

printf 'Test 46: Auto-tune section — populated row renders old -> new, host, evidence\n'
NOW="$(date +%s)"
{
  printf '{"_v":1,"ts":%s,"flag":"objective_contract_min_files","old":4,"new":5,"evidence":"reprompt_rate_pct=66 blocks=12 reprompts=8 window_days=7","host":"ci-host"}\n' \
    "${NOW}"
  printf '{"_v":1,"ts":%s,"flag":"objective_contract_min_files","old":5,"new":6,"evidence":"FUTURE-MUST-NOT-COUNT","host":"future-host"}\n' \
    "$((NOW + 86400))"
  printf '{"_v":1,"ts":"%s","flag":"objective_contract_min_files","old":5,"new":6,"evidence":"STRING-TS-MUST-NOT-COUNT","host":"string-host"}\n' \
    "${NOW}"
  printf '{"_v":1,"ts":%s.5,"flag":"objective_contract_min_files","old":5,"new":6,"evidence":"FRACTIONAL-TS-MUST-NOT-COUNT","host":"fractional-host"}\n' \
    "${NOW}"
} > "${QP}/auto-tune.jsonl"
out="$(run_report week)"
assert_contains "T46a — window total rendered" "1 auto-tune application" "${out}"
assert_contains "T46b — old -> new delta rendered" "4 -> 5" "${out}"
assert_contains "T46c — host rendered" "ci-host" "${out}"
assert_contains "T46d — evidence rendered" "reprompt_rate_pct=66" "${out}"
assert_not_contains "T46e — future rows excluded from bounded window" \
  "FUTURE-MUST-NOT-COUNT" "${out}"
assert_not_contains "T46f — numeric-string timestamps excluded" \
  "STRING-TS-MUST-NOT-COUNT" "${out}"
assert_not_contains "T46g — fractional timestamps excluded" \
  "FRACTIONAL-TS-MUST-NOT-COUNT" "${out}"
rm -f "${QP}/auto-tune.jsonl"

# ----------------------------------------------------------------------
# The newest summary identity, not physical ledger order or timestamp alone,
# owns every session-aware `last` slice. S1 rows are deliberately newer and
# physically last to catch both historical failure modes. One identity-less
# serendipity row exercises the explicitly-labelled legacy approximation path.
printf 'Test 47: last mode scopes every session-aware ledger by exact identity\n'
NOW47="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"S2-exact","start_ts":${NOW47},"end_ts":$((NOW47 + 60)),"domain":"coding","intent":"execution","edit_count":2,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":2,"outcome":"shipped","skip_count":0,"serendipity_count":1}
{"session_id":"S1-foreign","start_ts":$((NOW47 - 1000)),"end_ts":$((NOW47 - 900)),"domain":"coding","intent":"execution","edit_count":99,"verified":true,"reviewed":true,"guard_blocks":9,"dim_blocks":0,"exhausted":false,"dispatches":9,"outcome":"shipped","skip_count":0,"serendipity_count":9}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW47},"session_id":"S2-exact","gate":"delivery-contract","event":"block","details":{}}
{"_v":1,"ts":${NOW47},"session":"S2-exact","gate":"state-corruption","event":"recovered","details":{"archive_path":"state.corrupt.${NOW47}","recovered_ts":"${NOW47}"}}
{"_v":1,"ts":$((NOW47 + 200)),"session_id":"S1-foreign","gate":"FOREIGN-GATE-MUST-NOT-LEAK","event":"block","details":{}}
{"_v":1,"ts":$((NOW47 + 201)),"session":"S1-foreign","gate":"state-corruption","event":"recovered","details":{"archive_path":"INVALID-FOREIGN-PATH","recovered_ts":"bad"}}
EOF
cat > "${QP}/serendipity-log.jsonl" <<EOF
{"ts":${NOW47},"session":"S2-exact","fix":"EXACT-S2-SERENDIPITY","original_task":"selected"}
{"ts":$((NOW47 + 50)),"fix":"LEGACY-APPROX-SERENDIPITY","original_task":"legacy"}
{"ts":$((NOW47 + 200)),"session_id":"S1-foreign","fix":"FOREIGN-S1-SERENDIPITY-MUST-NOT-LEAK","original_task":"foreign"}
EOF
cat > "${QP}/classifier_misfires.jsonl" <<EOF
{"ts":${NOW47},"session_id":"S2-exact","reason":"EXACT-S2-MISFIRE","corrected_by_user":false}
{"ts":$((NOW47 + 200)),"session":"S1-foreign","reason":"FOREIGN-S1-MISFIRE-MUST-NOT-LEAK","corrected_by_user":true}
EOF
cat > "${QP}/used-archetypes.jsonl" <<EOF
{"ts":${NOW47},"session":"S2-exact","project_key":"selected","archetype":"Exact-S2-Archetype"}
{"ts":$((NOW47 + 200)),"session_id":"S1-foreign","project_key":"foreign","archetype":"Foreign-S1-Archetype-Must-Not-Leak"}
EOF

out="$(run_report last)"
assert_contains "T47a — latest summary chosen by timestamp, not physical tail" "| Files edited | 2 |" "${out}"
assert_contains "T47b — exact-session serendipity included" "EXACT-S2-SERENDIPITY" "${out}"
assert_contains "T47c — bounded legacy serendipity included" "LEGACY-APPROX-SERENDIPITY" "${out}"
assert_contains "T47d — approximation is explicitly labelled" "1 legacy auxiliary row(s) lacked a session identity" "${out}"
assert_contains "T47e — exact-session misfire included" "EXACT-S2-MISFIRE" "${out}"
assert_contains "T47f — exact-session archetype included" "Exact-S2-Archetype" "${out}"
assert_contains "T47g — headline correction count uses exact session" "| Classifier corrections absorbed | 0 |" "${out}"
assert_not_contains "T47h — foreign serendipity excluded" "FOREIGN-S1-SERENDIPITY-MUST-NOT-LEAK" "${out}"
assert_not_contains "T47i — foreign misfire excluded" "FOREIGN-S1-MISFIRE-MUST-NOT-LEAK" "${out}"
assert_not_contains "T47j — foreign archetype excluded" "Foreign-S1-Archetype-Must-Not-Leak" "${out}"
assert_not_contains "T47k — foreign gate excluded" "FOREIGN-GATE-MUST-NOT-LEAK" "${out}"

share_out="$(run_report last --share)"
assert_contains "T47l — share exact + legacy serendipity count" "Serendipity Rule fires (adjacent defects caught):** 2" "${share_out}"
assert_contains "T47m — share weighted savings use exact gate slice" "Estimated time saved: ~20m 00s of debugging" "${share_out}"
assert_contains "T47n — share gate distribution uses exact session" "delivery-contract: 1" "${share_out}"
assert_contains "T47o — share labels legacy approximation" "1 legacy auxiliary row(s) lacked a session identity" "${share_out}"
assert_not_contains "T47p — share excludes foreign gate distribution" "FOREIGN-GATE-MUST-NOT-LEAK" "${share_out}"

audit_out="$(run_report last --field-shape-audit)"
assert_contains "T47q — field audit is exact-session scoped" "Audited 2 row(s) in window" "${audit_out}"
assert_contains "T47r — invalid foreign field shape excluded" "## Result: clean" "${audit_out}"

rm -f "${QP}/session_summary.jsonl" "${QP}/gate_events.jsonl" \
  "${QP}/serendipity-log.jsonl" "${QP}/classifier_misfires.jsonl" \
  "${QP}/used-archetypes.jsonl"

# ----------------------------------------------------------------------
# Legacy sweeps could emit outcome="abandoned" rows. They are excluded from
# every report cohort, so they must also be excluded while electing the `last`
# session identity; otherwise a newer abandoned row empties the session panel
# while steering every auxiliary ledger to the wrong session.
printf 'Test 48: last mode elects newest non-abandoned session identity\n'
NOW48="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"valid-session","start_ts":$((NOW48 - 100)),"end_ts":$((NOW48 - 50)),"domain":"coding","intent":"execution","edit_count":3,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"completed_inferred","skip_count":0,"serendipity_count":1}
{"session_id":"abandoned-session","start_ts":${NOW48},"end_ts":${NOW48},"domain":"coding","intent":"execution","edit_count":99,"verified":false,"reviewed":false,"guard_blocks":9,"dim_blocks":0,"exhausted":false,"dispatches":9,"outcome":"abandoned","skip_count":0,"serendipity_count":9}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":$((NOW48 - 90)),"session_id":"valid-session","gate":"delivery-contract","event":"block","details":{}}
{"_v":1,"ts":$((NOW48 - 89)),"session":"valid-session","gate":"state-corruption","event":"recovered","details":{"archive_path":"state.corrupt.${NOW48}","recovered_ts":"${NOW48}"}}
{"_v":1,"ts":$((NOW48 + 10)),"session_id":"abandoned-session","gate":"ABANDONED-GATE-MUST-NOT-LEAK","event":"block","details":{}}
{"_v":1,"ts":$((NOW48 + 11)),"session":"abandoned-session","gate":"state-corruption","event":"recovered","details":{"archive_path":"INVALID-ABANDONED-PATH","recovered_ts":"bad"}}
{"_v":1,"ts":$((NOW48 + 20)),"gate":"FUTURE-LEGACY-GATE-MUST-NOT-LEAK","event":"block","details":{}}
EOF
cat > "${QP}/serendipity-log.jsonl" <<EOF
{"ts":$((NOW48 - 88)),"session":"valid-session","fix":"VALID-SESSION-SERENDIPITY","original_task":"selected"}
{"ts":$((NOW48 + 12)),"session_id":"abandoned-session","fix":"ABANDONED-SERENDIPITY-MUST-NOT-LEAK","original_task":"abandoned"}
{"ts":$((NOW48 + 21)),"fix":"FUTURE-LEGACY-SERENDIPITY-MUST-NOT-LEAK","original_task":"newer-unreported"}
EOF
cat > "${QP}/classifier_misfires.jsonl" <<EOF
{"ts":$((NOW48 - 87)),"session_id":"valid-session","reason":"VALID-SESSION-MISFIRE","corrected_by_user":false}
{"ts":$((NOW48 + 13)),"session":"abandoned-session","reason":"ABANDONED-MISFIRE-MUST-NOT-LEAK","corrected_by_user":true}
EOF
cat > "${QP}/used-archetypes.jsonl" <<EOF
{"ts":$((NOW48 - 86)),"session":"valid-session","project_key":"valid","archetype":"Valid-Session-Archetype"}
{"ts":$((NOW48 + 14)),"session_id":"abandoned-session","project_key":"abandoned","archetype":"Abandoned-Archetype-Must-Not-Leak"}
EOF

out="$(run_report last)"
assert_contains "T48a — valid session remains visible" "| Files edited | 3 |" "${out}"
assert_contains "T48b — valid auxiliary identity selected" "VALID-SESSION-SERENDIPITY" "${out}"
assert_contains "T48c — valid misfire selected" "VALID-SESSION-MISFIRE" "${out}"
assert_contains "T48d — valid archetype selected" "Valid-Session-Archetype" "${out}"
assert_contains "T48e — abandoned correction excluded from headline pre-pass" "| Classifier corrections absorbed | 0 |" "${out}"
assert_not_contains "T48f — abandoned serendipity excluded" "ABANDONED-SERENDIPITY-MUST-NOT-LEAK" "${out}"
assert_not_contains "T48g — abandoned misfire excluded" "ABANDONED-MISFIRE-MUST-NOT-LEAK" "${out}"
assert_not_contains "T48h — abandoned archetype excluded" "Abandoned-Archetype-Must-Not-Leak" "${out}"
assert_not_contains "T48i — abandoned gate excluded" "ABANDONED-GATE-MUST-NOT-LEAK" "${out}"
assert_not_contains "T48i2 — post-end legacy serendipity excluded" "FUTURE-LEGACY-SERENDIPITY-MUST-NOT-LEAK" "${out}"
assert_not_contains "T48i3 — post-end legacy gate excluded" "FUTURE-LEGACY-GATE-MUST-NOT-LEAK" "${out}"

share_out="$(run_report last --share)"
assert_contains "T48j — share uses valid summary block count" "Quality-gate blocks (caught issues):** 1" "${share_out}"
assert_contains "T48k — share uses valid auxiliary weighting" "Estimated time saved: ~15m 00s of debugging" "${share_out}"
assert_contains "T48l — share distribution uses valid gate identity" "delivery-contract: 1" "${share_out}"
assert_not_contains "T48m — share excludes abandoned gate identity" "ABANDONED-GATE-MUST-NOT-LEAK" "${share_out}"
assert_not_contains "T48m2 — share excludes post-end legacy gate" "FUTURE-LEGACY-GATE-MUST-NOT-LEAK" "${share_out}"

audit_out="$(run_report last --field-shape-audit)"
assert_contains "T48n — audit uses valid identity only" "Audited 2 row(s) in window" "${audit_out}"
assert_contains "T48o — invalid abandoned shape excluded" "## Result: clean" "${audit_out}"

rm -f "${QP}/session_summary.jsonl" "${QP}/gate_events.jsonl" \
  "${QP}/serendipity-log.jsonl" "${QP}/classifier_misfires.jsonl" \
  "${QP}/used-archetypes.jsonl"

# Missing/non-numeric end_ts is a real in-flight/legacy shape. Preserve the
# start-only fallback, but make that weaker attribution explicit everywhere.
printf 'Test 49: last legacy approximation labels start-only fallback without end_ts\n'
NOW49="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"open-session","start_ts":${NOW49},"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"completed_inferred","skip_count":0,"serendipity_count":1}
EOF
cat > "${QP}/serendipity-log.jsonl" <<EOF
{"ts":$((NOW49 + 10)),"fix":"START-ONLY-LEGACY-SERENDIPITY","original_task":"legacy-open-session"}
EOF

out="$(run_report last)"
assert_contains "T49a — start-only legacy row retained" "START-ONLY-LEGACY-SERENDIPITY" "${out}"
assert_contains "T49b — verbose report labels missing-end fallback" \
  "by the selected session start time because a numeric end time was unavailable" "${out}"
share_out="$(run_report last --share)"
assert_contains "T49c — share retains start-only legacy count" "Serendipity Rule fires (adjacent defects caught):** 1" "${share_out}"
assert_contains "T49d — share labels missing-end fallback" \
  "by the selected session start time because a numeric end time was unavailable" "${share_out}"

rm -f "${QP}/session_summary.jsonl" "${QP}/serendipity-log.jsonl"

# ----------------------------------------------------------------------
# Share-mode gate names cross a privacy boundary. Gate producers and --merge
# inputs do not enforce an enum, so identifier-shaped secrets, Markdown, ANSI,
# and even non-string JSON must never reach the public card verbatim.
printf 'Test 50: share gate distribution allowlists structural labels locally and under merge\n'
NOW50="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"share-security-local","start_ts":${NOW50},"end_ts":$((NOW50 + 60)),"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":6,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${QP}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW50},"session_id":"share-security-local","gate":"delivery-contract","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 1)),"session_id":"share-security-local","gate":"SECRET-password=hunter2","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 2)),"session_id":"share-security-local","gate":"[MARKDOWN-SECRET](javascript:alert('hunter2'))","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 3)),"session_id":"share-security-local","gate":"\u001b[31mANSI-SECRET\u001b[0m","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 4)),"session_id":"share-security-local","gate":"identifierSecretToken42","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 5)),"session_id":"share-security-local","gate":"pretool-intent","event":"block","details":{}}
EOF

# Non-share mode remains a diagnostic surface and keeps the raw local value.
diag_out="$(run_report last)"
assert_contains "T50a — non-share diagnostics preserve raw custom gate" "SECRET-password=hunter2" "${diag_out}"

share_out="$(run_report last --share)"
assert_contains "T50b — canonical gate label remains visible" "delivery-contract: 1" "${share_out}"
assert_contains "T50b2 — canonical pretool gate label remains visible" "pretool-intent: 1" "${share_out}"
assert_contains "T50c — all local unknown gates share one safe bucket" "other/unknown: 4" "${share_out}"
assert_contains "T50d — sanitized and pretool gates retain documented weighting" "Estimated time saved: ~34m 00s of debugging" "${share_out}"
assert_not_contains "T50e — identifier-shaped secret suppressed" "identifierSecretToken42" "${share_out}"
assert_not_contains "T50f — password suppressed" "hunter2" "${share_out}"
assert_not_contains "T50g — Markdown payload suppressed" "MARKDOWN-SECRET" "${share_out}"
assert_not_contains "T50h — ANSI payload text suppressed" "ANSI-SECRET" "${share_out}"
if printf '%s' "${share_out}" | LC_ALL=C grep -q $'\x1b'; then
  printf '  FAIL: T50i — share card leaked a literal ANSI escape\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

EXT50="${TEST_HOME}/SECRET-MERGE-BASENAME-hunter2"
BAD_EXT50="${TEST_HOME}/INVALID-MERGE-PATH-secret-api-key"
mkdir -p "${EXT50}"
cat > "${EXT50}/session_summary.jsonl" <<EOF
{"session_id":"share-security-merged","host":"\u001b]52;c;SECRET-HOST-password=hunter2\u0007","start_ts":${NOW50},"end_ts":$((NOW50 + 60)),"domain":"coding","intent":"execution","edit_count":1,"verified":true,"reviewed":true,"guard_blocks":4,"dim_blocks":0,"exhausted":false,"dispatches":1,"outcome":"shipped","skip_count":0,"serendipity_count":0}
EOF
cat > "${EXT50}/gate_events.jsonl" <<EOF
{"_v":1,"ts":${NOW50},"session_id":"share-security-merged","gate":"MERGED-SECRET-token=sk-live-123","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 1)),"session_id":"share-security-merged","gate":"\u0060MERGED-MARKDOWN-SECRET\u0060","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 2)),"session_id":"share-security-merged","gate":"\u001b]0;MERGED-ANSI-SECRET\u0007","event":"block","details":{}}
{"_v":1,"ts":$((NOW50 + 3)),"session_id":"share-security-merged","gate":{"secret":"MERGED-OBJECT-SECRET"},"event":"block","details":{}}
EOF

merged_diag="$(run_report all --merge "${EXT50}")"
assert_contains "T50i2 — printable custom host diagnostic retained" "SECRET-HOST-password=hunter2" "${merged_diag}"
assert_contains "T50i3 — printable custom gate diagnostic retained" "MERGED-ANSI-SECRET" "${merged_diag}"
if printf '%s' "${merged_diag}" | LC_ALL=C grep -q $'\x1b' \
    || printf '%s' "${merged_diag}" | LC_ALL=C grep -q $'\x07'; then
  printf '  FAIL: T50i4 — merged non-share diagnostics leaked ESC/BEL\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
CONTROL_BAD_EXT50="${TEST_HOME}/BAD-PATH"$'\x1b]52;c;PATH-CONTROL-CANARY\x07'
control_path_diag="$(run_report all --merge "${CONTROL_BAD_EXT50}")"
assert_contains "T50i5 — printable invalid-path diagnostic retained" "PATH-CONTROL-CANARY" "${control_path_diag}"
if printf '%s' "${control_path_diag}" | LC_ALL=C grep -q $'\x1b' \
    || printf '%s' "${control_path_diag}" | LC_ALL=C grep -q $'\x07'; then
  printf '  FAIL: T50i6 — invalid merge-path diagnostic leaked ESC/BEL\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

merged_share="$(run_report all --share --merge "${EXT50}" --merge "${BAD_EXT50}")"
assert_contains "T50j0 — share merge banner is anonymous" "Including 1 external machine dir(s) (paths and host labels suppressed" "${merged_share}"
assert_contains "T50j1 — invalid share merge input is counted anonymously" "Skipped 1 invalid merge input(s) (paths suppressed)" "${merged_share}"
assert_contains "T50j — merged unknown gates join the safe bucket" "other/unknown: 8" "${merged_share}"
assert_contains "T50k — merged sanitized gates retain documented weighting" "Estimated time saved: ~54m 00s of debugging" "${merged_share}"
assert_not_contains "T50l — merged token suppressed" "sk-live-123" "${merged_share}"
assert_not_contains "T50m — merged Markdown suppressed" "MERGED-MARKDOWN-SECRET" "${merged_share}"
assert_not_contains "T50n — merged ANSI text suppressed" "MERGED-ANSI-SECRET" "${merged_share}"
assert_not_contains "T50o — merged object value suppressed" "MERGED-OBJECT-SECRET" "${merged_share}"
assert_not_contains "T50o2 — merged directory basename suppressed" "SECRET-MERGE-BASENAME-hunter2" "${merged_share}"
assert_not_contains "T50o3 — arbitrary merged host suppressed" "SECRET-HOST-password=hunter2" "${merged_share}"
assert_not_contains "T50o4 — invalid merge path suppressed" "INVALID-MERGE-PATH-secret-api-key" "${merged_share}"
assert_not_contains "T50o5 — no shared surface retains password token" "hunter2" "${merged_share}"
if printf '%s' "${merged_share}" | LC_ALL=C grep -q $'\x1b\|\x07'; then
  printf '  FAIL: T50p — merged share card leaked a literal control byte\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
set +e
missing_merge_share="$(run_report --merge --SECRET-NEXT-FLAG-hunter2 --share)"
missing_merge_rc=$?
set -e
assert_eq "T50q — redacted invalid share invocation retains usage rc" "2" "${missing_merge_rc}"
assert_not_contains "T50r — deferred missing-merge diagnostic suppresses next token" \
  "SECRET-NEXT-FLAG-hunter2" "${missing_merge_share}"

rm -rf "${EXT50}"
rm -f "${QP}/session_summary.jsonl" "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
# Every summary scalar crossing into Bash arithmetic must be typed first.
# Command-shaped strings previously caused arithmetic parse/fallthrough and
# exposed the verbose report; dispatch strings also leaked directly in a
# share bullet. Exercise both local and merged rows and prove no side effect.
printf 'Test 51: share summary numerics fail closed under local and merged poison\n'
NOW51="$(date +%s)"
SENTINEL51_LOCAL="${TEST_HOME}/share-local-arithmetic-fired"
SENTINEL51_MERGED="${TEST_HOME}/share-merged-arithmetic-fired"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"numeric-poison-local","start_ts":${NOW51},"end_ts":$((NOW51 + 60)),"guard_blocks":"arr[\$(touch ${SENTINEL51_LOCAL})]","dim_blocks":"","dispatches":"SECRET-DISPATCH-password=hunter2\u001b[31m","skip_count":"arr[\$(touch ${SENTINEL51_LOCAL})]","outcome":"shipped"}
EOF

set +e
poison_share="$(run_report all --share)"
poison_rc=$?
set -e
assert_eq "T51a — poisoned local share exits successfully" "0" "${poison_rc}"
assert_contains "T51b — poisoned local share still renders fixed card" "## oh-my-claude" "${poison_share}"
assert_contains "T51c — poisoned local blocks normalize to zero" "Quality-gate blocks (caught issues):** 0" "${poison_share}"
assert_contains "T51d — poisoned local dispatches normalize to zero" "Specialist dispatches:** 0" "${poison_share}"
assert_not_contains "T51e — poison never falls through to verbose report" "# Harness report" "${poison_share}"
assert_not_contains "T51f — poisoned dispatch secret suppressed" "hunter2" "${poison_share}"
assert_not_contains "T51g — arithmetic payload suppressed" "arr[" "${poison_share}"
if [[ -e "${SENTINEL51_LOCAL}" ]]; then
  printf '  FAIL: T51h — local arithmetic payload executed\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if printf '%s' "${poison_share}" | LC_ALL=C grep -q $'\x1b'; then
  printf '  FAIL: T51i — poisoned local share leaked control bytes\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

EXT51="${TEST_HOME}/numeric-poison-merged"
mkdir -p "${EXT51}"
cat > "${EXT51}/session_summary.jsonl" <<EOF
{"session_id":"numeric-poison-merged","start_ts":${NOW51},"end_ts":$((NOW51 + 60)),"guard_blocks":"arr[\$(touch ${SENTINEL51_MERGED})]","dim_blocks":"SECRET-DIM-password=merged","dispatches":"SECRET-MERGED-DISPATCH","skip_count":"arr[\$(touch ${SENTINEL51_MERGED})]","outcome":"shipped"}
EOF
set +e
poison_merged_share="$(run_report all --share --merge "${EXT51}")"
poison_merged_rc=$?
set -e
assert_eq "T51j — poisoned merged share exits successfully" "0" "${poison_merged_rc}"
assert_contains "T51k — merged poison still renders fixed card" "## oh-my-claude" "${poison_merged_share}"
assert_contains "T51l — both poisoned summaries remain countable" "Sessions:** 2" "${poison_merged_share}"
assert_not_contains "T51m — merged poison never falls through to verbose" "# Harness report" "${poison_merged_share}"
assert_not_contains "T51n — merged numeric secrets suppressed" "SECRET-MERGED-DISPATCH" "${poison_merged_share}"
assert_not_contains "T51o — merged dimension secret suppressed" "SECRET-DIM-password=merged" "${poison_merged_share}"
if [[ -e "${SENTINEL51_LOCAL}" ]] || [[ -e "${SENTINEL51_MERGED}" ]]; then
  printf '  FAIL: T51p — merged arithmetic payload executed\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -rf "${EXT51}"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# Share cohorts use the same current-schema contract as verbose reports:
# legacy abandoned summaries never count in all/week/month aggregates.
printf 'Test 52: non-last share excludes legacy abandoned summaries\n'
NOW52="$(date +%s)"
cat > "${QP}/session_summary.jsonl" <<EOF
{"session_id":"share-valid","start_ts":${NOW52},"end_ts":$((NOW52 + 60)),"guard_blocks":2,"dim_blocks":1,"dispatches":4,"skip_count":0,"outcome":"shipped"}
{"session_id":"share-abandoned","start_ts":$((NOW52 + 1)),"end_ts":$((NOW52 + 61)),"guard_blocks":99,"dim_blocks":99,"dispatches":99,"skip_count":0,"outcome":"abandoned"}
EOF
abandoned_share="$(run_report all --share)"
assert_contains "T52a — only valid summary counts" "Sessions:** 1" "${abandoned_share}"
assert_contains "T52b — abandoned blocks excluded" "Quality-gate blocks (caught issues):** 3" "${abandoned_share}"
assert_contains "T52c — abandoned dispatches excluded" "Specialist dispatches:** 4" "${abandoned_share}"
rm -f "${QP}/session_summary.jsonl"

# ----------------------------------------------------------------------
# A native --resume copies the logical session's findings/gates/state into B
# and fences A.  Every live state-root consumer must skip A or --sweep, the
# user-decision queue, and pending-aging all double the same work.
printf 'Test 53: transferred resume sources are excluded from every live scan\n'
NOW53="$(date +%s)"
STATE53="${QP}/state"
SOURCE53="resume-source-T53"
TARGET53="resume-target-T53"
mkdir -p "${STATE53}/${SOURCE53}" "${STATE53}/${TARGET53}"
cat > "${STATE53}/${SOURCE53}/session_state.json" <<EOF
{"session_start_ts":${NOW53},"last_user_prompt_ts":${NOW53},"task_domain":"coding","task_intent":"execution","subagent_dispatch_count":"7","resume_transferred_to":"${TARGET53}"}
EOF
cat > "${STATE53}/${TARGET53}/session_state.json" <<EOF
{"session_start_ts":${NOW53},"last_user_prompt_ts":${NOW53},"task_domain":"coding","task_intent":"execution","subagent_dispatch_count":"7","resume_source_session_id":"${SOURCE53}"}
EOF
cat > "${STATE53}/${SOURCE53}/findings.json" <<EOF
{"findings":[{"id":"F-T53","status":"pending","requires_user_decision":true,"surface":"api","decision_reason":"choose owner","ts":$((NOW53 - 2 * 86400))}]}
EOF
cp "${STATE53}/${SOURCE53}/findings.json" "${STATE53}/${TARGET53}/findings.json"
# A failed resume may retain copied state under the hidden, TTL-bounded
# quarantine. Recursive findings scans must not surface its pending work.
QUARANTINE53="${STATE53}/.resume-quarantine/resume-target-T53.1234.test/session"
mkdir -p "${QUARANTINE53}"
cat > "${QUARANTINE53}/findings.json" <<EOF
{"findings":[{"id":"F-Q53","status":"pending","requires_user_decision":true,"surface":"quarantine","decision_reason":"must stay hidden","ts":$((NOW53 - 9 * 86400))}]}
EOF
printf '{"ts":%s,"gate":"source-only-resume-gate","event":"block"}\n' "${NOW53}" \
  > "${STATE53}/${SOURCE53}/gate_events.jsonl"
printf '{"ts":%s,"gate":"target-owned-resume-gate","event":"block"}\n' "${NOW53}" \
  > "${STATE53}/${TARGET53}/gate_events.jsonl"
: > "${QP}/session_summary.jsonl"
: > "${QP}/gate_events.jsonl"

out53="$(run_report all --sweep)"
assert_contains "T53a — only target contributes a live session summary" "| Sessions | 1 |" "${out53}"
assert_contains "T53b — target-owned gate remains visible" "target-owned-resume-gate" "${out53}"
assert_not_contains "T53c — source gate is excluded" "source-only-resume-gate" "${out53}"
assert_contains "T53d — copied user-decision finding counted once" \
  "1 currently awaiting input" "${out53}"
assert_contains "T53e — copied pending finding ages once" \
  "1 pending/in-progress finding(s) across all sessions" "${out53}"
assert_not_contains "T53f — quarantined decision finding stays hidden" \
  "F-Q53" "${out53}"
assert_not_contains "T53g — quarantined decision reason stays hidden" \
  "must stay hidden" "${out53}"

rm -rf "${STATE53:?}/${SOURCE53:?}" "${STATE53:?}/${TARGET53:?}" \
  "${STATE53:?}/.resume-quarantine"
rm -f "${QP}/session_summary.jsonl" "${QP}/gate_events.jsonl"

NUL_SOURCE53="resume-nul-source-T53"
NUL_TARGET53="resume-nul-target-T53"
mkdir -p "${STATE53}/${NUL_SOURCE53}"
jq -nc --arg source "${NUL_SOURCE53}" --arg target "${NUL_TARGET53}" \
  --argjson now "${NOW53}" '
  {session_id:$source,session_start_ts:$now,last_user_prompt_ts:$now,
   task_domain:"coding",task_intent:"execution",subagent_dispatch_count:1,
   resume_transferred_to:($target + "\u0000")}
' >"${STATE53}/${NUL_SOURCE53}/session_state.json"
printf '{"ts":%s,"gate":"nul-owner-source-gate","event":"block"}\n' \
  "${NOW53}" >"${STATE53}/${NUL_SOURCE53}/gate_events.jsonl"
: >"${QP}/session_summary.jsonl"
: >"${QP}/gate_events.jsonl"
nul_out53="$(run_report all --sweep)"
assert_contains "T53h — NUL-bearing transfer marker cannot hide live evidence" \
  "nul-owner-source-gate" "${nul_out53}"
rm -rf "${STATE53:?}/${NUL_SOURCE53:?}"
rm -f "${QP}/session_summary.jsonl" "${QP}/gate_events.jsonl"

# ----------------------------------------------------------------------
printf '\n=== Show-Report Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
