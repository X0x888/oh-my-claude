#!/usr/bin/env bash
# test-auto-tune.sh — regression net for the opt-in `auto_tune` conf flag
# + session-start-auto-tune.sh (v1.48-pre).
#
# auto_tune is the harness's first self-modifying case: at most once per
# 7 days, it reuses show-report.sh's own objective-contract reprompt-rate
# signal (gate=objective-contract, event=block vs event=post-block-
# reprompt) to decide whether the gate looks like it is over-firing, and
# if the evidence clears a >=50% rate over >=10 blocks in the trailing
# 7-day window, raises `objective_contract_min_files` by exactly one
# step (clamped to [2,12]) via the existing atomic conf-write path
# (`omc-config.sh set user`). Off by default; deny-listed at
# project-conf scope because it rewrites the user's GLOBAL conf.
#
# Covers:
#   1. flag off (default)                          -> no-op, zero side effects
#   2. flag on + insufficient signal (<10 blocks)   -> no-op, reason in state file
#   3. flag on + sufficient rollup evidence          -> conf raised by exactly
#      1 step, audit row appended, other conf lines untouched
#   4. clamp respected at the ceiling (12) and at the disable sentinel (0)
#   5. 7-day cadence respected (second evaluation within the window is a no-op)
#   6. project-conf cannot enable it (deny-list); user-conf positive control

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-auto-tune.sh"

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
    printf '  FAIL: %s\n    needle=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    unwanted=%q\n    haystack=%q\n' "${label}" "${needle}" "${haystack:0:300}" >&2
    fail=$((fail + 1))
  fi
}

# Track every temp HOME created below so the EXIT trap cleans up even if
# an assertion aborts the script early (set -e). Mirrors
# test-repo-lessons.sh / test-stop-guard-bypass-surface.sh exactly.
declare -a _cleanup_dirs=()
_cleanup() {
  local d
  for d in ${_cleanup_dirs[@]+"${_cleanup_dirs[@]}"}; do
    rm -rf "${d}"
  done
}
trap _cleanup EXIT

# Fresh sandbox HOME with the real autowork/scripts tree (common.sh +
# omc-config.sh) symlinked in at the standard install path — mirrors
# test-watchdog-health.sh's setup exactly, since session-start-auto-tune.sh
# sources common.sh the same way session-start-watchdog-health.sh does.
new_sandbox_home() {
  local home="$1"
  mkdir -p "${home}/.claude/quality-pack" "${home}/.claude/skills"
  ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${home}/.claude/skills/autowork"
}

# Runs the hook with a given HOME + session_id, piping a minimal
# SessionStart payload on stdin. `-u`s any inherited auto_tune env var
# so the conf file (not a stray developer env export) is authoritative,
# matching test-stop-guard-bypass-surface.sh F-013's convention.
run_hook() {
  local home="$1" sid="$2"
  local input
  input="$(printf '{"session_id":"%s","source":"startup"}' "${sid}")"
  printf '%s' "${input}" \
    | env -u OMC_AUTO_TUNE HOME="${home}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
        bash "${HOOK}" 2>/dev/null \
    || true
}

# Writes N block-events and M reprompt-events for gate=objective-contract
# into the sandbox's gate_events.jsonl, all timestamped well within the
# trailing 7-day window (the hook's evidence-read window).
write_oc_events() {
  local home="$1" blocks="$2" reprompts="$3"
  local f="${home}/.claude/quality-pack/gate_events.jsonl"
  mkdir -p "$(dirname "${f}")"
  : > "${f}"
  local i now
  now="$(date +%s)"
  for ((i = 0; i < blocks; i++)); do
    printf '{"_v":1,"ts":%d,"host":"testhost","gate":"objective-contract","event":"block","details":{}}\n' \
      "$((now - i - 30))" >> "${f}"
  done
  for ((i = 0; i < reprompts; i++)); do
    printf '{"_v":1,"ts":%d,"host":"testhost","gate":"objective-contract","event":"post-block-reprompt","details":{}}\n' \
      "$((now - i - 15))" >> "${f}"
  done
}

read_conf_val() {
  local conf="$1" key="$2"
  grep -E "^${key}=" "${conf}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# ---------------------------------------------------------------------
printf 'Test 1: flag off (default) -> no-op, zero side effects\n'
_h1="$(mktemp -d)"; _cleanup_dirs+=("${_h1}")
new_sandbox_home "${_h1}"
write_oc_events "${_h1}" 12 8
out1="$(run_hook "${_h1}" "t1")"
assert_eq "T1: silent output" "" "${out1}"
if [[ -e "${_h1}/.claude/quality-pack/auto-tune-state.json" ]]; then
  printf '  FAIL: T1: auto-tune-state.json must not be created when auto_tune is off\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if [[ -e "${_h1}/.claude/quality-pack/auto-tune.jsonl" ]]; then
  printf '  FAIL: T1: auto-tune.jsonl must not be created when auto_tune is off\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 2: flag on + insufficient signal (<10 blocks) -> no-op with reason\n'
_h2="$(mktemp -d)"; _cleanup_dirs+=("${_h2}")
new_sandbox_home "${_h2}"
printf 'auto_tune=on\n' > "${_h2}/.claude/oh-my-claude.conf"
write_oc_events "${_h2}" 5 5
out2="$(run_hook "${_h2}" "t2")"
assert_eq "T2: silent output (no additionalContext emitted)" "" "${out2}"
_t2_state="${_h2}/.claude/quality-pack/auto-tune-state.json"
if [[ -f "${_t2_state}" ]]; then
  pass=$((pass + 1))
  _t2_applied="$(jq -r '.last_applied' "${_t2_state}" 2>/dev/null)"
  assert_eq "T2: last_applied is false" "false" "${_t2_applied}"
  _t2_reason="$(jq -r '.last_reason' "${_t2_state}" 2>/dev/null)"
  assert_contains "T2: reason names insufficient signal" "insufficient signal" "${_t2_reason}"
else
  printf '  FAIL: T2: auto-tune-state.json must be written even on a no-op check\n' >&2
  fail=$((fail + 1))
fi
if [[ -e "${_h2}/.claude/quality-pack/auto-tune.jsonl" ]]; then
  printf '  FAIL: T2: auto-tune.jsonl must not gain a row when signal is insufficient\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 3: flag on + sufficient rollup evidence -> raised by exactly 1 step, other conf lines untouched\n'
_h3="$(mktemp -d)"; _cleanup_dirs+=("${_h3}")
new_sandbox_home "${_h3}"
printf 'auto_tune=on\nstall_threshold=20\nobjective_contract_min_files=4\nexcellence_file_count=3\n' \
  > "${_h3}/.claude/oh-my-claude.conf"
write_oc_events "${_h3}" 12 8   # 8/12 = 66% >= 50% over-firing bar, >=10 blocks
out3="$(run_hook "${_h3}" "t3")"
assert_contains "T3: additionalContext announces the apply" "Auto-tune applied" "${out3}"
assert_contains "T3: additionalContext names the raise 4 -> 5" "4 -> 5" "${out3}"
assert_contains "T3: additionalContext carries the revert instruction" "auto_tune=off" "${out3}"

_t3_conf="${_h3}/.claude/oh-my-claude.conf"
assert_eq "T3: objective_contract_min_files raised to 5" "5" "$(read_conf_val "${_t3_conf}" objective_contract_min_files)"
assert_eq "T3: stall_threshold preserved byte-for-byte" "20" "$(read_conf_val "${_t3_conf}" stall_threshold)"
assert_eq "T3: excellence_file_count preserved byte-for-byte" "3" "$(read_conf_val "${_t3_conf}" excellence_file_count)"
assert_eq "T3: auto_tune line preserved" "on" "$(read_conf_val "${_t3_conf}" auto_tune)"
_t3_min_files_lines="$(grep -c '^objective_contract_min_files=' "${_t3_conf}")"
assert_eq "T3: exactly one objective_contract_min_files line (no duplicate)" "1" "${_t3_min_files_lines}"

_t3_ledger="${_h3}/.claude/quality-pack/auto-tune.jsonl"
if [[ -f "${_t3_ledger}" ]]; then
  pass=$((pass + 1))
  _t3_row="$(tail -1 "${_t3_ledger}")"
  assert_eq "T3: audit row flag" "objective_contract_min_files" "$(jq -r '.flag' <<<"${_t3_row}")"
  assert_eq "T3: audit row old=4" "4" "$(jq -r '.old' <<<"${_t3_row}")"
  assert_eq "T3: audit row new=5" "5" "$(jq -r '.new' <<<"${_t3_row}")"
  assert_contains "T3: audit row evidence names the reprompt rate" "reprompt_rate_pct=66" "$(jq -r '.evidence' <<<"${_t3_row}")"
  _t3_host="$(jq -r '.host' <<<"${_t3_row}")"
  if [[ -n "${_t3_host}" && "${_t3_host}" != "null" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T3: audit row must carry a non-empty host\n' >&2
    fail=$((fail + 1))
  fi
else
  printf '  FAIL: T3: auto-tune.jsonl audit row was not written\n' >&2
  fail=$((fail + 1))
fi
_t3_state="${_h3}/.claude/quality-pack/auto-tune-state.json"
assert_eq "T3: state file last_applied true" "true" "$(jq -r '.last_applied' "${_t3_state}" 2>/dev/null)"

# ---------------------------------------------------------------------
printf 'Test 4a: clamp at the ceiling (12) -> no further raise, no audit row\n'
_h4a="$(mktemp -d)"; _cleanup_dirs+=("${_h4a}")
new_sandbox_home "${_h4a}"
printf 'auto_tune=on\nobjective_contract_min_files=12\n' > "${_h4a}/.claude/oh-my-claude.conf"
write_oc_events "${_h4a}" 12 8
out4a="$(run_hook "${_h4a}" "t4a")"
assert_eq "T4a: silent (no additionalContext) at the ceiling" "" "${out4a}"
assert_eq "T4a: objective_contract_min_files stays 12" "12" "$(read_conf_val "${_h4a}/.claude/oh-my-claude.conf" objective_contract_min_files)"
if [[ -e "${_h4a}/.claude/quality-pack/auto-tune.jsonl" ]]; then
  printf '  FAIL: T4a: no audit row should be written when already at the ceiling\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "T4a: state reason mentions the ceiling" "ceiling" \
  "$(jq -r '.last_reason' "${_h4a}/.claude/quality-pack/auto-tune-state.json" 2>/dev/null)"

printf 'Test 4b: the documented volume-arm-disable sentinel (0) is left untouched\n'
_h4b="$(mktemp -d)"; _cleanup_dirs+=("${_h4b}")
new_sandbox_home "${_h4b}"
printf 'auto_tune=on\nobjective_contract_min_files=0\n' > "${_h4b}/.claude/oh-my-claude.conf"
write_oc_events "${_h4b}" 12 8
out4b="$(run_hook "${_h4b}" "t4b")"
assert_eq "T4b: silent (no additionalContext) at the disable sentinel" "" "${out4b}"
assert_eq "T4b: objective_contract_min_files stays 0" "0" "$(read_conf_val "${_h4b}/.claude/oh-my-claude.conf" objective_contract_min_files)"
if [[ -e "${_h4b}/.claude/quality-pack/auto-tune.jsonl" ]]; then
  printf '  FAIL: T4b: no audit row should be written when the volume arm is explicitly disabled\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
assert_contains "T4b: state reason names the managed range" "outside auto-tune's managed range" \
  "$(jq -r '.last_reason' "${_h4b}/.claude/quality-pack/auto-tune-state.json" 2>/dev/null)"

# ---------------------------------------------------------------------
printf 'Test 5: 7-day cadence — a second evaluation within the window is a no-op\n'
_h5="$(mktemp -d)"; _cleanup_dirs+=("${_h5}")
new_sandbox_home "${_h5}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' > "${_h5}/.claude/oh-my-claude.conf"
write_oc_events "${_h5}" 12 8
run_hook "${_h5}" "t5-first" >/dev/null
assert_eq "T5: first run raises to 5" "5" "$(read_conf_val "${_h5}/.claude/oh-my-claude.conf" objective_contract_min_files)"
_t5_ledger_count_after_first="$(wc -l < "${_h5}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
assert_eq "T5: exactly one audit row after the first run" "1" "${_t5_ledger_count_after_first}"

# Second run: DIFFERENT session_id (so the per-session auto_tune_checked
# guard cannot be the thing silencing it — this isolates the CROSS-session
# 7-day state file as the actual mechanism under test), same fresh
# evidence available. Cadence must still block the re-evaluation.
run_hook "${_h5}" "t5-second" >/dev/null
assert_eq "T5: second run within 7 days does not raise further (stays 5)" "5" "$(read_conf_val "${_h5}/.claude/oh-my-claude.conf" objective_contract_min_files)"
_t5_ledger_count_after_second="$(wc -l < "${_h5}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
assert_eq "T5: still exactly one audit row after the second (throttled) run" "1" "${_t5_ledger_count_after_second}"

# ---------------------------------------------------------------------
printf 'Test 6a: project-conf auto_tune=on is ignored (deny-list)\n'
_h6="$(mktemp -d)"; _cleanup_dirs+=("${_h6}")
mkdir -p "${_h6}/.claude/quality-pack" "${_h6}/.claude/skills" "${_h6}/repo/.claude"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${_h6}/.claude/skills/autowork"
printf 'objective_contract_min_files=4\n' > "${_h6}/.claude/oh-my-claude.conf"
printf 'auto_tune=on\n' > "${_h6}/repo/.claude/oh-my-claude.conf"
write_oc_events "${_h6}" 12 8
out6a="$(cd "${_h6}/repo" && printf '{"session_id":"t6a","source":"startup"}' \
  | env -u OMC_AUTO_TUNE HOME="${_h6}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
      bash "${HOOK}" 2>/dev/null || true)"
assert_eq "T6a: project-conf auto_tune=on must NOT enable self-tuning (deny-list bypass)" "" "${out6a}"
assert_eq "T6a: objective_contract_min_files untouched" "4" "$(read_conf_val "${_h6}/.claude/oh-my-claude.conf" objective_contract_min_files)"
if [[ -e "${_h6}/.claude/quality-pack/auto-tune-state.json" ]]; then
  printf '  FAIL: T6a: auto-tune-state.json must not be created when only project-conf sets auto_tune=on\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf 'Test 6b: user-level conf auto_tune=on works (positive control)\n'
rm -f "${_h6}/repo/.claude/oh-my-claude.conf"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' > "${_h6}/.claude/oh-my-claude.conf"
out6b="$(cd "${_h6}/repo" && printf '{"session_id":"t6b","source":"startup"}' \
  | env -u OMC_AUTO_TUNE HOME="${_h6}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
      bash "${HOOK}" 2>/dev/null || true)"
assert_contains "T6b: user-level conf auto_tune=on enables the apply" "Auto-tune applied" "${out6b}"
assert_eq "T6b: objective_contract_min_files raised to 5" "5" "$(read_conf_val "${_h6}/.claude/oh-my-claude.conf" objective_contract_min_files)"

# ---------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
