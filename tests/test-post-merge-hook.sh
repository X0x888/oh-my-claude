#!/usr/bin/env bash
#
# test-post-merge-hook.sh — covers the opt-in --git-hooks flow.
#
# The feature has three surfaces that need to stay in sync across releases:
#   1. install.sh::install_git_hooks writes the post-merge hook with a
#      stable signature, refuses to overwrite foreign hooks.
#   2. The hook script itself (a heredoc inside install_git_hooks) detects
#      bundle drift against the installed manifest + install-stamp.
#   3. uninstall.sh removes only signed (oh-my-claude) hooks and preserves
#      any foreign hook living at the same path.
#
# We extract the install_git_hooks function from install.sh and call it in
# isolation against a disposable fake repo, so the test does not touch the
# real ~/.claude, does not rsync the bundle, and does not mutate the repo's
# own .git/hooks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0
fail=0

TEST_ROOT="$(mktemp -d -t omc-post-merge-test.XXXXXX)"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_exists() {
  local label="$1"
  local path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    missing file: %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_contains() {
  local label="$1"
  local needle="$2"
  local path="$3"
  if [[ -f "${path}" ]] && grep -Fq "${needle}" "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected %s to contain: %s\n' "${label}" "${path}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# Extract the install_git_hooks function body from install.sh into a
# standalone snippet we can source. The function references SCRIPT_DIR
# (the source repo to write into) so the caller sets that before the call.
extract_fn() {
  local fn_name="$1"
  local src="$2"
  awk -v fn="${fn_name}" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}$/ { in_fn = 0; exit }
  ' "${src}"
}

setup_fake_repo() {
  local repo="$1"
  rm -rf "${repo}"
  mkdir -p "${repo}/bundle/dot-claude"
  # `git rev-parse --show-toplevel` inside the hook needs a real enough git
  # worktree to resolve; a hand-rolled .git/config is insufficient and falls
  # through to the hook's early-exit-on-empty-repo-root branch, which would
  # silently pass drift assertions. `git init --quiet` creates the minimum
  # real structure and is cheap.
  git init --quiet --initial-branch=main "${repo}" 2>/dev/null \
    || git init --quiet "${repo}"
}

# ===========================================================================
# Case 1: --git-hooks writes the signed hook into .git/hooks/post-merge.
# ===========================================================================
printf 'Case 1: --git-hooks writes the signed hook:\n'

REPO1="${TEST_ROOT}/repo1"
setup_fake_repo "${REPO1}"

# Source the function into a subshell with SCRIPT_DIR pointed at REPO1.
INSTALL_HOOKS_FN="$(extract_fn install_git_hooks "${INSTALL_SH}")"
(
  set -euo pipefail
  SCRIPT_DIR="${REPO1}"
  eval "${INSTALL_HOOKS_FN}"
  install_git_hooks >/dev/null 2>&1
)

HOOK1="${REPO1}/.git/hooks/post-merge"
assert_file_exists "hook written to post-merge" "${HOOK1}"
assert_file_contains "hook carries the signature line" "# oh-my-claude post-merge auto-sync" "${HOOK1}"
assert_file_contains "hook references the installer variable" 'installer="${repo_root}/install.sh"' "${HOOK1}"
assert_file_contains "hook honors OMC_AUTO_INSTALL" 'OMC_AUTO_INSTALL' "${HOOK1}"

if [[ -x "${HOOK1}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: hook is not executable: %s\n' "${HOOK1}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 2: a foreign (non-oh-my-claude) hook is preserved.
# ===========================================================================
printf 'Case 2: foreign hook is preserved:\n'

REPO2="${TEST_ROOT}/repo2"
setup_fake_repo "${REPO2}"
HOOK2="${REPO2}/.git/hooks/post-merge"
# Freeze the foreign hook onto disk via a fixture file so diff comparisons
# can round-trip exactly — $(cat) would strip trailing newlines and lie.
FOREIGN_FIXTURE="${TEST_ROOT}/foreign-hook.fixture"
printf '#!/usr/bin/env bash\n# user custom hook\necho "user hook fired"\n' > "${FOREIGN_FIXTURE}"
cp "${FOREIGN_FIXTURE}" "${HOOK2}"
chmod +x "${HOOK2}"

(
  set -euo pipefail
  SCRIPT_DIR="${REPO2}"
  eval "${INSTALL_HOOKS_FN}"
  install_git_hooks >/dev/null 2>&1
)

# The foreign hook body must still be there — no signature, no overwrite.
if diff -q "${FOREIGN_FIXTURE}" "${HOOK2}" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: foreign hook body changed\n' >&2
  diff "${FOREIGN_FIXTURE}" "${HOOK2}" || true
  fail=$((fail + 1))
fi

# The hook must NOT have acquired our signature — the installer's refuse-
# to-overwrite logic keyed off the signature's absence.
if grep -q '# oh-my-claude post-merge auto-sync' "${HOOK2}"; then
  printf '  FAIL: foreign hook was unexpectedly signed\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ===========================================================================
# Case 3: re-running with a pre-existing signed hook is idempotent.
# ===========================================================================
printf 'Case 3: re-running on a signed hook is idempotent:\n'

(
  set -euo pipefail
  SCRIPT_DIR="${REPO1}"
  eval "${INSTALL_HOOKS_FN}"
  install_git_hooks >/dev/null 2>&1
)

assert_file_contains "signature still present on re-run" "# oh-my-claude post-merge auto-sync" "${HOOK1}"

# ===========================================================================
# Case 4: uninstall.sh's removal clause drops only signed hooks.
#
# The uninstall block looks up repo_path from oh-my-claude.conf and deletes
# <repo>/.git/hooks/post-merge when it carries the signature. We reproduce
# that exact grep-then-rm sequence since the uninstall.sh block is short
# and copying it avoids invoking the full uninstaller.
# ===========================================================================
printf 'Case 4: uninstall removes signed hook, keeps foreign one:\n'

FAKE_HOME="${TEST_ROOT}/home"
mkdir -p "${FAKE_HOME}/.claude"
CONF="${FAKE_HOME}/.claude/oh-my-claude.conf"

# Signed hook — should be removed.
printf 'repo_path=%s\n' "${REPO1}" > "${CONF}"
_repo_path="$(grep -E '^repo_path=' "${CONF}" 2>/dev/null | head -1 | cut -d= -f2-)"
_hook_path="${_repo_path}/.git/hooks/post-merge"
if [[ -f "${_hook_path}" ]] && grep -q '# oh-my-claude post-merge auto-sync' "${_hook_path}" 2>/dev/null; then
  rm -f "${_hook_path}"
fi

if [[ -f "${HOOK1}" ]]; then
  printf '  FAIL: signed hook was not removed at %s\n' "${HOOK1}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# Foreign hook — repo2 still has it. Repeat the removal clause pointing at
# repo2 and assert it stays in place.
printf 'repo_path=%s\n' "${REPO2}" > "${CONF}"
_repo_path="$(grep -E '^repo_path=' "${CONF}" 2>/dev/null | head -1 | cut -d= -f2-)"
_hook_path="${_repo_path}/.git/hooks/post-merge"
if [[ -f "${_hook_path}" ]] && grep -q '# oh-my-claude post-merge auto-sync' "${_hook_path}" 2>/dev/null; then
  rm -f "${_hook_path}"
fi

assert_file_exists "foreign hook still present after uninstall clause" "${HOOK2}"
if diff -q "${FOREIGN_FIXTURE}" "${HOOK2}" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: foreign hook body changed by uninstall clause\n' >&2
  diff "${FOREIGN_FIXTURE}" "${HOOK2}" || true
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 5: the hook script exits cleanly when the manifest is missing.
#
# Users who clone-then-pull before ever running install.sh will see the
# hook fire with no manifest on disk. The hook must no-op rather than
# explode into the user's terminal.
# ===========================================================================
printf 'Case 5: hook no-ops when installed-manifest is missing:\n'

REPO3="${TEST_ROOT}/repo3"
setup_fake_repo "${REPO3}"
# Seed install.sh and two bundle files so cases 5-7 can exercise distinct
# drift paths (stamp-newer vs manifest-diff) without running into the
# "single-line manifest goes empty on grep -v" edge case.
cp "${INSTALL_SH}" "${REPO3}/install.sh"
printf 'placeholder\n' > "${REPO3}/bundle/dot-claude/placeholder.txt"
printf 'second\n' > "${REPO3}/bundle/dot-claude/second.txt"

(
  set -euo pipefail
  SCRIPT_DIR="${REPO3}"
  eval "${INSTALL_HOOKS_FN}"
  install_git_hooks >/dev/null 2>&1
)
HOOK3="${REPO3}/.git/hooks/post-merge"
assert_file_exists "repo3 hook installed" "${HOOK3}"

# Run the hook with HOME pointed at an empty dir — no manifest present.
empty_home="${TEST_ROOT}/empty_home"
mkdir -p "${empty_home}"
rc=0
(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" >/dev/null 2>&1) || rc=$?
assert_eq "hook exits 0 when no manifest exists" "0" "${rc}"

# Run the hook after planting a manifest and install-stamp with no drift —
# it should still exit 0 and print nothing.
mkdir -p "${empty_home}/.claude/quality-pack/state"
(cd "${REPO3}/bundle/dot-claude" && find . -type f ! -name '.DS_Store' 2>/dev/null \
  | sed 's|^\./||' | LC_ALL=C sort) > "${empty_home}/.claude/quality-pack/state/installed-manifest.txt"
touch "${empty_home}/.claude/.install-stamp"
# Make the stamp newer than all bundle files so the "newer-than-stamp"
# drift detector reports no change.
find "${REPO3}/bundle/dot-claude" -type f -exec touch -t 202001010000 {} \;

rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook exits 0 when manifest matches bundle" "0" "${rc}"
assert_eq "hook emits no warning on no drift" "" "${hook_out}"

# ===========================================================================
# Case 6: the hook reports drift when a bundle file is newer than the stamp.
#
# The no-drift case (5b) is useful but a regression that makes the hook
# silently skip ALL drift detection would still pass it. This positive
# case flips content_changed to 1 by touching a bundle file with a
# post-stamp mtime and asserts the yellow warning line appears.
# ===========================================================================
printf 'Case 6: hook reports drift when bundle file is newer than stamp:\n'

# Bump one file's mtime to "now" so find -newer catches it vs the stamp
# we planted in 2020. Keep stamp ancient; modify one bundle file current.
touch "${REPO3}/bundle/dot-claude/placeholder.txt"

rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook exits 0 on drift (non-blocking by design)" "0" "${rc}"
if printf '%s' "${hook_out}" | grep -q 'Bundle changes detected after merge'; then
  pass=$((pass + 1))
else
  printf '  FAIL: expected drift banner in hook output, got:\n%s\n' "${hook_out}" >&2
  fail=$((fail + 1))
fi
if printf '%s' "${hook_out}" | grep -q 'bundle files newer than last install'; then
  pass=$((pass + 1))
else
  printf '  FAIL: expected content_changed detail line in hook output, got:\n%s\n' "${hook_out}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 7: the hook reports drift when the file set changed (added/removed).
#
# Exercises the added_or_removed detector: sorted manifest diff against the
# live bundle file list. Remove one file from the manifest so the hook sees
# a "missing" file and must warn — covers the other branch independently.
# ===========================================================================
printf 'Case 7: hook reports drift when file set differs from manifest:\n'

# Reset file-system state to pre-drift: ancient stamp, ancient bundle.
find "${REPO3}/bundle/dot-claude" -type f -exec touch -t 202001010000 {} \;
touch -t 202001010000 "${empty_home}/.claude/.install-stamp"

# Remove a file from the manifest so the live bundle looks like it has
# EXTRA files vs what was last installed. This flips added_or_removed=1
# without touching mtimes. Second.txt is removed from the manifest but
# stays in the bundle, so the diff sees a present-file-missing-from-
# manifest case. Guarded with `|| true` because grep exits 1 when the
# pattern matches every line (never in this test, but keeps the test
# hermetic against future manifest changes).
manifest="${empty_home}/.claude/quality-pack/state/installed-manifest.txt"
{ grep -v 'second.txt' "${manifest}" || true; } > "${manifest}.tmp"
mv "${manifest}.tmp" "${manifest}"

rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook exits 0 on added_or_removed drift" "0" "${rc}"
if printf '%s' "${hook_out}" | grep -q 'File set changed'; then
  pass=$((pass + 1))
else
  printf '  FAIL: expected added_or_removed detail line, got:\n%s\n' "${hook_out}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n'
printf '=== Post-merge hook tests: %d passed, %d failed ===\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
