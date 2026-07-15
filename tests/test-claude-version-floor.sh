#!/usr/bin/env bash
# Runtime contract for the closeout hook stack's Claude Code version floor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORIG_PATH="${PATH}"
pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "${FAKE_CLAUDE_VERSION:-unparseable}"' \
  >"${tmp}/bin/claude"
chmod +x "${tmp}/bin/claude"
export PATH="${tmp}/bin:${ORIG_PATH}"

# Unit-check the installer's comparator independently of installer side effects.
version_function="$(awk '
  /^claude_code_version_at_least\(\)/ {capture=1}
  capture {print}
  capture && /^}/ {exit}
' "${REPO_ROOT}/install.sh")"
eval "${version_function}"

FAKE_CLAUDE_VERSION=2.1.162
export FAKE_CLAUDE_VERSION
rc=0
claude_code_version_at_least 163 || rc=$?
[[ "${rc}" -eq 1 ]] && ok || bad "2.1.162 should be below the floor (rc=${rc})"

FAKE_CLAUDE_VERSION=2.1.163
rc=0
claude_code_version_at_least 163 || rc=$?
[[ "${rc}" -eq 0 ]] && ok || bad "2.1.163 should meet the floor (rc=${rc})"

FAKE_CLAUDE_VERSION=2.2.0
rc=0
claude_code_version_at_least 163 || rc=$?
[[ "${rc}" -eq 0 ]] && ok || bad "newer minor should meet the floor (rc=${rc})"

FAKE_CLAUDE_VERSION='Claude Code development build'
rc=0
claude_code_version_at_least 163 || rc=$?
[[ "${rc}" -eq 2 ]] && ok || bad "unparseable version should be distinguishable (rc=${rc})"

# The old-client refusal must happen before creating the target installation.
old_home="${tmp}/old-home"
FAKE_CLAUDE_VERSION=2.1.162
old_rc=0
old_out="$(TARGET_HOME="${old_home}" bash "${REPO_ROOT}/install.sh" --no-ghostty 2>&1)" \
  || old_rc=$?
[[ "${old_rc}" -ne 0 ]] && ok || bad "installer accepted Claude Code 2.1.162"
[[ "${old_out}" == *'2.1.163 or newer is required'* ]] && ok \
  || bad "old-client refusal did not name the required version"
[[ ! -e "${old_home}/.claude" ]] && ok \
  || bad "old-client preflight mutated the target home"

# The exact boundary must install and verify successfully in an isolated home.
new_home="${tmp}/new-home"
FAKE_CLAUDE_VERSION=2.1.163
new_rc=0
new_out="$(TARGET_HOME="${new_home}" bash "${REPO_ROOT}/install.sh" --no-ghostty 2>&1)" \
  || new_rc=$?
[[ "${new_rc}" -eq 0 ]] && ok \
  || bad "installer rejected Claude Code 2.1.163: ${new_out}"
[[ -f "${new_home}/.claude/settings.json" ]] && ok \
  || bad "boundary install did not create settings.json"

verify_rc=0
verify_out="$(TARGET_HOME="${new_home}" bash "${REPO_ROOT}/verify.sh" 2>&1)" \
  || verify_rc=$?
[[ "${verify_rc}" -eq 0 ]] && ok \
  || bad "boundary install did not verify: ${verify_out}"
[[ "${verify_out}" =~ Errors:[[:space:]]+0 ]] && ok \
  || bad "boundary verifier did not report Errors: 0"
[[ "${verify_out}" == *'complete closeout hook stack (2.1.163)'* ]] && ok \
  || bad "verifier did not acknowledge the boundary version"

printf '\nClaude version floor: %d passed, %d failed\n' "${pass}" "${fail}"
exit "${fail}"
