#!/usr/bin/env bash
# CI integration for tools/replay-classifier-telemetry.sh.
# Asserts that the curated fixtures still match the current classifier
# (i.e. no unintended drift since the fixtures were captured).
#
# When this test fails, the classifier behavior has shifted on at least
# one curated prompt. Either:
#   (a) the change was intentional (e.g. a v1.X classifier improvement)
#       — update the affected fixture rows in
#       tools/classifier-fixtures/regression.jsonl and re-commit; or
#   (b) the change was unintentional — investigate the regression in
#       common.sh classify_task_intent / infer_domain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPLAY="${REPO_ROOT}/tools/replay-classifier-telemetry.sh"
FIXTURES="${REPO_ROOT}/tools/classifier-fixtures/regression.jsonl"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
printf 'Test 1: replay tool exists and is executable\n'
assert_eq "tool present" "yes" "$([[ -x "${REPLAY}" || -f "${REPLAY}" ]] && echo yes || echo no)"
assert_eq "fixtures present" "yes" "$([[ -f "${FIXTURES}" ]] && echo yes || echo no)"

# ----------------------------------------------------------------------
printf 'Test 2: fixtures file is valid JSONL with required fields\n'
row_count="$(wc -l < "${FIXTURES}" | tr -d '[:space:]')"
[[ "${row_count}" -gt 0 ]]
pass=$((pass + 1))
# Each row must parse as JSON object and carry prompt_preview + intent.
malformed=0
while IFS= read -r row; do
  [[ -z "${row}" ]] && continue
  if ! jq -e 'type=="object" and (.prompt_preview // .prompt) and .intent' <<<"${row}" >/dev/null 2>&1; then
    malformed=$((malformed + 1))
  fi
done < "${FIXTURES}"
assert_eq "all fixture rows valid" "0" "${malformed}"

# ----------------------------------------------------------------------
printf 'Test 3: replay against fixtures detects zero drift\n'
output="$(bash "${REPLAY}" 2>&1)"
rc=$?
assert_eq "replay exit 0 (no drift)" "0" "${rc}"
assert_contains "replay reports no drift" "No drift detected" "${output}"
assert_contains "replay reports row count" "Rows:" "${output}"

# ----------------------------------------------------------------------
printf 'Test 4: replay surfaces drift when a row is intentionally mismatched\n'
# Build a temporary fixtures file with one deliberately-wrong row.
TMP_FIXTURES="$(mktemp)"
cleanup() { rm -f "${TMP_FIXTURES}"; }
trap cleanup EXIT
# Use a prompt that classifier will definitely classify as execution+coding,
# but record it as advisory+writing — replay must flag this drift.
printf '%s\n' '{"prompt_preview":"/ulw fix the failing test","intent":"advisory","domain":"writing","note":"intentional mismatch for drift test"}' > "${TMP_FIXTURES}"
output="$(bash "${REPLAY}" "${TMP_FIXTURES}" 2>&1 || true)"
rc=0
bash "${REPLAY}" "${TMP_FIXTURES}" >/dev/null 2>&1 || rc=$?
assert_eq "drift returns nonzero" "1" "${rc}"
assert_contains "drift report mentions DRIFT" "DRIFT" "${output}"
assert_contains "drift report mentions intent shift" "intent advisory→execution" "${output}"

# ----------------------------------------------------------------------
printf 'Test 5: replay handles missing fixtures gracefully\n'
rc=0
bash "${REPLAY}" /nonexistent/path/fixtures.jsonl >/dev/null 2>&1 || rc=$?
assert_eq "missing fixtures returns 2" "2" "${rc}"

# ----------------------------------------------------------------------
printf 'Test 6: --help flag prints usage\n'
help_out="$(bash "${REPLAY}" --help 2>&1)"
assert_contains "help mentions usage" "Usage:" "${help_out}"
assert_contains "help mentions exit codes" "Exit codes" "${help_out}"

# ----------------------------------------------------------------------
printf 'Test 7: skips non-object rows in input (forward-compat)\n'
TMP2="$(mktemp)"
{
  printf '%s\n' '{"prompt_preview":"/ulw fix it","intent":"execution","domain":"coding"}'
  printf '%s\n' 'not valid json'
  printf '\n'
  printf '%s\n' '["array","not","object"]'
  printf '%s\n' '{"prompt_preview":"keep going","intent":"continuation","domain":"general"}'
} > "${TMP2}"
output="$(bash "${REPLAY}" "${TMP2}" 2>&1)"
rc=$?
rm -f "${TMP2}"
assert_eq "rc=0 with skipped rows" "0" "${rc}"
assert_contains "summary reports skipped count" "skipped:" "${output}"

printf '\n=== Classifier-Replay Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
