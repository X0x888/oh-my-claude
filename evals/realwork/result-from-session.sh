#!/usr/bin/env bash
#
# evals/realwork/result-from-session.sh — synthesize a scorable result
# JSON from a real ULW session's telemetry.
#
# v1.39.0 W3 closes the gap the council audit flagged: evals/realwork
# was contract-only (run.sh score consumed a JSON shape no script
# produced). Without a producer, the scoring layer was tested against
# hand-written fixtures — not against actual harness behavior.
#
# This script reads:
#   - <session>/session_state.json    (verify, review, edits, contract)
#   - <session>/timing.jsonl          (elapsed, tool count, char total)
#   - <session>/findings.json         (wave plan, finding statuses)
#   - <session>/edited_files.log      (touched paths)
#
# And emits stdout JSON conforming to run.sh's `score` input:
#   {
#     "scenario_id": "<id from --scenario>",
#     "tokens":           <approx via directive chars / 4>,
#     "tool_calls":       <count of timing.jsonl tool starts>,
#     "elapsed_seconds":  <last activity ts - session start ts>,
#     "outcomes": { <key>: <bool>, ... }
#   }
#
# Outcome keys covered (matched against the three shipped scenarios
# targeted-bugfix / ui-shipping / broad-project-eval, and a small set
# of generic signals likely to recur):
#   tests_passed                       targeted_verification
#   full_verification                  review_clean
#   regression_test_added              final_closeout_audit_ready
#   design_contract_recorded           ui_files_changed
#   browser_or_visual_verification     design_review_clean
#   no_layout_overlap                  council_or_lens_coverage
#   wave_plan_recorded                 findings_resolved_or_deferred_with_why
#   token_budget_respected
#
# Unknown outcome keys (scenarios that mention something this script
# doesn't detect) are emitted as `false`, which the scoring layer
# treats as missing — visible in the score output and audit-trail-
# friendly.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: result-from-session.sh --scenario <id> [--session <sid>] [--state-root <dir>]

  --scenario <id>     Scenario id to attribute the result to (required).
  --session <sid>     Session id to read. Defaults to most-recently-
                      modified directory under STATE_ROOT.
  --state-root <dir>  STATE_ROOT override. Defaults to env STATE_ROOT
                      or ~/.claude/quality-pack/state.
  -h, --help          Show this help.
EOF
}

SCENARIO_ID=""
SESSION_ID_ARG=""
STATE_ROOT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)   SCENARIO_ID="$2"; shift 2 ;;
    --session)    SESSION_ID_ARG="$2"; shift 2 ;;
    --state-root) STATE_ROOT_ARG="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${SCENARIO_ID}" ]] || { printf '--scenario is required\n' >&2; usage >&2; exit 2; }

STATE_ROOT="${STATE_ROOT_ARG:-${STATE_ROOT:-${HOME}/.claude/quality-pack/state}}"
[[ -d "${STATE_ROOT}" ]] || { printf 'state root not found: %s\n' "${STATE_ROOT}" >&2; exit 2; }

# Pick session: argument first, else most-recently-modified dir under STATE_ROOT.
if [[ -n "${SESSION_ID_ARG}" ]]; then
  SESSION_DIR="${STATE_ROOT}/${SESSION_ID_ARG}"
else
  SESSION_DIR="$(find "${STATE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
                 | while IFS= read -r d; do
                     mtime="$(stat -f '%m' "${d}" 2>/dev/null || stat -c '%Y' "${d}" 2>/dev/null || echo 0)"
                     printf '%s\t%s\n' "${mtime}" "${d}"
                   done | LC_ALL=C sort -nr | head -1 | cut -f2-)"
fi

[[ -n "${SESSION_DIR}" && -d "${SESSION_DIR}" ]] || {
  printf 'session dir not found: %s\n' "${SESSION_DIR:-<empty>}" >&2
  exit 2
}

STATE_FILE="${SESSION_DIR}/session_state.json"
TIMING_FILE="${SESSION_DIR}/timing.jsonl"
FINDINGS_FILE="${SESSION_DIR}/findings.json"
EDITED_LOG="${SESSION_DIR}/edited_files.log"

[[ -f "${STATE_FILE}" ]] || {
  printf 'session_state.json not found in: %s\n' "${SESSION_DIR}" >&2
  exit 2
}

# ---------------------------------------------------------------
# Numeric extraction
# ---------------------------------------------------------------

# Tokens: rough heuristic — sum of directive_emitted.chars / 4. The
# timing lib documents that chars/4 misattributes by 15-30% on
# directive-shaped text, but it is the best available proxy without
# a tokenizer call. Acceptable for relative comparison across scenario
# runs of the same harness version.
if [[ -f "${TIMING_FILE}" ]]; then
  directive_chars="$(jq -s '
    [.[] | select(.kind == "directive_emitted") | (.chars // 0)] | add // 0
  ' "${TIMING_FILE}" 2>/dev/null || echo 0)"
  [[ "${directive_chars}" =~ ^[0-9]+$ ]] || directive_chars=0
  tokens=$(( directive_chars / 4 ))
  tool_calls="$(jq -s '[.[] | select(.kind == "start")] | length' "${TIMING_FILE}" 2>/dev/null || echo 0)"
  [[ "${tool_calls}" =~ ^[0-9]+$ ]] || tool_calls=0
else
  tokens=0
  tool_calls=0
fi

# Elapsed: session_start_ts → last edit_ts/review_ts (most recent).
start_ts="$(jq -r '.session_start_ts // .last_user_prompt_ts // empty' "${STATE_FILE}" 2>/dev/null || true)"
end_ts="$(jq -r '
  ([.last_edit_ts // 0, .last_review_ts // 0, .last_verify_ts // 0, .last_assistant_message_ts // 0]
   | map(tonumber) | max // 0)
' "${STATE_FILE}" 2>/dev/null || echo 0)"

if [[ "${start_ts}" =~ ^[0-9]+$ && "${end_ts}" =~ ^[0-9]+$ && "${end_ts}" -gt "${start_ts}" ]]; then
  elapsed_seconds=$(( end_ts - start_ts ))
else
  elapsed_seconds=0
fi

# ---------------------------------------------------------------
# Outcome detectors
# ---------------------------------------------------------------
#
# Each emits "true" or "false". They read shared variables from state
# above. New scenarios that mention an unknown outcome key get `false`
# (missing) at the JSON synthesis step, which is the correct signal —
# the scorer will mark it missing and the score drops accordingly.

# Read shared signals once.
last_verify_outcome="$(jq -r '.last_verify_outcome // ""'   "${STATE_FILE}" 2>/dev/null || echo "")"
last_verify_scope="$(jq -r '.last_verify_scope // ""'       "${STATE_FILE}" 2>/dev/null || echo "")"
last_verify_method="$(jq -r '.last_verify_method // ""'     "${STATE_FILE}" 2>/dev/null || echo "")"
last_review_ts="$(jq -r '.last_review_ts // ""'             "${STATE_FILE}" 2>/dev/null || echo "")"
review_had_findings="$(jq -r '.review_had_findings // ""'   "${STATE_FILE}" 2>/dev/null || echo "")"
design_review_ts="$(jq -r '.design_review_ts // .design_reviewer_ts // ""' "${STATE_FILE}" 2>/dev/null || echo "")"
design_contract="$(jq -r '.design_contract // .design_contract_recorded_ts // ""' "${STATE_FILE}" 2>/dev/null || echo "")"
dispatches="$(jq -r '.subagent_dispatch_count // "0"'       "${STATE_FILE}" 2>/dev/null || echo 0)"
[[ "${dispatches}" =~ ^[0-9]+$ ]] || dispatches=0

# Boolean helpers
b() { [[ "$1" -eq 1 ]] && printf 'true' || printf 'false'; }

# tests_passed: verification passed AND scope demonstrated changed-behavior coverage.
det_tests_passed=0
[[ "${last_verify_outcome}" == "passed" \
   && ( "${last_verify_scope}" == "targeted" || "${last_verify_scope}" == "full" ) ]] && det_tests_passed=1

# targeted_verification: scope was targeted or full (full subsumes targeted)
det_targeted_verification=0
[[ "${last_verify_scope}" == "targeted" || "${last_verify_scope}" == "full" ]] && det_targeted_verification=1

# full_verification: scope was full
det_full_verification=0
[[ "${last_verify_scope}" == "full" ]] && det_full_verification=1

# review_clean: a review ran AND its FINDINGS_JSON was not flagged
det_review_clean=0
[[ -n "${last_review_ts}" && "${review_had_findings}" != "true" ]] && det_review_clean=1

# regression_test_added: edited_files.log includes a test-shaped path
det_regression_test_added=0
if [[ -f "${EDITED_LOG}" ]]; then
  if grep -Eiq '(^|/)(tests?|spec|__tests__)/|[._-](test|spec)\.(js|jsx|ts|tsx|py|rb|go|rs|swift|php|java|cs|sh)$' "${EDITED_LOG}" 2>/dev/null; then
    det_regression_test_added=1
  fi
fi

# final_closeout_audit_ready: closeout label signals (Changed./Verification./Risks./Next.)
# present in the last assistant message AND review+verify timestamps set.
det_final_closeout_audit_ready=0
last_assistant_message="$(jq -r '.last_assistant_message // ""' "${STATE_FILE}" 2>/dev/null || echo "")"
if [[ -n "${last_review_ts}" ]]; then
  closeout_signals=0
  for label in 'Changed\.\|Shipped\.' 'Verification\.' 'Risks\.\|Risk\.' 'Next\.'; do
    if grep -Eiq "\\*\\*(${label})\\*\\*" <<<"${last_assistant_message}"; then
      closeout_signals=$((closeout_signals + 1))
    fi
  done
  [[ "${closeout_signals}" -ge 2 ]] && det_final_closeout_audit_ready=1
fi

# design_contract_recorded: design_contract or its timestamp state key present
det_design_contract_recorded=0
[[ -n "${design_contract}" ]] && det_design_contract_recorded=1

# ui_files_changed: edited_files.log includes a UI/web-shaped path
det_ui_files_changed=0
if [[ -f "${EDITED_LOG}" ]]; then
  if grep -Eiq '\.(tsx|jsx|vue|svelte|css|scss|sass|less|html?|astro)$' "${EDITED_LOG}" 2>/dev/null; then
    det_ui_files_changed=1
  fi
fi

# browser_or_visual_verification: verify method touched browser/mcp/playwright
det_browser_or_visual_verification=0
case "${last_verify_method}" in
  *browser*|*playwright*|*chrome*|mcp_*) det_browser_or_visual_verification=1 ;;
esac

# design_review_clean: a design review ran AND it was clean
det_design_review_clean=0
design_review_had_findings="$(jq -r '.design_review_had_findings // ""' "${STATE_FILE}" 2>/dev/null || echo "")"
[[ -n "${design_review_ts}" && "${design_review_had_findings}" != "true" ]] && det_design_review_clean=1

# no_layout_overlap: design_review_layout_issue NOT flagged (defaults
# to "passing" — only fires false when reviewer explicitly recorded
# layout-overlap defect).
det_no_layout_overlap=1
design_review_layout_issue="$(jq -r '.design_review_layout_issue // ""' "${STATE_FILE}" 2>/dev/null || echo "")"
[[ "${design_review_layout_issue}" == "true" ]] && det_no_layout_overlap=0

# council_or_lens_coverage: ≥3 subagent dispatches AND any *-lens dispatch
# recorded in dispatch_log (best effort; falls back to dispatch count only).
det_council_or_lens_coverage=0
dispatch_log="${SESSION_DIR}/dispatch_log.jsonl"
if [[ "${dispatches}" -ge 3 ]]; then
  if [[ -f "${dispatch_log}" ]]; then
    if grep -Eq '"-lens"|"abstraction-critic"|"oracle"|"product-lens"|"sre-lens"|"data-lens"|"security-lens"|"design-lens"|"growth-lens"|"visual-craft-lens"' "${dispatch_log}" 2>/dev/null; then
      det_council_or_lens_coverage=1
    fi
  else
    # Without a dispatch_log we can only check the count — soft signal.
    det_council_or_lens_coverage=1
  fi
fi

# wave_plan_recorded: findings.json has a waves array with ≥1 wave
det_wave_plan_recorded=0
if [[ -f "${FINDINGS_FILE}" ]]; then
  if jq -e '(.waves // []) | length > 0' "${FINDINGS_FILE}" >/dev/null 2>&1; then
    det_wave_plan_recorded=1
  fi
fi

# findings_resolved_or_deferred_with_why: every finding has a terminal
# status (shipped / deferred / rejected) AND deferred/rejected carry a
# non-empty reason.
det_findings_resolved=0
if [[ -f "${FINDINGS_FILE}" ]]; then
  if jq -e '
    (.findings // []) as $all
    | ($all | length > 0)
    and ($all | all(.status == "shipped" or .status == "deferred" or .status == "rejected"))
    and ($all | all(if (.status == "deferred" or .status == "rejected") then ((.reason // "") | length > 0) else true end))
  ' "${FINDINGS_FILE}" >/dev/null 2>&1; then
    det_findings_resolved=1
  fi
fi

# token_budget_respected: the scoring layer also checks this against
# scenario.budgets.max_tokens; here we emit a "yes" signal so scenarios
# that include this outcome can request it as a positive flag. Always
# true at the producer; budget enforcement happens in the scorer.
det_token_budget_respected=1

# ---------------------------------------------------------------
# Emit result JSON
# ---------------------------------------------------------------

jq -nc \
  --arg scenario_id "${SCENARIO_ID}" \
  --argjson tokens "${tokens}" \
  --argjson tool_calls "${tool_calls}" \
  --argjson elapsed_seconds "${elapsed_seconds}" \
  --argjson tests_passed "$([[ "${det_tests_passed}" -eq 1 ]] && echo true || echo false)" \
  --argjson targeted_verification "$([[ "${det_targeted_verification}" -eq 1 ]] && echo true || echo false)" \
  --argjson full_verification "$([[ "${det_full_verification}" -eq 1 ]] && echo true || echo false)" \
  --argjson review_clean "$([[ "${det_review_clean}" -eq 1 ]] && echo true || echo false)" \
  --argjson regression_test_added "$([[ "${det_regression_test_added}" -eq 1 ]] && echo true || echo false)" \
  --argjson final_closeout_audit_ready "$([[ "${det_final_closeout_audit_ready}" -eq 1 ]] && echo true || echo false)" \
  --argjson design_contract_recorded "$([[ "${det_design_contract_recorded}" -eq 1 ]] && echo true || echo false)" \
  --argjson ui_files_changed "$([[ "${det_ui_files_changed}" -eq 1 ]] && echo true || echo false)" \
  --argjson browser_or_visual_verification "$([[ "${det_browser_or_visual_verification}" -eq 1 ]] && echo true || echo false)" \
  --argjson design_review_clean "$([[ "${det_design_review_clean}" -eq 1 ]] && echo true || echo false)" \
  --argjson no_layout_overlap "$([[ "${det_no_layout_overlap}" -eq 1 ]] && echo true || echo false)" \
  --argjson council_or_lens_coverage "$([[ "${det_council_or_lens_coverage}" -eq 1 ]] && echo true || echo false)" \
  --argjson wave_plan_recorded "$([[ "${det_wave_plan_recorded}" -eq 1 ]] && echo true || echo false)" \
  --argjson findings_resolved "$([[ "${det_findings_resolved}" -eq 1 ]] && echo true || echo false)" \
  --argjson token_budget_respected "$([[ "${det_token_budget_respected}" -eq 1 ]] && echo true || echo false)" \
  '
    {
      scenario_id: $scenario_id,
      tokens: $tokens,
      tool_calls: $tool_calls,
      elapsed_seconds: $elapsed_seconds,
      outcomes: {
        tests_passed: $tests_passed,
        targeted_verification: $targeted_verification,
        full_verification: $full_verification,
        review_clean: $review_clean,
        regression_test_added: $regression_test_added,
        final_closeout_audit_ready: $final_closeout_audit_ready,
        design_contract_recorded: $design_contract_recorded,
        ui_files_changed: $ui_files_changed,
        browser_or_visual_verification: $browser_or_visual_verification,
        design_review_clean: $design_review_clean,
        no_layout_overlap: $no_layout_overlap,
        council_or_lens_coverage: $council_or_lens_coverage,
        wave_plan_recorded: $wave_plan_recorded,
        findings_resolved_or_deferred_with_why: $findings_resolved,
        token_budget_respected: $token_budget_respected
      }
    }
  '
