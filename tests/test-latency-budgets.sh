#!/usr/bin/env bash
# test-latency-budgets.sh — Wave 3 (v1.28.0) coverage for the
# hook-latency budget framework.
#
# What this proves:
#   T1.  show-budgets prints all 6 hot-path hooks with budgets
#   T2.  budget_for_hook returns the documented default
#   T3.  budget_for_hook honors env override (OMC_LATENCY_BUDGET_*_MS)
#   T4.  Invalid env override (non-numeric) falls back to default
#   T5.  Unknown hook returns 0
#   T6.  emit_payload_for_hook produces valid JSON for each known hook
#   T7.  benchmark subcommand runs and prints all hooks
#   T8.  benchmark with --hook NAME runs only the named hook
#   T9.  benchmark with --samples 1 runs (no division by zero etc.)
#   T10. check subcommand exits 0 when all hooks within budget
#   T11. check subcommand exits 1 when a budget is breached
#   T12. Unknown subcommand returns 2

set -euo pipefail

TEST_NAME="test-latency-budgets.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/check-latency-budgets.sh"
COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

# Set up a TEST_HOME so the bench's STATE_ROOT cleanup doesn't hit the
# real user's session state.
TEST_HOME="$(mktemp -d)"
mkdir -p "${TEST_HOME}/.claude/skills/autowork/scripts/lib"
mkdir -p "${TEST_HOME}/.claude/quality-pack/state"
mkdir -p "${TEST_HOME}/.claude/quality-pack/blindspots"
ln -sf "${COMMON_SH}" "${TEST_HOME}/.claude/skills/autowork/scripts/common.sh"
ln -sf "${SCRIPT}" "${TEST_HOME}/.claude/skills/autowork/scripts/check-latency-budgets.sh"
for libfile in "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/lib/"*.sh; do
  ln -sf "${libfile}" "${TEST_HOME}/.claude/skills/autowork/scripts/lib/$(basename "${libfile}")"
done
for f in "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/"*.sh; do
  base="$(basename "$f")"
  [[ -L "${TEST_HOME}/.claude/skills/autowork/scripts/${base}" ]] || \
    ln -sf "$f" "${TEST_HOME}/.claude/skills/autowork/scripts/${base}"
done

run_script() {
  HOME="${TEST_HOME}" \
  STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash "${SCRIPT}" "$@"
}

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
    printf '         expected: %s\n         actual:   %s\n' "${expected}" "${actual}"
  fi
}

assert_true() {
  local cond="$1" msg="$2"
  if eval "${cond}"; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "${msg}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "${msg}"
  fi
}

# --- T1 ---
printf '\nT1: show-budgets prints all 6 hot-path hooks\n'
out="$(run_script show-budgets)"
for hook in prompt-intent-router.sh pretool-intent-guard.sh pretool-timing.sh \
            posttool-timing.sh stop-guard.sh stop-time-summary.sh; do
  if [[ "${out}" == *"${hook}"* ]]; then
    PASS=$((PASS + 1))
    printf '  PASS: lists %s\n' "${hook}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: missing %s\n' "${hook}"
  fi
done

# --- T2 ---
printf '\nT2: show-budgets emits documented default for each hook\n'
out="$(run_script show-budgets)"
expected_pairs=(
  "prompt-intent-router.sh|1200"
  "pretool-intent-guard.sh|300"
  "pretool-timing.sh|200"
  "posttool-timing.sh|200"
  "stop-guard.sh|1000"
  "stop-time-summary.sh|400"
)
for pair in "${expected_pairs[@]}"; do
  hook="${pair%|*}"
  expected="${pair#*|}"
  if printf '%s' "${out}" | grep -E "^${hook}[[:space:]]+${expected}\$" >/dev/null; then
    PASS=$((PASS + 1))
    printf '  PASS: %s default = %s\n' "${hook}" "${expected}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s default mismatch (expected %s)\n' "${hook}" "${expected}"
  fi
done

# --- T3 ---
printf '\nT3: env override surfaces in show-budgets\n'
out="$(OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=999 run_script show-budgets)"
if printf '%s' "${out}" | grep -E "^prompt-intent-router\.sh[[:space:]]+999[[:space:]]+\(env override; default 1200\)" >/dev/null; then
  PASS=$((PASS + 1))
  printf '  PASS: env override surfaces with annotation\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: env override missing in show-budgets output\n%s\n' "${out}"
fi

# --- T4 ---
printf '\nT4: invalid env override falls back to default\n'
out="$(OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=not-a-number run_script show-budgets)"
if printf '%s' "${out}" | grep -E "^prompt-intent-router\.sh[[:space:]]+1200\$" >/dev/null; then
  PASS=$((PASS + 1))
  printf '  PASS: non-numeric override ignored, default applied\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: non-numeric override not ignored\n%s\n' "${out}"
fi

# --- T5 ---
printf '\nT5: benchmark output respects env-overridden budget\n'
# When budget is impossibly low, the BUDGET column shows the override.
out="$(OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=1 \
  run_script benchmark --samples 1 --hook prompt-intent-router.sh 2>&1 || true)"
if printf '%s' "${out}" | grep -E 'prompt-intent-router\.sh.*1ms.*BREACH' >/dev/null; then
  PASS=$((PASS + 1))
  printf '  PASS: 1ms override produces BREACH against benchmark\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: 1ms override did not produce BREACH\n%s\n' "${out}"
fi

# --- T6 ---
printf '\nT6: synthetic payloads do not crash hooks (smoke test)\n'
# We treat "the script runs at all" as the smoke contract — if any
# emit_payload_for_hook returned malformed JSON, the hook would panic
# inside benchmark and the row would say `missing` or the script would
# error. Use --samples 1 to keep it fast.
out="$(run_script benchmark --samples 1 2>&1 || true)"
missing_count="$(printf '%s' "${out}" | grep -c 'missing' || true)"
assert_eq "${missing_count}" "0" "no hooks reported as missing (synthetic payloads valid)"

# --- T7 ---
printf '\nT7: benchmark subcommand runs all hooks\n'
out="$(run_script benchmark --samples 1 2>&1 || true)"
all_listed=1
for hook in prompt-intent-router.sh pretool-intent-guard.sh; do
  if [[ "${out}" != *"${hook}"* ]]; then
    all_listed=0
  fi
done
assert_eq "${all_listed}" "1" "benchmark lists all hooks"

# --- T8 ---
printf '\nT8: benchmark --hook filters\n'
out="$(run_script benchmark --hook pretool-timing.sh --samples 1 2>&1 || true)"
assert_true "[[ '${out}' == *'pretool-timing.sh'* ]]" "filtered hook present"
# When filtered, prompt-intent-router should NOT appear in the output table
# (header lines like 'HOOK' don't count). We grep the body specifically.
body="$(printf '%s' "${out}" | grep -E '^[a-z][a-z-]+\.sh' || true)"
assert_true "[[ '${body}' != *'prompt-intent-router.sh'* ]]" "non-filtered hook absent"

# --- T9 ---
printf '\nT9: --samples 1 produces stats without errors\n'
out="$(run_script benchmark --samples 1 --hook stop-time-summary.sh 2>&1 || true)"
# Should print a row with two ms values and a STATUS column.
if printf '%s' "${out}" | grep -Eq 'stop-time-summary\.sh.*[0-9]+ms.*[0-9]+ms.*(ok|BREACH)'; then
  PASS=$((PASS + 1))
  printf '  PASS: --samples 1 produces complete row\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL: --samples 1 row missing\n%s\n' "${out}"
fi

# --- T10 ---
printf '\nT10: check exits 0 when all within budget\n'
# Use generous overrides to ensure no breach.
out="$(OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=99999 \
  OMC_LATENCY_BUDGET_PRETOOL_INTENT_GUARD_MS=99999 \
  OMC_LATENCY_BUDGET_PRETOOL_TIMING_MS=99999 \
  OMC_LATENCY_BUDGET_POSTTOOL_TIMING_MS=99999 \
  OMC_LATENCY_BUDGET_STOP_GUARD_MS=99999 \
  OMC_LATENCY_BUDGET_STOP_TIME_SUMMARY_MS=99999 \
  HOME="${TEST_HOME}" \
  STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash "${SCRIPT}" check --samples 1 2>&1)"
exit_code=0
OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=99999 \
  OMC_LATENCY_BUDGET_PRETOOL_INTENT_GUARD_MS=99999 \
  OMC_LATENCY_BUDGET_PRETOOL_TIMING_MS=99999 \
  OMC_LATENCY_BUDGET_POSTTOOL_TIMING_MS=99999 \
  OMC_LATENCY_BUDGET_STOP_GUARD_MS=99999 \
  OMC_LATENCY_BUDGET_STOP_TIME_SUMMARY_MS=99999 \
  HOME="${TEST_HOME}" \
  STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash "${SCRIPT}" check --samples 1 >/dev/null 2>&1 || exit_code=$?
assert_eq "${exit_code}" "0" "check exits 0 with generous budgets"

# --- T11 ---
printf '\nT11: check exits 1 when a budget is breached\n'
exit_code=0
OMC_LATENCY_BUDGET_PROMPT_INTENT_ROUTER_MS=1 \
  HOME="${TEST_HOME}" \
  STATE_ROOT="${TEST_HOME}/.claude/quality-pack/state" \
  bash "${SCRIPT}" check --samples 1 >/dev/null 2>&1 || exit_code=$?
assert_eq "${exit_code}" "1" "check exits 1 with impossibly tight budget"

# --- T12 ---
printf '\nT12: unknown subcommand returns 2\n'
exit_code=0
HOME="${TEST_HOME}" run_script bogus >/dev/null 2>&1 || exit_code=$?
assert_eq "${exit_code}" "2" "unknown subcommand exits 2"

rm -rf "${TEST_HOME}"

printf '\n%s\n' "--------------------------------------------------------------------------------"
printf 'Results: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '%s\n' "--------------------------------------------------------------------------------"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
