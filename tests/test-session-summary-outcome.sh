#!/usr/bin/env bash
# test-session-summary-outcome.sh — v1.39.0 W1 regression net for the
# cross-session outcome label.
#
# Before v1.39.0 the daily sweep at common.sh:1540 defaulted
# `outcome` to bare "abandoned" whenever no Stop hook wrote
# `session_outcome`, which mislabeled every sweep-only session
# (rate-limit kill, /clear, native compact-quit, model crash) as if
# the user had abandoned the work. 348 of 418 historical rows were
# incorrectly labeled. The compound bug was that
# show-report.sh:1167 counted token "committed" for the apply-rate
# numerator, but the producer never emits that token — so the
# directive value attribution apply rate was structurally 0/N for
# every release that surfaced it.
#
# This test pins:
#   1. The sweep outcome inference (completed_inferred / idle /
#      unclassified_by_sweep) at common.sh:1540.
#   2. The token alignment in show-report.sh apply-rate aggregation —
#      "shipped" must count {completed, completed_inferred, released,
#      skip-released}, "dropped" must count {abandoned, exhausted,
#      unclassified_by_sweep}, "other" must absorb in-flight `active`
#      and zero-activity `idle` so they do not deflate the rate.
#   3. Lockstep — the inline jq patterns still exist in source.

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
# Part A: outcome inference (common.sh:1540)
# ---------------------------------------------------------------
#
# Mirror of the inline jq at common.sh:1540. The lockstep grep below
# fails the test if the inline form drifts from this fragment, so the
# two stay in sync.
OUTCOME_JQ='(
  if (.session_outcome // "") != "" then .session_outcome
  elif ((.last_review_ts // "") != "") and ((.last_verify_ts // "") != "") and (((.code_edit_count // "0") | tonumber) > 0) then "completed_inferred"
  elif (((.code_edit_count // "0") | tonumber) == 0) and ((.last_review_ts // "") == "") and ((.last_verify_ts // "") == "") then "idle"
  else "unclassified_by_sweep"
  end
)'

infer_outcome() {
  jq -r "${OUTCOME_JQ}" <<<"$1"
}

# A1: explicit session_outcome wins regardless of other signals
assert_eq "A1a explicit completed wins" "completed" \
  "$(infer_outcome '{"session_outcome":"completed","last_review_ts":"2026-01-01","code_edit_count":"5"}')"
assert_eq "A1b explicit released wins" "released" \
  "$(infer_outcome '{"session_outcome":"released"}')"
assert_eq "A1c explicit skip-released wins" "skip-released" \
  "$(infer_outcome '{"session_outcome":"skip-released"}')"
assert_eq "A1d explicit exhausted wins" "exhausted" \
  "$(infer_outcome '{"session_outcome":"exhausted","last_review_ts":"2026-01-01","code_edit_count":"7"}')"

# A2: empty string session_outcome falls through to inference
assert_eq "A2 empty session_outcome triggers inference" "completed_inferred" \
  "$(infer_outcome '{"session_outcome":"","last_review_ts":"2026-01-01","last_verify_ts":"2026-01-01","code_edit_count":"3"}')"

# A3: inferred-completed when reviewed AND verified AND code_edits>0
assert_eq "A3a inferred completed (reviewed+verified+edits)" "completed_inferred" \
  "$(infer_outcome '{"last_review_ts":"2026-01-01","last_verify_ts":"2026-01-01","code_edit_count":"3"}')"
assert_eq "A3b inferred completed (large edits)" "completed_inferred" \
  "$(infer_outcome '{"last_review_ts":"ts","last_verify_ts":"ts","code_edit_count":"42"}')"

# A4: idle when zero edits AND no review/verify
assert_eq "A4a idle (zero edits, all empty)" "idle" \
  "$(infer_outcome '{"code_edit_count":"0"}')"
assert_eq "A4b idle (empty object)" "idle" \
  "$(infer_outcome '{}')"

# A5: unclassified_by_sweep for everything in between
assert_eq "A5a unclassified (edits only, no review/verify)" "unclassified_by_sweep" \
  "$(infer_outcome '{"code_edit_count":"5"}')"
assert_eq "A5b unclassified (reviewed but no verify)" "unclassified_by_sweep" \
  "$(infer_outcome '{"last_review_ts":"2026-01-01","code_edit_count":"3"}')"
assert_eq "A5c unclassified (verified+reviewed but zero edits)" "unclassified_by_sweep" \
  "$(infer_outcome '{"last_verify_ts":"2026-01-01","last_review_ts":"2026-01-01","code_edit_count":"0"}')"
assert_eq "A5d unclassified (review without verify, edits>0)" "unclassified_by_sweep" \
  "$(infer_outcome '{"last_review_ts":"2026-01-01","code_edit_count":"2"}')"

# ---------------------------------------------------------------
# Part B: apply-rate aggregation tokens (show-report.sh:1150-1190)
# ---------------------------------------------------------------
#
# Verifies the directive-value-attribution aggregation buckets every
# producer-emitted outcome correctly. We feed a mix of session
# outcomes and assert the per-bucket counts + apply rate.

APPLY_RATE_JQ='
  group_by(.details.directive)
  | map({
      directive: .[0].details.directive,
      fires: length,
      sessions: (map(.session_id) | unique),
    })
  | map(. + {
      outcomes: (.sessions | map($outcomes[.] // "unknown"))
    })
  | map(. + {
      n_sessions: (.sessions | length),
      n_shipped: (.outcomes | map(select(. == "completed" or . == "completed_inferred" or . == "released" or . == "skip-released")) | length),
      n_dropped: (.outcomes | map(select(. == "abandoned" or . == "exhausted" or . == "unclassified_by_sweep")) | length),
      n_other: (.outcomes | map(select(. == "active" or . == "idle" or . == "unknown")) | length)
    })
  | .[]
'

# Build a session_id → outcome map that exercises every producer-emitted token
OUTCOMES_MAP='{"s-completed":"completed","s-inferred":"completed_inferred","s-released":"released","s-skip-released":"skip-released","s-abandoned":"abandoned","s-exhausted":"exhausted","s-unclassified":"unclassified_by_sweep","s-active":"active","s-idle":"idle"}'

# Fires: 9 rows, all directive=demo, one per session_id above
FIRES_NDJSON='{"gate":"bias-defense","event":"directive_fired","session_id":"s-completed","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-inferred","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-released","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-skip-released","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-abandoned","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-exhausted","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-unclassified","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-active","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-idle","details":{"directive":"demo"}}'

bucket="$(printf '%s\n' "${FIRES_NDJSON}" | jq -sr --argjson outcomes "${OUTCOMES_MAP}" "${APPLY_RATE_JQ}")"

# B1: shipped bucket counts all four success tokens
n_shipped="$(jq -r '.n_shipped' <<<"${bucket}")"
assert_eq "B1 n_shipped counts completed+completed_inferred+released+skip-released" "4" "${n_shipped}"

# B2: dropped bucket counts all three failure tokens
n_dropped="$(jq -r '.n_dropped' <<<"${bucket}")"
assert_eq "B2 n_dropped counts abandoned+exhausted+unclassified_by_sweep" "3" "${n_dropped}"

# B3: other bucket absorbs active + idle (and unknown)
n_other="$(jq -r '.n_other' <<<"${bucket}")"
assert_eq "B3 n_other counts active+idle" "2" "${n_other}"

# B4: apply rate = 4/7 = 57% (floor)
rate="$(jq -r 'if (.n_shipped + .n_dropped) > 0 then ((.n_shipped * 100 / (.n_shipped + .n_dropped)) | floor | tostring + "%") else "—" end' <<<"${bucket}")"
assert_eq "B4 apply rate 4/7 floor" "57%" "${rate}"

# B5: dash when both buckets empty (all sessions still active)
EMPTY_OUTCOMES='{"s-active1":"active","s-active2":"active"}'
EMPTY_FIRES='{"gate":"bias-defense","event":"directive_fired","session_id":"s-active1","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-active2","details":{"directive":"demo"}}'
bucket_empty="$(printf '%s\n' "${EMPTY_FIRES}" | jq -sr --argjson outcomes "${EMPTY_OUTCOMES}" "${APPLY_RATE_JQ}")"
rate_empty="$(jq -r 'if (.n_shipped + .n_dropped) > 0 then ((.n_shipped * 100 / (.n_shipped + .n_dropped)) | floor | tostring + "%") else "—" end' <<<"${bucket_empty}")"
assert_eq "B5 dash when no terminal outcomes in window" "—" "${rate_empty}"

# ---------------------------------------------------------------
# Part C: lockstep — the inline jq must still exist in source
# ---------------------------------------------------------------

if grep -q '"completed_inferred"' "${COMMON_SH}" \
   && grep -q '"unclassified_by_sweep"' "${COMMON_SH}" \
   && grep -q 'elif ((.last_review_ts // "") != "") and ((.last_verify_ts // "") != "")' "${COMMON_SH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: lockstep — outcome inference fragment missing from common.sh:1540\n' >&2
  fail=$((fail + 1))
fi

if grep -q 'n_shipped:' "${REPORT_SH}" \
   && grep -q 'n_dropped:' "${REPORT_SH}" \
   && grep -q '. == "completed" or . == "completed_inferred"' "${REPORT_SH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: lockstep — apply-rate token alignment missing from show-report.sh\n' >&2
  fail=$((fail + 1))
fi

# Negative lockstep: the prior bug tokens must NOT appear in the
# apply-rate jq block, or we silently regress.
if grep -E '^\s+n_committed:|^\s+n_abandoned:' "${REPORT_SH}" >/dev/null; then
  printf '  FAIL: negative lockstep — bug tokens n_committed/n_abandoned still present in show-report.sh\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf '\nSession-summary outcome tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
