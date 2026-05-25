#!/usr/bin/env bash
# test-project-readiness.sh — regression net for
# tools/verify-project-readiness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/verify-project-readiness.sh"
README_REAL="${REPO_ROOT}/README.md"
CONTRIBUTING_REAL="${REPO_ROOT}/CONTRIBUTING.md"
CLAUDE_REAL="${REPO_ROOT}/CLAUDE.md"
AGENTS_REAL="${REPO_ROOT}/AGENTS.md"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_jq_eq() {
  local label="$1" query="$2" expected="$3" json="$4"
  local actual
  actual="$(printf '%s' "${json}" | jq -r "${query}")"
  assert_eq "${label}" "${expected}" "${actual}"
}

TMP_DIR="$(mktemp -d -t project-readiness-XXXXXX)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# mk_json_stub lives in tests/lib/composition-stubs.sh — shared across
# the readiness-composer test family. See that file's header for contract.
# shellcheck source=lib/composition-stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/composition-stubs.sh"

run_tool() {
  local professional_cmd="$1"
  local install_cmd="$2"
  local distribution_cmd="$3"
  shift 3

  env \
    OMC_PROJECT_READINESS_PROFESSIONAL_CMD="bash ${professional_cmd}" \
    OMC_PROJECT_READINESS_INSTALL_CMD="bash ${install_cmd}" \
    OMC_PROJECT_READINESS_DISTRIBUTION_CMD="bash ${distribution_cmd}" \
    bash "${TOOL}" "$@"
}

professional_ok="$(mk_json_stub professional-ok ok 8 0 0 "verify-professional-readiness: summary: 8 OK, 0 SKIP, 0 FAIL" "professional green" 0)"
install_ok="$(mk_json_stub install-ok ok 4 0 0 "verify-install-readiness: summary: 4 OK, 0 SKIP, 0 FAIL" "install green" 0)"
distribution_ok="$(mk_json_stub distribution-ok ok 4 0 0 "verify-distribution-readiness: summary: 4 OK, 0 SKIP, 0 FAIL" "distribution green" 0)"
distribution_fail="$(mk_json_stub distribution-fail fail 3 0 1 "verify-distribution-readiness: summary: 3 OK, 0 SKIP, 1 FAIL" "distribution fail" 1)"
distribution_pending_remote="$(mk_json_stub distribution-pending fail 3 0 1 "verify-distribution-readiness: summary: 3 OK, 0 SKIP, 1 FAIL" "verify-distribution-readiness: remote deployment is behind, but the local deployment candidate is coherent for example/fixture" 1)"

printf 'Test 1: text mode composes professional, install, and distribution readiness\n'
out="$(
  run_tool "${professional_ok}" "${install_ok}" "${distribution_ok}" 2>&1
)"
assert_contains "T1: professional surface ok" $'OK\tprofessional\tverify-professional-readiness: summary: 8 OK, 0 SKIP, 0 FAIL' "${out}"
assert_contains "T1: install surface ok" $'OK\tinstall\tverify-install-readiness: summary: 4 OK, 0 SKIP, 0 FAIL' "${out}"
assert_contains "T1: distribution surface ok" $'OK\tdistribution\tverify-distribution-readiness: summary: 4 OK, 0 SKIP, 0 FAIL' "${out}"
assert_contains "T1: summary text" "verify-project-readiness: summary: 3 OK, 0 SKIP, 0 FAIL" "${out}"
assert_contains "T1: green message" "verify-project-readiness: project is green across professional, install, and distribution readiness surfaces" "${out}"

printf 'Test 2: json mode captures failing and skipped surfaces\n'
set +e
out="$(
  run_tool "${professional_ok}" "${install_ok}" "${distribution_fail}" --skip-professional --skip-install --json 2>&1
)"
rc="$?"
set -e
assert_eq "T2: json mode exits non-zero on downstream failure" "1" "${rc}"
assert_jq_eq "T2: result is fail" '.result' "fail" "${out}"
assert_jq_eq "T2: ok count" '.counts.ok' "0" "${out}"
assert_jq_eq "T2: skip count" '.counts.skip' "2" "${out}"
assert_jq_eq "T2: fail count" '.counts.fail' "1" "${out}"
assert_jq_eq "T2: professional skipped" '.surfaces[] | select(.name=="professional") | .status' "SKIP" "${out}"
assert_jq_eq "T2: install skipped" '.surfaces[] | select(.name=="install") | .status' "SKIP" "${out}"
assert_jq_eq "T2: distribution failed" '.surfaces[] | select(.name=="distribution") | .status' "FAIL" "${out}"
assert_jq_eq "T2: distribution nested summary preserved" '.surfaces[] | select(.name=="distribution") | .details.summary_text' "verify-distribution-readiness: summary: 3 OK, 0 SKIP, 1 FAIL" "${out}"

printf 'Test 3: help output describes the combined contract\n'
out="$(bash "${TOOL}" --help)"
assert_contains "T3: help mentions professional users" "product readiness for professional users" "${out}"
assert_contains "T3: help mentions install readiness" "install/onboarding readiness across the bootstrapper" "${out}"
assert_contains "T3: help mentions distribution readiness" "distribution readiness of the published release surface" "${out}"
assert_contains "T3: help mentions skip-professional" "--skip-professional" "${out}"
assert_contains "T3: help mentions skip-install" "--skip-install" "${out}"
assert_contains "T3: help mentions skip-distribution" "--skip-distribution" "${out}"

printf 'Test 4: candidate-aware failure message surfaces the real blocker\n'
set +e
out="$(
  run_tool "${professional_ok}" "${install_ok}" "${distribution_pending_remote}" --json 2>&1
)"
rc="$?"
set -e
assert_eq "T4: candidate-aware failure exits non-zero" "1" "${rc}"
assert_jq_eq "T4: candidate-aware message names remote deployment as the remaining blocker" '.message' "verify-project-readiness: professional and install readiness are green; remaining blocker is remote deployment while the local distribution candidate is coherent" "${out}"

printf 'Test 5: docs inventory the project-readiness helper\n'
readme_contents="$(cat "${README_REAL}")"
contributing_contents="$(cat "${CONTRIBUTING_REAL}")"
claude_contents="$(cat "${CLAUDE_REAL}")"
agents_contents="$(cat "${AGENTS_REAL}")"
assert_contains "T5: README mentions helper" 'tools/verify-project-readiness.sh' "${readme_contents}"
assert_contains "T5: README mentions install helper" 'tools/verify-install-readiness.sh' "${readme_contents}"
assert_contains "T5: CONTRIBUTING mentions helper" 'tools/verify-project-readiness.sh' "${contributing_contents}"
assert_contains "T5: CONTRIBUTING mentions install helper" 'tools/verify-install-readiness.sh' "${contributing_contents}"
assert_contains "T5: CLAUDE mentions helper" 'verify-project-readiness.sh' "${claude_contents}"
assert_contains "T5: CLAUDE mentions install helper" 'verify-install-readiness.sh' "${claude_contents}"
assert_contains "T5: AGENTS mentions helper" 'verify-project-readiness.sh' "${agents_contents}"
assert_contains "T5: AGENTS mentions install helper" 'verify-install-readiness.sh' "${agents_contents}"

printf '\nproject-readiness tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
