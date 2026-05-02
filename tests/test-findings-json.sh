#!/usr/bin/env bash
# test-findings-json.sh — Wave 2 (v1.28.0) coverage for the
# FINDINGS_JSON reviewer contract.
#
# What this proves:
#   T1.  extract_findings_json — parses single-line JSON array, emits NDJSON
#   T2.  Empty / missing FINDINGS_JSON line returns nothing (fail-open)
#   T3.  Malformed JSON — fail-open, no throw, no rows emitted
#   T4.  Multiple FINDINGS_JSON lines — last one wins
#   T5.  Indented FINDINGS_JSON line (quoted excerpt) is skipped
#   T6.  count_findings_json — returns array length
#   T7.  normalize_finding_object — coerces severity / category to canonical
#   T8.  normalize — unknown severity defaults to medium
#   T9.  normalize — unknown category defaults to other
#   T10. normalize — line as string is coerced to int or null
#   T11. extract_discovered_findings prefers JSON path when present
#   T12. extract_discovered_findings falls through to prose when JSON missing
#   T13. extract_discovered_findings falls through when JSON is empty array
#   T14. JSON path produces stable ids (same input → same id)
#   T15. JSON path emits .structured field with full JSON payload
#   T16. JSON path summary format: [severity/category] claim @ file:line
#   T17. Long fields are truncated (claim ≤140, evidence ≤600)
#   T18. Reviewer agents document FINDINGS_JSON contract in their .md

set -euo pipefail

TEST_NAME="test-findings-json.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
    printf '         expected: %s\n         actual:   %s\n' "${expected}" "${actual}"
  fi
}

assert_true() {
  local cond="$1" msg="$2"
  if eval "${cond}"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
  fi
}

# Source common.sh so functions are available.
TEST_HOME="$(mktemp -d)"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
HOME="${TEST_HOME}" STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
export HOME STATE_ROOT
# shellcheck disable=SC1090
. "${COMMON_SH}"

# --- T1 ---
printf '\nT1: extract_findings_json parses single-line JSON array\n'
msg='Some prose

FINDINGS_JSON: [{"severity":"high","category":"bug","file":"a.ts","line":1,"claim":"x","evidence":"y","recommended_fix":"z"},{"severity":"medium","category":"docs","file":"","line":null,"claim":"q","evidence":"r","recommended_fix":"s"}]

VERDICT: FINDINGS (2)'
rows="$(extract_findings_json "${msg}")"
count="$(printf '%s\n' "${rows}" | grep -c severity || true)"
assert_eq "${count}" "2" "extract emits 2 NDJSON rows"

first_severity="$(printf '%s\n' "${rows}" | head -1 | jq -r '.severity')"
assert_eq "${first_severity}" "high" "first row severity preserved"

second_line_null="$(printf '%s\n' "${rows}" | sed -n '2p' | jq -r '.line')"
assert_eq "${second_line_null}" "null" "null line preserved as JSON null"

# --- T2 ---
printf '\nT2: empty / missing FINDINGS_JSON line returns nothing\n'
out="$(extract_findings_json "no findings json here")"
assert_eq "${out}" "" "empty when no FINDINGS_JSON line"
out="$(extract_findings_json "")"
assert_eq "${out}" "" "empty when message is empty"

# --- T3 ---
printf '\nT3: malformed JSON returns nothing (fail-open)\n'
out="$(extract_findings_json $'FINDINGS_JSON: [not valid json\nVERDICT: FINDINGS (1)' || true)"
assert_eq "${out}" "" "fail-open on malformed JSON"

# --- T4 ---
printf '\nT4: multiple FINDINGS_JSON lines — last one wins\n'
multi=$'FINDINGS_JSON: [{"severity":"low","category":"other","file":"a","line":1,"claim":"old","evidence":"e","recommended_fix":"f"}]\nSome more prose.\nFINDINGS_JSON: [{"severity":"high","category":"bug","file":"b","line":2,"claim":"new","evidence":"e","recommended_fix":"f"}]\nVERDICT: FINDINGS (1)'
rows="$(extract_findings_json "${multi}")"
claim="$(printf '%s' "${rows}" | head -1 | jq -r '.claim')"
assert_eq "${claim}" "new" "last FINDINGS_JSON line wins"

# --- T5 ---
printf '\nT5: indented FINDINGS_JSON line (quoted excerpt) is skipped\n'
indented=$'> FINDINGS_JSON: [{"severity":"high"}]\nFINDINGS_JSON: [{"severity":"low","category":"other","file":"","line":null,"claim":"real","evidence":"e","recommended_fix":"f"}]\nVERDICT: FINDINGS (1)'
rows="$(extract_findings_json "${indented}")"
claim="$(printf '%s' "${rows}" | head -1 | jq -r '.claim')"
assert_eq "${claim}" "real" "unindented line is selected, quoted excerpt skipped"

# --- T6 ---
printf '\nT6: count_findings_json returns array length\n'
n="$(count_findings_json "${msg}")"
assert_eq "${n}" "2" "count returns 2"
n="$(count_findings_json "no json")"
assert_eq "${n}" "" "count empty when no FINDINGS_JSON"

# --- T7 ---
printf '\nT7: normalize_finding_object preserves canonical fields\n'
row='{"severity":"HIGH","category":"BUG","file":"f.ts","line":42,"claim":"c","evidence":"e","recommended_fix":"r"}'
norm="$(normalize_finding_object "${row}")"
sev="$(printf '%s' "${norm}" | jq -r '.severity')"
cat="$(printf '%s' "${norm}" | jq -r '.category')"
assert_eq "${sev}" "high" "severity lowercased"
assert_eq "${cat}" "bug" "category lowercased"

# --- T8 ---
printf '\nT8: unknown severity defaults to medium\n'
row='{"severity":"weird","category":"bug","file":"f","line":1,"claim":"c","evidence":"e","recommended_fix":"r"}'
sev="$(normalize_finding_object "${row}" | jq -r '.severity')"
assert_eq "${sev}" "medium" "unknown severity → medium"
# Aliases — critical / p0 / blocker → high
row='{"severity":"critical","category":"bug","file":"f","line":1,"claim":"c","evidence":"e","recommended_fix":"r"}'
sev="$(normalize_finding_object "${row}" | jq -r '.severity')"
assert_eq "${sev}" "high" "critical aliases to high"
row='{"severity":"p1","category":"bug","file":"f","line":1,"claim":"c","evidence":"e","recommended_fix":"r"}'
sev="$(normalize_finding_object "${row}" | jq -r '.severity')"
assert_eq "${sev}" "medium" "p1 aliases to medium"

# --- T9 ---
printf '\nT9: unknown category defaults to other\n'
row='{"severity":"high","category":"weird","file":"f","line":1,"claim":"c","evidence":"e","recommended_fix":"r"}'
cat="$(normalize_finding_object "${row}" | jq -r '.category')"
assert_eq "${cat}" "other" "unknown category → other"

# --- T10 ---
printf '\nT10: line coercion\n'
row='{"severity":"high","category":"bug","file":"f","line":"42","claim":"c","evidence":"e","recommended_fix":"r"}'
ln="$(normalize_finding_object "${row}" | jq -r '.line')"
assert_eq "${ln}" "42" "line as string coerced to int"
row='{"severity":"high","category":"bug","file":"f","line":"not-a-num","claim":"c","evidence":"e","recommended_fix":"r"}'
ln="$(normalize_finding_object "${row}" | jq -r '.line')"
assert_eq "${ln}" "null" "non-numeric line coerced to null"

# --- T11 ---
printf '\nT11: extract_discovered_findings prefers JSON path\n'
msg='Some prose findings.

1. heuristic finding 1
2. heuristic finding 2

FINDINGS_JSON: [{"severity":"high","category":"bug","file":"a.ts","line":1,"claim":"json win","evidence":"e","recommended_fix":"r"}]

VERDICT: FINDINGS (1)'
rows="$(extract_discovered_findings "quality-reviewer" "${msg}")"
n="$(printf '%s\n' "${rows}" | grep -c source || true)"
assert_eq "${n}" "1" "JSON path emits exactly 1 row (not 2 from heuristic)"
sum="$(printf '%s\n' "${rows}" | head -1 | jq -r '.summary')"
assert_true "[[ '${sum}' == *'json win'* ]]" "summary contains 'json win'"
assert_true "[[ '${sum}' == *'high/bug'* ]]" "summary contains '[high/bug]' tag"

# --- T12 ---
printf '\nT12: prose fallback when JSON missing\n'
msg='## Findings

1. The auth middleware fails on token expiry — high severity bug
2. Database queries lack indexing — medium

VERDICT: FINDINGS (2)'
rows="$(extract_discovered_findings "quality-reviewer" "${msg}")"
n="$(printf '%s\n' "${rows}" | grep -c source || true)"
assert_eq "${n}" "2" "prose path emits 2 rows when no JSON"

# --- T13 ---
printf '\nT13: empty JSON array — falls through to prose\n'
msg='## Findings

1. The auth middleware fails on token expiry — high

FINDINGS_JSON: []

VERDICT: FINDINGS (1)'
rows="$(extract_discovered_findings "quality-reviewer" "${msg}")"
# Empty JSON should fall through to prose
n="$(printf '%s\n' "${rows}" | grep -c source || true)"
assert_eq "${n}" "1" "empty JSON falls through to prose (1 row from prose)"

# --- T14 ---
printf '\nT14: JSON path produces stable ids\n'
msg='FINDINGS_JSON: [{"severity":"high","category":"bug","file":"a.ts","line":1,"claim":"x","evidence":"e","recommended_fix":"r"}]

VERDICT: FINDINGS (1)'
id1="$(extract_discovered_findings "quality-reviewer" "${msg}" | jq -r '.id')"
id2="$(extract_discovered_findings "quality-reviewer" "${msg}" | jq -r '.id')"
assert_eq "${id1}" "${id2}" "id is stable across invocations"
assert_true "[[ -n '${id1}' && \${#id1} -eq 12 ]]" "id is 12 hex chars"

# --- T15 ---
printf '\nT15: JSON path emits .structured field\n'
msg='FINDINGS_JSON: [{"severity":"high","category":"bug","file":"a.ts","line":42,"claim":"x","evidence":"why","recommended_fix":"how"}]

VERDICT: FINDINGS (1)'
rows="$(extract_discovered_findings "quality-reviewer" "${msg}")"
struct_evidence="$(printf '%s' "${rows}" | jq -r '.structured.evidence')"
struct_fix="$(printf '%s' "${rows}" | jq -r '.structured.recommended_fix')"
assert_eq "${struct_evidence}" "why" ".structured.evidence preserved"
assert_eq "${struct_fix}" "how" ".structured.recommended_fix preserved"

# --- T16 ---
printf '\nT16: JSON path summary format\n'
msg='FINDINGS_JSON: [{"severity":"high","category":"bug","file":"a.ts","line":42,"claim":"Token expiry","evidence":"e","recommended_fix":"r"}]

VERDICT: FINDINGS (1)'
sum="$(extract_discovered_findings "quality-reviewer" "${msg}" | jq -r '.summary')"
assert_eq "${sum}" "[high/bug] Token expiry @ a.ts:42" "summary follows expected shape"

msg2='FINDINGS_JSON: [{"severity":"medium","category":"docs","file":"","line":null,"claim":"missing readme","evidence":"e","recommended_fix":"r"}]

VERDICT: FINDINGS (1)'
sum="$(extract_discovered_findings "quality-reviewer" "${msg2}" | jq -r '.summary')"
assert_eq "${sum}" "[medium/docs] missing readme" "summary handles empty file/null line"

# --- T17 ---
printf '\nT17: long fields are truncated\n'
long_claim="$(printf 'x%.0s' {1..200})"
long_evidence="$(printf 'y%.0s' {1..1000})"
msg="FINDINGS_JSON: [{\"severity\":\"high\",\"category\":\"bug\",\"file\":\"a.ts\",\"line\":1,\"claim\":\"${long_claim}\",\"evidence\":\"${long_evidence}\",\"recommended_fix\":\"r\"}]

VERDICT: FINDINGS (1)"
norm="$(extract_findings_json "${msg}" | head -1 | normalize_finding_object "$(cat)" 2>/dev/null || true)"
# Normalize directly via stdin
normalized="$(extract_findings_json "${msg}" | head -1)"
norm_out="$(normalize_finding_object "${normalized}")"
claim_len="$(printf '%s' "${norm_out}" | jq -r '.claim | length')"
ev_len="$(printf '%s' "${norm_out}" | jq -r '.evidence | length')"
assert_true "[[ ${claim_len} -le 140 ]]" "claim truncated to ≤140 (got ${claim_len})"
assert_true "[[ ${ev_len} -le 600 ]]" "evidence truncated to ≤600 (got ${ev_len})"

# --- T18a (Serendipity Rule fix, v1.28.0) ---
printf '\nT18a: FINDINGS_JSON inside fenced code block is ignored\n'
fenced_msg=$'Real findings prose.\n\n```\nFINDINGS_JSON: [{"severity":"high","category":"bug","file":"phantom.ts","line":1,"claim":"PHANTOM","evidence":"e","recommended_fix":"f"}]\n```\n\nVERDICT: CLEAN'
out="$(extract_findings_json "${fenced_msg}")"
assert_eq "${out}" "" "fenced FINDINGS_JSON not extracted (phantom-finding fix)"
n="$(count_findings_json "${fenced_msg}")"
assert_eq "${n}" "" "count returns empty when only fenced match exists"

printf '\nT18b: real FINDINGS_JSON outside fences still works alongside fenced example\n'
mixed_msg=$'Example block (not real):\n\n```\nFINDINGS_JSON: [{"severity":"low","category":"other","file":"x","line":1,"claim":"PHANTOM","evidence":"e","recommended_fix":"f"}]\n```\n\nFINDINGS_JSON: [{"severity":"high","category":"bug","file":"r.ts","line":42,"claim":"REAL","evidence":"e","recommended_fix":"f"}]\n\nVERDICT: FINDINGS (1)'
out="$(extract_findings_json "${mixed_msg}" | head -1 | jq -r '.claim')"
assert_eq "${out}" "REAL" "real finding extracted; phantom dropped"

printf '\nT18c: FINDINGS_JSON without `[` (prose mention) is ignored\n'
prose_msg=$'The reviewer should emit a FINDINGS_JSON: line.\n\nVERDICT: CLEAN'
out="$(extract_findings_json "${prose_msg}")"
assert_eq "${out}" "" "prose mention without [ is not extracted"

# --- T18 ---
printf '\nT18: reviewer agents document FINDINGS_JSON contract\n'
for agent in quality-reviewer excellence-reviewer oracle abstraction-critic metis design-reviewer briefing-analyst; do
  agent_md="${REPO_ROOT}/bundle/dot-claude/agents/${agent}.md"
  if [[ ! -f "${agent_md}" ]]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s.md missing\n' "${agent}"
    continue
  fi
  if grep -q 'FINDINGS_JSON:' "${agent_md}"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s.md documents FINDINGS_JSON\n' "${agent}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s.md missing FINDINGS_JSON contract\n' "${agent}"
  fi
done

rm -rf "${TEST_HOME}"

printf '\n%s\n' "--------------------------------------------------------------------------------"
printf 'Results: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '%s\n' "--------------------------------------------------------------------------------"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
