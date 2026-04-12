#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common.sh for state functions
# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

# Set up a temporary state root for isolated testing
TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="test-session"
ensure_session_dir

cleanup() {
  rm -rf "${TEST_STATE_ROOT}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

# --- Test: stall_paths.log tracks paths correctly ---
printf '=== Stall Detection Tests ===\n\n'

printf 'Path tracking:\n'

# Simulate appending paths
append_limited_state "stall_paths.log" "/src/foo.ts" "12"
append_limited_state "stall_paths.log" "/src/bar.ts" "12"
append_limited_state "stall_paths.log" "/src/foo.ts" "12"

paths_file="$(session_file "stall_paths.log")"
total="$(wc -l < "${paths_file}" | tr -d '[:space:]')"
unique="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"

assert_eq "3 paths tracked" "3" "${total}"
assert_eq "2 unique paths" "2" "${unique}"

# --- Test: window limits to 12 entries ---
printf '\nWindow limiting:\n'

: > "${paths_file}"
for i in $(seq 1 15); do
  append_limited_state "stall_paths.log" "/src/file${i}.ts" "12"
done

total="$(wc -l < "${paths_file}" | tr -d '[:space:]')"
assert_eq "window capped at 12" "12" "${total}"

# --- Test: spinning detection (same file repeated) ---
printf '\nSpinning detection:\n'

: > "${paths_file}"
for _ in $(seq 1 12); do
  append_limited_state "stall_paths.log" "/src/same.ts" "12"
done

unique="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"
assert_eq "1 unique path (spinning)" "1" "${unique}"

# Verify this would trigger strong warning (unique < 4)
if [[ "${unique}" -lt 4 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: spinning should trigger strong warning (unique=%s, threshold <4)\n' "${unique}" >&2
  fail=$((fail + 1))
fi

# --- Test: wide exploration (many unique files) ---
printf '\nWide exploration:\n'

: > "${paths_file}"
for i in $(seq 1 12); do
  append_limited_state "stall_paths.log" "/src/module${i}/index.ts" "12"
done

unique="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"
assert_eq "12 unique paths (exploration)" "12" "${unique}"

# Verify this would reset silently (unique >= 8)
if [[ "${unique}" -ge 8 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: wide exploration should reset silently (unique=%s, threshold >=8)\n' "${unique}" >&2
  fail=$((fail + 1))
fi

# --- Test: moderate exploration (4-7 unique files) ---
printf '\nModerate exploration:\n'

: > "${paths_file}"
for i in $(seq 1 5); do
  append_limited_state "stall_paths.log" "/src/file${i}.ts" "12"
done
for i in $(seq 1 7); do
  append_limited_state "stall_paths.log" "/src/file1.ts" "12"
done

total="$(wc -l < "${paths_file}" | tr -d '[:space:]')"
unique="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"

assert_eq "window at 12" "12" "${total}"
# After limiting to 12: last 12 of 12 entries = 5 unique + 7 repeats of file1
# But append_limited_state keeps the LAST 12 lines, so:
# file1, file2, file3, file4, file5, file1, file1, file1, file1, file1, file1, file1
# unique = 5

if [[ "${unique}" -ge 4 && "${unique}" -lt 8 ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: moderate exploration should get lighter nudge (unique=%s, threshold 4-7)\n' "${unique}" >&2
  fail=$((fail + 1))
fi

# --- Test: counter reset clears window ---
printf '\nCounter reset clears window:\n'

: > "${paths_file}"
append_limited_state "stall_paths.log" "/src/old.ts" "12"
write_state "stall_counter" "0"

# Simulate what record-advisory-verification.sh does when counter is 0
stall_counter="$(read_state "stall_counter")"
if [[ "${stall_counter}" -eq 0 ]]; then
  : > "$(session_file "stall_paths.log")" 2>/dev/null || true
fi

if [[ ! -s "${paths_file}" ]]; then
  pass=$((pass + 1))
else
  printf '  FAIL: paths file should be empty after counter reset\n' >&2
  fail=$((fail + 1))
fi

# --- Test: agent delegation halves counter (not full reset) ---
printf '\nAgent delegation halving:\n'

write_state "stall_counter" "10"
# Simulate what reflect-after-agent.sh does: halve instead of reset
stall_counter="$(read_state "stall_counter")"
stall_counter="${stall_counter:-0}"
write_state "stall_counter" "$(( stall_counter / 2 ))"

result="$(read_state "stall_counter")"
assert_eq "counter halved from 10 to 5" "5" "${result}"

# Second halving
stall_counter="$(read_state "stall_counter")"
write_state "stall_counter" "$(( stall_counter / 2 ))"
result="$(read_state "stall_counter")"
assert_eq "counter halved from 5 to 2" "2" "${result}"

# Halving from 1 goes to 0
write_state "stall_counter" "1"
stall_counter="$(read_state "stall_counter")"
write_state "stall_counter" "$(( stall_counter / 2 ))"
result="$(read_state "stall_counter")"
assert_eq "counter halved from 1 to 0" "0" "${result}"

# Halving from 0 stays at 0
write_state "stall_counter" "0"
stall_counter="$(read_state "stall_counter")"
write_state "stall_counter" "$(( stall_counter / 2 ))"
result="$(read_state "stall_counter")"
assert_eq "counter stays 0 when already 0" "0" "${result}"

# Counter at threshold minus 1 should survive one halving
write_state "stall_counter" "11"
stall_counter="$(read_state "stall_counter")"
write_state "stall_counter" "$(( stall_counter / 2 ))"
result="$(read_state "stall_counter")"
assert_eq "11 halved to 5 (below threshold)" "5" "${result}"

printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
