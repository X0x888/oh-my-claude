#!/usr/bin/env bash
# Regression net for first-run install recovery paths.
#
# Proves the highest-risk bootstrapper failures remain professionally
# actionable and documented:
#   1. missing prereqs
#   2. canonical-path collision / foreign repo protection
#   3. post-install verify failure handoff
#
# The focused bootstrapper suite already covers these mechanics in
# isolation. This file closes the remaining distribution gap by pinning
# the user-visible transcript plus README troubleshooting guidance
# together as one contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAPPER="${REPO_ROOT}/install-remote.sh"

pass=0
fail=0

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
TEST_HOME="${WORK_DIR}/home"
mkdir -p "${TEST_HOME}"

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
    printf '  FAIL: %s — needle %q not in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1"
  if eval "$2"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n' "${label}" >&2
    fail=$((fail + 1))
  fi
}

printf '1. Missing prereq failure stays actionable\n'

safe_path="$(mktemp -d)"
ln -s "$(command -v bash)" "${safe_path}/bash"
ln -s "$(command -v jq)" "${safe_path}/jq"
ln -s "$(command -v rsync)" "${safe_path}/rsync"

set +e
missing_prereq_output="$(env -i HOME="${TEST_HOME}" PATH="${safe_path}" bash "${BOOTSTRAPPER}" 2>&1)"
missing_prereq_rc=$?
set -e

assert_true "missing-prereq exits non-zero" "[[ '${missing_prereq_rc}' -ne 0 ]]"
assert_contains "missing-prereq names the missing command" \
  "missing required command: git" "${missing_prereq_output}"
assert_contains "missing-prereq tells user to install and retry" \
  "Install it (e.g. via your package manager) and retry." "${missing_prereq_output}"

printf '\n'
printf '2. Foreign-repo collision is blocked before any installer runs\n'

expected_src="${WORK_DIR}/expected-source"
expected_bare="${WORK_DIR}/expected.git"
foreign_src="${WORK_DIR}/foreign-source"
foreign_bare="${WORK_DIR}/foreign.git"
foreign_clone="${WORK_DIR}/foreign-clone"
mkdir -p "${expected_src}" "${foreign_src}"

(
  cd "${expected_src}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'EXPECTED-INSTALL-RAN\n'
exit 0
STUB
  cat > verify.sh <<'STUB'
#!/usr/bin/env bash
printf 'EXPECTED-VERIFY-RAN\n'
printf '  Errors:        0\n'
exit 0
STUB
  chmod +x install.sh verify.sh
  git add install.sh verify.sh
  git commit --quiet -m "expected repo"
)
git clone --quiet --bare "${expected_src}" "${expected_bare}"

(
  cd "${foreign_src}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'FOREIGN-INSTALL-RAN\n'
exit 0
STUB
  chmod +x install.sh
  git add install.sh
  git commit --quiet -m "foreign repo"
)
git clone --quiet --bare "${foreign_src}" "${foreign_bare}"
git clone --quiet "${foreign_bare}" "${foreign_clone}"

set +e
foreign_output="$(OMC_SRC_DIR="${foreign_clone}" OMC_REPO_URL="${expected_bare}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
foreign_rc=$?
set -e

assert_true "foreign-repo collision exits non-zero" "[[ '${foreign_rc}' -ne 0 ]]"
assert_contains "foreign-repo collision names both remotes" \
  "points at ${foreign_bare}, expected ${expected_bare}" "${foreign_output}"
assert_contains "foreign-repo collision explains refusal" \
  "Refusing to run the wrong installer." "${foreign_output}"
if [[ "${foreign_output}" == *"FOREIGN-INSTALL-RAN"* ]]; then
  printf '  FAIL: foreign repo collision should not run install.sh\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf '\n'
printf '3. Post-install verify failure points at the retained repo and verifier\n'

failing_src="${WORK_DIR}/failing-source"
failing_bare="${WORK_DIR}/failing.git"
failing_clone="${WORK_DIR}/failing-clone"
mkdir -p "${failing_src}"

(
  cd "${failing_src}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  cat > install.sh <<'STUB'
#!/usr/bin/env bash
printf 'FAILING-INSTALL-RAN\n'
exit 0
STUB
  cat > verify.sh <<'STUB'
#!/usr/bin/env bash
printf 'FAILING-VERIFY-RAN\n'
printf '=== Verification complete ===\n'
printf '  Errors:        1\n'
exit 1
STUB
  chmod +x install.sh verify.sh
  git add install.sh verify.sh
  git commit --quiet -m "failing verify fixture"
)
git clone --quiet --bare "${failing_src}" "${failing_bare}"

set +e
verify_fail_output="$(OMC_SRC_DIR="${failing_clone}" OMC_REPO_URL="${failing_bare}" OMC_REF="main" \
  HOME="${TEST_HOME}" bash "${BOOTSTRAPPER}" 2>&1)"
verify_fail_rc=$?
set -e

assert_true "verify-failure exits non-zero" "[[ '${verify_fail_rc}' -ne 0 ]]"
assert_true "verify-failure leaves cloned repo on disk" "[[ -d '${failing_clone}/.git' ]]"
assert_contains "verify-failure includes verifier output" \
  "Errors:        1" "${verify_fail_output}"
assert_contains "verify-failure emits recovery summary" \
  "post-install verification failed. Source repo remains at ${failing_clone};" "${verify_fail_output}"
assert_contains "verify-failure points at re-run verifier path" \
  "re-run ${failing_clone}/verify.sh" "${verify_fail_output}"

printf '\n'
printf '4. README troubleshooting documents the same recovery paths\n'

readme="$(<"${REPO_ROOT}/README.md")"

assert_contains "README covers bootstrapper missing-prereq failures" \
  "\`install-remote.sh\` exits with \`missing required command:" "${readme}"
assert_contains "README covers bootstrapper foreign-repo collision" \
  "Refusing to run the wrong installer" "${readme}"
assert_contains "README covers bootstrapper verify failure handoff" \
  "\`install-remote.sh\` says \`post-install verification failed\`" "${readme}"

printf '\n=== Install recovery tests: %s passed, %s failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
