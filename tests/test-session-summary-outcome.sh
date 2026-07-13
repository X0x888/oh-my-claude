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
OUTCOME_JQ='def has_code_edits:
  (((.code_edit_count // "0") | tonumber) > 0)
  or ((.bash_unknown_edit_scope // "") == "1");
(
  if (.session_outcome // "") != "" then .session_outcome
  elif ((.last_review_ts // "") != "") and ((.last_verify_ts // "") != "") and has_code_edits then "completed_inferred"
  elif has_code_edits and (((.last_review_ts // "") != "") or ((.last_verify_ts // "") != "")) then "completed_inferred_partial"
  elif has_code_edits then "edited_no_quality"
  elif (has_code_edits | not) and ((.last_review_ts // "") == "") and ((.last_verify_ts // "") == "") then "idle"
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

# A5: unclassified_by_sweep — only when verified+reviewed BUT zero edits
# (real-world: reviewer ran on an empty/no-change branch; that's not idle
# nor edited, so the bucket name stays).
assert_eq "A5 unclassified (verified+reviewed but zero edits)" "unclassified_by_sweep" \
  "$(infer_outcome '{"last_verify_ts":"2026-01-01","last_review_ts":"2026-01-01","code_edit_count":"0"}')"

# v1.43 data-lens F-001 — new buckets

# A6: completed_inferred_partial — edits + ONE quality step.
# These rows previously fell to unclassified_by_sweep (poisoning
# n_shipped) — now correctly counted as shipped.
assert_eq "A6a partial (edits + review, no verify)" "completed_inferred_partial" \
  "$(infer_outcome '{"last_review_ts":"2026-01-01","code_edit_count":"3"}')"
assert_eq "A6b partial (edits + verify, no review)" "completed_inferred_partial" \
  "$(infer_outcome '{"last_verify_ts":"2026-01-01","code_edit_count":"4"}')"

# A7: edited_no_quality — edits but neither review nor verify fired.
# These rows previously fell to unclassified_by_sweep (counted as
# dropped) — now surfaced separately as a "shipping unknown, quality
# concern" bucket; excluded from both n_shipped AND n_dropped.
assert_eq "A7a edited_no_quality (edits only)" "edited_no_quality" \
  "$(infer_outcome '{"code_edit_count":"5"}')"
assert_eq "A7b edited_no_quality (large edits, no quality)" "edited_no_quality" \
  "$(infer_outcome '{"code_edit_count":"42"}')"

# Bash mutations have no authoritative exact path/count. The explicit unknown
# scope bit is still an edit signal for outcome attribution; otherwise a real
# Bash-only change is mislabeled idle merely because code_edit_count stays 0.
assert_eq "A8a Bash-only unknown scope is edited_no_quality, not idle" "edited_no_quality" \
  "$(infer_outcome '{"code_edit_count":"0","bash_unknown_edit_scope":"1"}')"
assert_eq "A8b reviewed+verified Bash-only scope is completed_inferred" "completed_inferred" \
  "$(infer_outcome '{"code_edit_count":"0","bash_unknown_edit_scope":"1","last_review_ts":"ts","last_verify_ts":"ts"}')"

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
      n_shipped: (.outcomes | map(select(. == "completed" or . == "completed_inferred" or . == "completed_inferred_partial" or . == "released" or . == "skip-released")) | length),
      n_dropped: (.outcomes | map(select(. == "abandoned" or . == "exhausted" or . == "unclassified_by_sweep")) | length),
      n_other: (.outcomes | map(select(. == "active" or . == "idle" or . == "edited_no_quality" or . == "unknown")) | length)
    })
  | .[]
'

# Build a session_id → outcome map that exercises every producer-emitted
# token, including the v1.43 additions (completed_inferred_partial,
# edited_no_quality).
OUTCOMES_MAP='{"s-completed":"completed","s-inferred":"completed_inferred","s-partial":"completed_inferred_partial","s-released":"released","s-skip-released":"skip-released","s-abandoned":"abandoned","s-exhausted":"exhausted","s-unclassified":"unclassified_by_sweep","s-active":"active","s-idle":"idle","s-edited-noq":"edited_no_quality"}'

# Fires: 11 rows, all directive=demo, one per session_id above
FIRES_NDJSON='{"gate":"bias-defense","event":"directive_fired","session_id":"s-completed","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-inferred","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-partial","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-released","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-skip-released","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-abandoned","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-exhausted","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-unclassified","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-active","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-idle","details":{"directive":"demo"}}
{"gate":"bias-defense","event":"directive_fired","session_id":"s-edited-noq","details":{"directive":"demo"}}'

bucket="$(printf '%s\n' "${FIRES_NDJSON}" | jq -sr --argjson outcomes "${OUTCOMES_MAP}" "${APPLY_RATE_JQ}")"

# B1: shipped bucket counts all FIVE success tokens
n_shipped="$(jq -r '.n_shipped' <<<"${bucket}")"
assert_eq "B1 n_shipped counts completed+completed_inferred+completed_inferred_partial+released+skip-released" "5" "${n_shipped}"

# B2: dropped bucket counts the three failure tokens (unchanged)
n_dropped="$(jq -r '.n_dropped' <<<"${bucket}")"
assert_eq "B2 n_dropped counts abandoned+exhausted+unclassified_by_sweep" "3" "${n_dropped}"

# B3: other bucket absorbs active + idle + edited_no_quality (and unknown)
n_other="$(jq -r '.n_other' <<<"${bucket}")"
assert_eq "B3 n_other counts active+idle+edited_no_quality" "3" "${n_other}"

# B4: apply rate = 5/8 = 62% (floor)
rate="$(jq -r 'if (.n_shipped + .n_dropped) > 0 then ((.n_shipped * 100 / (.n_shipped + .n_dropped)) | floor | tostring + "%") else "—" end' <<<"${bucket}")"
assert_eq "B4 apply rate 5/8 floor" "62%" "${rate}"

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
   && grep -q '"completed_inferred_partial"' "${COMMON_SH}" \
   && grep -q '"edited_no_quality"' "${COMMON_SH}" \
   && grep -q '"unclassified_by_sweep"' "${COMMON_SH}" \
   && grep -q 'or ((.bash_unknown_edit_scope // "") == "1")' "${COMMON_SH}" \
   && grep -q 'elif ((.last_review_ts // "") != "") and ((.last_verify_ts // "") != "")' "${COMMON_SH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: lockstep — outcome inference fragment (three-tier ladder) missing from common.sh:1540\n' >&2
  fail=$((fail + 1))
fi

if grep -q 'n_shipped:' "${REPORT_SH}" \
   && grep -q 'n_dropped:' "${REPORT_SH}" \
   && grep -q '. == "completed_inferred_partial"' "${REPORT_SH}" \
   && grep -q '. == "edited_no_quality"' "${REPORT_SH}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: lockstep — apply-rate token alignment (new buckets) missing from show-report.sh\n' >&2
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

# ---------------------------------------------------------------
# Part D: real stale-session sweep row for Bash-only unknown scope
# ---------------------------------------------------------------

SWEEP_HOME="$(mktemp -d)"
sweep_rows="$(HOME="${SWEEP_HOME}" OMC_STATE_TTL_DAYS=1 bash -c '
  set -euo pipefail
  export OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1
  . "'"${COMMON_SH}"'"
  root="${HOME}/.claude/quality-pack/state"
  mkdir -p "${root}/bash-noq" "${root}/bash-complete"
  printf '\''%s\n'\'' '\''{"session_start_ts":"1","last_edit_ts":"2","code_edit_count":"0","bash_unknown_edit_scope":"1"}'\'' > "${root}/bash-noq/session_state.json"
  printf '\''%s\n'\'' '\''{"session_start_ts":"1","last_edit_ts":"2","last_review_ts":"3","last_verify_ts":"4","code_edit_count":"0","bash_unknown_edit_scope":"1"}'\'' > "${root}/bash-complete/session_state.json"
  touch -t 202001010000 "${root}/bash-noq" "${root}/bash-complete"
  rm -f "${root}/.last_sweep"
  _sweep_stale_sessions_locked
  cat "${HOME}/.claude/quality-pack/session_summary.jsonl"
')"
assert_eq "D1 real sweep emits unknown-scope boolean" "true" \
  "$(jq -sr 'map(select(.session_id == "bash-noq"))[0].bash_unknown_edit_scope' <<<"${sweep_rows}")"
assert_eq "D2 real sweep classifies Bash-only edit without quality" "edited_no_quality" \
  "$(jq -sr 'map(select(.session_id == "bash-noq"))[0].outcome' <<<"${sweep_rows}")"
assert_eq "D3 real sweep classifies reviewed+verified Bash-only edit" "completed_inferred" \
  "$(jq -sr 'map(select(.session_id == "bash-complete"))[0].outcome' <<<"${sweep_rows}")"
rm -rf "${SWEEP_HOME}"

printf '\nSession-summary outcome tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
