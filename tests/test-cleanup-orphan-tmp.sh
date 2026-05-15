#!/usr/bin/env bash
#
# Regression net for bundle/dot-claude/quality-pack/scripts/cleanup-orphan-tmp.sh.
#
# The script sweeps stale `/tmp/omc-*` paths left by test helpers
# (sterile-env mostly) that don't trap cleanup. The hot path runs
# `stat` + `rm`; these tests redirect the script's tmp-root at runtime
# via a sandbox directory and a wrapper shim so the real `/tmp/` is
# never touched. Each test fixture creates synthetic paths in the
# sandbox, drives the cleanup script (wrapped to point at the sandbox
# as its `_tmp_root`), and asserts on what remains.
#
# Coverage axes:
#   - empty directory: clean no-op
#   - non-omc-prefixed paths are never touched
#   - old omc-* directory is removed
#   - old omc-* file is removed
#   - recent omc-* preserved (mtime newer than threshold)
#   - env override OMC_ORPHAN_TMP_MAX_AGE_HOURS applies
#   - cleanup_orphan_tmp=off skips entirely
#   - hard-cap of 100 removals respected on synthetic 105-path set
#   - script exits 0 when no candidates exist
#   - file types: directory, regular file, symlink all handled

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/cleanup-orphan-tmp.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# Install a stub HOME so the script's `. ${HOME}/.claude/skills/.../common.sh`
# resolves to the source repo's common.sh.
export HOME="${TMPDIR_TEST}/fake-home"
mkdir -p "${HOME}/.claude/skills/autowork/scripts" "${HOME}/.claude/quality-pack"
ln -sf "${COMMON_SH}" "${HOME}/.claude/skills/autowork/scripts/common.sh"
if [[ -d "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib" ]]; then
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib" \
    "${HOME}/.claude/skills/autowork/scripts/lib"
fi

# The script hardcodes `_tmp_root="/tmp"`. For tests we substitute it
# at run time by copying the script into a sandbox and patching the
# literal `/tmp` path to a per-test sandbox dir. This keeps the real
# script unchanged while letting tests run hermetically.
SANDBOX_TMP="${TMPDIR_TEST}/sandbox-tmp"
mkdir -p "${SANDBOX_TMP}"

# Build a per-test copy of the script with `_tmp_root` patched to the
# sandbox. Done once per test inside `setup_test` so each test can use
# a fresh sandbox if needed.
PATCHED_SCRIPT="${TMPDIR_TEST}/cleanup-orphan-tmp-sandboxed.sh"
sed "s|_tmp_root=\"/tmp\"|_tmp_root=\"${SANDBOX_TMP}\"|" "${SOURCE_SCRIPT}" >"${PATCHED_SCRIPT}"
chmod +x "${PATCHED_SCRIPT}"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

reset_sandbox() {
  rm -rf "${SANDBOX_TMP}"
  mkdir -p "${SANDBOX_TMP}"
}

count_remaining() {
  shopt -s nullglob
  local items=( "${SANDBOX_TMP}"/* )
  shopt -u nullglob
  printf '%s' "${#items[@]}"
}

# Make a path with a specific age (mtime = now - hours*3600).
mk_old_dir() {
  local name="$1" age_hours="$2"
  local p="${SANDBOX_TMP}/${name}"
  mkdir -p "${p}"
  touch -t "$(date -v -"${age_hours}"H +%Y%m%d%H%M 2>/dev/null || date -d "-${age_hours} hours" +%Y%m%d%H%M)" "${p}" 2>/dev/null || true
}

mk_old_file() {
  local name="$1" age_hours="$2"
  local p="${SANDBOX_TMP}/${name}"
  : >"${p}"
  touch -t "$(date -v -"${age_hours}"H +%Y%m%d%H%M 2>/dev/null || date -d "-${age_hours} hours" +%Y%m%d%H%M)" "${p}" 2>/dev/null || true
}

mk_recent_dir() {
  local name="$1"
  mkdir -p "${SANDBOX_TMP}/${name}"
}

# --------------------------------------------------------------------
# Test 1 — empty sandbox: clean no-op, exit 0
# --------------------------------------------------------------------
printf 'Test 1: empty sandbox → no-op\n'
reset_sandbox
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 1: zero items remain" "0" "$(count_remaining)"

# --------------------------------------------------------------------
# Test 2 — non-omc-prefixed paths are NEVER touched
# --------------------------------------------------------------------
printf 'Test 2: non-omc paths preserved\n'
reset_sandbox
mk_old_dir "my-work-dir" 100
mk_old_file "important.json" 100
mk_old_dir "session-data" 100
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 2: all 3 non-omc items preserved" "3" "$(count_remaining)"

# --------------------------------------------------------------------
# Test 3 — old omc-* directory removed
# --------------------------------------------------------------------
printf 'Test 3: old omc-* directory removed\n'
reset_sandbox
mk_old_dir "omc-sterile-tmp-AAAA" 100
mk_old_dir "omc-sterile-home-BBBB" 100
mk_old_dir "regular-work" 100
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 3: only non-omc remains" "1" "$(count_remaining)"
[[ -d "${SANDBOX_TMP}/regular-work" ]] && pass=$((pass + 1)) || { printf '  FAIL: regular-work was removed\n' >&2; fail=$((fail + 1)); }

# --------------------------------------------------------------------
# Test 4 — old omc-* file removed
# --------------------------------------------------------------------
printf 'Test 4: old omc-* file removed\n'
reset_sandbox
mk_old_file "omc-findings.json" 100
mk_old_file "omc-report.txt" 100
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 4: both omc files removed" "0" "$(count_remaining)"

# --------------------------------------------------------------------
# Test 5 — recent omc-* preserved
# --------------------------------------------------------------------
printf 'Test 5: recent omc-* preserved (within threshold)\n'
reset_sandbox
mk_recent_dir "omc-sterile-tmp-RECENT"
mk_old_dir "omc-sterile-tmp-OLD" 100
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 5: recent preserved, old removed" "1" "$(count_remaining)"
[[ -d "${SANDBOX_TMP}/omc-sterile-tmp-RECENT" ]] && pass=$((pass + 1)) || { printf '  FAIL: RECENT was removed\n' >&2; fail=$((fail + 1)); }

# --------------------------------------------------------------------
# Test 6 — OMC_ORPHAN_TMP_MAX_AGE_HOURS env override applies
# --------------------------------------------------------------------
printf 'Test 6: env max-age override\n'
reset_sandbox
mk_old_dir "omc-2h" 2   # 2h < default 24h
# Default 24h would NOT remove a 2h dir.
# Override to 1h SHOULD remove.
OMC_ORPHAN_TMP_MAX_AGE_HOURS=1 bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 6: 2h dir removed with 1h threshold" "0" "$(count_remaining)"

# --------------------------------------------------------------------
# Test 7 — cleanup_orphan_tmp=off → no removals even on old items
# --------------------------------------------------------------------
printf 'Test 7: cleanup_orphan_tmp=off → no removals\n'
reset_sandbox
mk_old_dir "omc-old" 100
OMC_CLEANUP_ORPHAN_TMP=off bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
assert_eq "Test 7: opt-out respected" "1" "$(count_remaining)"

# --------------------------------------------------------------------
# Test 8 — hard cap of 100 removals
# --------------------------------------------------------------------
printf 'Test 8: hard cap of 100 respected on 105 candidates\n'
reset_sandbox
for i in $(seq 1 105); do
  mk_old_dir "omc-mass-${i}" 100
done
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
remaining="$(count_remaining)"
# After cap, exactly 5 should remain (105 candidates - 100 cap).
assert_eq "Test 8: 5 remain after hard-cap" "5" "${remaining}"

# --------------------------------------------------------------------
# Test 9 — file/dir/symlink mix
# --------------------------------------------------------------------
printf 'Test 9: file + dir + symlink all handled\n'
reset_sandbox
mk_old_dir "omc-dir" 100
mk_old_file "omc-file" 100
# Make a symlink to a real path outside; the sweep should remove the
# symlink, NOT the link target. Target a path outside sandbox so the
# test verifies link-only deletion.
external_target="${TMPDIR_TEST}/external-target"
mkdir -p "${external_target}"
ln -s "${external_target}" "${SANDBOX_TMP}/omc-symlink"
# Backdate the symlink (-h on macOS, --no-dereference on GNU). If
# neither flag is supported, the symlink may stay fresh and be
# preserved by the age check — that's an acceptable platform skew.
touch -h -t "$(date -v -100H +%Y%m%d%H%M 2>/dev/null || date -d '-100 hours' +%Y%m%d%H%M)" "${SANDBOX_TMP}/omc-symlink" 2>/dev/null || true
bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1
# omc-dir, omc-file, omc-symlink (if backdate worked) → all gone.
# external-target survives.
[[ -d "${external_target}" ]] && pass=$((pass + 1)) || { printf '  FAIL: external target deleted via symlink\n' >&2; fail=$((fail + 1)); }
[[ ! -d "${SANDBOX_TMP}/omc-dir" ]] && pass=$((pass + 1)) || { printf '  FAIL: omc-dir not removed\n' >&2; fail=$((fail + 1)); }
[[ ! -f "${SANDBOX_TMP}/omc-file" ]] && pass=$((pass + 1)) || { printf '  FAIL: omc-file not removed\n' >&2; fail=$((fail + 1)); }

# --------------------------------------------------------------------
# Test 10 — non-existent tmp-root (script's sandbox dir gone)
# --------------------------------------------------------------------
printf 'Test 10: missing tmp-root → clean no-op\n'
rm -rf "${SANDBOX_TMP}"
if bash "${PATCHED_SCRIPT}" </dev/null >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  printf '  FAIL: nonzero exit on missing tmp-root\n' >&2
  fail=$((fail + 1))
fi
mkdir -p "${SANDBOX_TMP}"

# --------------------------------------------------------------------
# Results
# --------------------------------------------------------------------
printf '\n=== cleanup-orphan-tmp tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
exit "${fail}"
