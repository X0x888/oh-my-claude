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
          detect_mcp_verification_outcome classify_verification_scope \
          verification_command_is_authoritative_execution \
          verification_command_semantic_target _omc_authority_digest \
          verification_command_launcher_path \
          verification_output_reports_zero_execution \
          verification_output_reports_failure \
          verification_output_reports_kind_observation \
          verification_command_requested_evidence_kind \
          verification_receipt_evidence_kind \
          _verification_normalize_proof_path \
          _verification_file_identity \
          _verification_file_identity_review_matches \
          verification_png_decoder_available \
          mcp_verification_embedded_image_digest \
          mcp_verification_screenshot_file_digest; do
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
printf 'Test 5: lib has only audited source-time bootstrap/seal execution\n'
# SHA authority must disable hostile aliases before Bash parses its function
# bodies, then seal the complete chain readonly after definition. Those two
# behavior-tested source regions are explicit; reject every other top-level
# invocation. Recognize both ordinary `name() {` and Bash
# `function name () (` definitions so subshell-bodied helpers stay in-scope.
stray_calls="$(awk '
  /^# BEGIN OMC_SHA_AUTHORITY_SOURCE_(BOOTSTRAP|SEAL)$/ {
    if (audited) print NR ": nested audited source region"
    audited = 1
    next
  }
  /^# END OMC_SHA_AUTHORITY_SOURCE_(BOOTSTRAP|SEAL)$/ {
    if (!audited) print NR ": unmatched audited source-region end"
    audited = 0
    next
  }
  audited { next }
  heredoc && /^PERL$/ { heredoc = 0; next }
  heredoc { next }
  /<<'\''PERL'\''/ { heredoc = 1; next }
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  /^(function[[:space:]]+)?[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\(\)[[:space:]]*[\{\(]?/ {
    in_fn = 1
    next
  }
  /^[\}\)][[:space:]]*$/ { in_fn = 0; next }
  in_fn { next }
  /^[[:space:]]/ { next }
  /^readonly[[:space:]]/ { next }
  { print NR": "$0 }
  END { if (audited) print NR ": unterminated audited source region" }
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
state_io_line="$(awk '
  /^[[:space:]]*(source|\.)[[:space:]]+.*lib\/state-io\.sh/ { print NR; exit }
' "${common}")"
verify_line="$(awk '
  /^[[:space:]]*(if[[:space:]]+![[:space:]]+)?(source|\.)[[:space:]]+.*lib\/verification\.sh/ { print NR; exit }
' "${common}")"
classifier_line="$(awk '
  /^[[:space:]]*(source|\.)[[:space:]]+.*lib\/classifier\.sh/ { print NR; exit }
' "${common}")"
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

# Bare ShellCheck: framework keyword plus authoritative silent completion.
got="$(score_verification_confidence 'shellcheck script.sh' '' '')"
assert_eq "silent shellcheck reaches execution floor" "40" "${got}"

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

# A configured glob is matcher data, not a cwd pathname expansion. Before the
# quoted array split, a colliding filename expanded `mcp__trusted__*` during
# the for-loop and changed which MCP tools could mint verification evidence.
collision_dir="$(mktemp -d)"
touch "${collision_dir}/mcp__trusted__cwd-collision"
got="$(cd "${collision_dir}" \
  && OMC_CUSTOM_VERIFY_MCP_TOOLS='mcp__trusted__*|mcp__other__?' \
  && classify_mcp_verification_tool 'mcp__trusted__runner')"
rm -rf "${collision_dir}"
assert_eq "custom MCP glob is stable across cwd filename collisions" \
  "custom_mcp_tool" "${got}"

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
assert_eq "absent output → failed (no observation)" "failed" "${got}"

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
for decorated in \
  'bash scripts/check-release.sh npm test' \
  'bash scripts/check-release.sh "npm test"'; do
  if verification_matches_project_test_command "${decorated}" 'npm test'; then
    printf '  FAIL: ignored argv borrowed project-test bonus: %s\n' \
      "${decorated}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if verification_matches_project_test_command \
    'CI=1 npm test -- --runInBand' 'npm test'; then
  pass=$((pass + 1))
else
  printf '  FAIL: literal-env actual argv prefix lost project-test bonus\n' >&2
  fail=$((fail + 1))
fi

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

# Silent authoritative lint: framework + hook-observed execution authority.
got="$(score_verification_confidence_factors 'shellcheck script.sh' '' '')"
assert_eq "T12: silent shellcheck reaches the executable floor" \
  "test_match:0|framework:30|output_counts:0|clear_outcome:10|total:40" "${got}"

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

# ----------------------------------------------------------------------
printf 'Test 14: Definition proof rejects discovery and skip modes without rejecting verbosity\n'
for command in \
  'pytest --collect-only' \
  'pytest --co' \
  'pytest --fixtures' \
  'pytest --fixtures-per-test' \
  'jest --listTests' \
  'go test ./... -list .' \
  'cargo test --no-run' \
  'mvn verify -DskipTests' \
  'gradle test -x test' \
  'npm run test --if-present' \
  'vitest --passWithNoTests' \
  'dotnet test -t' \
  'swift test list' \
  'phpunit --list-tests-xml out.xml' \
  'test Q-001' \
  '"pytest fake" tests/test_alpha.py' \
  'bash "$VERIFY_SCRIPT"' \
  'pytest tests/test_*.py'; do
  if verification_command_is_authoritative_execution "${command}" ''; then
    printf '  FAIL: non-executing proof admitted: %s\n' "${command}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if verification_command_is_authoritative_execution 'pytest -v tests/test_auth.py' ''; then
  pass=$((pass + 1))
else
  printf '  FAIL: ordinary lowercase pytest -v was rejected\n' >&2
  fail=$((fail + 1))
fi
if verification_command_is_authoritative_execution 'pytest -V' ''; then
  printf '  FAIL: pytest version mode was admitted\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if verification_command_is_authoritative_execution \
    'bash scripts/validate-release.sh' ''; then
  pass=$((pass + 1))
else
  printf '  FAIL: plainly named custom validation script was rejected\n' >&2
  fail=$((fail + 1))
fi
shadow_root="$(mktemp -d -t verification-builtin-shadow-XXXXXX)"
mkdir -p "${shadow_root}/test"
if (cd "${shadow_root}" \
    && verification_command_is_authoritative_execution 'test anything' ''); then
  printf '  FAIL: shell builtin test borrowed a same-named directory\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
check() { :; }
if verification_command_is_authoritative_execution 'check anything' ''; then
  printf '  FAIL: shell function check became external proof authority\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
unset -f check
rm -rf "${shadow_root}"
if verification_has_framework_keyword 'zsh scripts/validate-release.sh'; then
  pass=$((pass + 1))
else
  printf '  FAIL: authoritative zsh validation script lacked verifier scoring\n' >&2
  fail=$((fail + 1))
fi
for command in \
  'PYTHONPATH=. pytest tests/test_alpha.py' \
  'CI=1 npm test' \
  'RAILS_ENV=test bundle exec rspec' \
  'env CI=1 npm test'; do
  if verification_command_is_authoritative_execution "${command}" ''; then
    printf '  FAIL: environment-prefixed proof retained authority: %s\n' \
      "${command}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for nonexecuting_command in \
  'go test -c ./...' \
  'go test -c=compiled.test ./...' \
  'make test -n' \
  'make test -q' \
  'make test --question' \
  'make test -t' \
  'make test --touch' \
  'make test -qn' \
  'make --just-print test' \
  'make test --dry-run' \
  'shellcheck --list-optional tests/test-verification-lib.sh' \
  'pytest --cache-show' \
  'pytest -o addopts=--collect-only' \
  'pytest -oaddopts=--collect-only' \
  'pytest -o=addopts=--collect-only' \
  'pytest --override-ini=addopts=--collect-only' \
  'pytest --override-ini addopts=--collect-only' \
  'pytest -o addopts=--version' \
  'pytest -o addopts=--help' \
  'python -m pytest --cache-show' \
  'uv run pytest --cache-show' \
  'ruff check --show-files' \
  'ruff check --show-settings' \
  'tsc --init' \
  'swift build --show-bin-path' \
  'jest --clearCache' \
  'npx jest --clearCache' \
  'bash tests/run-tests.sh --cache-show' \
  'phpunit --warm-coverage-cache' \
  'phpunit --list-groups' \
  'xcodebuild test -showBuildSettings' \
  'xcodebuild -showdestinations test'; do
  if verification_command_is_authoritative_execution \
      "${nonexecuting_command}" 'make test'; then
    printf '  FAIL: non-executing mode retained authority: %s\n' \
      "${nonexecuting_command}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for observational_mcp in \
  mcp__github__get_pull_request \
  mcp__github__get_comment \
  mcp__github__get_commit \
  mcp__github__get_open_issue \
  mcp__filesystem__stat \
  mcp__filesystem__stat_file; do
  if mcp_tool_attempts_artifact_mutation "${observational_mcp}" '{}'; then
    printf '  FAIL: observational MCP noun was classified as mutation: %s\n' \
      "${observational_mcp}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if mcp_tool_attempts_artifact_mutation \
    mcp__filesystem__stat_file '{"action":"delete"}'; then
  pass=$((pass + 1))
else
  printf '  FAIL: mutating action did not override stat read-only classification\n' >&2
  fail=$((fail + 1))
fi
for observational_aggregator in \
  'mcp__github__pull_request_read|{"method":"get"}' \
  'mcp__github__pull_request_read|{"method":"get_diff"}' \
  'mcp__github__issue_read|{"method":"get_comments"}'; do
  aggregator_tool="${observational_aggregator%%|*}"
  aggregator_input="${observational_aggregator#*|}"
  if mcp_tool_attempts_artifact_mutation \
      "${aggregator_tool}" "${aggregator_input}"; then
    printf '  FAIL: observational MCP aggregator was classified as mutation: %s\n' \
      "${observational_aggregator}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for mutating_mcp_case in \
  'mcp__postgres__query|{}' \
  'mcp__postgres__query|{"sql":"DELETE FROM jobs"}' \
  'mcp__postgres__query|{"statement":"UPDATE jobs SET done=true"}' \
  'mcp__postgres__query|{"query":"CREATE TABLE receipts(id int)"}' \
  'mcp__sqlite__query|{"query":"PRAGMA writable_schema=ON"}' \
  'mcp__sqlite__query|{"query":"ATTACH DATABASE other.db AS other"}' \
  'mcp__github__get_and_delete|{}' \
  'mcp__github__get_or_create_user|{}' \
  'mcp__filesystem__read_write_file|{}' \
  'mcp__lint__check_and_fix|{}' \
  'mcp__users__find_or_create|{}'; do
  mutating_mcp_tool="${mutating_mcp_case%%|*}"
  mutating_mcp_input="${mutating_mcp_case#*|}"
  if mcp_tool_attempts_artifact_mutation \
      "${mutating_mcp_tool}" "${mutating_mcp_input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: MCP mutation was classified observational: %s\n' \
      "${mutating_mcp_case}" >&2
    fail=$((fail + 1))
  fi
done
if mcp_tool_attempts_artifact_mutation \
    mcp__postgres__query '{"sql":"SELECT id FROM jobs"}'; then
  pass=$((pass + 1))
else
  printf '  FAIL: generic SQL SELECT overclaimed read-only authority\n' >&2
  fail=$((fail + 1))
fi
for output_saving_tool in \
  mcp__plugin_playwright_playwright__browser_snapshot \
  mcp__plugin_playwright_playwright__browser_take_screenshot \
  mcp__plugin_playwright_playwright__browser_console_messages \
  mcp__plugin_playwright_playwright__browser_network_requests; do
  if mcp_tool_attempts_artifact_mutation \
      "${output_saving_tool}" '{"filename":"proof/output.txt"}'; then
    pass=$((pass + 1))
  else
    printf '  FAIL: MCP filename save was classified read-only: %s\n' \
      "${output_saving_tool}" >&2
    fail=$((fail + 1))
  fi
done
for output_destination_input in \
    '{"output_file":"proof/copied.txt"}' \
    '{"options":{"outputFile":"proof/nested-copy.txt"}}'; do
  if mcp_tool_attempts_artifact_mutation \
      mcp__filesystem__read_file "${output_destination_input}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: generic MCP output destination was classified read-only: %s\n' \
      "${output_destination_input}" >&2
    fail=$((fail + 1))
  fi
done
assert_eq "T14: screenshot digest ignores generated transport filename" \
  "$(mcp_verification_observation_digest_material \
    mcp__plugin_playwright_playwright__browser_take_screenshot \
    'Screenshot saved to /tmp/page-20260718-120000.png; pixels=abc123')" \
  "$(mcp_verification_observation_digest_material \
    mcp__plugin_playwright_playwright__browser_take_screenshot \
    'Screenshot saved to /var/tmp/page-20260718-120001.png; pixels=abc123')"
if [[ "$(mcp_verification_observation_digest_material \
      mcp__plugin_playwright_playwright__browser_take_screenshot \
      'Screenshot saved to /tmp/page-20260718-120000.png; pixels=abc123')" \
    != "$(mcp_verification_observation_digest_material \
      mcp__plugin_playwright_playwright__browser_take_screenshot \
      'Screenshot saved to /tmp/page-20260718-120001.png; pixels=changed')" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: screenshot digest normalization erased observation content\n' >&2
  fail=$((fail + 1))
fi
screenshot_tmp="$(mktemp -d "${TMPDIR:-/tmp}/omc-screenshot-test.XXXXXX")"
screenshot_one="${screenshot_tmp}/page-20260718-120000.png"
screenshot_two="${screenshot_tmp}/page-20260718-120001.png"
_verification_decode_base64_file \
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
  "${screenshot_one}"
_verification_decode_base64_file \
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==' \
  "${screenshot_two}"
screenshot_digest_one="$(mcp_verification_screenshot_file_digest \
  mcp__plugin_playwright_playwright__browser_take_screenshot \
  "Screenshot saved to ${screenshot_one}" "${screenshot_tmp}" || true)"
screenshot_digest_two="$(mcp_verification_screenshot_file_digest \
  mcp__plugin_playwright_playwright__browser_take_screenshot \
  "Screenshot saved to ${screenshot_two}" "${screenshot_tmp}" || true)"
if [[ "${screenshot_digest_one}" =~ ^[0-9a-f]{64}$ \
    && "${screenshot_digest_two}" =~ ^[0-9a-f]{64}$ \
    && "${screenshot_digest_one}" != "${screenshot_digest_two}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: screenshot file digest did not bind distinct image bytes\n' >&2
  fail=$((fail + 1))
fi
spaced_screenshot_dir="${screenshot_tmp}/path with spaces"
mkdir -p "${spaced_screenshot_dir}"
spaced_screenshot="${spaced_screenshot_dir}/visual proof.png"
cp "${screenshot_one}" "${spaced_screenshot}"
for spaced_report in \
  "Screenshot saved to ${spaced_screenshot}" \
  "Screenshot saved to \"${spaced_screenshot}\"" \
  "Screenshot saved to '${spaced_screenshot}'"; do
  assert_eq "T14: complete reported screenshot path preserves spaces and quotes" \
    "${screenshot_digest_one}" \
    "$(mcp_verification_screenshot_file_digest \
      mcp__plugin_playwright_playwright__browser_take_screenshot \
      "${spaced_report}" "${screenshot_tmp}" || true)"
done
assert_eq "T14: missing path-only screenshot has no content digest" "" \
  "$(mcp_verification_screenshot_file_digest \
    mcp__plugin_playwright_playwright__browser_take_screenshot \
    'Screenshot saved to /tmp/page-does-not-exist.png' "${screenshot_tmp}" \
    2>/dev/null || true)"
png_base64="$(base64 <"${screenshot_one}" | tr -d '\r\n')"
embedded_hook="$(jq -nc --arg data "${png_base64}" \
  '{tool_response:{content:[{type:"image",mimeType:"image/png",data:$data}]}}')"
if [[ "$(mcp_verification_embedded_image_digest "${embedded_hook}" || true)" \
    =~ ^[0-9a-f]{64}$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: valid embedded PNG content did not mint a digest\n' >&2
  fail=$((fail + 1))
fi
decoder_path_before="${_OMC_OBSERVER_SAFE_PATH}"
_OMC_OBSERVER_SAFE_PATH="${screenshot_tmp}/decoder-unavailable"
if verification_png_decoder_available; then
  printf '  FAIL: missing PNG decoder was reported available\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
_OMC_OBSERVER_SAFE_PATH="${decoder_path_before}"
assert_eq "T14: structured image path is not embedded content" "" \
  "$(mcp_verification_embedded_image_digest \
    '{"tool_response":{"type":"image","url":"/tmp/page.png"}}' \
    2>/dev/null || true)"
assert_eq "T14: unvalidated image data is not embedded pixels" "" \
  "$(mcp_verification_embedded_image_digest \
    '{"tool_response":{"type":"image","mimeType":"image/png","data":"eA=="}}' \
    2>/dev/null || true)"
assert_eq "T14: PNG signature alone is not a renderable image" "" \
  "$(mcp_verification_embedded_image_digest \
    '{"tool_response":{"content":[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="}]}}' \
    2>/dev/null || true)"
header_only_png="${screenshot_tmp}/page-header-only.png"
printf '\211PNG\r\n\032\n' >"${header_only_png}"
assert_eq "T14: path-only PNG signature cannot mint visual authority" "" \
  "$(mcp_verification_screenshot_file_digest \
    mcp__plugin_playwright_playwright__browser_take_screenshot \
    "Screenshot saved to ${header_only_png}" "${screenshot_tmp}" \
    2>/dev/null || true)"
corrupt_crc_png="${screenshot_tmp}/page-corrupt-crc.png"
corrupt_idat_png="${screenshot_tmp}/page-corrupt-idat.png"
empty_idat_png="${screenshot_tmp}/page-empty-idat.png"
perl -MCompress::Raw::Zlib=crc32 -e '
  use strict; use warnings;
  my ($source, $crc_out, $idat_out, $empty_idat_out) = @ARGV;
  open my $in, "<:raw", $source or die $!; local $/; my $png = <$in>;
  close $in or die $!;
  my $pos = 8; my ($idat_data_pos, $idat_len, $idat_crc_pos);
  while ($pos < length($png)) {
    my $len = unpack("N", substr($png, $pos, 4));
    my $type = substr($png, $pos + 4, 4);
    if ($type eq "IDAT") {
      ($idat_data_pos, $idat_len, $idat_crc_pos) =
        ($pos + 8, $len, $pos + 8 + $len);
      last;
    }
    $pos += 12 + $len;
  }
  defined($idat_crc_pos) && $idat_len > 0 or die "missing IDAT";
  my $crc_png = $png;
  substr($crc_png, $idat_crc_pos, 1) =
    chr(ord(substr($crc_png, $idat_crc_pos, 1)) ^ 1);
  open my $crc_fh, ">:raw", $crc_out or die $!;
  print {$crc_fh} $crc_png; close $crc_fh or die $!;
  my $idat_png = $png;
  substr($idat_png, $idat_data_pos, 1) = "\0";
  my $changed = substr($idat_png, $idat_data_pos, $idat_len);
  substr($idat_png, $idat_crc_pos, 4) =
    pack("N", crc32("IDAT" . $changed) & 0xffffffff);
  open my $idat_fh, ">:raw", $idat_out or die $!;
  print {$idat_fh} $idat_png; close $idat_fh or die $!;
  my $empty_chunk = pack("N", 0) . "IDAT"
    . pack("N", crc32("IDAT") & 0xffffffff);
  my $empty_idat_png = $png;
  substr($empty_idat_png, $idat_crc_pos + 4, 0) = $empty_chunk;
  open my $empty_fh, ">:raw", $empty_idat_out or die $!;
  print {$empty_fh} $empty_idat_png; close $empty_fh or die $!;
' "${screenshot_one}" "${corrupt_crc_png}" "${corrupt_idat_png}" \
  "${empty_idat_png}"
for corrupt_png in "${corrupt_crc_png}" "${corrupt_idat_png}"; do
  assert_eq "T14: corrupt CRC or IDAT cannot mint decoded-pixel authority" "" \
    "$(mcp_verification_screenshot_file_digest \
      mcp__plugin_playwright_playwright__browser_take_screenshot \
      "Screenshot saved to ${corrupt_png}" "${screenshot_tmp}" \
      2>/dev/null || true)"
done
if [[ "$(mcp_verification_screenshot_file_digest \
    mcp__plugin_playwright_playwright__browser_take_screenshot \
    "Screenshot saved to ${empty_idat_png}" "${screenshot_tmp}" || true)" \
    =~ ^[0-9a-f]{64}$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: valid zero-length IDAT chunk was rejected\n' >&2
  fail=$((fail + 1))
fi

portable_hash_tmp="$(mktemp -d "${TMPDIR:-/tmp}/omc-hash-test.XXXXXX")"
portable_expected="$(_verification_sha256_text 'portable-image-content')"
portable_hasher="$(_verification_trusted_sha256_executable)"
idempotent_authority_actual="$(bash -c '
  . "$1"
  . "$1"
  _verification_sha256_text portable-image-content
' bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh")"
assert_eq "T14: common re-source preserves the sealed authority chain" \
  "${portable_expected}" "${idempotent_authority_actual}"
set +e
post_source_override_actual="$({
  ( eval '_verification_sha256_text() { printf "%064d" 0; }' ) 2>/dev/null
  override_rc=$?
  ( unset -f _verification_sha256_text ) 2>/dev/null
  unset_rc=$?
  digest="$(_verification_sha256_text 'portable-image-content')"
  printf '%s|%s|%s' "${override_rc}" "${unset_rc}" "${digest}"
})"
post_source_override_rc=$?
set -e
IFS='|' read -r redefine_rc authority_unset_rc sealed_digest \
  <<<"${post_source_override_actual}"
if (( post_source_override_rc == 0 && redefine_rc != 0 \
    && authority_unset_rc != 0 )) \
    && [[ "${sealed_digest}" == "${portable_expected}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: post-source authority helper replacement was not sealed (%q)\n' \
    "${post_source_override_actual}" >&2
  fail=$((fail + 1))
fi
set +e
readonly_conflict_out="$(BASH_ENV=/dev/null bash -c '
  _omc_authority_digest() { printf forged; }
  readonly -f _omc_authority_digest
  if . "$1"; then
    exit 0
  fi
  [[ -z "${_OMC_COMMON_SOURCED:-}" ]] || exit 98
  [[ ! -o posix && "${POSIXLY_CORRECT+x}" != x ]] || exit 99
  exit 97
' bash "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" 2>&1)"
readonly_conflict_rc=$?
set -e
if (( readonly_conflict_rc == 97 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: preexisting readonly authority conflict did not fail cleanly (rc=%s): %s\n' \
    "${readonly_conflict_rc}" "${readonly_conflict_out}" >&2
  fail=$((fail + 1))
fi
case "${portable_hasher}" in
  /usr/bin/shasum|/usr/bin/sha256sum|/bin/shasum|/bin/sha256sum|/usr/sbin/shasum|/usr/sbin/sha256sum|/sbin/shasum|/sbin/sha256sum)
    [[ -f "${portable_hasher}" && -x "${portable_hasher}" \
        && ! -L "${portable_hasher}" ]] \
      && pass=$((pass + 1)) \
      || { printf '  FAIL: trusted SHA resolver returned an unsafe node\n' >&2; fail=$((fail + 1)); }
    ;;
  /nix/store/*/bin/shasum|/nix/store/*/bin/sha256sum)
    [[ -f "${portable_hasher}" && -x "${portable_hasher}" ]] \
      && pass=$((pass + 1)) \
      || { printf '  FAIL: trusted SHA resolver returned an unsafe Nix node\n' >&2; fail=$((fail + 1)); }
    ;;
  *)
    printf '  FAIL: trusted SHA resolver returned %q\n' \
      "${portable_hasher}" >&2
    fail=$((fail + 1))
    ;;
esac
printf '#!/bin/sh\nprintf "%%064d\\n" 0\n' >"${portable_hash_tmp}/shasum"
printf '#!/bin/sh\nprintf "%%064d\\n" 0\n' >"${portable_hash_tmp}/sha256sum"
chmod +x "${portable_hash_tmp}/shasum"
chmod +x "${portable_hash_tmp}/sha256sum"
assert_eq "T14: caller PATH cannot replace the image digest observer" \
  "${portable_expected}" "$(PATH="${portable_hash_tmp}" \
    _verification_sha256_text 'portable-image-content')"
portable_function_actual="$({
  shasum() { printf '%064d  -\n' 0; }
  sha256sum() { printf '%064d  -\n' 0; }
  export -f shasum sha256sum
  _verification_sha256_text 'portable-image-content'
})"
assert_eq "T14: forged SHA shell functions cannot replace exact observer" \
  "${portable_expected}" "${portable_function_actual}"
portable_builtin_shim_actual="$({
  # shellcheck disable=SC2294 # trusted test fixture path; exercise slash-named functions.
  eval "function ${portable_hasher}() { return 81; }"
  builtin() { return 82; }
  command() { return 83; }
  printf() { return 84; }
  read() { return 85; }
  local() { return 86; }
  _verification_sha256_text 'portable-image-content'
})"
assert_eq "T14: builtin/command/printf and exact-path functions cannot forge authority" \
  "${portable_expected}" "${portable_builtin_shim_actual}"
if ({
  builtin() { return 82; }
  readonly -f builtin
  _verification_sha256_text 'portable-image-content'
}) >/dev/null 2>&1; then
  printf '  FAIL: readonly builtin shim did not fail SHA authority closed\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
portable_hash_file="${portable_hash_tmp}/authority-input"
printf '%s' 'portable-image-content' >"${portable_hash_file}"
portable_file_actual="$({
  shasum() { printf '%064d  forged\n' 0; }
  sha256sum() { printf '%064d  forged\n' 0; }
  export -f shasum sha256sum
  _verification_sha256_file "${portable_hash_file}"
})"
assert_eq "T14: authority file hashing shares the exact SHA observer" \
  "${portable_expected}" "${portable_file_actual}"
portable_bash_env="${portable_hash_tmp}/forged-bash-env"
printf '%s\n' \
  'shopt -s expand_aliases' \
  "alias builtin='return 101'" \
  "alias unset='return 102'" \
  "alias local='return 103'" \
  "alias _verification_sanitize_sha256_shell='return 104'" \
  "alias _verification_sha256_text='return 105'" \
  "alias _omc_authority_digest='return 106'" \
  'source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/verification.sh"' \
  'eval "function ${PORTABLE_HASHER}() { return 91; }"' \
  'builtin() { return 92; }' \
  'command() { return 93; }' \
  'printf() { return 94; }' \
  'read() { return 95; }' \
  'local() { return 96; }' \
  'shasum() { printf "%064d  -\\n" 0; }' \
  'sha256sum() { printf "%064d  -\\n" 0; }' \
  'export -f shasum sha256sum' >"${portable_bash_env}"
portable_bash_env_actual="$(BASH_ENV="${portable_bash_env}" \
  REPO_ROOT="${REPO_ROOT}" PORTABLE_HASHER="${portable_hasher}" \
  bash -c '_verification_sha256_text "portable-image-content"')"
assert_eq "T14: BASH_ENV builtin and SHA functions cannot forge authority digest" \
  "${portable_expected}" "${portable_bash_env_actual}"
portable_bash_env_authority="$(BASH_ENV="${portable_bash_env}" \
  REPO_ROOT="${REPO_ROOT}" PORTABLE_HASHER="${portable_hasher}" \
  bash -c '_omc_authority_digest "portable-image-content"')"
assert_eq "T14: BASH_ENV authority-helper aliases are disabled before parsing" \
  "${portable_expected:0:24}" "${portable_bash_env_authority}"
if _OMC_OBSERVER_SAFE_PATH="${portable_hash_tmp}" \
    _omc_authority_digest 'definition-authority' >/dev/null 2>&1; then
  printf '  FAIL: authority digest accepted an untrusted writable SHA tool\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
rm -f -- "${portable_hash_tmp}/sha256sum" \
  "${portable_hash_tmp}/shasum" "${portable_hash_file}" \
  "${portable_bash_env}"
rmdir -- "${portable_hash_tmp}"
rm -f -- "${spaced_screenshot}"
rmdir -- "${spaced_screenshot_dir}"
rm -f -- "${screenshot_one}" "${screenshot_two}" "${header_only_png}" \
  "${corrupt_crc_png}" "${corrupt_idat_png}" "${empty_idat_png}"
rmdir -- "${screenshot_tmp}"
assert_eq "T14: named run-tests script can reach default threshold" "60" \
  "$(score_verification_confidence 'bash tools/run-tests.sh' \
    '1 test passed; exit code: 0' '')"
assert_eq "T14: extensionless named verifier can reach default threshold" "60" \
  "$(score_verification_confidence './scripts/verify-release' \
    '1 test passed; exit code: 0' '')"

# ----------------------------------------------------------------------
printf 'Test 15: proof identity binds wrapper policy and real selectors\n'
_omc_load_quality_contract
literal_path_tmp="$(mktemp -d "${TMPDIR:-/tmp}/omc-literal-path.XXXXXX")"
plain_source_path="${literal_path_tmp}/foo"
quoted_source_path="${literal_path_tmp}/\"foo\""
newline_source_path="${literal_path_tmp}/foo"$'\n''bar'
printf '%s\n' plain >"${plain_source_path}"
printf '%s\n' quoted >"${quoted_source_path}"
printf '%s\n' newline >"${newline_source_path}"
literal_path_root="$(_verification_normalize_proof_path \
  "${literal_path_tmp}")"
assert_eq "T15: literal quote filename retains its own source identity" \
  "${literal_path_root}/\"foo\"" \
  "$(_verification_normalize_proof_path "${quoted_source_path}" 0 source)"
if [[ "$(_verification_normalize_proof_path "${plain_source_path}" 0 source)" \
    != "$(_verification_normalize_proof_path "${quoted_source_path}" 0 source)" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: literal quote source filename aliased its unquoted sibling\n' >&2
  fail=$((fail + 1))
fi
assert_eq "T15: control-byte source path fails closed" "" \
  "$(_verification_normalize_proof_path "${newline_source_path}" 0 source \
    2>/dev/null || true)"
chmod +x "${plain_source_path}" "${quoted_source_path}"
assert_eq "T15: literal quote executable retains its runner identity" \
  "${literal_path_root}/\"foo\"" \
  "$(_verification_normalize_proof_path "${quoted_source_path}" 0 executable)"
rm -f -- "${plain_source_path}" "${quoted_source_path}" \
  "${newline_source_path}"
rmdir -- "${literal_path_tmp}"
target_a="$(verification_command_semantic_target \
  'bash tests/check-release.sh Q-001' '')"
target_b="$(verification_command_semantic_target \
  'bash ./tests/../tests/check-release.sh Q-005' '')"
if [[ "${target_a}" != "${target_b}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: custom-script argv policy was not bound into proof target\n' >&2
  fail=$((fail + 1))
fi
if _quality_contract_bash_targets_overlap "${target_a}" "${target_b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: custom-script argv minted independent criterion scopes\n' >&2
  fail=$((fail + 1))
fi
plain_env_pytest="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py' '')"
python_module_pytest="$(verification_command_semantic_target \
  'python3 -m pytest tests/test_alpha.py' '')"
npx_pytest="$(verification_command_semantic_target \
  'npx pytest tests/test_alpha.py' '')"
[[ -n "${plain_env_pytest}" ]] && pass=$((pass + 1)) \
  || { printf '  FAIL: plain pytest lost semantic target\n' >&2; fail=$((fail + 1)); }
assert_eq "T15: pytest and python -m pytest share one suite surface" \
  "${plain_env_pytest}" "${python_module_pytest}"
assert_eq "T15: pytest and npx pytest share one suite surface" \
  "${plain_env_pytest}" "${npx_pytest}"
for prefixed_proof in \
  'PYTHONPATH=. pytest tests/test_alpha.py' \
  'env CI=1 pytest tests/test_alpha.py' \
  'env "CI=1" pytest tests/test_alpha.py' \
  'env CI\=1 pytest tests/test_alpha.py'; do
  if verification_command_semantic_target "${prefixed_proof}" '' \
      >/dev/null 2>&1; then
    printf '  FAIL: environment-prefixed Definition proof was admitted: %s\n' \
      "${prefixed_proof}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
target_sh="$(verification_command_semantic_target \
  'sh tests/check-release.sh Q-001' '')"
target_direct="$(verification_command_semantic_target \
  './tests/check-release.sh Q-001' '')"
assert_eq "T15: shell choice cannot split one custom-script target" \
  "${target_a}" "${target_sh}"
assert_eq "T15: direct and interpreter launch share one script target" \
  "${target_a}" "${target_direct}"
pytest_a="$(verification_command_semantic_target \
  'pytest -q tests/test_alpha.py' '')"
pytest_a_alias="$(verification_command_semantic_target \
  'pytest -q ./tests/../tests/test_alpha.py' '')"
pytest_b="$(verification_command_semantic_target \
  'pytest -q tests/test_beta.py' '')"
assert_eq "T15: path alias and opaque pytest label share one target" \
  "${pytest_a}" "${pytest_a_alias}"
if [[ "${pytest_a}" != "${pytest_b}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: distinct pytest files collapsed to one semantic target\n' >&2
  fail=$((fail + 1))
fi
opaque_a="$(verification_command_semantic_target \
  'pytest --opaque /tmp/Q-001 tests/test_alpha.py' '')"
opaque_b="$(verification_command_semantic_target \
  'pytest --opaque /tmp/Q-999 tests/test_beta.py' '')"
assert_eq "T15: unknown option path values cannot mint target identities" \
  "${opaque_a}" "${opaque_b}"
unknown_before="$(verification_command_semantic_target \
  'pytest --maxfail 1 tests/test_alpha.py' '')"
unknown_after="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py --maxfail 1' '')"
assert_eq "T15: unknown option order collapses the whole selector vector" \
  "${unknown_before}" "${unknown_after}"
cwd_dot="$(verification_command_semantic_target 'pytest .' '')"
cwd_absolute="$(verification_command_semantic_target \
  "pytest \"${REPO_ROOT}\"" '')"
assert_eq "T15: dot and absolute cwd aliases share one target" \
  "${cwd_dot}" "${cwd_absolute}"
duplicate_selector="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py ./tests/../tests/test_alpha.py' '')"
assert_eq "T15: repeated selector aliases cannot mint tuple multiplicity" \
  "${pytest_a}" "${duplicate_selector}"
selector_pair="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py tests/test_beta.py' '')"
selector_pair_reversed="$(verification_command_semantic_target \
  'pytest tests/test_beta.py tests/test_alpha.py' '')"
assert_eq "T15: selector tuple ordering cannot mint a new target" \
  "${selector_pair}" "${selector_pair_reversed}"
unknown_equals="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py --maxfail=1' '')"
assert_eq "T15: unknown equals/split option spellings collapse equally" \
  "${unknown_after}" "${unknown_equals}"
proof_alias_dir="$(mktemp -d -t verification-proof-alias-XXXXXX)"
proof_alias_dir="$(_verification_normalize_proof_path "${proof_alias_dir}")"
ln -s "${REPO_ROOT}/tests/test-verification-lib.sh" \
  "${proof_alias_dir}/test-proof-a.sh"
ln -s "${REPO_ROOT}/tests/test-verification-lib.sh" \
  "${proof_alias_dir}/test-proof-b.sh"
alias_a="$(verification_command_semantic_target \
  "bash ${proof_alias_dir}/test-proof-a.sh Q-001" '')"
alias_b="$(verification_command_semantic_target \
  "bash ${proof_alias_dir}/test-proof-b.sh Q-999" '')"
assert_eq "T15: symlink aliases share the physical execution surface" \
  "${alias_a%%|policy=*}" "${alias_b%%|policy=*}"
if _quality_contract_bash_targets_overlap "${alias_a}" "${alias_b}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: symlink aliases minted independent criterion scopes\n' >&2
  fail=$((fail + 1))
fi
: >"${proof_alias_dir}/pytest"
chmod +x "${proof_alias_dir}/pytest"
ln -s "${proof_alias_dir}/pytest" "${proof_alias_dir}/pytest-alias"
absolute_pytest="$(verification_command_semantic_target \
  "${proof_alias_dir}/pytest tests/test_alpha.py" '' 2>/dev/null || true)"
bare_pytest="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py' '')"
path_alias_pytest="$(PATH="${proof_alias_dir}:${PATH}" \
  verification_command_semantic_target \
    'pytest-alias tests/test_alpha.py' '' 2>/dev/null || true)"
if [[ -n "${absolute_pytest}" ]]; then
  printf '  FAIL: explicit fake pytest received semantic proof authority\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
[[ -n "${path_alias_pytest}" ]] && pass=$((pass + 1)) \
  || { printf '  FAIL: session-canonical PATH alias lost authority\n' >&2; fail=$((fail + 1)); }
[[ -n "${bare_pytest}" ]] && pass=$((pass + 1)) \
  || { printf '  FAIL: canonical pytest lost semantic authority\n' >&2; fail=$((fail + 1)); }
printf '%s\n' '#!/bin/sh' 'exit 0' >"${proof_alias_dir}/python3"
chmod +x "${proof_alias_dir}/python3"
observer_path_before="${PATH}"
if [[ -n "${_OMC_HOOK_CALLER_PATH+x}" ]]; then
  caller_path_was_set=1
  caller_path_before="${_OMC_HOOK_CALLER_PATH}"
else
  caller_path_was_set=0
  caller_path_before=""
fi
_OMC_HOOK_CALLER_PATH="${proof_alias_dir}:${observer_path_before}"
PATH="${_OMC_OBSERVER_SAFE_PATH}"
assert_eq "T15: pinned observer PATH resolves the caller's direct runner" \
  "$(_verification_normalize_proof_path \
    "${proof_alias_dir}/pytest" 0 executable)" \
  "$(verification_command_launcher_path \
    'pytest tests/test_alpha.py' 2>/dev/null || true)"
assert_eq "T15: pinned observer PATH resolves the caller's module interpreter" \
  "$(_verification_normalize_proof_path \
    "${proof_alias_dir}/python3" 0 executable)" \
  "$(verification_command_launcher_path \
    'python3 -m pytest tests/test_alpha.py' 2>/dev/null || true)"
caller_direct_target="$(verification_command_semantic_target \
  'pytest tests/test_alpha.py' '' 2>/dev/null || true)"
caller_module_target="$(verification_command_semantic_target \
  'python3 -m pytest tests/test_alpha.py' '' 2>/dev/null || true)"
assert_eq "T15: caller direct/module aliases retain one semantic target" \
  "${caller_direct_target}" "${caller_module_target}"
PATH="${observer_path_before}"
if [[ "${caller_path_was_set}" -eq 1 ]]; then
  _OMC_HOOK_CALLER_PATH="${caller_path_before}"
else
  unset _OMC_HOOK_CALLER_PATH
fi
for runner in mypy swift xcodebuild; do
  : >"${proof_alias_dir}/${runner}"
  chmod +x "${proof_alias_dir}/${runner}"
  bare_runner_target="$(verification_command_semantic_target \
    "${runner} $([[ "${runner}" == swift ]] && printf test || \
      { [[ "${runner}" == xcodebuild ]] && printf test || printf src; })" '' \
      2>/dev/null || true)"
  absolute_runner_target="$(verification_command_semantic_target \
    "${proof_alias_dir}/${runner} $([[ "${runner}" == swift ]] && printf test || \
      { [[ "${runner}" == xcodebuild ]] && printf test || printf src; })" '' \
      2>/dev/null || true)"
  if [[ -n "${absolute_runner_target}" ]]; then
    printf '  FAIL: explicit fake %s received semantic proof authority\n' \
      "${runner}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
shell_syntax_bare="$(verification_command_semantic_target \
  'bash -n tests/test-verification-lib.sh' '')"
shell_syntax_absolute="$(verification_command_semantic_target \
  '/bin/bash -n tests/test-verification-lib.sh' '')"
assert_eq "T15: absolute shell syntax launcher cannot split one target" \
  "${shell_syntax_bare}" "${shell_syntax_absolute}"
shell_syntax_double_dash="$(verification_command_semantic_target \
  'bash -n -- tests/test-verification-lib.sh' '')"
assert_eq "T15: shell -- terminator preserves the syntax target" \
  "${shell_syntax_bare}" "${shell_syntax_double_dash}"
canonical_verification_script="$(_verification_normalize_proof_path \
  "${REPO_ROOT}/tests/test-verification-lib.sh" 0 executable)"
for interpreter_command in \
  'bash -e tests/test-verification-lib.sh' \
  'bash --norc tests/test-verification-lib.sh' \
  'bash -n -- tests/test-verification-lib.sh' \
  'python3 tests/test-verification-lib.sh'; do
  assert_eq "T15: interpreter options preserve the concrete script subject: ${interpreter_command}" \
    "${canonical_verification_script}" \
    "$(verification_command_subject_path \
      "${interpreter_command}" "${REPO_ROOT}" 2>/dev/null || true)"
done
assert_eq "T15: unresolved Python module bytes fail closed as proof subject" "" \
  "$(verification_command_subject_path \
    'python3 -m pytest tests/test-verification-lib.sh' \
    "${REPO_ROOT}" 2>/dev/null || true)"
symlink_subject_root="$(mktemp -d -t verification-symlink-subject-XXXXXX)"
mkdir -p "${symlink_subject_root}/real"
printf '%s\n' '#!/bin/sh' 'exit 0' \
  >"${symlink_subject_root}/real/check.sh"
chmod +x "${symlink_subject_root}/real/check.sh"
ln -s real "${symlink_subject_root}/current"
assert_eq "T15: mutable symlink ancestors cannot establish proof provenance" "" \
  "$(verification_command_subject_path \
    "bash ${symlink_subject_root}/current/check.sh" \
    "${REPO_ROOT}" 2>/dev/null || true)"
rm -f -- "${symlink_subject_root}/current" \
  "${symlink_subject_root}/real/check.sh"
rmdir -- "${symlink_subject_root}/real" "${symlink_subject_root}"
ancestry_identity_root="$(mktemp -d -t verification-ancestry-XXXXXX)"
mkdir -p "${ancestry_identity_root}/tests"
printf '%s\n' stable >"${ancestry_identity_root}/tests/check.sh"
ancestry_identity_before="$(_verification_file_identity \
  "${ancestry_identity_root}/tests/check.sh" \
  "${ancestry_identity_root}")"
printf '%s\n' unrelated >"${ancestry_identity_root}/tests/sibling.txt"
ancestry_identity_after_sibling="$(_verification_file_identity \
  "${ancestry_identity_root}/tests/check.sh" \
  "${ancestry_identity_root}")"
if [[ "${ancestry_identity_before}" != "${ancestry_identity_after_sibling}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: sibling churn did not change strict proof identity\n' >&2
  fail=$((fail + 1))
fi
if _verification_file_identity_review_matches \
    "${ancestry_identity_before}" "${ancestry_identity_after_sibling}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: sibling churn invalidated durable settled-state identity\n' >&2
  fail=$((fail + 1))
fi
rm -f -- "${ancestry_identity_root}/tests/sibling.txt"
ancestry_identity_other_parent="${ancestry_identity_before%:s:*}:s:$(printf '0%.0s' {1..64})"
if _verification_file_identity_review_matches \
    "${ancestry_identity_before}" "${ancestry_identity_other_parent}"; then
  printf '  FAIL: changed stable ancestor projection retained durable identity\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
mv "${ancestry_identity_root}/tests" \
  "${ancestry_identity_root}/tests.original"
mkdir -p "${ancestry_identity_root}/tests"
printf '%s\n' replacement >"${ancestry_identity_root}/tests/check.sh"
rm -f -- "${ancestry_identity_root}/tests/check.sh"
rmdir -- "${ancestry_identity_root}/tests"
mv "${ancestry_identity_root}/tests.original" \
  "${ancestry_identity_root}/tests"
ancestry_identity_after="$(_verification_file_identity \
  "${ancestry_identity_root}/tests/check.sh" \
  "${ancestry_identity_root}")"
if [[ "${ancestry_identity_before}" != "${ancestry_identity_after}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: restored ancestor directory retained its old proof identity\n' >&2
  fail=$((fail + 1))
fi
rm -f -- "${ancestry_identity_root}/tests/check.sh"
rmdir -- "${ancestry_identity_root}/tests" "${ancestry_identity_root}"
mkdir -p "${proof_alias_dir}/my suite"
: >"${proof_alias_dir}/my suite/test_alpha.py"
quoted_target="$(verification_command_semantic_target \
  "pytest \"${proof_alias_dir}/my suite/test_alpha.py\"" '')"
escaped_target="$(verification_command_semantic_target \
  "pytest ${proof_alias_dir}/my\\ suite/test_alpha.py" '')"
single_quoted_target="$(verification_command_semantic_target \
  "pytest '${proof_alias_dir}/my suite/test_alpha.py'" '')"
assert_eq "T15: double-quoted and escaped paths share one target" \
  "${quoted_target}" "${escaped_target}"
assert_eq "T15: single-quoted and double-quoted paths share one target" \
  "${quoted_target}" "${single_quoted_target}"
double_backslash_target="$(verification_command_semantic_target \
  'pytest "tests/test_back\slash.py"' '')"
single_backslash_target="$(verification_command_semantic_target \
  "pytest 'tests/test_back\\slash.py'" '')"
assert_eq "T15: double-quoted non-special backslash remains literal" \
  "${single_backslash_target}" "${double_backslash_target}"
param_target="$(verification_command_semantic_target \
  "pytest 'tests/test_alpha.py::test_case[param]'" '')"
assert_eq "T15: parametrized pytest node IDs remain authoritative" \
  "pytest:$(_verification_normalize_proof_path \
    "${REPO_ROOT}/tests/test_alpha.py")::test_case[param]" "${param_target}"
future_relative="$(verification_command_semantic_target \
  'pytest tests/omc_future_selector.py' '')"
future_absolute="$(verification_command_semantic_target \
  "pytest \"${REPO_ROOT}/tests/omc_future_selector.py\"" '')"
assert_eq "T15: future relative and absolute selectors share one target" \
  "${future_relative}" "${future_absolute}"
multibyte_component="check-"
for ((idx=0; idx<64; idx++)); do
  multibyte_component="${multibyte_component}💥"
done
multibyte_component="${multibyte_component}.sh"
if _verification_normalize_proof_path \
    "${proof_alias_dir}/${multibyte_component}" >/dev/null 2>&1; then
  printf '  FAIL: >255-byte multibyte path component was normalized\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
future_case_a="$(verification_command_semantic_target \
  "pytest ${proof_alias_dir}/Future-Selector.py" '')"
future_case_b="$(verification_command_semantic_target \
  "pytest ${proof_alias_dir}/future-selector.py" '')"
if _verification_directory_case_insensitive "${proof_alias_dir}"; then
  assert_eq "T15: future case aliases collapse on case-insensitive volumes" \
    "${future_case_a}" "${future_case_b}"
else
  pass=$((pass + 1))
fi
case_probe_dir="${proof_alias_dir}/large-case-probe"
mkdir -p "${case_probe_dir}"
for ((idx=0; idx<1200; idx++)); do
  : >"${case_probe_dir}/entry-${idx}-MixedCase"
done
SECONDS=0
if _verification_directory_case_insensitive "${case_probe_dir}"; then
  # A genuinely case-insensitive volume may need the exact-entry scan. The
  # Linux regression this guards is specifically the missing-alternate path.
  pass=$((pass + 1))
elif (( SECONDS < 5 )); then
  pass=$((pass + 1))
else
  printf '  FAIL: case-sensitive directory probe regressed beyond 5 seconds\n' >&2
  fail=$((fail + 1))
fi
mkdir -p "${proof_alias_dir}/hardlink-case-probe"
: >"${proof_alias_dir}/hardlink-case-probe/Marker"
if ln "${proof_alias_dir}/hardlink-case-probe/Marker" \
    "${proof_alias_dir}/hardlink-case-probe/mARKER" 2>/dev/null; then
  if _verification_directory_case_insensitive \
      "${proof_alias_dir}/hardlink-case-probe"; then
    printf '  FAIL: case-variant hardlinks impersonated a case-insensitive volume\n' >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
else
  # The host rejected the second spelling, which itself establishes a
  # case-insensitive directory for this fixture.
  pass=$((pass + 1))
fi
: >"${proof_alias_dir}/future-selector.py"
future_case_after="$(verification_command_semantic_target \
  "pytest ${proof_alias_dir}/Future-Selector.py" '')"
assert_eq "T15: future target identity survives later file creation" \
  "${future_case_a}" "${future_case_after}"
if verification_command_is_authoritative_execution \
    'pytest tests/test_alpha.py::test_case[param]' ''; then
  printf '  FAIL: unquoted bracket glob was admitted as literal proof argv\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if verification_command_semantic_target 'pytest ~other/tests/test_alpha.py' '' \
    >/dev/null 2>&1; then
  printf '  FAIL: environment-owned ~user expansion minted a proof target\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
tilde_fixture_root="${proof_alias_dir}/tilde-provenance"
mkdir -p "${tilde_fixture_root}/home" "${tilde_fixture_root}/~/" \
  "${tilde_fixture_root}/bin"
: >"${tilde_fixture_root}/home/check-proof.sh"
: >"${tilde_fixture_root}/~/check-proof.sh"
tilde_home_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  verification_command_semantic_target 'bash ~/check-proof.sh' ''
)"
tilde_quoted_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  verification_command_semantic_target 'bash "~/check-proof.sh"' ''
)"
tilde_escaped_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  verification_command_semantic_target 'bash \~/check-proof.sh' ''
)"
if [[ "${tilde_home_target}" == "${tilde_quoted_target}" ]]; then
  printf '  FAIL: quoted tilde collapsed into HOME-expanded proof target\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_eq "T15: escaped and quoted tilde retain the same literal cwd target" \
  "${tilde_quoted_target}" "${tilde_escaped_target}"
: >"${tilde_fixture_root}/home/Cargo.toml"
: >"${tilde_fixture_root}/~/Cargo.toml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${tilde_fixture_root}/bin/cargo"
chmod +x "${tilde_fixture_root}/bin/cargo"
for fixture_runner in go npm pnpm yarn bun npx uv pytest vitest jest rspec \
    phpunit swift gradle xcodebuild mvn dotnet deno mix; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    >"${tilde_fixture_root}/bin/${fixture_runner}"
  chmod +x "${tilde_fixture_root}/bin/${fixture_runner}"
done
semantic_with_fixture_path() {
  PATH="${tilde_fixture_root}/bin:${PATH}" \
    verification_command_semantic_target "$@"
}
authoritative_with_fixture_path() {
  PATH="${tilde_fixture_root}/bin:${PATH}" \
    verification_command_is_authoritative_execution "$@"
}
assert_definition_scope_rejected() {
  local label="$1" command="$2"
  if authoritative_with_fixture_path "${command}" '' >/dev/null 2>&1; then
    printf '  FAIL: %s retained broad Definition authority: %s\n' \
      "${label}" "${command}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}
assert_definition_scope_allowed() {
  local label="$1" command="$2"
  if authoritative_with_fixture_path "${command}" '' >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s lost Definition authority: %s\n' \
      "${label}" "${command}" >&2
    fail=$((fail + 1))
  fi
}
cargo_split_tilde_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  semantic_with_fixture_path \
    'cargo test --manifest-path ~/Cargo.toml' ''
)"
cargo_equals_tilde_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  semantic_with_fixture_path \
    'cargo test --manifest-path=~/Cargo.toml' ''
)"
cargo_quoted_tilde_target="$(
  cd "${tilde_fixture_root}" || exit 1
  HOME="${tilde_fixture_root}/home"
  export HOME
  semantic_with_fixture_path \
    'cargo test --manifest-path "~/Cargo.toml"' ''
)"
if [[ "${cargo_split_tilde_target}" == "${cargo_equals_tilde_target}" ]]; then
  printf '  FAIL: option-value tilde collapsed literal and HOME targets\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_eq "T15: quoted split and equals-option tilde stay cwd-relative" \
  "${cargo_quoted_tilde_target}" "${cargo_equals_tilde_target}"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${tilde_fixture_root}/bin/FOO=x"
chmod +x "${tilde_fixture_root}/bin/FOO=x"
for quoted_assignment in '"FOO=x" pytest tests/test_ok.py' \
    'FOO\=x pytest tests/test_ok.py'; do
  if PATH="${tilde_fixture_root}/bin:${PATH}" \
      verification_command_is_authoritative_execution \
        "${quoted_assignment}" ''; then
    printf '  FAIL: quoted/escaped assignment-like executable was stripped: %s\n' \
      "${quoted_assignment}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if verification_command_is_authoritative_execution \
    'FOO="x y" pytest tests/test_ok.py' ''; then
  printf '  FAIL: shell assignment prefix retained Definition authority\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${tilde_fixture_root}/target-check-proof"
chmod +x "${tilde_fixture_root}/target-check-proof"
ln -s "target-check-proof" "${tilde_fixture_root}/check-proof::mode"
colon_target="$(verification_command_semantic_target \
  "${tilde_fixture_root}/target-check-proof" '')"
colon_alias_target="$(verification_command_semantic_target \
  "${tilde_fixture_root}/check-proof::mode" '')"
assert_eq "T15: literal double-colon executable symlink cannot split proof identity" \
  "${colon_target}" "${colon_alias_target}"
mkdir -p "${tilde_fixture_root}/hardlink-a" \
  "${tilde_fixture_root}/hardlink-b"
: >"${tilde_fixture_root}/hardlink-a/source-proof.txt"
if _verification_normalize_proof_path \
    "${tilde_fixture_root}/hardlink-a/source-proof.txt" 0 source \
    >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: ordinary single-link source file lost proof authority\n' >&2
  fail=$((fail + 1))
fi
if ln "${tilde_fixture_root}/hardlink-a/source-proof.txt" \
    "${tilde_fixture_root}/hardlink-b/source-proof.txt" 2>/dev/null; then
  if _verification_normalize_proof_path \
      "${tilde_fixture_root}/hardlink-a/source-proof.txt" 0 source \
      >/dev/null 2>&1; then
    printf '  FAIL: multiply-linked source file minted path-based authority\n' >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
else
  # A filesystem that cannot create the alias is already safe for this case.
  pass=$((pass + 1))
fi
assert_definition_scope_rejected \
  "T15: Cargo forwarded skip filter" 'cargo test -- --skip smoke'
assert_definition_scope_rejected \
  "T15: Cargo forwarded positional filter" 'cargo test -- smoke'
assert_definition_scope_allowed \
  "T15: Cargo harmless output/concurrency policy" \
  'cargo test -- --test-threads 2 --color=never --nocapture'
cargo_package_a="$(semantic_with_fixture_path \
  'cargo test -p crate_a' '')"
cargo_package_a_alias="$(semantic_with_fixture_path \
  'cargo test --package=crate_a' '')"
cargo_package_b="$(semantic_with_fixture_path \
  'cargo test -p crate_b' '')"
assert_eq "T15: Cargo package-option aliases share one target" \
  "${cargo_package_a}" "${cargo_package_a_alias}"
if [[ "${cargo_package_a}" != "${cargo_package_b}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: distinct Cargo packages collapsed to one target\n' >&2
  fail=$((fail + 1))
fi
cargo_pair="$(semantic_with_fixture_path \
  'cargo test -p crate_a --test integration' '')"
cargo_pair_reversed="$(semantic_with_fixture_path \
  'cargo test --test integration -p crate_a' '')"
assert_eq "T15: Cargo selector order cannot mint a new target" \
  "${cargo_pair}" "${cargo_pair_reversed}"
cargo_workspace="$(semantic_with_fixture_path \
  'cargo test --workspace' '')"
cargo_all="$(semantic_with_fixture_path 'cargo test --all' '')"
assert_eq "T15: Cargo workspace aliases share one target" \
  "${cargo_workspace}" "${cargo_all}"
assert_definition_scope_rejected \
  "T15: Go forwarded argv" 'go test ./... -- smoke'
assert_definition_scope_rejected \
  "T15: Go run filter" 'go test ./... -run TestSmoke'
assert_definition_scope_rejected \
  "T15: Go skip filter" 'go test ./... -skip TestSlow'
assert_definition_scope_rejected \
  "T15: Go short mode" 'go test ./... -short'
assert_definition_scope_allowed \
  "T15: Go cache-disable/concurrency flags" \
  'go test ./... -count=1 -parallel=4'
assert_definition_scope_rejected \
  "T15: package-script forwarded argv" \
  'npm test -- --criterion Q-001'
npm_target="$(semantic_with_fixture_path 'npm test' '')"
npm_run_target="$(semantic_with_fixture_path 'npm run test' '')"
pnpm_target="$(semantic_with_fixture_path 'pnpm test' '' 2>/dev/null || true)"
assert_eq "T15: package-script shorthand cannot split one target" \
  "${npm_target}" "${npm_run_target}"
if [[ -n "${pnpm_target}" ]]; then
  assert_eq "T15: installed package-manager aliases cannot split one target" \
    "${npm_target}" "${pnpm_target}"
else
  pass=$((pass + 1))
fi

while IFS='|' read -r scope_label scope_command; do
  [[ -n "${scope_label}" ]] || continue
  assert_definition_scope_rejected "T15: ${scope_label}" "${scope_command}"
done <<'SCOPE_REJECTIONS'
pytest last-failed cache|pytest --lf
pytest last-failed-no-failures cache|pytest --lfnf all
pytest deselect|pytest --deselect tests/test_alpha.py::test_one
pytest ignore-glob|pytest --ignore-glob '*.generated.py'
pytest stepwise cache|pytest --stepwise
pytest expression filter|pytest -k smoke
pytest marker filter|pytest -m fast
Jest only-changed alias|jest -o
Jest watch mode|jest --watch
Jest only-failures cache|jest --onlyFailures
Jest find-related short alias|jest -f tests/unit/a.test.js
Jest changed-since|jest --changedSince main
Jest related paths|jest --related tests/unit/a.test.js
Jest shard|jest --shard 1/2
Jest positional spec path|jest tests/unit/a.test.js
Vitest changed set|vitest --changed main
Vitest name filter|vitest -t smoke
Vitest exclusion|vitest --exclude tests/slow.test.ts
Vitest positional spec path|vitest tests/unit/a.test.ts
RSpec example|rspec --example smoke
RSpec tag|rspec --tag focus
RSpec only failures|rspec --only-failures
RSpec path line|rspec spec/unit/foo_spec.rb:12
PHPUnit filter|phpunit --filter smoke
PHPUnit group|phpunit --group fast
PHPUnit excluded group|phpunit --exclude-group slow
PHPUnit testsuite|phpunit --testsuite unit
Swift filter|swift test --filter SmokeTests
Swift skip|swift test --skip SlowTests
Swift skip build|swift test --skip-build
Gradle tests filter|gradle test --tests '*.SmokeTest'
Gradle excluded task|gradle test -x integrationTest
Xcode only testing|xcodebuild test -only-testing:AppTests/SmokeTests
Xcode skip testing|xcodebuild test -skip-testing:AppTests/SlowTests
Maven unit filter|mvn test -Dtest=SmokeTest
Maven integration filter|mvn verify -Dit.test=SmokeIT
Maven group filter|mvn test -Dgroups=fast
Maven excluded group|mvn test -DexcludedGroups=slow
Maven project list|mvn test -pl module-a
dotnet filter|dotnet test --filter Category=Fast
dotnet list only|dotnet test --list-tests
Deno filter|deno test --filter smoke
Deno ignore|deno test --ignore tests/slow_test.ts
Mix only tag|mix test --only focus
Mix excluded tag|mix test --exclude slow
Mix stale cache|mix test --stale
Mix failed cache|mix test --failed
Mix path line|mix test test/foo_test.exs:12
Cargo package exclusion|cargo test --workspace --exclude crate_slow
Cargo pre-boundary positional filter|cargo test smoke
Cargo unmodeled aggregate selector|cargo test --tests
Jest opaque positional pattern|jest smoke
Jest regular-expression option|jest --testRegex smoke
Jest project-root option|jest --roots tests
Vitest opaque positional pattern|vitest smoke
Vitest project option|vitest --project unit
Vitest include option|vitest --include '**/*.smoke.ts'
package forwarding through yarn|yarn test -- --filter smoke
package forwarding through bun|bun test -- --filter smoke
Yarn direct name filter|yarn test -t smoke
Yarn direct grep filter|yarn test --grep smoke
Yarn direct shard|yarn test --shard 1/2
Bun direct test path|bun test tests/unit/a.test.ts
Bun direct name filter|bun test --testNamePattern smoke
Bun direct path filter|bun test --testPathPattern unit
Bun direct changed filter|bun test --changed main
SCOPE_REJECTIONS

for harmless_scope_command in \
  'pytest --color=yes -n 2 --cache-clear tests/test_alpha.py' \
  'jest --colors --reporters default --maxWorkers=2 --no-cache' \
  'vitest --color --reporter verbose --maxWorkers=2' \
  'gradle test --info --max-workers=2 --rerun-tasks' \
  'mvn test -T 2 -Dstyle.color=never' \
  'dotnet test --no-restore --logger console' \
  'yarn test --reporter=dot --maxWorkers=2 --no-cache' \
  'bun test --reporter=dot --concurrency=2'; do
  assert_definition_scope_allowed \
    "T15: harmless reporter/color/concurrency/cache-disable policy" \
    "${harmless_scope_command}"
done

assert_definition_scope_allowed \
  "T15: python module pytest wrapper starts scanning after launcher argv" \
  'python3 -m pytest tests/test_alpha.py'
assert_definition_scope_allowed \
  "T15: uv pytest wrapper starts scanning after launcher argv" \
  'uv run pytest tests/test_alpha.py'
assert_definition_scope_allowed \
  "T15: npx pytest wrapper starts scanning after launcher argv" \
  'npx pytest tests/test_alpha.py'

pytest_broad_target="$(semantic_with_fixture_path 'pytest' '')"
pytest_path_target="$(semantic_with_fixture_path \
  'pytest tests/test_alpha.py' '')"
if [[ "${pytest_broad_target}" != "${pytest_path_target}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: modeled pytest positional path impersonated broad suite\n' >&2
  fail=$((fail + 1))
fi
mkdir -p "${proof_alias_dir}/unit"
pytest_plain_directory_target="$({
  cd "${proof_alias_dir}" || exit 1
  verification_command_semantic_target 'pytest unit' ''
})"
pytest_plain_broad_target="$({
  cd "${proof_alias_dir}" || exit 1
  verification_command_semantic_target 'pytest' ''
})"
if [[ "${pytest_plain_directory_target}" != "${pytest_plain_broad_target}" \
    && "${pytest_plain_directory_target}" == *"${proof_alias_dir}/unit"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: plain pytest directory collapsed to broad suite: %q\n' \
    "${pytest_plain_directory_target}" >&2
  fail=$((fail + 1))
fi
gradle_broad_target="$(semantic_with_fixture_path 'gradle test' '')"
gradle_policy_target="$(semantic_with_fixture_path \
  'gradle test --info --max-workers=2' '')"
if [[ "${gradle_broad_target}" != "${gradle_policy_target}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: collapsed-family admitted argv policy was not bound\n' >&2
  fail=$((fail + 1))
fi
if _quality_contract_bash_targets_overlap \
    "${gradle_broad_target}" "${gradle_policy_target}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: collapsed-family policy minted independent criteria\n' >&2
  fail=$((fail + 1))
fi
gradle_target="$(verification_command_semantic_target \
  'gradle test --info' '' 2>/dev/null || true)"
gradlew_target="$(verification_command_semantic_target \
  './gradlew test --info' '' 2>/dev/null || true)"
if [[ -n "${gradle_target}" && -n "${gradlew_target}" ]]; then
  assert_eq "T15: Gradle launcher aliases cannot split one task target" \
    "${gradle_target}" "${gradlew_target}"
else
  pass=$((pass + 1))
fi
rm -rf "${proof_alias_dir}"

# ----------------------------------------------------------------------
printf 'Test 16: explicit zero-test output cannot masquerade as empirical execution\n'
for output in \
  'collected 0 items' \
  'running 0 tests' \
  'Tests: 0 passed, 0 failed' \
  'No tests found, exiting with code 0' \
  'testing: warning: no tests to run' \
  '? example/pkg [no test files]' \
  ':test NO-SOURCE' \
  ':test SKIPPED' \
  'Tests are skipped.' \
  'all specs skipped' \
  'no specs run' \
  'no checks run' \
  '0 checks passed; SUCCESS' \
  'No tests were executed!' \
  'tests 0 selected' \
  '1..0 # SKIP no compatible runtime' \
  'No tests were found!!!' \
  'No tests executed!'; do
  if verification_output_reports_zero_execution "${output}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: zero-test output not detected: %s\n' "${output}" >&2
    fail=$((fail + 1))
  fi
done
for output in \
  'Tests run: 0, Failures: 0, Errors: 0, Skipped: 0' \
  '5 deselected in 0.01s' \
  '0 passing' \
  'Tests: 5 skipped, 5 total' \
  'Tests: 5 todo, 5 total' \
  '5 skipped in 0.02s' \
  '5 examples, 0 failures, 5 pending' \
  'Tests run: 5, Failures: 0, Errors: 0, Skipped: 5' \
  'Test Suites: 1 passed, 1 total; Tests: 5 skipped, 5 total' \
  'Total tests: 5. Passed: 0. Failed: 0. Skipped: 5.' \
  'setup: 1 passed; collected 0 items'; do
  if verification_output_reports_zero_execution "${output}" test; then
    pass=$((pass + 1))
  else
    printf '  FAIL: all-skipped/zero output not detected: %s\n' \
      "${output}" >&2
    fail=$((fail + 1))
  fi
done
if verification_output_reports_zero_execution \
    '0 benchmarks; SUCCESS' benchmark; then
  pass=$((pass + 1))
else
  printf '  FAIL: zero benchmark output not detected\n' >&2
  fail=$((fail + 1))
fi
for output in \
  '10 passed, 0 failed' \
  '1 passed, 2 deselected in 0.1s' \
  '2 failed, 3 deselected in 0.1s' \
  'Tests: 4 passed, 0 failed' \
  'running 2 tests' \
  $':processResources NO-SOURCE\n:test 5 passed' \
  $'? example/empty [no test files]\nok example/real 0.1s' \
  $'running 0 tests\ntest result: ok. 0 passed; 0 failed\nrunning 2 tests\ntest result: ok. 2 passed; 0 failed' \
  $'Tests run: 0, Failures: 0, Errors: 0, Skipped: 0\nTests run: 2, Failures: 0, Errors: 0, Skipped: 0' \
  $'Tests run: 0, Failures: 0, Errors: 0, Skipped: 0\n1 passed' \
  $'Tests run: 5, Failures: 0, Errors: 0, Skipped: 0\nTests run: 5, Failures: 0, Errors: 0, Skipped: 5' \
  $'Total tests: 5. Passed: 0. Failed: 0. Skipped: 5.\nTotal tests: 5. Passed: 5. Failed: 0. Skipped: 0.'; do
  if verification_output_reports_zero_execution "${output}"; then
    printf '  FAIL: positive execution misclassified as zero: %s\n' "${output}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for mixed_custom_output in \
  $'all specs skipped\n2 specs passed' \
  $'no checks run\n3 checks executed'; do
  if verification_output_reports_zero_execution "${mixed_custom_output}"; then
    printf '  FAIL: real custom sibling execution misclassified as zero: %s\n' \
      "${mixed_custom_output}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if verification_output_reports_zero_execution \
    '4 benchmarks completed; SUCCESS' benchmark; then
  printf '  FAIL: positive benchmark output misclassified as zero\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
for kind_output in \
  'benchmark|0 benchmarks
2 benchmarks' \
  'comparison|comparisons: 0
comparisons: 2' \
  'render|renders: 0
renders: 2'; do
  kind="${kind_output%%|*}"
  output="${kind_output#*|}"
  if verification_output_reports_zero_execution "${output}" "${kind}"; then
    printf '  FAIL: mixed positive %s output misclassified as zero\n' \
      "${kind}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for skipped_output in \
  'SKIP: integration environment unavailable' \
  'all checks skipped' \
  '1 check skipped'; do
  if verification_output_reports_zero_execution "${skipped_output}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: skipped custom check was not zero execution: %s\n' \
      "${skipped_output}" >&2
    fail=$((fail + 1))
  fi
done

# ----------------------------------------------------------------------
printf 'Test 17: specialized evidence requires role-aware intent and result signals\n'
for green_failure_summary in \
  '0 failures' \
  'Failures: 0, Errors: 0' \
  'SUCCESS: no errors' \
  '1 passed, 0 failed' \
  $'ok 1 - returns an error for invalid input\n1 passed' \
  $'PASS renders the error page\nTests: 1 passed, 0 failed' \
  $'1 example, 1 failure\n10 examples, 0 failures' \
  $'Tests run: 1, Failures: 1, Errors: 0\nTests run: 1, Failures: 0, Errors: 0'; do
  if verification_output_reports_failure "${green_failure_summary}"; then
    printf '  FAIL: green summary classified as failure: %s\n' \
      "${green_failure_summary}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for negative_failure_summary in \
  'failed benchmark mean 1 ms' \
  'error: render wrote no artifact' \
  'Failures: 2, Errors: 0' \
  'exit status: 3' \
  $'FAILED tests/test_a.py::test_x\ncleanup: no errors' \
  $'TAP version 13\nnot ok 1 - should work\n1..1\n# tests 1\n# pass 0\n# fail 1'; do
  if verification_output_reports_failure "${negative_failure_summary}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: negative summary escaped failure detection: %s\n' \
      "${negative_failure_summary}" >&2
    fail=$((fail + 1))
  fi
done
assert_eq "T17: pytest selector name does not request benchmark evidence" "" \
  "$(verification_command_requested_evidence_kind \
    'pytest tests/test_benchmark_config.py' 2>/dev/null || true)"
assert_eq "T17: pytest selector name does not request render evidence" "" \
  "$(verification_command_requested_evidence_kind \
    'pytest tests/test_render.py' 2>/dev/null || true)"
for command in \
  'pytest --benchmark-only tests/test_perf.py' \
  'pytest --benchmark-enable tests/test_perf.py' \
  'go test -bench=.' \
  'go test -bench .'; do
  assert_eq "T17: canonical benchmark option requests benchmark: ${command}" \
    "benchmark" "$(verification_command_requested_evidence_kind "${command}")"
done
assert_eq "T17: explicit benchmark disable is not benchmark evidence" "" \
  "$(verification_command_requested_evidence_kind \
    'pytest --benchmark-disable tests/test_perf.py' 2>/dev/null || true)"
assert_eq "T17: generic comparison test output is not a comparison observation" \
  "test" "$(verification_receipt_evidence_kind framework_keyword unknown \
    'bash scripts/check.sh --comparison' 'comparison tests: 5 passed')"
assert_eq "T17: generic render test output is not a render observation" \
  "test" "$(verification_receipt_evidence_kind framework_keyword unknown \
    'bash scripts/check.sh --render' 'render tests: 5 passed')"
for non_comparison in \
  'baseline latency: 5 ms' \
  'diff completed in 7 ms'; do
  if verification_output_reports_kind_observation \
      "${non_comparison}" comparison; then
    printf '  FAIL: single-sided timing laundered comparison proof: %s\n' \
      "${non_comparison}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
if verification_output_reports_kind_observation \
    'baseline 20 ms; candidate 15 ms; delta 25 percent' comparison; then
  pass=$((pass + 1))
else
  printf '  FAIL: measured baseline/candidate delta was not comparison evidence\n' >&2
  fail=$((fail + 1))
fi
for broken_render in \
  'screenshot missing; artifact unavailable' \
  'render not produced; no artifact' \
  'render result was skipped; image 100px; SUCCESS' \
  'render config artifact=proof.png; SUCCESS' \
  'render target image 100px configured; SUCCESS'; do
  if verification_output_reports_kind_observation "${broken_render}" render; then
    printf '  FAIL: broken render laundered positive evidence: %s\n' \
      "${broken_render}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for valid_render in \
  'render produced artifact: proof.png' \
  'render produced 1 image' \
  'render produced artifact: proof.png within budget; PASS' \
  $'render unavailable; retrying\nrender produced artifact: recovered.png'; do
  if verification_output_reports_kind_observation "${valid_render}" render; then
    pass=$((pass + 1))
  else
    printf '  FAIL: valid render observation was rejected: %s\n' \
      "${valid_render}" >&2
    fail=$((fail + 1))
  fi
done
if verification_output_reports_kind_observation \
    'Benchmark parser: mean 5 ms; threshold 10 ms; PASS' benchmark; then
  pass=$((pass + 1))
else
  printf '  FAIL: measured benchmark with a passing threshold was rejected\n' >&2
  fail=$((fail + 1))
fi
for zero_diagnostic_result in \
  'benchmark|Benchmark parser: mean 5 ms; errors: 0; PASS' \
  'comparison|comparison: 3 matched, 0 differences, failures: 0; PASS' \
  'comparison|Q-004 blind comparison: 5 comparisons matched, 0 differences; 5 passed, 0 failed' \
  'render|rendered 1 page to proof.pdf; errors: 0; PASS'; do
  kind="${zero_diagnostic_result%%|*}"
  output="${zero_diagnostic_result#*|}"
  if verification_output_reports_kind_observation "${output}" "${kind}" \
      && ! verification_output_reports_zero_execution "${output}" "${kind}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: zero diagnostic count erased concrete %s output\n' \
      "${kind}" >&2
    fail=$((fail + 1))
  fi
done
for broken_special in \
  'benchmark|benchmark unavailable; retry after 1 ms; SUCCESS' \
  'benchmark|benchmark results are unavailable; retry after 1 ms; SUCCESS' \
  'benchmark|benchmark config: latency budget 100 ms; 1 test passed; SUCCESS' \
  'benchmark|benchmark timeout configured at 200 ms; SUCCESS' \
  'comparison|comparison unavailable; retry delta 1 ms; SUCCESS' \
  'comparison|comparison results are unavailable; retry delta 1 ms; SUCCESS' \
  'comparison|baseline and candidate delta pending; SUCCESS' \
  'comparison|comparison threshold delta 10 percent configured; SUCCESS'; do
  kind="${broken_special%%|*}"
  output="${broken_special#*|}"
  if verification_output_reports_kind_observation "${output}" "${kind}"; then
    printf '  FAIL: non-observation laundered %s evidence: %s\n' \
      "${kind}" "${output}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done
for negative_special in \
  'benchmark|failed benchmark mean 1 ms' \
  'benchmark|error benchmark mean 1 ms' \
  'benchmark|failure benchmark mean 1 ms' \
  'benchmark|benchmark disabled; previous mean 1 ms' \
  'benchmark|benchmark dry run; mean 1 ms' \
  'benchmark|benchmark cached; mean 1 ms' \
  'comparison|failed comparison: 1 changed' \
  'comparison|error: comparison 1 changed' \
  'comparison|comparison disabled: 1 changed' \
  'render|failed render wrote artifact proof.png' \
  'render|error: render wrote artifact proof.png' \
  'render|render dry run wrote artifact proof.png'; do
  kind="${negative_special%%|*}"
  output="${negative_special#*|}"
  if verification_output_reports_kind_observation "${output}" "${kind}"; then
    printf '  FAIL: negative diagnostic laundered %s observation: %s\n' \
      "${kind}" "${output}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
  if verification_output_reports_zero_execution "${output}" "${kind}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: negative %s diagnostic was not zero execution: %s\n' \
      "${kind}" "${output}" >&2
    fail=$((fail + 1))
  fi
done
if verification_output_reports_kind_observation \
    $'benchmark unavailable; retrying\nBenchmark 2: parser\nTime (mean): 10 ms' \
    benchmark; then
  pass=$((pass + 1))
else
  printf '  FAIL: later concrete benchmark did not supersede retry diagnostic\n' >&2
  fail=$((fail + 1))
fi
for recovered_special in \
  'comparison|comparison disabled: 1 changed
comparison: 2 changed' \
  'render|render dry run wrote artifact stale.png
render produced artifact: recovered.png'; do
  kind="${recovered_special%%|*}"
  output="${recovered_special#*|}"
  if verification_output_reports_kind_observation "${output}" "${kind}" \
      && ! verification_output_reports_zero_execution "${output}" "${kind}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: later concrete %s did not supersede diagnostic\n' \
      "${kind}" >&2
    fail=$((fail + 1))
  fi
done
for terminal_negative_special in \
  'benchmark|Benchmark 1: parser
Time (mean): 1 ms
benchmark failed to complete' \
  'comparison|comparison: 1 changed
comparison unavailable' \
  'render|render wrote artifact proof.png
render failed to save'; do
  kind="${terminal_negative_special%%|*}"
  output="${terminal_negative_special#*|}"
  if verification_output_reports_kind_observation "${output}" "${kind}"; then
    printf '  FAIL: terminal %s failure did not supersede earlier output\n' \
      "${kind}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
  if verification_output_reports_zero_execution "${output}" "${kind}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: terminal %s failure was not decisive zero evidence\n' \
      "${kind}" >&2
    fail=$((fail + 1))
  fi
done
if verification_output_reports_kind_observation \
    $'Benchmark 1: parser\nTime (mean): 10 ms\nERROR: worker crashed' \
    benchmark; then
  printf '  FAIL: terminal generic error did not supersede benchmark output\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if verification_output_reports_kind_observation \
    $'ERROR: first worker crashed\nBenchmark 2: parser\nTime (mean): 9 ms' \
    benchmark; then
  pass=$((pass + 1))
else
  printf '  FAIL: concrete retry did not supersede earlier generic error\n' >&2
  fail=$((fail + 1))
fi
assert_eq "T17: failed specialized command retains requested evidence kind" \
  "benchmark" "$(verification_receipt_evidence_kind framework_keyword unknown \
    'bash scripts/check.sh --benchmark' 'segmentation fault' failed)"
for realistic in \
  $'----- benchmark: 1 tests -----\nName Mean OPS' \
  $'Benchmark 1: parser\nTime (mean ± σ): 22.5 ms ± 1.0 ms'; do
  if verification_output_reports_kind_observation "${realistic}" benchmark; then
    pass=$((pass + 1))
  else
    printf '  FAIL: realistic multiline benchmark output was not admitted\n' >&2
    fail=$((fail + 1))
  fi
done

printf '\n=== Verification Lib Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
