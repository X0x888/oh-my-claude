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

repo_is_git_checkout() {
  local repo_root="$1"
  git -C "${repo_root}" rev-parse --show-toplevel >/dev/null 2>&1
}

run_install_from() {
  # v1.47 CI diagnosability: callers capture via `$(run_install)`, so when
  # install.sh dies under `set -e` the error output used to die inside the
  # caller's dead substitution — the 17-day undiagnosable ubuntu-CI sterile
  # failure hid exactly here. On failure, the tail of install.sh's output
  # now also goes to STDERR (outside the substitution), where the
  # run-sterile failing-output capture can see it.
  # v1.47 CI diagnosability, round 2: the runner-only failure HEALS itself
  # (a traced RERUN after the failure succeeded end-to-end), so post-hoc
  # tracing cannot catch it — the FAILING attempt itself must be traced.
  # BASH_XTRACEFD (bash >=4.1: the runner; macOS 3.2 skips, keeping local
  # runs byte-identical) routes the xtrace to a side file so the captured
  # stdout the assertions grep stays clean. On failure, the tail of THIS
  # attempt's trace names the dying line directly.
  local repo_root="$1" _ri_rc=0 _ri_out="" _ri_trace="" _ri_traced=0
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )); then
    _ri_traced=1
    _ri_trace="${TEST_HOME}/.install-trace"
    local _ri_fd
    exec {_ri_fd}>"${_ri_trace}"
    _ri_out="$(TARGET_HOME="${TEST_HOME}" BASH_XTRACEFD="${_ri_fd}" bash -x "${repo_root}/install.sh" 2>&1)" || _ri_rc=$?
    exec {_ri_fd}>&-
  else
    _ri_out="$(TARGET_HOME="${TEST_HOME}" bash "${repo_root}/install.sh" 2>&1)" || _ri_rc=$?
  fi
  printf '%s' "${_ri_out}"
  if [[ "${_ri_rc}" -ne 0 ]]; then
    {
      printf 'run_install: install.sh exited rc=%s — last 25 lines of its output:\n' "${_ri_rc}"
      printf '%s\n' "${_ri_out}" | tail -25 | sed 's/^/    /'
      if [[ "${_ri_traced}" -eq 1 ]]; then
        printf 'run_install: last 60 trace lines of the FAILING attempt:\n'
        tail -60 "${_ri_trace}" 2>/dev/null | sed 's/^/    x /'
      fi
    } >&2
    return "${_ri_rc}"
  fi
}

run_install() {
  run_install_from "${REPO_ROOT}"
}

run_install_state_report_from_home() {
  local report_home="$1"
  shift
  TARGET_HOME="${report_home}" bash "${REPO_ROOT}/tools/install-state-report.sh" "$@"
}

# ---------------------------------------------------------------------------
# Setup: create an isolated TARGET_HOME
# ---------------------------------------------------------------------------
printf 'Install artifacts test\n'
printf '======================\n\n'

# v1.47 CI diagnosability fingerprint: this test installs FROM the live
# repo tree, so pollution left by earlier CI-job steps changes install.sh
# behavior between section 1 and section 2 in ways no clean local repro
# can reproduce. One line of env truth up front.
_fp_dirty="$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
printf 'env fingerprint: repo-dirty-paths=%s HOME=%s\n' "${_fp_dirty:-?}" "${HOME:-unset}"
if [[ "${_fp_dirty:-0}" != "0" ]]; then
  git -C "${REPO_ROOT}" status --porcelain 2>/dev/null | head -8 | sed 's/^/  dirty: /'
fi
printf '\n'

TEST_HOME="$(mktemp -d)"
CLAUDE_HOME="${TEST_HOME}/.claude"
CONF="${CLAUDE_HOME}/oh-my-claude.conf"
MANIFEST="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
HASHES="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
STAMP="${CLAUDE_HOME}/.install-stamp"
BACKUP_PARENT="${CLAUDE_HOME}/backups"
INSTALL_STATE_REPORT="${REPO_ROOT}/tools/install-state-report.sh"
LAST_INSTALL_REPORT="${CLAUDE_HOME}/quality-pack/state/last-install-report.json"

# ---------------------------------------------------------------------------
# Test 1: First install writes SHA, manifest, and install-stamp
# ---------------------------------------------------------------------------
printf '1. First install artifacts\n'

install_output="$(run_install)"
assert_true "install exits cleanly" "[[ -d '${CLAUDE_HOME}' ]]"
assert_true "last-install-report.json exists after install" "[[ -f '${LAST_INSTALL_REPORT}' ]]"
assert_contains "fresh install summary requires restart" \
  "Restart Claude Code (or open a new session) before testing." "${install_output}"

# SHA: repo IS a git checkout (clone or worktree), so installed_sha must be set.
if repo_is_git_checkout "${REPO_ROOT}"; then
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
  printf '  SKIP: repo is not a git checkout; SHA test not applicable\n'
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
assert_eq "fresh install report kind" "fresh-install" \
  "$(jq -r '.install_kind' "${LAST_INSTALL_REPORT}")"
assert_eq "fresh install report restart_required" "true" \
  "$(jq -r '.restart_required' "${LAST_INSTALL_REPORT}")"

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

# Explicit worktree path: install.sh must record installed_sha when the
# source checkout is a linked worktree (`.git` file pointing at the common
# git dir), not just when `.git` is a directory.
if repo_is_git_checkout "${REPO_ROOT}"; then
  fixture_repo="${TEST_HOME}/fixture-repo"
  fixture_wt="${TEST_HOME}/fixture-worktree"
  fixture_home="${TEST_HOME}/fixture-home"
  mkdir -p "${fixture_repo}" "${fixture_home}"
  rsync -a --exclude '.git' "${REPO_ROOT}/" "${fixture_repo}/" >/dev/null
  (
    cd "${fixture_repo}"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email test@test.local
    git config user.name test
    git add -A
    git commit --quiet -m "snapshot"
    git worktree add --quiet "${fixture_wt}" -b install-artifacts-worktree HEAD
  )
  TARGET_HOME="${fixture_home}" bash "${fixture_wt}/install.sh" >/dev/null 2>&1
  fixture_conf="${fixture_home}/.claude/oh-my-claude.conf"
  fixture_sha_line="$(grep '^installed_sha=' "${fixture_conf}" 2>/dev/null || true)"
  fixture_sha_value="${fixture_sha_line#installed_sha=}"
  if [[ "${fixture_sha_value}" =~ ^[0-9a-f]{40}$ ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: worktree install must write a 40-char installed_sha (got: [%s])\n' "${fixture_sha_value}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  SKIP: repo is not a git checkout; worktree SHA test not applicable\n'
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
# SHA is written for any git checkout, including linked worktrees. Guard
# mirrors Test 1 above so tarball-source runs still skip cleanly.
if repo_is_git_checkout "${REPO_ROOT}"; then
  assert_true "installed_sha still set" "grep -q '^installed_sha=' '${CONF}'"
else
  printf '  SKIP: repo is not a git checkout; SHA persistence test not applicable\n'
fi
assert_true "manifest still exists" "[[ -f '${MANIFEST}' ]]"
assert_true "install-stamp still exists" "[[ -f '${STAMP}' ]]"
assert_eq "no-op reinstall report kind" "reinstall-noop" \
  "$(jq -r '.install_kind' "${LAST_INSTALL_REPORT}")"
assert_eq "no-op reinstall restart_required" "false" \
  "$(jq -r '.restart_required' "${LAST_INSTALL_REPORT}")"
assert_eq "no-op reinstall managed change total" "0" \
  "$(jq -r '.managed_changes.total' "${LAST_INSTALL_REPORT}")"
assert_eq "no-op reinstall settings_changed false" "false" \
  "$(jq -r '.settings_changed' "${LAST_INSTALL_REPORT}")"
assert_contains "no-op reinstall summary says no restart required" \
  "No Claude Code restart is required" "${install_output_3}"
helper_noop_state="$(run_install_state_report_from_home "${TEST_HOME}" --json)"
assert_eq "install-state-report surfaces last_install restart=false" "false" \
  "$(printf '%s' "${helper_noop_state}" | jq -r '.last_install.restart_required')"
assert_eq "install-state-report surfaces last_install kind" "reinstall-noop" \
  "$(printf '%s' "${helper_noop_state}" | jq -r '.last_install.kind')"
helper_noop_restart_guidance="$(run_install_state_report_from_home "${TEST_HOME}" --restart-guidance)"
assert_contains "install-state-report no-op restart guidance says no restart" \
  "No Claude Code restart is required." "${helper_noop_restart_guidance}"

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
# prior checkout install, then simulate a non-git install from a copied
# source tree with `.git` excluded entirely. This avoids mutating the
# real repo metadata under test while still exercising the tarball/zip
# path that must scrub stale installed_sha.
if repo_is_git_checkout "${REPO_ROOT}"; then
  NON_GIT_SOURCE="${TEST_HOME}/source-no-git"
  mkdir -p "${NON_GIT_SOURCE}"
  rsync -a --exclude '.git' "${REPO_ROOT}/" "${NON_GIT_SOURCE}/" >/dev/null
  # Seed a stale SHA into the conf so we can verify it gets cleaned.
  printf 'installed_sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >> "${CONF}"

  run_install_from "${NON_GIT_SOURCE}" >/dev/null 2>&1

  # After install with no .git, the stale sha should be removed from conf.
  if ! grep -q '^installed_sha=' "${CONF}"; then
    pass=$((pass + 1))
  else
    _got="$(grep '^installed_sha=' "${CONF}" | head -1)"
    printf '  FAIL: installed_sha line should be removed for non-git install (got: %s)\n' "${_got}" >&2
    fail=$((fail + 1))
  fi

else
  printf '  SKIP: repo is not a git checkout; non-git cleanup test not applicable\n'
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
# Test 11: install-state-report helper (AI-assisted install/update flow)
# ---------------------------------------------------------------------------
printf '11. Install-state report helper\n'

assert_true "install-state-report helper exists" "[[ -f '${INSTALL_STATE_REPORT}' ]]"

# 11a — no conf / no installed_version => not-installed.
blank_home="${TEST_HOME}/install-state-blank"
mkdir -p "${blank_home}"
out_state_blank="$(run_install_state_report_from_home "${blank_home}" --json)"
assert_eq "blank home install_status" "not-installed" \
  "$(printf '%s' "${out_state_blank}" | jq -r '.install_status')"
assert_eq "blank home currentness" "not-applicable" \
  "$(printf '%s' "${out_state_blank}" | jq -r '.currentness')"
assert_contains "blank home reason mentions installed_version" \
  "No installed_version recorded" "$(printf '%s' "${out_state_blank}" | jq -r '.reason')"

# Main-branch fixture used for already-current / tag-ahead / commit-ahead
# / version-only-fallback branches.
state_root="${TEST_HOME}/install-state-fixtures"
origin_src_main="${state_root}/origin-src-main"
origin_bare_main="${state_root}/origin-main.git"
checkout_main="${state_root}/checkout-main"
home_main="${state_root}/home-main"
mkdir -p "${origin_src_main}" "${home_main}/.claude"
(
  cd "${origin_src_main}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  printf '1.0.0\n' > VERSION
  git add VERSION
  git commit --quiet -m "v1.0.0"
  git tag v1.0.0
  git branch -m main 2>/dev/null || true
)
git clone --quiet --bare "${origin_src_main}" "${origin_bare_main}"
git clone --quiet "${origin_bare_main}" "${checkout_main}"
sha_main_v100="$(git -C "${checkout_main}" rev-parse HEAD)"
touch "${home_main}/.claude/.install-stamp"
cat > "${home_main}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.0.0
repo_path=${checkout_main}
installed_sha=${sha_main_v100}
EOF

# 11b — already current: latest tag matches and installed_sha matches origin/main.
out_state_current="$(run_install_state_report_from_home "${home_main}" --json)"
assert_eq "current fixture install_status" "installed" \
  "$(printf '%s' "${out_state_current}" | jq -r '.install_status')"
assert_eq "current fixture currentness" "already-current" \
  "$(printf '%s' "${out_state_current}" | jq -r '.currentness')"
assert_eq "current fixture latest_tag" "1.0.0" \
  "$(printf '%s' "${out_state_current}" | jq -r '.latest_tag')"
assert_eq "current fixture default ref" "origin/main" \
  "$(printf '%s' "${out_state_current}" | jq -r '.origin_default_ref')"
assert_eq "current fixture origin sha" "${sha_main_v100}" \
  "$(printf '%s' "${out_state_current}" | jq -r '.origin_default_sha')"
if [[ -n "$(printf '%s' "${out_state_current}" | jq -r '.last_install_at // empty')" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: install-state-report should expose last_install_at when .install-stamp exists\n' >&2
  fail=$((fail + 1))
fi
current_summary_text="$(run_install_state_report_from_home "${home_main}" --already-current-summary)"
assert_contains "already-current summary surfaces version" "Already current: v1.0.0" "${current_summary_text}"
assert_contains "already-current summary surfaces install timestamp" "last install:" "${current_summary_text}"

# 11c — tag-ahead update: latest tag newer than installed_version.
(
  cd "${origin_src_main}"
  printf '1.1.0\n' > VERSION
  git add VERSION
  git commit --quiet -m "v1.1.0"
  git tag v1.1.0
  git push --quiet "${origin_bare_main}" main --tags
)
out_state_tag_ahead="$(run_install_state_report_from_home "${home_main}" --json)"
assert_eq "tag-ahead currentness" "update-available" \
  "$(printf '%s' "${out_state_tag_ahead}" | jq -r '.currentness')"
assert_eq "tag-ahead latest_tag" "1.1.0" \
  "$(printf '%s' "${out_state_tag_ahead}" | jq -r '.latest_tag')"
assert_contains "tag-ahead reason names newer tag" \
  "latest tag v1.1.0 is newer" "$(printf '%s' "${out_state_tag_ahead}" | jq -r '.reason')"

# 11d — commit-ahead update at same tag: origin/main moved past installed_sha
# without a new release tag.
sha_main_v110="$(git -C "${origin_src_main}" rev-parse HEAD)"
cat > "${home_main}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.1.0
repo_path=${checkout_main}
installed_sha=${sha_main_v110}
EOF
(
  cd "${origin_src_main}"
  printf 'post-tag drift\n' > NOTES.md
  git add NOTES.md
  git commit --quiet -m "post-tag drift"
  git push --quiet "${origin_bare_main}" main
)
sha_main_posttag="$(git -C "${origin_src_main}" rev-parse HEAD)"
out_state_commit_ahead="$(run_install_state_report_from_home "${home_main}" --json)"
assert_eq "commit-ahead currentness" "update-available" \
  "$(printf '%s' "${out_state_commit_ahead}" | jq -r '.currentness')"
assert_eq "commit-ahead latest_tag stays at 1.1.0" "1.1.0" \
  "$(printf '%s' "${out_state_commit_ahead}" | jq -r '.latest_tag')"
assert_eq "commit-ahead origin sha" "${sha_main_posttag}" \
  "$(printf '%s' "${out_state_commit_ahead}" | jq -r '.origin_default_sha')"
assert_contains "commit-ahead reason names origin/main" \
  "origin/main is ahead of installed_sha" "$(printf '%s' "${out_state_commit_ahead}" | jq -r '.reason')"

# 11e — tarball / archive fallback: installed_sha absent means
# installed_version vs latest_tag is authoritative.
cat > "${home_main}/.claude/oh-my-claude.conf" <<EOF
installed_version=1.1.0
repo_path=${checkout_main}
EOF
out_state_version_only="$(run_install_state_report_from_home "${home_main}" --json)"
assert_eq "version-only fallback currentness" "already-current" \
  "$(printf '%s' "${out_state_version_only}" | jq -r '.currentness')"
assert_contains "version-only fallback reason is explicit" \
  "version-only fallback applies" "$(printf '%s' "${out_state_version_only}" | jq -r '.reason')"

# 11f — default-branch detection must not be hardcoded to origin/main.
origin_src_trunk="${state_root}/origin-src-trunk"
origin_bare_trunk="${state_root}/origin-trunk.git"
checkout_trunk="${state_root}/checkout-trunk"
home_trunk="${state_root}/home-trunk"
mkdir -p "${origin_src_trunk}" "${home_trunk}/.claude"
(
  cd "${origin_src_trunk}"
  git init --quiet --initial-branch=trunk 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  printf '2.0.0\n' > VERSION
  git add VERSION
  git commit --quiet -m "v2.0.0"
  git tag v2.0.0
  git branch -m trunk 2>/dev/null || true
)
git clone --quiet --bare "${origin_src_trunk}" "${origin_bare_trunk}"
git clone --quiet "${origin_bare_trunk}" "${checkout_trunk}"
sha_trunk_v200="$(git -C "${checkout_trunk}" rev-parse HEAD)"
touch "${home_trunk}/.claude/.install-stamp"
cat > "${home_trunk}/.claude/oh-my-claude.conf" <<EOF
installed_version=2.0.0
repo_path=${checkout_trunk}
installed_sha=${sha_trunk_v200}
EOF
out_state_trunk="$(run_install_state_report_from_home "${home_trunk}" --json)"
assert_eq "trunk fixture currentness" "already-current" \
  "$(printf '%s' "${out_state_trunk}" | jq -r '.currentness')"
assert_eq "trunk fixture default ref" "origin/trunk" \
  "$(printf '%s' "${out_state_trunk}" | jq -r '.origin_default_ref')"
assert_contains "trunk fixture reason names origin/trunk" \
  "origin/trunk" "$(printf '%s' "${out_state_trunk}" | jq -r '.reason')"

printf '\n'

# ---------------------------------------------------------------------------
# Test 12: settings-only reinstall still requires restart
# ---------------------------------------------------------------------------
printf '12. Settings-only reinstall requires restart\n'

settings_home="${TEST_HOME}/settings-reinstall-home"
mkdir -p "${settings_home}"
TARGET_HOME="${settings_home}" bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1
settings_report="${settings_home}/.claude/quality-pack/state/last-install-report.json"
out_settings_reinstall="$(TARGET_HOME="${settings_home}" bash "${REPO_ROOT}/install.sh" --bypass-permissions 2>&1)"
assert_eq "settings-only report kind" "reinstall" \
  "$(jq -r '.install_kind' "${settings_report}")"
assert_eq "settings-only restart_required" "true" \
  "$(jq -r '.restart_required' "${settings_report}")"
assert_eq "settings-only managed change total stays zero" "0" \
  "$(jq -r '.managed_changes.total' "${settings_report}")"
assert_eq "settings-only settings_changed true" "true" \
  "$(jq -r '.settings_changed' "${settings_report}")"
assert_contains "settings-only summary requires restart" \
  "Restart Claude Code (or open a new session) before testing." "${out_settings_reinstall}"
helper_settings_state="$(run_install_state_report_from_home "${settings_home}" --json)"
assert_eq "install-state-report surfaces settings-only restart=true" "true" \
  "$(printf '%s' "${helper_settings_state}" | jq -r '.last_install.restart_required')"
assert_eq "install-state-report surfaces settings-only settings_changed=true" "true" \
  "$(printf '%s' "${helper_settings_state}" | jq -r '.last_install.settings_changed')"
helper_settings_restart_guidance="$(run_install_state_report_from_home "${settings_home}" --restart-guidance)"
assert_contains "install-state-report settings restart guidance says restart" \
  "Restart Claude Code (or open a new session) before testing." "${helper_settings_restart_guidance}"

printf '\n'

# ---------------------------------------------------------------------------
# Test 13: update installs record prior/current refs and changelog summary
# ---------------------------------------------------------------------------
printf '13. Update change summary artifact\n'

update_fixture_repo="${TEST_HOME}/update-fixture-repo"
update_home="${TEST_HOME}/update-fixture-home"
mkdir -p "${update_fixture_repo}" "${update_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${update_fixture_repo}/" >/dev/null
(
  cd "${update_fixture_repo}"
  git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
  git config user.email test@test.local
  git config user.name test
  printf '9.9.0\n' > VERSION
  git add -A
  git commit --quiet -m "fixture baseline"
)
update_baseline_sha="$(git -C "${update_fixture_repo}" rev-parse HEAD)"
TARGET_HOME="${update_home}" bash "${update_fixture_repo}/install.sh" >/dev/null 2>&1

(
  cd "${update_fixture_repo}"
  printf '9.9.1\n' > VERSION
  printf 'fixture delta\n' > CHANGE_SUMMARY_FIXTURE.md
  git add VERSION CHANGE_SUMMARY_FIXTURE.md
  git commit --quiet -m "fixture update delta"
)
update_current_sha="$(git -C "${update_fixture_repo}" rev-parse HEAD)"
update_install_output="$(TARGET_HOME="${update_home}" bash "${update_fixture_repo}/install.sh" 2>&1)"

update_report="${update_home}/.claude/quality-pack/state/last-install-report.json"
assert_eq "update report kind" "update" \
  "$(jq -r '.install_kind' "${update_report}")"
assert_eq "update report previous version" "9.9.0" \
  "$(jq -r '.previous_install.installed_version' "${update_report}")"
assert_eq "update report previous sha" "${update_baseline_sha}" \
  "$(jq -r '.previous_install.installed_sha' "${update_report}")"
assert_eq "update report current version" "9.9.1" \
  "$(jq -r '.current_install.installed_version' "${update_report}")"
assert_eq "update report current sha" "${update_current_sha}" \
  "$(jq -r '.current_install.installed_sha' "${update_report}")"
assert_eq "update report change summary available" "true" \
  "$(jq -r '.change_summary.available' "${update_report}")"
assert_eq "update report change summary count" "1" \
  "$(jq -r '.change_summary.commit_count' "${update_report}")"
assert_eq "update report change summary subject" "fixture update delta" \
  "$(jq -r '.change_summary.commits[0].subject' "${update_report}")"
assert_eq "update report restart reason reflects unchanged installed bytes" \
  "Update completed, but managed bundle files and settings.json were unchanged." \
  "$(jq -r '.restart_reason' "${update_report}")"
assert_contains "install.sh prints update summary header" "Update summary:" "${update_install_output}"
assert_contains "install.sh prints previous install ref" "Previous install: v9.9.0 @ ${update_baseline_sha:0:12}" "${update_install_output}"
assert_contains "install.sh prints current install ref" "Current install:  v9.9.1 @ ${update_current_sha:0:12}" "${update_install_output}"
assert_contains "install.sh prints update restart decision" "Restart needed:  no" "${update_install_output}"
assert_contains "install.sh prints update reason" "Reason:          Update completed, but managed bundle files and settings.json were unchanged." "${update_install_output}"
assert_contains "install.sh prints update commit subject" "fixture update delta" "${update_install_output}"

helper_update_state="$(run_install_state_report_from_home "${update_home}" --json)"
assert_eq "install-state-report surfaces previous version" "9.9.0" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.previous.installed_version')"
assert_eq "install-state-report surfaces previous sha" "${update_baseline_sha}" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.previous.installed_sha')"
assert_eq "install-state-report surfaces current version" "9.9.1" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.current.installed_version')"
assert_eq "install-state-report surfaces current sha" "${update_current_sha}" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.current.installed_sha')"
assert_eq "install-state-report surfaces change summary availability" "true" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.change_summary.available')"
assert_eq "install-state-report surfaces change summary count" "1" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.change_summary.commit_count')"
assert_eq "install-state-report surfaces change summary subject" "fixture update delta" \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.change_summary.commits[0].subject')"
assert_eq "install-state-report surfaces corrected update reason" \
  "Update completed, but managed bundle files and settings.json were unchanged." \
  "$(printf '%s' "${helper_update_state}" | jq -r '.last_install.reason')"
helper_update_summary="$(run_install_state_report_from_home "${update_home}" --last-update-summary)"
assert_contains "install-state-report text summary header" "Update summary:" "${helper_update_summary}"
assert_contains "install-state-report text summary previous ref" \
  "Previous install: v9.9.0 @ ${update_baseline_sha:0:12}" "${helper_update_summary}"
assert_contains "install-state-report text summary current ref" \
  "Current install:  v9.9.1 @ ${update_current_sha:0:12}" "${helper_update_summary}"
assert_contains "install-state-report text summary restart decision" \
  "Restart needed:  no" "${helper_update_summary}"
assert_contains "install-state-report text summary reason" \
  "Reason:          Update completed, but managed bundle files and settings.json were unchanged." "${helper_update_summary}"
assert_contains "install-state-report text summary commit subject" \
  "fixture update delta" "${helper_update_summary}"

printf '\n'

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf '=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
