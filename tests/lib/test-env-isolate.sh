# shellcheck shell=bash
#
# tests/lib/test-env-isolate.sh — shared environment isolation for tests.
#
# v1.31.0 Wave 3 (metis emergent finding F-013): closes the long-tail
# of test failures caused by:
#   1. Conf-flag leak — when the user's `~/.claude/oh-my-claude.conf`
#      sets default-OFF flags (prometheus_suggest=on, etc.) the
#      common.sh load_conf reads them into the parent env, and those
#      env vars survive HOME=$TEST_HOME overrides because they were
#      already exported. Documented in
#      `~/.claude/projects/-Users-xxxcoding-Documents-ai-coding-oh-my-claude/memory/project_test_isolation_conf_leak.md`
#      Pre-Wave-3 fix: every test explicitly forced expected env via
#      `HOME=tmp OMC_FLAG=on bash router.sh` invocations. This works
#      but is repetitive and error-prone for new tests.
#   2. Locale leak — `wc -m` and `${#var}` are locale-dependent.
#      Tests run in shells with LC_ALL=C return BYTE counts; tests
#      run with LC_ALL=en_US.UTF-8 return CHAR counts. T37 sparkline
#      assertion is the canonical example.
#
# Source this file from a test to get reset_test_env() and
# pinned_locale_env to enforce a known baseline.
#
# Usage:
#   . "$(cd "$(dirname "$0")" && pwd)/lib/test-env-isolate.sh"
#   reset_test_env             # call before each test that touches OMC_* env
#   eval "$(pinned_locale_env)" # eval-injects LC_ALL/LANG to en_US.UTF-8

# reset_test_env — clears every OMC_* env var that load_conf would
# otherwise set from a user-installed conf. Tests that explicitly
# set OMC_* vars before invoking the harness do NOT need this (they
# override after the reset). Tests that rely on default values DO.
#
# Implementation: enumerate via `compgen -e | grep ^OMC_` then unset.
# Bash 3.2 compatible. `unset` is safe on undefined vars.
reset_test_env() {
  local _omc_var
  while IFS= read -r _omc_var; do
    [[ -z "${_omc_var}" ]] && continue
    # Preserve OMC_TEST_* vars (test-specific overrides) so tests
    # can opt-in to specific behaviors via OMC_TEST_<feature>=...
    case "${_omc_var}" in
      OMC_TEST_*) continue ;;
    esac
    unset "${_omc_var}" 2>/dev/null || true
  done < <(compgen -e 2>/dev/null | grep '^OMC_' || true)
}

# pinned_locale_env — emit `export LC_ALL=...; export LANG=...` so a
# test's `eval "$(pinned_locale_env)"` pins the locale to a UTF-8
# variant that `wc -m` and similar tools handle correctly. Falls back
# to C.UTF-8 (Linux) or en_US.UTF-8 (macOS) — the FIRST locale present
# on the host wins.
pinned_locale_env() {
  local _candidate _picked=""
  # Order: C.UTF-8 (Linux modern), en_US.UTF-8 (macOS / older Linux),
  # en_GB.UTF-8 (UK Linux), POSIX/C (last-resort no-locale).
  for _candidate in C.UTF-8 en_US.UTF-8 en_GB.UTF-8 C.utf8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qi "^${_candidate}$"; then
      _picked="${_candidate}"
      break
    fi
  done
  if [[ -z "${_picked}" ]]; then
    # Last resort: assume en_US.UTF-8 even if locale -a doesn't list
    # it (some sandboxed envs don't expose locale -a but the locale
    # works fine for wc -m).
    _picked="en_US.UTF-8"
  fi
  printf 'export LC_ALL=%s\nexport LANG=%s\n' "${_picked}" "${_picked}"
}

# isolate_test_home — create a fresh TEST_HOME, point HOME at it,
# install minimal symlinks for common.sh + lib/ so the harness can
# source them. Returns the TEST_HOME path on stdout. Caller is
# responsible for `rm -rf "${TEST_HOME}"` at teardown.
#
# Pattern: `TEST_HOME="$(isolate_test_home /path/to/repo/bundle)"`
isolate_test_home() {
  local bundle_root="$1"
  local _test_home
  _test_home="$(mktemp -d)" || return 1
  mkdir -p "${_test_home}/.claude/skills/autowork/scripts/lib"
  mkdir -p "${_test_home}/.claude/quality-pack/state"
  mkdir -p "${_test_home}/.claude/quality-pack/blindspots"
  ln -sf "${bundle_root}/dot-claude/skills/autowork/scripts/common.sh" \
    "${_test_home}/.claude/skills/autowork/scripts/common.sh" 2>/dev/null
  local _libfile
  for _libfile in "${bundle_root}/dot-claude/skills/autowork/scripts/lib/"*.sh; do
    [[ -f "${_libfile}" ]] || continue
    ln -sf "${_libfile}" \
      "${_test_home}/.claude/skills/autowork/scripts/lib/$(basename "${_libfile}")" 2>/dev/null
  done
  printf '%s' "${_test_home}"
}
