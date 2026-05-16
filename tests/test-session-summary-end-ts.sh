#!/usr/bin/env bash
# test-session-summary-end-ts.sh — v1.41 W1 regression net for the
# end_ts cascade and end_ts_source label.
#
# Pre-v1.41 the cross-session ledger writer at common.sh:1592 used
#   end_ts: (.last_edit_ts // .last_review_ts // null)
# which produced `end_ts: null` for every advisory / exploratory /
# prompt-only session that ran no edit and no review. A 248-session
# telemetry audit found 66% of rows carried null end_ts — making the
# ledger structurally blind to advisory-work duration.
#
# v1.41 W1 extends the cascade to .last_user_prompt_ts as a third
# fallback and adds an `end_ts_source` field ("edit"/"review"/"prompt"
# or null) so downstream readers can filter by signal strength when
# they want edit-or-review-grade duration only.
#
# This test pins:
#   1. The end_ts cascade priority: edit > review > prompt > null.
#   2. The end_ts_source label matches whichever fallback fired.
#   3. Empty-string fields fall through correctly (jq `// X` keeps
#      "" so the explicit `(.x // "") != ""` guard is required).
#   4. Lockstep — both common.sh (the daily sweep) and show-report.sh
#      (the --sweep in-memory join) carry identical inline jq blocks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
REPORT_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"

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

# ---------------------------------------------------------------
# Part A: end_ts cascade priority
# ---------------------------------------------------------------
#
# Mirror of the inline jq at common.sh:1592 / show-report.sh:207.
# Trailing comma omitted so the fragment evaluates as a standalone
# object via jq.

END_TS_JQ='{
  end_ts: (
    if   ((.last_edit_ts // "")        != "") then .last_edit_ts
    elif ((.last_review_ts // "")      != "") then .last_review_ts
    elif ((.last_user_prompt_ts // "") != "") then .last_user_prompt_ts
    else null
    end
  ),
  end_ts_source: (
    if   ((.last_edit_ts // "")        != "") then "edit"
    elif ((.last_review_ts // "")      != "") then "review"
    elif ((.last_user_prompt_ts // "") != "") then "prompt"
    else null
    end
  )
}'

infer() {
  jq -c "${END_TS_JQ}" <<<"$1"
}

# A1: all three present — edit wins
assert_eq "A1 edit wins when all three present" \
  '{"end_ts":"1000","end_ts_source":"edit"}' \
  "$(infer '{"last_edit_ts":"1000","last_review_ts":"2000","last_user_prompt_ts":"3000"}')"

# A2: edit absent, review wins
assert_eq "A2 review wins when edit absent" \
  '{"end_ts":"2000","end_ts_source":"review"}' \
  "$(infer '{"last_review_ts":"2000","last_user_prompt_ts":"3000"}')"

# A3: edit + review absent, prompt fallback fires
assert_eq "A3 prompt fallback fires (advisory session)" \
  '{"end_ts":"3000","end_ts_source":"prompt"}' \
  "$(infer '{"last_user_prompt_ts":"3000"}')"

# A4: all absent — null
assert_eq "A4 all absent yields null" \
  '{"end_ts":null,"end_ts_source":null}' \
  "$(infer '{}')"

# A5: empty-string fields fall through (jq's // doesn't catch "")
assert_eq "A5a empty edit falls through to review" \
  '{"end_ts":"2000","end_ts_source":"review"}' \
  "$(infer '{"last_edit_ts":"","last_review_ts":"2000"}')"

assert_eq "A5b empty edit + empty review falls through to prompt" \
  '{"end_ts":"3000","end_ts_source":"prompt"}' \
  "$(infer '{"last_edit_ts":"","last_review_ts":"","last_user_prompt_ts":"3000"}')"

assert_eq "A5c all empty strings yields null end_ts and null source" \
  '{"end_ts":null,"end_ts_source":null}' \
  "$(infer '{"last_edit_ts":"","last_review_ts":"","last_user_prompt_ts":""}')"

# A6: realistic mid-session-killed advisory session — no edit, no review,
#     one prompt arrived (the user typed before the rate limit fired).
ADVISORY_FIXTURE='{
  "project_key":"abc123",
  "session_start_ts":"1777000000",
  "last_user_prompt_ts":"1777003600",
  "task_intent":"advisory",
  "task_domain":"mixed"
}'
assert_eq "A6 advisory session gets prompt-grade end_ts" \
  '{"end_ts":"1777003600","end_ts_source":"prompt"}' \
  "$(infer "${ADVISORY_FIXTURE}")"

# A7: realistic completed coding session — edit beats review, both present
CODING_FIXTURE='{
  "session_start_ts":"1777000000",
  "last_user_prompt_ts":"1777000100",
  "last_review_ts":"1777003500",
  "last_edit_ts":"1777003600",
  "code_edit_count":"5"
}'
assert_eq "A7 coding session gets edit-grade end_ts" \
  '{"end_ts":"1777003600","end_ts_source":"edit"}' \
  "$(infer "${CODING_FIXTURE}")"

# ---------------------------------------------------------------
# Part B: lockstep — inline jq in both writers matches the test reference
# ---------------------------------------------------------------
#
# Both common.sh (sweep_stale_sessions) and show-report.sh (--sweep
# in-memory merge) must carry the same end_ts cascade. If a future edit
# touches one without the other, the cross-session ledger and the live
# `/ulw-report --sweep` view will disagree silently. Catch that here.

assert_contains_pattern() {
  local label="$1" path="$2" pattern="$3"
  if grep -qE "${pattern}" "${path}" 2>/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    pattern=%s\n    path=%s\n' "${label}" "${pattern}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

# Both files carry the if/elif end_ts cascade (three branches over
# .last_edit_ts / .last_review_ts / .last_user_prompt_ts).
assert_contains_pattern "B1a common.sh end_ts edit branch" "${COMMON_SH}" 'then \.last_edit_ts'
assert_contains_pattern "B1b common.sh end_ts review branch" "${COMMON_SH}" 'then \.last_review_ts'
assert_contains_pattern "B1c common.sh end_ts prompt branch" "${COMMON_SH}" 'then \.last_user_prompt_ts'
assert_contains_pattern "B2a show-report.sh end_ts edit branch" "${REPORT_SH}" 'then \.last_edit_ts'
assert_contains_pattern "B2b show-report.sh end_ts review branch" "${REPORT_SH}" 'then \.last_review_ts'
assert_contains_pattern "B2c show-report.sh end_ts prompt branch" "${REPORT_SH}" 'then \.last_user_prompt_ts'

# Both files carry the end_ts_source label block.
SOURCE_PATTERN='end_ts_source:'
assert_contains_pattern "B3 common.sh end_ts_source present" "${COMMON_SH}" "${SOURCE_PATTERN}"
assert_contains_pattern "B4 show-report.sh end_ts_source present" "${REPORT_SH}" "${SOURCE_PATTERN}"

# Both files agree on the "edit" / "review" / "prompt" labels (not
# accidentally renamed in one site).
for label in edit review prompt; do
  assert_contains_pattern "B5 common.sh has \"${label}\" label" "${COMMON_SH}" "then \"${label}\""
  assert_contains_pattern "B6 show-report.sh has \"${label}\" label" "${REPORT_SH}" "then \"${label}\""
done

# ---------------------------------------------------------------
# Part C: sibling booleans — verified / reviewed / exhausted
# ---------------------------------------------------------------
#
# v1.41 W1 Serendipity-Rule fix: the same `if .x then true else false end`
# shape that broke end_ts on empty strings ALSO infected the verified /
# reviewed / exhausted booleans in the same jq block. A session whose
# last_review_ts was ever written as "" (rare but the same write-path
# that produced empty end_ts) used to report `reviewed:true`. Tightened
# to `((.x // "") != "")` — matches the existing pattern in show-status.sh
# and outcome:.

BOOLS_JQ='{
  verified:  ((.last_verify_ts // "") != ""),
  reviewed:  ((.last_review_ts // "") != ""),
  exhausted: ((.guard_exhausted // "") != "")
}'

infer_bools() {
  jq -c "${BOOLS_JQ}" <<<"$1"
}

# C1: all unset → all false
assert_eq "C1 all unset booleans false" \
  '{"verified":false,"reviewed":false,"exhausted":false}' \
  "$(infer_bools '{}')"

# C2: all empty strings → all false (the pre-fix bug)
assert_eq "C2 empty-string booleans false (post-fix)" \
  '{"verified":false,"reviewed":false,"exhausted":false}' \
  "$(infer_bools '{"last_verify_ts":"","last_review_ts":"","guard_exhausted":""}')"

# C3: real timestamp values → true
assert_eq "C3 set timestamps yield true" \
  '{"verified":true,"reviewed":true,"exhausted":true}' \
  "$(infer_bools '{"last_verify_ts":"1777000000","last_review_ts":"1777000100","guard_exhausted":"1777000200"}')"

# C4: mixed — verified set, others empty
assert_eq "C4 mixed booleans" \
  '{"verified":true,"reviewed":false,"exhausted":false}' \
  "$(infer_bools '{"last_verify_ts":"1777000000","last_review_ts":""}')"

# C5: lockstep — both writers carry the tightened boolean form
assert_contains_pattern "C5a common.sh verified tightened" "${COMMON_SH}" \
  'verified: \(\(.last_verify_ts // ""\) != ""\)'
assert_contains_pattern "C5b common.sh reviewed tightened" "${COMMON_SH}" \
  'reviewed: \(\(.last_review_ts // ""\) != ""\)'
assert_contains_pattern "C5c common.sh exhausted tightened" "${COMMON_SH}" \
  'exhausted: \(\(.guard_exhausted // ""\) != ""\)'
assert_contains_pattern "C5d show-report.sh verified tightened" "${REPORT_SH}" \
  'verified: \(\(.last_verify_ts // ""\) != ""\)'
assert_contains_pattern "C5e show-report.sh reviewed tightened" "${REPORT_SH}" \
  'reviewed: \(\(.last_review_ts // ""\) != ""\)'
assert_contains_pattern "C5f show-report.sh exhausted tightened" "${REPORT_SH}" \
  'exhausted: \(\(.guard_exhausted // ""\) != ""\)'

# C6: anti-pattern guard — the OLD buggy form must NOT appear anywhere in
# either writer. Catches a future "simplification" that reintroduces it.
assert_old_form_absent() {
  local label="$1" path="$2"
  if grep -E 'if \.(last_verify_ts|last_review_ts|guard_exhausted) then true else false end' "${path}" >/dev/null 2>&1; then
    printf '  FAIL: %s\n    old buggy form found in %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}
assert_old_form_absent "C6a common.sh old buggy form absent" "${COMMON_SH}"
assert_old_form_absent "C6b show-report.sh old buggy form absent" "${REPORT_SH}"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
total=$((pass + fail))
printf '\n%s: %d passed, %d failed (of %d)\n' \
  "$(basename "$0")" "${pass}" "${fail}" "${total}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
