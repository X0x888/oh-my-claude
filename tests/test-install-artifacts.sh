#!/usr/bin/env bash
# Essential installer contract: one real install/reinstall plus the two
# boundaries whose failure would put user data or release bytes at risk.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=""
pass=0
fail=0

cleanup() {
  if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
    rm -rf -- "${TEST_ROOT}"
  fi
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — expected [%s], got [%s]\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_file() {
  local label="$1" path="$2"
  if [[ -f "${path}" && ! -L "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — missing regular file: %s\n' \
      "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains_file() {
  local label="$1" needle="$2" path="$3"
  if [[ -f "${path}" ]] && grep -qF -- "${needle}" "${path}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — [%s] not found in %s\n' \
      "${label}" "${needle}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

conf_value() {
  local key="$1" path="$2" line=""
  line="$(grep -m1 "^${key}=" "${path}" 2>/dev/null || true)"
  printf '%s' "${line#*=}"
}

run_install() {
  local source_root="$1" target_home="$2" output_path="$3"
  CI=1 TARGET_HOME="${target_home}" \
    bash "${source_root}/install.sh" >"${output_path}" 2>&1
}

printf 'Essential installer contract\n'
printf '============================\n\n'

TEST_ROOT="$(mktemp -d)"
SYMLINK_TARGET="${TEST_ROOT}/symlink-target"
SYMLINK_HOME="${TEST_ROOT}/symlink-home"
SYMLINK_OUT="${TEST_ROOT}/symlink-home.out"
SYMLINK_DOT_OUT="${TEST_ROOT}/symlink-home-dot.out"
ROOT_HOME_OUT="${TEST_ROOT}/root-home.out"
mkdir -p "${SYMLINK_TARGET}"
ln -s "${SYMLINK_TARGET}" "${SYMLINK_HOME}"

printf '0. TARGET_HOME symlink boundary\n'
symlink_rc=0
CI=1 TARGET_HOME="${SYMLINK_HOME}/" bash "${REPO_ROOT}/install.sh" \
  >"${SYMLINK_OUT}" 2>&1 || symlink_rc=$?
assert_eq "trailing slash cannot hide a symlink TARGET_HOME" "1" \
  "${symlink_rc}"
assert_eq "refused symlink target receives no install state" "false" \
  "$([[ -e "${SYMLINK_TARGET}/.claude" ]] && printf true || printf false)"
symlink_dot_rc=0
CI=1 TARGET_HOME="${SYMLINK_HOME}/." bash "${REPO_ROOT}/install.sh" \
  >"${SYMLINK_DOT_OUT}" 2>&1 || symlink_dot_rc=$?
assert_eq "lexical dot cannot disguise a symlink TARGET_HOME or mutate it" \
  "1:false" \
  "${symlink_dot_rc}:$([[ -e "${SYMLINK_TARGET}/.claude" ]] \
    && printf true || printf false)"
root_home_rc=0
CI=1 TARGET_HOME="/" bash "${REPO_ROOT}/install.sh" \
  >"${ROOT_HOME_OUT}" 2>&1 || root_home_rc=$?
assert_eq "filesystem root is refused as TARGET_HOME with an explicit error" \
  "1:1" \
  "${root_home_rc}:$(grep -cF \
    'TARGET_HOME must be an existing, non-symlink absolute directory' \
    "${ROOT_HOME_OUT}" || true)"

INSTALL_HOME="${TEST_ROOT}/install-home"
CLAUDE_HOME="${INSTALL_HOME}/.claude"
INSTALL_OUT="${TEST_ROOT}/fresh-install.out"
REINSTALL_OUT="${TEST_ROOT}/reinstall.out"
VERIFY_OUT="${TEST_ROOT}/verify.out"
mkdir -p "${CLAUDE_HOME}"

# User-owned state exists before installation and must survive both passes.
printf '%s\n' 'foreign-file-sentinel' >"${CLAUDE_HOME}/foreign.keep"
printf '%s\n' '{"customSetting":"preserve-me"}' \
  >"${CLAUDE_HOME}/settings.json"

printf '1. Fresh install and artifact integrity\n'
fresh_rc=0
run_install "${REPO_ROOT}" "${INSTALL_HOME}" "${INSTALL_OUT}" \
  || fresh_rc=$?
assert_eq "fresh install exits cleanly" "0" "${fresh_rc}"

CONF="${CLAUDE_HOME}/oh-my-claude.conf"
MANIFEST="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
HASHES="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
STAMP="${CLAUDE_HOME}/.install-stamp"
REPORT="${CLAUDE_HOME}/quality-pack/state/last-install-report.json"

assert_file "installed configuration exists" "${CONF}"
assert_file "installed manifest exists" "${MANIFEST}"
assert_file "installed hash manifest exists" "${HASHES}"
assert_file "install stamp exists" "${STAMP}"
assert_file "last-install report exists" "${REPORT}"
assert_file "core bundle file is installed" "${CLAUDE_HOME}/CLAUDE.md"
assert_file "statusline is installed" "${CLAUDE_HOME}/statusline.py"
assert_contains_file "manifest owns CLAUDE.md" "CLAUDE.md" "${MANIFEST}"
assert_contains_file "manifest owns common.sh" \
  "skills/autowork/scripts/common.sh" "${MANIFEST}"
assert_contains_file "hash manifest owns CLAUDE.md" "CLAUDE.md" "${HASHES}"

expected_version="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
assert_eq "configuration records installed version" "${expected_version}" \
  "$(conf_value installed_version "${CONF}")"
assert_eq "configuration records source repository" "${REPO_ROOT}" \
  "$(conf_value repo_path "${CONF}")"
if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  assert_eq "configuration records source commit" \
    "$(git -C "${REPO_ROOT}" rev-parse HEAD)" \
    "$(conf_value installed_sha "${CONF}")"
fi
assert_eq "fresh install report kind" "fresh-install" \
  "$(jq -r '.install_kind // ""' "${REPORT}" 2>/dev/null || true)"
assert_eq "fresh install requires restart" "true" \
  "$(jq -r '.restart_required // false' "${REPORT}" 2>/dev/null || true)"

printf '\n2. Reinstall and user-owned state preservation\n'
reinstall_rc=0
run_install "${REPO_ROOT}" "${INSTALL_HOME}" "${REINSTALL_OUT}" \
  || reinstall_rc=$?
assert_eq "reinstall exits cleanly" "0" "${reinstall_rc}"
assert_eq "foreign file survives install and reinstall" \
  "foreign-file-sentinel" \
  "$(<"${CLAUDE_HOME}/foreign.keep")"
assert_eq "foreign settings key survives install and reinstall" \
  "preserve-me" \
  "$(jq -r '.customSetting // ""' \
    "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
assert_contains_file "reinstall retains manifest ownership" \
  "statusline.py" "${MANIFEST}"

verify_rc=0
CI=1 TARGET_HOME="${INSTALL_HOME}" bash "${REPO_ROOT}/verify.sh" \
  >"${VERIFY_OUT}" 2>&1 || verify_rc=$?
assert_eq "installed harness verifies cleanly" "0" "${verify_rc}"
verify_errors="$(sed -n \
  's/^[[:space:]]*Errors:[[:space:]]*//p' "${VERIFY_OUT}" | tail -1)"
assert_eq "verifier reports zero errors" "0" "${verify_errors}"

printf '\n3. Source mutation is refused before bundle publication\n'
MUTATION_REPO="${TEST_ROOT}/mutation-repo"
MUTATION_HOME="${TEST_ROOT}/mutation-home"
MUTATION_OUT="${TEST_ROOT}/mutation-install.out"
MUTATION_READY="${TEST_ROOT}/mutation.ready"
MUTATION_RELEASE="${TEST_ROOT}/mutation.release"
mkdir -p "${MUTATION_REPO}" "${MUTATION_HOME}/.claude"
rsync -a --exclude '.git' "${REPO_ROOT}/" "${MUTATION_REPO}/" >/dev/null
printf '%s\n' 'mutation-home-sentinel' \
  >"${MUTATION_HOME}/.claude/foreign.keep"

mutation_rc=0
(
  CI=1 OMC_TEST_INSTALL_BARRIER_ENABLE=1 \
    OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_READY_FILE="${MUTATION_READY}" \
    OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_RELEASE_FILE="${MUTATION_RELEASE}" \
    TARGET_HOME="${MUTATION_HOME}" \
    bash "${MUTATION_REPO}/install.sh" >"${MUTATION_OUT}" 2>&1
) &
mutation_pid=$!

mutation_seen=0
attempt=0
while [[ "${attempt}" -lt 3000 ]]; do
  if [[ -e "${MUTATION_READY}" ]]; then
    mutation_seen=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.01
done
assert_eq "source mutation probe reaches sealed-snapshot barrier" \
  "1" "${mutation_seen}"
if [[ "${mutation_seen}" -eq 1 ]]; then
  printf '\nsource changed after snapshot\n' \
    >>"${MUTATION_REPO}/bundle/dot-claude/CLAUDE.md"
fi
: >"${MUTATION_RELEASE}"
wait "${mutation_pid}" || mutation_rc=$?

assert_eq "source mutation is refused" "1" "${mutation_rc}"
assert_contains_file "source mutation refusal is explicit" \
  "source distribution changed after preflight" "${MUTATION_OUT}"
assert_eq "source refusal publishes no bundle" "false" \
  "$([[ -e "${MUTATION_HOME}/.claude/statusline.py" ]] \
    && printf true || printf false)"
assert_eq "source refusal preserves foreign files" \
  "mutation-home-sentinel" \
  "$(<"${MUTATION_HOME}/.claude/foreign.keep")"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -ne 0 ]]; then
  printf 'Fresh install output: %s\n' "${INSTALL_OUT}" >&2
  printf 'Reinstall output: %s\n' "${REINSTALL_OUT}" >&2
  printf 'Mutation output: %s\n' "${MUTATION_OUT}" >&2
  exit 1
fi
