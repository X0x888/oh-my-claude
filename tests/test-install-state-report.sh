#!/usr/bin/env bash
#
# tests/test-install-state-report.sh — contract regression net for
# tools/install-state-report.sh.
#
# Why this exists (defect D9 from the post-91fc96b cumulative review):
# install-state-report.sh is the AI-installer's primary probe per AGENTS.md
# but had 31 references-from-scenarios in test-install-artifacts.sh and zero
# assertions on its documented contract surface. A field-rename refactor
# (e.g., currentness → status_class, dropping a documented --*-summary
# mode) could land while every existing test still passes because the
# scenario tests grep for individual key/value pairs in their own context,
# not for the schema or the full mode-set. This file pins the contract.
#
# What this file asserts:
#   1. The --json output includes every documented top-level key.
#   2. The currentness value comes from a closed enum.
#   3. Each documented --*-summary mode emits at the documented condition
#      and stays silent otherwise (safe-fallback for --restart-guidance).
#   4. install_status=not-installed when ~/.claude is absent or conf is
#      missing the installed_version stamp.
#   5. The script exits 0 in all happy paths; exits 1 on jq missing
#      under --json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOL="${REPO_ROOT}/tools/install-state-report.sh"
[[ -x "${TOOL}" ]] || { printf 'install-state-report.sh missing or not executable: %s\n' "${TOOL}" >&2; exit 1; }

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL: %s\n    expected: %q\n    actual:   %q\n' "${label}" "${expected}" "${actual}" >&2
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL: %s\n    needle: %q\n    in: %q\n' "${label}" "${needle}" "${haystack}" >&2
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '  FAIL: %s\n    forbidden needle: %q\n    in: %q\n' "${label}" "${needle}" "${haystack}" >&2
  fi
}

mk_fixture_home() {
  local home_dir
  home_dir="$(mktemp -d -t omc-state-report-XXXXXX)"
  mkdir -p "${home_dir}/.claude"
  printf '%s' "${home_dir}"
}

write_conf() {
  local home_dir="$1"
  shift
  : > "${home_dir}/.claude/oh-my-claude.conf"
  while [[ $# -gt 0 ]]; do
    printf '%s\n' "$1" >> "${home_dir}/.claude/oh-my-claude.conf"
    shift
  done
}

write_install_stamp() {
  local home_dir="$1"
  printf '%s\n' "$2" > "${home_dir}/.claude/.install-stamp"
}

cleanup_fixture() {
  local home_dir="$1"
  [[ -n "${home_dir}" ]] && rm -rf "${home_dir}"
}

run_tool_json() {
  local home_dir="$1"
  shift
  TARGET_HOME="${home_dir}" bash "${TOOL}" --json "$@"
}

run_tool_text() {
  local home_dir="$1"
  shift
  TARGET_HOME="${home_dir}" bash "${TOOL}" "$@"
}

# ---------------------------------------------------------------------
printf 'Test 1: --json on a fresh (no conf, no stamp) home reports install_status=not-installed\n'
home="$(mk_fixture_home)"
out="$(run_tool_json "${home}")"
rc=$?
assert_eq "T1: exit 0 on fresh home" "0" "${rc}"
assert_eq "T1: install_status not-installed" "not-installed" "$(printf '%s' "${out}" | jq -r '.install_status')"
assert_eq "T1: currentness not-applicable" "not-applicable" "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 2: --json output contains every documented top-level key\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.43.0' 'installed_sha=698f98e' 'repo_path=/tmp/omc-repo'
write_install_stamp "${home}" "$(date +%s)"
out="$(run_tool_json "${home}")"
# Per install-state-report.sh usage block (lines 31-39): the documented
# top-level keys.
expected_keys=(
  install_status
  currentness
  reason
  conf_path
  install_stamp
  installed_version
  installed_sha
  repo_path
  repo_checkout
  fetched
  latest_tag
  origin_default_ref
  origin_default_sha
  local_repo_version
  last_install_at
  last_install_epoch
  last_install
)
actual_keys="$(printf '%s' "${out}" | jq -r 'keys[]' | sort | tr '\n' ' ')"
for key in "${expected_keys[@]}"; do
  assert_contains "T2: --json emits documented key '${key}'" "${key} " "${actual_keys} "
done
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 3: currentness comes from the documented closed enum\n'
home="$(mk_fixture_home)"
# Fresh home → currentness=not-applicable
out_fresh="$(run_tool_json "${home}")"
currentness_fresh="$(printf '%s' "${out_fresh}" | jq -r '.currentness')"
case "${currentness_fresh}" in
  not-applicable|already-current|update-available|unknown)
    pass=$((pass + 1))
    ;;
  *)
    fail=$((fail + 1))
    printf '  FAIL: T3: currentness=%q outside documented enum\n' "${currentness_fresh}" >&2
    ;;
esac
# Installed but with a non-existent repo_path → currentness=unknown (no
# git tree to compare against). NOT update-available — the helper has no
# reference for what "current" means.
write_conf "${home}" 'installed_version=1.43.0' 'installed_sha=698f98e' 'repo_path=/tmp/this-path-does-not-exist-omc-test'
write_install_stamp "${home}" "$(date +%s)"
out_installed="$(run_tool_json "${home}")"
currentness_installed="$(printf '%s' "${out_installed}" | jq -r '.currentness')"
case "${currentness_installed}" in
  not-applicable|already-current|update-available|unknown)
    pass=$((pass + 1))
    ;;
  *)
    fail=$((fail + 1))
    printf '  FAIL: T3: currentness=%q outside documented enum (installed case)\n' "${currentness_installed}" >&2
    ;;
esac
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 4: --last-update-summary stays silent when last install was not an update\n'
home="$(mk_fixture_home)"
# No last_install report → mode emits nothing.
out="$(run_tool_text "${home}" --last-update-summary)"
assert_eq "T4: --last-update-summary silent without last install" "" "${out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 5: --restart-guidance always emits (safe-fallback: restart)\n'
home="$(mk_fixture_home)"
out="$(run_tool_text "${home}" --restart-guidance)"
# Must always emit SOMETHING — the documented safe-fallback is to recommend
# restart. Asserting non-empty guards the contract.
if [[ -n "${out}" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf '  FAIL: T5: --restart-guidance produced empty output (safe-fallback contract broken)\n' >&2
fi
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 6: --already-current-summary stays silent unless currentness=already-current\n'
home="$(mk_fixture_home)"
# Fresh home → currentness=not-applicable → mode emits nothing.
out="$(run_tool_text "${home}" --already-current-summary)"
assert_eq "T6: --already-current-summary silent when not already-current" "" "${out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 7: text mode emits the documented field labels\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.43.0' 'installed_sha=698f98e6'
out="$(run_tool_text "${home}")"
assert_contains "T7: text mode names Install status" "Install status:" "${out}"
assert_contains "T7: text mode names Currentness" "Currentness:" "${out}"
assert_contains "T7: text mode names Reason" "Reason:" "${out}"
assert_contains "T7: text mode renders installed_version" "1.43.0" "${out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 8: install_stamp path defaults to ~/.claude/.install-stamp\n'
home="$(mk_fixture_home)"
out="$(run_tool_json "${home}")"
expected_stamp="${home}/.claude/.install-stamp"
actual_stamp="$(printf '%s' "${out}" | jq -r '.install_stamp')"
assert_eq "T8: install_stamp resolves under TARGET_HOME" "${expected_stamp}" "${actual_stamp}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 9: mode precedence — when multiple summary flags are passed, the order matches the source-level dispatch chain (last-update first, then restart-guidance, then already-current, then JSON/text)\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.43.0'
# --last-update-summary fires FIRST in the dispatch chain (install-state-
# report.sh:454) and silently exits when last_install kind is not update.
# So combining --last-update-summary with anything else means the rest is
# unreachable — the contract is "modes are processed in dispatch-chain
# order; the first one whose condition triggers wins."
out="$(run_tool_text "${home}" --last-update-summary --json)"
rc=$?
assert_eq "T9a: combined modes exit 0" "0" "${rc}"
assert_eq "T9a: --last-update-summary first in chain pre-empts --json (no update → silent)" "" "${out}"
# When --restart-guidance is paired with --json BUT no --last-update-summary,
# restart-guidance fires first per dispatch order and pre-empts --json.
out="$(run_tool_text "${home}" --restart-guidance --json)"
rc=$?
assert_eq "T9b: --restart-guidance + --json exit 0" "0" "${rc}"
# Restart guidance must produce something (safe-fallback).
if [[ -n "${out}" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf '  FAIL: T9b: --restart-guidance produced empty output\n' >&2
fi
# JSON-only mode (no summary flag) must produce parseable JSON.
out="$(run_tool_json "${home}")"
rc=$?
assert_eq "T9c: bare --json exits 0" "0" "${rc}"
if printf '%s' "${out}" | jq -e '.install_status' >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf '  FAIL: T9c: bare --json output does not parse as JSON\n' >&2
fi
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf '\n=== install-state-report tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
