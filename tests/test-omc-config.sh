#!/usr/bin/env bash
# test-omc-config.sh — coverage for the /omc-config skill backend.
#
# Validates the omc-config.sh helper that backs the /omc-config skill:
#   - detect-mode emits not-installed | setup | update | change correctly
#   - show prints a non-empty table and respects defaults
#   - set/apply-preset write atomically (validation runs before write)
#   - set rejects unknown flags, bad enum values, bad bool/int values
#   - apply-preset rejects unknown profiles
#   - mark-completed stamps the sentinel that flips setup → change
#   - project scope writes under PWD/.claude/, user scope writes under HOME/.claude/
#   - preserved-keys: writes never strip keys other than those being set
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"
COMMON="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

if [[ ! -f "${HELPER}" ]]; then
  printf 'FAIL: helper not found at %s\n' "${HELPER}" >&2
  exit 1
fi

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%q actual=%q\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unexpected match: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_has_line() {
  local label="$1" file="$2" pattern="$3"
  if grep -qE "${pattern}" "${file}" 2>/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file=%s\n    pattern=%s\n    contents:\n' "${label}" "${file}" "${pattern}" >&2
    cat "${file}" >&2 || true
    fail=$((fail + 1))
  fi
}

assert_file_lacks_line() {
  local label="$1" file="$2" pattern="$3"
  if [[ ! -f "${file}" ]] || ! grep -qE "${pattern}" "${file}" 2>/dev/null; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file=%s\n    pattern=%s should NOT match\n' "${label}" "${file}" "${pattern}" >&2
    fail=$((fail + 1))
  fi
}

# Use a fresh tmp HOME for each test so they cannot interact.
setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude"
  export USER_CONF_PATH="${TEST_HOME}/.claude/oh-my-claude.conf"
}

teardown() {
  rm -rf "${TEST_HOME}"
  unset HOME USER_CONF_PATH
}

# Stub repo with a VERSION file so resolve_bundle_version returns a real value.
make_stub_repo() {
  local repo="$1" version="$2"
  mkdir -p "${repo}"
  printf '%s\n' "${version}" > "${repo}/VERSION"
}

install_real_model_switch_fixture() {
  cp -R "${REPO_ROOT}/bundle/dot-claude/agents" "${TEST_HOME}/.claude/agents"
  cp "${REPO_ROOT}/bundle/dot-claude/switch-tier.sh" \
    "${TEST_HOME}/.claude/switch-tier.sh"
  chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
}

install_minimal_parent_model_fixture() {
  mkdir -p "${TEST_HOME}/.claude/agents"
  cp "${REPO_ROOT}/bundle/dot-claude/agents/librarian.md" \
    "${TEST_HOME}/.claude/agents/librarian.md"
}

count_installed_model() {
  local model="$1"
  { grep -hE "^model: ${model}$" "${TEST_HOME}/.claude/agents/"*.md 2>/dev/null || true; } \
    | wc -l | tr -d '[:space:]'
}

installed_agent_model() {
  local agent="$1"
  sed -n 's/^model: //p' "${TEST_HOME}/.claude/agents/${agent}.md" | head -1
}

file_mode() {
  local path="$1"
  stat -f '%Lp' "${path}" 2>/dev/null \
    || stat -c '%a' "${path}" 2>/dev/null
}

agent_tree_digest() {
  find "${TEST_HOME}/.claude/agents" -type f -name '*.md' -print \
    | sort \
    | while IFS= read -r agent_file; do
        printf '%s  %s\n' "$(cksum < "${agent_file}")" \
          "${agent_file#"${TEST_HOME}/.claude/agents/"}"
      done \
    | cksum
}

wait_for_file() {
  local path="$1" attempt=0
  while [[ ! -e "${path}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 1000 ]] || return 1
    sleep 0.01
  done
}

remove_killed_owner_lock() {
  local expected_pid="$1" lock="${TEST_HOME}/.claude/.install.lock"
  [[ -d "${lock}" && ! -L "${lock}" \
      && "$(cat "${lock}/pid" 2>/dev/null || true)" == "${expected_pid}" ]] \
    || return 1
  local participant=""
  for participant in "${lock}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 1
  done
  rm -f -- "${lock}/pid" "${lock}/token" || return 1
  rmdir "${lock}"
}

# --- Test 1: detect-mode handles missing conf ---
printf 'Test 1: detect-mode without conf returns not-installed\n'
setup
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode no-conf" "not-installed" "${out}"
teardown

# --- Test 2: detect-mode with metadata only returns setup ---
printf 'Test 2: detect-mode after install (no sentinel) returns setup\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode setup" "setup" "${out}"
teardown

# --- Test 3: detect-mode with sentinel + bundle == installed returns change ---
printf 'Test 3: detect-mode after sentinel and matching bundle returns change\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode change" "change" "${out}"
teardown

# --- Test 4: detect-mode with bundle > installed returns update ---
printf 'Test 4: detect-mode after sentinel but bundle ahead returns update\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.23.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode update" "update" "${out}"
teardown

# --- Test 5: detect-mode with bundle == installed (sentinel set) is change, not update ---
printf 'Test 5: detect-mode does not regress to update when versions equal\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
  printf 'gate_level=full\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode equal versions" "change" "${out}"
teardown

# --- Test 6: show prints a table and lists known flags ---
printf 'Test 6: show prints table with known flags\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" show 2>&1)"
assert_contains "show contains FLAG header" "FLAG" "${out}"
assert_contains "show contains gate_level row" "gate_level" "${out}"
assert_contains "show contains resume_watchdog row" "resume_watchdog" "${out}"
assert_contains "show shows installed version" "1.22.0" "${out}"
teardown

# --- Test 7: set writes to user scope ---
printf 'Test 7: set user gate_level=basic writes correctly\n'
setup
out="$(bash "${HELPER}" set user gate_level=basic 2>&1)"
assert_contains "set reports success" "wrote 1 key(s)" "${out}"
assert_file_has_line "user conf has gate_level=basic" "${USER_CONF_PATH}" "^gate_level=basic\$"
teardown

# --- Test 8: set rejects unknown flag (no write) ---
printf 'Test 8: set rejects unknown flag and does not write\n'
setup
set +e
out="$(bash "${HELPER}" set user nonsense_flag=true 2>&1)"
rc=$?
set -e
assert_eq "set unknown flag exit code 2" "2" "${rc}"
assert_contains "set unknown flag error" "unknown flag" "${out}"
# Conf should not exist (no successful write).
if [[ ! -f "${USER_CONF_PATH}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: set rejected but conf was written\n' >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 9: set rejects bad enum value (no write) ---
printf 'Test 9: set rejects bad enum value\n'
setup
printf 'repo_path=/x\ninstalled_version=1.22.0\n' > "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user gate_level=BANANA 2>&1)"
rc=$?
set -e
assert_eq "set bad enum exit code 2" "2" "${rc}"
assert_contains "set bad enum error" "must be one of basic/standard/full" "${out}"
# Verify conf was not modified — gate_level should still be absent.
assert_file_lacks_line "no gate_level row written" "${USER_CONF_PATH}" "^gate_level="
teardown

# --- Test 10: set rejects bad bool value ---
printf 'Test 10: set rejects bad bool value\n'
setup
set +e
out="$(bash "${HELPER}" set user auto_memory=YES 2>&1)"
rc=$?
set -e
assert_eq "set bad bool exit code 2" "2" "${rc}"
assert_contains "set bad bool error" "must be on|off" "${out}"
teardown

# --- Test 11: set rejects bad int value ---
printf 'Test 11: set rejects bad int value\n'
setup
set +e
out="$(bash "${HELPER}" set user verify_confidence_threshold=ABC 2>&1)"
rc=$?
set -e
assert_eq "set bad int exit code 2" "2" "${rc}"
assert_contains "set bad int error" "must be a non-negative integer" "${out}"
teardown

# --- Test 12: set is atomic — bad value in batch rejects whole batch ---
printf 'Test 12: set is atomic across multi-key batch\n'
setup
printf 'repo_path=/x\ninstalled_version=1.22.0\n' > "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user gate_level=full auto_memory=YES discovered_scope=on 2>&1)"
rc=$?
set -e
assert_eq "atomic batch exit code 2" "2" "${rc}"
# None of the three keys should have been written.
assert_file_lacks_line "atomic batch: gate_level not written" "${USER_CONF_PATH}" "^gate_level=full\$"
assert_file_lacks_line "atomic batch: auto_memory not written" "${USER_CONF_PATH}" "^auto_memory="
assert_file_lacks_line "atomic batch: discovered_scope not written" "${USER_CONF_PATH}" "^discovered_scope=on\$"
teardown

# --- Test 13: apply-preset maximum writes all keys (v1.28.0 added
# blindspot_inventory + intent_broadening; v1.30.0 added prompt_persist;
# v1.32.0 added divergence_directive; v1.33.0 added directive_budget;
# v1.34.0 added inferred_contract for Delivery Contract v2;
# v1.35.0 added shortcut_ratio_gate for shortcut-on-big-tasks defense;
# zero-steering policy added quality_policy; v1.40.0 added
# no_defer_mode for the no-defer contract; v1.44 added
# god_scope_on_bare_prompt for the No-Out-of-Scope contract;
# v1.44-pre added circuit_breaker + transcript_archive;
# v1.46-pre added objective_contract_gate for the Codex /goal port
# objective-completion contract; workflow_substrate for the Workflow-
# tool execution substrate; goal_gate for the /goal relentless driver) ---
printf 'Test 13: apply-preset maximum writes 41 keys\n'
setup
install_real_model_switch_fixture
out="$(bash "${HELPER}" apply-preset user maximum 2>&1)"
assert_contains "apply-preset reports 41 keys" "41 keys" "${out}"
assert_file_has_line "maximum: gate_level=full" "${USER_CONF_PATH}" "^gate_level=full\$"
assert_file_has_line "maximum: workflow_substrate=on" "${USER_CONF_PATH}" "^workflow_substrate=on\$"
assert_file_has_line "maximum: guard_exhaustion_mode=block" "${USER_CONF_PATH}" "^guard_exhaustion_mode=block\$"
assert_file_has_line "maximum: quality_policy=zero_steering" "${USER_CONF_PATH}" "^quality_policy=zero_steering\$"
assert_file_has_line "maximum: definition_of_excellent=always" "${USER_CONF_PATH}" "^definition_of_excellent=always\$"
assert_file_has_line "maximum: quality_constitution=on" "${USER_CONF_PATH}" "^quality_constitution=on\$"
assert_file_has_line "maximum: taste_learning=adaptive" "${USER_CONF_PATH}" "^taste_learning=adaptive\$"
assert_file_has_line "maximum: Constitution context=4000" "${USER_CONF_PATH}" "^quality_constitution_max_context_chars=4000\$"
assert_file_has_line "maximum: prometheus_suggest=on" "${USER_CONF_PATH}" "^prometheus_suggest=on\$"
assert_file_has_line "maximum: metis_on_plan_gate=on" "${USER_CONF_PATH}" "^metis_on_plan_gate=on\$"
assert_file_has_line "maximum: resume_watchdog=on" "${USER_CONF_PATH}" "^resume_watchdog=on\$"
assert_file_has_line "maximum: prompt_persist=on" "${USER_CONF_PATH}" "^prompt_persist=on\$"
assert_file_has_line "maximum: model_tier=quality" "${USER_CONF_PATH}" "^model_tier=quality\$"
# v1.23.0: Maximum preset includes the three new flags (all on for the
# quality posture).
assert_file_has_line "maximum: exemplifying_directive=on" "${USER_CONF_PATH}" "^exemplifying_directive=on\$"
assert_file_has_line "maximum: exemplifying_scope_gate=on" "${USER_CONF_PATH}" "^exemplifying_scope_gate=on\$"
assert_file_has_line "maximum: prompt_text_override=on" "${USER_CONF_PATH}" "^prompt_text_override=on\$"
assert_file_has_line "maximum: mark_deferred_strict=on" "${USER_CONF_PATH}" "^mark_deferred_strict=on\$"
# v1.35.0: shortcut_ratio_gate=on in maximum (mechanical backstop for the
# shortcut-on-big-tasks pattern; complements mark_deferred_strict).
assert_file_has_line "maximum: shortcut_ratio_gate=on" "${USER_CONF_PATH}" "^shortcut_ratio_gate=on\$"
# Regression net: council_deep_default=on belongs in Maximum (consistent
# with model_tier=quality — every quality lever pulled). Originally
# shipped as `off` for cost reasons; corrected after user review pointed
# out the inconsistency. This assertion locks the right value in.
assert_file_has_line "maximum: council_deep_default=on" "${USER_CONF_PATH}" "^council_deep_default=on\$"
# v1.28.0: blindspot_inventory + intent_broadening included in maximum.
assert_file_has_line "maximum: blindspot_inventory=on" "${USER_CONF_PATH}" "^blindspot_inventory=on\$"
assert_file_has_line "maximum: intent_broadening=on" "${USER_CONF_PATH}" "^intent_broadening=on\$"
assert_file_has_line "maximum: directive_budget=maximum" "${USER_CONF_PATH}" "^directive_budget=maximum\$"
# v1.40.0: no_defer_mode=on in maximum (and zero-steering/balanced) is the
# load-bearing default for the no-defer contract. Power-user opt-out
# is no_defer_mode=off (minimal preset emits off — see Test 15).
assert_file_has_line "maximum: no_defer_mode=on" "${USER_CONF_PATH}" "^no_defer_mode=on\$"
# v1.47: objective_contract_arm_on_god_scope=on in maximum/balanced (bumps the
# key count 35->36); minimal emits off (god-scope + the gate are off there).
assert_file_has_line "maximum: objective_contract_arm_on_god_scope=on" "${USER_CONF_PATH}" "^objective_contract_arm_on_god_scope=on\$"
# v1.47 single-entrance embed: goal_auto_arm=on in maximum/balanced (bumps
# the key count 36->37); minimal emits off (auto-arm fires on prose, so the
# lightest-footprint preset opts out — sibling of arm_on_god_scope, NOT of
# goal_gate which is inert-until-armed and stays on everywhere).
assert_file_has_line "maximum: goal_auto_arm=on" "${USER_CONF_PATH}" "^goal_auto_arm=on\$"
teardown

# --- Test 14: apply-preset balanced writes balanced values ---
printf 'Test 14: apply-preset balanced writes balanced defaults\n'
setup
install_real_model_switch_fixture
bash "${HELPER}" apply-preset user balanced > /dev/null
assert_file_has_line "balanced: guard_exhaustion_mode=scorecard" "${USER_CONF_PATH}" "^guard_exhaustion_mode=scorecard\$"
assert_file_has_line "balanced: quality_policy=balanced" "${USER_CONF_PATH}" "^quality_policy=balanced\$"
assert_file_has_line "balanced: definition_of_excellent=adaptive" "${USER_CONF_PATH}" "^definition_of_excellent=adaptive\$"
assert_file_has_line "balanced: quality_constitution=on" "${USER_CONF_PATH}" "^quality_constitution=on\$"
assert_file_has_line "balanced: taste_learning=review" "${USER_CONF_PATH}" "^taste_learning=review\$"
assert_file_has_line "balanced: Constitution context=2400" "${USER_CONF_PATH}" "^quality_constitution_max_context_chars=2400\$"
assert_file_has_line "balanced: prometheus_suggest=off" "${USER_CONF_PATH}" "^prometheus_suggest=off\$"
assert_file_has_line "balanced: exemplifying_scope_gate=on" "${USER_CONF_PATH}" "^exemplifying_scope_gate=on\$"
assert_file_has_line "balanced: resume_watchdog=off" "${USER_CONF_PATH}" "^resume_watchdog=off\$"
assert_file_has_line "balanced: model_tier=balanced" "${USER_CONF_PATH}" "^model_tier=balanced\$"
assert_file_has_line "balanced: directive_budget=balanced" "${USER_CONF_PATH}" "^directive_budget=balanced\$"
assert_file_has_line "balanced: workflow_substrate=on" "${USER_CONF_PATH}" "^workflow_substrate=on\$"
# Counterpart to the Maximum assertion above — Balanced is where the
# council cost cap lives. If someone ever flips this to `on`, the cap
# moves and Balanced loses its reason to exist.
assert_file_has_line "balanced: council_deep_default=off" "${USER_CONF_PATH}" "^council_deep_default=off\$"
# v1.35.0: shortcut_ratio_gate stays on in balanced (mechanical defense
# is cheap and catches a real failure mode; no reason to relax in default).
assert_file_has_line "balanced: shortcut_ratio_gate=on" "${USER_CONF_PATH}" "^shortcut_ratio_gate=on\$"
# v1.47: goal_auto_arm on in balanced (high-precision, announced, cheap to undo).
assert_file_has_line "balanced: goal_auto_arm=on" "${USER_CONF_PATH}" "^goal_auto_arm=on\$"
teardown

# --- Test 15: apply-preset minimal writes minimal values ---
printf 'Test 15: apply-preset minimal writes minimal defaults\n'
setup
install_real_model_switch_fixture
bash "${HELPER}" apply-preset user minimal > /dev/null
assert_file_has_line "minimal: gate_level=basic" "${USER_CONF_PATH}" "^gate_level=basic\$"
assert_file_has_line "minimal: workflow_substrate=off" "${USER_CONF_PATH}" "^workflow_substrate=off\$"
assert_file_has_line "minimal: guard_exhaustion_mode=silent" "${USER_CONF_PATH}" "^guard_exhaustion_mode=silent\$"
assert_file_has_line "minimal: quality_policy=balanced" "${USER_CONF_PATH}" "^quality_policy=balanced\$"
assert_file_has_line "minimal: definition_of_excellent=off" "${USER_CONF_PATH}" "^definition_of_excellent=off\$"
assert_file_has_line "minimal: quality_constitution=off" "${USER_CONF_PATH}" "^quality_constitution=off\$"
assert_file_has_line "minimal: taste_learning=off" "${USER_CONF_PATH}" "^taste_learning=off\$"
assert_file_has_line "minimal: Constitution context=1200" "${USER_CONF_PATH}" "^quality_constitution_max_context_chars=1200\$"
assert_file_has_line "minimal: auto_memory=off" "${USER_CONF_PATH}" "^auto_memory=off\$"
assert_file_has_line "minimal: exemplifying_scope_gate=off" "${USER_CONF_PATH}" "^exemplifying_scope_gate=off\$"
assert_file_has_line "minimal: model_tier=economy" "${USER_CONF_PATH}" "^model_tier=economy\$"
assert_file_has_line "minimal: directive_budget=minimal" "${USER_CONF_PATH}" "^directive_budget=minimal\$"
# stop_failure_capture stays on across all presets (privacy + utility).
assert_file_has_line "minimal: stop_failure_capture stays on" "${USER_CONF_PATH}" "^stop_failure_capture=on\$"
# v1.47: minimal opts out of prose-triggered auto-arm (lightest footprint).
assert_file_has_line "minimal: goal_auto_arm=off" "${USER_CONF_PATH}" "^goal_auto_arm=off\$"
# v1.35.0: shortcut_ratio_gate=off in minimal (matches the minimal posture
# of releasing as many gates as possible while keeping safety-critical paths).
assert_file_has_line "minimal: shortcut_ratio_gate=off" "${USER_CONF_PATH}" "^shortcut_ratio_gate=off\$"
teardown

# --- Test 16: apply-preset rejects unknown profile ---
printf 'Test 16: apply-preset rejects unknown profile\n'
setup
set +e
out="$(bash "${HELPER}" apply-preset user nonsense 2>&1)"
rc=$?
set -e
assert_eq "apply-preset unknown profile exit code 2" "2" "${rc}"
assert_contains "apply-preset unknown profile error" "unknown preset" "${out}"
teardown

# --- Test 17: apply-preset preserves metadata keys (repo_path, installed_version) ---
printf 'Test 17: apply-preset preserves install metadata\n'
setup
install_real_model_switch_fixture
{
  printf 'repo_path=/Users/me/oh-my-claude\n'
  printf 'installed_version=1.22.0\n'
  printf 'installed_sha=abc123\n'
} > "${USER_CONF_PATH}"
bash "${HELPER}" apply-preset user balanced > /dev/null
assert_file_has_line "preset preserves repo_path" "${USER_CONF_PATH}" "^repo_path=/Users/me/oh-my-claude\$"
assert_file_has_line "preset preserves installed_version" "${USER_CONF_PATH}" "^installed_version=1.22.0\$"
assert_file_has_line "preset preserves installed_sha" "${USER_CONF_PATH}" "^installed_sha=abc123\$"
teardown

# --- Test 18: set replaces existing key in place (last-write-wins) ---
printf 'Test 18: set overwrites existing key value\n'
setup
{
  printf 'gate_level=basic\n'
  printf 'auto_memory=on\n'
} > "${USER_CONF_PATH}"
bash "${HELPER}" set user gate_level=full > /dev/null
# Should have exactly one gate_level line.
gate_count=$(grep -c '^gate_level=' "${USER_CONF_PATH}")
assert_eq "exactly one gate_level row" "1" "${gate_count}"
assert_file_has_line "gate_level updated to full" "${USER_CONF_PATH}" "^gate_level=full\$"
assert_file_has_line "auto_memory preserved" "${USER_CONF_PATH}" "^auto_memory=on\$"
teardown

# --- Test 19: set preserves comment lines ---
printf 'Test 19: set preserves user-authored comment lines\n'
setup
{
  printf '# user comment\n'
  printf 'gate_level=basic\n'
  printf '\n'
  printf '# another comment\n'
  printf 'auto_memory=on\n'
} > "${USER_CONF_PATH}"
bash "${HELPER}" set user gate_level=full > /dev/null
assert_file_has_line "first comment preserved" "${USER_CONF_PATH}" "^# user comment\$"
assert_file_has_line "second comment preserved" "${USER_CONF_PATH}" "^# another comment\$"
teardown

# --- Test 20: project scope writes under PWD/.claude ---
printf 'Test 20: project scope writes under cwd/.claude\n'
setup
project_dir="${TEST_HOME}/myproject"
mkdir -p "${project_dir}"
(
  cd "${project_dir}"
  bash "${HELPER}" set project gate_level=full > /dev/null
)
assert_file_has_line "project conf gets gate_level=full" "${project_dir}/.claude/oh-my-claude.conf" "^gate_level=full\$"
# User scope should remain untouched.
if [[ ! -f "${USER_CONF_PATH}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: project scope leaked to user conf\n' >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 21: set rejects unknown scope ---
printf 'Test 21: set rejects unknown scope\n'
setup
set +e
out="$(bash "${HELPER}" set bogus gate_level=full 2>&1)"
rc=$?
set -e
assert_eq "unknown scope exit code 2" "2" "${rc}"
assert_contains "unknown scope error" "unknown scope" "${out}"
teardown

# --- Test 22: mark-completed writes ISO timestamp sentinel ---
printf 'Test 22: mark-completed stamps ISO date\n'
setup
bash "${HELPER}" mark-completed user > /dev/null
assert_file_has_line "sentinel written" "${USER_CONF_PATH}" "^omc_config_completed=20[0-9]{2}-[0-9]{2}-[0-9]{2}T"
# After mark-completed, detect-mode should now return change (with stub repo).
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
} >> "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode after mark-completed" "change" "${out}"
teardown

# --- Test 23: presets subcommand prints kv pairs ---
printf 'Test 23: presets emits key=value lines\n'
setup
out="$(bash "${HELPER}" presets maximum 2>&1)"
assert_contains "presets maximum has gate_level" "gate_level=full" "${out}"
assert_contains "presets maximum has resume_watchdog" "resume_watchdog=on" "${out}"
assert_contains "presets maximum has directive_budget=maximum" "directive_budget=maximum" "${out}"
assert_contains "presets maximum has quality_policy=zero_steering" "quality_policy=zero_steering" "${out}"
# Maximum must include council_deep_default=on for internal consistency
# with model_tier=quality. Cost cap lives in Balanced.
assert_contains "presets maximum has council_deep_default=on" "council_deep_default=on" "${out}"
out="$(bash "${HELPER}" presets zero-steering 2>&1)"
assert_contains "presets zero-steering alias has gate_level" "gate_level=full" "${out}"
assert_contains "presets zero-steering alias has quality_policy" "quality_policy=zero_steering" "${out}"
out="$(bash "${HELPER}" presets minimal 2>&1)"
assert_contains "presets minimal has gate_level basic" "gate_level=basic" "${out}"
assert_contains "presets minimal has directive_budget=minimal" "directive_budget=minimal" "${out}"
teardown

# --- Test 24: presets rejects unknown profile ---
printf 'Test 24: presets rejects unknown profile\n'
setup
set +e
out="$(bash "${HELPER}" presets bogus 2>&1)"
rc=$?
set -e
assert_eq "presets unknown exit 2" "2" "${rc}"
assert_contains "presets unknown error" "unknown preset" "${out}"
teardown

# --- Test 25: apply-tier rejects bad tier ---
printf 'Test 25: apply-tier rejects bad tier name\n'
setup
set +e
out="$(bash "${HELPER}" apply-tier bogus 2>&1)"
rc=$?
set -e
assert_eq "apply-tier bad name exit 2" "2" "${rc}"
assert_contains "apply-tier bad name error" "must be quality|balanced|economy" "${out}"
teardown

# --- Test 26: apply-tier reports missing switcher ---
printf 'Test 26: apply-tier surfaces missing switch-tier.sh\n'
setup
set +e
out="$(bash "${HELPER}" apply-tier quality 2>&1)"
rc=$?
set -e
assert_eq "apply-tier missing switcher exit 1" "1" "${rc}"
assert_contains "apply-tier missing switcher error" "switch-tier.sh not found" "${out}"
teardown

# --- Test 27: install-watchdog reports missing installer ---
printf 'Test 27: install-watchdog surfaces missing installer\n'
setup
set +e
out="$(bash "${HELPER}" install-watchdog 2>&1)"
rc=$?
set -e
assert_eq "install-watchdog missing exit 1" "1" "${rc}"
assert_contains "install-watchdog missing installer error" "watchdog installer not found" "${out}"
teardown

# --- Test 28: list-flags emits valid JSON array ---
printf 'Test 28: list-flags emits valid JSON\n'
setup
out="$(bash "${HELPER}" list-flags 2>&1)"
# Must be valid JSON.
echo "${out}" | jq empty 2>/dev/null && pass=$((pass + 1)) || { printf '  FAIL: list-flags not valid JSON\n%s\n' "${out}" >&2; fail=$((fail + 1)); }
# Must contain known flag names — query JSON directly so the test does not
# depend on jq's pretty-print spacing.
gate_count=$(echo "${out}" | jq -r '[.[] | select(.name == "gate_level")] | length')
assert_eq "list-flags includes gate_level" "1" "${gate_count}"
watch_count=$(echo "${out}" | jq -r '[.[] | select(.name == "resume_watchdog")] | length')
assert_eq "list-flags includes resume_watchdog" "1" "${watch_count}"
# Each entry must have required fields.
count=$(echo "${out}" | jq 'length')
if [[ "${count}" -ge 20 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: list-flags returned only %d entries (expected ≥20)\n' "${count}" >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 29: usage on unknown subcommand exits 2 ---
printf 'Test 29: unknown subcommand exits 2 with usage\n'
setup
set +e
out="$(bash "${HELPER}" bogus-subcommand 2>&1)"
rc=$?
set -e
assert_eq "unknown subcommand exit 2" "2" "${rc}"
assert_contains "unknown subcommand surfaces usage hint" "Subcommands:" "${out}"
teardown

# --- Test 30: detect-mode with conf but no installed_version returns not-installed ---
printf 'Test 30: detect-mode with empty conf returns not-installed\n'
setup
printf '# placeholder only\n' > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "detect-mode empty conf" "not-installed" "${out}"
teardown

# --- Test 31 (P0-1): mark-completed project still stamps USER_CONF ---
printf 'Test 31: mark-completed project scope still stamps user conf\n'
setup
project_dir="${TEST_HOME}/myproject"
mkdir -p "${project_dir}/.claude"
(
  cd "${project_dir}"
  bash "${HELPER}" mark-completed project > /dev/null
)
# Sentinel must be in USER_CONF, not project conf.
assert_file_has_line "P0-1: sentinel in user conf" "${USER_CONF_PATH}" "^omc_config_completed="
assert_file_lacks_line "P0-1: sentinel NOT in project conf" "${project_dir}/.claude/oh-my-claude.conf" "^omc_config_completed="
teardown

# --- Test 32 (P0-1): detect-mode after project-scope mark-completed returns change ---
printf 'Test 32: detect-mode change after project-scope mark-completed\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.22.0"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/myproject"
mkdir -p "${project_dir}/.claude"
(
  cd "${project_dir}"
  bash "${HELPER}" mark-completed project > /dev/null
)
out="$(bash "${HELPER}" detect-mode)"
assert_eq "P0-1: detect-mode = change after project mark-completed" "change" "${out}"
teardown

# --- Test 33 (P0-2): within-batch dedup keeps last value ---
printf 'Test 33: set within-batch duplicate keys keep last value\n'
setup
bash "${HELPER}" set user gate_level=full gate_level=basic > /dev/null
gate_count=$(grep -c '^gate_level=' "${USER_CONF_PATH}")
assert_eq "P0-2: exactly one gate_level row" "1" "${gate_count}"
assert_file_has_line "P0-2: gate_level uses LAST value (basic)" "${USER_CONF_PATH}" "^gate_level=basic\$"
assert_file_lacks_line "P0-2: gate_level=full was discarded" "${USER_CONF_PATH}" "^gate_level=full\$"
teardown

# --- Test 34 (P0-2): within-batch dedup across multiple keys ---
printf 'Test 34: set within-batch dedup across multiple keys\n'
setup
bash "${HELPER}" set user gate_level=full auto_memory=on gate_level=basic auto_memory=off > /dev/null
gate_count=$(grep -c '^gate_level=' "${USER_CONF_PATH}")
mem_count=$(grep -c '^auto_memory=' "${USER_CONF_PATH}")
assert_eq "P0-2: exactly one gate_level row" "1" "${gate_count}"
assert_eq "P0-2: exactly one auto_memory row" "1" "${mem_count}"
assert_file_has_line "P0-2: gate_level=basic (last)" "${USER_CONF_PATH}" "^gate_level=basic\$"
assert_file_has_line "P0-2: auto_memory=off (last)" "${USER_CONF_PATH}" "^auto_memory=off\$"
teardown

# --- Test 35 (P1-3): newline in str-type value rejected ---
printf 'Test 35: set rejects newline-injected value in str type\n'
setup
set +e
out="$(bash "${HELPER}" set user "custom_verify_mcp_tools=foo
evil_smuggled=on" 2>&1)"
rc=$?
set -e
assert_eq "P1-3: newline in str exit code 2" "2" "${rc}"
assert_contains "P1-3: newline error message" "cannot contain newlines" "${out}"
# Conf must not have been written at all.
assert_file_lacks_line "P1-3: smuggled key not present" "${USER_CONF_PATH}" "^evil_smuggled="
assert_file_lacks_line "P1-3: legit key not present either (atomic)" "${USER_CONF_PATH}" "^custom_verify_mcp_tools="
teardown

# --- Test 36 (P1-3): carriage return in str-type value rejected ---
printf 'Test 36: set rejects carriage-return-injected value\n'
setup
set +e
# bash $'\r' literal CR
out="$(bash "${HELPER}" set user "custom_verify_mcp_tools=foo"$'\r'"bar" 2>&1)"
rc=$?
set -e
assert_eq "P1-3: carriage return exit 2" "2" "${rc}"
assert_contains "P1-3: CR error message" "cannot contain newlines or carriage returns" "${out}"
teardown

# --- Test 37 (P1-4): apply-preset auto-fires apply-tier when tier changes ---
printf 'Test 37: apply-preset invokes switch-tier.sh on tier change\n'
setup
install_minimal_parent_model_fixture
# Mock switch-tier.sh so we can detect invocation.
mkdir -p "${TEST_HOME}/.claude"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'mock-switch-tier called with: %s\n' "$*" >> "${HOME}/.claude/.switch-tier.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
# Seed conf with model_tier=balanced (the default).
{
  printf 'model_tier=balanced\n'
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
# Apply maximum preset (sets model_tier=quality — should trigger switch).
out="$(bash "${HELPER}" apply-preset user maximum 2>&1)"
assert_contains "P1-4: tier change announced" "model_tier changed" "${out}"
# Mock script must have been invoked.
inv_file="${TEST_HOME}/.claude/.switch-tier.invocations"
if [[ -f "${inv_file}" ]]; then
  inv_content="$(cat "${inv_file}")"
  assert_contains "P1-4: switch-tier called with quality" "quality" "${inv_content}"
else
  printf '  FAIL: P1-4: switch-tier.sh was NOT invoked\n' >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 38 (P1-4): an explicit preset repairs materialized tier drift ---
printf 'Test 38: apply-preset re-materializes an unchanged tier\n'
setup
install_minimal_parent_model_fixture
mkdir -p "${TEST_HOME}/.claude"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED: %s\n' "$*" >> "${HOME}/.claude/.switch-tier.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
# Seed conf with model_tier=balanced and apply balanced preset (same tier).
{
  printf 'model_tier=balanced\n'
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" apply-preset user balanced 2>&1)"
assert_not_contains "P1-4: no tier-change message when same" "model_tier changed" "${out}"
assert_contains "P1-4: unchanged preset announces repair" \
  "model_tier unchanged at balanced; re-materializing" "${out}"
assert_file_has_line "P1-4: unchanged preset invokes switch-tier for repair" \
  "${TEST_HOME}/.claude/.switch-tier.invocations" '^INVOKED: balanced$'
teardown

# --- Test 39 (P2-7): detect-mode rejects malformed VERSION (treats as unknown) ---
printf 'Test 39: detect-mode handles malformed VERSION gracefully\n'
setup
stub="${TEST_HOME}/repo"
mkdir -p "${stub}"
printf 'not-a-version\n' > "${stub}/VERSION"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
# Malformed VERSION → bundle = unknown → no version comparison → returns change
assert_eq "P2-7: malformed VERSION returns change not garbage" "change" "${out}"
teardown

# --- Test 40 (P2-7): detect-mode handles pre-release VERSION ---
printf 'Test 40: detect-mode handles pre-release VERSION\n'
setup
stub="${TEST_HOME}/repo"
make_stub_repo "${stub}" "1.23.0-rc1"
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
# 1.23.0-rc1 > 1.22.0 → update mode (semver pre-release supported by sort -V)
assert_eq "P2-7: pre-release VERSION accepted" "update" "${out}"
teardown

# --- Test 41 (P2-7): detect-mode handles missing VERSION file ---
printf 'Test 41: detect-mode handles missing VERSION file\n'
setup
stub="${TEST_HOME}/repo"
mkdir -p "${stub}"
# No VERSION file written
{
  printf 'repo_path=%s\n' "${stub}"
  printf 'installed_version=1.22.0\n'
  printf 'omc_config_completed=2026-04-30T00:00:00Z\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" detect-mode)"
assert_eq "P2-7: missing VERSION returns change" "change" "${out}"
teardown

# --- Test 42 (final P1 #2): show reflects project-scope override ---
printf 'Test 42: show reflects project-scope override over user value\n'
setup
{
  printf 'repo_path=/x\n'
  printf 'installed_version=1.22.0\n'
  printf 'gate_level=full\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/myproject"
mkdir -p "${project_dir}/.claude"
printf 'gate_level=basic\n' > "${project_dir}/.claude/oh-my-claude.conf"
# Run show from within the project so find_project_conf catches it.
out=$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)
assert_contains "show announces project conf" "project conf:" "${out}"
# The effective value for gate_level should now be `basic` (project override).
# Match the row: "* gate_level   basic   full   ... [P]"
echo "${out}" | grep -qE '^\s*\*\s*gate_level\s+basic\s+full\s+' && pass=$((pass + 1)) || \
  { printf '  FAIL: gate_level row should show effective value basic with star\n  out:\n%s\n' "${out}" >&2 ; fail=$((fail + 1)); }
# Source-tag column should mark gate_level as [P].
assert_contains "show shows [P] tag for project override" "[P]" "${out}"
teardown

# --- Test 43 (P1 #2): show without project conf falls back to user value ---
printf 'Test 43: show falls back to user conf when no project conf exists\n'
setup
{
  printf 'gate_level=basic\n'
} > "${USER_CONF_PATH}"
# Run from inside TEST_HOME so find_project_conf does not walk up into
# the dev environment and pick up the real user's ~/.claude conf.
out=$(cd "${TEST_HOME}" && bash "${HELPER}" show 2>&1)
# Effective value is user's `basic` (not the default `full`); marked [U].
echo "${out}" | grep -qE '^\s*\*\s*gate_level\s+basic\s+full\s+' && pass=$((pass + 1)) || \
  { printf '  FAIL: gate_level row should show user value basic with star\n  out:\n%s\n' "${out}" >&2 ; fail=$((fail + 1)); }
assert_contains "show shows [U] tag for user setting" "[U]" "${out}"
assert_not_contains "show without project: no [P] tag" "[P]" "${out}"
teardown

# --- Test 44 (P3 #7): cmd_set auto-fires apply-tier on tier change ---
printf 'Test 44: cmd_set auto-fires switch-tier.sh on model_tier change\n'
setup
install_minimal_parent_model_fixture
mkdir -p "${TEST_HOME}/.claude"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED: %s\n' "$*" >> "${HOME}/.claude/.set-switch-tier.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
{
  printf 'model_tier=balanced\n'
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
out=$(bash "${HELPER}" set user model_tier=quality 2>&1)
assert_contains "P3 #7: cmd_set announces tier change" "model_tier changed" "${out}"
inv_file="${TEST_HOME}/.claude/.set-switch-tier.invocations"
if [[ -f "${inv_file}" ]] && grep -q "quality" "${inv_file}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: P3 #7: switch-tier.sh was NOT invoked from cmd_set\n' >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 45 (P3 #7): explicit set repairs materialized tier drift ---
printf 'Test 45: cmd_set re-materializes an unchanged tier\n'
setup
install_minimal_parent_model_fixture
mkdir -p "${TEST_HOME}/.claude"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED\n' >> "${HOME}/.claude/.set-switch-tier-skip.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
{
  printf 'model_tier=balanced\n'
  printf 'installed_version=1.22.0\n'
} > "${USER_CONF_PATH}"
out=$(bash "${HELPER}" set user model_tier=balanced 2>&1)
assert_not_contains "P3 #7: no tier-change message when same" "model_tier changed" "${out}"
assert_contains "P3 #7: unchanged set announces repair" \
  "model_tier unchanged at balanced; re-materializing" "${out}"
assert_file_has_line "P3 #7: unchanged set invokes switch-tier for repair" \
  "${TEST_HOME}/.claude/.set-switch-tier-skip.invocations" '^INVOKED$'
teardown

# --- Test 46 (P3 #7): cmd_set without model_tier in batch does NOT trigger ---
printf 'Test 46: cmd_set without model_tier in batch never triggers switch-tier\n'
setup
mkdir -p "${TEST_HOME}/.claude"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED\n' >> "${HOME}/.claude/.set-no-tier.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
out=$(bash "${HELPER}" set user gate_level=full auto_memory=on 2>&1)
assert_not_contains "P3 #7: no tier-change for non-tier batch" "model_tier changed" "${out}"
if [[ ! -f "${TEST_HOME}/.claude/.set-no-tier.invocations" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: P3 #7: switch-tier.sh invoked when model_tier not in batch\n' >&2
  fail=$((fail + 1))
fi
teardown

# --- Test 47-50 (v1.31.0 Wave 6 design-lens F-028): output_style auto-syncs settings.json ---
printf 'Test 47: output_style change auto-syncs settings.json (opencode)\n'
setup
mkdir -p "${TEST_HOME}/.claude"
# Seed settings.json with the alternative bundled style.
printf '{"outputStyle":"executive-brief","other":"keep"}\n' > "${TEST_HOME}/.claude/settings.json"
printf 'output_style=opencode\n' > "${USER_CONF_PATH}"
bash "${HELPER}" set user output_style=opencode >/dev/null 2>&1
synced="$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 47: settings.json outputStyle synced to oh-my-claude" "oh-my-claude" "${synced}"
preserved="$(jq -r '.other' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 47: other settings.json keys preserved" "keep" "${preserved}"
teardown

printf 'Test 48: output_style change auto-syncs settings.json (executive)\n'
setup
mkdir -p "${TEST_HOME}/.claude"
printf '{"outputStyle":"oh-my-claude"}\n' > "${TEST_HOME}/.claude/settings.json"
bash "${HELPER}" set user output_style=executive >/dev/null 2>&1
synced="$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 48: settings.json outputStyle synced to executive-brief" "executive-brief" "${synced}"
teardown

printf 'Test 49: output_style=preserve does NOT touch settings.json\n'
setup
mkdir -p "${TEST_HOME}/.claude"
printf '{"outputStyle":"my-custom-style"}\n' > "${TEST_HOME}/.claude/settings.json"
bash "${HELPER}" set user output_style=preserve >/dev/null 2>&1
preserved_custom="$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 49: user-custom outputStyle preserved" "my-custom-style" "${preserved_custom}"
teardown

printf 'Test 50: explicit bundled-style choice replaces a current custom outputStyle\n'
setup
mkdir -p "${TEST_HOME}/.claude"
# `/omc-config set user` is direct user authority. `preserve` above is the
# no-touch choice; selecting opencode explicitly must activate it now.
printf '{"outputStyle":"my-very-custom-style"}\n' > "${TEST_HOME}/.claude/settings.json"
bash "${HELPER}" set user output_style=opencode >/dev/null 2>&1
synced_custom="$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 50: explicit opencode replaces custom outputStyle" \
  "oh-my-claude" "${synced_custom}"
teardown

printf 'Test 50b: explicit bundled-style choice creates missing settings.json\n'
setup
rm -f "${TEST_HOME}/.claude/settings.json"
bash "${HELPER}" set user output_style=executive >/dev/null 2>&1
assert_eq "Test 50b: missing settings.json is materialized" \
  "executive-brief" \
  "$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
teardown

# --- v1.32.16 (4-attacker security review, A2-LOW-5): claude_bin
# validator alignment with the parser. Pre-fix the omc-config writer
# accepted any non-newline string for claude_bin (type=str) while the
# common.sh parser silently dropped non-absolute paths — a writer/
# parser divergence that left bad pins on disk doing nothing. Now
# the writer enforces the parser's regex AND a path-prefix denylist.

printf 'Test 51: set claude_bin=relative-path rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=relative/path 2>&1)"
rc=$?
set -e
assert_eq "Test 51: set claude_bin=relative-path exit 2" "2" "${rc}"
assert_contains "Test 51: error names absolute-path requirement" \
  "must be an absolute path" "${out}"
teardown

printf 'Test 52: set claude_bin under /tmp/ rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/tmp/evil-claude 2>&1)"
rc=$?
set -e
assert_eq "Test 52: set claude_bin=/tmp/... exit 2" "2" "${rc}"
assert_contains "Test 52: error names world-writable rejection" \
  "world-writable" "${out}"
teardown

printf 'Test 53: set claude_bin under /Users/Shared/ rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/Users/Shared/evil 2>&1)"
rc=$?
set -e
assert_eq "Test 53: set claude_bin=/Users/Shared/... exit 2" "2" "${rc}"
teardown

printf 'Test 54: set claude_bin under /var/tmp/ rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/var/tmp/evil 2>&1)"
rc=$?
set -e
assert_eq "Test 54: set claude_bin=/var/tmp/... exit 2" "2" "${rc}"
teardown

printf 'Test 55: set claude_bin under /private/tmp/ rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/private/tmp/evil 2>&1)"
rc=$?
set -e
assert_eq "Test 55: set claude_bin=/private/tmp/... exit 2" "2" "${rc}"
teardown

printf 'Test 56: set claude_bin under /dev/shm/ rejected (Linux tmpfs)\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/dev/shm/evil 2>&1)"
rc=$?
set -e
assert_eq "Test 56: set claude_bin=/dev/shm/... exit 2" "2" "${rc}"
teardown

printf 'Test 56b: set claude_bin to an executable directory rejected\n'
setup
set +e
out="$(bash "${HELPER}" set user claude_bin=/bin 2>&1)"
rc=$?
set -e
assert_eq "Test 56b: set claude_bin=/bin exit 2" "2" "${rc}"
assert_contains "Test 56b: error requires executable file" \
  "existing executable file" "${out}"
teardown

printf 'Test 57: set claude_bin to legitimate path accepted\n'
setup
out="$(bash "${HELPER}" set user claude_bin=/bin/sh 2>&1)"
rc=$?
assert_eq "Test 57: set claude_bin=/bin/sh exit 0" "0" "${rc}"
# Verify it landed in the conf file.
written="$(grep '^claude_bin=' "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null \
  | head -1 | cut -d= -f2-)"
assert_eq "Test 57: legit claude_bin written to conf" "/bin/sh" "${written}"
teardown

# --- User-only authority + model materialization ---------------------------
# common.sh deliberately ignores a narrow deny-list from project config. The
# config UX must reproduce that rule exactly: show cannot present ignored
# values as effective, direct project writes fail atomically, and a project
# preset cannot mutate machine-wide enforcement/model state.

printf 'Test 58: show ignores project model values and marks user values effective\n'
setup
{
  printf 'installed_version=1.22.0\n'
  printf 'quality_policy=zero_steering\n'
  printf 'definition_of_excellent=always\n'
  printf 'quality_constitution=on\n'
  printf 'taste_learning=review\n'
  printf 'quality_constitution_max_context_chars=4000\n'
  printf 'repo_lessons=off\n'
  printf 'model_tier=quality\n'
  printf 'model_overrides=quality-reviewer:opus\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/model-project"
mkdir -p "${project_dir}/.claude"
{
  printf 'quality_policy=balanced\n'
  printf 'definition_of_excellent=off\n'
  printf 'quality_constitution=off\n'
  printf 'taste_learning=adaptive\n'
  printf 'quality_constitution_max_context_chars=512\n'
  printf 'repo_lessons=on\n'
  printf 'model_tier=economy\n'
  printf 'model_overrides=quality-reviewer:haiku\n'
} > "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
tier_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+model_tier[[:space:]]' || true)"
override_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+model_overrides[[:space:]]' || true)"
tier_value="$(awk '{print $3}' <<<"${tier_row}")"
override_value="$(awk '{print $3}' <<<"${override_row}")"
assert_contains "Test 58: ignored project model rows are explained" \
  "project model_tier/model_overrides entries are ignored" "${out}"
assert_eq "Test 58: user tier remains effective" "quality" "${tier_value}"
assert_contains "Test 58: user tier carries [U] provenance" "[U]" "${tier_row}"
assert_eq "Test 58: user override remains effective" \
  "quality-reviewer:opus" "${override_value}"
assert_contains "Test 58: user override carries [U] provenance" "[U]" "${override_row}"
assert_not_contains "Test 58: project override is not shown as effective" \
  "quality-reviewer:haiku" "${override_row}"
quality_policy_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+quality_policy[[:space:]]' || true)"
repo_lessons_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+repo_lessons[[:space:]]' || true)"
definition_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+definition_of_excellent[[:space:]]' || true)"
constitution_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+quality_constitution[[:space:]]' || true)"
taste_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+taste_learning[[:space:]]' || true)"
context_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+quality_constitution_max_context_chars[[:space:]]' || true)"
assert_contains "Test 58: full deny-list warning names enforcement row" \
  "quality_policy" "${out}"
assert_contains "Test 58: denied quality policy remains user-controlled" \
  "zero_steering" "${quality_policy_row}"
assert_contains "Test 58: denied quality policy carries [U]" "[U]" "${quality_policy_row}"
assert_contains "Test 58: denied persistence flag remains user-controlled" \
  "off" "${repo_lessons_row}"
assert_contains "Test 58: denied persistence flag carries [U]" "[U]" "${repo_lessons_row}"
assert_contains "Test 58: Definition remains user-controlled" "always" "${definition_row}"
assert_contains "Test 58: Constitution remains user-controlled" "on" "${constitution_row}"
assert_contains "Test 58: taste learning remains user-controlled" "review" "${taste_row}"
assert_contains "Test 58: Constitution cap remains user-controlled" "4000" "${context_row}"
teardown

printf 'Test 59: direct project model writes fail atomically without tier side effects\n'
setup
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED: %s\n' "$*" >> "${HOME}/.claude/.project-model-switch.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
project_dir="${TEST_HOME}/model-project"
mkdir -p "${project_dir}"
set +e
out="$(cd "${project_dir}" && bash "${HELPER}" set project \
  gate_level=basic model_tier=economy 2>&1)"
rc=$?
set -e
assert_eq "Test 59: project model_tier write exits 2" "2" "${rc}"
assert_contains "Test 59: rejection names user-only authority" "model_tier is user-only" "${out}"
assert_file_lacks_line "Test 59: safe sibling is not half-written" \
  "${project_dir}/.claude/oh-my-claude.conf" '^gate_level='
if [[ ! -f "${TEST_HOME}/.claude/.project-model-switch.invocations" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: Test 59: rejected project model_tier invoked switch-tier.sh\n' >&2
  fail=$((fail + 1))
fi
set +e
out="$(cd "${project_dir}" && bash "${HELPER}" set project \
  model_overrides=quality-reviewer:haiku 2>&1)"
rc=$?
set -e
assert_eq "Test 59: project model_overrides write exits 2" "2" "${rc}"
assert_contains "Test 59: override rejection names user-only authority" \
  "model_overrides is user-only" "${out}"
assert_file_lacks_line "Test 59: rejected override is absent" \
  "${project_dir}/.claude/oh-my-claude.conf" '^model_overrides='
printf '{"outputStyle":"oh-my-claude"}\n' \
  > "${TEST_HOME}/.claude/settings.json"

denied_pairs=(
  'pretool_intent_guard=false'
  'bg_spawn_gate=false'
  'agent_first_gate=on'
  'no_defer_mode=off'
  'quality_policy=balanced'
  'definition_of_excellent=off'
  'quality_constitution=off'
  'taste_learning=adaptive'
  'quality_constitution_max_context_chars=512'
  'model_tier=economy'
  'model_overrides=quality-reviewer:haiku'
  'council_deep_default=on'
  'workflow_substrate=on'
  'repo_lessons=on'
  'auto_tune=on'
  'output_style=executive'
  'resume_watchdog=on'
  'resume_watchdog_cooldown_secs=5'
  'resume_session_ttl_secs=9'
  'resume_request_ttl_days=1'
  'resume_scan_max_sessions=1'
  'claude_bin=/bin/sh'
  'state_ttl_days=1'
  'time_tracking_xs_retain_days=1'
  'custom_verify_mcp_tools=*'
  'custom_verify_patterns=.*'
)
for denied_pair in "${denied_pairs[@]}"; do
  denied_key="${denied_pair%%=*}"
  set +e
  denied_out="$(cd "${project_dir}" && bash "${HELPER}" set project "${denied_pair}" 2>&1)"
  denied_rc=$?
  set -e
  assert_eq "Test 59: project ${denied_key} is rejected" "2" "${denied_rc}"
  assert_contains "Test 59: ${denied_key} rejection explains authority" \
    "user-only" "${denied_out}"
  assert_file_lacks_line "Test 59: ${denied_key} is never written" \
    "${project_dir}/.claude/oh-my-claude.conf" "^${denied_key}="
done
assert_eq "Test 59: rejected project output_style leaves global settings unchanged" \
  "oh-my-claude" \
  "$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json")"
teardown

printf 'Test 60: project presets omit model keys and never invoke switch-tier\n'
setup
{
  printf 'installed_version=1.22.0\n'
  printf 'model_tier=quality\n'
  printf 'model_overrides=quality-reviewer:opus\n'
} > "${USER_CONF_PATH}"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'INVOKED: %s\n' "$*" >> "${HOME}/.claude/.project-preset-switch.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
project_dir="${TEST_HOME}/preset-project"
mkdir -p "${project_dir}"
out="$(cd "${project_dir}" && bash "${HELPER}" apply-preset project minimal 2>&1)"
project_conf="${project_dir}/.claude/oh-my-claude.conf"
assert_contains "Test 60: preset reports preserved user-wide settings" \
  "omitted user-only preset key(s):" "${out}"
assert_contains "Test 60: preset reports omitted quality policy" \
  "quality_policy" "${out}"
assert_contains "Test 60: preset reports omitted Definition authority" \
  "definition_of_excellent" "${out}"
assert_contains "Test 60: preset reports omitted no-defer authority" \
  "no_defer_mode" "${out}"
assert_contains "Test 60: preset reports omitted model tier" \
  "model_tier" "${out}"
assert_file_has_line "Test 60: project-safe preset key is written" \
  "${project_conf}" '^gate_level=basic$'
assert_file_lacks_line "Test 60: project preset omits model_tier" \
  "${project_conf}" '^model_tier='
assert_file_lacks_line "Test 60: project preset omits model_overrides" \
  "${project_conf}" '^model_overrides='
assert_file_lacks_line "Test 60: project preset omits quality_policy" \
  "${project_conf}" '^quality_policy='
assert_file_lacks_line "Test 60: project preset omits definition_of_excellent" \
  "${project_conf}" '^definition_of_excellent='
assert_file_lacks_line "Test 60: project preset omits quality_constitution" \
  "${project_conf}" '^quality_constitution='
assert_file_lacks_line "Test 60: project preset omits taste_learning" \
  "${project_conf}" '^taste_learning='
assert_file_lacks_line "Test 60: project preset omits Constitution context cap" \
  "${project_conf}" '^quality_constitution_max_context_chars='
assert_file_lacks_line "Test 60: project preset omits no_defer_mode" \
  "${project_conf}" '^no_defer_mode='
assert_file_lacks_line "Test 60: project preset omits machine-wide watchdog switch" \
  "${project_conf}" '^resume_watchdog='
assert_file_has_line "Test 60: user tier remains unchanged" \
  "${USER_CONF_PATH}" '^model_tier=quality$'
assert_file_has_line "Test 60: user override remains unchanged" \
  "${USER_CONF_PATH}" '^model_overrides=quality-reviewer:opus$'
if [[ ! -f "${TEST_HOME}/.claude/.project-preset-switch.invocations" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: Test 60: project preset invoked switch-tier.sh\n' >&2
  fail=$((fail + 1))
fi
teardown

printf 'Test 61: model flag metadata describes user-only adaptive economy\n'
setup
flags_json="$(bash "${HELPER}" list-flags)"
tier_desc="$(jq -r '.[] | select(.name == "model_tier") | .description' <<<"${flags_json}")"
override_desc="$(jq -r '.[] | select(.name == "model_overrides") | .description' <<<"${flags_json}")"
token_desc="$(jq -r '.[] | select(.name == "token_tracking") | .description' <<<"${flags_json}")"
assert_contains "Test 61: economy wording is adaptive" "adaptive reasoning-risk escalation" "${tier_desc}"
assert_contains "Test 61: tier metadata names project restriction" \
  "Project conf cannot set" "${tier_desc}"
assert_contains "Test 61: override metadata names project restriction" \
  "project conf cannot set" "${override_desc}"
assert_contains "Test 61: token metadata names parent and nested sidechains" \
  "parent + nested sidechain transcripts" "${token_desc}"
assert_contains "Test 61: token metadata names dispatch attribution" \
  "role/model/native-dispatch attribution" "${token_desc}"
json_document_count="$(jq -s 'length' <<<"${flags_json}")"
assert_eq "Test 61: list-flags emits exactly one JSON document" "1" "${json_document_count}"
teardown

printf 'Test 62: environment model display is sanitized and marked [E]\n'
setup
install_real_model_switch_fixture
{
  printf 'installed_version=1.22.0\n'
  printf 'model_tier=quality\n'
  printf 'model_overrides=quality-reviewer:opus\n'
} > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && OMC_MODEL_TIER=economy \
  OMC_MODEL_OVERRIDES=' oracle:inherit,broken,plugin-x:reviewer:opus,librarian:not-a-model ' \
  bash "${HELPER}" show 2>&1)"
tier_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+model_tier[[:space:]]' || true)"
override_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+model_overrides[[:space:]]' || true)"
assert_eq "Test 62: env tier is effective" "economy" "$(awk '{print $3}' <<<"${tier_row}")"
assert_contains "Test 62: env tier carries [E]" "[E]" "${tier_row}"
assert_eq "Test 62: only resolver-valid env pins are displayed" \
  "oracle:inherit,plugin-x:reviewer:opus" "$(awk '{print $3}' <<<"${override_row}")"
assert_contains "Test 62: env pins carry [E]" "[E]" "${override_row}"
assert_not_contains "Test 62: invalid pin is not overclaimed" "librarian:not-a-model" "${override_row}"
assert_contains "Test 62: invalid entries are explained" \
  "rejected pairs are ignored and only the accepted environment pins govern" "${out}"
assert_contains "Test 62: no-project footer defines [E]" \
  "[E]=environment override, [U]=user setting" "${out}"
teardown

printf 'Test 62b: wholly invalid environment overrides fall back to saved pins\n'
setup
{
  printf 'installed_version=1.22.0\n'
  printf 'model_overrides=quality-reviewer:opus\n'
} > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && \
  OMC_MODEL_OVERRIDES='broken,quality-reviewer:not-a-model,../victim:opus' \
  bash "${HELPER}" show 2>&1)"
override_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+model_overrides[[:space:]]' || true)"
assert_eq "Test 62b: saved pins remain effective" \
  "quality-reviewer:opus" "$(awk '{print $3}' <<<"${override_row}")"
assert_contains "Test 62b: saved pins retain [U] provenance" "[U]" \
  "${override_row}"
assert_not_contains "Test 62b: invalid env is not claimed as [E]" "[E]" \
  "${override_row}"
assert_contains "Test 62b: invalid-all fallback warning is explicit" \
  "contains no valid pins and is ignored; saved user pins remain effective" \
  "${out}"
teardown

printf 'Test 63: invalid environment tier preserves valid saved quality\n'
setup
printf 'model_tier=quality\n' > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && OMC_MODEL_TIER=not-a-model bash "${HELPER}" show 2>&1)"
tier_row="$(printf '%s\n' "${out}" | grep -E '^[[:space:]*]+model_tier[[:space:]]' || true)"
assert_eq "Test 63: invalid env tier leaves saved quality effective" "quality" "$(awk '{print $3}' <<<"${tier_row}")"
assert_contains "Test 63: saved tier retains user provenance" "[U]" "${tier_row}"
assert_not_contains "Test 63: invalid env is not claimed as provenance" "[E]" "${tier_row}"
assert_contains "Test 63: ignored invalid override warning is explicit" \
  "is ignored; saved user tier or the balanced default remains effective" "${out}"
teardown

printf 'Test 63b: mixed saved overrides show only the resolver-valid subset\n'
setup
printf 'installed_version=1.22.0\nmodel_overrides=oracle:oppus,librarian:haiku\n' \
  > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && bash "${HELPER}" show 2>&1)"
override_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+model_overrides[[:space:]]' || true)"
assert_eq "Test 63b: valid saved subset is displayed" "librarian:haiku" \
  "$(awk '{print $3}' <<<"${override_row}")"
assert_contains "Test 63b: valid saved subset retains [U]" "[U]" \
  "${override_row}"
assert_not_contains "Test 63b: invalid saved pin is not overclaimed" \
  "oracle:oppus" "${override_row}"
assert_contains "Test 63b: rejected saved pair warning is explicit" \
  "saved model_overrides contains invalid entries; rejected pairs are ignored" \
  "${out}"
teardown

printf 'Test 63c: invalid-all saved overrides show no effective user pins\n'
setup
printf 'installed_version=1.22.0\nmodel_overrides=oracle:oppus,broken\n' \
  > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && bash "${HELPER}" show 2>&1)"
override_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+model_overrides[[:space:]]' || true)"
assert_contains "Test 63c: invalid-all saved pins render unset" "(unset)" \
  "${override_row}"
assert_not_contains "Test 63c: invalid-all saved pins have no [U]" "[U]" \
  "${override_row}"
assert_contains "Test 63c: invalid-all saved warning is explicit" \
  "saved model_overrides contains no valid pins and is ignored" "${out}"
flags_json="$(bash "${HELPER}" list-flags)"
assert_eq "Test 63c: list-flags also sanitizes invalid-all saved pins" "" \
  "$(jq -r '.[] | select(.name == "model_overrides") | .current' \
    <<<"${flags_json}")"
teardown

printf 'Test 63d: invalid saved tier displays balanced runtime fallback\n'
setup
printf 'installed_version=1.22.0\nmodel_tier=not-a-model\n' \
  > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" && bash "${HELPER}" show 2>&1)"
tier_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+model_tier[[:space:]]' || true)"
tier_value="$(awk '{for (i=1; i<=NF; i++) if ($i == "model_tier") {print $(i+1); exit}}' \
  <<<"${tier_row}")"
assert_eq "Test 63d: invalid saved tier displays balanced" "balanced" \
  "${tier_value}"
assert_not_contains "Test 63d: invalid saved tier has no [U]" "[U]" \
  "${tier_row}"
assert_contains "Test 63d: invalid saved tier warning is explicit" \
  "saved model_tier=not-a-model is invalid and ignored" "${out}"
flags_json="$(bash "${HELPER}" list-flags)"
assert_eq "Test 63d: list-flags also normalizes invalid saved tier" \
  "balanced" \
  "$(jq -r '.[] | select(.name == "model_tier") | .current' \
    <<<"${flags_json}")"
teardown

printf 'Test 63e: set rejects malformed model overrides atomically\n'
setup
mkdir -p "${TEST_HOME}/.claude/agents"
printf -- '---\nname: custom-fixed\nmodel: sonnet\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/custom-fixed.md"
printf 'gate_level=full\nmodel_overrides=librarian:haiku\n' \
  > "${USER_CONF_PATH}"
invalid_override_values=(
  'oracle:oppus'
  'broken'
  '../victim:opus'
  'too:many:colons:opus'
  'oracle:opus,'
  'ghost:inherit'
  'custom-fixed:inherit'
  'plugin-x:reviewer:inherit'
)
for invalid_override in "${invalid_override_values[@]}"; do
  set +e
  out="$(bash "${HELPER}" set user gate_level=basic \
    "model_overrides=${invalid_override}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 63e: invalid override rejected (${invalid_override})" \
    "2" "${rc}"
  assert_contains "Test 63e: rejection explains grammar (${invalid_override})" \
    "model_overrides must be empty or comma-separated agent:model pins" \
    "${out}"
done
assert_file_has_line "Test 63e: failed batch preserves prior override" \
  "${USER_CONF_PATH}" '^model_overrides=librarian:haiku$'
assert_file_has_line "Test 63e: failed batch preserves sibling flag" \
  "${USER_CONF_PATH}" '^gate_level=full$'
teardown

printf 'Test 63f: set accepts valid namespaced and bare pins\n'
setup
install_real_model_switch_fixture
printf -- '---\nname: custom-inherited\nmodel: inherit\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/custom-inherited.md"
out="$(bash "${HELPER}" set user \
  model_overrides=plugin-x:reviewer:opus,librarian:inherit,custom-inherited:inherit 2>&1)"
rc=$?
assert_eq "Test 63f: valid namespaced override set exits 0" "0" "${rc}"
assert_file_has_line "Test 63f: valid namespaced and bare pins persist" \
  "${USER_CONF_PATH}" \
  '^model_overrides=plugin-x:reviewer:opus,librarian:inherit,custom-inherited:inherit$'
assert_eq "Test 63f: bare inherit pin is materialized before live omission" \
  "inherit" "$(installed_agent_model librarian)"
assert_eq "Test 63f: already-inherited custom definition remains untouched" \
  "inherit" "$(installed_agent_model custom-inherited)"
teardown

printf 'Test 64: changed quality override forces one canonical reconstruction\n'
setup
install_minimal_parent_model_fixture
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/.claude/.override-switch.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=quality\nmodel_overrides=oracle:opus\n' > "${USER_CONF_PATH}"
bash "${HELPER}" set user model_overrides=librarian:haiku >/dev/null 2>&1
invocations="$(cat "${TEST_HOME}/.claude/.override-switch.invocations")"
assert_eq "Test 64: quality override change passes force flag" \
  "quality --force-reconstruct" "${invocations}"
assert_eq "Test 64: switcher called exactly once" "1" \
  "$(wc -l < "${TEST_HOME}/.claude/.override-switch.invocations" | tr -d ' ')"
teardown

printf 'Test 65: clearing a quality override also forces reconstruction\n'
setup
install_minimal_parent_model_fixture
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/.claude/.override-clear.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=quality\nmodel_overrides=oracle:opus\n' > "${USER_CONF_PATH}"
bash "${HELPER}" set user model_overrides= >/dev/null 2>&1
assert_eq "Test 65: empty replacement still passes force flag" \
  "quality --force-reconstruct" \
  "$(cat "${TEST_HOME}/.claude/.override-clear.invocations")"
teardown

printf 'Test 66: economy override refresh stays source-independent\n'
setup
install_minimal_parent_model_fixture
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/.claude/.override-economy.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=economy\nmodel_overrides=oracle:opus\n' > "${USER_CONF_PATH}"
bash "${HELPER}" set user model_overrides=librarian:haiku >/dev/null 2>&1
assert_eq "Test 66: economy reapply does not force source reconstruction" \
  "economy" "$(cat "${TEST_HOME}/.claude/.override-economy.invocations")"
teardown

printf 'Test 67: tier plus override batch invokes quality reconstruction once\n'
setup
install_minimal_parent_model_fixture
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/.claude/.override-batch.invocations"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=balanced\nmodel_overrides=oracle:inherit\n' > "${USER_CONF_PATH}"
bash "${HELPER}" set user model_tier=quality model_overrides=librarian:haiku >/dev/null 2>&1
assert_eq "Test 67: target quality receives force flag" \
  "quality --force-reconstruct" \
  "$(cat "${TEST_HOME}/.claude/.override-batch.invocations")"
assert_eq "Test 67: combined batch calls switcher once" "1" \
  "$(wc -l < "${TEST_HOME}/.claude/.override-batch.invocations" | tr -d ' ')"
teardown

printf 'Test 68: set economy to quality reconstructs despite an inherit override\n'
setup
install_real_model_switch_fixture
printf 'repo_path=%s\nmodel_tier=balanced\nmodel_overrides=oracle:inherit\n' \
  "${REPO_ROOT}" > "${USER_CONF_PATH}"
bash "${TEST_HOME}/.claude/switch-tier.sh" economy >/dev/null 2>&1
assert_eq "Test 68: economy fixture retains every shipped inherit deliberator" \
  "14" "$(count_installed_model inherit)"
bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1
assert_eq "Test 68: quality restores all shipped inherit deliberators" \
  "14" "$(count_installed_model inherit)"
assert_eq "Test 68: quality lifts only shipped fixed specialists" \
  "23" "$(count_installed_model opus)"
assert_eq "Test 68: representative reviewer rides the session model" \
  "inherit" "$(installed_agent_model quality-reviewer)"
assert_eq "Test 68: representative planner rides the session model" \
  "inherit" "$(installed_agent_model quality-planner)"
teardown

printf 'Test 69: quality preset reconstructs economy despite an inherit override\n'
setup
install_real_model_switch_fixture
printf 'repo_path=%s\nmodel_tier=balanced\nmodel_overrides=oracle:inherit\n' \
  "${REPO_ROOT}" > "${USER_CONF_PATH}"
bash "${TEST_HOME}/.claude/switch-tier.sh" economy >/dev/null 2>&1
assert_eq "Test 69: economy fixture retains every shipped inherit deliberator" \
  "14" "$(count_installed_model inherit)"
bash "${HELPER}" apply-preset user maximum >/dev/null 2>&1
assert_eq "Test 69: maximum preset restores all shipped inherit deliberators" \
  "14" "$(count_installed_model inherit)"
assert_eq "Test 69: maximum preset lifts only shipped fixed specialists" \
  "23" "$(count_installed_model opus)"
assert_eq "Test 69: representative critic rides the session model" \
  "inherit" "$(installed_agent_model metis)"
assert_eq "Test 69: representative executor uses Opus" \
  "opus" "$(installed_agent_model frontend-developer)"
teardown

printf 'Test 70: persistent model writes materialize saved values despite environment shadows\n'
setup
install_minimal_parent_model_fixture
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'args=%s|tier=%s|overrides=%s\n' "$*" \
  "${OMC_MODEL_TIER:-}" "${OMC_MODEL_OVERRIDES:-}" \
  > "${HOME}/.claude/.saved-model-materialization"
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=balanced\nmodel_overrides=\n' > "${USER_CONF_PATH}"
out="$(OMC_MODEL_TIER=economy OMC_MODEL_OVERRIDES=oracle:haiku \
  bash "${HELPER}" set user model_tier=quality model_overrides=oracle:opus 2>&1)"
assert_eq "Test 70: switcher sees saved target without environment tier or overrides" \
  "args=quality --force-reconstruct|tier=|overrides=" \
  "$(cat "${TEST_HOME}/.claude/.saved-model-materialization")"
assert_eq "Test 70: saved tier is quality" \
  "quality" "$(awk -F= '$1 == "model_tier" { print $2 }' "${USER_CONF_PATH}")"
assert_eq "Test 70: saved override is Opus" \
  "oracle:opus" "$(awk -F= '$1 == "model_overrides" { print $2 }' "${USER_CONF_PATH}")"
assert_contains "Test 70: live environment precedence is explained" \
  "remove the environment override and start a new session" "${out}"
out="$(OMC_MODEL_TIER=economy OMC_MODEL_OVERRIDES=oracle:haiku \
  bash "${HELPER}" set user model_tier=quality model_overrides=oracle:opus 2>&1)"
assert_contains "Test 70: unchanged explicit model write still explains env shadow" \
  "remove the environment override and start a new session" "${out}"
assert_contains "Test 70: unchanged explicit model write repairs materialization" \
  "model_tier unchanged at quality; re-materializing" "${out}"
teardown

printf 'Test 71: failed inherit materialization never claims live activation\n'
setup
mkdir -p "${TEST_HOME}/.claude/agents"
printf -- '---\nname: librarian\nmodel: sonnet\n---\nbody\n' \
  > "${TEST_HOME}/.claude/agents/librarian.md"
cat > "${TEST_HOME}/.claude/switch-tier.sh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "${TEST_HOME}/.claude/switch-tier.sh"
printf 'model_tier=balanced\nmodel_overrides=\n' > "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user model_overrides=librarian:inherit 2>&1)"
rc=$?
set -e
assert_eq "Test 71: failed materialization rejects the batch" "1" "${rc}"
assert_file_has_line "Test 71: prior empty override is restored" \
  "${USER_CONF_PATH}" '^model_overrides=$'
assert_file_lacks_line "Test 71: failed pin is never saved" \
  "${USER_CONF_PATH}" '^model_overrides=librarian:inherit$'
assert_contains "Test 71: failure reports whole-batch rollback" \
  "rolling back the whole config/materialization batch" "${out}"
assert_eq "Test 71: failed switch leaves fixed definition unchanged" \
  "sonnet" "$(installed_agent_model librarian)"
teardown

printf 'Test 72: omc-config shipped materialization rosters match the bundle\n'
bundle_inherit_roster="$({
  for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
    if [[ "$(sed -n 's/^model: //p' "${agent_file}" | head -1)" == "inherit" ]]; then
      basename "${agent_file}" .md
    fi
  done
} | sort | tr '\n' ' ' | sed 's/ $//')"
bundle_fixed_roster="$({
  for agent_file in "${REPO_ROOT}"/bundle/dot-claude/agents/*.md; do
    if [[ "$(sed -n 's/^model: //p' "${agent_file}" | head -1)" == "sonnet" ]]; then
      basename "${agent_file}" .md
    fi
  done
} | sort | tr '\n' ' ' | sed 's/ $//')"
config_inherit_roster="$(sed -n \
  "s/^OMC_CONFIG_SHIPPED_INHERIT_AGENTS='\\(.*\\)'$/\\1/p" "${HELPER}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
config_fixed_roster="$(sed -n \
  "s/^OMC_CONFIG_SHIPPED_FIXED_AGENTS='\\(.*\\)'$/\\1/p" "${HELPER}" \
  | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "Test 72: omc-config inherit roster matches bundle" \
  "${bundle_inherit_roster}" "${config_inherit_roster}"
assert_eq "Test 72: omc-config fixed roster matches bundle" \
  "${bundle_fixed_roster}" "${config_fixed_roster}"
config_roster_count="$(printf '%s\n%s\n' \
  "${config_inherit_roster}" "${config_fixed_roster}" \
  | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d '[:space:]')"
assert_eq "Test 72: omc-config materialization authority covers 37 agents" \
  "37" "${config_roster_count}"

printf 'Test 73: Definition and Constitution environment shadows are effective and visible\n'
setup
{
  printf 'installed_version=1.50.0\n'
  printf 'definition_of_excellent=always\n'
  printf 'quality_constitution=on\n'
  printf 'taste_learning=off\n'
  printf 'quality_constitution_max_context_chars=2400\n'
} > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" \
  && OMC_DEFINITION_OF_EXCELLENT=off \
  OMC_QUALITY_CONSTITUTION=off \
  OMC_TASTE_LEARNING=adaptive \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=7777 \
  bash "${HELPER}" show 2>&1)"
for expected in \
  'definition_of_excellent off' \
  'quality_constitution off' \
  'taste_learning adaptive' \
  'quality_constitution_max_context_chars 7777'; do
  key="${expected%% *}"
  value="${expected#* }"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 73: ${key} environment value is effective" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 73: ${key} carries environment provenance" "[E]" "${row}"
done
assert_contains "Test 73: footer explains new runtime environment authority" \
  "[E]=environment override, [U]=user setting" "${out}"
teardown

printf 'Test 74: Constitution context cap rejects impossible saved and environment values\n'
setup
printf 'quality_constitution_max_context_chars=2400\n' > "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user quality_constitution_max_context_chars=12001 2>&1)"
rc=$?
set -e
assert_eq "Test 74: >12000 set exits 2" "2" "${rc}"
assert_contains "Test 74: >12000 error names hard cap" "must be at most 12000" "${out}"
assert_file_has_line "Test 74: rejected write preserves saved value" \
  "${USER_CONF_PATH}" '^quality_constitution_max_context_chars=2400$'
out="$(cd "${TEST_HOME}" \
  && OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=12001 \
  bash "${HELPER}" show 2>&1)"
row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+quality_constitution_max_context_chars[[:space:]]' || true)"
assert_eq "Test 74: invalid env cap falls back to saved value" \
  "2400" "$(awk '{print $3}' <<<"${row}")"
assert_contains "Test 74: saved fallback retains user provenance" "[U]" "${row}"
assert_not_contains "Test 74: invalid env cap is not claimed as effective" "[E]" "${row}"
teardown

printf 'Test 75: fine-tune skill exposes every user-owned Definition control\n'
config_skill="${REPO_ROOT}/bundle/dot-claude/skills/omc-config/SKILL.md"
assert_contains "Test 75: fine-tune documents six user and three project clusters" \
  "six at user scope, three at project scope" "$(cat "${config_skill}")"
for definition_flag in \
  definition_of_excellent \
  quality_constitution \
  taste_learning \
  quality_constitution_max_context_chars; do
  definition_cluster="$(sed -n \
    '/Cluster 2 — Definition of Excellent & Taste/,/Cluster 3 — Advisory routing/p' \
    "${config_skill}")"
  assert_contains "Test 75: interactive Definition cluster exposes ${definition_flag}" \
    "${definition_flag}=" "${definition_cluster}"
  assert_contains "Test 75: project deny-list documents ${definition_flag}" \
    "\`${definition_flag}\`" \
    "$(sed -n '/User-only flags at project scope/,$p' "${config_skill}")"
done

printf 'Test 76: Constitution context cap uses canonical bounded decimals\n'
setup
printf 'quality_constitution_max_context_chars=2400\n' > "${USER_CONF_PATH}"
for rejected_cap in 511 12001 18446744073709551616 0512 08; do
  set +e
  out="$(bash "${HELPER}" set user \
    "quality_constitution_max_context_chars=${rejected_cap}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 76: rejected cap ${rejected_cap} exits 2" "2" "${rc}"
  assert_file_has_line "Test 76: rejected cap ${rejected_cap} preserves saved value" \
    "${USER_CONF_PATH}" '^quality_constitution_max_context_chars=2400$'
done
for accepted_cap in 512 12000; do
  out="$(bash "${HELPER}" set user \
    "quality_constitution_max_context_chars=${accepted_cap}" 2>&1)"
  assert_file_has_line "Test 76: boundary cap ${accepted_cap} is saved" \
    "${USER_CONF_PATH}" "^quality_constitution_max_context_chars=${accepted_cap}$"
done
printf 'quality_constitution_max_context_chars=2400\n' > "${USER_CONF_PATH}"
for rejected_env_cap in 511 12001 18446744073709551616 0512 08; do
  out="$(cd "${TEST_HOME}" \
    && OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS="${rejected_env_cap}" \
    bash "${HELPER}" show 2>&1)"
  row="$(printf '%s\n' "${out}" \
    | grep -E '^[[:space:]*]+quality_constitution_max_context_chars[[:space:]]' || true)"
  assert_eq "Test 76: invalid env cap ${rejected_env_cap} falls back" \
    "2400" "$(awk '{print $3}' <<<"${row}")"
  assert_not_contains "Test 76: invalid env cap ${rejected_env_cap} has no env provenance" \
    "[E]" "${row}"
done
teardown

printf 'Test 77: user quality writes warn precisely when environment wins\n'
setup
install_real_model_switch_fixture
out="$(OMC_DEFINITION_OF_EXCELLENT=off \
  OMC_QUALITY_CONSTITUTION=off \
  OMC_TASTE_LEARNING=adaptive \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=7777 \
  bash "${HELPER}" set user \
    definition_of_excellent=always \
    quality_constitution=on \
    taste_learning=review \
    quality_constitution_max_context_chars=2400 2>&1)"
for env_name in \
  OMC_DEFINITION_OF_EXCELLENT \
  OMC_QUALITY_CONSTITUTION \
  OMC_TASTE_LEARNING \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS; do
  assert_contains "Test 77: set warns for ${env_name}" \
    "active ${env_name}=" "${out}"
done
out="$(OMC_DEFINITION_OF_EXCELLENT=off \
  OMC_QUALITY_CONSTITUTION=off \
  OMC_TASTE_LEARNING=adaptive \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=7777 \
  bash "${HELPER}" apply-preset user balanced 2>&1)"
for env_name in \
  OMC_DEFINITION_OF_EXCELLENT \
  OMC_QUALITY_CONSTITUTION \
  OMC_TASTE_LEARNING \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS; do
  assert_contains "Test 77: preset warns for ${env_name}" \
    "active ${env_name}=" "${out}"
done
out="$(OMC_DEFINITION_OF_EXCELLENT=adaptive \
  OMC_QUALITY_CONSTITUTION=on \
  OMC_TASTE_LEARNING=review \
  OMC_QUALITY_CONSTITUTION_MAX_CONTEXT_CHARS=2400 \
  bash "${HELPER}" set user \
    definition_of_excellent=adaptive \
    quality_constitution=on \
    taste_learning=review \
    quality_constitution_max_context_chars=2400 2>&1)"
assert_not_contains "Test 77: matching env values do not warn" \
  "overrides saved" "${out}"
teardown

printf 'Test 78: malformed saved quality controls are diagnosed and ignored\n'
setup
{
  printf 'definition_of_excellent=bogus\n'
  printf 'quality_constitution=wat\n'
  printf 'taste_learning=x\n'
  printf 'quality_constitution_max_context_chars=99999\n'
} > "${USER_CONF_PATH}"
out="$(bash "${HELPER}" show 2>&1)"
for invalid_saved in \
  'definition_of_excellent=bogus' \
  'quality_constitution=wat' \
  'taste_learning=x' \
  'quality_constitution_max_context_chars=99999'; do
  assert_contains "Test 78: show diagnoses ${invalid_saved}" \
    "saved ${invalid_saved} is invalid and ignored" "${out}"
done
for expected in \
  'definition_of_excellent adaptive' \
  'quality_constitution on' \
  'taste_learning review' \
  'quality_constitution_max_context_chars 2400'; do
  key="${expected%% *}"
  value="${expected#* }"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 78: ${key} falls back to default" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_not_contains "Test 78: ${key} does not claim user provenance" \
    "[U]" "${row}"
done
flags_json="$(bash "${HELPER}" list-flags --json)"
for expected in \
  'definition_of_excellent=adaptive' \
  'quality_constitution=on' \
  'taste_learning=review' \
  'quality_constitution_max_context_chars=2400'; do
  key="${expected%%=*}"
  value="${expected#*=}"
  assert_eq "Test 78: list-flags defaults invalid ${key}" \
    "${value}" "$(jq -r --arg key "${key}" '.[] | select(.name == $key) | .current' \
      <<<"${flags_json}")"
done
teardown

printf 'Test 79: unrelated or invalid project rows preserve user provenance\n'
setup
project_dir="${TEST_HOME}/project"
mkdir -p "${project_dir}/.claude"
printf 'gate_level=basic\n' > "${USER_CONF_PATH}"
printf 'stall_threshold=invalid\n' \
  > "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+gate_level[[:space:]]' || true)"
assert_eq "Test 79: unrelated project conf preserves user value" \
  "basic" "$(awk '{print $3}' <<<"${row}")"
assert_contains "Test 79: unrelated project conf preserves user provenance" \
  "[U]" "${row}"
row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+stall_threshold[[:space:]]' || true)"
assert_eq "Test 79: invalid project row falls back to default" \
  "12" "$(awk '{print $3}' <<<"${row}")"
assert_not_contains "Test 79: invalid project row does not claim project provenance" \
  "[P]" "${row}"
teardown

printf 'Test 80: show resolves every valid documented environment authority\n'
setup
{
  printf 'gate_level=full\n'
  printf 'transcript_archive=off\n'
  printf 'time_card_min_seconds=5\n'
  printf 'agent_first_gate=off\n'
  printf 'guard_exhaustion_mode=block\n'
} > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" \
  && OMC_GATE_LEVEL=basic \
  OMC_TRANSCRIPT_ARCHIVE=on \
  OMC_TIME_CARD_MIN_SECONDS=17 \
  OMC_AGENT_FIRST_GATE=ON \
  OMC_GUARD_EXHAUSTION_MODE=warn \
  bash "${HELPER}" show 2>&1)"
for expected in \
  'gate_level=basic' \
  'transcript_archive=on' \
  'time_card_min_seconds=17' \
  'agent_first_gate=on' \
  'guard_exhaustion_mode=scorecard'; do
  key="${expected%%=*}"
  value="${expected#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 80: ${key} environment value is effective" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 80: ${key} carries environment provenance" \
    "[E]" "${row}"
done
assert_contains "Test 80: generic environment legend is rendered" \
  "[E]=environment override" "${out}"

out="$(cd "${TEST_HOME}" \
  && OMC_GATE_LEVEL=bogus \
  OMC_TRANSCRIPT_ARCHIVE=maybe \
  OMC_TIME_CARD_MIN_SECONDS=-1 \
  bash "${HELPER}" show 2>&1)"
for expected in \
  'gate_level=full' \
  'transcript_archive=off' \
  'time_card_min_seconds=5'; do
  key="${expected%%=*}"
  value="${expected#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 80: invalid ${key} environment value is ignored" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_not_contains "Test 80: invalid ${key} has no environment provenance" \
    "[E]" "${row}"
done

out="$(OMC_GATE_LEVEL=basic bash "${HELPER}" set user \
  gate_level=standard 2>&1)"
assert_contains "Test 80: generic write warns about environment shadow" \
  "active OMC_GATE_LEVEL=basic overrides saved user gate_level=standard" \
  "${out}"
teardown

printf 'Test 81: public numeric domains reject zero, leading zero, overflow, and out-of-range values\n'
setup
printf 'gate_level=basic\n' > "${USER_CONF_PATH}"
for rejected_numeric in \
  'verify_confidence_threshold=101' \
  'stall_threshold=0' \
  'excellence_file_count=08' \
  'dimension_gate_file_count=12abc' \
  'state_ttl_days=18446744073709551616' \
  'advisory_no_findings_threshold=0' \
  'resume_request_ttl_days=0' \
  'resume_watchdog_cooldown_secs=0' \
  'resume_session_ttl_secs=0'; do
  set +e
  out="$(bash "${HELPER}" set user "${rejected_numeric}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 81: ${rejected_numeric} exits 2" "2" "${rc}"
  assert_file_has_line "Test 81: ${rejected_numeric} preserves conf" \
    "${USER_CONF_PATH}" '^gate_level=basic$'
  assert_file_lacks_line "Test 81: ${rejected_numeric} is not written" \
    "${USER_CONF_PATH}" "^${rejected_numeric%%=*}="
done
for accepted_numeric in \
  'stall_threshold=1' \
  'excellence_file_count=5' \
  'state_ttl_days=9'; do
  out="$(bash "${HELPER}" set user "${accepted_numeric}" 2>&1)"
  assert_file_has_line "Test 81: ${accepted_numeric} is accepted" \
    "${USER_CONF_PATH}" "^${accepted_numeric}$"
done
flags_json="$(bash "${HELPER}" list-flags --json)"
for positive_flag in \
  stall_threshold \
  excellence_file_count \
  dimension_gate_file_count \
  traceability_file_count \
  state_ttl_days \
  advisory_no_findings_threshold \
  resume_request_ttl_days \
  resume_watchdog_cooldown_secs \
  resume_session_ttl_secs; do
  assert_eq "Test 81: ${positive_flag} advertises positive integer domain" \
    "pint" "$(jq -r --arg key "${positive_flag}" \
      '.[] | select(.name == $key) | .type' <<<"${flags_json}")"
done
teardown

printf 'Test 82: readers trim values, canonicalize aliases, and retain the last valid duplicate\n'
setup
{
  printf 'gate_level=basic\n'
  printf 'agent_first_gate=ON \r\n'
  printf 'guard_exhaustion_mode=warn\n'
  printf 'stall_threshold=17\n'
  printf 'stall_threshold=08\n'
  printf 'claude_bin=/bin/sh\n'
  printf 'claude_bin=/definitely/missing/claude\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/duplicates-project"
mkdir -p "${project_dir}/.claude"
{
  printf 'gate_level=standard \r\n'
  printf 'gate_level=not-a-level\n'
  printf 'transcript_archive=on \r\n'
} > "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
for expected in \
  'gate_level=standard=[P]' \
  'agent_first_gate=on=[U]' \
  'guard_exhaustion_mode=scorecard=[U]' \
  'stall_threshold=17=[U]' \
  'claude_bin=/bin/sh=[U]'; do
  key="${expected%%=*}"
  remainder="${expected#*=}"
  value="${remainder%%=*}"
  provenance="${remainder#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 82: ${key} resolves canonical last-valid value" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 82: ${key} reports correct provenance" \
    "${provenance}" "${row}"
done
transcript_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+transcript_archive[[:space:]]' || true)"
assert_eq "Test 82: project cannot promote default-off transcript capture" \
  "off" "$(awk '{print $3}' <<<"${transcript_row}")"
assert_not_contains "Test 82: ignored transcript promotion has no project provenance" \
  "[P]" "${transcript_row}"
assert_contains "Test 82: ignored transcript promotion is diagnosed" \
  "project transcript_archive=on is a privacy/retention promotion and is ignored" \
  "${out}"
assert_contains "Test 82: malformed later project duplicate is diagnosed" \
  "project gate_level=not-a-level is invalid and ignored" "${out}"
assert_contains "Test 82: malformed later saved numeric is diagnosed" \
  "saved stall_threshold=08 is invalid and ignored" "${out}"
assert_contains "Test 82: missing saved claude executable is diagnosed" \
  "saved claude_bin=/definitely/missing/claude is invalid and ignored" "${out}"
teardown

printf 'Test 83: malformed generic environment values fall through in config UX and common runtime\n'
setup
{
  printf 'gate_level=full\n'
  printf 'transcript_archive=off\n'
  printf 'time_card_min_seconds=5\n'
  printf 'agent_first_gate=off\n'
  printf 'guard_exhaustion_mode=block\n'
  printf 'claude_bin=/bin/sh\n'
} > "${USER_CONF_PATH}"
out="$(cd "${TEST_HOME}" \
  && OMC_GATE_LEVEL=bogus \
  OMC_TRANSCRIPT_ARCHIVE=maybe \
  OMC_TIME_CARD_MIN_SECONDS=-1 \
  OMC_CLAUDE_BIN=/definitely/missing/claude \
  bash "${HELPER}" show 2>&1)"
for invalid_env_name in \
  OMC_GATE_LEVEL OMC_TRANSCRIPT_ARCHIVE OMC_TIME_CARD_MIN_SECONDS OMC_CLAUDE_BIN; do
  assert_contains "Test 83: ${invalid_env_name} is diagnosed" \
    "invalid ${invalid_env_name}=" "${out}"
done
runtime_values="$(
  cd "${TEST_HOME}"
  BASH_ENV=/dev/null \
    OMC_GATE_LEVEL=bogus \
    OMC_TRANSCRIPT_ARCHIVE=maybe \
    OMC_TIME_CARD_MIN_SECONDS=-1 \
    OMC_CLAUDE_BIN=/definitely/missing/claude \
    OMC_AGENT_FIRST_GATE=ON \
    OMC_GUARD_EXHAUSTION_MODE=warn \
    /bin/bash -c '. "$1" 2>/dev/null; printf "%s|%s|%s|%s|%s|%s" \
      "$OMC_GATE_LEVEL" "$OMC_TRANSCRIPT_ARCHIVE" \
      "$OMC_TIME_CARD_MIN_SECONDS" "$OMC_CLAUDE_BIN" \
      "$OMC_AGENT_FIRST_GATE" "$OMC_GUARD_EXHAUSTION_MODE"' \
      _ "${COMMON}"
)"
assert_eq "Test 83: common runtime uses valid lower sources and canonical aliases" \
  'full|off|5|/bin/sh|on|scorecard' "${runtime_values}"
teardown

printf 'Test 84: statusline controls are user-only and share compatibility grammar\n'
setup
{
  printf 'installation_drift_check=off\n'
  printf 'statusline_retention=NO\n'
  printf 'statusline_width=false\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/statusline-project"
mkdir -p "${project_dir}/.claude"
{
  printf 'installation_drift_check=true\n'
  printf 'statusline_retention=on\n'
  printf 'statusline_width=on\n'
} > "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
for expected in \
  'installation_drift_check=false' \
  'statusline_retention=off' \
  'statusline_width=off'; do
  key="${expected%%=*}"
  value="${expected#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 84: ${key} ignores project row" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 84: ${key} retains user provenance" "[U]" "${row}"
  project_value="on"
  [[ "${key}" == "installation_drift_check" ]] && project_value="true"
  set +e
  rejected="$(cd "${project_dir}" \
    && bash "${HELPER}" set project "${key}=${project_value}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 84: project write rejects ${key}" "2" "${rc}"
  assert_contains "Test 84: ${key} rejection names user-only authority" \
    "${key} is user-only" "${rejected}"
done
assert_contains "Test 84: show calls out ignored display rows" \
  "installation_drift_check,statusline_retention,statusline_width" "${out}"
assert_contains "Test 84: complete provenance legend includes user" \
  "[U]=user setting" "${out}"

out="$(cd "${project_dir}" \
  && OMC_INSTALLATION_DRIFT_CHECK=YES \
  OMC_STATUSLINE_RETENTION=1 \
  OMC_STATUSLINE_WIDTH=TRUE \
  bash "${HELPER}" show 2>&1)"
for expected in \
  'installation_drift_check=true' \
  'statusline_retention=on' \
  'statusline_width=on'; do
  key="${expected%%=*}"
  value="${expected#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 84: ${key} accepts compatibility env alias" \
    "${value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 84: ${key} env alias has environment provenance" \
    "[E]" "${row}"
done

out="$(cd "${project_dir}" \
  && OMC_INSTALLATION_DRIFT_CHECK=invalid \
  OMC_STATUSLINE_RETENTION=invalid \
  OMC_STATUSLINE_WIDTH=invalid \
  bash "${HELPER}" show 2>&1)"
for key in installation_drift_check statusline_retention statusline_width; do
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_contains "Test 84: invalid ${key} env falls through to user" "[U]" "${row}"
  assert_not_contains "Test 84: invalid ${key} env is not authoritative" "[E]" "${row}"
done
teardown

printf 'Test 85: list-flags current uses environment, project, user, default precedence\n'
setup
{
  printf 'gate_level=basic\n'
  printf 'output_style=executive\n'
} > "${USER_CONF_PATH}"
project_dir="${TEST_HOME}/list-flags-project"
mkdir -p "${project_dir}/.claude"
{
  printf 'gate_level=full\n'
  printf 'output_style=opencode\n'
} > "${project_dir}/.claude/oh-my-claude.conf"
flags_json="$(cd "${project_dir}" \
  && OMC_GATE_LEVEL=standard bash "${HELPER}" list-flags --json)"
assert_eq "Test 85: valid environment is current" "standard" \
  "$(jq -r '.[] | select(.name == "gate_level") | .current' \
    <<<"${flags_json}")"
flags_json="$(cd "${project_dir}" \
  && OMC_GATE_LEVEL=invalid bash "${HELPER}" list-flags --json)"
assert_eq "Test 85: invalid environment falls through to allowed project" "full" \
  "$(jq -r '.[] | select(.name == "gate_level") | .current' \
    <<<"${flags_json}")"
assert_eq "Test 85: denied project output style falls through to user" \
  "executive" \
  "$(jq -r '.[] | select(.name == "output_style") | .current' \
    <<<"${flags_json}")"
teardown

printf 'Test 86: saved output style materializes despite a conflicting environment\n'
setup
printf 'output_style=opencode\n' > "${USER_CONF_PATH}"
printf '{"outputStyle":"oh-my-claude"}\n' \
  > "${TEST_HOME}/.claude/settings.json"
out="$(OMC_OUTPUT_STYLE=opencode bash "${HELPER}" set user \
  output_style=executive 2>&1)"
assert_eq "Test 86: explicit saved choice is materialized immediately" \
  "executive-brief" \
  "$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json")"
assert_contains "Test 86: next-install environment conflict is explicit" \
  "active OMC_OUTPUT_STYLE=opencode will override it on the next install" \
  "${out}"
teardown

printf 'Test 87: project privacy overlays can reduce capture but cannot promote persistence or retention\n'
privacy_flags=(
  classifier_telemetry
  auto_memory
  prompt_persist
  stop_failure_capture
  transcript_archive
  time_tracking
  token_tracking
  model_drift_canary
  blindspot_inventory
)
setup
project_dir="${TEST_HOME}/privacy-project"
mkdir -p "${project_dir}/.claude"
for key in "${privacy_flags[@]}"; do
  printf '%s=off\n' "${key}" >> "${USER_CONF_PATH}"
  printf '%s=on\n' "${key}" >> "${project_dir}/.claude/oh-my-claude.conf"
done
printf 'resume_request_per_cwd_cap=3\n' >> "${USER_CONF_PATH}"
printf 'resume_request_ttl_days=7\nresume_scan_max_sessions=30\nwave_override_ttl_seconds=7200\n' \
  >> "${USER_CONF_PATH}"
printf 'self_audit_nudge=off\nwhats_new_session_hint=false\n' \
  >> "${USER_CONF_PATH}"
printf 'resume_request_per_cwd_cap=2\nresume_request_per_cwd_cap=4\nresume_request_ttl_days=1\nresume_scan_max_sessions=1\nwave_override_ttl_seconds=600\nwave_override_ttl_seconds=9000\n' \
  >> "${project_dir}/.claude/oh-my-claude.conf"
printf 'self_audit_nudge=on\nwhats_new_session_hint=true\n' \
  >> "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
for key in "${privacy_flags[@]}"; do
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 87: project cannot promote ${key}" \
    "off" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 87: ${key} retains user provenance" "[U]" "${row}"
  set +e
  rejected="$(cd "${project_dir}" \
    && bash "${HELPER}" set project "${key}=on" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 87: direct project ${key}=on is rejected" "2" "${rc}"
  assert_contains "Test 87: ${key} rejection explains sensitive persistence" \
    "cannot re-enable sensitive persistence" "${rejected}"
done
cap_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+resume_request_per_cwd_cap[[:space:]]' || true)"
assert_eq "Test 87: rejected later cap does not erase prior allowed reduction" \
  "2" "$(awk '{print $3}' <<<"${cap_row}")"
assert_contains "Test 87: allowed cap reduction has project provenance" \
  "[P]" "${cap_row}"
set +e
rejected="$(cd "${project_dir}" && bash "${HELPER}" set project \
  resume_request_per_cwd_cap=4 2>&1)"
rc=$?
set -e
assert_eq "Test 87: project cannot raise resume artifact cap" "2" "${rc}"
assert_contains "Test 87: cap rejection explains retention authority" \
  "cannot increase prompt-bearing resume artifact retention" "${rejected}"
for user_only_resume in resume_request_ttl_days resume_scan_max_sessions; do
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${user_only_resume}[[:space:]]" || true)"
  expected_resume_value=7
  [[ "${user_only_resume}" == "resume_scan_max_sessions" ]] \
    && expected_resume_value=30
  assert_eq "Test 87: project cannot split ${user_only_resume} authority" \
    "${expected_resume_value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 87: ${user_only_resume} retains user provenance" \
    "[U]" "${row}"
  set +e
  rejected="$(cd "${project_dir}" && bash "${HELPER}" set project \
    "${user_only_resume}=1" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 87: direct project ${user_only_resume} is rejected" \
    "2" "${rc}"
  assert_contains "Test 87: ${user_only_resume} names user-only authority" \
    "user-only" "${rejected}"
done
wave_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+wave_override_ttl_seconds[[:space:]]' || true)"
assert_eq "Test 87: rejected wave widening preserves allowed reduction" \
  "600" "$(awk '{print $3}' <<<"${wave_row}")"
assert_contains "Test 87: wave reduction has project provenance" \
  "[P]" "${wave_row}"
set +e
rejected="$(cd "${project_dir}" && bash "${HELPER}" set project \
  wave_override_ttl_seconds=9000 2>&1)"
rc=$?
set -e
assert_eq "Test 87: project cannot widen wave authorization" "2" "${rc}"
assert_contains "Test 87: wave rejection names authorization ceiling" \
  "cannot increase the user/default authorization ceiling" "${rejected}"
for notice_pair in self_audit_nudge=on whats_new_session_hint=true; do
  notice_key="${notice_pair%%=*}"
  expected_notice=off
  [[ "${notice_key}" == "whats_new_session_hint" ]] && expected_notice=false
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${notice_key}[[:space:]]" || true)"
  assert_eq "Test 87: project cannot re-enable ${notice_key}" \
    "${expected_notice}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 87: ${notice_key} retains user provenance" \
    "[U]" "${row}"
  set +e
  rejected="$(cd "${project_dir}" \
    && bash "${HELPER}" set project "${notice_pair}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 87: direct project ${notice_key} promotion is rejected" \
    "2" "${rc}"
  assert_contains "Test 87: ${notice_key} rejection names notice authority" \
    "cannot re-enable a user-disabled machine-wide session notice" \
    "${rejected}"
done

# Presets omit unsafe `on` promotions but retain privacy-reducing `off` rows.
rm -f "${project_dir}/.claude/oh-my-claude.conf"
preset_out="$(cd "${project_dir}" \
  && bash "${HELPER}" apply-preset project maximum 2>&1)"
assert_contains "Test 87: project preset reports omitted promotions" \
  "omitted capture/retention/authorization promotion(s):" "${preset_out}"
for key in classifier_telemetry auto_memory prompt_persist \
    stop_failure_capture time_tracking token_tracking model_drift_canary \
    blindspot_inventory; do
  assert_file_lacks_line "Test 87: preset omits unsafe ${key}=on" \
    "${project_dir}/.claude/oh-my-claude.conf" "^${key}=on$"
done
assert_file_has_line "Test 87: preset retains safe transcript_archive=off" \
  "${project_dir}/.claude/oh-my-claude.conf" '^transcript_archive=off$'
teardown

setup
project_dir="${TEST_HOME}/privacy-reduction-project"
mkdir -p "${project_dir}/.claude"
for key in "${privacy_flags[@]}"; do
  printf '%s=on\n' "${key}" >> "${USER_CONF_PATH}"
  printf '%s=off\n' "${key}" >> "${project_dir}/.claude/oh-my-claude.conf"
done
printf 'resume_request_per_cwd_cap=3\n' >> "${USER_CONF_PATH}"
printf 'wave_override_ttl_seconds=7200\n' >> "${USER_CONF_PATH}"
printf 'self_audit_nudge=on\nwhats_new_session_hint=true\n' \
  >> "${USER_CONF_PATH}"
printf 'resume_request_per_cwd_cap=2\nwave_override_ttl_seconds=600\nself_audit_nudge=off\nwhats_new_session_hint=false\n' \
  >> "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" && bash "${HELPER}" show 2>&1)"
for key in "${privacy_flags[@]}"; do
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${key}[[:space:]]" || true)"
  assert_eq "Test 87: project may reduce ${key}" \
    "off" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 87: ${key} reduction has project provenance" \
    "[P]" "${row}"
done
wave_row="$(printf '%s\n' "${out}" \
  | grep -E '^[[:space:]*]+wave_override_ttl_seconds[[:space:]]' || true)"
assert_eq "Test 87: project may shorten wave authorization" \
  "600" "$(awk '{print $3}' <<<"${wave_row}")"
assert_contains "Test 87: shortened wave has project provenance" \
  "[P]" "${wave_row}"
for notice_pair in self_audit_nudge=off whats_new_session_hint=false; do
  notice_key="${notice_pair%%=*}"
  notice_value="${notice_pair#*=}"
  row="$(printf '%s\n' "${out}" \
    | grep -E "^[[:space:]*]+${notice_key}[[:space:]]" || true)"
  assert_eq "Test 87: project may suppress ${notice_key}" \
    "${notice_value}" "$(awk '{print $3}' <<<"${row}")"
  assert_contains "Test 87: ${notice_key} suppression has project provenance" \
    "[P]" "${row}"
done
teardown

printf 'Test 88: custom verification matchers are validated user authority\n'
setup
bash "${HELPER}" set user \
  'custom_verify_mcp_tools=mcp__trusted__*' \
  'custom_verify_patterns=trusted-wrapper' >/dev/null
set +e
out="$(bash "${HELPER}" set user 'custom_verify_patterns=[' 2>&1)"
rc=$?
set -e
assert_eq "Test 88: invalid ERE write exits 2" "2" "${rc}"
assert_contains "Test 88: invalid ERE diagnostic is explicit" \
  "must be a valid extended regular expression" "${out}"
assert_file_has_line "Test 88: invalid ERE preserves prior matcher" \
  "${USER_CONF_PATH}" '^custom_verify_patterns=trusted-wrapper$'
for control_pair in \
    "custom_verify_patterns=trusted"$'\033'"wrapper" \
    "custom_verify_mcp_tools=mcp__trusted__*"$'\t'"mcp__other__*"; do
  set +e
  out="$(bash "${HELPER}" set user "${control_pair}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 88: control-character write exits 2" "2" "${rc}"
  assert_contains "Test 88: control-character diagnostic is explicit" \
    "cannot contain control characters" "${out}"
done
assert_file_has_line "Test 88: control rejection preserves MCP matcher" \
  "${USER_CONF_PATH}" '^custom_verify_mcp_tools=mcp__trusted__\*$'
assert_file_has_line "Test 88: control rejection preserves Bash matcher" \
  "${USER_CONF_PATH}" '^custom_verify_patterns=trusted-wrapper$'
project_dir="${TEST_HOME}/custom-verification-project"
mkdir -p "${project_dir}/.claude"
for denied_pair in 'custom_verify_mcp_tools=*' 'custom_verify_patterns=.*'; do
  set +e
  out="$(cd "${project_dir}" \
    && bash "${HELPER}" set project "${denied_pair}" 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 88: project ${denied_pair%%=*} is rejected" "2" "${rc}"
  assert_contains "Test 88: project matcher rejection names user authority" \
    "user-only" "${out}"
done
{
  printf 'custom_verify_patterns=trusted-wrapper\n'
  printf 'custom_verify_patterns=[\n'
} > "${USER_CONF_PATH}"
flags_json="$(OMC_CUSTOM_VERIFY_PATTERNS='[' \
  bash "${HELPER}" list-flags --json)"
assert_eq "Test 88: invalid env and later invalid row retain last valid ERE" \
  "trusted-wrapper" \
  "$(jq -r '.[] | select(.name == "custom_verify_patterns") | .current' \
    <<<"${flags_json}")"
flags_json="$(OMC_CUSTOM_VERIFY_PATTERNS='env-wrapper' \
  bash "${HELPER}" list-flags --json)"
assert_eq "Test 88: valid ERE environment has precedence" "env-wrapper" \
  "$(jq -r '.[] | select(.name == "custom_verify_patterns") | .current' \
    <<<"${flags_json}")"
{
  printf 'custom_verify_mcp_tools=mcp__trusted__*\n'
  printf 'custom_verify_mcp_tools=\n'
  printf 'custom_verify_patterns=trusted-wrapper\n'
  printf 'custom_verify_patterns=\n'
} > "${USER_CONF_PATH}"
flags_json="$(bash "${HELPER}" list-flags --json)"
assert_eq "Test 88: explicit empty MCP row revokes earlier authority" "" \
  "$(jq -r '.[] | select(.name == "custom_verify_mcp_tools") | .current' \
    <<<"${flags_json}")"
assert_eq "Test 88: explicit empty Bash row revokes earlier authority" "" \
  "$(jq -r '.[] | select(.name == "custom_verify_patterns") | .current' \
    <<<"${flags_json}")"
teardown

printf 'Test 89: metadata readers trim edges and use the last exact-key row\n'
setup
metadata_repo="${TEST_HOME}/source  repo's checkout"
metadata_padding="  "
mkdir -p "${metadata_repo}"
printf '9.9.9\n' > "${metadata_repo}/VERSION"
{
  printf 'installed_version=1.22.0\n'
  printf 'repo_path=/obsolete/checkout\n'
  printf 'repo_path=%s%s%s\n' \
    "${metadata_padding}" "${metadata_repo}" "${metadata_padding}"
} > "${USER_CONF_PATH}"
assert_eq "Test 89: padded duplicate repo_path resolves bundle update" \
  "update" "$(bash "${HELPER}" detect-mode)"
out="$(bash "${HELPER}" show 2>&1)"
assert_contains "Test 89: show resolves bundle through exact last repo_path" \
  "bundle:       9.9.9" "${out}"
teardown

printf 'Test 90: invalid config diagnostics escape terminal controls\n'
setup
project_dir="${TEST_HOME}/diagnostic"$'\033'"[35m-project"
mkdir -p "${project_dir}/.claude"
printf 'model_tier=bad%s[31m-tier\n' $'\033' > "${USER_CONF_PATH}"
printf 'gate_level=bad%s[32m-project\n' $'\033' \
  > "${project_dir}/.claude/oh-my-claude.conf"
out="$(cd "${project_dir}" \
  && OMC_STALL_THRESHOLD="bad"$'\033'"[33m-env" \
     bash "${HELPER}" show 2>&1)"
assert_not_contains "Test 90: terminal ESC bytes never reach diagnostics" \
  $'\033' "${out}"
assert_contains "Test 90: escaped invalid project value remains diagnosable" \
  "project gate_level=" "${out}"
assert_contains "Test 90: escaped invalid environment remains diagnosable" \
  "invalid OMC_STALL_THRESHOLD=" "${out}"
assert_contains "Test 90: escaped invalid saved tier remains diagnosable" \
  "saved model_tier=" "${out}"
set +e
direct_out="$(bash "${HELPER}" set user \
  "gate_level=bad"$'\033'"[31m-direct" 2>&1)"
direct_rc=$?
set -e
assert_eq "Test 90: direct invalid write exits 2" "2" "${direct_rc}"
assert_not_contains "Test 90: direct-set diagnostic escapes terminal ESC" \
  $'\033' "${direct_out}"
assert_contains "Test 90: escaped direct-set value remains diagnosable" \
  "gate_level" "${direct_out}"
teardown

printf 'Test 91: mutation writers preserve identity boundaries, modes, and the shared lock\n'
setup
conf_target="${TEST_HOME}/conf-target"
printf 'gate_level=full\n' > "${conf_target}"
ln -s "${conf_target}" "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user gate_level=basic 2>&1)"
rc=$?
set -e
assert_eq "Test 91: symlinked user conf is rejected" "1" "${rc}"
assert_eq "Test 91: user conf symlink is not severed" "yes" \
  "$([[ -L "${USER_CONF_PATH}" ]] && printf yes || printf no)"
assert_file_has_line "Test 91: symlink target remains untouched" \
  "${conf_target}" '^gate_level=full$'
teardown

setup
mkdir "${USER_CONF_PATH}"
set +e
out="$(bash "${HELPER}" set user gate_level=basic 2>&1)"
rc=$?
set -e
assert_eq "Test 91: directory config leaf is rejected" "1" "${rc}"
assert_eq "Test 91: directory config leaf remains a directory" "yes" \
  "$([[ -d "${USER_CONF_PATH}" ]] && printf yes || printf no)"
teardown

setup
printf 'gate_level=full\n' > "${USER_CONF_PATH}"
chmod 640 "${USER_CONF_PATH}"
settings_target="${TEST_HOME}/settings-target.json"
printf '{"outputStyle":"custom-style"}\n' > "${settings_target}"
ln -s "${settings_target}" "${TEST_HOME}/.claude/settings.json"
set +e
out="$(bash "${HELPER}" set user gate_level=basic \
  output_style=executive 2>&1)"
rc=$?
set -e
assert_eq "Test 91: settings alias rejects the atomic batch" "1" "${rc}"
assert_eq "Test 91: rolled-back config mode is preserved" "640" \
  "$(file_mode "${USER_CONF_PATH}")"
assert_file_has_line "Test 91: settings alias failure restores config bytes" \
  "${USER_CONF_PATH}" '^gate_level=full$'
assert_file_lacks_line "Test 91: failed style is never saved" \
  "${USER_CONF_PATH}" '^output_style='
assert_eq "Test 91: settings symlink is not severed" "yes" \
  "$([[ -L "${TEST_HOME}/.claude/settings.json" ]] \
    && printf yes || printf no)"
assert_eq "Test 91: settings symlink target remains untouched" \
  "custom-style" "$(jq -r '.outputStyle' "${settings_target}")"
assert_contains "Test 91: settings alias failure is surfaced" \
  "nothing changed" "${out}"
teardown

setup
umask 022
bash "${HELPER}" set user gate_level=basic >/dev/null
assert_eq "Test 91: new user conf is private" "600" \
  "$(file_mode "${USER_CONF_PATH}")"
project_dir="${TEST_HOME}/parent-alias-project"
mkdir -p "${project_dir}"
ln -s "${TEST_HOME}/.claude" "${project_dir}/.claude"
set +e
out="$(cd "${project_dir}" \
  && bash "${HELPER}" set project gate_level=full 2>&1)"
rc=$?
set -e
assert_eq "Test 91: symlinked project .claude parent is rejected" "1" "${rc}"
assert_file_has_line "Test 91: parent alias cannot rewrite user conf" \
  "${USER_CONF_PATH}" '^gate_level=basic$'
teardown

setup
mkdir "${TEST_HOME}/.claude/.install.lock"
printf '424242\n' > "${TEST_HOME}/.claude/.install.lock/pid"
printf 'foreign-token\n' > "${TEST_HOME}/.claude/.install.lock/token"
set +e
out="$(OMC_TEST_CONFIG_LOCK_ATTEMPTS=1 bash "${HELPER}" set user \
  gate_level=basic 2>&1)"
rc=$?
set -e
assert_eq "Test 91: contended shared operation lock fails closed" "1" "${rc}"
assert_contains "Test 91: lock contention names exact lock" \
  ".install.lock" "${out}"
assert_eq "Test 91: foreign lock token is not removed" "foreign-token" \
  "$(cat "${TEST_HOME}/.claude/.install.lock/token")"
assert_eq "Test 91: contended mutation does not create conf" "no" \
  "$([[ -e "${USER_CONF_PATH}" ]] && printf yes || printf no)"
teardown

setup
mkdir "${TEST_HOME}/.claude/.install.lock"
printf '424242\n' > "${TEST_HOME}/.claude/.install.lock/pid"
printf '424242.1.2\0\n' > "${TEST_HOME}/.claude/.install.lock/token"
nul_lock_token_before="$(cksum \
  < "${TEST_HOME}/.claude/.install.lock/token")"
set +e
OMC_TEST_CONFIG_LOCK_ATTEMPTS=1 \
  OMC_PARENT_OPERATION_LOCK_PID=424242 \
  OMC_PARENT_OPERATION_LOCK_TOKEN=424242.1.2 \
  bash "${HELPER}" recover-only >/dev/null 2>&1
rc=$?
set -e
assert_eq "Test 91: NUL-normalized borrowed lock is rejected" "1" "${rc}"
assert_eq "Test 91: malformed borrowed lock remains retained" "yes" \
  "$([[ -d "${TEST_HOME}/.claude/.install.lock" ]] \
    && printf yes || printf no)"
assert_eq "Test 91: malformed borrowed token bytes remain exact" \
  "${nul_lock_token_before}" \
  "$(cksum < "${TEST_HOME}/.claude/.install.lock/token")"
teardown

setup
lock="${TEST_HOME}/.claude/.install.lock"
mkdir "${lock}"
printf '424242\n' > "${lock}/pid"
printf '424242.1.2\n' > "${lock}/token"
lock_id="$(stat -f '%d:%i' "${lock}" 2>/dev/null \
  || stat -c '%d:%i' "${lock}" 2>/dev/null)"
printf 'v1\t%s\t424242\t424242.1.2\0\n' "${lock_id}" \
  > "${lock}/owner-released"
chmod 600 "${lock}/owner-released"
nul_release_marker_before="$(cksum < "${lock}/owner-released")"
set +e
OMC_TEST_CONFIG_LOCK_ATTEMPTS=1 bash "${HELPER}" recover-only \
  >/dev/null 2>&1
rc=$?
set -e
assert_eq "Test 91: NUL-normalized release marker is rejected" "1" "${rc}"
assert_eq "Test 91: malformed released generation is not reaped" "yes" \
  "$([[ -f "${lock}/owner-released" && -f "${lock}/pid" \
      && -f "${lock}/token" ]] && printf yes || printf no)"
assert_eq "Test 91: malformed release-marker bytes remain exact" \
  "${nul_release_marker_before}" "$(cksum < "${lock}/owner-released")"
teardown

printf 'Test 92: config/materialization transactions recover every crash boundary\n'
setup
install_real_model_switch_fixture
printf 'model_tier=balanced\ngate_level=full\ncustom_row=keep\n' \
  > "${USER_CONF_PATH}"
printf '{"outputStyle":"custom-style","keep":true}\n' \
  > "${TEST_HOME}/.claude/settings.json"
chmod 640 "${USER_CONF_PATH}" "${TEST_HOME}/.claude/settings.json"
agents_before="$(agent_tree_digest)"
conf_before="$(cksum < "${USER_CONF_PATH}")"
settings_before="$(cksum < "${TEST_HOME}/.claude/settings.json")"
set +e
out="$(OMC_TEST_CONFIG_FAIL_AFTER_SETTINGS=1 bash "${HELPER}" set user \
  model_tier=quality gate_level=basic output_style=executive 2>&1)"
rc=$?
set -e
assert_eq "Test 92: injected post-settings failure exits nonzero" "1" "${rc}"
assert_contains "Test 92: injected failure reports rollback" \
  "rolling back the whole batch" "${out}"
assert_eq "Test 92: graceful rollback restores all agents" \
  "${agents_before}" "$(agent_tree_digest)"
assert_eq "Test 92: graceful rollback restores config bytes" \
  "${conf_before}" "$(cksum < "${USER_CONF_PATH}")"
assert_eq "Test 92: graceful rollback restores settings bytes" \
  "${settings_before}" "$(cksum < "${TEST_HOME}/.claude/settings.json")"
assert_eq "Test 92: graceful rollback preserves config mode" "640" \
  "$(file_mode "${USER_CONF_PATH}")"
assert_eq "Test 92: graceful rollback preserves settings mode" "640" \
  "$(file_mode "${TEST_HOME}/.claude/settings.json")"
assert_eq "Test 92: graceful rollback retires parent WAL" "no" \
  "$([[ -e "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
    && printf yes || printf no)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\ngate_level=full\n' > "${USER_CONF_PATH}"
printf '{"outputStyle":"custom-style"}\n' \
  > "${TEST_HOME}/.claude/settings.json"
agents_before="$(agent_tree_digest)"
conf_before="$(cksum < "${USER_CONF_PATH}")"
settings_before="$(cksum < "${TEST_HOME}/.claude/settings.json")"
ready="${TEST_HOME}/post-model.ready"
release="${TEST_HOME}/post-model.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_POST_MODEL_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality output_style=executive \
    >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e
  wait "${txn_pid}" 2>/dev/null
  set -e
  if remove_killed_owner_lock "${txn_pid}" \
      && OMC_SWITCH_SKIP_CONF_PERSIST=1 \
        OMC_SWITCH_PARENT_TX_CAPABILITY=poisoned \
        bash "${HELPER}" recover-only >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: Test 92: killed parent transaction could not be recovered\n' >&2
    fail=$((fail + 1))
  fi
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: post-model SIGKILL barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
assert_eq "Test 92: SIGKILL rollback restores agents" \
  "${agents_before}" "$(agent_tree_digest)"
assert_eq "Test 92: SIGKILL rollback restores config" \
  "${conf_before}" "$(cksum < "${USER_CONF_PATH}")"
assert_eq "Test 92: SIGKILL rollback leaves settings untouched" \
  "${settings_before}" "$(cksum < "${TEST_HOME}/.claude/settings.json")"
assert_eq "Test 92: recover-only retires parent WAL" "no" \
  "$([[ -e "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
    && printf yes || printf no)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
agents_before="$(agent_tree_digest)"
conf_before="$(cksum < "${USER_CONF_PATH}")"
ready="${TEST_HOME}/parent-stage.ready"
release="${TEST_HOME}/parent-stage.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_WAL_STAGE_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_WAL_STAGE_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  if bash "${HELPER}" recover-only >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: Test 92: orphan parent stage blocked recover-only\n' >&2
    fail=$((fail + 1))
  fi
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent stage barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
assert_eq "Test 92: unpublished parent stage never changes agents" \
  "${agents_before}" "$(agent_tree_digest)"
assert_eq "Test 92: unpublished parent stage never changes config" \
  "${conf_before}" "$(cksum < "${USER_CONF_PATH}")"
assert_eq "Test 92: orphan parent stages are swept" "" \
  "$(find "${TEST_HOME}/.claude" -maxdepth 1 \
    -name '.omc-config-transaction.stage.*' -print -quit)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-commit.ready"
release="${TEST_HOME}/parent-commit.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_COMMIT_LINK_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_COMMIT_LINK_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  if bash "${HELPER}" recover-only >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: Test 92: committed parent metadata could not retire\n' >&2
    fail=$((fail + 1))
  fi
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent commit-link barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
assert_file_has_line "Test 92: committed parent crash keeps final tier" \
  "${USER_CONF_PATH}" '^model_tier=quality$'
assert_eq "Test 92: committed parent crash keeps final agents" "opus" \
  "$(installed_agent_model librarian)"
assert_eq "Test 92: committed parent metadata is removed" "no" \
  "$([[ -e "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
    && printf yes || printf no)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-retired.ready"
release="${TEST_HOME}/parent-retired.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_RETIRE_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_RETIRE_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  bash "${HELPER}" recover-only >/dev/null 2>&1 || true
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
fi
assert_file_has_line "Test 92: authorized retired crash keeps final config" \
  "${USER_CONF_PATH}" '^model_tier=quality$'
assert_eq "Test 92: authorized retired parent is swept" "" \
  "$(find "${TEST_HOME}/.claude" -maxdepth 1 \
    -name '.omc-config-retired.*' -print -quit)"
mkdir -m 700 "${TEST_HOME}/.claude/.omc-config-retired.EMPTY01"
bash "${HELPER}" recover-only >/dev/null 2>&1
assert_eq "Test 92: empty retired parent crash window is swept" "no" \
  "$([[ -e "${TEST_HOME}/.claude/.omc-config-retired.EMPTY01" ]] \
    && printf yes || printf no)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/corrupt-parent.ready"
release="${TEST_HOME}/corrupt-parent.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_POST_MODEL_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  agents_current="$(agent_tree_digest)"
  conf_current="$(cksum < "${USER_CONF_PATH}")"
  cp -p "${TEST_HOME}/.claude/.omc-config-transaction/version" \
    "${TEST_HOME}/config-version.saved"
  printf '1\0\n' > "${TEST_HOME}/.claude/.omc-config-transaction/version"
  set +e
  bash "${HELPER}" recover-only >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "Test 92: raw-NUL parent WAL authority fails closed" "1" "${rc}"
  assert_eq "Test 92: raw-NUL parent WAL does not change agents" \
    "${agents_current}" "$(agent_tree_digest)"
  assert_eq "Test 92: raw-NUL parent WAL does not change config" \
    "${conf_current}" "$(cksum < "${USER_CONF_PATH}")"
  assert_eq "Test 92: raw-NUL parent WAL remains retained" "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
  cp -p "${TEST_HOME}/config-version.saved" \
    "${TEST_HOME}/.claude/.omc-config-transaction/version"
  printf '1\\u0000\n' > "${TEST_HOME}/.claude/.omc-config-transaction/version"
  set +e
  bash "${HELPER}" recover-only >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "Test 92: escaped-NUL parent WAL authority fails closed" "1" "${rc}"
  assert_eq "Test 92: escaped-NUL parent WAL remains retained" "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
  cp -p "${TEST_HOME}/config-version.saved" \
    "${TEST_HOME}/.claude/.omc-config-transaction/version"
  printf '1\n\n' > "${TEST_HOME}/.claude/.omc-config-transaction/version"
  set +e
  bash "${HELPER}" recover-only >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "Test 92: extra parent WAL version record fails closed" "1" "${rc}"
  assert_eq "Test 92: extra parent WAL version record remains retained" "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
  cp -p "${TEST_HOME}/config-version.saved" \
    "${TEST_HOME}/.claude/.omc-config-transaction/version"
  cp -p "${TEST_HOME}/.claude/.omc-config-transaction/agents.tsv" \
    "${TEST_HOME}/config-agents.saved"
  printf '\n' >> "${TEST_HOME}/.claude/.omc-config-transaction/agents.tsv"
  set +e
  bash "${HELPER}" recover-only >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "Test 92: trailing blank parent TSV record fails closed" "1" "${rc}"
  assert_eq "Test 92: trailing blank parent TSV does not change agents" \
    "${agents_current}" "$(agent_tree_digest)"
  assert_eq "Test 92: trailing blank parent TSV does not change config" \
    "${conf_current}" "$(cksum < "${USER_CONF_PATH}")"
  assert_eq "Test 92: trailing blank parent TSV remains retained" "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
  cp -p "${TEST_HOME}/config-agents.saved" \
    "${TEST_HOME}/.claude/.omc-config-transaction/agents.tsv"
  printf 'truncated-row' \
    >> "${TEST_HOME}/.claude/.omc-config-transaction/agent-intents.tsv"
  set +e
  out="$(bash "${HELPER}" recover-only 2>&1)"
  rc=$?
  set -e
  assert_eq "Test 92: truncated parent WAL fails closed" "1" "${rc}"
  assert_eq "Test 92: malformed WAL does not change agents" \
    "${agents_current}" "$(agent_tree_digest)"
  assert_eq "Test 92: malformed WAL does not change config" \
    "${conf_current}" "$(cksum < "${USER_CONF_PATH}")"
  assert_eq "Test 92: malformed WAL is retained for inspection" "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: corrupt-parent setup barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-final-race.ready"
release="${TEST_HOME}/parent-final-race.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_POST_MODEL_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  printf '\n# foreign parent-generation edit\n' \
    >> "${TEST_HOME}/.claude/agents/librarian.md"
  : > "${release}"
  set +e
  wait "${txn_pid}" 2>/dev/null
  rc=$?
  set -e
  assert_eq "Test 92: parent final-generation race rejects commit" "1" "${rc}"
  assert_file_has_line "Test 92: foreign final generation is not erased" \
    "${TEST_HOME}/.claude/agents/librarian.md" \
    '^# foreign parent-generation edit$'
  assert_eq "Test 92: parent WAL remains after foreign-generation conflict" \
    "yes" \
    "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
      && printf yes || printf no)"
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent final-generation barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
teardown

setup
install_real_model_switch_fixture
mkdir -m 700 \
  "${TEST_HOME}/.claude/.switch-tier-transaction.stage.MANUAL1"
bash "${HELPER}" recover-only >/dev/null 2>&1
assert_eq "Test 92: parent recover-only sweeps child orphan metadata" "no" \
  "$([[ -e "${TEST_HOME}/.claude/.switch-tier-transaction.stage.MANUAL1" ]] \
    && printf yes || printf no)"
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-recovery-race-crash.ready"
release="${TEST_HOME}/parent-recovery-race-crash.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_POST_MODEL_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  recover_ready="${TEST_HOME}/parent-recovery-race.ready"
  recover_release="${TEST_HOME}/parent-recovery-race.release"
  OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
    OMC_TEST_CONFIG_RECOVERY_READY_FILE="${recover_ready}" \
    OMC_TEST_CONFIG_RECOVERY_RELEASE_FILE="${recover_release}" \
    bash "${HELPER}" recover-only >/dev/null 2>&1 &
  recover_pid=$!
  if wait_for_file "${recover_ready}"; then
    printf '\n# foreign parent recovery edit\n' \
      >> "${TEST_HOME}/.claude/agents/librarian.md"
    : > "${recover_release}"
    set +e
    wait "${recover_pid}" 2>/dev/null
    rc=$?
    set -e
    assert_eq "Test 92: parent recovery race rejects WAL retirement" "1" \
      "${rc}"
    assert_file_has_line "Test 92: parent recovery preserves foreign bytes" \
      "${TEST_HOME}/.claude/agents/librarian.md" \
      '^# foreign parent recovery edit$'
    assert_eq "Test 92: parent recovery race retains WAL" "yes" \
      "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
        && printf yes || printf no)"
  else
    kill -9 "${recover_pid}" 2>/dev/null || true
    set +e; wait "${recover_pid}" 2>/dev/null; set -e
    printf '  FAIL: Test 92: parent recovery final barrier was never reached\n' >&2
    fail=$((fail + 1))
  fi
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent recovery-race setup barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-dir-race-crash.ready"
release="${TEST_HOME}/parent-dir-race-crash.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_POST_MODEL_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_POST_MODEL_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  remove_killed_owner_lock "${txn_pid}" || true
  recover_ready="${TEST_HOME}/parent-dir-race.ready"
  recover_release="${TEST_HOME}/parent-dir-race.release"
  OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
    OMC_TEST_CONFIG_RECOVERY_READY_FILE="${recover_ready}" \
    OMC_TEST_CONFIG_RECOVERY_RELEASE_FILE="${recover_release}" \
    bash "${HELPER}" recover-only >/dev/null 2>&1 &
  recover_pid=$!
  if wait_for_file "${recover_ready}"; then
    mv "${TEST_HOME}/.claude/agents" \
      "${TEST_HOME}/agents-original-generation"
    cp -R "${TEST_HOME}/agents-original-generation" \
      "${TEST_HOME}/.claude/agents"
    : > "${recover_release}"
    set +e
    wait "${recover_pid}" 2>/dev/null
    rc=$?
    set -e
    assert_eq "Test 92: parent rejects agents-directory replacement" "1" \
      "${rc}"
    assert_eq "Test 92: directory replacement retains parent WAL" "yes" \
      "$([[ -d "${TEST_HOME}/.claude/.omc-config-transaction" ]] \
        && printf yes || printf no)"
  else
    kill -9 "${recover_pid}" 2>/dev/null || true
    set +e; wait "${recover_pid}" 2>/dev/null; set -e
    printf '  FAIL: Test 92: parent directory-race barrier was never reached\n' >&2
    fail=$((fail + 1))
  fi
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent directory-race setup barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
teardown

setup
install_real_model_switch_fixture
printf 'model_tier=balanced\n' > "${USER_CONF_PATH}"
ready="${TEST_HOME}/parent-retirement-replacement.ready"
release="${TEST_HOME}/parent-retirement-replacement.release"
OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  OMC_TEST_CONFIG_RETIRE_READY_FILE="${ready}" \
  OMC_TEST_CONFIG_RETIRE_RELEASE_FILE="${release}" \
  bash "${HELPER}" set user model_tier=quality >/dev/null 2>&1 &
txn_pid=$!
if wait_for_file "${ready}"; then
  retired_parent="$(cat "${ready}")"
  mv "${retired_parent}/transaction" \
    "${retired_parent}/original-transaction"
  mkdir -m 700 "${retired_parent}/transaction"
  printf 'do-not-delete\n' > "${retired_parent}/transaction/sentinel"
  : > "${release}"
  set +e
  wait "${txn_pid}" 2>/dev/null
  rc=$?
  set -e
  assert_eq "Test 92: parent retirement replacement exits nonzero" "1" \
    "${rc}"
  assert_file_has_line \
    "Test 92: parent retirement does not delete replacement tree" \
    "${retired_parent}/transaction/sentinel" '^do-not-delete$'
  assert_eq "Test 92: original retired parent WAL remains recoverable" "yes" \
    "$([[ -d "${retired_parent}/original-transaction" ]] \
      && printf yes || printf no)"
else
  kill -9 "${txn_pid}" 2>/dev/null || true
  set +e; wait "${txn_pid}" 2>/dev/null; set -e
  printf '  FAIL: Test 92: parent retirement replacement barrier was never reached\n' >&2
  fail=$((fail + 1))
fi
teardown

setup
install_real_model_switch_fixture
mv "${TEST_HOME}/.claude/agents" "${TEST_HOME}/outside-agents"
ln -s "${TEST_HOME}/outside-agents" "${TEST_HOME}/.claude/agents"
outside_before="$(cksum < "${TEST_HOME}/outside-agents/librarian.md")"
set +e
out="$(bash "${HELPER}" set user model_tier=quality 2>&1)"
rc=$?
set -e
assert_eq "Test 92: parent rejects symlinked agents directory" "1" "${rc}"
assert_eq "Test 92: symlinked agents referent is unchanged" \
  "${outside_before}" "$(cksum < "${TEST_HOME}/outside-agents/librarian.md")"
assert_eq "Test 92: rejected parent does not save model tier" "no" \
  "$([[ -e "${USER_CONF_PATH}" ]] && printf yes || printf no)"
teardown

setup
outside_wal="${TEST_HOME}/outside-wal"
mkdir "${outside_wal}"
printf 'keep\n' > "${outside_wal}/sentinel"
ln -s "${outside_wal}" "${TEST_HOME}/.claude/.omc-config-transaction"
set +e
out="$(bash "${HELPER}" recover-only 2>&1)"
rc=$?
set -e
assert_eq "Test 92: symlinked parent WAL fails closed" "1" "${rc}"
assert_file_has_line "Test 92: symlinked WAL referent is untouched" \
  "${outside_wal}/sentinel" '^keep$'
teardown

# --- Summary ---
printf '\n=== test-omc-config: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
