#!/usr/bin/env bash
# test-install-readiness.sh — regression net for
# tools/verify-install-readiness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/verify-install-readiness.sh"
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

TMP_DIR="$(mktemp -d -t install-readiness-XXXXXX)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mk_stub() {
  local name="$1" exit_code="$2"
  shift 2
  local path="${TMP_DIR}/${name}.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf "cat <<'EOF'\n"
    while [[ $# -gt 0 ]]; do
      printf '%s\n' "$1"
      shift
    done
    printf "EOF\n"
    printf 'exit %s\n' "${exit_code}"
  } > "${path}"
  chmod +x "${path}"
  printf '%s' "${path}"
}

run_tool() {
  local bootstrapper_cmd="$1"
  local handoff_cmd="$2"
  local recovery_cmd="$3"
  local onboarding_cmd="$4"
  shift 4

  env \
    OMC_INSTALL_READINESS_BOOTSTRAPPER_CMD="bash ${bootstrapper_cmd}" \
    OMC_INSTALL_READINESS_HANDOFF_CMD="bash ${handoff_cmd}" \
    OMC_INSTALL_READINESS_RECOVERY_CMD="bash ${recovery_cmd}" \
    OMC_INSTALL_READINESS_ONBOARDING_CMD="bash ${onboarding_cmd}" \
    bash "${TOOL}" "$@"
}

bootstrapper_ok="$(mk_stub bootstrapper-ok 0 'install-remote: 57 passed, 0 failed')"
handoff_ok="$(mk_stub handoff-ok 0 '=== Install handoff tests: 16 passed, 0 failed ===')"
recovery_ok="$(mk_stub recovery-ok 0 '=== Install recovery tests: 15 passed, 0 failed ===')"
onboarding_ok="$(mk_stub onboarding-ok 0 '=== Wave 4 onboarding tests: 16 passed, 0 failed ===')"
recovery_fail="$(mk_stub recovery-fail 1 'recovery trace line' '=== Install recovery tests: 14 passed, 1 failed ===')"

printf 'Test 1: all-green text mode composes the install/onboarding proof surfaces\n'
out="$(
  run_tool \
    "${bootstrapper_ok}" \
    "${handoff_ok}" \
    "${recovery_ok}" \
    "${onboarding_ok}" 2>&1
)"
assert_contains "T1: bootstrapper surface ok" $'OK\tbootstrapper\tinstall-remote: 57 passed, 0 failed' "${out}"
assert_contains "T1: handoff surface ok" $'OK\thandoff\t=== Install handoff tests: 16 passed, 0 failed ===' "${out}"
assert_contains "T1: recovery surface ok" $'OK\trecovery\t=== Install recovery tests: 15 passed, 0 failed ===' "${out}"
assert_contains "T1: onboarding surface ok" $'OK\tonboarding\t=== Wave 4 onboarding tests: 16 passed, 0 failed ===' "${out}"
assert_contains "T1: summary text" "verify-install-readiness: summary: 4 OK, 0 SKIP, 0 FAIL" "${out}"
assert_contains "T1: green message" "verify-install-readiness: install/onboarding readiness is green across bootstrapper, handoff, recovery, and onboarding proof surfaces" "${out}"

printf 'Test 2: json mode reports failing and skipped surfaces structurally\n'
set +e
out="$(
  run_tool \
    "${bootstrapper_ok}" \
    "${handoff_ok}" \
    "${recovery_fail}" \
    "${onboarding_ok}" \
    --skip-bootstrapper \
    --skip-onboarding \
    --json 2>&1
)"
rc="$?"
set -e
assert_eq "T2: json mode exits non-zero on failure" "1" "${rc}"
assert_jq_eq "T2: top-level result is fail" '.result' "fail" "${out}"
assert_jq_eq "T2: ok count" '.counts.ok' "1" "${out}"
assert_jq_eq "T2: skip count" '.counts.skip' "2" "${out}"
assert_jq_eq "T2: fail count" '.counts.fail' "1" "${out}"
assert_jq_eq "T2: bootstrapper skipped" '.surfaces[] | select(.name=="bootstrapper") | .status' "SKIP" "${out}"
assert_jq_eq "T2: recovery failed" '.surfaces[] | select(.name=="recovery") | .status' "FAIL" "${out}"
assert_jq_eq "T2: onboarding skipped" '.surfaces[] | select(.name=="onboarding") | .status' "SKIP" "${out}"
assert_jq_eq "T2: recovery output captured" '.surfaces[] | select(.name=="recovery") | .output' $'recovery trace line\n=== Install recovery tests: 14 passed, 1 failed ===' "${out}"
assert_jq_eq "T2: bootstrapper skip summary captured" '.surfaces[] | select(.name=="bootstrapper") | .summary' "verify-install-readiness: bootstrapper audit skipped by caller" "${out}"

printf 'Test 3: help output documents the composed readiness surfaces\n'
out="$(bash "${TOOL}" --help)"
assert_contains "T3: help mentions bootstrapper" "bootstrapper / canonical update path contract" "${out}"
assert_contains "T3: help mentions handoff" "fresh-install handoff contract" "${out}"
assert_contains "T3: help mentions recovery" "first-run recovery-path contract" "${out}"
assert_contains "T3: help mentions onboarding" "AI-assisted onboarding/install prompt contract" "${out}"

printf 'Test 4: docs inventory the install-readiness helper\n'
readme_contents="$(cat "${README_REAL}")"
contributing_contents="$(cat "${CONTRIBUTING_REAL}")"
claude_contents="$(cat "${CLAUDE_REAL}")"
agents_contents="$(cat "${AGENTS_REAL}")"
assert_contains "T4: README mentions helper" 'tools/verify-install-readiness.sh' "${readme_contents}"
assert_contains "T4: CONTRIBUTING mentions helper" 'tools/verify-install-readiness.sh' "${contributing_contents}"
assert_contains "T4: CLAUDE mentions helper" 'verify-install-readiness.sh' "${claude_contents}"
assert_contains "T4: AGENTS mentions helper" 'verify-install-readiness.sh' "${agents_contents}"

printf '\ninstall-readiness tests: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
