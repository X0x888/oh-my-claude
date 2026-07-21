#!/usr/bin/env bash
# test-omc-doctor.sh — focused regression for omc-doctor.sh (v1.48 W2).
#
# The doctor's contract: standalone diagnosis of the INSTALLED tree at
# ~/.claude (override: OMC_DOCTOR_CLAUDE_HOME), no common.sh dependency —
# a broken install is exactly when sourcing harness code would mask the
# problem. Exit 0 iff zero FAIL lines.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCTOR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-doctor.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q\n    actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %q\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# Build a minimal healthy synthetic install.
build_healthy() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}/skills/autowork/scripts/lib" \
           "${root}/quality-pack/scripts" \
           "${root}/quality-pack/memory" \
           "${root}/quality-pack/state" \
           "${root}/agents" "${root}/skills/demo"
  printf '#!/usr/bin/env bash\ntrue\n' > "${root}/skills/autowork/scripts/common.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${root}/skills/autowork/scripts/stop-guard.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${root}/skills/autowork/scripts/lib/classifier.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${root}/quality-pack/scripts/prompt-intent-router.sh"
  chmod +x "${root}/skills/autowork/scripts/common.sh" \
           "${root}/skills/autowork/scripts/stop-guard.sh" \
           "${root}/skills/autowork/scripts/lib/classifier.sh" \
           "${root}/quality-pack/scripts/prompt-intent-router.sh"
  printf 'core\n'   > "${root}/quality-pack/memory/core.md"
  printf 'skills\n' > "${root}/quality-pack/memory/skills.md"
  printf '@~/.claude/quality-pack/memory/core.md\n' > "${root}/CLAUDE.md"
  # The @-include resolver expands ~ to $HOME — point HOME-relative include
  # content at real files via the test HOME below.
  jq -n '{hooks: {Stop: [{hooks: [{type: "command",
    command: "$HOME/.claude/skills/autowork/scripts/stop-guard.sh"}]}]}}' \
    > "${root}/settings.json"
  {
    printf 'installed_version=0.0.1\n'
    printf 'installed_version=  9.9.9  \r\n'
  } > "${root}/oh-my-claude.conf"
  printf -- '---\nname: demo\n---\n' > "${root}/skills/demo/SKILL.md"
  printf -- '---\nname: a\n---\n' > "${root}/agents/a.md"
}

run_doctor() {
  local root="$1"
  OMC_DOCTOR_CLAUDE_HOME="${root}" HOME="${WORK}/home" bash "${DOCTOR}" 2>&1
}

# Doctor resolves @-includes and hook $HOME paths against $HOME/.claude —
# mirror the synthetic root there so a healthy tree resolves cleanly.
mkdir -p "${WORK}/home"
ln -sfn "${WORK}/root" "${WORK}/home/.claude"

# ----------------------------------------------------------------------
printf 'T1: healthy synthetic install passes\n'
build_healthy "${WORK}/root"
rc=0; out_t1="$(run_doctor "${WORK}/root")" || rc=$?
assert_eq "T1: exit 0" "0" "${rc}"
assert_contains "T1: zero FAILs reported" ", 0 FAIL" "${out_t1}"
assert_contains "T1: version read" "installed version: 9.9.9" "${out_t1}"

# ----------------------------------------------------------------------
printf 'T2: broken @-include is a FAIL\n'
build_healthy "${WORK}/root"
printf '@~/.claude/quality-pack/memory/missing-doctrine.md\n' >> "${WORK}/root/CLAUDE.md"
rc=0; out_t2="$(run_doctor "${WORK}/root")" || rc=$?
assert_eq "T2: exit 1" "1" "${rc}"
assert_contains "T2: names the broken include" "broken @-include" "${out_t2}"

# ----------------------------------------------------------------------
printf 'T3: hook referencing a missing script is a FAIL\n'
build_healthy "${WORK}/root"
jq -n '{hooks: {Stop: [{hooks: [{type: "command",
  command: "$HOME/.claude/skills/autowork/scripts/gone-forever.sh"}]}]}}' \
  > "${WORK}/root/settings.json"
rc=0; out_t3="$(run_doctor "${WORK}/root")" || rc=$?
assert_eq "T3: exit 1" "1" "${rc}"
assert_contains "T3: names the missing hook script" "missing script" "${out_t3}"

# ----------------------------------------------------------------------
printf 'T4: non-executable hook script is a warn, not a FAIL\n'
build_healthy "${WORK}/root"
chmod -x "${WORK}/root/skills/autowork/scripts/stop-guard.sh"
rc=0; out_t4="$(run_doctor "${WORK}/root")" || rc=$?
assert_eq "T4: exit 0 (warn only)" "0" "${rc}"
assert_contains "T4: names the non-executable script" "not executable" "${out_t4}"

# ----------------------------------------------------------------------
printf 'T5: missing settings.json is a FAIL with recovery text\n'
build_healthy "${WORK}/root"
rm -f "${WORK}/root/settings.json"
rc=0; out_t5="$(run_doctor "${WORK}/root")" || rc=$?
assert_eq "T5: exit 1" "1" "${rc}"
assert_contains "T5: recovery path printed" "Recovery" "${out_t5}"

# ----------------------------------------------------------------------
printf '\n=== omc-doctor tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
