#!/usr/bin/env bash
# test-ulw-report-outcomes.sh — v1.43 product-lens Wave 5 regression net.
#
# Pins the /ulw-report "Outcomes" section structure:
#   - Renders BEFORE the Headline section (so a vibe-coder reading
#     top-down sees value delivered first).
#   - Adapts the one-line summary to the data shape:
#     · zero sessions in window → invitation to try /ulw
#     · all-zero outcomes → "Clean shipping" reassurance
#     · any nonzero → comma-joined non-zero clauses
#   - Table rows always present (zero-valued rows show as "0", giving
#     the user the inventory).
#   - Outcome labels use user-facing language ("Premature stops
#     prevented", not "guard_blocks").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    needle=%q\n    haystack[0:300]=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

# Isolate HOME + STATE_ROOT so we don't read the developer's real data.
TEST_ROOT="$(mktemp -d)"
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.claude/quality-pack"
export STATE_ROOT="${TEST_ROOT}/state"
mkdir -p "${STATE_ROOT}"
cd "${TEST_ROOT}"

cleanup() { rm -rf "${TEST_ROOT}"; }
trap cleanup EXIT

SUMMARY="${HOME}/.claude/quality-pack/session_summary.jsonl"
MISFIRES="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"
GATE_EVENTS="${HOME}/.claude/quality-pack/gate_events.jsonl"

# ---------------------------------------------------------------
# O1: empty data → invitation message (no /ulw cycles yet)
# ---------------------------------------------------------------
: > "${SUMMARY}"
out="$(bash "${SHOW_REPORT}" all 2>&1)"
outcomes_section="$(printf '%s\n' "${out}" | sed -n '/^## Outcomes/,/^## Headline/p')"
assert_contains "O1a Outcomes heading present" "## Outcomes" "${outcomes_section}"
assert_contains "O1b zero-session invitation" "No /ulw cycles in window yet" "${outcomes_section}"
# Should NOT render the table when zero sessions.
if [[ "${outcomes_section}" == *"Premature stops prevented"* ]]; then
  printf '  FAIL: O1c zero-session render leaked table rows\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------
# O2: all-zero outcomes → "Clean shipping" reassurance
# ---------------------------------------------------------------
now_ts="$(date +%s)"
cat > "${SUMMARY}" <<EOF
{"session_id":"clean-1","start_ts":"$(( now_ts - 3600 ))","end_ts":null,"domain":"coding","intent":"execution","edit_count":0,"code_edits":0,"doc_edits":0,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"outcome":"released"}
EOF
out="$(bash "${SHOW_REPORT}" all 2>&1)"
outcomes_section="$(printf '%s\n' "${out}" | sed -n '/^## Outcomes/,/^## Headline/p')"
assert_contains "O2a clean-shipping when all-zero outcomes" "Clean shipping" "${outcomes_section}"
assert_contains "O2b session count surfaced in clean-shipping line" "1 session(s)" "${outcomes_section}"

# ---------------------------------------------------------------
# O3: non-zero outcomes → one-line summary with joined clauses + table
# ---------------------------------------------------------------
cat > "${SUMMARY}" <<EOF
{"session_id":"work-1","start_ts":"$(( now_ts - 3600 ))","end_ts":null,"domain":"coding","intent":"execution","edit_count":3,"code_edits":3,"doc_edits":0,"verified":true,"reviewed":true,"guard_blocks":2,"dim_blocks":1,"exhausted":false,"dispatches":5,"skip_count":0,"serendipity_count":1,"outcome":"completed","findings":{"total":4,"shipped":3,"deferred":0,"rejected":0,"pending":1}}
{"session_id":"work-2","start_ts":"$(( now_ts - 1800 ))","end_ts":null,"domain":"coding","intent":"execution","edit_count":1,"code_edits":1,"doc_edits":0,"verified":true,"reviewed":true,"guard_blocks":1,"dim_blocks":0,"exhausted":false,"dispatches":3,"skip_count":0,"serendipity_count":0,"outcome":"completed","findings":{"total":2,"shipped":2,"deferred":0,"rejected":0,"pending":0}}
EOF
out="$(bash "${SHOW_REPORT}" all 2>&1)"
outcomes_section="$(printf '%s\n' "${out}" | sed -n '/^## Outcomes/,/^## Headline/p')"
# Aggregated values: blocks = 2+1+1 = 4, serendipity = 1, findings.shipped = 3+2 = 5, dispatches = 5+3 = 8
assert_contains "O3a one-liner mentions premature stops" "prevented 4 premature stops" "${outcomes_section}"
assert_contains "O3b one-liner mentions Serendipity" "caught 1 adjacent bug via Serendipity Rule" "${outcomes_section}"
assert_contains "O3c one-liner mentions findings shipped" "shipped 5 wave-plan findings" "${outcomes_section}"
assert_contains "O3d table row premature stops = 4" "| Premature stops prevented | 4 |" "${outcomes_section}"
assert_contains "O3e table row Serendipity = 1" "Serendipity Rule) | 1 |" "${outcomes_section}"
assert_contains "O3f table row findings shipped = 5" "| Wave-plan findings shipped | 5 |" "${outcomes_section}"
assert_contains "O3g table row dispatches = 8" "| Specialist sub-agents dispatched | 8 |" "${outcomes_section}"

# ---------------------------------------------------------------
# O4: structural ordering — Outcomes MUST render BEFORE Headline
# ---------------------------------------------------------------
outcomes_line="$(printf '%s\n' "${out}" | grep -n '^## Outcomes' | head -1 | cut -d: -f1)"
headline_line="$(printf '%s\n' "${out}" | grep -n '^## Headline' | head -1 | cut -d: -f1)"
if [[ -n "${outcomes_line}" ]] && [[ -n "${headline_line}" ]] && [[ "${outcomes_line}" -lt "${headline_line}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: O4 Outcomes must precede Headline (got outcomes=%s, headline=%s)\n' "${outcomes_line:-missing}" "${headline_line:-missing}" >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------
# O5: classifier corrections aggregated from cross-session ledger
# ---------------------------------------------------------------
cat > "${MISFIRES}" <<EOF
{"ts":${now_ts},"session_id":"work-1","misfire":true,"corrected_by_user":true,"prior_intent":"advisory","corrected_intent":"execution","reason":"intent=execution"}
{"ts":${now_ts},"session_id":"work-2","misfire":true,"corrected_by_user":true,"prior_intent":"advisory","corrected_intent":"execution","reason":"intent=execution"}
EOF
out="$(bash "${SHOW_REPORT}" all 2>&1)"
outcomes_section="$(printf '%s\n' "${out}" | sed -n '/^## Outcomes/,/^## Headline/p')"
assert_contains "O5a corrections in table" "| Classifier corrections absorbed | 2 |" "${outcomes_section}"
assert_contains "O5b corrections in one-liner" "absorbed 2 classifier corrections" "${outcomes_section}"

# ---------------------------------------------------------------
# O6: corrections-only path also surfaces (no other nonzero outcomes)
# ---------------------------------------------------------------
cat > "${SUMMARY}" <<EOF
{"session_id":"clean-only","start_ts":"$(( now_ts - 600 ))","end_ts":null,"domain":"coding","intent":"execution","edit_count":0,"code_edits":0,"doc_edits":0,"verified":false,"reviewed":false,"guard_blocks":0,"dim_blocks":0,"exhausted":false,"dispatches":0,"skip_count":0,"serendipity_count":0,"outcome":"released"}
EOF
# MISFIRES file still carries 2 corrections.
out="$(bash "${SHOW_REPORT}" all 2>&1)"
outcomes_section="$(printf '%s\n' "${out}" | sed -n '/^## Outcomes/,/^## Headline/p')"
assert_contains "O6 corrections-only one-liner" "absorbed 2 classifier corrections" "${outcomes_section}"

printf '\nulw-report Outcomes tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
