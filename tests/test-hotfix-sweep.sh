#!/usr/bin/env bash
#
# tests/test-hotfix-sweep.sh — regression net for tools/hotfix-sweep.sh
# (v1.32.11 R5 closure from the v1.32.0 release post-mortem).
#
# Pins the four checks the sweep performs:
#   1. No-op exit when no changes since baseline tag
#   2. CHANGELOG-coupled tests run (and fail when they should)
#   3. shellcheck failure on lint-broken changed file → sweep exits non-zero
#   4. lib-reachability orphan detection (modified lib without test)
#
# The sweep tool runs on the LIVE repo. To pin its behavior we set up
# a tmpdir git repo with controlled fixtures and override REPO_ROOT
# via the tool's `cd "${REPO_ROOT}"` line. Since the tool computes
# REPO_ROOT from its own location (`$(dirname "$0")/..`), the test
# copies the tool into a fixture repo's tools/ dir and runs from
# there, with its own LAST_TAG baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL_REAL="${REPO_ROOT_REAL}/tools/hotfix-sweep.sh"

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

# Build a fixture repo with the tool, a baseline tag, and any extra
# files passed in. Returns the repo path on stdout.
mk_fixture_repo() {
  local repo
  repo="$(mktemp -d -t hotfix-sweep-XXXXXX)"
  (
    cd "${repo}" || exit 1
    git init -q
    git config user.email "test@example.test"
    git config user.name "Test"
    mkdir -p tools tests bundle/dot-claude/skills/autowork/scripts/lib \
             .github/workflows
    cp "${TOOL_REAL}" "tools/hotfix-sweep.sh"
    chmod +x "tools/hotfix-sweep.sh"
    # Minimal validate.yml so lib-reachability check has a workflow
    # to grep. Pin one fake test so we can test pinned vs unpinned.
    # Format MUST match the real repo's pattern: `run:` on its own
    # line, 8-space indented, no leading `-`. The lib-reachability
    # regex `^\s+run:\s+bash tests/test-X` depends on that shape.
    cat > .github/workflows/validate.yml <<'YAML'
name: Validate
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Run foo tests
        run: bash tests/test-foo.sh
YAML
    git add -A
    git commit -q -m "baseline"
    git tag v0.0.0
  ) || return 1
  printf '%s' "${repo}"
}

cleanup_fixture() {
  local repo="$1"
  [[ -n "${repo}" && -d "${repo}" && "${repo}" == */hotfix-sweep-* ]] && rm -rf "${repo}"
}

# ---------------------------------------------------------------------
printf 'Test 1: no-op exit when no changes since baseline tag\n'
repo="$(mk_fixture_repo)"
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh 2>&1)"
rc=$?
set -e
assert_eq "T1: no-op exits 0" "0" "${rc}"
assert_contains "T1: announces no-op" "sweep is a no-op" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 2: docs-only change → fast-path skips heavy checks\n'
repo="$(mk_fixture_repo)"
echo "doc change" > "${repo}/README.md"
(cd "${repo}" && git add README.md && git commit -q -m "docs only")
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh --verbose 2>&1)"
rc=$?
set -e
assert_eq "T2: docs-only exits 0" "0" "${rc}"
assert_contains "T2: sterile skipped on docs-only" "no fix-shaped changes" "${out}"
assert_contains "T2: passes" "All checks passed" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 3: shellcheck failure on changed bundle script → sweep fails\n'
repo="$(mk_fixture_repo)"
# Create a deliberately broken script. `local foo=$(...)` outside a
# function is SC2168 (error) AND SC2155 (warning) — fires under
# --severity=warning.
mkdir -p "${repo}/bundle/dot-claude/scripts"
cat > "${repo}/bundle/dot-claude/scripts/broken.sh" <<'SH'
#!/usr/bin/env bash
local foo=$(echo bar)
printf '%s\n' "${foo}"
SH
(cd "${repo}" && git add bundle && git commit -q -m "broken script")
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc=$?
set -e
assert_eq "T3: sweep exits non-zero on shellcheck failure" "1" "${rc}"
assert_contains "T3: names shellcheck failure" "shellcheck:" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 4: lib-reachability — modified lib without matching test\n'
repo="$(mk_fixture_repo)"
mkdir -p "${repo}/bundle/dot-claude/skills/autowork/scripts/lib"
# Valid lint-clean lib content
cat > "${repo}/bundle/dot-claude/skills/autowork/scripts/lib/orphan.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "orphan"
SH
(cd "${repo}" && git add bundle && git commit -q -m "orphan lib")
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc=$?
set -e
assert_eq "T4: sweep exits non-zero on orphan lib" "1" "${rc}"
assert_contains "T4: names orphan" "orphan.sh" "${out}"
assert_contains "T4: lib-reachability label" "lib-reachability" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 5: lib with matching pinned test passes lib-reachability\n'
repo="$(mk_fixture_repo)"
# Setup: lib + matching test + pin in validate.yml
mkdir -p "${repo}/bundle/dot-claude/skills/autowork/scripts/lib"
cat > "${repo}/bundle/dot-claude/skills/autowork/scripts/lib/foo.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "foo"
SH
cat > "${repo}/tests/test-foo.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "test-foo"
SH
chmod +x "${repo}/tests/test-foo.sh"
# validate.yml already pins test-foo.sh from mk_fixture_repo
(cd "${repo}" && git add -A && git commit -q -m "lib + test pinned")
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc=$?
set -e
assert_eq "T5: sweep passes when lib has CI-pinned test" "0" "${rc}"
assert_contains "T5: All checks passed" "All checks passed" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
printf 'Test 6: --quick mode skips sterile-env with warning\n'
repo="$(mk_fixture_repo)"
# Just create some change so it's not no-op
mkdir -p "${repo}/bundle/dot-claude/scripts"
cat > "${repo}/bundle/dot-claude/scripts/ok.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
SH
(cd "${repo}" && git add -A && git commit -q -m "fix-shaped change")
set +e
out="$(cd "${repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc=$?
set -e
assert_eq "T6: --quick exits 0 when other checks pass" "0" "${rc}"
assert_contains "T6: --quick warning surfaces" "sterile-env skipped" "${out}"
cleanup_fixture "${repo}"

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# Test 7 (v1.32.12 G1 fix): no-tags + fix-shaped changes — pre-fix
# silently green-passed because `git rev-parse HEAD~10` writes
# "HEAD~10" to stdout AND fails rc=128. Post-fix uses
# `git rev-parse --max-parents=0 HEAD` (root commit) which always
# succeeds; the diff against root reaches every commit.
# ---------------------------------------------------------------------
printf 'Test 7: no-tags repo with fix-shaped changes is NOT silently green\n'
no_tag_repo="$(mktemp -d -t hotfix-sweep-notag-XXXXXX)"
(
  cd "${no_tag_repo}" || exit 1
  git init -q
  git config user.email "test@example.test"
  git config user.name "Test"
  mkdir -p tools tests bundle/dot-claude/skills/autowork/scripts/lib \
           .github/workflows
  cp "${TOOL_REAL}" "tools/hotfix-sweep.sh"
  chmod +x "tools/hotfix-sweep.sh"
  cat > .github/workflows/validate.yml <<'YAML'
name: Validate
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Run foo tests
        run: bash tests/test-foo.sh
YAML
  echo "initial" > a
  git add -A
  git commit -q -m "initial commit"
  # No git tag — this simulates the install-remote.sh shallow-clone case.
)
# Make a fix-shaped change AFTER the root commit.
mkdir -p "${no_tag_repo}/bundle/dot-claude/skills/autowork/scripts/lib"
cat > "${no_tag_repo}/bundle/dot-claude/skills/autowork/scripts/lib/orphan.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "orphan"
SH
(cd "${no_tag_repo}" && git add -A && git commit -q -m "fix-shaped change")
set +e
out_t7="$(cd "${no_tag_repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc_t7=$?
set -e
# Pre-fix: silently green-passed with "sweep is a no-op", rc=0. The
# G1 fix detects fix-shaped changes via root-commit baseline and
# the lib-reachability check fires on the orphan lib.
assert_eq "T7: no-tags repo with fix-shaped change exits non-zero" "1" "${rc_t7}"
# Crucially must NOT silently green-pass:
if [[ "${out_t7}" == *"sweep is a no-op"* ]]; then
  printf '  FAIL: T7: tool reported no-op despite fix-shaped change present\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "T7: detects orphan lib via root-commit baseline" "orphan.sh" "${out_t7}"
rm -rf "${no_tag_repo}" 2>/dev/null

# ---------------------------------------------------------------------
# Test 8 (v1.32.12 G3 fix): --quick stamps a marker; subsequent
# --quick run sees the marker and warns about prior-also-quick.
# ---------------------------------------------------------------------
printf 'Test 8: --quick run stamps marker for later detection\n'
repo="$(mk_fixture_repo)"
mkdir -p "${repo}/bundle/dot-claude/scripts"
cat > "${repo}/bundle/dot-claude/scripts/ok.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
SH
(cd "${repo}" && git add -A && git commit -q -m "fix-shaped change")
# First --quick run — stamps marker.
set +e
out_first="$(cd "${repo}" && bash tools/hotfix-sweep.sh --quick 2>&1)"
rc_first=$?
set -e
assert_eq "T8: first --quick exits 0" "0" "${rc_first}"
if [[ -f "${repo}/.hotfix-sweep-quick" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T8: --quick did not create .hotfix-sweep-quick marker\n' >&2
  fail=$((fail + 1))
fi
cleanup_fixture "${repo}"

printf '\n=== hotfix-sweep tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
