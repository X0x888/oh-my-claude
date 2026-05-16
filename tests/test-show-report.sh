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
printf '\n=== Show-Report Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
