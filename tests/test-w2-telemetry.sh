#!/usr/bin/env bash
# v1.36.x Wave 2 telemetry & outcome attribution regression tests.
#
# Covers F-006 (directive value attribution joining bias-defense events
# with session outcomes), F-007 (reviewer ROI joining timing × agent-
# metrics), F-008 (insight-first Headline section at top of /ulw-report),
# F-009 (share-card time-saved weighted by gate type, minus skip cost),
# F-010 (cross-session JSONL schema versioning via _v field).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_TMP="$(mktemp -d)"
QP="${TEST_TMP}/.claude/quality-pack"
mkdir -p "${QP}"

cleanup() { rm -rf "${TEST_TMP}"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); }
fail_msg() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=$((fail + 1))
}

# ----------------------------------------------------------------------
# F-008 — Headline section renders at the top before any detail section.
# ----------------------------------------------------------------------
printf '\n--- F-008: Headline section appears before detail sections ---\n'

# Empty quality-pack — Headline shows "no sessions" empty state.
out_empty="$(HOME="${TEST_TMP}" bash "${SHOW_REPORT}" week 2>/dev/null || true)"

# Headline appears before "## Sessions"
headline_line=$(printf '%s\n' "${out_empty}" | grep -n '^## Headline' | head -1 | cut -d: -f1)
sessions_line=$(printf '%s\n' "${out_empty}" | grep -n '^## Sessions' | head -1 | cut -d: -f1)
if [[ -n "${headline_line}" && -n "${sessions_line}" && "${headline_line}" -lt "${sessions_line}" ]]; then
  ok
else
  fail_msg "F-008: Headline (line ${headline_line:-?}) should appear before Sessions (line ${sessions_line:-?})"
fi

# Empty-state message
if printf '%s' "${out_empty}" | grep -q "No sessions in window"; then
  ok
else
  fail_msg "F-008: Headline empty-state message missing"
fi

# Synthesize sessions data with high gate-fire density to trigger H1.
mkdir -p "${QP}"
now_ts=$(date +%s)
{
  for i in 1 2 3; do
    jq -nc --argjson ts "$((now_ts - i * 3600))" --arg sid "sess-$i" \
      '{session_id:$sid, start_ts: ($ts | tostring), guard_blocks: 5, dim_blocks: 0, dispatches: 1, skip_count: 0, serendipity_count: 0, reviewed: true, exhausted: false, outcome: "committed", domain:"coding", intent:"execution"}'
  done
} > "${QP}/session_summary.jsonl"

out_dense="$(HOME="${TEST_TMP}" bash "${SHOW_REPORT}" week 2>/dev/null || true)"
if printf '%s' "${out_dense}" | grep -q "High gate-fire density"; then
  ok
else
  fail_msg "F-008: H1 (high gate-fire density) should fire on 5+ blocks/session"
fi

# ----------------------------------------------------------------------
# F-009 — Share-card uses weighted gate types and subtracts skip cost.
# ----------------------------------------------------------------------
printf '\n--- F-009: Share-card weighted by gate type and skip cost ---\n'

# Synthesize gate events: one delivery-contract (600s), one advisory (240s).
{
  jq -nc --argjson ts "$((now_ts - 3600))" \
    '{_v:1, ts:$ts, gate:"delivery-contract", event:"block", details:{}, session_id:"sess-1", project_key:"k"}'
  jq -nc --argjson ts "$((now_ts - 1800))" \
    '{_v:1, ts:$ts, gate:"advisory", event:"block", details:{}, session_id:"sess-2", project_key:"k"}'
} > "${QP}/gate_events.jsonl"

# Re-write session_summary so total_blocks=2 + skip_count=1 (1 false positive).
{
  jq -nc --argjson ts "${now_ts}" \
    '{session_id:"sess-1", start_ts:($ts|tostring), guard_blocks:1, dim_blocks:0, dispatches:1, skip_count:0, serendipity_count:0, reviewed:true, exhausted:false, outcome:"committed", domain:"coding", intent:"execution"}'
  jq -nc --argjson ts "${now_ts}" \
    '{session_id:"sess-2", start_ts:($ts|tostring), guard_blocks:1, dim_blocks:0, dispatches:1, skip_count:1, serendipity_count:0, reviewed:true, exhausted:false, outcome:"committed", domain:"coding", intent:"execution"}'
} > "${QP}/session_summary.jsonl"

out_share="$(HOME="${TEST_TMP}" bash "${SHOW_REPORT}" week --share 2>/dev/null || true)"
# Expected weighted seconds: 600 (delivery) + 240 (advisory) - 60 (1 skip) = 780s = 13m
if printf '%s' "${out_share}" | grep -qE "13m"; then
  ok
else
  printf '  share output: %s\n' "$(printf '%s' "${out_share}" | head -10)" >&2
  fail_msg "F-009: weighted time-saved should be ~13m (600+240-60=780s); not found in share output"
fi

# ----------------------------------------------------------------------
# F-010 — gate_events writer emits _v:1 schema version field.
# ----------------------------------------------------------------------
printf '\n--- F-010: cross-session JSONL writers emit _v:1 ---\n'

# Inspect the source — every cross-session emitter should write _v:1.
if grep -qE "_v:1.*ts.*gate.*event" "${COMMON_SH}"; then
  ok
else
  fail_msg "F-010: record_gate_event source missing _v:1 in row literal"
fi

if grep -qF "{_v:1, ts:" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-serendipity.sh"; then
  ok
else
  fail_msg "F-010: record-serendipity row missing _v:1"
fi

if grep -qF "{_v:1, ts:" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-archetype.sh"; then
  ok
else
  fail_msg "F-010: record-archetype row missing _v:1"
fi

if grep -qE "_v: 1" "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh"; then
  ok
else
  fail_msg "F-010: classifier_telemetry record missing _v:1"
fi

# Functional check — write a gate event and verify _v field is present.
TEST_STATE_ROOT="${TEST_TMP}/state"
mkdir -p "${TEST_STATE_ROOT}/test-session"
echo '{}' > "${TEST_STATE_ROOT}/test-session/session_state.json"

bash -c "
  set +e
  STATE_ROOT='${TEST_STATE_ROOT}'
  SESSION_ID='test-session'
  source '${COMMON_SH}'
  record_gate_event 'test-gate' 'block' 'detail=foo'
"

if [[ -f "${TEST_STATE_ROOT}/test-session/gate_events.jsonl" ]]; then
  emitted_v="$(jq -r '._v // empty' "${TEST_STATE_ROOT}/test-session/gate_events.jsonl" 2>/dev/null | head -1)"
  if [[ "${emitted_v}" == "1" ]]; then
    ok
  else
    fail_msg "F-010: emitted gate event missing _v=1 (got: ${emitted_v})"
  fi
else
  fail_msg "F-010: gate event was not written"
fi

# ----------------------------------------------------------------------
# F-006 — Directive value attribution joins bias-defense × session outcomes.
# ----------------------------------------------------------------------
printf '\n--- F-006: Directive value attribution section appears in /ulw-report ---\n'

# Synthesize bias-defense events for two directives across sessions.
rm -f "${QP}/gate_events.jsonl"
{
  for i in 1 2 3; do
    jq -nc --argjson ts "$((now_ts - i * 3600))" \
      --arg sid "f006-sess-$i" \
      '{_v:1, ts:$ts, gate:"bias-defense", event:"directive_fired", details:{directive:"intent-verify"}, session_id:$sid, project_key:"k"}'
  done
  for i in 1 2; do
    jq -nc --argjson ts "$((now_ts - i * 3600))" \
      --arg sid "f006-sess-$i" \
      '{_v:1, ts:$ts, gate:"bias-defense", event:"directive_fired", details:{directive:"divergence"}, session_id:$sid, project_key:"k"}'
  done
} > "${QP}/gate_events.jsonl"

{
  jq -nc --arg sid "f006-sess-1" --arg ts "${now_ts}" \
    '{session_id:$sid, start_ts:$ts, guard_blocks:0, dim_blocks:0, dispatches:0, skip_count:0, serendipity_count:0, reviewed:true, exhausted:false, outcome:"committed", domain:"coding", intent:"execution"}'
  jq -nc --arg sid "f006-sess-2" --arg ts "${now_ts}" \
    '{session_id:$sid, start_ts:$ts, guard_blocks:0, dim_blocks:0, dispatches:0, skip_count:0, serendipity_count:0, reviewed:false, exhausted:false, outcome:"abandoned", domain:"coding", intent:"execution"}'
  jq -nc --arg sid "f006-sess-3" --arg ts "${now_ts}" \
    '{session_id:$sid, start_ts:$ts, guard_blocks:0, dim_blocks:0, dispatches:0, skip_count:0, serendipity_count:0, reviewed:true, exhausted:false, outcome:"committed", domain:"coding", intent:"execution"}'
} > "${QP}/session_summary.jsonl"

out_dva="$(HOME="${TEST_TMP}" bash "${SHOW_REPORT}" week 2>/dev/null || true)"
if printf '%s' "${out_dva}" | grep -q "## Directive value attribution"; then
  ok
else
  fail_msg "F-006: 'Directive value attribution' section missing from /ulw-report"
fi

# intent-verify fires 3x: 2 committed, 1 abandoned → apply rate = 66%
if printf '%s' "${out_dva}" | grep -qE 'intent-verify.*66%|intent-verify.*\| 3 \|'; then
  ok
else
  fail_msg "F-006: intent-verify directive row missing or apply-rate wrong (expected 66%)"
fi

# ----------------------------------------------------------------------
# F-007 — Reviewer ROI section joins agent-metrics with timing rollup.
# ----------------------------------------------------------------------
printf '\n--- F-007: Reviewer ROI section appears with time-per-invocation ---\n'

# Synthesize agent-metrics with one reviewer
cat > "${QP}/agent-metrics.json" <<'EOF'
{
  "_schema_version": 2,
  "agents": {
    "quality-reviewer": {
      "invocations": 10,
      "clean_verdicts": 5,
      "finding_verdicts": 5,
      "last_used_ts": 0,
      "avg_confidence": 80
    }
  }
}
EOF

# Synthesize timing.jsonl rollup with agent_breakdown
echo "{\"ts\":${now_ts},\"session\":\"f007-sess\",\"project_key\":\"k\",\"walltime_s\":300,\"agent_total_s\":150,\"agent_breakdown\":{\"quality-reviewer\":150},\"agent_calls\":{\"quality-reviewer\":10},\"tool_total_s\":50,\"tool_breakdown\":{},\"tool_calls\":{},\"prompt_count\":1,\"directive_total_chars\":0,\"directive_count\":0}" > "${QP}/timing.jsonl"

out_roi="$(HOME="${TEST_TMP}" bash "${SHOW_REPORT}" all 2>/dev/null || true)"
if printf '%s' "${out_roi}" | grep -q "Reviewer ROI"; then
  ok
else
  fail_msg "F-007: Reviewer ROI section missing"
fi

# Avg/inv = 150 / 10 = 15s
if printf '%s' "${out_roi}" | grep -qE 'quality-reviewer.* 15s'; then
  ok
else
  printf '  ROI output snippet: %s\n' "$(printf '%s' "${out_roi}" | grep -A 2 'Reviewer ROI' | head -8)" >&2
  fail_msg "F-007: avg/inv should be 15s (150s / 10 inv); table row not found"
fi

# ----------------------------------------------------------------------
printf '\n=== Wave 2 telemetry tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
