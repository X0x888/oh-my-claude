#!/usr/bin/env bash
#
# Tests for quality-pack/scripts/session-start-welcome.sh — the SessionStart
# hook that closes the v1.29.0 growth-lens P0-3 silent-dropoff trap by
# detecting install-without-restart and surfacing a one-shot welcome
# banner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-welcome.sh"

ORIG_HOME="${HOME}"
ORIG_PWD="${PWD}"
pass=0
fail=0

setup_test() {
  TEST_HOME="$(mktemp -d)"
  export HOME="${TEST_HOME}"
  mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
  ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh" \
    "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
  for lib in state-io.sh classifier.sh verification.sh timing.sh; do
    if [[ -f "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" ]]; then
      ln -sf "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/${lib}" \
        "${TEST_HOME}/.claude/skills/autowork/scripts/lib/${lib}"
    fi
  done
  mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
  export STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state"
  unset OMC_PROMPT_PERSIST 2>/dev/null || true
}

teardown_test() {
  export HOME="${ORIG_HOME}"
  cd "${ORIG_PWD}" 2>/dev/null || true
  rm -rf "${TEST_HOME}" 2>/dev/null || true
  unset STATE_ROOT 2>/dev/null || true
}

trap 'teardown_test' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s\n    actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

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

# Run the hook with a synthetic SessionStart payload. Returns the
# decoded additionalContext or empty if no banner was emitted.
run_hook() {
  local sid="$1"
  local source="${2:-startup}"
  local hook_json
  hook_json="$(jq -nc \
    --arg sid "${sid}" \
    --arg src "${source}" \
    '{session_id:$sid, source:$src, cwd:env.PWD}')"

  bash "${HOOK}" <<<"${hook_json}" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null \
    || true
}

# ----------------------------------------------------------------------
printf 'Test 1: first emit — install-stamp + no marker + no prompts → banner fires\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

out="$(run_hook "t1-${RANDOM}")"
assert_contains "T1: banner mentions oh-my-claude" "oh-my-claude" "${out}"
assert_contains "T1: banner mentions version" "v1.30.0" "${out}"
assert_contains "T1: banner recommends /ulw-demo" "/ulw-demo" "${out}"
assert_contains "T1: banner mentions /omc-config" "/omc-config" "${out}"
[[ -f "${TEST_HOME}/.claude/.welcome-shown-at" ]] && pass=$((pass + 1)) \
  || { printf '  FAIL: T1: marker not stamped\n' >&2; fail=$((fail + 1)); }
teardown_test

# ----------------------------------------------------------------------
printf 'Test 2: second emit suppressed by per-install marker\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

# First fire: emits.
_ignored="$(run_hook "t2a-${RANDOM}")"
# Marker now records install-stamp's mtime.
# Second fire (different session_id, no fresh install) → silent.
out="$(run_hook "t2b-${RANDOM}")"
assert_eq "T2: second session-start no banner" "" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 3: re-install triggers re-emit (install-stamp newer than marker)\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

_ignored="$(run_hook "t3a-${RANDOM}")"

# Simulate a re-install: bump install-stamp's mtime forward by 10s.
# touch -t accepts CCYYMMDDhhmm.SS; date +%s is converted via the
# BSD/GNU two-step.
future_ts=$(( $(date +%s) + 10 ))
touch_ts="$(date -r "${future_ts}" +%Y%m%d%H%M.%S 2>/dev/null \
  || date -d "@${future_ts}" +%Y%m%d%H%M.%S 2>/dev/null)"
if [[ -n "${touch_ts}" ]]; then
  touch -t "${touch_ts}" "${TEST_HOME}/.claude/.install-stamp"
fi

out="$(run_hook "t3b-${RANDOM}")"
assert_contains "T3: re-install banner fires again" "oh-my-claude" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 4: recent_prompts.jsonl present → silent (user already engaged)\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

sid="t4-${RANDOM}"
mkdir -p "${STATE_ROOT}/${sid}"
printf '{"ts":1,"text":"prior prompt"}\n' > "${STATE_ROOT}/${sid}/recent_prompts.jsonl"

out="$(run_hook "${sid}")"
assert_eq "T4: existing recent_prompts suppresses banner" "" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 5: per-session idempotency — welcome_banner_emitted=1 → silent\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

sid="t5-${RANDOM}"
mkdir -p "${STATE_ROOT}/${sid}"
printf '{"welcome_banner_emitted":"1"}\n' > "${STATE_ROOT}/${sid}/session_state.json"

out="$(run_hook "${sid}")"
assert_eq "T5: per-session flag suppresses banner" "" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 6: missing install-stamp → silent (partial install / test rig)\n'
setup_test
# Note: NO .install-stamp file. Conf still set.
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

out="$(run_hook "t6-${RANDOM}")"
assert_eq "T6: missing install-stamp → no banner" "" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 7: corrupt marker → re-emit (defensive against partial writes)\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"
# Garbage marker — not a numeric epoch.
printf 'corrupt-content\n' > "${TEST_HOME}/.claude/.welcome-shown-at"

out="$(run_hook "t7-${RANDOM}")"
assert_contains "T7: corrupt marker triggers re-emit" "oh-my-claude" "${out}"
# Verify the marker was reset to a numeric epoch.
new_marker="$(cat "${TEST_HOME}/.claude/.welcome-shown-at" 2>/dev/null || echo "")"
if [[ "${new_marker}" =~ ^[0-9]+$ ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: T7: marker not reset to numeric (got %q)\n' "${new_marker}" >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
printf 'Test 8: missing version conf → banner shows (unknown) gracefully\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
# No conf file — version unreadable.

out="$(run_hook "t8-${RANDOM}")"
assert_contains "T8: missing conf falls back to (unknown)" "(unknown)" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 9: per-session state flag is set after emit\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
printf 'installed_version=1.30.0\n' > "${TEST_HOME}/.claude/oh-my-claude.conf"

sid="t9-${RANDOM}"
_ignored="$(run_hook "${sid}")"
state="${STATE_ROOT}/${sid}/session_state.json"
if [[ -f "${state}" ]]; then
  flag="$(jq -r '.welcome_banner_emitted // ""' "${state}")"
  assert_eq "T9: state flag set to 1 after emit" "1" "${flag}"
else
  printf '  FAIL: T9: session_state.json not created\n' >&2
  fail=$((fail + 1))
fi
teardown_test

# ----------------------------------------------------------------------
printf 'Test 10: missing session_id → exit 0 silently\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"

out="$(printf '{}' | bash "${HOOK}" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
assert_eq "T10: empty session_id no output" "" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 11 (v1.36.0 #17): conf profile line — maximum defaults\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
# Conf with ONLY auto-set keys → 0 user overrides → "maximum defaults" line.
cat > "${TEST_HOME}/.claude/oh-my-claude.conf" <<EOF
repo_path=/Users/xxxcoding/Documents/ai-coding/oh-my-claude
installed_version=1.36.0
installed_sha=abc123
model_tier=quality
output_style=opencode
EOF
out="$(run_hook "t11-${RANDOM}")"
assert_contains "T11: banner mentions maximum defaults" "maximum defaults" "${out}"
assert_contains "T11: banner suggests omc-config for profile switch" "switch profile" "${out}"
assert_not_contains "T11: not flag-override mode when count is 0" "flag override(s) active" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf 'Test 12 (v1.36.0 #17): conf profile line — N overrides\n'
setup_test
touch "${TEST_HOME}/.claude/.install-stamp"
# Add 3 user overrides on top of the auto-set keys.
cat > "${TEST_HOME}/.claude/oh-my-claude.conf" <<EOF
repo_path=/Users/xxxcoding/Documents/ai-coding/oh-my-claude
installed_version=1.36.0
model_tier=quality
output_style=opencode
directive_budget=balanced
prompt_persist=off
auto_memory=off
EOF
out="$(run_hook "t12-${RANDOM}")"
assert_contains "T12: banner names override count" "3 flag override(s) active" "${out}"
assert_not_contains "T12: not maximum-defaults mode when overrides present" "maximum defaults" "${out}"
teardown_test

# ----------------------------------------------------------------------
printf '\n=== Session-start-welcome tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
