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
printf 'Test 1: lib/classifier.sh exports the eight contracted functions\n'
for fn in is_imperative_request count_keyword_matches is_ui_request \
          infer_domain classify_task_intent record_classifier_telemetry \
          detect_classifier_misfire is_execution_intent_value; do
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
printf '\n=== Classifier Lib Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
