#!/usr/bin/env bash
# Focused tests for lib/classifier.sh — the extracted prompt classifier.
#
# The behavior contract is exhaustively covered by test-intent-classification.sh
# (441 assertions) and test-classifier-replay.sh (15). This file is the
# minimal symbol-presence regression net for the lib itself: catches the
# "lib file shipped but functions silently missing" failure mode that
# verify.sh's path-existence check cannot detect.
#
# Mirrors the pattern of tests/test-state-io.sh for the v1.12.0 lib.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

assert_function_defined() {
  local fn="$1"
  if declare -F "${fn}" >/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: function %q not defined after sourcing common.sh\n' "${fn}" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
printf 'Test 1: lib/classifier.sh exports the contracted functions\n'
for fn in is_imperative_request count_keyword_matches is_ui_request \
          is_design_review_semantic_request \
          infer_domain classify_task_intent record_classifier_telemetry \
          detect_classifier_misfire is_execution_intent_value \
          is_council_phase8_entry_request \
          is_council_phase8_followup_request \
          is_exhaustive_authorization_request \
          is_review_cycle_broad_scope_request \
          is_product_shaped_request is_ambiguous_execution_request \
          is_exemplifying_request; do
  assert_function_defined "${fn}"
done

# ----------------------------------------------------------------------
printf 'Test 2: lib file exists alongside common.sh in the bundle\n'
lib="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh"
[[ -f "${lib}" ]] && pass=$((pass + 1)) || { printf '  FAIL: %s missing\n' "${lib}" >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 3: lib parses cleanly under bash -n\n'
if bash -n "${lib}"; then pass=$((pass + 1)); else printf '  FAIL: bash -n %s\n' "${lib}" >&2; fail=$((fail + 1)); fi

# ----------------------------------------------------------------------
printf 'Test 4: lib does NOT shebang-execute itself (sourced-only)\n'
# The lib should be sourced by common.sh; running it as ./lib/classifier.sh
# would run the function definitions but execute no entry-point code.
# Asserting the lib has no top-level invocation prevents accidental side
# effects on direct execution.
toplevel_invocations="$(grep -cE '^[^#[:space:]].*\(\)[[:space:]]*\{' "${lib}" || true)"
# All function definitions match the pattern; we want to confirm there are
# NO non-function-definition top-level statements that aren't comments or
# part of a function body. A coarse check: count lines that start with a
# non-whitespace, non-comment, non-`}`, non-function-decl token at column 1
# outside known function bodies.
# We approximate by asserting the file's non-comment top-level lines match
# only function definitions. Detailed parse is out of scope; this catches
# the obvious "added a stray classify_task_intent 'foo' call at the top".
stray_calls="$(awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  /^[a-zA-Z_][a-zA-Z_0-9]*\(\)[[:space:]]*\{?/ { in_fn = 1; next }
  /^\}[[:space:]]*$/ { in_fn = 0; next }
  in_fn { next }
  /^[[:space:]]/ { next }     # continuation of multi-line decl
  /^[A-Z_][A-Z0-9_]*=/ { next }   # top-level UPPERCASE/_-leading constant
  /^_OMC_[A-Z0-9_]*=/ { next }    # oh-my-claude shared regex constants
  { print NR": "$0 }
' "${lib}")"
if [[ -z "${stray_calls}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: lib has stray top-level statements:\n%s\n' "${stray_calls}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 5: classifier dependencies are defined before the source CALL site\n'
# Source ordering regression: every helper named in the lib's dependency
# header must be defined in common.sh strictly above the source-call site
# (the line where _omc_load_classifier actually fires, not where the
# loader function itself is defined). v1.27.0 introduced a lazy-load
# loader function whose body contains a `source` statement at definition
# time but only fires at the conditional call site near the bottom of
# common.sh — that conditional call is the real "source line" for
# ordering purposes.
common="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
# Match the conditional load block (the actual call site, not the loader
# function definition). The pattern `_omc_load_classifier` line in the
# OMC_LAZY_CLASSIFIER if-block is the one that matters at runtime.
source_line="$(grep -nE '^[[:space:]]*_omc_load_classifier[[:space:]]*$' "${common}" | grep -v '^[[:space:]]*#' | tail -1 | cut -d: -f1)"
if [[ -z "${source_line}" ]]; then
  # Pre-v1.27 fallback: literal source line.
  source_line="$(grep -n 'source.*lib/classifier\.sh' "${common}" | grep -v '^[[:space:]]*#' | tail -1 | cut -d: -f1)"
fi
[[ -n "${source_line}" ]] || { printf '  FAIL: no source-call site for lib/classifier.sh\n' >&2; fail=$((fail + 1)); }

for dep in project_profile_has normalize_task_prompt extract_skill_primary_task \
           is_continuation_request is_checkpoint_request is_session_management_request \
           is_advisory_request now_epoch truncate_chars trim_whitespace log_hook log_anomaly; do
  dep_line="$(grep -n "^${dep}()[[:space:]]*{" "${common}" | head -1 | cut -d: -f1)"
  if [[ -z "${dep_line}" ]]; then
    printf '  FAIL: dependency %q not defined in common.sh\n' "${dep}" >&2
    fail=$((fail + 1))
  elif [[ "${dep_line}" -ge "${source_line}" ]]; then
    printf '  FAIL: dependency %q defined at line %s, AFTER source-call line %s\n' "${dep}" "${dep_line}" "${source_line}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done

# ----------------------------------------------------------------------
printf 'Test 6: smoke — classify_task_intent returns sensible values\n'
got_exec="$(classify_task_intent "Implement OAuth login on the web app")"
assert_eq "execution prompt classifies as execution" "execution" "${got_exec}"
got_advisory="$(classify_task_intent "Should we use OAuth or SAML?")"
assert_eq "advisory question classifies as advisory" "advisory" "${got_advisory}"
got_eval_then_exec="$(classify_task_intent "evaluate my project and implement the recommended fixes")"
assert_eq "recommended-fixes mutation outranks advisory vocabulary" "execution" "${got_eval_then_exec}"

# ----------------------------------------------------------------------
printf 'Test 7: is_execution_intent_value contract\n'
is_execution_intent_value execution && pass=$((pass + 1)) || { printf '  FAIL: execution should be true\n' >&2; fail=$((fail + 1)); }
is_execution_intent_value continuation && pass=$((pass + 1)) || { printf '  FAIL: continuation should be true\n' >&2; fail=$((fail + 1)); }
! is_execution_intent_value advisory && pass=$((pass + 1)) || { printf '  FAIL: advisory should be false\n' >&2; fail=$((fail + 1)); }
! is_execution_intent_value checkpoint && pass=$((pass + 1)) || { printf '  FAIL: checkpoint should be false\n' >&2; fail=$((fail + 1)); }

# Council evaluation and Council implementation are separate contracts.
is_council_phase8_entry_request "evaluate my project and fix all findings" \
  && pass=$((pass + 1)) || { printf '  FAIL: fix-all Council request should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_entry_request "make this project impeccable" \
  && pass=$((pass + 1)) || { printf '  FAIL: high-bar make request should enter Phase 8\n' >&2; fail=$((fail + 1)); }
! is_council_phase8_entry_request "evaluate my project" \
  && pass=$((pass + 1)) || { printf '  FAIL: assessment imperative alone must remain advisory\n' >&2; fail=$((fail + 1)); }
! is_council_phase8_entry_request "perform an exhaustive audit of my project" \
  && pass=$((pass + 1)) || { printf '  FAIL: exhaustive audit alone must remain advisory\n' >&2; fail=$((fail + 1)); }
! is_council_phase8_entry_request "evaluate my project; report only" \
  && pass=$((pass + 1)) || { printf '  FAIL: report-only veto must suppress Phase 8\n' >&2; fail=$((fail + 1)); }
! is_council_phase8_entry_request "review the product and update me" \
  && pass=$((pass + 1)) || { printf '  FAIL: update-me must not be treated as mutation\n' >&2; fail=$((fail + 1)); }
for advisory_council in \
  "Do not repair the project; evaluate it" \
  "Do not refactor the app; audit only" \
  "Do not publish the changes; review the project" \
  "Review the app, not implement the findings" \
  "Evaluate the project and do not address the findings" \
  "Evaluate this project and report what to change" \
  "Evaluate my project and address whether it is ready" \
  "Review my app and resolve the question of product-market fit" \
  "Review my project and commit to a recommendation" \
  "Evaluate my project and apply a rigorous security rubric" \
  "Assess the codebase and apply a rigorous security checklist" \
  "Evaluate my project, fix every issue, then do not make any changes" \
  "Evaluate my project and implement fixes, but do not make any changes; report the plan" \
  "What changes would make this project better?"; do
  ! is_council_phase8_entry_request "${advisory_council}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: negated mutation must remain advisory: %q\n' "${advisory_council}" >&2; fail=$((fail + 1)); }
done
for implementation_council in \
  "implement" \
  "ship" \
  "fix everything" \
  "review the project and implement" \
  "evaluate and ship" \
  "review the project and ship fixes" \
  "evaluate my project and implement the recommended fixes" \
  "evaluate my project and apply the recommended fixes" \
  "Review only the backend, then fix all findings" \
  "Just review auth, then implement recommendations" \
  "Do not change docs; fix all code issues" \
  "No edits to tests, but repair the app" \
  "Evaluate and fix all findings; report only the final result"; do
  is_council_phase8_entry_request "${implementation_council}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: explicit mutation must enter Phase 8: %q\n' "${implementation_council}" >&2; fail=$((fail + 1)); }
done

for design_prompt in \
  "change the button color to red" \
  "increase padding on the cards" \
  "adjust the typography scale" \
  "fix low contrast text" \
  "fix responsive breakpoints" \
  "improve keyboard focus rings" \
  "change the SwiftUI accent color" \
  "fix Dynamic Type clipping"; do
  is_design_review_semantic_request "${design_prompt}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: visual prompt should require design semantics: %q\n' "${design_prompt}" >&2; fail=$((fail + 1)); }
done
! is_design_review_semantic_request "change the authentication provider in Widget.tsx" \
  && pass=$((pass + 1)) || { printf '  FAIL: logic-only TSX prompt should not require design semantics\n' >&2; fail=$((fail + 1)); }

is_council_phase8_followup_request "implement all recommendations" \
  && pass=$((pass + 1)) || { printf '  FAIL: Council recommendations follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "ship" \
  && pass=$((pass + 1)) || { printf '  FAIL: terse ship follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "fix the issue identified in the assessment" \
  && pass=$((pass + 1)) || { printf '  FAIL: explicit assessment-result follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "address every finding" \
  && pass=$((pass + 1)) || { printf '  FAIL: referential every-finding follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "ulw implement the top 3 findings" \
  && pass=$((pass + 1)) || { printf '  FAIL: bounded top-N Council follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "ulw implement only the critical findings" \
  && pass=$((pass + 1)) || { printf '  FAIL: severity-bounded Council follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
is_council_phase8_followup_request "ulw fix all" \
  && pass=$((pass + 1)) || { printf '  FAIL: terse fix-all Council follow-up should enter Phase 8\n' >&2; fail=$((fail + 1)); }
! is_council_phase8_followup_request "fix this unrelated parser bug" \
  && pass=$((pass + 1)) || { printf '  FAIL: unrelated later fix must not inherit Council scope\n' >&2; fail=$((fail + 1)); }
for unrelated_followup in \
  "fix the performance gap in the parser" \
  "address the test gaps in this feature" \
  "implement the recommendation from the linter" \
  "ship the wave animation fix"; do
  ! is_council_phase8_followup_request "${unrelated_followup}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: focused work must not inherit Council scope: %q\n' "${unrelated_followup}" >&2; fail=$((fail + 1)); }
done

# ----------------------------------------------------------------------
printf 'Test 8: is_exhaustive_authorization_request — vocabulary coverage\n'

assert_auth() {
  local label="$1" prompt="$2"
  if is_exhaustive_authorization_request "${prompt}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — should authorize: %q\n' "${label}" "${prompt}" >&2
    fail=$((fail + 1))
  fi
}

assert_no_auth() {
  local label="$1" prompt="$2"
  if ! is_exhaustive_authorization_request "${prompt}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — should NOT authorize: %q\n' "${label}" "${prompt}" >&2
    fail=$((fail + 1))
  fi
}

# Tier 1 — canonical exhaustive markers
assert_auth "implement all" "implement all the findings from the council"
assert_no_auth "exhaustive assessment artifact" "evaluate the project and produce an exhaustive plan"
assert_no_auth "intensity adverb is not exhaustive auth" "evaluate my project thoroughly"
assert_no_auth "deep flag is not exhaustive auth" "evaluate my project --deep"
assert_auth "fix everything" "review and fix everything the lens flagged"
assert_auth "ship it all"   "address the issues then ship it all"
assert_auth "address each one" "go through and address each one in turn"
assert_auth "every item"    "cover every item the council surfaced"
assert_auth "every finding" "ship every finding before stopping"

# Tier 2 — "do all <object>" (the user's "do all waves" phrasing)
assert_auth "do all waves"     "Continue all identified gaps in Waves. Do all waves."
assert_auth "do all gaps"      "do all gaps surfaced this session"
assert_auth "do all of them"   "we should do all of them in this run"

# Tier 3 — "continue all <stuff>" (the user's "continue all identified gaps" phrasing)
assert_auth "continue all gaps"     "Continue all identified gaps in Waves"
assert_auth "continue all findings" "continue all remaining findings"

# Tier 4 — action verb + all/every + scope-unit
assert_auth "complete all waves"  "we need to complete all waves before stopping"
assert_auth "tackle every finding" "tackle every finding the lens surfaced"
assert_auth "close all gaps"       "close all gaps from the audit"

# Tier 5 must not infer a whole-scope authorization from an unresolved pronoun.
assert_no_auth "ambiguous impeccable pronoun" "make it impeccable"

# Tier 5 — "make X impeccable" implementation-bar markers
assert_auth "make X impeccable" "Make this feature impeccable to use"
assert_auth "make X production-ready" "make the application production-ready"
assert_auth "make X world-class"      "make our platform world-class"
assert_auth "make X polished"         "make the project polished"

# Tier 6 — binary-quality framing (user's "0 or 1" phrasing)
assert_auth "0 or 1"           "As a product, it is either 0 or 1"
assert_auth "either 0 or 1"    "Either 0 or 1 — middle states are basically 0"
assert_auth "no middle ground" "No middle ground — ship it complete"

# Tier 7 — tail-position "ship/land/merge it all"
assert_auth "ship them all" "review the PRs then ship them all"
assert_auth "land it all"   "merge the branches and land it all"

# Negatives — non-authorization shapes that must NOT trigger
assert_no_auth "make sure"          "make sure the api is production-ready before shipping"
assert_no_auth "make a perfect"     "make a perfect commit message for this PR"
assert_no_auth "narrow scope"       "fix this one bug in the auth module"
assert_no_auth "single finding"     "address this finding from the security review"
assert_no_auth "advisory"           "what should we do next about the auth module"
assert_no_auth "make this function" "make this function impeccable"
assert_no_auth "templating"         "make the docstring polished and the readme excellent"
assert_no_auth "bounded top N"      "Thoroughly assess the project, then implement the top 3 fixes"
assert_no_auth "bounded severity subset" "Exhaustively review the project and implement only the critical findings"
assert_no_auth "selected subset"    "implement selected findings from the assessment"
assert_no_auth "top-N before action" "For the top 3 findings, implement them all exhaustively"
assert_no_auth "severity before passive action" "Only the critical findings should be implemented, even after an exhaustive audit"
assert_no_auth "all severity subset" "Exhaustively assess the project, then implement all high-severity findings"
assert_no_auth "severity after object" "Implement all findings classified as P1 after the exhaustive review"
assert_no_auth "domain-only action-first" "Exhaustively review everything, then implement only the security findings"
assert_no_auth "domain-only suffix" "Implement the performance findings only, despite the exhaustive assessment"
assert_no_auth "domain-only reverse" "Only the accessibility findings should be fixed after the exhaustive audit"
assert_no_auth "domain source qualifier" "Exhaustively audit the project, then implement only findings from security"
assert_no_auth "explicit IDs action-first" "Exhaustively review the project, then implement F-001 and F-003"
assert_no_auth "explicit IDs before action" "F-002 and SEC-17 are the findings to fix after the exhaustive audit"
assert_auth "thorough explicit every" "thoroughly implement every recommendation"

# The user's verbatim prompt body — load-bearing fixture
assert_auth "user verbatim prompt body" "At this stage, what should we do next to further improve the agent memory wall feature? Remember, think what Steve Jobs would do. Make this feature impeccable to use. As a product, it is either 0 or 1. Middle states are basically 0. Continue all identified gaps in Waves. Do all waves."

# Blocking review breadth is stricter than authorization. Intensity alone or
# a focused target must not summon excellence-reviewer; explicit whole/all
# scope still does.
is_review_cycle_broad_scope_request "fix everything in the repository" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: explicit repository-wide scope should be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "implement all findings from the audit" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: all-findings scope should be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "implement all improvements" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: all-improvements scope should be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "implement all" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: canonical bare implement-all should be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "exhaustively improve this project" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: exhaustive explicit project target should be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "comprehensively evaluate this project and implement all improvements" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: open project mandate should be broad\n' >&2; fail=$((fail + 1)); }
! is_review_cycle_broad_scope_request "thoroughly fix this function" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: focused thorough function fix should not be broad\n' >&2; fail=$((fail + 1)); }
! is_review_cycle_broad_scope_request "thoroughly fix the parser" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: intensity without whole-scope referent should not be broad\n' >&2; fail=$((fail + 1)); }
! is_review_cycle_broad_scope_request "make this feature impeccable" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: focused high-bar feature should not be broad\n' >&2; fail=$((fail + 1)); }
is_review_cycle_broad_scope_request "make this project impeccable" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: explicit high-bar project scope should be broad\n' >&2; fail=$((fail + 1)); }
for focused_context_prompt in \
  "Fix the typo. This project uses Bash." \
  "Update dependencies in this project." \
  "Review the login flow in this project."; do
  ! is_review_cycle_broad_scope_request "${focused_context_prompt}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: incidental project context must not widen review: %q\n' "${focused_context_prompt}" >&2; fail=$((fail + 1)); }
done
for broad_prompt in \
  "rewrite the whole codebase" \
  "refactor the entire application" \
  "overhaul the whole system" \
  "modernize the codebase end to end" \
  "fix issues across the repository" \
  "improve the project as a whole" \
  "harden the entire platform" \
  "update all code" \
  "rebuild the application from end to end" \
  "clean up the whole repo" \
  "make the entire product reliable"; do
  is_review_cycle_broad_scope_request "${broad_prompt}" \
    && pass=$((pass + 1)) \
    || { printf '  FAIL: whole-scope implementation should be broad: %q\n' "${broad_prompt}" >&2; fail=$((fail + 1)); }
done

! is_exhaustive_authorization_request "Thoroughly review my app, then fix the highest-priority issue" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: top-one mutation must override thorough assessment adjective\n' >&2; fail=$((fail + 1)); }
! is_exhaustive_authorization_request "Perform an exhaustive audit, then implement the top recommendation" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: top recommendation must not authorize all waves\n' >&2; fail=$((fail + 1)); }
! is_exhaustive_authorization_request "Thoroughly assess the project, then implement the top 3 fixes" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: top-N fixes must not authorize all waves\n' >&2; fail=$((fail + 1)); }
! is_exhaustive_authorization_request "Exhaustively review the project and implement only the critical findings" \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: severity-bounded fixes must not authorize all waves\n' >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
# v1.42.x security: record_classifier_telemetry must redact secret-shaped
# tokens before writing prompt_preview to <session>/classifier_telemetry.jsonl.
# Without redaction the cross-session sweep can aggregate prompt text
# (including any pasted credential) into ~/.claude/quality-pack which is
# a less-guarded surface than the per-session dir.
printf 'Test: classifier_telemetry redacts secret tokens at write time\n'
_CLF_TMP="$(mktemp -d)"
export SESSION_ID="redaction-classifier-test"
ORIG_STATE_ROOT="${STATE_ROOT:-}"
ORIG_TELEMETRY="${OMC_CLASSIFIER_TELEMETRY:-}"
# Override STATE_ROOT directly — common.sh's STATE_ROOT was bound at
# source time so a later HOME change has no effect. The writer reads
# the live value via `session_file`.
export STATE_ROOT="${_CLF_TMP}/state"
export OMC_CLASSIFIER_TELEMETRY="on"
mkdir -p "${STATE_ROOT}/${SESSION_ID}"
_omc_load_classifier 2>/dev/null || true
_SECRET='sk-ant-deadbeefcafebabe1234567ABCDEFG'
_PROMPT_WITH_SECRET="please run with --auth-token ${_SECRET} and ship Wave 1"
record_classifier_telemetry "execution" "coding" "${_PROMPT_WITH_SECRET}" 0 2>/dev/null || true
_clf_file="${STATE_ROOT}/${SESSION_ID}/classifier_telemetry.jsonl"
if [[ -s "${_clf_file}" ]]; then
  _row="$(tail -n 1 "${_clf_file}")"
  case "${_row}" in
    *"${_SECRET}"*)
      printf '  FAIL: classifier telemetry leaked sk-ant- token\n    row=%s\n' "${_row}" >&2
      fail=$((fail + 1))
      ;;
    *"<redacted-secret>"*)
      pass=$((pass + 1))
      ;;
    *)
      printf '  FAIL: classifier telemetry redaction marker missing\n    row=%s\n' "${_row}" >&2
      fail=$((fail + 1))
      ;;
  esac
  case "${_row}" in
    *"Ship Wave 1"*|*"ship Wave 1"*) pass=$((pass + 1)) ;;
    *) printf '  FAIL: classifier non-secret prose dropped from prompt_preview\n    row=%s\n' "${_row}" >&2; fail=$((fail + 1)) ;;
  esac
else
  printf '  FAIL: classifier telemetry file not created (%s)\n' "${_clf_file}" >&2
  fail=$((fail + 1))
fi
# Restore env and clean up.
if [[ -n "${ORIG_STATE_ROOT}" ]]; then export STATE_ROOT="${ORIG_STATE_ROOT}"; else unset STATE_ROOT; fi
if [[ -n "${ORIG_TELEMETRY}" ]]; then export OMC_CLASSIFIER_TELEMETRY="${ORIG_TELEMETRY}"; else unset OMC_CLASSIFIER_TELEMETRY; fi
rm -rf "${_CLF_TMP}"
unset SESSION_ID

# ----------------------------------------------------------------------
printf '\n=== Classifier Lib Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
