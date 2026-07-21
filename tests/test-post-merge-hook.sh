#!/usr/bin/env bash
#
# test-post-merge-hook.sh — covers the opt-in --git-hooks flow.
#
# The feature has three surfaces that need to stay in sync across releases:
#   1. install.sh::install_git_hooks writes the post-merge hook with a
#      stable signature, refuses to overwrite foreign hooks.
#   2. The canonical config/post-merge.hook template detects file-set drift
#      against the installed manifest and byte/mode drift from installed_sha.
#   3. uninstall.sh removes only signed (oh-my-claude) hooks and preserves
#      any foreign hook living at the same path.
#
# We extract the install_git_hooks function from install.sh and call it in
# isolation against a disposable fake repo, so the test does not touch the
# real ~/.claude, does not rsync the bundle, and does not mutate the repo's
# own resolved hooks directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
UNINSTALL_SH="${REPO_ROOT}/uninstall.sh"

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

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${1:-}" | awk '{print $1}'
  else
    sha256sum "${1:-}" | awk '{print $1}'
  fi
}

write_head_legacy_hook() {
  local destination="$1"
  git show HEAD:install.sh | awk '
    /cat > .*<<'"'"'HOOK'"'"'/ { in_hook = 1; next }
    in_hook && /^HOOK$/ { exit }
    in_hook { print }
  ' > "${destination}"
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

hook_path_for_checkout() {
  local repo="$1"
  local hooks_dir=""

  hooks_dir="$(git -C "${repo}" rev-parse --git-path hooks 2>/dev/null || true)"
  [[ -n "${hooks_dir}" ]] || return 1
  if [[ "${hooks_dir}" != /* ]]; then
    hooks_dir="${repo}/${hooks_dir}"
  fi
  printf '%s/post-merge\n' "${hooks_dir}"
}

setup_fake_repo() {
  local repo="$1"
  rm -rf "${repo}"
  mkdir -p "${repo}/bundle/dot-claude" \
    "${repo}/bundle/omc-user-template" \
    "${repo}/config/ghostty/themes"
  cp "${REPO_ROOT}/config/post-merge.hook" "${repo}/config/post-merge.hook"
  # `git rev-parse --show-toplevel` inside the hook needs a real enough git
  # worktree to resolve; a hand-rolled .git/config is insufficient and falls
  # through to the hook's early-exit-on-empty-repo-root branch, which would
  # silently pass drift assertions. `git init --quiet` creates the minimum
  # real structure and is cheap.
  git init --quiet --initial-branch=main "${repo}" 2>/dev/null \
    || git init --quiet "${repo}"
  git -C "${repo}" config user.email test@test.local
  git -C "${repo}" config user.name test
  printf 'seed\n' > "${repo}/bundle/dot-claude/.seed"
  printf '%s\n' '{}' > "${repo}/config/settings.patch.json"
  printf 'override template\n' \
    > "${repo}/bundle/omc-user-template/overrides.md"
  printf 'theme fixture\n' > "${repo}/config/ghostty/themes/fixture"
  git -C "${repo}" add -A
  git -C "${repo}" commit --quiet -m "seed"
}

# ===========================================================================
# Case 1: --git-hooks writes the signed hook into the resolved hooks path.
# ===========================================================================
printf 'Case 1: --git-hooks writes the signed hook:\n'

REPO1="${TEST_ROOT}/repo1"
setup_fake_repo "${REPO1}"

# Source the helper stack + function into a subshell with SCRIPT_DIR
# pointed at the target checkout.
INSTALL_HOOKS_SNIPPET="$(
  {
    extract_fn install_readlink_exact "${INSTALL_SH}"
    printf '\n'
    extract_fn install_stat_value "${INSTALL_SH}"
    printf '\n'
    extract_fn install_file_identity "${INSTALL_SH}"
    printf '\n'
    extract_fn install_node_identity "${INSTALL_SH}"
    printf '\n'
    extract_fn install_directory_identity "${INSTALL_SH}"
    printf '\n'
    extract_fn install_file_mode "${INSTALL_SH}"
    printf '\n'
    extract_fn snapshot_install_transaction_path "${INSTALL_SH}"
    printf '\n'
    extract_fn install_transaction_path_phase_is_current "${INSTALL_SH}"
    printf '\n'
    extract_fn clear_install_transaction_publication "${INSTALL_SH}"
    printf '\n'
    extract_fn arm_install_transaction_publication "${INSTALL_SH}"
    printf '\n'
    extract_fn record_install_transaction_publication "${INSTALL_SH}"
    printf '\n'
    extract_fn publish_install_regular_stage "${INSTALL_SH}"
    printf '\n'
    extract_fn publish_install_regular_source "${INSTALL_SH}"
    printf '\n'
    extract_fn mutate_conf_key "${INSTALL_SH}"
    printf '\n'
    extract_fn set_conf "${INSTALL_SH}"
    printf '\n'
    extract_fn is_git_checkout "${INSTALL_SH}"
    printf '\n'
    extract_fn git_hooks_dir_for_checkout "${INSTALL_SH}"
    printf '\n'
    extract_fn managed_git_hook_path_is_safe "${INSTALL_SH}"
    printf '\n'
    extract_fn read_last_valid_conf_sha256 "${INSTALL_SH}"
    printf '\n'
    extract_fn installed_git_hook_needs_refresh "${INSTALL_SH}"
    printf '\n'
    extract_fn install_git_hooks "${INSTALL_SH}"
    printf '\n%s\n' \
      'MANAGED_GIT_HOOK_TEMPLATE="${SCRIPT_DIR}/config/post-merge.hook"' \
      'LEGACY_GIT_HOOK_SHA256_V1="bdd46902aa5fe24d08a101cc9dbf0683e951109901faf33a657606c78b87d545"' \
      'GIT_HOOK_TRANSACTION_PATH=""' \
      'trusted_sha256_file() {' \
      '  local tool="$1" path="$2" output=""' \
      '  case "${tool##*/}" in' \
      '    shasum) output="$("${tool}" -a 256 -- "${path}")" ;;' \
      '    sha256sum) output="$("${tool}" -- "${path}")" ;;' \
      '    *) return 1 ;;' \
      '  esac' \
      '  printf "%s" "${output%%[[:space:]]*}"' \
      '}' \
      'init_install_hook_test() {' \
      '  TARGET_HOME="$1"' \
      '  CLAUDE_HOME="${TARGET_HOME}/.claude"' \
      '  mkdir -p "${CLAUDE_HOME}"' \
      '  INSTALL_TRANSACTION_DIR="$(mktemp -d "${TARGET_HOME}/.install-hook-txn.XXXXXX")"' \
      '  INSTALL_ROLLBACK_ARMED=1' \
      '  TRUSTED_SHA256_TOOL="$(command -v shasum 2>/dev/null || command -v sha256sum)"' \
      '  snapshot_install_transaction_path "${CLAUDE_HOME}/oh-my-claude.conf" config' \
      '}'
  }
)"
(
  set -euo pipefail
  SCRIPT_DIR="${REPO1}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home1"
  install_git_hooks >/dev/null 2>&1
)

HOOK1="$(hook_path_for_checkout "${REPO1}")"
assert_file_exists "hook written to post-merge" "${HOOK1}"
assert_file_contains "hook carries the signature line" "# oh-my-claude post-merge auto-sync" "${HOOK1}"
assert_file_contains "hook references the installer variable" 'installer="${repo_root}/install.sh"' "${HOOK1}"
assert_file_contains "hook honors OMC_AUTO_INSTALL" 'OMC_AUTO_INSTALL' "${HOOK1}"
assert_eq "installed hook bytes equal canonical template" "true" \
  "$(cmp -s "${REPO1}/config/post-merge.hook" "${HOOK1}" \
    && printf true || printf false)"

if [[ -x "${HOOK1}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: hook is not executable: %s\n' "${HOOK1}" >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 1b: worktree installs resolve to the shared hooks directory.
# ===========================================================================
printf 'Case 1b: worktree checkout resolves the shared hooks path:\n'

REPO1B_MAIN="${TEST_ROOT}/repo1b-main"
REPO1B_WT="${TEST_ROOT}/repo1b-worktree"
setup_fake_repo "${REPO1B_MAIN}"
git -C "${REPO1B_MAIN}" worktree add --quiet "${REPO1B_WT}" -b repo1b-worktree HEAD

(
  set -euo pipefail
  SCRIPT_DIR="${REPO1B_WT}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home1b"
  install_git_hooks >/dev/null 2>&1
)

HOOK1B="$(hook_path_for_checkout "${REPO1B_WT}")"
assert_file_exists "worktree hook written to resolved path" "${HOOK1B}"
assert_file_contains "worktree hook carries the signature line" "# oh-my-claude post-merge auto-sync" "${HOOK1B}"

# ===========================================================================
# Case 2: a foreign (non-oh-my-claude) hook is preserved.
# ===========================================================================
printf 'Case 2: foreign hook is preserved:\n'

REPO2="${TEST_ROOT}/repo2"
setup_fake_repo "${REPO2}"
HOOK2="$(hook_path_for_checkout "${REPO2}")"
# Freeze the foreign hook onto disk via a fixture file so diff comparisons
# can round-trip exactly — $(cat) would strip trailing newlines and lie.
FOREIGN_FIXTURE="${TEST_ROOT}/foreign-hook.fixture"
printf '#!/usr/bin/env bash\n# user custom hook\necho "user hook fired"\n' > "${FOREIGN_FIXTURE}"
cp "${FOREIGN_FIXTURE}" "${HOOK2}"
chmod +x "${HOOK2}"

(
  set -euo pipefail
  SCRIPT_DIR="${REPO2}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home2"
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

# A marker substring is not ownership. Preserve a foreign hook that happens to
# mention the old marker text.
REPO2B="${TEST_ROOT}/repo2b"
setup_fake_repo "${REPO2B}"
HOOK2B="$(hook_path_for_checkout "${REPO2B}")"
printf '%s\n' '#!/usr/bin/env bash' \
  '# oh-my-claude post-merge auto-sync' \
  'printf "foreign marker decoy\n"' > "${HOOK2B}"
cp "${HOOK2B}" "${TEST_ROOT}/marker-decoy.before"
(
  set -euo pipefail
  SCRIPT_DIR="${REPO2B}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home2b"
  install_git_hooks >/dev/null 2>&1
)
assert_eq "marker-only foreign hook is preserved by install" "true" \
  "$(cmp -s "${TEST_ROOT}/marker-decoy.before" "${HOOK2B}" \
    && printf true || printf false)"

# ===========================================================================
# Case 3: re-running with a pre-existing signed hook is idempotent.
# ===========================================================================
printf 'Case 3: re-running on a signed hook is idempotent:\n'

(
  set -euo pipefail
  SCRIPT_DIR="${REPO1}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home1"
  install_git_hooks >/dev/null 2>&1
)

assert_file_contains "signature still present on re-run" "# oh-my-claude post-merge auto-sync" "${HOOK1}"

# Pre-provenance releases emitted a fixed heredoc hook at the ordinary 755
# mode. Its exact historical digest (never its marker) is migration authority:
# a default update recognizes that it needs refresh, and the publisher replaces
# it with today's 700 template plus a digest receipt.
REPO_LEGACY="${TEST_ROOT}/repo-legacy-hook"
setup_fake_repo "${REPO_LEGACY}"
HOOK_LEGACY="$(hook_path_for_checkout "${REPO_LEGACY}")"
write_head_legacy_hook "${HOOK_LEGACY}"
chmod 755 "${HOOK_LEGACY}"
legacy_refresh_needed="$(
  set -euo pipefail
  SCRIPT_DIR="${REPO_LEGACY}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home-legacy-hook"
  if installed_git_hook_needs_refresh; then
    printf yes
  else
    printf no
  fi
  install_git_hooks >/dev/null 2>&1
)"
assert_eq "legacy pre-provenance hook is admitted for automatic refresh" \
  "yes" "${legacy_refresh_needed}"
assert_eq "legacy hook is migrated to today's exact template" "true" \
  "$(cmp -s "${REPO_LEGACY}/config/post-merge.hook" "${HOOK_LEGACY}" \
    && printf true || printf false)"
assert_eq "migrated hook mode is normalized" "700" \
  "$(stat -c '%a' "${HOOK_LEGACY}" 2>/dev/null \
    || stat -f '%Lp' "${HOOK_LEGACY}" 2>/dev/null)"

# ===========================================================================
# Case 4: the real uninstaller drops only provenance-owned hooks.
# ===========================================================================
printf 'Case 4: uninstall removes signed hook, keeps foreign one:\n'

FAKE_HOME="${TEST_ROOT}/home"
mkdir -p "${FAKE_HOME}/.claude"
CONF="${FAKE_HOME}/.claude/oh-my-claude.conf"

# Signed historical hook — should be removed using its persisted digest even
# though its bytes no longer match today's template.
printf '# simulated historical template generation\n' >> "${HOOK1}"
hook_digest="$(sha256_file "${HOOK1}")"
printf 'repo_path=%s\ngit_post_merge_hook_sha256=%s\n' \
  "${REPO1}" "${hook_digest}" > "${CONF}"
TARGET_HOME="${FAKE_HOME}" bash "${UNINSTALL_SH}" --yes >/dev/null 2>&1

if [[ -f "${HOOK1}" ]]; then
  printf '  FAIL: signed hook was not removed at %s\n' "${HOOK1}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# Foreign hook — repo2 still has it. Invoke the real uninstaller and assert it
# stays in place.
mkdir -p "${FAKE_HOME}/.claude"
printf 'repo_path=%s\n' "${REPO2}" > "${CONF}"
TARGET_HOME="${FAKE_HOME}" bash "${UNINSTALL_SH}" --yes >/dev/null 2>&1

assert_file_exists "foreign hook still present after uninstall clause" "${HOOK2}"
if diff -q "${FOREIGN_FIXTURE}" "${HOOK2}" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: foreign hook body changed by uninstall clause\n' >&2
  diff "${FOREIGN_FIXTURE}" "${HOOK2}" || true
  fail=$((fail + 1))
fi

mkdir -p "${FAKE_HOME}/.claude"
printf 'repo_path=%s\n' "${REPO2B}" > "${CONF}"
TARGET_HOME="${FAKE_HOME}" bash "${UNINSTALL_SH}" --yes >/dev/null 2>&1
assert_file_exists "marker-only foreign hook survives uninstall ownership check" \
  "${HOOK2B}"

# A user may uninstall directly after upgrading from the final pre-provenance
# generation, before running the new installer. Exact historical bytes at its
# emitted executable mode remain removable without a forged conf receipt.
REPO_LEGACY_UNINSTALL="${TEST_ROOT}/repo-legacy-uninstall"
setup_fake_repo "${REPO_LEGACY_UNINSTALL}"
HOOK_LEGACY_UNINSTALL="$(hook_path_for_checkout "${REPO_LEGACY_UNINSTALL}")"
write_head_legacy_hook "${HOOK_LEGACY_UNINSTALL}"
chmod 755 "${HOOK_LEGACY_UNINSTALL}"
mkdir -p "${FAKE_HOME}/.claude"
printf 'repo_path=%s\n' "${REPO_LEGACY_UNINSTALL}" > "${CONF}"
TARGET_HOME="${FAKE_HOME}" bash "${UNINSTALL_SH}" --yes >/dev/null 2>&1
assert_eq "exact pre-provenance hook is removed without digest" "false" \
  "$([[ -e "${HOOK_LEGACY_UNINSTALL}" ]] \
    && printf true || printf false)"

# Worktree repo_path — uninstall should resolve the shared hooks dir too.
mkdir -p "${FAKE_HOME}/.claude"
hook_digest="$(sha256_file "${HOOK1B}")"
printf 'repo_path=%s\ngit_post_merge_hook_sha256=%s\n' \
  "${REPO1B_WT}" "${hook_digest}" > "${CONF}"
TARGET_HOME="${FAKE_HOME}" bash "${UNINSTALL_SH}" --yes >/dev/null 2>&1
if [[ -f "${HOOK1B}" ]]; then
  printf '  FAIL: worktree-sourced signed hook was not removed at %s\n' "${HOOK1B}" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
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
# drift paths (source-generation diff vs manifest diff) without running into the
# "single-line manifest goes empty on grep -v" edge case.
cp "${INSTALL_SH}" "${REPO3}/install.sh"
printf 'placeholder\n' > "${REPO3}/bundle/dot-claude/placeholder.txt"
printf 'second\n' > "${REPO3}/bundle/dot-claude/second.txt"
git -C "${REPO3}" add install.sh bundle/dot-claude
git -C "${REPO3}" commit --quiet -m 'bundle drift fixtures'
repo3_installed_sha="$(git -C "${REPO3}" rev-parse HEAD)"

(
  set -euo pipefail
  SCRIPT_DIR="${REPO3}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home3"
  install_git_hooks >/dev/null 2>&1
)
HOOK3="$(hook_path_for_checkout "${REPO3}")"
assert_file_exists "repo3 hook installed" "${HOOK3}"

# Run the hook with HOME pointed at an empty dir — no manifest present.
empty_home="${TEST_ROOT}/empty_home"
mkdir -p "${empty_home}"
rc=0
(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" >/dev/null 2>&1) || rc=$?
assert_eq "hook exits 0 when no manifest exists" "0" "${rc}"

# Run the hook after planting a manifest and matching installed SHA with no drift —
# it should still exit 0 and print nothing.
mkdir -p "${empty_home}/.claude/quality-pack/state"
printf 'installed_sha=%s\nexclude_ios=off\n' "${repo3_installed_sha}" \
  > "${empty_home}/.claude/oh-my-claude.conf"
(cd "${REPO3}/bundle/dot-claude" && find . -type f ! -name '.DS_Store' 2>/dev/null \
  | sed 's|^\./||' | LC_ALL=C sort) > "${empty_home}/.claude/quality-pack/state/installed-manifest.txt"

rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook exits 0 when manifest matches bundle" "0" "${rc}"
assert_eq "hook emits no warning on no drift" "" "${hook_out}"

# A failed current-manifest build is inconclusive, never proof of no drift.
# The production branch catches find/sort/I/O failures; this denial-only seam
# makes that otherwise host-dependent failure deterministic.
rc=0
hook_out="$(cd "${REPO3}" \
  && HOME="${empty_home}" OMC_TEST_POST_MERGE_MANIFEST_FAILURE=1 \
    bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook remains non-blocking when manifest comparison fails" "0" "${rc}"
if [[ "${hook_out}" == *'Managed source comparison could not be completed'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: manifest comparison failure was silently treated as current\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 6: the hook reports byte and mode drift from the installed commit.
#
# The no-drift case (5b) is useful but a regression that makes the hook
# silently skip ALL drift detection would still pass it. This positive
# case changes a tracked bundle file and asserts the yellow warning line.
# ===========================================================================
printf 'Case 6: hook reports byte/mode drift from installed commit:\n'

# Change bytes without relying on timestamps; the Git comparison also detects
# executable-mode-only drift.
printf 'changed\n' >> "${REPO3}/bundle/dot-claude/placeholder.txt"

rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "hook exits 0 on drift (non-blocking by design)" "0" "${rc}"
if printf '%s' "${hook_out}" \
    | grep -q 'Installer-managed source changes detected after merge'; then
  pass=$((pass + 1))
else
  printf '  FAIL: expected drift banner in hook output, got:\n%s\n' "${hook_out}" >&2
  fail=$((fail + 1))
fi
if printf '%s' "${hook_out}" \
    | grep -q 'Managed source bytes or executable modes differ'; then
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

# Reset bytes to the installed generation before exercising file-set drift.
printf 'placeholder\n' > "${REPO3}/bundle/dot-claude/placeholder.txt"

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
# Case 8: --no-ios persists an exclusion contract used by drift comparison.
# iOS-only source changes must not create permanent false drift, while a
# non-iOS change still must.
# ===========================================================================
printf 'Case 8: persisted no-ios mode filters only iOS agent drift:\n'
mkdir -p "${REPO3}/bundle/dot-claude/agents"
printf 'ios\n' > "${REPO3}/bundle/dot-claude/agents/ios-test.md"
git -C "${REPO3}" add bundle/dot-claude/agents/ios-test.md
git -C "${REPO3}" commit --quiet -m 'iOS drift fixture'
repo3_installed_sha="$(git -C "${REPO3}" rev-parse HEAD)"
printf 'installed_sha=%s\nexclude_ios=off\nexclude_ios=on\n' \
  "${repo3_installed_sha}" > "${empty_home}/.claude/oh-my-claude.conf"
(cd "${REPO3}/bundle/dot-claude" \
  && find . -type f ! -name '.DS_Store' ! -path './agents/ios-*.md' \
    2>/dev/null | sed 's|^\./||' | LC_ALL=C sort) > "${manifest}"
printf 'excluded-ios-drift\n' \
  >> "${REPO3}/bundle/dot-claude/agents/ios-test.md"
rc=0
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || rc=$?
assert_eq "no-ios hook ignores excluded iOS-only drift" "0" "${rc}"
assert_eq "no-ios hook is silent for excluded iOS-only drift" "" "${hook_out}"

printf 'non-ios-change\n' >> "${REPO3}/bundle/dot-claude/second.txt"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: no-ios hook ignored non-iOS drift\n' >&2
  fail=$((fail + 1))
fi

# Last-valid semantics: a later explicit off overrides an earlier on, while a
# malformed later row cannot erase the last valid off. With iOS included in
# the manifest baseline, its content change must therefore be reported.
printf 'installed_sha=%s\nexclude_ios=on\nexclude_ios=off\nexclude_ios=maybe\n' \
  "${repo3_installed_sha}" > "${empty_home}/.claude/oh-my-claude.conf"
printf 'second\n' > "${REPO3}/bundle/dot-claude/second.txt"
(cd "${REPO3}/bundle/dot-claude" \
  && find . -type f ! -name '.DS_Store' 2>/dev/null \
    | sed 's|^\./||' | LC_ALL=C sort) > "${manifest}"
printf 'ios-changed\n' >> "${REPO3}/bundle/dot-claude/agents/ios-test.md"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: last-valid exclude_ios=off did not restore iOS drift detection\n' >&2
  fail=$((fail + 1))
fi

# Mode-only drift is part of the Git generation comparison. Restore bytes and
# flip one tracked file's executable bit without changing its mtime/content.
# The hook must explicitly override a checkout-level core.fileMode=false.
printf 'ios\n' > "${REPO3}/bundle/dot-claude/agents/ios-test.md"
git -C "${REPO3}" config core.fileMode false
chmod 755 "${REPO3}/bundle/dot-claude/placeholder.txt"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: chmod-only bundle drift was not detected with core.fileMode=false\n' >&2
  fail=$((fail + 1))
fi

# Non-bundle installer inputs also materialize installed state. Restore the
# bundle mode, then prove settings, user-template, and installed-hook source
# generations independently wake the post-merge handoff.
chmod 644 "${REPO3}/bundle/dot-claude/placeholder.txt"
printf '%s\n' '{"managed":"settings-change"}' \
  > "${REPO3}/config/settings.patch.json"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: settings.patch.json drift was not detected\n' >&2
  fail=$((fail + 1))
fi
git -C "${REPO3}" show \
  "${repo3_installed_sha}:config/settings.patch.json" \
  > "${REPO3}/config/settings.patch.json"

printf 'template drift\n' \
  >> "${REPO3}/bundle/omc-user-template/overrides.md"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: omc-user template drift was not detected\n' >&2
  fail=$((fail + 1))
fi
git -C "${REPO3}" show \
  "${repo3_installed_sha}:bundle/omc-user-template/overrides.md" \
  > "${REPO3}/bundle/omc-user-template/overrides.md"

printf '\n# hook source drift\n' >> "${REPO3}/config/post-merge.hook"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: installed post-merge hook source drift was not detected\n' >&2
  fail=$((fail + 1))
fi
git -C "${REPO3}" show \
  "${repo3_installed_sha}:config/post-merge.hook" \
  > "${REPO3}/config/post-merge.hook"

# The installer is itself a managed input: changes to migration, merge, or
# recovery behavior require reinstall even when every bundle byte is stable.
printf '\n# installer-only drift\n' >> "${REPO3}/install.sh"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: install.sh-only drift was not detected\n' >&2
  fail=$((fail + 1))
fi
git -C "${REPO3}" show \
  "${repo3_installed_sha}:install.sh" > "${REPO3}/install.sh"

# A stale or damaged installed_sha must not be interpreted as proof that
# non-bundle managed inputs are current. The hook remains non-blocking but
# emits an explicit reinstall handoff.
cp "${empty_home}/.claude/oh-my-claude.conf" \
  "${empty_home}/.claude/oh-my-claude.conf.before-unresolved"
printf 'installed_sha=deadbeef\nexclude_ios=off\nghostty_installed=off\n' \
  > "${empty_home}/.claude/oh-my-claude.conf"
rm -f "${REPO3}/.git/ORIG_HEAD"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Managed source comparison could not be completed'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: unresolved source baseline was silently treated as current\n' >&2
  fail=$((fail + 1))
fi
mv "${empty_home}/.claude/oh-my-claude.conf.before-unresolved" \
  "${empty_home}/.claude/oh-my-claude.conf"

# Ghostty sources follow the installer's auto-detect policy: irrelevant when
# the user has no Ghostty config directory, relevant once that destination
# exists. A persisted install receipt then wins over changing host detection.
printf 'ghostty source drift\n' >> "${REPO3}/config/ghostty/themes/fixture"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
assert_eq "hook ignores Ghostty-only drift when Ghostty is not detected" \
  "" "${hook_out}"
mkdir -p "${empty_home}/.config/ghostty"
hook_out="$(cd "${REPO3}" && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: Ghostty source drift was not detected after auto-detection\n' >&2
  fail=$((fail + 1))
fi
printf '\nghostty_installed=on\nghostty_installed=off\nghostty_installed=invalid\n' \
  >> "${empty_home}/.claude/oh-my-claude.conf"
hook_out="$(cd "${REPO3}" \
  && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
assert_eq "explicit Ghostty opt-out suppresses drift despite detected directory" \
  "" "${hook_out}"
rm -rf "${empty_home}/.config/ghostty"
printf '\nghostty_installed=on\n' \
  >> "${empty_home}/.claude/oh-my-claude.conf"
hook_out="$(cd "${REPO3}" \
  && HOME="${empty_home}" bash "${HOOK3}" 2>&1)" || true
if [[ "${hook_out}" == *'Installer-managed source changes detected after merge'* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: persisted Ghostty install receipt did not retain drift detection\n' >&2
  fail=$((fail + 1))
fi

# ===========================================================================
# Case 9: remediation commands shell-quote unusual checkout paths.
# ===========================================================================
printf 'Case 9: remediation command quotes checkout paths safely:\n'

REPO4="${TEST_ROOT}/repo quote's space"
setup_fake_repo "${REPO4}"
cp "${INSTALL_SH}" "${REPO4}/install.sh"
printf 'quoted-path baseline\n' > "${REPO4}/bundle/dot-claude/quoted.txt"
git -C "${REPO4}" add install.sh bundle/dot-claude/quoted.txt
git -C "${REPO4}" commit --quiet -m 'quoted path fixture'
repo4_installed_sha="$(git -C "${REPO4}" rev-parse HEAD)"
(
  set -euo pipefail
  SCRIPT_DIR="${REPO4}"
  eval "${INSTALL_HOOKS_SNIPPET}"
  init_install_hook_test "${TEST_ROOT}/home4"
  install_git_hooks >/dev/null 2>&1
)
HOOK4="$(hook_path_for_checkout "${REPO4}")"
home4="${TEST_ROOT}/home4"
mkdir -p "${home4}/.claude/quality-pack/state"
printf 'installed_sha=%s\nexclude_ios=off\n' "${repo4_installed_sha}" \
  > "${home4}/.claude/oh-my-claude.conf"
(cd "${REPO4}/bundle/dot-claude" \
  && find . -type f ! -name '.DS_Store' 2>/dev/null \
    | sed 's|^\./||' | LC_ALL=C sort) \
  > "${home4}/.claude/quality-pack/state/installed-manifest.txt"
printf 'drift\n' >> "${REPO4}/bundle/dot-claude/quoted.txt"
hook_out="$(cd "${REPO4}" && HOME="${home4}" bash "${HOOK4}" 2>&1)" \
  || true
printf -v expected_install_command '    bash %q' "${REPO4}/install.sh"
if [[ "${hook_out}" == *"${expected_install_command}"* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: remediation command was not safely quoted\n' >&2
  printf '    expected substring: %s\n    output: %s\n' \
    "${expected_install_command}" "${hook_out}" >&2
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
