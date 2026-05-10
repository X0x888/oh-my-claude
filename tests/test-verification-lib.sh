#!/usr/bin/env bash
# Focused tests for lib/verification.sh — the extracted verification subsystem.
#
# The behavior contract is exhaustively covered by test-common-utilities.sh
# (verification_matches_project_test_command bash-family + score boundary
# cases), test-quality-gates.sh (MCP classification + scoring + outcome
# integration with stop-guard), and test-intent-classification.sh
# (verification_has_framework_keyword shell-test recognition). This file
# is the minimal symbol-presence regression net for the lib itself:
# catches the "lib file shipped but functions silently missing" failure
# mode that verify.sh's path-existence check cannot detect.
#
# Mirrors the pattern of tests/test-state-io.sh (v1.12.0) and
# tests/test-classifier.sh (v1.13.0).
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

assert_readonly_set() {
  local var="$1"
  local expected_pattern="$2"
  local val="${!var:-__UNSET__}"
  if [[ "${val}" == "__UNSET__" ]]; then
    printf '  FAIL: readonly %q is unset\n' "${var}" >&2
    fail=$((fail + 1))
    return
  fi
  # Glob matching is intentional — patterns like `*playwright*__browser_snapshot`.
  # shellcheck disable=SC2053
  if [[ "${val}" != ${expected_pattern} ]]; then
    printf '  FAIL: readonly %q = %q, expected pattern %q\n' "${var}" "${val}" "${expected_pattern}" >&2
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
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
printf 'Test 1: lib/verification.sh exports the contracted functions\n'
for fn in verification_matches_project_test_command verification_has_framework_keyword \
          verification_output_has_counts verification_output_has_clear_outcome \
          detect_verification_method score_verification_confidence \
          classify_mcp_verification_tool score_mcp_verification_confidence \
          detect_mcp_verification_outcome classify_verification_scope; do
  assert_function_defined "${fn}"
done

# ----------------------------------------------------------------------
printf 'Test 2: MCP_VERIFY_* readonly constants are defined and non-empty\n'
# Without these globs, classify_mcp_verification_tool silently returns
# the empty string for every Playwright/computer-use call, which would
# zero out MCP scoring at the gate.
assert_readonly_set MCP_VERIFY_SNAPSHOT     '*playwright*'
assert_readonly_set MCP_VERIFY_SCREENSHOT   '*playwright*'
assert_readonly_set MCP_VERIFY_CONSOLE      '*playwright*'
assert_readonly_set MCP_VERIFY_NETWORK      '*playwright*'
assert_readonly_set MCP_VERIFY_EVALUATE     '*playwright*'
assert_readonly_set MCP_VERIFY_RUN_CODE     '*playwright*'
assert_readonly_set MCP_VERIFY_CU_SCREENSHOT 'mcp__computer-use__screenshot'

# ----------------------------------------------------------------------
printf 'Test 3: lib file exists alongside common.sh in the bundle\n'
lib="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/verification.sh"
[[ -f "${lib}" ]] && pass=$((pass + 1)) || { printf '  FAIL: %s missing\n' "${lib}" >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
printf 'Test 4: lib parses cleanly under bash -n\n'
if bash -n "${lib}"; then pass=$((pass + 1)); else printf '  FAIL: bash -n %s\n' "${lib}" >&2; fail=$((fail + 1)); fi

# ----------------------------------------------------------------------
printf 'Test 5: lib does NOT shebang-execute itself (sourced-only)\n'
# Same shape check as test-classifier.sh — fail if the lib gains a
# top-level invocation that would run on bare execution.
stray_calls="$(awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  /^[a-zA-Z_][a-zA-Z_0-9]*\(\)[[:space:]]*\{?/ { in_fn = 1; next }
  /^\}[[:space:]]*$/ { in_fn = 0; next }
  in_fn { next }
  /^[[:space:]]/ { next }
  /^readonly[[:space:]]/ { next }
  { print NR": "$0 }
' "${lib}")"
if [[ -z "${stray_calls}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: lib has stray top-level statements:\n%s\n' "${stray_calls}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 6: source order — verification.sh sourced after lib/state-io.sh\n'
# The lib has no inter-lib dependency on classifier.sh, so its source
# line should land in the early bootstrap block alongside state-io.sh,
# not next to the late classifier.sh source line that depends on
# project_profile_has / is_advisory_request / etc.
common="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
state_io_line="$(grep -n 'source.*lib/state-io\.sh' "${common}" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
verify_line="$(grep -n 'source.*lib/verification\.sh' "${common}" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
classifier_line="$(grep -n 'source.*lib/classifier\.sh' "${common}" | grep -v '^[[:space:]]*#' | head -1 | cut -d: -f1)"
if [[ -n "${state_io_line}" && -n "${verify_line}" && -n "${classifier_line}" \
      && "${state_io_line}" -lt "${verify_line}" \
      && "${verify_line}" -lt "${classifier_line}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: source order wrong — state-io=%s verification=%s classifier=%s\n' \
    "${state_io_line}" "${verify_line}" "${classifier_line}" >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 7: smoke — score_verification_confidence sums factors correctly\n'
# Project test command match (40) + framework keyword (30) + counts (20) + clear outcome (10) = 100
got="$(score_verification_confidence 'npm test -- --runInBand' \
        'PASS auth/login.test.ts'$'\n''Tests: 10 passed, 0 failed' \
        'npm test')"
assert_eq "all four factors → 100" "100" "${got}"

# Bash-only family bonus: framework keyword path matches `bash tests/<file>.sh`
got="$(score_verification_confidence 'bash tests/test-foo.sh' \
        '=== Results: 5 passed, 0 failed ===' \
        'bash tests/test-bar.sh')"
# 40 (project family match) + 30 (framework keyword via tests/*.sh) + 20 (count) + 10 (clear outcome PASS-likeword "passed") = 100
assert_eq "bash-family + counts + outcome → 100" "100" "${got}"

# Bare shellcheck: only framework keyword (30), no counts, no clear outcome
got="$(score_verification_confidence 'shellcheck script.sh' '' '')"
assert_eq "shellcheck-only → 30" "30" "${got}"

# Empty cmd → 0
got="$(score_verification_confidence '' '' '')"
assert_eq "empty cmd → 0" "0" "${got}"

# ----------------------------------------------------------------------
printf 'Test 8: smoke — score_mcp_verification_confidence base + bonuses + cap\n'
# browser_dom_check base 25, no UI context, no output → 25
got="$(score_mcp_verification_confidence 'browser_dom_check' '' 'false')"
assert_eq "browser_dom_check base → 25" "25" "${got}"

# browser_dom_check + UI context → 45
got="$(score_mcp_verification_confidence 'browser_dom_check' '' 'true')"
assert_eq "browser_dom_check + UI ctx → 45" "45" "${got}"

# browser_eval_check (35) + counts bonus (15) + outcome bonus (10) + UI ctx (20) = 80
got="$(score_mcp_verification_confidence 'browser_eval_check' '5 passed, 0 errors' 'true')"
assert_eq "browser_eval_check + signals → 80" "80" "${got}"

# Cap at 100: artificial inputs that would otherwise total > 100
got="$(score_mcp_verification_confidence 'browser_eval_check' \
        '50 passed, 0 errors' 'true')"
# 35 + 15 (counts) + 10 (no PASS keyword in this string but "passed" matches via regex)
# Actually "50 passed" matches both regexes — counts (+15) and outcome (+10).
assert_eq "browser_eval_check + counts + outcome + UI" "80" "${got}"

# ----------------------------------------------------------------------
printf 'Test 8b: passive types cannot clear default threshold (40) on UI context alone\n'
# Passive observation types (visual screenshots) get a capped UI bonus
# (+10 instead of +20), so an empty-output passive call in a UI-edit
# session lands BELOW the default threshold and still requires an
# assertion-bearing signal. The intent is documented at the head of
# score_mcp_verification_confidence.

# browser_visual_check (20) + UI ctx (+10 capped) = 30 — below threshold (40)
got="$(score_mcp_verification_confidence 'browser_visual_check' '' 'true')"
assert_eq "browser_visual_check + UI ctx → 30 (capped)" "30" "${got}"

# visual_check (computer-use screenshot, 15) + UI ctx (+10 capped) = 25 — below threshold
got="$(score_mcp_verification_confidence 'visual_check' '' 'true')"
assert_eq "visual_check + UI ctx → 25 (capped)" "25" "${got}"

# browser_visual_check + UI ctx + assertion-bearing output:
# 20 (base) + 10 (capped UI ctx) + 15 (counts) + 10 (outcome) = 55 — above threshold
got="$(score_mcp_verification_confidence 'browser_visual_check' \
        '3 tests passed' 'true')"
assert_eq "browser_visual_check + UI ctx + assertions → 55" "55" "${got}"

# Targeted checks still get the full +20 — DOM/console/network/eval unchanged
got="$(score_mcp_verification_confidence 'browser_console_check' '' 'true')"
assert_eq "browser_console_check + UI ctx → 50 (full bonus)" "50" "${got}"

got="$(score_mcp_verification_confidence 'browser_network_check' '' 'true')"
assert_eq "browser_network_check + UI ctx → 50 (full bonus)" "50" "${got}"

# No-UI-context: passive types unchanged — base scores only
got="$(score_mcp_verification_confidence 'browser_visual_check' '' 'false')"
assert_eq "browser_visual_check no UI ctx → 20" "20" "${got}"

got="$(score_mcp_verification_confidence 'visual_check' '' 'false')"
assert_eq "visual_check no UI ctx → 15" "15" "${got}"

# ----------------------------------------------------------------------
printf 'Test 9: smoke — classify_mcp_verification_tool buckets are correct\n'
got="$(classify_mcp_verification_tool 'mcp__plugin_playwright_playwright__browser_snapshot')"
assert_eq "playwright snapshot → browser_dom_check" "browser_dom_check" "${got}"

got="$(classify_mcp_verification_tool 'mcp__plugin_playwright_playwright__browser_console_messages')"
assert_eq "playwright console → browser_console_check" "browser_console_check" "${got}"

got="$(classify_mcp_verification_tool 'mcp__computer-use__screenshot')"
assert_eq "computer-use screenshot → visual_check" "visual_check" "${got}"

got="$(classify_mcp_verification_tool 'mcp__plugin_playwright_playwright__browser_click')"
assert_eq "non-verify tool → empty" "" "${got}"

got="$(classify_mcp_verification_tool '')"
assert_eq "empty tool name → empty" "" "${got}"

# ----------------------------------------------------------------------
printf 'Test 10: smoke — detect_mcp_verification_outcome catches errors\n'
got="$(detect_mcp_verification_outcome 'TypeError: foo is undefined' 'browser_console_check')"
assert_eq "TypeError → failed" "failed" "${got}"

got="$(detect_mcp_verification_outcome 'GET /api/x 404 Not Found' 'browser_network_check')"
assert_eq "404 in network → failed" "failed" "${got}"

got="$(detect_mcp_verification_outcome 'AssertionError: expected 5 got 3' 'browser_eval_check')"
assert_eq "AssertionError in eval → failed" "failed" "${got}"

got="$(detect_mcp_verification_outcome '<html><body>OK</body></html>' 'browser_dom_check')"
assert_eq "clean DOM → passed" "passed" "${got}"

got="$(detect_mcp_verification_outcome '' 'browser_dom_check')"
assert_eq "empty output → passed (default)" "passed" "${got}"

# ----------------------------------------------------------------------
printf 'Test 11: path-traversal guard in verification_matches_project_test_command\n'
# A malformed project_test_cmd like `bash ../tests/foo.sh` should not
# over-credit a user's `bash tests/other.sh` via family match.
verification_matches_project_test_command 'bash tests/test-x.sh' 'bash ../tests/foo.sh' \
  && { printf '  FAIL: ptc with ../ should be rejected\n' >&2; fail=$((fail + 1)); } \
  || pass=$((pass + 1))

# Direct prefix match still works regardless of ../ presence elsewhere
verification_matches_project_test_command 'bash ../tests/foo.sh extra-args' 'bash ../tests/foo.sh' \
  && pass=$((pass + 1)) \
  || { printf '  FAIL: direct prefix match should not be blocked by ../ in ptc\n' >&2; fail=$((fail + 1)); }

# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
printf 'Test 12: score_verification_confidence_factors emits per-factor breakdown (v1.27.0 F-023)\n'
assert_function_defined score_verification_confidence_factors

# All four factors fire on a full-fat test invocation.
got="$(score_verification_confidence_factors 'npm test -- --runInBand' \
        'PASS auth/login.test.ts'$'\n''Tests: 10 passed, 0 failed' \
        'npm test')"
assert_eq "T12: all four factors fire" \
  "test_match:40|framework:30|output_counts:20|clear_outcome:10|total:100" "${got}"

# Lint-only command (shellcheck): only framework keyword fires.
got="$(score_verification_confidence_factors 'shellcheck script.sh' '' '')"
assert_eq "T12: shellcheck-only → 30 via framework only" \
  "test_match:0|framework:30|output_counts:0|clear_outcome:0|total:30" "${got}"

# Empty cmd → all zeros, total=0.
got="$(score_verification_confidence_factors '' '' '')"
assert_eq "T12: empty cmd → all zeros" \
  "test_match:0|framework:0|output_counts:0|clear_outcome:0|total:0" "${got}"

# Total field equals score_verification_confidence on the same inputs
# (round-trip property).
for inputs in \
  'npm test|PASS|npm test' \
  'shellcheck a.sh||' \
  'bash tests/x.sh|=== Results: 1 passed ===|bash tests/y.sh'; do
  IFS='|' read -r _cmd _out _proj <<<"${inputs}"
  factors_total="$(score_verification_confidence_factors "${_cmd}" "${_out}" "${_proj}" \
    | sed 's/.*total://' )"
  legacy_total="$(score_verification_confidence "${_cmd}" "${_out}" "${_proj}")"
  assert_eq "T12: factors.total == legacy total ($_cmd)" "${legacy_total}" "${factors_total}"
done

# ----------------------------------------------------------------------
printf 'Test 13: classify_verification_scope distinguishes proof breadth\n'
assert_eq "T13: project test command match → full" \
  "full" "$(classify_verification_scope 'npm test -- --runInBand' 'npm test')"
assert_eq "T13: pytest specific test file → targeted" \
  "targeted" "$(classify_verification_scope 'pytest tests/test_auth.py -q' '')"
assert_eq "T13: pytest selector → targeted" \
  "targeted" "$(classify_verification_scope 'pytest -k login' '')"
assert_eq "T13: shellcheck → lint" \
  "lint" "$(classify_verification_scope 'shellcheck bundle/foo.sh' '')"
assert_eq "T13: docker build → build" \
  "build" "$(classify_verification_scope 'docker build .' '')"

printf '\n=== Verification Lib Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
