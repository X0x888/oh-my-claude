#!/usr/bin/env bash
set -euo pipefail

# Essential uninstall coverage only: one realistic managed tree, preservation
# of foreign/user state, and the explicit destructive-purge boundary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' \
      "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_exists() {
  local label="$1" path="$2"
  assert_eq "${label}" true \
    "$([[ -e "${path}" || -L "${path}" ]] && printf true || printf false)"
}

assert_missing() {
  local label="$1" path="$2"
  assert_eq "${label}" false \
    "$([[ -e "${path}" || -L "${path}" ]] && printf true || printf false)"
}

command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for uninstall merge tests.\n' >&2
  exit 1
}

printf 'Essential uninstall behavior:\n'

# The filesystem root is never a valid managed home. Refusal must happen at
# startup, before the operation lock can create /.claude.
root_target_rc=0
root_target_out="$(TARGET_HOME=/ \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || root_target_rc=$?
assert_eq "filesystem-root TARGET_HOME is refused" 1 "${root_target_rc}"
assert_eq "filesystem-root refusal identifies the unsafe root" 1 \
  "$(grep -c 'TARGET_HOME must be an existing, non-symlink absolute directory' \
    <<<"${root_target_out}" || true)"

# Build one representative managed tree without duplicating the exhaustive
# artifact inventory owned by test-install-artifacts.sh.
installed_home="${TEST_ROOT}/installed-home"
claude_home="${installed_home}/.claude"
mkdir -p "${claude_home}/quality-pack" \
  "${claude_home}/skills/autowork" "${claude_home}/agents"
printf 'managed quality pack\n' >"${claude_home}/quality-pack/marker"
printf 'managed skill\n' >"${claude_home}/skills/autowork/marker"
printf 'managed agent\n' >"${claude_home}/agents/quality-reviewer.md"
printf 'managed statusline\n' >"${claude_home}/statusline.py"

# Start from the exact settings ownership authority, then add unrelated user
# state at both the JSON and filesystem surfaces.
jq '
  .userSetting = "keep"
  | .hooks.Stop[0].hooks += [{
      type: "command",
      command: "$HOME/.claude/user-stop-mixed.sh"
    }]
  | .hooks.Stop += [{
      matcher: "foreign",
      hooks: [{type: "command", command: "$HOME/.claude/user-stop.sh"}]
    }]
' "${REPO_ROOT}/config/settings.patch.json" >"${claude_home}/settings.json"
mkdir -p "${claude_home}/agents" \
  "${claude_home}/skills/user-skill" \
  "${claude_home}/backups/user-backup" \
  "${claude_home}/omc-user/quality-constitutions/profiles/default"
printf 'foreign agent\n' >"${claude_home}/agents/user-agent.md"
printf 'foreign skill\n' >"${claude_home}/skills/user-skill/SKILL.md"
printf 'user backup\n' >"${claude_home}/backups/user-backup/marker"
printf '%s\n' '{"schema_version":1,"profile":"default"}' \
  >"${claude_home}/omc-user/quality-constitutions/profiles/default/constitution.json"

ordinary_rc=0
ordinary_out="$(TARGET_HOME="${installed_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes 2>&1)" || ordinary_rc=$?
if [[ "${ordinary_rc}" -ne 0 ]]; then
  printf '%s\n' "${ordinary_out}" >&2
fi
assert_eq "ordinary uninstall succeeds" 0 "${ordinary_rc}"
assert_missing "managed quality-pack is removed" \
  "${claude_home}/quality-pack"
assert_missing "managed skill is removed" \
  "${claude_home}/skills/autowork"
assert_missing "managed agent is removed" \
  "${claude_home}/agents/quality-reviewer.md"
assert_missing "managed statusline is removed" \
  "${claude_home}/statusline.py"
assert_eq "foreign settings key survives" keep \
  "$(jq -r '.userSetting' "${claude_home}/settings.json")"
assert_eq "foreign hook survives" 1 \
  "$(jq '[.hooks.Stop[]? | select(.matcher == "foreign")] | length' \
    "${claude_home}/settings.json")"
assert_eq "foreign hook in a mixed managed entry survives" 1 \
  "$(jq '[.hooks.Stop[]?.hooks[]?
      | select(.command == "$HOME/.claude/user-stop-mixed.sh")] | length' \
    "${claude_home}/settings.json")"
assert_eq "managed sibling is removed from the mixed entry" 0 \
  "$(jq '[.hooks.Stop[]?.hooks[]?
      | select(.command == "$HOME/.claude/skills/autowork/scripts/stop-dispatch.sh")] | length' \
    "${claude_home}/settings.json")"
assert_eq "managed hook commands are removed" 0 \
  "$(jq '[.. | objects | .command? | strings
      | select(contains("$HOME/.claude/quality-pack/")
          or contains("$HOME/.claude/skills/autowork/"))] | length' \
    "${claude_home}/settings.json")"
assert_exists "foreign agent survives" \
  "${claude_home}/agents/user-agent.md"
assert_exists "foreign skill survives" \
  "${claude_home}/skills/user-skill/SKILL.md"
assert_exists "user backup survives" \
  "${claude_home}/backups/user-backup/marker"
constitution_file="${claude_home}/omc-user/quality-constitutions/profiles/default/constitution.json"
assert_exists "ordinary uninstall preserves Constitution data" \
  "${constitution_file}"
assert_eq "ordinary summary reports Constitution preservation" 1 \
  "$(grep -c 'Quality Constitution data was preserved' \
    <<<"${ordinary_out}" || true)"

# Purge-only remains available after the harness has already been removed.
purge_rc=0
purge_out="$(TARGET_HOME="${installed_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
    --purge-quality-constitutions 2>&1)" || purge_rc=$?
if [[ "${purge_rc}" -ne 0 ]]; then
  printf '%s\n' "${purge_out}" >&2
fi
assert_eq "explicit purge succeeds after ordinary uninstall" 0 "${purge_rc}"
assert_missing "explicit purge removes only Constitution root" \
  "${claude_home}/omc-user/quality-constitutions"
assert_exists "explicit purge preserves other user skill" \
  "${claude_home}/skills/user-skill/SKILL.md"
assert_eq "purge summary reports destructive action" 1 \
  "$(grep -c 'Quality Constitution data was explicitly purged' \
    <<<"${purge_out}" || true)"

# A user-controlled symlink must never redirect explicit purge outside the
# selected home, and refusal must occur before managed harness mutation.
unsafe_home="${TEST_ROOT}/unsafe-home"
external_root="${TEST_ROOT}/external-user-data"
mkdir -p "${unsafe_home}/.claude/quality-pack" \
  "${external_root}/quality-constitutions/profiles/default"
printf 'managed\n' >"${unsafe_home}/.claude/quality-pack/marker"
printf 'external\n' \
  >"${external_root}/quality-constitutions/profiles/default/constitution.json"
ln -s "${external_root}" "${unsafe_home}/.claude/omc-user"

unsafe_rc=0
unsafe_out="$(TARGET_HOME="${unsafe_home}" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
    --purge-quality-constitutions 2>&1)" || unsafe_rc=$?
assert_eq "symlinked purge is refused" 1 "${unsafe_rc}"
assert_exists "symlink refusal preserves external Constitution data" \
  "${external_root}/quality-constitutions/profiles/default/constitution.json"
assert_exists "symlink refusal leaves managed harness untouched" \
  "${unsafe_home}/.claude/quality-pack/marker"
assert_eq "symlink refusal identifies the unsafe boundary" 1 \
  "$(grep -c 'symlinked path component' <<<"${unsafe_out}" || true)"

# A trailing slash must not turn a symlinked TARGET_HOME into an apparently
# real directory before physical canonicalization.
target_alias="${TEST_ROOT}/target-home-alias"
target_external="${TEST_ROOT}/target-home-external"
mkdir -p "${target_external}/.claude/quality-pack" \
  "${target_external}/.claude/omc-user/quality-constitutions/profiles/default"
printf 'managed\n' >"${target_external}/.claude/quality-pack/marker"
printf 'external\n' \
  >"${target_external}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json"
ln -s "${target_external}" "${target_alias}"

target_alias_rc=0
target_alias_out="$(TARGET_HOME="${target_alias}/" \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
    --purge-quality-constitutions 2>&1)" || target_alias_rc=$?
assert_eq "trailing-slash TARGET_HOME symlink is refused" 1 \
  "${target_alias_rc}"
assert_exists "TARGET_HOME refusal preserves external Constitution data" \
  "${target_external}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json"
assert_exists "TARGET_HOME refusal leaves external harness untouched" \
  "${target_external}/.claude/quality-pack/marker"
assert_eq "TARGET_HOME refusal identifies the unsafe root" 1 \
  "$(grep -c 'TARGET_HOME must be an existing, non-symlink absolute directory' \
    <<<"${target_alias_out}" || true)"

# Dot components must not hide the same symlinked root from the lexical leaf
# check before physical canonicalization.
target_dot_rc=0
target_dot_out="$(TARGET_HOME="${target_alias}/." \
  bash "${REPO_ROOT}/uninstall.sh" --yes \
    --purge-quality-constitutions 2>&1)" || target_dot_rc=$?
assert_eq "dot-component TARGET_HOME symlink is refused" 1 \
  "${target_dot_rc}"
assert_exists "dot-component refusal preserves external Constitution data" \
  "${target_external}/.claude/omc-user/quality-constitutions/profiles/default/constitution.json"
assert_exists "dot-component refusal leaves external harness untouched" \
  "${target_external}/.claude/quality-pack/marker"
assert_eq "dot-component refusal identifies the unsafe root" 1 \
  "$(grep -c 'TARGET_HOME must not contain . or .. path components' \
    <<<"${target_dot_out}" || true)"

printf '\n=== Essential uninstall tests: %d passed, %d failed ===\n' \
  "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
