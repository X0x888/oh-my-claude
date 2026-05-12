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
# ---------------------------------------------------------------------
# T9 (v1.32.15 G1 fix): trailing whitespace on [Unreleased] heading
# detected and rejected pre-1.32.15 the perl regex silent-no-op'd.
# ---------------------------------------------------------------------
printf 'Test 9: [Unreleased] heading with trailing whitespace → fails\n'
repo="$(mk_release_fixture)"
# Replace clean [Unreleased] with one carrying trailing spaces.
perl -i -pe 's|^## \[Unreleased\]$|## [Unreleased]   |' "${repo}/CHANGELOG.md"
(cd "${repo}" && git add -A && git commit -q -m "introduce trailing whitespace")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T9: trailing-ws heading rejected" "1" "${rc}"
assert_contains "T9: names trailing whitespace" "trailing whitespace" "${out}"
# Verify CHANGELOG was NOT mutated (the bug pre-1.32.15 was a
# silent perl no-op; we should fail BEFORE the perl substitution).
if grep -qE '^## \[1\.0\.1\]' "${repo}/CHANGELOG.md"; then
  printf '  FAIL: T9: trailing-ws case wrote a release heading anyway\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T10 (v1.32.15 G1 fix): CRLF line endings on [Unreleased] detected.
# ---------------------------------------------------------------------
printf 'Test 10: CRLF line endings on [Unreleased] → fails\n'
repo="$(mk_release_fixture)"
# Convert just the CHANGELOG to CRLF endings to simulate a Windows
# editor save.
awk 'BEGIN{ORS="\r\n"} {print}' "${repo}/CHANGELOG.md" > "${repo}/CHANGELOG.md.crlf"
mv "${repo}/CHANGELOG.md.crlf" "${repo}/CHANGELOG.md"
(cd "${repo}" && git add -A && git commit -q -m "introduce CRLF")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T10: CRLF heading rejected" "1" "${rc}"
assert_contains "T10: names CRLF" "CRLF" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T11 (v1.32.15 G2 fix): empty [Unreleased] section refuses to ship.
# ---------------------------------------------------------------------
printf 'Test 11: empty [Unreleased] section → fails\n'
repo="$(mk_release_fixture)"
# Replace the populated [Unreleased] with an empty one.
cat > "${repo}/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

initial.
CL
(cd "${repo}" && git add -A && git commit -q -m "empty unreleased")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T11: empty Unreleased rejected" "1" "${rc}"
assert_contains "T11: names empty Unreleased" "[Unreleased] section is empty" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T12 (v1.33.x): --tag-on-green and --no-watch are mutually exclusive.
# tag-on-green REQUIRES the watch to know whether to tag, so combining
# them silently degrades to the eager-tag flow without warning unless
# the script rejects the combo loudly. Regression net for that.
printf 'Test 12: --tag-on-green + --no-watch → mutually exclusive\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --tag-on-green --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T12: combo rejected" "2" "${rc}"
assert_contains "T12: names mutual exclusion" "mutually exclusive" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T13 (v1.33.x): legacy eager-tag dry-run announces tag-on-commit shape.
# Smoke check that the unflagged path still reaches "Step 10-12: commit
# + tag + push" and emits the [dry-run] tag command — guards against
# accidental refactor regressions in the eager-tag branch.
printf 'Test 13: eager-tag dry-run still emits tag step\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --no-watch 2>&1)"
rc=$?
set -e
assert_eq "T13: dry-run exits 0" "0" "${rc}"
assert_contains "T13: tag step present" "git tag v1.0.1" "${out}"
assert_contains "T13: tagged-and-pushed announcement" "tagged v1.0.1 and pushed" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T14 (v1.33.x): --tag-on-green dry-run defers the tag and the GH release
# until after CI watch. Smoke check that the new branch is wired and
# emits the deferred-tag announcement instead of "tagged v...".
printf 'Test 14: --tag-on-green dry-run defers tag until CI green\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --tag-on-green 2>&1)"
rc=$?
set -e
assert_eq "T14: dry-run exits 0" "0" "${rc}"
assert_contains "T14: announces deferred tag" "tag deferred until CI green" "${out}"
assert_contains "T14: defers GH release" "GitHub release (deferred" "${out}"
# In dry-run we should NOT see the eager "tagged v1.0.1 and pushed" line.
if printf '%s' "${out}" | grep -q "tagged v1.0.1 and pushed"; then
  printf '  FAIL: T14: --tag-on-green leaked into eager-tag flow (saw "tagged ... and pushed")\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T15 (v1.33.x): unknown args still reject loudly even with the new flag
# in the parser.
printf 'Test 15: unknown arg still rejected after --tag-on-green added\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --bogus-flag 2>&1)"
rc=$?
set -e
assert_eq "T15: unknown arg rejects with rc=2" "2" "${rc}"
assert_contains "T15: names the bad flag" "unknown arg" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T16 (v1.34.1): --ci-preflight and --tag-on-green are mutually
# exclusive. Both gate the tag — picking both is a config bug.
printf 'Test 16: --ci-preflight + --tag-on-green mutually exclusive (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --ci-preflight --tag-on-green 2>&1)"
rc=$?
set -e
assert_eq "T16: combo rejects with rc=2" "2" "${rc}"
assert_contains "T16: names the conflict" "mutually exclusive" "${out}"
assert_contains "T16: explains gate-overlap" "both gate the tag" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T17 (v1.34.1): --ci-preflight dry-run announces Step 6.5 and
# implies the post-flight watch is skipped (no Step 14 watch).
printf 'Test 17: --ci-preflight dry-run announces Step 6.5 and skips watch (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --ci-preflight 2>&1)"
rc=$?
set -e
assert_eq "T17: dry-run exits 0" "0" "${rc}"
assert_contains "T17: announces Step 6.5" "Step 6.5" "${out}"
assert_contains "T17: dry-runs local-ci.sh" "[dry-run] bash tools/local-ci.sh" "${out}"
assert_contains "T17: skips post-flight watch with ci-preflight wording" "ci-preflight already validated" "${out}"
# v1.34.1 reviewer fix: `Step 14: watch CI$` end-anchor can never match
# because `say` decorates output as `── Step 14: watch CI (dry-run) ───`,
# making the negative-watch half a structural no-op. Use the dry-run
# Step 14 wording (`watch CI (dry-run)`) and the live-watch wording
# (`watching run`) directly — both are unambiguous and unanchored.
if printf '%s' "${out}" | grep -q "watching run\|watch CI (dry-run)"; then
  printf '  FAIL: T17: --ci-preflight should skip the watch but watch fired\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "T17: tag stays eager (no defer)" "Step 10-12: commit + tag + push" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T18 (v1.34.1): --ci-preflight parsed regardless of arg order.
printf 'Test 18: --dry-run --ci-preflight order-independent (v1.34.1)\n'
repo="$(mk_release_fixture)"
set +e
out_a="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --ci-preflight 2>&1)"
rc_a=$?
set -e
set +e
out_b="$(cd "${repo}" && bash tools/release.sh "1.0.1" --ci-preflight --dry-run 2>&1)"
rc_b=$?
set -e
assert_eq "T18: order A rc=0" "0" "${rc_a}"
assert_eq "T18: order B rc=0" "0" "${rc_b}"
assert_contains "T18: order A announces Step 6.5" "Step 6.5" "${out_a}"
assert_contains "T18: order B announces Step 6.5" "Step 6.5" "${out_b}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T19 (v1.40.x): local-sweep gate skips with notice when validate.yml
# is missing. The minimal fixture has no .github/workflows/validate.yml
# (it's not part of mk_release_fixture), so the gate must skip
# gracefully rather than abort the release flow.
# ---------------------------------------------------------------------
printf 'Test 19: local-sweep gate skip-with-notice on missing validate.yml (v1.40.x)\n'
repo="$(mk_release_fixture)"
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T19: dry-run with missing validate.yml exits 0" "0" "${rc}"
assert_contains "T19: announces Step 6.7" "Step 6.7" "${out}"
assert_contains "T19: notice on missing workflow" "validate.yml not present" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T20 (v1.40.x): --skip-local-sweep bypasses the gate explicitly.
# Even with validate.yml present, the flag must cleanly skip and
# announce the skip rather than silently running the sweep.
# ---------------------------------------------------------------------
printf 'Test 20: --skip-local-sweep bypass (v1.40.x)\n'
repo="$(mk_release_fixture)"
# Plant a non-empty validate.yml so the gate WOULD run without the
# skip flag. Use a content shape that the gate's grep recognizes.
mkdir -p "${repo}/.github/workflows"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run a test
        run: bash tests/test-nonexistent.sh
YML
(cd "${repo}" && git add -A && git commit -q -m "add fixture validate.yml")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" --dry-run --skip-local-sweep 2>&1)"
rc=$?
set -e
assert_eq "T20: --skip-local-sweep dry-run exits 0" "0" "${rc}"
assert_contains "T20: announces gate skipped" "local-sweep gate skipped" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T21 (v1.40.x): OMC_RELEASE_SKIP_LOCAL_SWEEP=1 bypasses the gate.
# Env-var-based skip is useful for nested CI contexts where a parent
# wrapper has already verified the bash suite.
# ---------------------------------------------------------------------
printf 'Test 21: OMC_RELEASE_SKIP_LOCAL_SWEEP env bypass (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - run: bash tests/test-nonexistent.sh
YML
(cd "${repo}" && git add -A && git commit -q -m "add fixture validate.yml")
set +e
out="$(cd "${repo}" && OMC_RELEASE_SKIP_LOCAL_SWEEP=1 bash tools/release.sh "1.0.1" --dry-run 2>&1)"
rc=$?
set -e
assert_eq "T21: env-skip dry-run exits 0" "0" "${rc}"
assert_contains "T21: env-skip announces gate skipped" "local-sweep gate skipped" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# T22 (v1.40.x): the gate ABORTS the release when a CI-pinned test
# fails. This is the load-bearing assertion — without it, a future
# refactor that turns the gate into "warn but continue" would silently
# regress and v1.40.0-class CI-red tags would ship again.
#
# Build a fixture that:
#   1) Has a validate.yml pinning a failing test
#   2) Has the failing test on disk (so the gate runs it, vs. the
#      "file not present" sub-failure path)
#   3) Drives a NON-dry-run invocation (dry-run bypasses the gate
#      body, so testing the abort requires a real run)
# ---------------------------------------------------------------------
printf 'Test 22: local-sweep gate aborts on test failure (v1.40.x)\n'
repo="$(mk_release_fixture)"
mkdir -p "${repo}/.github/workflows" "${repo}/tests"
cat > "${repo}/.github/workflows/validate.yml" <<'YML'
jobs:
  test:
    steps:
      - name: Run failing test
        run: bash tests/test-deliberate-fail.sh
YML
cat > "${repo}/tests/test-deliberate-fail.sh" <<'TEST'
#!/usr/bin/env bash
printf 'this test deliberately fails for T22 coverage\n' >&2
exit 1
TEST
chmod +x "${repo}/tests/test-deliberate-fail.sh"
(cd "${repo}" && git add -A && git commit -q -m "add failing fixture test")
set +e
out="$(cd "${repo}" && bash tools/release.sh "1.0.1" 2>&1)"
rc=$?
set -e
assert_eq "T22: gate-failure exits non-zero" "1" "${rc}"
assert_contains "T22: names local-sweep gate failure" "local sweep gate failed" "${out}"
assert_contains "T22: lists the failing test" "test-deliberate-fail.sh" "${out}"
# Verify the gate aborted BEFORE Step 7 (VERSION bump). If Step 7 ran,
# the failing test fixture would have been promoted to a release.
ver_after="$(cat "${repo}/VERSION")"
assert_eq "T22: VERSION unchanged after gate-failure" "1.0.0" "${ver_after}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf '\n=== release tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
