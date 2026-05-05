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

# --- Test 13: apply-preset maximum writes all 24 keys (v1.28.0 added
# blindspot_inventory + intent_broadening; v1.30.0 added prompt_persist;
# v1.32.0 added divergence_directive; v1.33.0 added directive_budget;
# v1.34.0 added inferred_contract for Delivery Contract v2) ---
printf 'Test 13: apply-preset maximum writes 24 keys\n'
setup
out="$(bash "${HELPER}" apply-preset user maximum 2>&1)"
assert_contains "apply-preset reports 24 keys" "24 keys" "${out}"
assert_file_has_line "maximum: gate_level=full" "${USER_CONF_PATH}" "^gate_level=full\$"
assert_file_has_line "maximum: guard_exhaustion_mode=block" "${USER_CONF_PATH}" "^guard_exhaustion_mode=block\$"
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
# Regression net: council_deep_default=on belongs in Maximum (consistent
# with model_tier=quality — every quality lever pulled). Originally
# shipped as `off` for cost reasons; corrected after user review pointed
# out the inconsistency. This assertion locks the right value in.
assert_file_has_line "maximum: council_deep_default=on" "${USER_CONF_PATH}" "^council_deep_default=on\$"
# v1.28.0: blindspot_inventory + intent_broadening included in maximum.
assert_file_has_line "maximum: blindspot_inventory=on" "${USER_CONF_PATH}" "^blindspot_inventory=on\$"
assert_file_has_line "maximum: intent_broadening=on" "${USER_CONF_PATH}" "^intent_broadening=on\$"
assert_file_has_line "maximum: directive_budget=maximum" "${USER_CONF_PATH}" "^directive_budget=maximum\$"
teardown

# --- Test 14: apply-preset balanced writes balanced values ---
printf 'Test 14: apply-preset balanced writes balanced defaults\n'
setup
bash "${HELPER}" apply-preset user balanced > /dev/null
assert_file_has_line "balanced: guard_exhaustion_mode=scorecard" "${USER_CONF_PATH}" "^guard_exhaustion_mode=scorecard\$"
assert_file_has_line "balanced: prometheus_suggest=off" "${USER_CONF_PATH}" "^prometheus_suggest=off\$"
assert_file_has_line "balanced: exemplifying_scope_gate=on" "${USER_CONF_PATH}" "^exemplifying_scope_gate=on\$"
assert_file_has_line "balanced: resume_watchdog=off" "${USER_CONF_PATH}" "^resume_watchdog=off\$"
assert_file_has_line "balanced: model_tier=balanced" "${USER_CONF_PATH}" "^model_tier=balanced\$"
assert_file_has_line "balanced: directive_budget=balanced" "${USER_CONF_PATH}" "^directive_budget=balanced\$"
# Counterpart to the Maximum assertion above — Balanced is where the
# council cost cap lives. If someone ever flips this to `on`, the cap
# moves and Balanced loses its reason to exist.
assert_file_has_line "balanced: council_deep_default=off" "${USER_CONF_PATH}" "^council_deep_default=off\$"
teardown

# --- Test 15: apply-preset minimal writes minimal values ---
printf 'Test 15: apply-preset minimal writes minimal defaults\n'
setup
bash "${HELPER}" apply-preset user minimal > /dev/null
assert_file_has_line "minimal: gate_level=basic" "${USER_CONF_PATH}" "^gate_level=basic\$"
assert_file_has_line "minimal: guard_exhaustion_mode=silent" "${USER_CONF_PATH}" "^guard_exhaustion_mode=silent\$"
assert_file_has_line "minimal: auto_memory=off" "${USER_CONF_PATH}" "^auto_memory=off\$"
assert_file_has_line "minimal: exemplifying_scope_gate=off" "${USER_CONF_PATH}" "^exemplifying_scope_gate=off\$"
assert_file_has_line "minimal: model_tier=economy" "${USER_CONF_PATH}" "^model_tier=economy\$"
assert_file_has_line "minimal: directive_budget=minimal" "${USER_CONF_PATH}" "^directive_budget=minimal\$"
# stop_failure_capture stays on across all presets (privacy + utility).
assert_file_has_line "minimal: stop_failure_capture stays on" "${USER_CONF_PATH}" "^stop_failure_capture=on\$"
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
# Maximum must include council_deep_default=on for internal consistency
# with model_tier=quality. Cost cap lives in Balanced.
assert_contains "presets maximum has council_deep_default=on" "council_deep_default=on" "${out}"
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

# --- Test 38 (P1-4): apply-preset does NOT fire apply-tier when tier unchanged ---
printf 'Test 38: apply-preset skips switch-tier when tier unchanged\n'
setup
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
# Mock script must NOT have been invoked.
if [[ ! -f "${TEST_HOME}/.claude/.switch-tier.invocations" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: P1-4: switch-tier.sh invoked when tier did not change\n' >&2
  fail=$((fail + 1))
fi
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

# --- Test 45 (P3 #7): cmd_set skips switch-tier when tier unchanged ---
printf 'Test 45: cmd_set skips switch-tier.sh when tier unchanged\n'
setup
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
if [[ ! -f "${TEST_HOME}/.claude/.set-switch-tier-skip.invocations" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: P3 #7: switch-tier.sh invoked when tier did not change in cmd_set\n' >&2
  fail=$((fail + 1))
fi
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

printf 'Test 50: user-set custom outputStyle is NOT auto-synced even on bundled-style change\n'
setup
mkdir -p "${TEST_HOME}/.claude"
# User has a custom style (not in the bundled set). Switching the conf
# flag must NOT silently rewrite the user's choice.
printf '{"outputStyle":"my-very-custom-style"}\n' > "${TEST_HOME}/.claude/settings.json"
bash "${HELPER}" set user output_style=opencode >/dev/null 2>&1
preserved_custom="$(jq -r '.outputStyle' "${TEST_HOME}/.claude/settings.json" 2>/dev/null)"
assert_eq "Test 50: user-custom outputStyle preserved across opencode set" "my-very-custom-style" "${preserved_custom}"
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

printf 'Test 57: set claude_bin to legitimate path accepted\n'
setup
out="$(bash "${HELPER}" set user claude_bin=/usr/local/bin/claude 2>&1)"
rc=$?
assert_eq "Test 57: set claude_bin=/usr/local/bin/claude exit 0" "0" "${rc}"
# Verify it landed in the conf file.
written="$(grep '^claude_bin=' "${TEST_HOME}/.claude/oh-my-claude.conf" 2>/dev/null \
  | head -1 | cut -d= -f2-)"
assert_eq "Test 57: legit claude_bin written to conf" "/usr/local/bin/claude" "${written}"
teardown

# --- Summary ---
printf '\n=== test-omc-config: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
