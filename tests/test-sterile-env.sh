#!/usr/bin/env bash
#
# tests/test-sterile-env.sh — regression net for tests/lib/sterile-env.sh
# and tests/run-sterile.sh.
#
# v1.32.3 (gap 2 closure): the sterile-env helper became load-bearing
# in v1.32.2 when run-sterile.sh promoted from advisory → strict +
# CI-pinned. Without a dedicated test, the v1.32.2 fixes
# (STATE_ROOT/SESSION_ID removal, /sbin PATH addition) could regress
# in any future edit and only surface when one of the 7 affected
# tests starts failing under sterile env — exactly the diffuse-blast-
# radius shape the helper exists to prevent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' \
      "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# ----------------------------------------------------------------------
# Test 1: build_sterile_env output shape
# ----------------------------------------------------------------------
printf 'Test 1: build_sterile_env output shape\n'

# shellcheck source=lib/sterile-env.sh
. "${REPO_ROOT}/tests/lib/sterile-env.sh"
env_out="$(build_sterile_env)"

assert_contains "T1: contains HOME=" "HOME=" "${env_out}"
assert_contains "T1: contains TMPDIR=" "TMPDIR=" "${env_out}"
assert_contains "T1: contains PATH=" "PATH=" "${env_out}"
assert_contains "T1: contains TERM=" "TERM=" "${env_out}"
assert_contains "T1: contains LANG=" "LANG=" "${env_out}"
assert_contains "T1: contains LC_ALL=" "LC_ALL=" "${env_out}"
assert_contains "T1: contains GIT_AUTHOR_NAME=" "GIT_AUTHOR_NAME=" "${env_out}"

# v1.32.2 R9 closure: STATE_ROOT and SESSION_ID must NOT be pre-set —
# the harness's common.sh derives STATE_ROOT from
# ${HOME}/.claude/quality-pack/state when unset; pre-setting collides
# with that derivation and breaks 7 tests that compute state paths
# from HOME.
assert_not_contains "T1: NO STATE_ROOT (R9 fix)" "STATE_ROOT=" "${env_out}"
assert_not_contains "T1: NO SESSION_ID (R9 fix)" "SESSION_ID=" "${env_out}"

# ----------------------------------------------------------------------
# Test 2: PATH composition includes /sbin (macOS md5)
# ----------------------------------------------------------------------
printf 'Test 2: PATH composition includes /sbin\n'

path_line="$(printf '%s\n' "${env_out}" | grep '^PATH=' | head -1)"
assert_contains "T2: PATH includes /sbin (macOS md5)" "/sbin" "${path_line}"
assert_contains "T2: PATH includes /usr/bin (linux md5sum)" "/usr/bin" "${path_line}"
assert_contains "T2: PATH includes /bin (POSIX core)" "/bin" "${path_line}"

# ----------------------------------------------------------------------
# Test 3: jq-dir auto-detection
# ----------------------------------------------------------------------
printf 'Test 3: jq-dir auto-detection\n'

# When jq is available on dev shell, build_sterile_env must prefix its
# directory so sterile-PATH still finds the same jq. macOS dev typically
# has jq at /opt/homebrew/bin/jq; CI Ubuntu has it at /usr/bin/jq.
jq_path="$(command -v jq 2>/dev/null || true)"
if [[ -n "${jq_path}" ]]; then
  jq_dir="$(dirname "${jq_path}")"
  assert_contains "T3: PATH includes jq's dir (${jq_dir})" "${jq_dir}" "${path_line}"
else
  printf '  T3: jq not in dev PATH — skipping (CI without jq is a separate failure mode)\n'
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
# Test 4: run-sterile.sh env-var precedence (v1.32.3 gap 1 fix)
# ----------------------------------------------------------------------
printf 'Test 4: run-sterile.sh env-var precedence with both flags set\n'

# Both flags set → ADVISORY wins (matches CLI flag --advisory) AND a
# warning fires on stderr. Pre-1.32.3 the order silently degraded
# strict → advisory without warning if both were set.
# Note: `| head -N` inside `$()` raises SIGPIPE (exit 141) when the
# upstream is still writing — kills the test under `set -e`. Capture
# full output then grep is the correct shape.
out="$(OMC_STERILE_STRICT=1 OMC_STERILE_ADVISORY=1 \
  bash "${REPO_ROOT}/tests/run-sterile.sh" --only test-state-io.sh 2>&1)"

assert_contains "T4: warn fires when both flags set" "warn:" "${out}"
assert_contains "T4: warn names both flags" "OMC_STERILE_ADVISORY" "${out}"
assert_contains "T4: warn names both flags" "OMC_STERILE_STRICT" "${out}"
assert_contains "T4: mode resolves to advisory" "mode: advisory" "${out}"

# Only STRICT=1 → strict (backward-compat path)
out_strict="$(OMC_STERILE_STRICT=1 bash "${REPO_ROOT}/tests/run-sterile.sh" --only test-state-io.sh 2>&1)"
assert_contains "T4: STRICT=1 alone resolves to strict" "mode: strict" "${out_strict}"

# Only ADVISORY=1 → advisory
out_adv="$(OMC_STERILE_ADVISORY=1 bash "${REPO_ROOT}/tests/run-sterile.sh" --only test-state-io.sh 2>&1)"
assert_contains "T4: ADVISORY=1 alone resolves to advisory" "mode: advisory" "${out_adv}"

# Neither set → strict (v1.32.2 default)
unset OMC_STERILE_STRICT OMC_STERILE_ADVISORY
out_default="$(bash "${REPO_ROOT}/tests/run-sterile.sh" --only test-state-io.sh 2>&1)"
assert_contains "T4: neither flag set → strict default" "mode: strict" "${out_default}"

# ----------------------------------------------------------------------
# Test 5: run-sterile.sh CLI-flag precedence
# ----------------------------------------------------------------------
printf 'Test 5: run-sterile.sh CLI-flag precedence\n'

# --advisory flag wins over default
out_adv_flag="$(bash "${REPO_ROOT}/tests/run-sterile.sh" --advisory --only test-state-io.sh 2>&1)"
assert_contains "T5: --advisory flag → advisory" "mode: advisory" "${out_adv_flag}"

# --strict flag explicit (redundant but should work)
out_strict_flag="$(bash "${REPO_ROOT}/tests/run-sterile.sh" --strict --only test-state-io.sh 2>&1)"
assert_contains "T5: --strict flag → strict" "mode: strict" "${out_strict_flag}"

# ----------------------------------------------------------------------
# Test 6 (v1.33.x): sterile TMPDIR is forced under /tmp/.
#
# Post-mortem of the v1.33.0/.1/.2 cascade: Wave-4's claude_bin
# denylist (rejects pins under /tmp, /private/tmp, /var/tmp,
# /Users/Shared, /dev/shm) fired on Linux CI because mktemp -d
# returned /tmp/tmp.XXX, but never on macOS sterile-env where
# TMPDIR previously pointed inside sterile_home (/var/folders/...).
# Forcing TMPDIR under /tmp/ makes sterile-env catch the
# path-prefix-denylist class on every host.
#
# Regression net: assert build_sterile_env emits a TMPDIR= line
# whose value starts with `/tmp/`. Source the lib directly so this
# is a pure-unit assertion, no full sterile run needed.
# ----------------------------------------------------------------------
printf 'Test 6: sterile TMPDIR is forced under /tmp/ (v1.33.x post-mortem)\n'

# shellcheck disable=SC1091
. "${REPO_ROOT}/tests/lib/sterile-env.sh"

env_block="$(build_sterile_env)"
tmpdir_line="$(printf '%s\n' "${env_block}" | grep -E '^TMPDIR=')"
home_line="$(printf '%s\n' "${env_block}" | grep -E '^HOME=')"

assert_contains "T6: TMPDIR= line is emitted" "TMPDIR=" "${env_block}"

tmpdir_value="${tmpdir_line#TMPDIR=}"
home_value="${home_line#HOME=}"

if [[ "${tmpdir_value}" == /tmp/* ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T6: sterile TMPDIR not under /tmp/ — got %q\n' "${tmpdir_value}" >&2
  fail=$((fail + 1))
fi

# Sister check: HOME must NOT be under /tmp/. Pre-fix attempt had HOME
# under /tmp which was MORE hostile than real CI (where HOME is
# /home/runner) and broke tests using ${HOME}/.cache/... pin paths.
# Ensures the sterile env stays a faithful proxy for CI, not stricter.
case "${home_value}" in
  /tmp/*|/private/tmp/*|/var/tmp/*)
    printf '  FAIL: T6: sterile HOME landed under /tmp shape — got %q (sterile is not supposed to be more hostile than CI)\n' "${home_value}" >&2
    fail=$((fail + 1))
    ;;
  *)
    pass=$((pass + 1))
    ;;
esac

# Cleanup the dirs build_sterile_env created so this test doesn't
# accumulate garbage under /tmp on repeated runs.
[[ -n "${tmpdir_value}" && -d "${tmpdir_value}" ]] && rm -rf "${tmpdir_value}"
[[ -n "${home_value}" && -d "${home_value}" ]] && rm -rf "${home_value}"

# ----------------------------------------------------------------------
printf '\n=== sterile-env tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
