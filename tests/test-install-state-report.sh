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

fixture_file_mtime_epoch() {
  local path="$1"
  if stat -f '%m' "${path}" >/dev/null 2>&1; then
    stat -f '%m' "${path}"
  else
    stat -c '%Y' "${path}"
  fi
}

write_authoritative_noop_report() {
  local home_dir="$1" report_stamp_epoch=""
  mkdir -p "${home_dir}/.claude/quality-pack/state"
  report_stamp_epoch="$(fixture_file_mtime_epoch \
    "${home_dir}/.claude/.install-stamp")"
  jq -n --argjson install_stamp_epoch "${report_stamp_epoch}" '
    {
      schema_version: 1,
      install_kind: "reinstall-noop",
      restart_required: false,
      restart_reason: "No managed changes.",
      managed_changes: {total: 0},
      settings_changed: false,
      install_stamp_epoch: $install_stamp_epoch,
      previous_install: {
        installed_version: "1.43.0",
        installed_sha: "698f98e"
      },
      current_install: {
        installed_version: "1.44.0",
        installed_sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      },
      change_summary: {
        available: false,
        reason: "Not an update install.",
        commit_count: 0,
        truncated_count: 0,
        commits: []
      }
    }
  ' > "${home_dir}/.claude/quality-pack/state/last-install-report.json"
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
printf 'Test 10: duplicate padded repo_path uses the exact last key and preserves literal interior pathname bytes\n'
home="$(mk_fixture_home)"
repo="${home}/repo  two's\\backslash"
remote="${home}/remote.git"
mkdir -p "${repo}"
git init -q "${repo}"
git -C "${repo}" config user.email omc-state-report@example.invalid
git -C "${repo}" config user.name 'OMC State Report Test'
printf '1.43.0\n' > "${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'fixture release'
branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
git init --bare -q "${remote}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${branch}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q -u origin "${branch}"
git -C "${repo}" tag v1.43.0
git -C "${repo}" push -q origin v1.43.0
git -C "${repo}" remote set-head origin "${branch}"
installed_sha="$(git -C "${repo}" rev-parse HEAD)"
printf -v padded_repo_path 'repo_path= \t%s \t' "${repo}"
write_conf "${home}" \
  'installed_version=1.43.0' \
  "installed_sha=${installed_sha}" \
  'repo_path=/tmp/stale-repo-path' \
  "not_repo_path=${home}/foreign" \
  "${padded_repo_path}"
write_install_stamp "${home}" "$(date +%s)"
out="$(run_tool_json "${home}")"
assert_eq "T10: exact-key last repo_path wins with edge whitespace trimmed" \
  "${repo}" "$(printf '%s' "${out}" | jq -r '.repo_path')"
assert_eq "T10: normalized literal path remains a usable checkout" \
  "true" "$(printf '%s' "${out}" | jq -r '.repo_checkout')"
assert_eq "T10: normalized current checkout can report already-current" \
  "already-current" "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 11: text diagnostics neutralize control-bearing config values while JSON remains lossless\n'
home="$(mk_fixture_home)"
control_repo="/tmp/omc-control-"$'\033'"[31m-path"
mkdir -p "${home}/.claude"
printf 'installed_version=1.43.0\nrepo_path=%s\n' "${control_repo}" \
  > "${home}/.claude/oh-my-claude.conf"
out="$(run_tool_text "${home}")"
if [[ "${out}" == *$'\033'* ]]; then
  fail=$((fail + 1))
  printf '  FAIL: T11: text output retained a raw escape control byte\n' >&2
else
  pass=$((pass + 1))
fi
assert_contains "T11: text output visibly neutralizes control byte" \
  '/tmp/omc-control-?[31m-path' "${out}"
out="$(run_tool_json "${home}")"
assert_eq "T11: JSON preserves the literal config value through escaping" \
  "${control_repo}" "$(printf '%s' "${out}" | jq -r '.repo_path')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 12: update summaries preserve commit row boundaries and sanitize fields\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
mkdir -p "${home}/.claude/quality-pack/state"
write_install_stamp "${home}" 'update-summary-fixture'
report_stamp_epoch="$(fixture_file_mtime_epoch \
  "${home}/.claude/.install-stamp")"
jq -n \
  --arg second_subject $'second subject\033[31m' \
  --argjson install_stamp_epoch "${report_stamp_epoch}" \
  '{
    schema_version: 1,
    install_kind: "update",
    restart_required: true,
    restart_reason: "managed files changed",
    managed_changes: {total: 2},
    settings_changed: false,
    previous_install: {
      installed_version: "1.43.0",
      installed_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    current_install: {
      installed_version: "1.44.0",
      installed_sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    install_stamp_epoch: $install_stamp_epoch,
    change_summary: {
      available: true,
      reason: null,
      commit_count: 2,
      truncated_count: 0,
      commits: [
        {sha: "1111111111111111111111111111111111111111", subject: "first subject"},
        {sha: "2222222222222222222222222222222222222222", subject: $second_subject}
      ]
    }
  }' > "${home}/.claude/quality-pack/state/last-install-report.json"
out="$(run_tool_text "${home}" --last-update-summary)"
commit_rows="$(printf '%s\n' "${out}" \
  | grep -E '^      (111111111111|222222222222) ' || true)"
assert_eq "T12: each commit remains on its own rendered row" \
  $'      111111111111 first subject\n      222222222222 second subject?[31m' \
  "${commit_rows}"
if [[ "${out}" == *$'\033'* ]]; then
  fail=$((fail + 1))
  printf '  FAIL: T12: update summary retained a raw escape byte\n' >&2
else
  pass=$((pass + 1))
fi
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 13: wrong-typed valid JSON reports fail closed without breaking modes\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
mkdir -p "${home}/.claude/quality-pack/state"
printf '%s\n' \
  '{"schema_version":1,"install_kind":"update","restart_required":"yes","managed_changes":{"total":"oops"},"settings_changed":false,"previous_install":{},"current_install":{},"change_summary":{"available":true,"reason":null,"commit_count":1,"truncated_count":0,"commits":{}}}' \
  > "${home}/.claude/quality-pack/state/last-install-report.json"
invalid_rc=0
out="$(run_tool_json "${home}" 2>/dev/null)" || invalid_rc=$?
assert_eq "T13: malformed report does not break --json" "0" "${invalid_rc}"
assert_eq "T13: malformed report is treated as absent" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
out="$(run_tool_text "${home}" --last-update-summary)"
assert_eq "T13: malformed update report cannot drive a summary" "" "${out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 13a: raw and decoded NUL report bytes cannot suppress restart authority\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
write_install_stamp "${home}" 'nul-authority-fixture'
write_authoritative_noop_report "${home}"
report_path="${home}/.claude/quality-pack/state/last-install-report.json"
cp "${report_path}" "${home}/valid-report.json"

# jq accepts a raw NUL in numeric position as the number zero. The report
# reader must reject the captured bytes themselves before that parser behavior
# can turn malformed storage into a restart_required=false authority.
jq -c '.managed_changes.total = "__RAW_NUL__"' \
  "${home}/valid-report.json" > "${home}/marked-report.json"
marked_report="$(<"${home}/marked-report.json")"
raw_marker='"__RAW_NUL__"'
{
  printf '%s' "${marked_report%%"${raw_marker}"*}"
  printf '\0'
  printf '%s\n' "${marked_report#*"${raw_marker}"}"
} > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13a: raw NUL report has no JSON authority" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
restart_out="$(run_tool_text "${home}" --restart-guidance)"
assert_contains "T13a: raw NUL cannot suppress safe restart guidance" \
  'Restart Claude Code (or open a new session) before testing.' \
  "${restart_out}"

# An escaped NUL is valid JSON and jq -r would decode it before Bash silently
# drops it. Reject it while the report is still a structured snapshot.
jq '.restart_reason = "No managed changes.\u0000"' \
  "${home}/valid-report.json" > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13a: decoded NUL report has no JSON authority" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
restart_out="$(run_tool_text "${home}" --restart-guidance)"
assert_contains "T13a: decoded NUL cannot suppress safe restart guidance" \
  'Restart Claude Code (or open a new session) before testing.' \
  "${restart_out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 13b: shell-normalizing string framing cannot manufacture update authority\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
write_install_stamp "${home}" 'framing-authority-fixture'
write_authoritative_noop_report "${home}"
report_path="${home}/.claude/quality-pack/state/last-install-report.json"

# Command substitution strips trailing LFs. Without pre-projection validation,
# jq -r turns this stored value into the exact Bash token `update`.
jq '.install_kind = "update\n"' "${report_path}" \
  > "${home}/framed-report.json"
mv "${home}/framed-report.json" "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13b: LF-framed kind leaves last_install null" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
update_out="$(run_tool_text "${home}" --last-update-summary)"
assert_eq "T13b: LF-framed kind cannot manufacture update summary" "" \
  "${update_out}"
restart_out="$(run_tool_text "${home}" --restart-guidance)"
assert_contains "T13b: LF-framed report cannot suppress restart" \
  'Restart Claude Code (or open a new session) before testing.' \
  "${restart_out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 13c: report install identities and commit rows use bounded exact schemas\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
write_install_stamp "${home}" 'identity-schema-fixture'
write_authoritative_noop_report "${home}"
report_path="${home}/.claude/quality-pack/state/last-install-report.json"
cp "${report_path}" "${home}/valid-report.json"

jq '.current_install.installed_version = "1.44.0/../forged"' \
  "${home}/valid-report.json" > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13c: malformed current version rejects report" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"

jq '.previous_install.installed_sha = "not-a-git-object"' \
  "${home}/valid-report.json" > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13c: malformed install SHA rejects report" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"

jq '.change_summary.available = true
    | .change_summary.commit_count = 1
    | .change_summary.commits = [{sha: "698f98e", subject: "abbreviated"}]' \
  "${home}/valid-report.json" > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13c: abbreviated commit-row SHA rejects report" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"

# Historical install metadata allowed a pre-release VERSION and abbreviated
# installed_sha. Keep that display-only legacy readable while commit rows stay
# bound to full git object IDs.
jq '.previous_install.installed_version = "1.22.0-rc.1"
    | .previous_install.installed_sha = "698f98e"' \
  "${home}/valid-report.json" > "${report_path}"
out="$(run_tool_json "${home}")"
assert_eq "T13c: documented legacy pre-release version remains readable" \
  "1.22.0-rc.1" \
  "$(printf '%s' "${out}" | jq -r '.last_install.previous.installed_version')"
assert_eq "T13c: legacy abbreviated installed SHA remains readable" \
  "698f98e" \
  "$(printf '%s' "${out}" | jq -r '.last_install.previous.installed_sha')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 14: commit-DAG currentness distinguishes remote-ahead, local-ahead, and divergence\n'
home="$(mk_fixture_home)"
repo="${home}/dag-repo"
remote="${home}/dag-remote.git"
peer="${home}/dag-peer"
git init -q "${repo}"
git -C "${repo}" config user.email omc-state-report@example.invalid
git -C "${repo}" config user.name 'OMC State Report Test'
printf '1.43.0\n' > "${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'base release'
branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
git init --bare -q "${remote}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${branch}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q -u origin "${branch}"
git -C "${repo}" tag v1.43.0
git -C "${repo}" push -q origin v1.43.0
git -C "${repo}" remote set-head origin "${branch}"
base_sha="$(git -C "${repo}" rev-parse HEAD)"
# Put a semantically newer release tag on the remote base. The recorded SHA,
# not this version-only signal, must still decide the local-ahead and divergence
# cases below. Archive installs without installed_sha retain the tag fallback.
git -C "${repo}" tag v1.45.0 "${base_sha}"
git -C "${repo}" push -q origin v1.45.0
printf '1.44.0\n' > "${repo}/VERSION"
printf 'local-only\n' > "${repo}/local-only"
git -C "${repo}" add VERSION local-only
git -C "${repo}" commit -qm 'local install ahead of origin'
installed_sha="$(git -C "${repo}" rev-parse HEAD)"
write_conf "${home}" \
  'installed_version=1.44.0' \
  "installed_sha=${installed_sha}" \
  "repo_path=${repo}"
out="$(run_tool_json "${home}")"
assert_eq "T14: SHA-authoritative local-ahead install stays current despite a newer tag" \
  "already-current" "$(printf '%s' "${out}" | jq -r '.currentness')"

git clone -q "${remote}" "${peer}"
git -C "${peer}" config user.email omc-state-report@example.invalid
git -C "${peer}" config user.name 'OMC State Report Peer'
printf 'remote-only\n' > "${peer}/remote-only"
git -C "${peer}" add remote-only
git -C "${peer}" commit -qm 'remote branch diverges from installed commit'
git -C "${peer}" push -q origin "${branch}"
out="$(run_tool_json "${home}")"
assert_eq "T14: SHA-authoritative divergence stays unknown despite a newer tag" \
  "unknown" "$(printf '%s' "${out}" | jq -r '.currentness')"
assert_contains "T14: divergence reason is explicit" "have diverged" \
  "$(printf '%s' "${out}" | jq -r '.reason')"

write_conf "${home}" \
  'installed_version=1.43.0' \
  "installed_sha=${base_sha}" \
  "repo_path=${repo}"
out="$(run_tool_json "${home}")"
assert_eq "T14: an installed ancestor of the remote branch needs update" \
  "update-available" "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 15: semver ordering does not depend on GNU sort -V\n'
home="$(mk_fixture_home)"
repo="${home}/portable-semver-repo"
remote="${home}/portable-semver-remote.git"
mock_bin="${home}/mock-bin"
mkdir -p "${repo}" "${mock_bin}"
git init -q "${repo}"
git -C "${repo}" config user.email omc-state-report@example.invalid
git -C "${repo}" config user.name 'OMC State Report Test'
printf '1.10.10\n' > "${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'portable semver fixture'
branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
git init --bare -q "${remote}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${branch}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q -u origin "${branch}"
for version in 1.2.10 1.10.2 1.10.10; do
  git -C "${repo}" tag "v${version}"
done
git -C "${repo}" push -q origin --tags
git -C "${repo}" remote set-head origin "${branch}"
installed_sha="$(git -C "${repo}" rev-parse HEAD)"
write_conf "${home}" \
  'installed_version=1.10.10' \
  "installed_sha=${installed_sha}" \
  "repo_path=${repo}"
real_sort="$(command -v sort)"
cat > "${mock_bin}/sort" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
  [[ "\${arg}" == "-V" ]] && exit 91
done
exec "${real_sort}" "\$@"
MOCK
chmod +x "${mock_bin}/sort"
out="$(PATH="${mock_bin}:${PATH}" TARGET_HOME="${home}" \
  bash "${TOOL}" --json)"
assert_eq "T15: Bash-native comparison selects the highest semantic tag" \
  "1.10.10" "$(printf '%s' "${out}" | jq -r '.latest_tag')"
assert_eq "T15: currentness works when sort rejects -V" \
  "already-current" "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 16: internal whitespace in install metadata is preserved and cannot be normalized into authority\n'
home="$(mk_fixture_home)"
write_conf "${home}" \
  'installed_version=1. 44.0' \
  'installed_sha=abc def0' \
  'repo_path=/tmp/this-path-does-not-exist-omc-whitespace-test'
out="$(run_tool_json "${home}")"
assert_eq "T16: version keeps invalid interior whitespace" \
  '1. 44.0' "$(printf '%s' "${out}" | jq -r '.installed_version')"
assert_eq "T16: SHA keeps invalid interior whitespace" \
  'abc def0' "$(printf '%s' "${out}" | jq -r '.installed_sha')"
assert_eq "T16: malformed metadata cannot manufacture currentness" \
  'unknown' "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 17: restart guidance trusts only a report bound to the current install stamp\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
mkdir -p "${home}/.claude/quality-pack/state"
write_install_stamp "${home}" 'first-install-generation'
touch -t 202001010101.01 "${home}/.claude/.install-stamp"
report_stamp_epoch="$(fixture_file_mtime_epoch \
  "${home}/.claude/.install-stamp")"
jq -n --argjson install_stamp_epoch "${report_stamp_epoch}" '
  {
    schema_version: 1,
    install_kind: "reinstall-noop",
    restart_required: false,
    restart_reason: "No managed changes.",
    managed_changes: {total: 0},
    settings_changed: false,
    install_stamp_epoch: $install_stamp_epoch,
    previous_install: {installed_version: "1.44.0", installed_sha: null},
    current_install: {installed_version: "1.44.0", installed_sha: null},
    change_summary: {
      available: false,
      reason: "Not an update install.",
      commit_count: 0,
      truncated_count: 0,
      commits: []
    }
  }
' > "${home}/.claude/quality-pack/state/last-install-report.json"
out="$(run_tool_json "${home}")"
assert_eq "T17: matching report generation is admitted" \
  "${report_stamp_epoch}" \
  "$(printf '%s' "${out}" | jq -r '.last_install.install_stamp_epoch')"
out="$(run_tool_text "${home}" --restart-guidance)"
assert_contains "T17: matching no-op report may suppress restart guidance" \
  "No Claude Code restart is required." "${out}"

# Advance only the authoritative install stamp, modeling a newer install that
# died before publishing its report. The old restart_required=false report
# must not be allowed to describe that newer generation.
touch -t 202101010101.01 "${home}/.claude/.install-stamp"
out="$(run_tool_json "${home}")"
assert_eq "T17: stale report is excluded from JSON" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
out="$(run_tool_text "${home}" --restart-guidance)"
assert_contains "T17: stale no-op report falls back to restart" \
  "Restart Claude Code (or open a new session) before testing." "${out}"

# Even a same-generation-shaped report without the required schema field has
# no authority to suppress restart guidance.
jq 'del(.install_stamp_epoch)' \
  "${home}/.claude/quality-pack/state/last-install-report.json" \
  > "${home}/.claude/quality-pack/state/last-install-report.missing-stamp.json"
mv "${home}/.claude/quality-pack/state/last-install-report.missing-stamp.json" \
  "${home}/.claude/quality-pack/state/last-install-report.json"
out="$(run_tool_json "${home}")"
assert_eq "T17: report missing install_stamp_epoch is rejected" "null" \
  "$(printf '%s' "${out}" | jq -c '.last_install')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 18: version fallback ignores local-only and off-default origin tags\n'
home="$(mk_fixture_home)"
repo="${home}/tag-authority-repo"
remote="${home}/tag-authority-remote.git"
mkdir -p "${repo}"
git init -q "${repo}"
git -C "${repo}" config user.email omc-state-report@example.invalid
git -C "${repo}" config user.name 'OMC State Report Test'
printf '1.0.0\n' > "${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'origin default release'
branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
git -C "${repo}" tag v1.0.0
git init --bare -q "${remote}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${branch}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q -u origin "${branch}" --tags
git -C "${repo}" remote set-head origin "${branch}"

# These unpublished and remote-deleted tags point at the default-branch tip,
# while the advertised v88 tag points at a commit outside the default-branch
# DAG. None is release authority for archive/version-only currentness.
git -C "${repo}" tag v99.0.0
git -C "${repo}" tag v77.0.0
git -C "${repo}" push -q origin v77.0.0
git -C "${repo}" push -q --delete origin v77.0.0
empty_tree="$(git -C "${repo}" mktree </dev/null)"
side_commit="$(printf 'off-default release tag\n' \
  | git -C "${repo}" commit-tree "${empty_tree}")"
git -C "${repo}" tag v88.0.0 "${side_commit}"
git -C "${repo}" push -q origin v88.0.0
write_conf "${home}" \
  'installed_version=1.0.0' \
  "repo_path=${repo}"
out="$(run_tool_json "${home}")"
assert_eq "T18: latest tag is origin-advertised and default-ref reachable" \
  '1.0.0' "$(printf '%s' "${out}" | jq -r '.latest_tag')"
assert_eq "T18: arbitrary tags cannot manufacture an update" \
  'already-current' "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 19: report fields come from one validated snapshot generation\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
mkdir -p "${home}/.claude/quality-pack/state" "${home}/mock-bin"
write_install_stamp "${home}" 'snapshot-generation'
report_stamp_epoch="$(fixture_file_mtime_epoch \
  "${home}/.claude/.install-stamp")"
report_path="${home}/.claude/quality-pack/state/last-install-report.json"
jq -n --argjson install_stamp_epoch "${report_stamp_epoch}" '
  {
    schema_version:1,install_kind:"update",restart_required:true,
    restart_reason:"managed files changed",managed_changes:{total:1},
    settings_changed:false,install_stamp_epoch:$install_stamp_epoch,
    previous_install:{installed_version:"1.43.0",installed_sha:null},
    current_install:{installed_version:"1.44.0",installed_sha:null},
    change_summary:{available:false,reason:"fixture",commit_count:0,
      truncated_count:0,commits:[]}
  }
' >"${report_path}"
printf '%s\n' '{}' >"${home}/replacement-report.json"
real_jq="$(command -v jq)"
mock_jq_count="${home}/mock-jq-count"
printf '0\n' >"${mock_jq_count}"
cat >"${home}/mock-bin/jq" <<MOCK
#!/usr/bin/env bash
"${real_jq}" "\$@"
rc=\$?
count="\$(<"${mock_jq_count}")"
if [[ "\${count}" == "0" ]]; then
  printf '1\\n' >"${mock_jq_count}"
  cp "${home}/replacement-report.json" "${report_path}"
fi
exit "\${rc}"
MOCK
chmod +x "${home}/mock-bin/jq"
out="$(PATH="${home}/mock-bin:${PATH}" TARGET_HOME="${home}" \
  bash "${TOOL}" --json)"
assert_eq "T19: admitted report remains the single captured generation" \
  'true' "$(printf '%s' "${out}" | "${real_jq}" -r \
    '.last_install.restart_required')"
assert_eq "T19: concurrent replacement cannot clear report presence" \
  'update' "$(printf '%s' "${out}" | "${real_jq}" -r \
    '.last_install.kind')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 20: report size check and parse stay bound to one inode generation\n'
home="$(mk_fixture_home)"
write_conf "${home}" 'installed_version=1.44.0'
mkdir -p "${home}/.claude/quality-pack/state" "${home}/mock-bin"
write_install_stamp "${home}" 'descriptor-generation'
report_stamp_epoch="$(fixture_file_mtime_epoch \
  "${home}/.claude/.install-stamp")"
report_path="${home}/.claude/quality-pack/state/last-install-report.json"
jq -n --argjson install_stamp_epoch "${report_stamp_epoch}" '
  {
    schema_version:1,install_kind:"update",restart_required:true,
    restart_reason:"managed files changed",managed_changes:{total:1},
    settings_changed:false,install_stamp_epoch:$install_stamp_epoch,
    previous_install:{installed_version:"1.43.0",installed_sha:null},
    current_install:{installed_version:"1.44.0",installed_sha:null},
    change_summary:{available:false,reason:"fixture",commit_count:0,
      truncated_count:0,commits:[]}
  }
' >"${report_path}"
cp "${report_path}" "${home}/original-report.json"
jq -n --argjson install_stamp_epoch "${report_stamp_epoch}" '
  {
    schema_version:1,install_kind:"reinstall-noop",restart_required:false,
    restart_reason:"replacement must not inherit the size check",
    managed_changes:{total:0},settings_changed:false,
    install_stamp_epoch:$install_stamp_epoch,
    previous_install:{installed_version:"1.44.0",installed_sha:null},
    current_install:{installed_version:"1.44.0",installed_sha:null},
    change_summary:{available:false,reason:"fixture",commit_count:0,
      truncated_count:0,commits:[]}
  }
' >"${home}/replacement-report.json"
real_stat="$(command -v stat)"
stat_swap_marker="${home}/stat-swapped"
cat >"${home}/mock-bin/stat" <<MOCK
#!/usr/bin/env bash
target_seen=0
for arg in "\$@"; do
  [[ "\${arg}" == "${report_path}" ]] && target_seen=1
done
if [[ "\${target_seen}" -eq 1 && ! -e "${stat_swap_marker}" ]]; then
  output="\$("${real_stat}" "\$@" 2>/dev/null)"
  rc=\$?
  if [[ "\${rc}" -eq 0 ]]; then
    : >"${stat_swap_marker}"
    mv "${home}/replacement-report.json" "${report_path}"
  fi
  [[ -n "\${output}" ]] && printf '%s\n' "\${output}"
  exit "\${rc}"
fi
exec "${real_stat}" "\$@"
MOCK
chmod +x "${home}/mock-bin/stat"
out="$(PATH="${home}/mock-bin:${PATH}" TARGET_HOME="${home}" \
  bash "${TOOL}" --json)"
assert_eq "T20: check-to-open inode substitution rejects report authority" \
  'null' "$(printf '%s' "${out}" | jq -c '.last_install')"
mv "${report_path}" "${home}/replacement-report.json"
cp "${home}/original-report.json" "${report_path}"
rm -f "${stat_swap_marker}"
restart_out="$(PATH="${home}/mock-bin:${PATH}" TARGET_HOME="${home}" \
  bash "${TOOL}" --restart-guidance)"
assert_contains "T20: rejected replacement cannot suppress restart" \
  'Restart Claude Code (or open a new session) before testing.' \
  "${restart_out}"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf 'Test 21: currentness follows the live remote HEAD after a default-branch change\n'
home="$(mk_fixture_home)"
repo="${home}/changed-default-repo"
remote="${home}/changed-default-remote.git"
mkdir -p "${repo}"
git init -q "${repo}"
git -C "${repo}" config user.email omc-state-report@example.invalid
git -C "${repo}" config user.name 'OMC State Report Test'
printf '1.0.0\n' >"${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'former default tip'
former_branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD)"
former_sha="$(git -C "${repo}" rev-parse HEAD)"
git init --bare -q "${remote}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${former_branch}"
git -C "${repo}" remote add origin "${remote}"
git -C "${repo}" push -q -u origin "${former_branch}"
git -C "${repo}" remote set-head origin "${former_branch}"

replacement_branch='replacement-default'
git -C "${repo}" checkout -qb "${replacement_branch}"
printf 'live default\n' >>"${repo}/VERSION"
git -C "${repo}" add VERSION
git -C "${repo}" commit -qm 'live default tip'
replacement_sha="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" push -q -u origin "${replacement_branch}"
git -C "${remote}" symbolic-ref HEAD "refs/heads/${replacement_branch}"
assert_eq "T21: fixture keeps a stale cached origin/HEAD before probe" \
  "origin/${former_branch}" \
  "$(git -C "${repo}" symbolic-ref --short refs/remotes/origin/HEAD)"
write_conf "${home}" \
  'installed_version=1.0.0' \
  "installed_sha=${former_sha}" \
  "repo_path=${repo}"
out="$(run_tool_json "${home}")"
assert_eq "T21: live advertised default ref outranks cached origin/HEAD" \
  "origin/${replacement_branch}" \
  "$(printf '%s' "${out}" | jq -r '.origin_default_ref')"
assert_eq "T21: live advertised default SHA is fetched and verified" \
  "${replacement_sha}" \
  "$(printf '%s' "${out}" | jq -r '.origin_default_sha')"
assert_eq "T21: new live default tip makes the prior install stale" \
  'update-available' \
  "$(printf '%s' "${out}" | jq -r '.currentness')"
cleanup_fixture "${home}"

# ---------------------------------------------------------------------
printf '\n=== install-state-report tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
