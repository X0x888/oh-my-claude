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
          infer_domain classify_task_intent record_classifier_telemetry \
          detect_classifier_misfire is_execution_intent_value \
          is_exhaustive_authorization_request \
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
printf 'Test 5: classifier dependencies are defined before the source line\n'
# Source ordering regression: every helper named in the lib's dependency
# header must be defined in common.sh strictly above the source statement.
common="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
source_line="$(grep -n 'source.*lib/classifier\.sh' "${common}" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
[[ -n "${source_line}" ]] || { printf '  FAIL: no source line for lib/classifier.sh\n' >&2; fail=$((fail + 1)); }

for dep in project_profile_has normalize_task_prompt extract_skill_primary_task \
           is_continuation_request is_checkpoint_request is_session_management_request \
           is_advisory_request now_epoch truncate_chars trim_whitespace log_hook log_anomaly; do
  dep_line="$(grep -n "^${dep}()[[:space:]]*{" "${common}" | head -1 | cut -d: -f1)"
  if [[ -z "${dep_line}" ]]; then
    printf '  FAIL: dependency %q not defined in common.sh\n' "${dep}" >&2
    fail=$((fail + 1))
  elif [[ "${dep_line}" -ge "${source_line}" ]]; then
    printf '  FAIL: dependency %q defined at line %s, AFTER source line %s\n' "${dep}" "${dep_line}" "${source_line}" >&2
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

# ----------------------------------------------------------------------
printf 'Test 7: is_execution_intent_value contract\n'
is_execution_intent_value execution && pass=$((pass + 1)) || { printf '  FAIL: execution should be true\n' >&2; fail=$((fail + 1)); }
is_execution_intent_value continuation && pass=$((pass + 1)) || { printf '  FAIL: continuation should be true\n' >&2; fail=$((fail + 1)); }
! is_execution_intent_value advisory && pass=$((pass + 1)) || { printf '  FAIL: advisory should be false\n' >&2; fail=$((fail + 1)); }
! is_execution_intent_value checkpoint && pass=$((pass + 1)) || { printf '  FAIL: checkpoint should be false\n' >&2; fail=$((fail + 1)); }

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
assert_auth "exhaustive"    "evaluate the project and produce an exhaustive plan"
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

# The user's verbatim prompt body — load-bearing fixture
assert_auth "user verbatim prompt body" "At this stage, what should we do next to further improve the agent memory wall feature? Remember, think what Steve Jobs would do. Make this feature impeccable to use. As a product, it is either 0 or 1. Middle states are basically 0. Continue all identified gaps in Waves. Do all waves."

# ----------------------------------------------------------------------
printf '\n=== Classifier Lib Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
