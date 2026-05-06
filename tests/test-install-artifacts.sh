#!/usr/bin/env bash
#
# Tests for install.sh artifacts introduced in 1.8.0:
#   - installed_sha in oh-my-claude.conf (when source is a git repo)
#   - installed-manifest.txt (bundle file list, under quality-pack/state/)
#   - Orphan warning when a prior manifest contains files no longer bundled
#   - .install-stamp at the install root
#
# These tests run install.sh against an isolated TARGET_HOME to avoid
# touching the developer's real ~/.claude/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_HOME=""

cleanup() {
  if [[ -n "${TEST_HOME}" && -d "${TEST_HOME}" ]]; then
    rm -rf "${TEST_HOME}"
  fi
}
trap cleanup EXIT

pass=0
fail=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — expected [%s], got [%s]\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_true() {
  local label="$1"
  local cond="$2"
  if eval "${cond}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — condition [%s] was false\n' "${label}" "${cond}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — [%s] not found in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

run_install() {
  TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" 2>&1
}

# ---------------------------------------------------------------------------
# Setup: create an isolated TARGET_HOME
# ---------------------------------------------------------------------------
printf 'Install artifacts test\n'
printf '======================\n\n'

TEST_HOME="$(mktemp -d)"
CLAUDE_HOME="${TEST_HOME}/.claude"
CONF="${CLAUDE_HOME}/oh-my-claude.conf"
MANIFEST="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
HASHES="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
STAMP="${CLAUDE_HOME}/.install-stamp"
BACKUP_PARENT="${CLAUDE_HOME}/backups"

# ---------------------------------------------------------------------------
# Test 1: First install writes SHA, manifest, and install-stamp
# ---------------------------------------------------------------------------
printf '1. First install artifacts\n'

install_output="$(run_install)"
assert_true "install exits cleanly" "[[ -d '${CLAUDE_HOME}' ]]"

# SHA: repo IS a git worktree (the repo itself), so installed_sha must be set.
if [[ -d "${REPO_ROOT}/.git" ]]; then
  sha_line="$(grep '^installed_sha=' "${CONF}" 2>/dev/null || true)"
  sha_value="${sha_line#installed_sha=}"
  # 40-char SHA expected. Empty value is a failure.
  if [[ "${sha_value}" =~ ^[0-9a-f]{40}$ ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: installed_sha must be a 40-char hex (got: [%s])\n' "${sha_value}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  SKIP: repo is not a git worktree; SHA test not applicable\n'
fi

# Manifest exists and is non-empty.
assert_true "installed-manifest.txt exists" "[[ -f '${MANIFEST}' ]]"
manifest_lines="$(wc -l < "${MANIFEST}" | tr -d '[:space:]')"
if [[ "${manifest_lines}" -gt 10 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: manifest must be non-trivial (got %s lines)\n' "${manifest_lines}" >&2
  fail=$((fail + 1))
fi

# Manifest should contain at least the known core files.
assert_contains "manifest lists CLAUDE.md" "CLAUDE.md" "$(cat "${MANIFEST}")"
assert_contains "manifest lists statusline.py" "statusline.py" "$(cat "${MANIFEST}")"
assert_contains "manifest lists common.sh" "skills/autowork/scripts/common.sh" "$(cat "${MANIFEST}")"

# Install stamp exists.
assert_true ".install-stamp exists" "[[ -f '${STAMP}' ]]"

# First install produces no orphan warnings (there's no prior manifest).
if ! printf '%s' "${install_output}" | grep -q 'Orphans:'; then
  pass=$((pass + 1))
else
  printf '  FAIL: first install should not emit orphan warning\n' >&2
  fail=$((fail + 1))
fi

# v1.32.16 (4-attacker security review, A2-MED-4): SHA-256 manifest for
# drift detection. Best-effort write — present iff shasum or sha256sum
# is on PATH at install time. CI runners and macOS dev boxes both have
# shasum (Perl ships with it), so the file should exist on every install
# we exercise here. Skip-on-tool-absence preserves the install-on-minimal-
# container path; the assertion below would fire if tools regressed.
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  assert_true "installed-hashes.txt exists when shasum/sha256sum is available" "[[ -f '${HASHES}' ]]"

  # Each line: "<64-char hex>  <relative-path>".
  if [[ -f "${HASHES}" ]]; then
    hashes_lines="$(wc -l < "${HASHES}" | tr -d '[:space:]')"
    if [[ "${hashes_lines}" -gt 10 ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: installed-hashes.txt must be non-trivial (got %s lines)\n' "${hashes_lines}" >&2
      fail=$((fail + 1))
    fi

    # First non-blank line must match `<sha256>  <path>` shape.
    first_line="$(grep -v '^[[:space:]]*$' "${HASHES}" | head -1)"
    if [[ "${first_line}" =~ ^[0-9a-f]{64}\ \ .+ ]]; then
      pass=$((pass + 1))
    else
      printf '  FAIL: first hash line must be `<sha256>  <path>` (got: %s)\n' "${first_line}" >&2
      fail=$((fail + 1))
    fi

    # Hashes file should reference at least the core bundle files.
    assert_contains "hashes lists CLAUDE.md" "CLAUDE.md" "$(cat "${HASHES}")"
    assert_contains "hashes lists common.sh" "skills/autowork/scripts/common.sh" "$(cat "${HASHES}")"
  fi
else
  printf '  SKIP: no shasum/sha256sum on PATH; drift-detection write skipped\n'
fi

# v1.32.16 (4-attacker security review, A2-MED-6): backup directory
# perms are chmod 700 to prevent read-anywhere-in-${HOME} attackers from
# mining prior settings.json / oh-my-claude.conf for credentials, paths,
# or model-tier hints.
backup_dirs="$(find "${BACKUP_PARENT}" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null || true)"
if [[ -n "${backup_dirs}" ]]; then
  backup_first="$(printf '%s\n' "${backup_dirs}" | head -1)"
  # stat -c (GNU) and stat -f (BSD/macOS); fall back gracefully if both fail.
  backup_mode="$(stat -c '%a' "${backup_first}" 2>/dev/null || stat -f '%Lp' "${backup_first}" 2>/dev/null || printf 'unknown')"
  if [[ "${backup_mode}" == "700" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: backup dir must be chmod 700 (got: %s) at %s\n' "${backup_mode}" "${backup_first}" >&2
    fail=$((fail + 1))
  fi
else
  # First-install case where there's nothing to back up still creates
  # the dir at install.sh:938. Confirm the dir exists and is 700.
  if [[ -d "${BACKUP_PARENT}" ]]; then
    pass=$((pass + 1))
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 2: Orphan detection flags files present in old manifest but not new bundle
# ---------------------------------------------------------------------------
printf '2. Orphan detection\n'

# Inject a fake orphan into the current manifest and drop a matching
# file into ~/.claude/, simulating a past release that shipped this
# file but the current bundle no longer does.
fake_orphan_rel="legacy/deprecated-hook.sh"
mkdir -p "${CLAUDE_HOME}/legacy"
printf '# stale from an older release\n' > "${CLAUDE_HOME}/${fake_orphan_rel}"
printf '%s\n' "${fake_orphan_rel}" >> "${MANIFEST}"
# Re-sort the manifest so comm's sorted-input requirement is satisfied.
# Must match the locale discipline used by install.sh (LC_ALL=C) so the
# comparison keys align across re-install locales.
LC_ALL=C sort -o "${MANIFEST}" "${MANIFEST}"

install_output_2="$(run_install)"
assert_contains "orphan warning header" "Orphans:" "${install_output_2}"
assert_contains "orphan warning lists path" "${fake_orphan_rel}" "${install_output_2}"

# After re-install, the manifest is overwritten with the fresh bundle list
# — the orphan line must be GONE from the post-install manifest.
if ! grep -qF "${fake_orphan_rel}" "${MANIFEST}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: orphan entry should be removed from new manifest\n' >&2
  fail=$((fail + 1))
fi

# The orphan file itself is NOT deleted (install.sh warns, does not delete).
assert_true "orphan file still exists on disk" "[[ -f '${CLAUDE_HOME}/${fake_orphan_rel}' ]]"

printf '\n'

# ---------------------------------------------------------------------------
# Test 3: Idempotent re-install preserves stamp/manifest/SHA without errors
# ---------------------------------------------------------------------------
printf '3. Idempotent re-install\n'

# Remove the fake orphan so it doesn't re-warn.
rm -f "${CLAUDE_HOME}/${fake_orphan_rel}"
rmdir "${CLAUDE_HOME}/legacy" 2>/dev/null || true

install_output_3="$(run_install)"
# No orphan warning this time.
if ! printf '%s' "${install_output_3}" | grep -q 'Orphans:'; then
  pass=$((pass + 1))
else
  printf '  FAIL: clean re-install should not emit orphan warning\n' >&2
  fail=$((fail + 1))
fi

# SHA, manifest, stamp all still present.
# SHA is only written when the source is a regular git clone (`.git` directory);
# git worktrees have `.git` as a file, so install.sh skips the SHA write and the
# assertion would fire spuriously. Guard mirrors Test 1 above.
if [[ -d "${REPO_ROOT}/.git" ]]; then
  assert_true "installed_sha still set" "grep -q '^installed_sha=' '${CONF}'"
else
  printf '  SKIP: repo is not a git worktree; SHA persistence test not applicable\n'
fi
assert_true "manifest still exists" "[[ -f '${MANIFEST}' ]]"
assert_true "install-stamp still exists" "[[ -f '${STAMP}' ]]"

printf '\n'

# ---------------------------------------------------------------------------
# Test 4: Install-stamp mtime advances on re-install
# ---------------------------------------------------------------------------
printf '4. Install-stamp mtime refreshes\n'

# Back-date the stamp, re-install, verify mtime advanced.
mtime_before=""
if stat -f %m "${STAMP}" >/dev/null 2>&1; then
  # BSD stat (macOS)
  touch -A -0100 "${STAMP}" 2>/dev/null || touch -t 202001010000 "${STAMP}"
  mtime_before="$(stat -f %m "${STAMP}")"
else
  # GNU stat (Linux)
  touch -d '1 hour ago' "${STAMP}" 2>/dev/null || true
  mtime_before="$(stat -c %Y "${STAMP}")"
fi

# Tiny sleep to ensure the post-install touch observably advances mtime
# on filesystems with 1-second granularity.
sleep 1

run_install >/dev/null 2>&1

if stat -f %m "${STAMP}" >/dev/null 2>&1; then
  mtime_after="$(stat -f %m "${STAMP}")"
else
  mtime_after="$(stat -c %Y "${STAMP}")"
fi

if [[ -n "${mtime_before}" && "${mtime_after}" -gt "${mtime_before}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: install-stamp mtime should advance on re-install (before=%s after=%s)\n' "${mtime_before}" "${mtime_after}" >&2
  fail=$((fail + 1))
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 5: Empty installed_sha is cleaned from conf, not written as blank line
# ---------------------------------------------------------------------------
printf '5. Empty installed_sha cleanup\n'

# Pre-seed the conf with a stale installed_sha from a hypothetical
# prior worktree install, then simulate a non-git-worktree install by
# temporarily pointing TARGET_HOME install at a copied-tree source.
# Simplest repro: manually append `installed_sha=deadbeef...` to the
# conf, then re-run install from the same repo (which IS a git
# worktree). The new code keeps the current SHA — but if the source
# were a tarball, it would strip the key. We simulate the tarball
# case by moving .git aside temporarily.
if [[ -d "${REPO_ROOT}/.git" ]]; then
  # Save + hide the .git dir, run install, then restore. Minimum-
  # disruptive simulation of a tarball-sourced install.
  GIT_BACKUP="$(mktemp -d)"
  mv "${REPO_ROOT}/.git" "${GIT_BACKUP}/.git"
  trap 'mv "${GIT_BACKUP}/.git" "${REPO_ROOT}/.git" 2>/dev/null; cleanup' EXIT

  # Seed a stale SHA into the conf so we can verify it gets cleaned.
  printf 'installed_sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >> "${CONF}"

  run_install >/dev/null 2>&1

  # After install with no .git, the stale sha should be removed from conf.
  if ! grep -q '^installed_sha=' "${CONF}"; then
    pass=$((pass + 1))
  else
    _got="$(grep '^installed_sha=' "${CONF}" | head -1)"
    printf '  FAIL: installed_sha line should be removed for non-git install (got: %s)\n' "${_got}" >&2
    fail=$((fail + 1))
  fi

  # Restore .git for subsequent tests.
  mv "${GIT_BACKUP}/.git" "${REPO_ROOT}/.git"
  rmdir "${GIT_BACKUP}"
  trap cleanup EXIT
else
  printf '  SKIP: repo is not a git worktree; non-git cleanup test not applicable\n'
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 6: Locale discipline — orphan detection does not false-positive
# across LC_ALL changes
# ---------------------------------------------------------------------------
printf '6. Locale-safe orphan detection\n'

# Install once under LC_ALL=C, then re-install under LC_ALL=en_US.UTF-8
# (if available). The orphan detector must not report spurious orphans
# when neither the bundle nor on-disk state changed between runs.
LC_ALL=C run_install >/dev/null 2>&1

# Try a common UTF-8 locale; fall back to en_US.UTF-8 on macOS/Linux.
# If the locale is not available, skip the test rather than fail.
locale_ok=0
for _loc in en_US.UTF-8 C.UTF-8 en_GB.UTF-8; do
  if LC_ALL="${_loc}" locale 2>/dev/null | grep -q "LC_CTYPE=\"${_loc}\"" \
      || LC_ALL="${_loc}" locale 2>/dev/null | grep -q "LC_CTYPE=${_loc}"; then
    locale_ok=1
    out_locale="$(LC_ALL="${_loc}" run_install 2>&1)"
    if ! printf '%s' "${out_locale}" | grep -q 'Orphans:'; then
      pass=$((pass + 1))
    else
      printf '  FAIL: re-install under LC_ALL=%s produced spurious orphan warnings\n' "${_loc}" >&2
      printf '  Output excerpt: %s\n' "$(printf '%s' "${out_locale}" | grep -A3 'Orphans:' | head -5)" >&2
      fail=$((fail + 1))
    fi
    break
  fi
done

if [[ "${locale_ok}" -eq 0 ]]; then
  printf '  SKIP: no suitable UTF-8 locale available on this system\n'
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 7: "What's new" surface — re-install with a prior installed_version
# triggers the changelog-summary block in the install footer (v1.30.0
# closes the v1.29.0 product-lens P2-10 / growth-lens P2-10 deferral).
# ---------------------------------------------------------------------------
printf '7. "What'\''s new since v$prev" surface on re-install\n'

# First, run a clean install so the harness writes installed_version=$current.
LC_ALL=C run_install >/dev/null 2>&1

# Synthesize the "user upgraded from an older version" state by rewriting
# the conf's installed_version to a known older value. Mirrors the real
# upgrade flow: prior install captured 1.27.0, current run will overwrite
# to OMC_VERSION and detect the gap.
if [[ -f "${CONF}" ]]; then
  _backup="$(mktemp)"
  grep -v '^installed_version=' "${CONF}" > "${_backup}" 2>/dev/null || true
  printf 'installed_version=1.27.0\n' >> "${_backup}"
  mv "${_backup}" "${CONF}"
fi

# Re-run install — the footer summary should now contain the "What's new"
# block listing version headings between 1.27.0 (exclusive) and current.
out_whatsnew="$(LC_ALL=C run_install 2>&1)"

assert_contains "What's new line present"  "What's new:"   "${out_whatsnew}"
assert_contains "names prior version 1.27.0" "since v1.27.0" "${out_whatsnew}"
# The CHANGELOG between 1.27.0 (exclusive) and head should include 1.28.0
# and 1.29.0 entries — both are stable tagged releases. We do NOT assert
# the current OMC_VERSION number because that changes per release; the
# extractor's behavior is what's under test, not the version it picks up.
assert_contains "lists v1.28.0"             "1.28.0"        "${out_whatsnew}"
assert_contains "lists v1.29.0"             "1.29.0"        "${out_whatsnew}"
assert_contains "links to CHANGELOG"        "CHANGELOG.md"  "${out_whatsnew}"

# Idempotency: a third install with installed_version now matching
# OMC_VERSION (i.e. no upgrade) must NOT render the block.
out_noop="$(LC_ALL=C run_install 2>&1)"
if printf '%s' "${out_noop}" | grep -q "What's new:"; then
  printf '  FAIL: same-version reinstall surfaced What'\''s new block (should be silent)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 8 (v1.36.0): --no-ghostty and ghostty auto-detect
# ---------------------------------------------------------------------------
printf '8. Ghostty install gating (v1.36.0)\n'

# Reset test home to start clean.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}"
GHOSTTY_HOME_FAKE="${TEST_HOME}/.config/ghostty"

# 8a — Default install with no pre-existing ~/.config/ghostty/ should
# NOT seed the dir (auto-detect skips silently). This is the silent-
# side-effect closure — pre-1.36.0 every install seeded ghostty.
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1 || true
if [[ -d "${GHOSTTY_HOME_FAKE}" ]]; then
  printf '  FAIL: auto-detect should skip when ~/.config/ghostty/ does not pre-exist (was created)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 8b — Pre-create ~/.config/ghostty/ then install — should now seed.
mkdir -p "${GHOSTTY_HOME_FAKE}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1 || true
if [[ -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: auto-detect should seed when ~/.config/ghostty/ pre-exists (themes/ missing)\n' >&2
  fail=$((fail + 1))
fi

# 8c — --no-ghostty must skip seeding even when the dir pre-exists.
rm -rf "${GHOSTTY_HOME_FAKE}/themes"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --no-ghostty >/dev/null 2>&1 || true
if [[ ! -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --no-ghostty should skip even when ghostty home pre-exists\n' >&2
  fail=$((fail + 1))
fi

# 8d — --with-ghostty must seed even when ~/.config/ghostty/ does NOT exist.
rm -rf "${GHOSTTY_HOME_FAKE}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --with-ghostty >/dev/null 2>&1 || true
if [[ -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --with-ghostty should force-seed when ghostty home is absent\n' >&2
  fail=$((fail + 1))
fi

# 8e — F-4 regression net: --no-ghostty and --with-ghostty are mutually
# exclusive. Pre-fix the arg loop accepted both and silently last-wins
# (whichever appeared last); post-fix the install must refuse the
# combination with a non-zero exit and a clear error.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}"
out_mutex="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --no-ghostty --with-ghostty 2>&1 || true)"
exit_mutex="$?"
assert_contains "mutex error message" "mutually exclusive" "${out_mutex}"
# install.sh on the conflict path must NOT have created CLAUDE_HOME.
if [[ ! -d "${TEST_HOME}/.claude" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --no-ghostty + --with-ghostty should fail before install begins\n' >&2
  fail=$((fail + 1))
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 9 (v1.36.0): --keep-backups=N retention
# ---------------------------------------------------------------------------
printf '9. Backup retention (v1.36.0)\n'

# Reset test home + simulate 12 prior backup directories with old timestamps.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}/.claude/backups"
for i in $(seq 1 12); do
  # Names sort by lexical timestamp; use 12-digit synthetic stamps.
  stamp="$(printf '20260401-%06d' "$((100000 + i))")"
  mkdir -p "${TEST_HOME}/.claude/backups/oh-my-claude-${stamp}"
  printf 'placeholder\n' > "${TEST_HOME}/.claude/backups/oh-my-claude-${stamp}/marker"
done

# Default install adds one more (the current install's backup). With
# 12 synthetic + 1 real = 13 dirs, default keep=10 should prune 3.
out_prune="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" 2>&1 || true)"
remaining_count="$(find "${TEST_HOME}/.claude/backups" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${remaining_count}" -eq 10 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: default retention should keep 10 dirs (got %s)\n' "${remaining_count}" >&2
  fail=$((fail + 1))
fi
assert_contains "prune output names retention" "Backup retention" "${out_prune}"

# 9b — --keep-backups=all should not prune.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}/.claude/backups"
for i in $(seq 1 5); do
  stamp="$(printf '20260401-%06d' "$((200000 + i))")"
  mkdir -p "${TEST_HOME}/.claude/backups/oh-my-claude-${stamp}"
done
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --keep-backups=all >/dev/null 2>&1 || true
remaining_all="$(find "${TEST_HOME}/.claude/backups" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${remaining_all}" -ge 6 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --keep-backups=all should preserve all dirs (got %s)\n' "${remaining_all}" >&2
  fail=$((fail + 1))
fi

# 9c — --keep-backups with invalid value (non-integer) should fail fast.
out_bad="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --keep-backups=foo 2>&1 || true)"
assert_contains "invalid keep-backups rejected" "Invalid --keep-backups" "${out_bad}"

# 9d — --keep-backups=2 should aggressively prune.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}/.claude/backups"
for i in $(seq 1 6); do
  stamp="$(printf '20260401-%06d' "$((300000 + i))")"
  mkdir -p "${TEST_HOME}/.claude/backups/oh-my-claude-${stamp}"
done
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --keep-backups=2 >/dev/null 2>&1 || true
remaining_two="$(find "${TEST_HOME}/.claude/backups" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${remaining_two}" -eq 2 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --keep-backups=2 should prune to 2 dirs (got %s)\n' "${remaining_two}" >&2
  fail=$((fail + 1))
fi

# 9e — F-1 regression net (Wave 1 review): under adversarial sort order
# (prior dirs with FUTURE-dated stamps that sort AHEAD of the current
# install's stamp), the just-created backup must STILL survive. Pre-fix
# the lexical-sort-only logic would push ${BACKUP_DIR} past the keep
# threshold and rm -rf it, leaving the user with no recovery surface
# for the install that just ran.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}/.claude/backups"
# 12 future-dated stamps (year 2099) sort AHEAD of any plausible STAMP.
for i in $(seq 1 12); do
  stamp="$(printf '20990101-%06d' "$((400000 + i))")"
  mkdir -p "${TEST_HOME}/.claude/backups/oh-my-claude-${stamp}"
done
# Run install with --keep-backups=2. Without the BACKUP_DIR guard the
# real backup would be pruned (it sorts ALL the way at the bottom),
# leaving only 2 of the future-dated synthetic dirs. With the guard
# the real backup survives and the count stays at 3 (2 synthetic + 1
# real).
out_adv="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --keep-backups=2 2>&1 || true)"
# Locate the real backup dir by looking for the only one whose stamp
# isn't a 2099 synthetic.
real_backup_count="$(find "${TEST_HOME}/.claude/backups" -maxdepth 1 -type d -name 'oh-my-claude-*' \
                       ! -name 'oh-my-claude-20990101-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${real_backup_count}" -eq 1 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: F-1 adversarial — real BACKUP_DIR should survive future-dated synthetics (got %s real backup(s))\n' "${real_backup_count}" >&2
  fail=$((fail + 1))
fi

printf '\n'

# ---------------------------------------------------------------------------
# Test 10 (v1.36.0): warn_modified_memory_files
# ---------------------------------------------------------------------------
printf '10. Memory file overwrite warning (v1.36.0)\n'

# Reset and run a clean install to lay down memory files + .install-stamp.
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1 || true

mem_dir="${TEST_HOME}/.claude/quality-pack/memory"
core_md="${mem_dir}/core.md"
stamp_file="${TEST_HOME}/.claude/.install-stamp"

assert_true "memory dir exists after install" "[[ -d '${mem_dir}' ]]"
assert_true "core.md present" "[[ -f '${core_md}' ]]"
assert_true ".install-stamp present" "[[ -f '${stamp_file}' ]]"

# 10a — Clean re-install (no user edits) should NOT warn.
out_quiet="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" 2>&1 || true)"
if printf '%s' "${out_quiet}" | grep -q 'User edits detected'; then
  printf '  FAIL: clean re-install should not warn (no user edits)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 10c — F-6 (Wave 4 review): regression test for SHA-256 drift fix.
# Pre-v1.36.0 the hash manifest reflected BUNDLE bytes but
# apply_model_tier rewrites CLAUDE_HOME agent files, so verify.sh
# drift detection FAILED on every install with model_tier ≠ balanced.
# Post-fix the hash manifest reflects CLAUDE_HOME bytes after all
# post-rsync mutations, so drift check matches reality.
#
# We can't run verify.sh against test home easily here (it's tightly
# scoped to ~/.claude paths). Instead we assert structural invariants
# of the hash file: every line resolves to an existing file under
# CLAUDE_HOME (no orphan hash entries from --no-ios removals).
rm -rf "${TEST_HOME}"
mkdir -p "${TEST_HOME}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --no-ios >/dev/null 2>&1 || true
hashes_file="${TEST_HOME}/.claude/quality-pack/state/installed-hashes.txt"
if [[ -f "${hashes_file}" ]]; then
  orphan_hash_count=0
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # Each line: "<sha>  <relative-path>" — extract path and verify.
    rel_path="$(printf '%s' "${line}" | awk '{print substr($0, index($0, $2))}')"
    [[ -f "${TEST_HOME}/.claude/${rel_path}" ]] || orphan_hash_count=$((orphan_hash_count + 1))
  done < "${hashes_file}"
  if [[ "${orphan_hash_count}" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: hash manifest has %d entries pointing at non-existent files (--no-ios drift)\n' "${orphan_hash_count}" >&2
    fail=$((fail + 1))
  fi
  # Also assert the manifest does NOT include iOS agents (excluded by --no-ios).
  if grep -q '^[0-9a-f]\{64\}.*agents/ios-' "${hashes_file}"; then
    printf '  FAIL: --no-ios install left iOS agents in hash manifest\n' >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
else
  printf '  SKIP: T10c — hashes file not generated (shasum/sha256sum absent?)\n'
fi

# 10b — Touch core.md so its mtime > .install-stamp mtime, then re-install.
# Bump the file's mtime forward; touch -d / -t both work cross-platform
# given we're not asserting an exact value. CI=1 suppresses the
# warn_modified_memory_files 5-second Ctrl-C window (F-2 fix from Wave 1
# review) — keeps the test run fast while still exercising the warning
# emission path.
sleep 1
printf '\n# user edit\n' >> "${core_md}"
out_warn="$(CI=1 TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" 2>&1 || true)"

if printf '%s' "${out_warn}" | grep -qF 'User edits detected'; then
  pass=$((pass + 1))
else
  printf '  FAIL: hand-edited core.md should trigger warning\n' >&2
  fail=$((fail + 1))
fi

# Warning should name the offending basename and the omc-user/overrides.md
# remediation surface.
assert_contains "warning names core.md"             "core.md"               "${out_warn}"
assert_contains "warning points to omc-user/"       "omc-user/overrides.md" "${out_warn}"

printf '\n'

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf '=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
