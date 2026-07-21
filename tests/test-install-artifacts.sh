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

file_mode() {
  stat -c '%a' "${1:-}" 2>/dev/null \
    || stat -f '%Lp' "${1:-}" 2>/dev/null
}

file_node_identity() {
  stat -c '%d:%i' "${1:-}" 2>/dev/null \
    || stat -f '%d:%i' "${1:-}" 2>/dev/null
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
assert_eq "successful install retires fixed transaction metadata" "false" \
  "$([[ -e "${CLAUDE_HOME}/.install-transaction" \
      || -L "${CLAUDE_HOME}/.install-transaction" ]] \
    && printf true || printf false)"
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

# A malformed-but-user-owned non-string outputStyle is preserved by the
# implicit default merge. The install summary must describe that state
# without rendering multiline JSON or claiming a bundled style is active.
summary_style_home="${TEST_HOME}/summary-non-string-home"
mkdir -p "${summary_style_home}/.claude"
printf '%s\n' '{"outputStyle":{"custom":"kept"}}' \
  > "${summary_style_home}/.claude/settings.json"
summary_style_rc=0
summary_style_output="$(
  unset OMC_OUTPUT_STYLE_PREF OMC_OUTPUT_STYLE_PREF_EXPLICIT
  TARGET_HOME="${summary_style_home}" bash "${REPO_ROOT}/install.sh" 2>&1
)" || summary_style_rc=$?
assert_eq "non-string outputStyle install succeeds" "0" \
  "${summary_style_rc}"
assert_eq "implicit install preserves object outputStyle" \
  '{"custom":"kept"}' \
  "$(jq -c '.outputStyle' \
    "${summary_style_home}/.claude/settings.json" 2>/dev/null || true)"
assert_contains "summary labels preserved non-string outputStyle" \
  'Output style:  preserved non-string settings.outputStyle (object); bundled fallback not selected' \
  "${summary_style_output}"
assert_eq "summary does not falsely claim bundled output style" "false" \
  "$([[ "${summary_style_output}" == *'Output style:  oh-my-claude'* ]] \
    && printf true || printf false)"

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
assert_contains "manifest lists dispatch recovery guard" \
  "skills/autowork/scripts/dispatch-recovery-guard.sh" \
  "$(cat "${MANIFEST}")"
assert_contains "manifest lists planner publication transaction lib" \
  "skills/autowork/scripts/lib/plan-publication-transaction.sh" \
  "$(cat "${MANIFEST}")"
assert_true "planner publication transaction lib is installed" \
  "[[ -f '${CLAUDE_HOME}/skills/autowork/scripts/lib/plan-publication-transaction.sh' ]]"

# Install stamp exists.
assert_true ".install-stamp exists" "[[ -f '${STAMP}' ]]"
for mode_rel in oh-my-claude.conf.example statusline.py agents/prometheus.md; do
  assert_eq "installed mode matches source for ${mode_rel}" \
    "$(file_mode "${REPO_ROOT}/bundle/dot-claude/${mode_rel}")" \
    "$(file_mode "${CLAUDE_HOME}/${mode_rel}")"
done
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
# drift detection. A trusted exact shasum/sha256sum is now an install
# dependency because Definition and verification authority use the same
# primitive; every successful install must publish a non-empty manifest.
assert_true "installed-hashes.txt exists after successful install" \
  "[[ -f '${HASHES}' ]]"

if [[ -f "${HASHES}" ]]; then
  hashes_lines="$(wc -l < "${HASHES}" | tr -d '[:space:]')"
  if [[ "${hashes_lines}" -gt 10 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: installed-hashes.txt must be non-trivial (got %s lines)\n' "${hashes_lines}" >&2
    fail=$((fail + 1))
  fi

  # First non-blank line must match `<sha256>  <path>` shape.
  first_line="$(grep -m1 -v '^[[:space:]]*$' "${HASHES}")"
  if [[ "${first_line}" =~ ^[0-9a-f]{64}\ \ .+ ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: first hash line must be `<sha256>  <path>` (got: %s)\n' "${first_line}" >&2
    fail=$((fail + 1))
  fi

  assert_contains "hashes lists CLAUDE.md" "CLAUDE.md" "$(cat "${HASHES}")"
  assert_contains "hashes lists common.sh" \
    "skills/autowork/scripts/common.sh" "$(cat "${HASHES}")"
fi

forged_sha_env="${TEST_HOME}/forged-sha-bash-env"
printf '%s\n' \
  'shasum() { printf "%064d  forged\\n" 0; }' \
  'sha256sum() { printf "%064d  forged\\n" 0; }' \
  'export -f shasum sha256sum' >"${forged_sha_env}"
BASH_ENV="${forged_sha_env}" TARGET_HOME="${TEST_HOME}" \
  bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1
if grep -Eq '^0{64}[[:space:]][[:space:]]' "${HASHES}"; then
  printf '  FAIL: BASH_ENV SHA function forged installed hash manifest\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
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
# to OMC_VERSION and detect the gap. A malformed later duplicate must not be
# normalized into authority by deleting its interior whitespace; last VALID
# metadata wins for both the version and SHA coordinates.
_prior_valid_sha=""
if [[ -f "${CONF}" ]]; then
  _backup="$(mktemp)"
  grep -v '^installed_version=' "${CONF}" > "${_backup}" 2>/dev/null || true
  _prior_valid_sha="$(grep -E '^installed_sha=[0-9A-Fa-f]{7,40}$' \
    "${_backup}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf 'installed_version=1.27.0\n' >> "${_backup}"
  _current_version="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
  _malformed_current_version="${_current_version/./. }"
  printf 'installed_version=%s\n' "${_malformed_current_version}" >> "${_backup}"
  printf 'installed_sha=ffffffffffffffffffff ffffffffffffffffffff\n' \
    >> "${_backup}"
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
assert_eq "last-valid prior version rejects interior-whitespace normalization" \
  "1.27.0" \
  "$(jq -r '.previous_install.installed_version // empty' \
    "${LAST_INSTALL_REPORT}" 2>/dev/null || true)"
if [[ -n "${_prior_valid_sha}" ]]; then
  assert_eq "last-valid prior SHA rejects interior-whitespace normalization" \
    "${_prior_valid_sha}" \
    "$(jq -r '.previous_install.installed_sha // empty' \
      "${LAST_INSTALL_REPORT}" 2>/dev/null || true)"
fi

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
assert_eq "auto-detect skip records Ghostty selection" \
  "ghostty_installed=off" \
  "$(grep '^ghostty_installed=' \
    "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"

# 8b — Pre-create ~/.config/ghostty/ then install — should now seed.
mkdir -p "${GHOSTTY_HOME_FAKE}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" >/dev/null 2>&1 || true
if [[ -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: auto-detect should seed when ~/.config/ghostty/ pre-exists (themes/ missing)\n' >&2
  fail=$((fail + 1))
fi
assert_eq "auto-detect install records Ghostty selection" \
  "ghostty_installed=on" \
  "$(grep '^ghostty_installed=' \
    "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"

# 8c — --no-ghostty must skip seeding even when the dir pre-exists.
rm -rf "${GHOSTTY_HOME_FAKE}/themes"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --no-ghostty >/dev/null 2>&1 || true
if [[ ! -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --no-ghostty should skip even when ghostty home pre-exists\n' >&2
  fail=$((fail + 1))
fi
assert_eq "explicit Ghostty opt-out is persisted for drift checks" \
  "ghostty_installed=off" \
  "$(grep '^ghostty_installed=' \
    "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"

# 8d — --with-ghostty must seed even when ~/.config/ghostty/ does NOT exist.
rm -rf "${GHOSTTY_HOME_FAKE}"
TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" --with-ghostty >/dev/null 2>&1 || true
if [[ -d "${GHOSTTY_HOME_FAKE}/themes" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: --with-ghostty should force-seed when ghostty home is absent\n' >&2
  fail=$((fail + 1))
fi
assert_eq "explicit Ghostty install is persisted for drift checks" \
  "ghostty_installed=on" \
  "$(grep '^ghostty_installed=' \
    "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null || true)"

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

# Octal-looking and machine-width values are also invalid before any install
# path is created. Both previously passed the digit-only regex and reached Bash
# arithmetic (`08` aborting as invalid octal; a huge decimal wrapping).
for invalid_keep in 00 08 10001 999999999999999999999999999999999999; do
  invalid_keep_home="${TEST_HOME}/invalid-keep-${invalid_keep}"
  invalid_keep_rc=0
  invalid_keep_out="$(TARGET_HOME="${invalid_keep_home}" \
    bash "${REPO_ROOT}/install.sh" \
      "--keep-backups=${invalid_keep}" 2>&1)" || invalid_keep_rc=$?
  assert_eq "non-canonical/bounded keep-backups rejects ${invalid_keep}" \
    "1" "${invalid_keep_rc}"
  assert_contains "invalid keep-backups ${invalid_keep} is diagnosed" \
    "Invalid --keep-backups" "${invalid_keep_out}"
  assert_eq "invalid keep-backups ${invalid_keep} mutates no install home" \
    "no" "$([[ -e "${invalid_keep_home}/.claude" ]] \
      && printf yes || printf no)"
done

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

# 9f — the retention preview is not deletion authority for descendants added
# during its user-interaction window. The old tree must be preserved intact if
# its sealed node set changes before rm -rf.
prune_race_home="${TEST_HOME}/backup-prune-race-home"
prune_race_ready="${TEST_HOME}/backup-prune-race.ready"
prune_race_release="${TEST_HOME}/backup-prune-race.release"
prune_race_out="${TEST_HOME}/backup-prune-race.out"
prune_race_old="${prune_race_home}/.claude/backups/oh-my-claude-20000101-000001"
mkdir -p "${prune_race_old}"
printf 'pre-preview\n' > "${prune_race_old}/original"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_BACKUP_PRUNE_READY_FILE="${prune_race_ready}" \
  OMC_TEST_INSTALL_BACKUP_PRUNE_RELEASE_FILE="${prune_race_release}" \
  TARGET_HOME="${prune_race_home}" bash "${REPO_ROOT}/install.sh" \
    --keep-backups=1 >"${prune_race_out}" 2>&1
) &
prune_race_pid=$!
prune_race_seen=0
for _wait in $(seq 1 2000); do
  [[ -e "${prune_race_ready}" ]] \
    && { prune_race_seen=1; break; }
  kill -0 "${prune_race_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "backup prune reaches post-preview subtree barrier" "1" \
  "${prune_race_seen}"
if [[ "${prune_race_seen}" -eq 1 ]]; then
  mkdir -p "${prune_race_old}/concurrent"
  printf 'must-survive\n' > "${prune_race_old}/concurrent/foreign"
fi
: > "${prune_race_release}"
prune_race_rc=0
wait "${prune_race_pid}" || prune_race_rc=$?
assert_eq "changed backup subtree is a non-fatal maintenance warning" "0" \
  "${prune_race_rc}"
assert_eq "backup prune preserves the originally previewed tree" \
  "pre-preview" \
  "$(cat "${prune_race_old}/original" 2>/dev/null || true)"
assert_eq "backup prune preserves a new descendant instead of sweeping it" \
  "must-survive" \
  "$(cat "${prune_race_old}/concurrent/foreign" 2>/dev/null || true)"
assert_contains "backup prune reports the changed target" \
  "Backup prune target changed after preview; preserved" \
  "$(<"${prune_race_out}")"

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
quiet_reinstall_rc=0
out_quiet="$(TARGET_HOME="${TEST_HOME}" bash "${REPO_ROOT}/install.sh" 2>&1)" \
  || quiet_reinstall_rc=$?
assert_eq "private snapshot modes leave a normal install reinstallable" "0" \
  "${quiet_reinstall_rc}"
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
manifest_file="${TEST_HOME}/.claude/quality-pack/state/installed-manifest.txt"
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
  hash_paths="${TEST_HOME}/no-ios-hash-paths"
  awk '{print substr($0, index($0, $2))}' "${hashes_file}" \
    | LC_ALL=C sort > "${hash_paths}"
  assert_eq "manifest and hash path sets are identical after --no-ios" "true" \
    "$(cmp -s "${manifest_file}" "${hash_paths}" \
      && printf true || printf false)"
  assert_eq "--no-ios manifest excludes only optional iOS definitions" "0" \
    "$(grep -c '^agents/ios-.*\.md$' "${manifest_file}" || true)"
  assert_eq "--no-ios mode persists for later source comparison" "on" \
    "$(sed -n 's/^exclude_ios=//p' \
      "${TEST_HOME}/.claude/oh-my-claude.conf" | tail -1)"
else
  printf '  FAIL: T10c — successful install omitted required hash manifest\n' >&2
  fail=$((fail + 1))
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
# Test 14: source-node and settings transaction admission
# ---------------------------------------------------------------------------
printf '14. Source-node and settings transaction admission\n'

for source_node_case in file-symlink directory-symlink fifo; do
  source_fixture="${TEST_HOME}/source-node-${source_node_case}"
  source_target_home="${TEST_HOME}/source-node-home-${source_node_case}"
  mkdir -p "${source_fixture}" "${source_target_home}"
  rsync -a --exclude '.git' "${REPO_ROOT}/" "${source_fixture}/" >/dev/null
  case "${source_node_case}" in
    file-symlink)
      printf 'external\n' > "${source_fixture}/external-source-file"
      rm -f "${source_fixture}/bundle/dot-claude/quality-pack/memory/core.md"
      ln -s "${source_fixture}/external-source-file" \
        "${source_fixture}/bundle/dot-claude/quality-pack/memory/core.md"
      ;;
    directory-symlink)
      mkdir -p "${source_fixture}/external-source-dir"
      printf 'external\n' > "${source_fixture}/external-source-dir/value"
      ln -s "${source_fixture}/external-source-dir" \
        "${source_fixture}/bundle/dot-claude/quality-pack/source-link"
      ;;
    fifo)
      mkfifo "${source_fixture}/bundle/dot-claude/quality-pack/source-fifo"
      ;;
  esac
  source_node_rc=0
  source_node_out="$(TARGET_HOME="${source_target_home}" \
    bash "${source_fixture}/install.sh" 2>&1)" || source_node_rc=$?
  assert_eq "${source_node_case} source node is refused" "1" \
    "${source_node_rc}"
  assert_eq "${source_node_case} source refusal creates no .claude" \
    "false" \
    "$([[ -e "${source_target_home}/.claude" ]] && printf true || printf false)"
  assert_contains "${source_node_case} source refusal names tree preflight" \
    "Source distribution tree preflight failed" "${source_node_out}"
done

unsafe_state_home="${TEST_HOME}/unsafe-installed-state-parent"
unsafe_state_external="${TEST_HOME}/unsafe-installed-state-external"
mkdir -p "${unsafe_state_home}/.claude/quality-pack" \
  "${unsafe_state_external}"
printf 'external\n' > "${unsafe_state_external}/sentinel"
ln -s "${unsafe_state_external}" \
  "${unsafe_state_home}/.claude/quality-pack/state"
unsafe_state_rc=0
unsafe_state_out="$(TARGET_HOME="${unsafe_state_home}" \
  bash "${REPO_ROOT}/install.sh" 2>&1)" || unsafe_state_rc=$?
assert_eq "symlinked installed manifest parent is refused" "1" \
  "${unsafe_state_rc}"
assert_true "symlinked manifest parent cannot alter external target" \
  "[[ -f '${unsafe_state_external}/sentinel' ]]"
assert_eq "unsafe manifest parent copies no bundle" "false" \
  "$([[ -e "${unsafe_state_home}/.claude/statusline.py" ]] \
    && printf true || printf false)"
assert_contains "unsafe manifest parent is named" \
  "Refusing manifest publication through symlinked path" \
  "${unsafe_state_out}"

for control_case in manifest hashes stamp report; do
  control_home="${TEST_HOME}/unsafe-control-leaf-${control_case}"
  control_external="${TEST_HOME}/unsafe-control-external-${control_case}"
  mkdir -p "${control_home}/.claude/quality-pack/state"
  printf 'external-%s\n' "${control_case}" > "${control_external}"
  case "${control_case}" in
    manifest) control_rel='quality-pack/state/installed-manifest.txt' ;;
    hashes) control_rel='quality-pack/state/installed-hashes.txt' ;;
    stamp) control_rel='.install-stamp' ;;
    report) control_rel='quality-pack/state/last-install-report.json' ;;
  esac
  if [[ "${control_case}" == "report" ]]; then
    printf 'pre-install-managed-bytes\n' \
      > "${control_home}/.claude/CLAUDE.md"
    mkdir -p "${control_home}/.claude/output-styles"
    printf 'legacy-user-bytes\n' \
      > "${control_home}/.claude/output-styles/opencode-compact.md"
  fi
  ln -s "${control_external}" "${control_home}/.claude/${control_rel}"
  control_rc=0
  TARGET_HOME="${control_home}" bash "${REPO_ROOT}/install.sh" \
    >/dev/null 2>&1 || control_rc=$?
  assert_eq "${control_case} symlink leaf is refused" "1" "${control_rc}"
  assert_eq "${control_case} symlink target bytes are untouched" \
    "external-${control_case}" "$(cat "${control_external}")"
  assert_eq "${control_case} symlink leaf is restored after rollback" "true" \
    "$([[ -L "${control_home}/.claude/${control_rel}" ]] \
      && printf true || printf false)"
  if [[ "${control_case}" == "report" ]]; then
    assert_eq "late report failure restores arbitrary prior bundle bytes" \
      "pre-install-managed-bytes" \
      "$(cat "${control_home}/.claude/CLAUDE.md")"
    assert_eq "late report failure restores removed legacy style" \
      "legacy-user-bytes" \
      "$(cat "${control_home}/.claude/output-styles/opencode-compact.md")"
  else
    assert_eq "${control_case} failure removes newly copied bundle leaves" \
      "false" \
      "$([[ -e "${control_home}/.claude/CLAUDE.md" ]] \
        && printf true || printf false)"
  fi
done

rollback_home="${TEST_HOME}/full-install-rollback"
mkdir -p "${rollback_home}/.claude/output-styles"
printf 'prior-claude-bytes\n' > "${rollback_home}/.claude/CLAUDE.md"
printf 'legacy-prior-bytes\n' \
  > "${rollback_home}/.claude/output-styles/opencode-compact.md"
printf '%s\n' '{"userKey":"prior"}' \
  > "${rollback_home}/.claude/settings.json"
cp "${rollback_home}/.claude/settings.json" \
  "${rollback_home}/settings.before.json"
rollback_rc=0
OMC_TEST_INSTALL_FAIL_AFTER_LEGACY_CLEANUP=1 \
  TARGET_HOME="${rollback_home}" bash "${REPO_ROOT}/install.sh" \
  >/dev/null 2>&1 || rollback_rc=$?
assert_eq "late injected failure returns original status" "97" "${rollback_rc}"
assert_eq "late failure restores arbitrary prior bundle file" \
  "prior-claude-bytes" "$(cat "${rollback_home}/.claude/CLAUDE.md")"
assert_eq "late failure restores deleted legacy output style" \
  "legacy-prior-bytes" \
  "$(cat "${rollback_home}/.claude/output-styles/opencode-compact.md")"
assert_eq "late failure restores exact pre-install settings bytes" "true" \
  "$(cmp -s "${rollback_home}/settings.before.json" \
      "${rollback_home}/.claude/settings.json" && printf true || printf false)"
for rollback_absent in statusline.py .install-stamp \
    quality-pack/state/installed-manifest.txt \
    quality-pack/state/installed-hashes.txt \
    quality-pack/state/last-install-report.json; do
  assert_eq "late failure removes newly-created ${rollback_absent}" "false" \
    "$([[ -e "${rollback_home}/.claude/${rollback_absent}" \
        || -L "${rollback_home}/.claude/${rollback_absent}" ]] \
      && printf true || printf false)"
done
assert_eq "catchable rollback retires fixed transaction metadata" "false" \
  "$([[ -e "${rollback_home}/.claude/.install-transaction" \
      || -L "${rollback_home}/.claude/.install-transaction" ]] \
    && printf true || printf false)"

for settings_node_case in fifo directory dangling-symlink; do
  settings_node_home="${TEST_HOME}/settings-node-${settings_node_case}"
  mkdir -p "${settings_node_home}/.claude"
  printf 'preserve\n' > "${settings_node_home}/.claude/user-sentinel"
  case "${settings_node_case}" in
    fifo) mkfifo "${settings_node_home}/.claude/settings.json" ;;
    directory) mkdir "${settings_node_home}/.claude/settings.json" ;;
    dangling-symlink)
      ln -s "${settings_node_home}/missing.json" \
        "${settings_node_home}/.claude/settings.json"
      ;;
  esac
  settings_node_rc=0
  settings_node_out="$(TARGET_HOME="${settings_node_home}" \
    bash "${REPO_ROOT}/install.sh" 2>&1)" || settings_node_rc=$?
  assert_eq "${settings_node_case} settings node is refused" "1" \
    "${settings_node_rc}"
  assert_true "${settings_node_case} settings refusal preserves user sentinel" \
    "[[ -f '${settings_node_home}/.claude/user-sentinel' ]]"
  assert_eq "${settings_node_case} settings refusal copies no bundle" "false" \
    "$([[ -e "${settings_node_home}/.claude/statusline.py" ]] \
      && printf true || printf false)"
  assert_contains "${settings_node_case} settings refusal is explicit" \
    "settings.json is dangling or not a regular file" "${settings_node_out}"
done

for malformed_settings_case in root hooks event bypass-permissions; do
  malformed_settings_home="${TEST_HOME}/malformed-install-settings-${malformed_settings_case}"
  mkdir -p "${malformed_settings_home}/.claude"
  case "${malformed_settings_case}" in
    root) printf '%s\n' '[]' > "${malformed_settings_home}/.claude/settings.json" ;;
    hooks) printf '%s\n' '{"hooks":42}' > "${malformed_settings_home}/.claude/settings.json" ;;
    event) printf '%s\n' '{"hooks":{"Stop":42}}' > "${malformed_settings_home}/.claude/settings.json" ;;
    bypass-permissions)
      printf '%s\n' '{"permissions":"foreign-scalar"}' \
        > "${malformed_settings_home}/.claude/settings.json"
      ;;
  esac
  malformed_settings_rc=0
  if [[ "${malformed_settings_case}" == "bypass-permissions" ]]; then
    malformed_settings_out="$(TARGET_HOME="${malformed_settings_home}" \
      bash "${REPO_ROOT}/install.sh" --bypass-permissions 2>&1)" \
      || malformed_settings_rc=$?
  else
    malformed_settings_out="$(TARGET_HOME="${malformed_settings_home}" \
      bash "${REPO_ROOT}/install.sh" 2>&1)" \
      || malformed_settings_rc=$?
  fi
  assert_eq "${malformed_settings_case} settings shape is refused" "1" \
    "${malformed_settings_rc}"
  assert_eq "${malformed_settings_case} shape copies no bundle" "false" \
    "$([[ -e "${malformed_settings_home}/.claude/statusline.py" ]] \
      && printf true || printf false)"
  assert_contains "${malformed_settings_case} shape refusal is atomic" \
    "Installed files were not changed" "${malformed_settings_out}"
done

linked_settings_home="${TEST_HOME}/linked-install-settings-home"
linked_settings_target_dir="${TEST_HOME}/linked-install-settings-target"
mkdir -p "${linked_settings_home}/.claude" "${linked_settings_target_dir}"
printf '%s\n' '{"userKey":"keep","permissions":null}' \
  > "${linked_settings_target_dir}/settings.json"
ln -s "${linked_settings_target_dir}/settings.json" \
  "${linked_settings_home}/.claude/settings.json"
TARGET_HOME="${linked_settings_home}" bash "${REPO_ROOT}/install.sh" \
  --bypass-permissions >/dev/null 2>&1
assert_true "install preserves a regular settings symlink" \
  "[[ -L '${linked_settings_home}/.claude/settings.json' ]]"
assert_eq "linked physical settings target receives managed hooks" "true" \
  "$(jq -r '(.hooks.Stop | length) > 0' \
    "${linked_settings_target_dir}/settings.json")"
assert_eq "bypass install normalizes null permissions" "bypassPermissions" \
  "$(jq -r '.permissions.defaultMode' \
    "${linked_settings_target_dir}/settings.json")"
assert_eq "linked settings preserve foreign keys" "keep" \
  "$(jq -r '.userKey' "${linked_settings_target_dir}/settings.json")"
linked_backup_dir="$(find "${linked_settings_home}/.claude/backups" \
  -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort | tail -1)"
assert_true "linked settings backup stores physical target bytes" \
  "[[ -f '${linked_backup_dir}/settings.json' && ! -L '${linked_backup_dir}/settings.json' ]]"
assert_eq "linked settings backup contains pre-merge user bytes" "keep" \
  "$(jq -r '.userKey' "${linked_backup_dir}/settings.json")"

# Every decoded string is NUL-free before preflight projects any value through
# jq -r into Bash. Command authorities are additionally single-line: CR/LF
# cannot split a poisoned command into an allowlisted prefix plus hidden bytes.
poison_patch_repo="${TEST_HOME}/poison-patch-repo"
mkdir -p "${poison_patch_repo}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${poison_patch_repo}/" >/dev/null
cp "${poison_patch_repo}/config/settings.patch.json" \
  "${TEST_HOME}/settings.patch.clean.json"
for poison_patch_case in raw-nul status-nul status-cr status-lf \
    hook-nul hook-cr hook-lf; do
  poison_patch_home="${TEST_HOME}/poison-patch-${poison_patch_case}-home"
  mkdir -p "${poison_patch_home}/.claude"
  printf '%s\n' '{"userKey":"preserve"}' \
    > "${poison_patch_home}/.claude/settings.json"
  printf 'prior-managed-bytes\n' \
    > "${poison_patch_home}/.claude/CLAUDE.md"
  cp "${poison_patch_home}/.claude/settings.json" \
    "${poison_patch_home}/settings.before.json"
  cp "${poison_patch_home}/.claude/CLAUDE.md" \
    "${poison_patch_home}/CLAUDE.before.md"

  case "${poison_patch_case}" in
    raw-nul)
      # jq accepts this literal byte after a numeric scalar. Preflight must
      # judge the exact byte stream, not jq's normalized parse.
      perl -0pe \
        's/("padding"[[:space:]]*:[[:space:]]*0)/$1\0/' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    status-nul)
      jq '.statusLine.command += "\u0000"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    status-cr)
      jq '.statusLine.command += "\r"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    status-lf)
      jq '.statusLine.command += "\n"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    hook-nul)
      jq '.hooks.SessionStart[0].hooks[0].command += "\u0000"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    hook-cr)
      jq '.hooks.SessionStart[0].hooks[0].command += "\r"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
    hook-lf)
      jq '.hooks.SessionStart[0].hooks[0].command += "\n"' \
        "${TEST_HOME}/settings.patch.clean.json" \
        > "${poison_patch_repo}/config/settings.patch.json"
      ;;
  esac
  cp "${poison_patch_repo}/config/settings.patch.json" \
    "${TEST_HOME}/settings.patch.${poison_patch_case}.before.json"

  poison_patch_rc=0
  poison_patch_out="$(TARGET_HOME="${poison_patch_home}" \
    bash "${poison_patch_repo}/install.sh" 2>&1)" || poison_patch_rc=$?
  assert_eq "${poison_patch_case} source patch is refused" "1" \
    "${poison_patch_rc}"
  assert_contains "${poison_patch_case} source patch refusal is explicit" \
    "Malformed settings patch" "${poison_patch_out}"
  assert_eq "${poison_patch_case} source patch bytes are preserved" "true" \
    "$(cmp -s \
        "${TEST_HOME}/settings.patch.${poison_patch_case}.before.json" \
        "${poison_patch_repo}/config/settings.patch.json" \
      && printf true || printf false)"
  assert_eq "${poison_patch_case} installed settings bytes are preserved" \
    "true" \
    "$(cmp -s "${poison_patch_home}/settings.before.json" \
        "${poison_patch_home}/.claude/settings.json" \
      && printf true || printf false)"
  assert_eq "${poison_patch_case} installed bundle bytes are preserved" \
    "true" \
    "$(cmp -s "${poison_patch_home}/CLAUDE.before.md" \
        "${poison_patch_home}/.claude/CLAUDE.md" \
      && printf true || printf false)"
  assert_eq "${poison_patch_case} copies no new bundle" "false" \
    "$([[ -e "${poison_patch_home}/.claude/statusline.py" \
        || -e "${poison_patch_home}/.claude/quality-pack" ]] \
      && printf true || printf false)"
done

# ---------------------------------------------------------------------------
# Test 15: settings/source TOCTOU snapshots and rendered-stage seals
# ---------------------------------------------------------------------------
printf '15. Source snapshots and rendered-stage seals\n'

# The live patch becomes malformed after its verified copy is taken. Parsing
# must still reach the post-validation barrier using private A bytes; the
# final source re-attestation may then fail closed. EXIT cleanup owns the
# private snapshot on every outcome.
patch_race_repo="${TEST_HOME}/patch-race-repo"
patch_race_home="${TEST_HOME}/patch-race-home"
patch_snapshot_ready="${TEST_HOME}/install-patch-snapshot.ready"
patch_snapshot_release="${TEST_HOME}/install-patch-snapshot.release"
patch_validated_ready="${TEST_HOME}/install-patch-validated.ready"
patch_validated_release="${TEST_HOME}/install-patch-validated.release"
patch_race_out="${TEST_HOME}/install-patch-race.out"
mkdir -p "${patch_race_repo}" "${patch_race_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${patch_race_repo}/" >/dev/null
cp "${patch_race_repo}/config/settings.patch.json" \
  "${patch_race_repo}/config/settings.patch.saved.json"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_PATCH_SNAPSHOT_READY_FILE="${patch_snapshot_ready}" \
  OMC_TEST_INSTALL_PATCH_SNAPSHOT_RELEASE_FILE="${patch_snapshot_release}" \
  OMC_TEST_INSTALL_PATCH_VALIDATED_READY_FILE="${patch_validated_ready}" \
  OMC_TEST_INSTALL_PATCH_VALIDATED_RELEASE_FILE="${patch_validated_release}" \
  TARGET_HOME="${patch_race_home}" bash "${patch_race_repo}/install.sh" \
    >"${patch_race_out}" 2>&1
) &
patch_race_pid=$!
patch_snapshot_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${patch_snapshot_ready}" ]] \
    && { patch_snapshot_seen=1; break; }
  sleep 0.01
done
assert_eq "install patch race reaches private-snapshot barrier" "1" \
  "${patch_snapshot_seen}"
install_patch_snapshot="${TEST_HOME}/missing-install-patch-snapshot"
if [[ "${patch_snapshot_seen}" -eq 1 ]]; then
  install_patch_snapshot="$(head -1 \
    "${patch_snapshot_ready}" 2>/dev/null || true)"
  [[ -n "${install_patch_snapshot}" ]] \
    || install_patch_snapshot="${TEST_HOME}/missing-install-patch-snapshot"
  printf '%s\n' '{"hooks":42}' \
    >"${patch_race_repo}/config/settings.patch.json"
fi
: >"${patch_snapshot_release}"
patch_validated_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${patch_validated_ready}" ]] \
    && { patch_validated_seen=1; break; }
  sleep 0.01
done
assert_eq "malformed live patch cannot feed install validation" "1" \
  "${patch_validated_seen}"
assert_eq "install private snapshot retains approved patch" "high" \
  "$(jq -r '.effortLevel' "${install_patch_snapshot}" 2>/dev/null || true)"
cp "${patch_race_repo}/config/settings.patch.saved.json" \
  "${patch_race_repo}/config/settings.patch.json"
: >"${patch_validated_release}"
wait "${patch_race_pid}" || true
assert_eq "install EXIT trap removes private patch snapshot" "false" \
  "$([[ -e "${install_patch_snapshot}" || -L "${install_patch_snapshot}" ]] \
    && printf true || printf false)"

# Replace the private base after its pathname validation but before renderer
# descriptors open it. Descriptor identity alone is insufficient here: every
# descriptor could consistently open the replacement. The post-unlink hashes
# must bind them back to the sealed settings generation and reject the merge.
render_input_home="${TEST_HOME}/install-render-input-race-home"
render_input_ready="${TEST_HOME}/install-render-input.ready"
render_input_release="${TEST_HOME}/install-render-input.release"
render_input_out="${TEST_HOME}/install-render-input-race.out"
mkdir -p "${render_input_home}/.claude"
printf '%s\n' '{"userKey":"render-input-original"}' \
  > "${render_input_home}/.claude/settings.json"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_SETTINGS_RENDER_READY_FILE="${render_input_ready}" \
  OMC_TEST_INSTALL_SETTINGS_RENDER_RELEASE_FILE="${render_input_release}" \
  TARGET_HOME="${render_input_home}" bash "${REPO_ROOT}/install.sh" \
    >"${render_input_out}" 2>&1
) &
render_input_pid=$!
render_input_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${render_input_ready}" ]] \
    && { render_input_seen=1; break; }
  sleep 0.01
done
assert_eq "install render-input race reaches descriptor barrier" "1" \
  "${render_input_seen}"
render_input_path="${TEST_HOME}/missing-install-render-input"
if [[ "${render_input_seen}" -eq 1 ]]; then
  render_input_path="$(head -1 \
    "${render_input_ready}" 2>/dev/null || true)"
  printf '%s\n' '{"userKey":"attacker-render-input"}' \
    > "${render_input_path}"
fi
: >"${render_input_release}"
render_input_rc=0
wait "${render_input_pid}" || render_input_rc=$?
assert_eq "replaced private renderer input is refused" "1" \
  "${render_input_rc}"
assert_eq "renderer-input replacement preserves original settings" \
  "render-input-original" \
  "$(jq -r '.userKey // ""' \
    "${render_input_home}/.claude/settings.json" 2>/dev/null || true)"
assert_contains "renderer-input replacement refusal is explicit" \
  "render descriptors did not match their sealed inputs" \
  "$(<"${render_input_out}")"
assert_eq "installer cleans replaced private renderer input" "false" \
  "$([[ -e "${render_input_path}" || -L "${render_input_path}" ]] \
    && printf true || printf false)"

# Replace a fully-rendered settings stage after it has been sealed but before
# publication. The target must never receive attacker bytes, and EXIT cleanup
# must remove the rejected same-directory stage.
install_stage_home="${TEST_HOME}/install-stage-race-home"
install_stage_ready="${TEST_HOME}/install-stage.ready"
install_stage_release="${TEST_HOME}/install-stage.release"
install_stage_out="${TEST_HOME}/install-stage-race.out"
mkdir -p "${install_stage_home}/.claude"
printf '%s\n' '{"userKey":"keep"}' \
  >"${install_stage_home}/.claude/settings.json"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_SETTINGS_STAGE_READY_FILE="${install_stage_ready}" \
  OMC_TEST_INSTALL_SETTINGS_STAGE_RELEASE_FILE="${install_stage_release}" \
  TARGET_HOME="${install_stage_home}" bash "${REPO_ROOT}/install.sh" \
    >"${install_stage_out}" 2>&1
) &
install_stage_pid=$!
install_stage_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${install_stage_ready}" ]] \
    && { install_stage_seen=1; break; }
  sleep 0.01
done
assert_eq "install stage race reaches publication barrier" "1" \
  "${install_stage_seen}"
install_replaced_stage="${TEST_HOME}/missing-install-settings-stage"
if [[ "${install_stage_seen}" -eq 1 ]]; then
  install_replaced_stage="$(head -1 \
    "${install_stage_ready}" 2>/dev/null || true)"
fi
install_stage_payload_safe=false
if [[ -n "${install_replaced_stage}" \
    && -f "${install_replaced_stage}" \
    && ! -L "${install_replaced_stage}" ]]; then
  install_stage_payload_safe=true
  printf '%s\n' '{"attacker":true}' >"${install_replaced_stage}"
fi
assert_eq "install stage barrier identifies a regular stage" "true" \
  "${install_stage_payload_safe}"
: >"${install_stage_release}"
install_stage_rc=0
wait "${install_stage_pid}" || install_stage_rc=$?
assert_eq "replaced install settings stage is refused" "1" \
  "${install_stage_rc}"
assert_eq "replaced install stage preserves original settings" "keep" \
  "$(jq -r '.userKey // ""' \
      "${install_stage_home}/.claude/settings.json" 2>/dev/null || true)"
assert_eq "replaced install stage never publishes attacker bytes" "false" \
  "$(jq -r '.attacker // false' \
      "${install_stage_home}/.claude/settings.json" 2>/dev/null || true)"
assert_eq "install EXIT trap removes rejected settings stage" "false" \
  "$([[ -e "${install_replaced_stage}" || -L "${install_replaced_stage}" ]] \
    && printf true || printf false)"
assert_contains "install stage refusal is explicit" \
  "rendered settings stage was replaced or modified" \
  "$(<"${install_stage_out}")"

# Replacing a supported settings symlink with a new inode that names the same
# referent is still a concurrent lexical-generation change. Exact target text
# alone must not authorize publication through the replacement link.
install_link_home="${TEST_HOME}/install-link-race-home"
install_link_target="${TEST_HOME}/install-link-race-settings.json"
install_link_ready="${TEST_HOME}/install-link-race.ready"
install_link_release="${TEST_HOME}/install-link-race.release"
install_link_out="${TEST_HOME}/install-link-race.out"
mkdir -p "${install_link_home}/.claude"
printf '%s\n' '{"userKey":"same-target"}' > "${install_link_target}"
ln -s "${install_link_target}" "${install_link_home}/.claude/settings.json"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_SETTINGS_STAGE_READY_FILE="${install_link_ready}" \
  OMC_TEST_INSTALL_SETTINGS_STAGE_RELEASE_FILE="${install_link_release}" \
  TARGET_HOME="${install_link_home}" bash "${REPO_ROOT}/install.sh" \
    >"${install_link_out}" 2>&1
) &
install_link_pid=$!
install_link_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${install_link_ready}" ]] \
    && { install_link_seen=1; break; }
  sleep 0.01
done
assert_eq "install symlink race reaches publication barrier" "1" \
  "${install_link_seen}"
if [[ "${install_link_seen}" -eq 1 ]]; then
  rm -f -- "${install_link_home}/.claude/settings.json"
  ln -s "${install_link_target}" \
    "${install_link_home}/.claude/settings.json"
fi
: > "${install_link_release}"
install_link_rc=0
wait "${install_link_pid}" || install_link_rc=$?
assert_eq "same-target replacement settings symlink is refused" "1" \
  "${install_link_rc}"
assert_eq "same-target symlink race preserves referent bytes" "same-target" \
  "$(jq -r '.userKey // ""' "${install_link_target}" 2>/dev/null || true)"
assert_eq "same-target replacement symlink remains user-owned" \
  "${install_link_target}" \
  "$(readlink "${install_link_home}/.claude/settings.json" \
    2>/dev/null || true)"

# An initially absent generic publication parent is owned only after this
# invocation creates and seals its exact directory generation. Replacing the
# real omc-user directory with another real directory must not be blessed by
# allow_created_parent or receive the staged overrides template.
created_parent_home="${TEST_HOME}/created-parent-race-home"
created_parent_ready="${TEST_HOME}/created-parent-race.ready"
created_parent_release="${TEST_HOME}/created-parent-race.release"
mkdir -p "${created_parent_home}"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_GENERIC_STAGE_MATCH="${created_parent_home}/.claude/omc-user/overrides.md" \
  OMC_TEST_INSTALL_GENERIC_STAGE_READY_FILE="${created_parent_ready}" \
  OMC_TEST_INSTALL_GENERIC_STAGE_RELEASE_FILE="${created_parent_release}" \
  TARGET_HOME="${created_parent_home}" bash "${REPO_ROOT}/install.sh" \
    >/dev/null 2>&1
) &
created_parent_pid=$!
created_parent_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${created_parent_ready}" ]] \
    && { created_parent_seen=1; break; }
  sleep 0.01
done
assert_eq "created-parent race reaches generic publication barrier" "1" \
  "${created_parent_seen}"
if [[ "${created_parent_seen}" -eq 1 ]]; then
  mv "${created_parent_home}/.claude/omc-user" \
    "${created_parent_home}/.claude/.omc-user-held"
  mkdir "${created_parent_home}/.claude/omc-user"
  printf 'foreign-parent\n' \
    > "${created_parent_home}/.claude/omc-user/sentinel"
fi
: > "${created_parent_release}"
created_parent_rc=0
wait "${created_parent_pid}" || created_parent_rc=$?
assert_eq "same-type created-parent replacement aborts install" "1" \
  "${created_parent_rc}"
assert_eq "foreign created-parent winner survives rollback" \
  "foreign-parent" \
  "$(cat "${created_parent_home}/.claude/omc-user/sentinel" \
    2>/dev/null || true)"
assert_eq "foreign created parent receives no managed template" "false" \
  "$([[ -e "${created_parent_home}/.claude/omc-user/overrides.md" ]] \
    && printf true || printf false)"

# A -> B in the live checkout during copy -> A before re-attestation must never
# publish B. Copy consumes the immutable private generation, so the install may
# succeed, but destination bytes must remain the original A generation.
content_race_repo="${TEST_HOME}/content-race-repo"
content_race_home="${TEST_HOME}/content-race-home"
bundle_copy_ready="${TEST_HOME}/bundle-copy.ready"
bundle_copy_release="${TEST_HOME}/bundle-copy.release"
bundle_copied_ready="${TEST_HOME}/bundle-copied.ready"
bundle_copied_release="${TEST_HOME}/bundle-copied.release"
content_race_out="${TEST_HOME}/content-race.out"
mkdir -p "${content_race_repo}" "${content_race_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${content_race_repo}/" >/dev/null
cp "${content_race_repo}/bundle/dot-claude/CLAUDE.md" \
  "${content_race_repo}/CLAUDE.md.saved-test"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_BUNDLE_COPY_READY_FILE="${bundle_copy_ready}" \
  OMC_TEST_INSTALL_BUNDLE_COPY_RELEASE_FILE="${bundle_copy_release}" \
  OMC_TEST_INSTALL_BUNDLE_COPIED_READY_FILE="${bundle_copied_ready}" \
  OMC_TEST_INSTALL_BUNDLE_COPIED_RELEASE_FILE="${bundle_copied_release}" \
  TARGET_HOME="${content_race_home}" bash "${content_race_repo}/install.sh" \
    >"${content_race_out}" 2>&1
) &
content_race_pid=$!
bundle_copy_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${bundle_copy_ready}" ]] && { bundle_copy_seen=1; break; }
  sleep 0.01
done
assert_eq "content race reaches pre-copy barrier" "1" "${bundle_copy_seen}"
if [[ "${bundle_copy_seen}" -eq 1 ]]; then
  printf '%s\n' 'TRANSIENT-BYTES-MUST-NOT-BE-BLESSED' \
    >"${content_race_repo}/bundle/dot-claude/CLAUDE.md"
fi
: >"${bundle_copy_release}"
bundle_copied_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${bundle_copied_ready}" ]] \
    && { bundle_copied_seen=1; break; }
  sleep 0.01
done
assert_eq "content race reaches post-copy barrier" "1" \
  "${bundle_copied_seen}"
cp "${content_race_repo}/CLAUDE.md.saved-test" \
  "${content_race_repo}/bundle/dot-claude/CLAUDE.md"
: >"${bundle_copied_release}"
content_race_rc=0
wait "${content_race_pid}" || content_race_rc=$?
assert_eq "A-to-B-to-A live-source race cannot derail snapshot install" "0" \
  "${content_race_rc}"
assert_eq "snapshot copy publishes original A bytes, never transient B" "true" \
  "$(cmp -s "${content_race_repo}/CLAUDE.md.saved-test" \
      "${content_race_home}/.claude/CLAUDE.md" && printf true || printf false)"
assert_eq "successful snapshot generation is hash-manifested" "true" \
  "$([[ -s "${content_race_home}/.claude/quality-pack/state/installed-hashes.txt" ]] \
    && printf true || printf false)"

# Footer helpers are executable installer inputs too. Replace the live
# checkout helper after all managed publications but before final attestation:
# the private snapshot must never run replacement code, final sealing must
# abort, and no success/restart prose may precede rollback.
helper_race_repo="${TEST_HOME}/helper-race-repo"
helper_race_home="${TEST_HOME}/helper-race-home"
helper_final_ready="${TEST_HOME}/helper-final.ready"
helper_final_release="${TEST_HOME}/helper-final.release"
helper_race_out="${TEST_HOME}/helper-race.out"
helper_race_sentinel="${TEST_HOME}/helper-race.executed"
mkdir -p "${helper_race_repo}" "${helper_race_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${helper_race_repo}/" >/dev/null
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_FINAL_ATTEST_READY_FILE="${helper_final_ready}" \
  OMC_TEST_INSTALL_FINAL_ATTEST_RELEASE_FILE="${helper_final_release}" \
  TARGET_HOME="${helper_race_home}" bash "${helper_race_repo}/install.sh" \
    >"${helper_race_out}" 2>&1
) &
helper_race_pid=$!
helper_final_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${helper_final_ready}" ]] && { helper_final_seen=1; break; }
  sleep 0.01
done
assert_eq "helper replacement race reaches final attestation" "1" \
  "${helper_final_seen}"
if [[ "${helper_final_seen}" -eq 1 ]]; then
  printf '#!/usr/bin/env bash\nprintf "executed\\n" > %q\n' \
    "${helper_race_sentinel}" \
    > "${helper_race_repo}/tools/install-state-report.sh"
fi
: > "${helper_final_release}"
helper_race_rc=0
wait "${helper_race_pid}" || helper_race_rc=$?
assert_eq "live footer-helper replacement aborts final commit" "1" \
  "${helper_race_rc}"
assert_eq "replacement footer helper is never executed" "false" \
  "$([[ -e "${helper_race_sentinel}" ]] && printf true || printf false)"
assert_eq "failed final attestation emits no install-complete banner" "false" \
  "$([[ "$(<"${helper_race_out}")" == *'install complete'* ]] \
    && printf true || printf false)"
assert_eq "failed final attestation emits no restart guidance" "false" \
  "$([[ "$(<"${helper_race_out}")" == *'Restart Claude Code'* ]] \
    && printf true || printf false)"

# A private admitted-path list is authority too. Remove one row while the
# private source generation is copied, then restore the exact list bytes before
# verification. Exact snapshot node-set verification must still reject the
# transient omission (A -> B -> A).
list_race_repo="${TEST_HOME}/list-race-repo"
list_race_home="${TEST_HOME}/list-race-home"
list_ready="${TEST_HOME}/source-list.ready"
list_release="${TEST_HOME}/source-list.release"
snapshot_copied_ready="${TEST_HOME}/source-snapshot-copied.ready"
snapshot_copied_release="${TEST_HOME}/source-snapshot-copied.release"
list_race_out="${TEST_HOME}/list-race.out"
mkdir -p "${list_race_repo}" "${list_race_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${list_race_repo}/" >/dev/null
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_SOURCE_LIST_READY_FILE="${list_ready}" \
  OMC_TEST_INSTALL_SOURCE_LIST_RELEASE_FILE="${list_release}" \
  OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_READY_FILE="${snapshot_copied_ready}" \
  OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_RELEASE_FILE="${snapshot_copied_release}" \
  TARGET_HOME="${list_race_home}" bash "${list_race_repo}/install.sh" \
    >"${list_race_out}" 2>&1
) &
list_race_pid=$!
list_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${list_ready}" ]] && { list_seen=1; break; }
  sleep 0.01
done
assert_eq "file-list race reaches sealed-list barrier" "1" "${list_seen}"
list_private_path=""
list_saved="${TEST_HOME}/source-list.saved"
if [[ "${list_seen}" -eq 1 ]]; then
  list_private_path="$(head -1 "${list_ready}")"
  cp "${list_private_path}" "${list_saved}"
  tail -n +2 "${list_saved}" > "${TEST_HOME}/source-list.subset"
  chmod u+w "${list_private_path}"
  cp "${TEST_HOME}/source-list.subset" "${list_private_path}"
  chmod 400 "${list_private_path}"
fi
: > "${list_release}"
snapshot_copy_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${snapshot_copied_ready}" ]] \
    && { snapshot_copy_seen=1; break; }
  sleep 0.01
done
assert_eq "file-list race reaches copied-snapshot barrier" "1" \
  "${snapshot_copy_seen}"
if [[ "${snapshot_copy_seen}" -eq 1 ]]; then
  chmod u+w "${list_private_path}"
  cp "${list_saved}" "${list_private_path}"
  chmod 400 "${list_private_path}"
fi
: > "${snapshot_copied_release}"
list_race_rc=0
wait "${list_race_pid}" || list_race_rc=$?
assert_eq "A-to-B-to-A admitted-file-list race is refused" "1" \
  "${list_race_rc}"
assert_eq "file-list race copies no installed generation" "false" \
  "$([[ -e "${list_race_home}/.claude/statusline.py" ]] \
    && printf true || printf false)"

# Mode bits are part of the sealed source generation. A transient executable-
# bit flip while the private snapshot is copied must be detected even when the
# live source is restored before final re-attestation.
mode_race_repo="${TEST_HOME}/mode-race-repo"
mode_race_home="${TEST_HOME}/mode-race-home"
mode_list_ready="${TEST_HOME}/mode-source-list.ready"
mode_list_release="${TEST_HOME}/mode-source-list.release"
mode_snapshot_ready="${TEST_HOME}/mode-source-snapshot.ready"
mode_snapshot_release="${TEST_HOME}/mode-source-snapshot.release"
mkdir -p "${mode_race_repo}" "${mode_race_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${mode_race_repo}/" >/dev/null
mode_original="$(file_mode "${mode_race_repo}/bundle/dot-claude/CLAUDE.md")"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_SOURCE_LIST_READY_FILE="${mode_list_ready}" \
  OMC_TEST_INSTALL_SOURCE_LIST_RELEASE_FILE="${mode_list_release}" \
  OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_READY_FILE="${mode_snapshot_ready}" \
  OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_RELEASE_FILE="${mode_snapshot_release}" \
  TARGET_HOME="${mode_race_home}" bash "${mode_race_repo}/install.sh" \
    >/dev/null 2>&1
) &
mode_race_pid=$!
mode_list_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${mode_list_ready}" ]] && { mode_list_seen=1; break; }
  sleep 0.01
done
assert_eq "source-mode race reaches sealed-list barrier" "1" \
  "${mode_list_seen}"
if [[ "${mode_list_seen}" -eq 1 ]]; then
  chmod 755 "${mode_race_repo}/bundle/dot-claude/CLAUDE.md"
fi
: > "${mode_list_release}"
mode_snapshot_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${mode_snapshot_ready}" ]] && { mode_snapshot_seen=1; break; }
  sleep 0.01
done
assert_eq "source-mode race reaches copied-snapshot barrier" "1" \
  "${mode_snapshot_seen}"
if [[ "${mode_snapshot_seen}" -eq 1 ]]; then
  chmod "${mode_original}" \
    "${mode_race_repo}/bundle/dot-claude/CLAUDE.md"
fi
: > "${mode_snapshot_release}"
mode_race_rc=0
wait "${mode_race_pid}" || mode_race_rc=$?
assert_eq "A-to-B-to-A source-mode race is refused" "1" "${mode_race_rc}"
assert_eq "source-mode race copies no installed generation" "false" \
  "$([[ -e "${mode_race_home}/.claude/statusline.py" ]] \
    && printf true || printf false)"

# Publication is a same-directory staged CAS. A foreign leaf that appears
# after staging wins and survives rollback because the installer never owned
# that path.
leaf_race_home="${TEST_HOME}/destination-leaf-race-home"
leaf_ready="${TEST_HOME}/destination-leaf.ready"
leaf_release="${TEST_HOME}/destination-leaf.release"
leaf_external="${TEST_HOME}/destination-leaf-external"
mkdir -p "${leaf_race_home}" "${leaf_external}"
printf 'foreign-winner\n' > "${leaf_external}/winner"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_DESTINATION_STAGE_MATCH="${leaf_race_home}/.claude/CLAUDE.md" \
  OMC_TEST_INSTALL_DESTINATION_STAGE_READY_FILE="${leaf_ready}" \
  OMC_TEST_INSTALL_DESTINATION_STAGE_RELEASE_FILE="${leaf_release}" \
  TARGET_HOME="${leaf_race_home}" bash "${REPO_ROOT}/install.sh" \
    >/dev/null 2>&1
) &
leaf_race_pid=$!
leaf_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${leaf_ready}" ]] && { leaf_seen=1; break; }
  sleep 0.01
done
assert_eq "destination leaf race reaches publication barrier" "1" \
  "${leaf_seen}"
if [[ "${leaf_seen}" -eq 1 ]]; then
  ln -s "${leaf_external}/winner" \
    "${leaf_race_home}/.claude/CLAUDE.md"
fi
: > "${leaf_release}"
leaf_race_rc=0
wait "${leaf_race_pid}" || leaf_race_rc=$?
assert_eq "destination leaf winner aborts publication" "1" "${leaf_race_rc}"
assert_eq "destination leaf winner survives rollback" "true" \
  "$([[ -L "${leaf_race_home}/.claude/CLAUDE.md" ]] \
    && printf true || printf false)"
assert_eq "destination leaf winner bytes remain foreign" "foreign-winner" \
  "$(cat "${leaf_race_home}/.claude/CLAUDE.md")"

# A winner that arrives after publication with the same bytes and mode still
# has a foreign inode. The final generation attestation must reject it, and
# rollback must preserve that exact replacement instead of treating equal
# content as installer ownership.
published_race_home="${TEST_HOME}/destination-published-race-home"
published_ready="${TEST_HOME}/destination-published.ready"
published_release="${TEST_HOME}/destination-published.release"
mkdir -p "${published_race_home}"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_DESTINATION_PUBLISHED_MATCH="${published_race_home}/.claude/CLAUDE.md" \
  OMC_TEST_INSTALL_DESTINATION_PUBLISHED_READY_FILE="${published_ready}" \
  OMC_TEST_INSTALL_DESTINATION_PUBLISHED_RELEASE_FILE="${published_release}" \
  TARGET_HOME="${published_race_home}" bash "${REPO_ROOT}/install.sh" \
    >/dev/null 2>&1
) &
published_race_pid=$!
published_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${published_ready}" ]] && { published_seen=1; break; }
  sleep 0.01
done
assert_eq "post-publication race reaches ownership barrier" "1" \
  "${published_seen}"
published_winner_id=""
if [[ "${published_seen}" -eq 1 ]]; then
  cp -p "${published_race_home}/.claude/CLAUDE.md" \
    "${published_race_home}/.claude/.CLAUDE.md.foreign"
  mv -f "${published_race_home}/.claude/.CLAUDE.md.foreign" \
    "${published_race_home}/.claude/CLAUDE.md"
  published_winner_id="$(file_node_identity \
    "${published_race_home}/.claude/CLAUDE.md")"
fi
: > "${published_release}"
published_race_rc=0
wait "${published_race_pid}" || published_race_rc=$?
assert_eq "same-byte post-publication replacement aborts install" "1" \
  "${published_race_rc}"
published_actual_id="$(file_node_identity \
  "${published_race_home}/.claude/CLAUDE.md" 2>/dev/null || true)"
assert_eq "same-byte post-publication winner survives rollback by identity" \
  "${published_winner_id}" \
  "${published_actual_id}"

# Moving an already-published managed directory and replacing it with a
# symlink back to that exact tree preserves every leaf inode/hash/mode. The
# lexical ancestor generation still changed, so final publication validation
# must fail before model-tier chmod/rewrites can follow the alias.
ancestor_alias_home="${TEST_HOME}/destination-ancestor-alias-home"
ancestor_alias_ready="${TEST_HOME}/destination-ancestor-alias.ready"
ancestor_alias_release="${TEST_HOME}/destination-ancestor-alias.release"
mkdir -p "${ancestor_alias_home}"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_BUNDLE_COPIED_READY_FILE="${ancestor_alias_ready}" \
  OMC_TEST_INSTALL_BUNDLE_COPIED_RELEASE_FILE="${ancestor_alias_release}" \
  TARGET_HOME="${ancestor_alias_home}" bash "${REPO_ROOT}/install.sh" \
    --model-tier=quality >/dev/null 2>&1
) &
ancestor_alias_pid=$!
ancestor_alias_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${ancestor_alias_ready}" ]] \
    && { ancestor_alias_seen=1; break; }
  sleep 0.01
done
assert_eq "post-copy ancestor alias reaches final-generation barrier" "1" \
  "${ancestor_alias_seen}"
ancestor_alias_before=""
if [[ "${ancestor_alias_seen}" -eq 1 ]]; then
  ancestor_alias_before="$(cksum \
    < "${ancestor_alias_home}/.claude/agents/abstraction-critic.md")"
  mv "${ancestor_alias_home}/.claude/agents" \
    "${ancestor_alias_home}/.claude/.agents-held"
  ln -s .agents-held "${ancestor_alias_home}/.claude/agents"
fi
: > "${ancestor_alias_release}"
ancestor_alias_rc=0
wait "${ancestor_alias_pid}" || ancestor_alias_rc=$?
assert_eq "same-tree post-copy ancestor alias aborts install" "1" \
  "${ancestor_alias_rc}"
assert_eq "same-tree ancestor alias remains a concurrent winner" "true" \
  "$([[ -L "${ancestor_alias_home}/.claude/agents" ]] \
    && printf true || printf false)"
assert_eq "ancestor alias is rejected before model-tier mutation" \
  "${ancestor_alias_before}" \
  "$(cksum \
    < "${ancestor_alias_home}/.claude/.agents-held/abstraction-critic.md" \
    2>/dev/null || true)"

# Replacing an admitted ancestor with a symlink after staging must not redirect
# the final rename or any rollback cleanup into the foreign tree.
ancestor_race_home="${TEST_HOME}/destination-ancestor-race-home"
ancestor_ready="${TEST_HOME}/destination-ancestor.ready"
ancestor_release="${TEST_HOME}/destination-ancestor.release"
ancestor_external="${TEST_HOME}/destination-ancestor-external"
mkdir -p "${ancestor_race_home}" "${ancestor_external}"
printf 'external-sentinel\n' > "${ancestor_external}/sentinel"
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_DESTINATION_STAGE_MATCH="${ancestor_race_home}/.claude/agents/abstraction-critic.md" \
  OMC_TEST_INSTALL_DESTINATION_STAGE_READY_FILE="${ancestor_ready}" \
  OMC_TEST_INSTALL_DESTINATION_STAGE_RELEASE_FILE="${ancestor_release}" \
  TARGET_HOME="${ancestor_race_home}" bash "${REPO_ROOT}/install.sh" \
    >/dev/null 2>&1
) &
ancestor_race_pid=$!
ancestor_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${ancestor_ready}" ]] && { ancestor_seen=1; break; }
  sleep 0.01
done
assert_eq "destination ancestor race reaches publication barrier" "1" \
  "${ancestor_seen}"
if [[ "${ancestor_seen}" -eq 1 ]]; then
  mv "${ancestor_race_home}/.claude/agents" \
    "${ancestor_race_home}/.claude/.agents-held"
  ln -s "${ancestor_external}" "${ancestor_race_home}/.claude/agents"
fi
: > "${ancestor_release}"
ancestor_race_rc=0
wait "${ancestor_race_pid}" || ancestor_race_rc=$?
assert_eq "destination ancestor swap aborts publication" "1" \
  "${ancestor_race_rc}"
assert_eq "destination ancestor foreign tree remains untouched" \
  "external-sentinel" "$(cat "${ancestor_external}/sentinel")"
assert_eq "destination ancestor receives no managed leaf" "false" \
  "$([[ -e "${ancestor_external}/abstraction-critic.md" ]] \
    && printf true || printf false)"

# An interrupted tier writer may leave a durable WAL after its model/config
# publications. The installer must roll that generation back while holding the
# shared lock and before it snapshots or publishes any new bundle generation.
install_wal_home="${TEST_HOME}/install-tier-wal-home"
install_wal_switch_ready="${TEST_HOME}/install-tier-wal.switch-ready"
install_wal_settled_ready="${TEST_HOME}/install-tier-wal.settled-ready"
install_wal_settled_release="${TEST_HOME}/install-tier-wal.settled-release"
install_wal_out="${TEST_HOME}/install-tier-wal.out"
mkdir -p "${install_wal_home}/.claude/quality-pack"
cp -R "${REPO_ROOT}/bundle/dot-claude/agents" \
  "${install_wal_home}/.claude/agents"
printf 'pre-install-marker\n' \
  > "${install_wal_home}/.claude/quality-pack/marker"
printf 'model_tier=balanced\n' \
  > "${install_wal_home}/.claude/oh-my-claude.conf"
chmod 600 "${install_wal_home}/.claude/oh-my-claude.conf"
printf '{}\n' > "${install_wal_home}/.claude/settings.json"
(
  OMC_TEST_SWITCH_BARRIER_ENABLE=1 \
  OMC_TEST_SWITCH_POST_CONF_READY_FILE="${install_wal_switch_ready}" \
  OMC_TEST_SWITCH_POST_CONF_RELEASE_FILE="${install_wal_switch_ready}.release" \
  HOME="${install_wal_home}" \
    bash "${REPO_ROOT}/bundle/dot-claude/switch-tier.sh" quality \
    >/dev/null 2>&1
) &
install_wal_switch_pid=$!
install_wal_switch_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${install_wal_switch_ready}" ]] \
    && { install_wal_switch_seen=1; break; }
  kill -0 "${install_wal_switch_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "install WAL writer reaches pre-commit interruption" "1" \
  "${install_wal_switch_seen}"
if kill -0 "${install_wal_switch_pid}" 2>/dev/null; then
  kill -9 "${install_wal_switch_pid}" 2>/dev/null || true
fi
wait "${install_wal_switch_pid}" 2>/dev/null || true
rm -f -- "${install_wal_home}/.claude/.install.lock/pid" \
  "${install_wal_home}/.claude/.install.lock/token" 2>/dev/null || true
rmdir "${install_wal_home}/.claude/.install.lock" 2>/dev/null || true
(
  OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
  OMC_TEST_INSTALL_TX_SETTLED_READY_FILE="${install_wal_settled_ready}" \
  OMC_TEST_INSTALL_TX_SETTLED_RELEASE_FILE="${install_wal_settled_release}" \
  TARGET_HOME="${install_wal_home}" bash "${REPO_ROOT}/install.sh" \
    >"${install_wal_out}" 2>&1
) &
install_wal_pid=$!
install_wal_settled_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${install_wal_settled_ready}" ]] \
    && { install_wal_settled_seen=1; break; }
  kill -0 "${install_wal_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "install settles tier WAL before bundle publication" "1" \
  "${install_wal_settled_seen}"
assert_eq "install WAL recovery restores pre-switch tier" \
  "model_tier=balanced" \
  "$(grep '^model_tier=' \
    "${install_wal_home}/.claude/oh-my-claude.conf" 2>/dev/null || true)"
assert_eq "install WAL recovery precedes new bundle writes" "false" \
  "$([[ -e "${install_wal_home}/.claude/statusline.py" ]] \
    && printf true || printf false)"
assert_eq "install retires the interrupted tier WAL" "false" \
  "$([[ -e "${install_wal_home}/.claude/.switch-tier-transaction" \
      || -L "${install_wal_home}/.claude/.switch-tier-transaction" ]] \
    && printf true || printf false)"
: > "${install_wal_settled_release}"
install_wal_rc=0
wait "${install_wal_pid}" || install_wal_rc=$?
assert_eq "install completes after tier WAL settlement" "0" \
  "${install_wal_rc}"

# A receipt-publication failure occurs before any managed destination write.
# The installer may remove only its exact empty fixed generation; doing so
# keeps a transient local failure retryable without weakening the malformed or
# nonempty fail-closed startup branch.
install_receipt_fail_home="${TEST_HOME}/install-fixed-wal-publish-failure-home"
install_receipt_fail_out="${TEST_HOME}/install-fixed-wal-publish-failure.out"
mkdir -p "${install_receipt_fail_home}/.claude"
printf 'pre-receipt-managed-bytes\n' \
  > "${install_receipt_fail_home}/.claude/CLAUDE.md"
install_receipt_fail_rc=0
OMC_TEST_INSTALL_FAIL_DURABLE_RECEIPT_PUBLICATION=1 \
TARGET_HOME="${install_receipt_fail_home}" bash "${REPO_ROOT}/install.sh" \
  >"${install_receipt_fail_out}" 2>&1 || install_receipt_fail_rc=$?
assert_eq "injected fixed-receipt publication failure aborts install" "1" \
  "${install_receipt_fail_rc}"
assert_eq "pre-receipt failure changes no managed destination" \
  "pre-receipt-managed-bytes" \
  "$(cat "${install_receipt_fail_home}/.claude/CLAUDE.md")"
assert_eq "pre-receipt failure retires only its exact empty generation" \
  "false" \
  "$([[ -e "${install_receipt_fail_home}/.claude/.install-transaction" \
      || -L "${install_receipt_fail_home}/.claude/.install-transaction" ]] \
    && printf true || printf false)"
install_receipt_retry_rc=0
TARGET_HOME="${install_receipt_fail_home}" bash "${REPO_ROOT}/install.sh" \
  >/dev/null 2>&1 || install_receipt_retry_rc=$?
assert_eq "install retries successfully after empty receipt failure" "0" \
  "${install_receipt_retry_rc}"
assert_eq "successful receipt-failure retry leaves no fixed metadata" \
  "false" \
  "$([[ -e "${install_receipt_fail_home}/.claude/.install-transaction" \
      || -L "${install_receipt_fail_home}/.claude/.install-transaction" ]] \
    && printf true || printf false)"

# A hard death after the first managed destination publication cannot run the
# EXIT rollback. The fixed prepared receipt must therefore survive, name the
# exact pre-install backup, and make the next installer refuse before it can
# snapshot the half-published generation as a new baseline.
install_crash_home="${TEST_HOME}/install-fixed-wal-prepared-home"
install_crash_ready="${TEST_HOME}/install-fixed-wal-prepared.ready"
install_crash_release="${TEST_HOME}/install-fixed-wal-prepared.release"
install_crash_out="${TEST_HOME}/install-fixed-wal-prepared.out"
install_crash_retry_out="${TEST_HOME}/install-fixed-wal-prepared-retry.out"
install_crash_live_snapshot="${TEST_HOME}/install-fixed-wal-live-claude.md"
install_crash_receipt="${install_crash_home}/.claude/.install-transaction/receipt.json"
mkdir -p "${install_crash_home}/.claude"
printf 'pre-crash-managed-bytes\n' \
  > "${install_crash_home}/.claude/CLAUDE.md"
printf '%s\n' '{"userKey":"pre-crash"}' \
  > "${install_crash_home}/.claude/settings.json"
OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
OMC_TEST_INSTALL_DESTINATION_PUBLISHED_MATCH='CLAUDE.md' \
OMC_TEST_INSTALL_DESTINATION_PUBLISHED_READY_FILE="${install_crash_ready}" \
OMC_TEST_INSTALL_DESTINATION_PUBLISHED_RELEASE_FILE="${install_crash_release}" \
TARGET_HOME="${install_crash_home}" bash "${REPO_ROOT}/install.sh" \
  >"${install_crash_out}" 2>&1 &
install_crash_pid=$!
install_crash_seen=0
for _wait in $(seq 1 1000); do
  [[ -e "${install_crash_ready}" ]] \
    && { install_crash_seen=1; break; }
  kill -0 "${install_crash_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "hard-kill install reaches managed-publication barrier" "1" \
  "${install_crash_seen}"
install_crash_backup=""
install_crash_backup_count_before="0"
if [[ "${install_crash_seen}" -eq 1 ]]; then
  install_crash_backup="$(jq -r '.backup_dir // empty' \
    "${install_crash_receipt}" 2>/dev/null || true)"
  install_crash_backup_count_before="$(find \
    "${install_crash_home}/.claude/backups" -maxdepth 1 -type d \
    -name 'oh-my-claude-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
  cp "${install_crash_home}/.claude/CLAUDE.md" \
    "${install_crash_live_snapshot}"
fi
assert_eq "hard-kill receipt is prepared before managed publication returns" \
  "prepared" \
  "$(jq -r '.phase // empty' "${install_crash_receipt}" \
    2>/dev/null || true)"
assert_eq "hard-kill receipt names a retained pre-install backup" \
  "pre-crash-managed-bytes" \
  "$(if [[ -n "${install_crash_backup}" ]]; then \
      cat "${install_crash_backup}/CLAUDE.md" 2>/dev/null || true; \
    fi)"
assert_eq "hard-kill point has published a new managed generation" "false" \
  "$(grep -qx 'pre-crash-managed-bytes' \
      "${install_crash_home}/.claude/CLAUDE.md" 2>/dev/null \
    && printf true || printf false)"
if kill -0 "${install_crash_pid}" 2>/dev/null; then
  kill -9 "${install_crash_pid}" 2>/dev/null || true
fi
wait "${install_crash_pid}" 2>/dev/null || true
rm -f -- "${install_crash_home}/.claude/.install.lock/pid" \
  "${install_crash_home}/.claude/.install.lock/token" 2>/dev/null || true
rmdir "${install_crash_home}/.claude/.install.lock" 2>/dev/null || true
install_crash_retry_rc=0
TARGET_HOME="${install_crash_home}" bash "${REPO_ROOT}/install.sh" \
  >"${install_crash_retry_out}" 2>&1 || install_crash_retry_rc=$?
install_crash_backup_count_after="$(find \
  "${install_crash_home}/.claude/backups" -maxdepth 1 -type d \
  -name 'oh-my-claude-*' 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "prepared hard-kill receipt blocks the next install" "1" \
  "${install_crash_retry_rc}"
assert_eq "prepared hard-kill refusal creates no new baseline backup" \
  "${install_crash_backup_count_before}" \
  "${install_crash_backup_count_after}"
assert_eq "prepared hard-kill refusal preserves half-published bytes" "true" \
  "$(cmp -s "${install_crash_live_snapshot}" \
      "${install_crash_home}/.claude/CLAUDE.md" \
    && printf true || printf false)"
assert_eq "prepared hard-kill receipt remains discoverable after refusal" \
  "prepared" \
  "$(jq -r '.phase // empty' "${install_crash_receipt}" \
    2>/dev/null || true)"
assert_eq "prepared hard-kill refusal preserves exact recovery authority" \
  "${install_crash_backup}" \
  "$(jq -r '.backup_dir // empty' "${install_crash_receipt}" \
    2>/dev/null || true)"
install_crash_retry_text="$(cat "${install_crash_retry_out}")"
assert_contains "prepared refusal explains interrupted transaction" \
  "an interrupted install transaction is still prepared" \
  "${install_crash_retry_text}"
assert_contains "prepared refusal names exact recovery backup" \
  "Recovery backup: ${install_crash_backup}" \
  "${install_crash_retry_text}"
assert_contains "prepared refusal occurs before any new snapshot" \
  "before any new managed snapshot is taken" \
  "${install_crash_retry_text}"

# A hard death after the durable commit marker is different: the installed
# generation already passed final attestation. The next startup may retire
# that terminal metadata and continue normally.
install_commit_home="${TEST_HOME}/install-fixed-wal-committed-home"
install_commit_ready="${TEST_HOME}/install-fixed-wal-committed.ready"
install_commit_release="${TEST_HOME}/install-fixed-wal-committed.release"
install_commit_out="${TEST_HOME}/install-fixed-wal-committed.out"
install_commit_retry_out="${TEST_HOME}/install-fixed-wal-committed-retry.out"
install_commit_receipt="${install_commit_home}/.claude/.install-transaction/receipt.json"
mkdir -p "${install_commit_home}"
OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
OMC_TEST_INSTALL_COMMIT_MARKED_READY_FILE="${install_commit_ready}" \
OMC_TEST_INSTALL_COMMIT_MARKED_RELEASE_FILE="${install_commit_release}" \
TARGET_HOME="${install_commit_home}" bash "${REPO_ROOT}/install.sh" \
  >"${install_commit_out}" 2>&1 &
install_commit_pid=$!
install_commit_seen=0
for _wait in $(seq 1 2000); do
  [[ -e "${install_commit_ready}" ]] \
    && { install_commit_seen=1; break; }
  kill -0 "${install_commit_pid}" 2>/dev/null || break
  sleep 0.01
done
assert_eq "hard-kill install reaches durable-commit barrier" "1" \
  "${install_commit_seen}"
assert_eq "durable-commit barrier exposes committed receipt" "committed" \
  "$(jq -r '.phase // empty' "${install_commit_receipt}" \
    2>/dev/null || true)"
if kill -0 "${install_commit_pid}" 2>/dev/null; then
  kill -9 "${install_commit_pid}" 2>/dev/null || true
fi
wait "${install_commit_pid}" 2>/dev/null || true
rm -f -- "${install_commit_home}/.claude/.install.lock/pid" \
  "${install_commit_home}/.claude/.install.lock/token" 2>/dev/null || true
rmdir "${install_commit_home}/.claude/.install.lock" 2>/dev/null || true
install_commit_retry_rc=0
TARGET_HOME="${install_commit_home}" bash "${REPO_ROOT}/install.sh" \
  >"${install_commit_retry_out}" 2>&1 || install_commit_retry_rc=$?
assert_eq "committed hard-kill receipt permits the next install" "0" \
  "${install_commit_retry_rc}"
assert_contains "next install reports terminal receipt recovery" \
  "Recovered terminal install transaction metadata (committed)." \
  "$(cat "${install_commit_retry_out}")"
assert_eq "next install retires fixed committed metadata" "false" \
  "$([[ -e "${install_commit_home}/.claude/.install-transaction" \
      || -L "${install_commit_home}/.claude/.install-transaction" ]] \
    && printf true || printf false)"

# A foreign or symlinked fixed authority is never followed or replaced. This
# refusal also happens before allocation of a timestamped backup.
install_tx_symlink_home="${TEST_HOME}/install-fixed-wal-symlink-home"
install_tx_symlink_external="${TEST_HOME}/install-fixed-wal-symlink-external"
mkdir -p "${install_tx_symlink_home}/.claude" \
  "${install_tx_symlink_external}"
printf 'external-transaction-sentinel\n' \
  > "${install_tx_symlink_external}/sentinel"
ln -s "${install_tx_symlink_external}" \
  "${install_tx_symlink_home}/.claude/.install-transaction"
install_tx_symlink_rc=0
install_tx_symlink_out="$(TARGET_HOME="${install_tx_symlink_home}" \
  bash "${REPO_ROOT}/install.sh" 2>&1)" || install_tx_symlink_rc=$?
assert_eq "symlinked fixed install transaction is refused" "1" \
  "${install_tx_symlink_rc}"
assert_contains "symlinked fixed transaction refusal names unsafe metadata" \
  "fixed install transaction metadata is unsafe or malformed" \
  "${install_tx_symlink_out}"
assert_eq "symlinked fixed transaction target remains untouched" \
  "external-transaction-sentinel" \
  "$(cat "${install_tx_symlink_external}/sentinel")"
assert_eq "symlinked fixed transaction refusal allocates no backup" "0" \
  "$(if [[ -d "${install_tx_symlink_home}/.claude/backups" ]]; then \
      find "${install_tx_symlink_home}/.claude/backups" -maxdepth 1 \
        -type d -name 'oh-my-claude-*' 2>/dev/null \
        | wc -l | tr -d '[:space:]'; \
    else \
      printf '0'; \
    fi)"

# A backslash is not a portable manifest separator: coreutils checksum
# manifests escape it, so admitting such a source would mint an install that
# verify.sh immediately rejects.
backslash_repo="${TEST_HOME}/backslash-source-repo"
backslash_home="${TEST_HOME}/backslash-source-home"
mkdir -p "${backslash_repo}" "${backslash_home}"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${backslash_repo}/" >/dev/null
printf 'unsafe portable manifest name\n' \
  > "${backslash_repo}/bundle/dot-claude/back\\slash.md"
backslash_rc=0
TARGET_HOME="${backslash_home}" bash "${backslash_repo}/install.sh" \
  >/dev/null 2>&1 || backslash_rc=$?
assert_eq "backslash source path is refused" "1" "${backslash_rc}"
assert_eq "backslash source refusal copies no bundle" "false" \
  "$([[ -e "${backslash_home}/.claude/statusline.py" ]] \
    && printf true || printf false)"

# Transaction seals are authority, not whitespace-tolerant config. Exercise
# the installer's actual bounded reader with byte patterns that command
# substitution/trimming used to normalize into a valid enum or identity.
eval "$(sed -n \
  '/^install_metadata_file_is_canonical()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
eval "$(sed -n \
  '/^install_read_canonical_metadata_snapshot()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
eval "$(sed -n \
  '/^install_read_canonical_metadata_line()/,/^}/p' \
  "${REPO_ROOT}/install.sh")"
install_metadata_probe="${TEST_HOME}/install-metadata-probe"
printf 'regular\n' > "${install_metadata_probe}"
assert_eq "canonical install transaction enum is readable" "regular" \
  "$(install_read_canonical_metadata_line "${install_metadata_probe}" 32)"
printf 'regular\000\n' > "${install_metadata_probe}"
assert_eq "raw-NUL install transaction enum is rejected" "rejected" \
  "$(if install_read_canonical_metadata_line \
      "${install_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf 'regular\n\n' > "${install_metadata_probe}"
assert_eq "extra blank install transaction enum is rejected" "rejected" \
  "$(if install_read_canonical_metadata_line \
      "${install_metadata_probe}" 32 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf '1:2\tregular\t3:4\t%s\t600\t\n' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  > "${install_metadata_probe}"
assert_eq "canonical install transaction history is byte-stable" "accepted" \
  "$(if install_metadata_file_is_canonical \
      "${install_metadata_probe}" 4096 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"
printf '\n' >> "${install_metadata_probe}"
assert_eq "trailing blank install transaction history is rejected" "rejected" \
  "$(if install_metadata_file_is_canonical \
      "${install_metadata_probe}" 4096 >/dev/null 2>&1; then \
      printf accepted; else printf rejected; fi)"

printf '\n'

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf '=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
