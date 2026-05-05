#!/usr/bin/env bash
#
# tests/test-release.sh — regression net for tools/release.sh
# (v1.32.14 R4 closure from the v1.32.0 release post-mortem).
#
# The release tool wraps CONTRIBUTING.md steps 7-14 into a single
# command. This test exercises the validation paths + dry-run mode
# against a fixture git repo. Live destructive tests (real tag
# push, gh release create) are intentionally NOT exercised — those
# would require a remote and gh credentials.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL_REAL="${REPO_ROOT}/tools/release.sh"

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

mk_release_fixture() {
  local repo
  repo="$(mktemp -d -t release-test-XXXXXX)"
  (
    cd "${repo}" || exit 1
    git init -q -b main
    git config user.email "test@example.test"
    git config user.name "Test"
    mkdir -p tools tests
    cp "${TOOL_REAL}" "tools/release.sh"
    chmod +x "tools/release.sh"
    printf '1.0.0\n' > VERSION
    printf '# Test\n[![Version](https://img.shields.io/badge/Version-1.0.0-blue.svg)]\n' > README.md
    cat > CHANGELOG.md <<'CL'
# Changelog

## [Unreleased]

### Added

- placeholder for next release

## [1.0.0] - 2026-01-01

initial.
CL
    # gitignore the hotfix-sweep marker so its presence doesn't
    # trip the dirty-tree check before release.sh detects it.
    printf '.hotfix-sweep-quick\n' > .gitignore
    git add -A
    git commit -q -m "initial"
  ) || return 1
  printf '%s' "${repo}"
}

cleanup_fixture() {
  local repo="$1"
  [[ -n "${repo}" && -d "${repo}" && "${repo}" == */release-test-* ]] && rm -rf "${repo}"
}

# ---------------------------------------------------------------------
printf 'Test 1: missing version arg → fails with usage\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh 2>&1)"
rc=$?
set -e
assert_eq "T1: missing arg exits non-zero" "1" "${rc}"
assert_contains "T1: prints usage hint" "missing version argument" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 2: invalid semver → fails\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "v1.2.3" 2>&1)"
rc=$?
set -e
assert_eq "T2: leading-v rejected" "1" "${rc}"
assert_contains "T2: names semver requirement" "X.Y.Z" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 3: dirty working tree → fails\n'
repo="$(mk_release_fixture)"
echo "dirt" > "${repo}/dirty-file"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T3: dirty tree rejected" "1" "${rc}"
assert_contains "T3: names dirty-tree blocker" "working tree is not clean" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 4: not on main → fails\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git checkout -q -b feature)
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T4: non-main rejected" "1" "${rc}"
assert_contains "T4: names branch" "must be on main" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 5: version not above current → fails\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.0" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T5: same-version rejected" "1" "${rc}"
assert_contains "T5: names not-above" "not above current" "${out}"

set +e
out_lower="$(cd "${repo}" && bash tools/release.sh "0.9.0" --dry-run 2>&1)"
rc_lower=$?
set -e
assert_eq "T5: lower-version rejected" "1" "${rc_lower}"
assert_contains "T5: lower also names not-above" "not above current" "${out_lower}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 6: tag already exists → fails\n'
repo="$(mk_release_fixture)"
(cd "${repo}" && git tag v1.0.1)
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T6: existing tag rejected" "1" "${rc}"
assert_contains "T6: names tag conflict" "already exists" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 7: hotfix-sweep --quick marker → fails\n'
repo="$(mk_release_fixture)"
: > "${repo}/.hotfix-sweep-quick"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T7: quick-marker rejected" "1" "${rc}"
assert_contains "T7: names hotfix-sweep" "hotfix-sweep" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 8: dry-run prints all steps without executing\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T8: dry-run exits 0 on valid path" "0" "${rc}"
assert_contains "T8: announces step 7" "Step 7" "${out}"
assert_contains "T8: announces step 9" "Step 9" "${out}"
assert_contains "T8: announces step 10-12" "Step 10-12" "${out}"
assert_contains "T8: dry-run marker present" "[dry-run]" "${out}"
# Verify VERSION not changed
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T8: VERSION unchanged in dry-run" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf '\n=== release tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
