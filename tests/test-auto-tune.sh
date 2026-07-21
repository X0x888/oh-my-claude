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
#   7. threshold reread uses trimmed last-valid canonical decimal semantics

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
run_hook_raw() {
  local home="$1" sid="$2"
  shift 2
  local input
  input="$(printf '{"session_id":"%s","source":"startup"}' "${sid}")"
  printf '%s' "${input}" \
    | env -u OMC_AUTO_TUNE -u OMC_OBJECTIVE_CONTRACT_MIN_FILES \
        HOME="${home}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
        "$@" bash "${HOOK}" 2>/dev/null
}

run_hook() {
  run_hook_raw "$@" || true
}

# Writes N block-events and M reprompt-events for gate=objective-contract
# into the sandbox's gate_events.jsonl, all timestamped well within the
# trailing 7-day window (the hook's evidence-read window).
write_oc_events() {
  local home="$1" blocks="$2" reprompts="$3"
  local f="${home}/.claude/quality-pack/gate_events.jsonl"
  write_oc_events_file "${f}" "${blocks}" "${reprompts}"
}

write_oc_events_file() {
  local f="$1" blocks="$2" reprompts="$3" host="${4:-testhost}"
  local event_session="${5:-${host}}"
  mkdir -p "$(dirname "${f}")"
  : > "${f}"
  local i now
  now="$(date +%s)"
  for ((i = 0; i < blocks; i++)); do
    printf '{"_v":1,"event_id":"ge:%s:%d","ts":%d,"host":"%s","gate":"objective-contract","event":"block","details":{}}\n' \
      "${event_session}" "$((i + 1))" "$((now - i - 30))" "${host}" >> "${f}"
  done
  for ((i = 0; i < reprompts; i++)); do
    printf '{"_v":1,"event_id":"ge:%s:%d","ts":%d,"host":"%s","gate":"objective-contract","event":"post-block-reprompt","details":{}}\n' \
      "${event_session}" "$((blocks + i + 1))" "$((now - i - 15))" "${host}" >> "${f}"
  done
}

write_live_oc_events() {
  local home="$1" sid="$2" blocks="$3" reprompts="$4"
  local host="${5:-testhost}"
  local dir="${home}/.claude/quality-pack/state/${sid}"
  mkdir -p "${dir}"
  chmod 700 "${home}/.claude/quality-pack/state" "${dir}"
  printf '{"session_start_ts":%s}\n' "$(date +%s)" \
    > "${dir}/session_state.json"
  chmod 600 "${dir}/session_state.json"
  write_oc_events_file "${dir}/gate_events.jsonl" \
    "${blocks}" "${reprompts}" "${host}" "${sid}"
  chmod 600 "${dir}/gate_events.jsonl"
}

read_conf_val() {
  local conf="$1" key="$2"
  grep -E "^${key}=" "${conf}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

wait_for_path() {
  local path="$1" attempt=0
  while [[ ! -e "${path}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 1000 ]] || return 1
    sleep 0.01
  done
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

file_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null \
    || stat -f '%d:%i' "$1" 2>/dev/null
}

file_link_count() {
  stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1" 2>/dev/null
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
  | env -u OMC_AUTO_TUNE -u OMC_OBJECTIVE_CONTRACT_MIN_FILES \
      HOME="${_h6}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
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
  | env -u OMC_AUTO_TUNE -u OMC_OBJECTIVE_CONTRACT_MIN_FILES \
      HOME="${_h6}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
      bash "${HOOK}" 2>/dev/null || true)"
assert_contains "T6b: user-level conf auto_tune=on enables the apply" "Auto-tune applied" "${out6b}"
assert_eq "T6b: objective_contract_min_files raised to 5" "5" "$(read_conf_val "${_h6}/.claude/oh-my-claude.conf" objective_contract_min_files)"

# ---------------------------------------------------------------------
printf 'Test 7: malformed later numeric duplicates cannot reach arithmetic or erase the last valid threshold\n'
_h7="$(mktemp -d)"; _cleanup_dirs+=("${_h7}")
new_sandbox_home "${_h7}"
printf 'auto_tune=on\nobjective_contract_min_files= 4 \nobjective_contract_min_files=08\nobjective_contract_min_files=999999999999999999999999999999\n' \
  > "${_h7}/.claude/oh-my-claude.conf"
write_oc_events "${_h7}" 12 8
out7="$(run_hook "${_h7}" "t7")"
assert_contains "T7: last valid canonical threshold remains authoritative" \
  "Auto-tune applied" "${out7}"
assert_eq "T7: auto-tune raises retained threshold 4 to 5" "5" \
  "$(read_conf_val "${_h7}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T7: successful writer deduplicates malformed threshold rows" "1" \
  "$(grep -c '^objective_contract_min_files=' "${_h7}/.claude/oh-my-claude.conf")"

# ---------------------------------------------------------------------
printf 'Test 8: concurrent sessions serialize one decision and one audit row\n'
_h8="$(mktemp -d)"; _cleanup_dirs+=("${_h8}")
new_sandbox_home "${_h8}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h8}/.claude/oh-my-claude.conf"
write_oc_events "${_h8}" 12 8
set +e
run_hook_raw "${_h8}" "t8-a" > "${_h8}/out-a" & _p8a=$!
run_hook_raw "${_h8}" "t8-b" > "${_h8}/out-b" & _p8b=$!
wait "${_p8a}"; _r8a=$?
wait "${_p8b}"; _r8b=$?
set -e
assert_eq "T8: first concurrent hook exits cleanly" "0" "${_r8a}"
assert_eq "T8: second concurrent hook exits cleanly" "0" "${_r8b}"
assert_eq "T8: concurrent hooks raise exactly once" "5" \
  "$(read_conf_val "${_h8}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T8: concurrent hooks append one audit row" "1" \
  "$(wc -l < "${_h8}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
assert_eq "T8: audit row carries schema version" "1" \
  "$(jq -r '._v' "${_h8}/.claude/quality-pack/auto-tune.jsonl")"
assert_eq "T8: normal completion removes shared mutation lock" "no" \
  "$([[ -e "${_h8}/.claude/.install.lock" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 9: prepared receipt never attributes an unrelated same-value generation\n'
_h9="$(mktemp -d)"; _cleanup_dirs+=("${_h9}")
new_sandbox_home "${_h9}"
printf 'auto_tune=on\nkeep=original\nobjective_contract_min_files=4\n' \
  > "${_h9}/.claude/oh-my-claude.conf"
write_oc_events "${_h9}" 12 8
set +e
run_hook_raw "${_h9}" "t9-crash" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT=1 >/dev/null
_r9=$?
set -e
assert_eq "T9: receipt failpoint exits at the crash seam" "75" "${_r9}"
assert_eq "T9: prepared receipt precedes config mutation" "4" \
  "$(read_conf_val "${_h9}/.claude/oh-my-claude.conf" objective_contract_min_files)"
# An independent serialized writer can produce the byte-exact deterministic
# final generation. Matching those bytes must not let recovery invent evidence
# that this auto-tune parent observed its own child publication.
HOME="${_h9}" bash \
  "${_h9}/.claude/skills/autowork/scripts/omc-config.sh" \
  set user objective_contract_min_files=5 >/dev/null
_expected_final9="$(jq -r '.final_digest' \
  "${_h9}/.claude/quality-pack/auto-tune-pending.json")"
_actual_final9="cksum:$(cksum < "${_h9}/.claude/oh-my-claude.conf")"
assert_eq "T9: independent writer reproduced the exact intended bytes" \
  "${_expected_final9}" "${_actual_final9}"
run_hook "${_h9}" "t9-recover" >/dev/null
assert_eq "T9: ambiguous same-value generation retains receipt" "yes" \
  "$([[ -f "${_h9}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"
assert_eq "T9: ambiguous same-value generation is not audited" "no" \
  "$([[ -e "${_h9}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 10: kill before writer observation stays quarantined as prepared\n'
_h10="$(mktemp -d)"; _cleanup_dirs+=("${_h10}")
new_sandbox_home "${_h10}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h10}/.claude/oh-my-claude.conf"
write_oc_events "${_h10}" 12 8
set +e
run_hook_raw "${_h10}" "t10-child" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_CHILD=1 >/dev/null
_r10a=$?
set -e
assert_eq "T10: child-publication seam exits nonzero" "75" "${_r10a}"
assert_eq "T10: unobserved child result remains prepared" "prepared" \
  "$(jq -r '.phase' "${_h10}/.claude/quality-pack/auto-tune-pending.json")"
run_hook "${_h10}" "t10-final" >/dev/null
assert_eq "T10: exact final bytes remain untouched" "5" \
  "$(read_conf_val "${_h10}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T10: ambiguous recovery retains pending receipt" "yes" \
  "$([[ -e "${_h10}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"
assert_eq "T10: ambiguous recovery publishes no audit" "no" \
  "$([[ -e "${_h10}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"
assert_eq "T10: ambiguous recovery publishes no cadence" "no" \
  "$([[ -e "${_h10}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 11: an applied pending decision settles even after auto_tune is disabled\n'
_h11="$(mktemp -d)"; _cleanup_dirs+=("${_h11}")
new_sandbox_home "${_h11}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h11}/.claude/oh-my-claude.conf"
write_oc_events "${_h11}" 12 8
set +e
run_hook_raw "${_h11}" "t11-crash" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_CONF=1 >/dev/null
_r11=$?
set -e
assert_eq "T11: post-conf seam exits nonzero" "75" "${_r11}"
printf 'auto_tune=off\n' >> "${_h11}/.claude/oh-my-claude.conf"
out11="$(run_hook "${_h11}" "t11-disabled-recovery")"
assert_contains "T11: disabled recovery announces only the prior application" \
  "Auto-tune applied (recovered)" "${out11}"
assert_eq "T11: disabled recovery does not increment again" "5" \
  "$(read_conf_val "${_h11}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T11: disabled recovery publishes one audit row" "1" \
  "$(wc -l < "${_h11}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
assert_eq "T11: disabled recovery clears pending" "no" \
  "$([[ -e "${_h11}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 12: post-audit and post-state crashes deduplicate exactly\n'
for _phase12 in AUDIT STATE; do
  _h12="$(mktemp -d)"; _cleanup_dirs+=("${_h12}")
  new_sandbox_home "${_h12}"
  printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
    > "${_h12}/.claude/oh-my-claude.conf"
  write_oc_events "${_h12}" 12 8
  set +e
  run_hook_raw "${_h12}" "t12-${_phase12}" \
    "OMC_TEST_AUTO_TUNE_FAIL_AFTER_${_phase12}=1" >/dev/null
  _r12=$?
  set -e
  assert_eq "T12 ${_phase12}: failpoint exits nonzero" "75" "${_r12}"
  run_hook "${_h12}" "t12-${_phase12}-recover" >/dev/null
  assert_eq "T12 ${_phase12}: one audit row after recovery" "1" \
    "$(wc -l < "${_h12}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
  assert_eq "T12 ${_phase12}: pending removed after recovery" "no" \
    "$([[ -e "${_h12}/.claude/quality-pack/auto-tune-pending.json" ]] \
      && printf yes || printf no)"
done

# ---------------------------------------------------------------------
printf 'Test 13: unsafe and partial control artifacts fail closed\n'
_h13a="$(mktemp -d)"; _cleanup_dirs+=("${_h13a}")
new_sandbox_home "${_h13a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13a}/.claude/oh-my-claude.conf"
write_oc_events "${_h13a}" 12 8
printf '{"victim":true}\n' > "${_h13a}/victim"
chmod 640 "${_h13a}/victim"
ln "${_h13a}/victim" "${_h13a}/.claude/quality-pack/auto-tune.jsonl"
_victim_before="$(cksum < "${_h13a}/victim")"
run_hook "${_h13a}" "t13-hardlink" >/dev/null
assert_eq "T13: hardlinked audit target does not change victim bytes" \
  "${_victim_before}" "$(cksum < "${_h13a}/victim")"
assert_eq "T13: hardlinked audit target does not chmod victim" "640" \
  "$(file_mode "${_h13a}/victim")"
assert_eq "T13: hardlinked audit blocks config mutation" "4" \
  "$(read_conf_val "${_h13a}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h13b="$(mktemp -d)"; _cleanup_dirs+=("${_h13b}")
new_sandbox_home "${_h13b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13b}/.claude/oh-my-claude.conf"
write_oc_events "${_h13b}" 12 8
set +e
run_hook_raw "${_h13b}" "t13-partial-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_CONF=1 >/dev/null
set -e
printf '{"_v":1' > "${_h13b}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13b}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13b}" "t13-partial-recover" >/dev/null
assert_eq "T13: partial audit tail retains durable receipt" "yes" \
  "$([[ -f "${_h13b}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"
assert_eq "T13: partial audit tail does not publish cadence" "no" \
  "$([[ -e "${_h13b}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

_h13c="$(mktemp -d)"; _cleanup_dirs+=("${_h13c}")
new_sandbox_home "${_h13c}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13c}/.claude/oh-my-claude.conf"
write_oc_events "${_h13c}" 12 8
set +e
run_hook_raw "${_h13c}" "t13-collision-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_CONF=1 >/dev/null
set -e
_id13="$(jq -r '.decision_id' \
  "${_h13c}/.claude/quality-pack/auto-tune-pending.json")"
jq -nc --arg id "${_id13}" \
  '{_v:1,decision_id:$id,ts:1,flag:"objective_contract_min_files",
    old:2,new:3,evidence:"conflicting",host:"test"}' \
  > "${_h13c}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13c}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13c}" "t13-collision-recover" >/dev/null
assert_eq "T13: mismatched same-ID audit row retains receipt" "yes" \
  "$([[ -f "${_h13c}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"
assert_eq "T13: mismatched same-ID row is not duplicated" "1" \
  "$(wc -l < "${_h13c}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"

_h13d="$(mktemp -d)"; _cleanup_dirs+=("${_h13d}")
new_sandbox_home "${_h13d}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13d}/.claude/oh-my-claude.conf"
write_oc_events "${_h13d}" 12 8
set +e
run_hook_raw "${_h13d}" "t13-forged-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT=1 >/dev/null
set -e
jq '.oc_pct = 49' \
  "${_h13d}/.claude/quality-pack/auto-tune-pending.json" \
  > "${_h13d}/forged-pending"
mv "${_h13d}/forged-pending" \
  "${_h13d}/.claude/quality-pack/auto-tune-pending.json"
chmod 600 "${_h13d}/.claude/quality-pack/auto-tune-pending.json"
run_hook "${_h13d}" "t13-forged-recover" >/dev/null
assert_eq "T13: below-threshold forged receipt cannot mutate config" "4" \
  "$(read_conf_val "${_h13d}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: below-threshold forged receipt is retained" "yes" \
  "$([[ -f "${_h13d}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

_h13e="$(mktemp -d)"; _cleanup_dirs+=("${_h13e}")
new_sandbox_home "${_h13e}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13e}/.claude/oh-my-claude.conf"
write_oc_events "${_h13e}" 12 8
set +e
run_hook_raw "${_h13e}" "t13-extra-pending-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT=1 >/dev/null
set -e
jq '.unexpected = true' \
  "${_h13e}/.claude/quality-pack/auto-tune-pending.json" \
  > "${_h13e}/pending-extra"
mv "${_h13e}/pending-extra" \
  "${_h13e}/.claude/quality-pack/auto-tune-pending.json"
chmod 600 "${_h13e}/.claude/quality-pack/auto-tune-pending.json"
run_hook "${_h13e}" "t13-extra-pending-recover" >/dev/null
assert_eq "T13: extra pending key fails closed before mutation" "4" \
  "$(read_conf_val "${_h13e}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: malformed pending receipt remains quarantined" "yes" \
  "$([[ -f "${_h13e}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

_h13f="$(mktemp -d)"; _cleanup_dirs+=("${_h13f}")
new_sandbox_home "${_h13f}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13f}/.claude/oh-my-claude.conf"
write_oc_events "${_h13f}" 12 8
set +e
run_hook_raw "${_h13f}" "t13-oversized-pending-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT=1 >/dev/null
set -e
head -c 40000 /dev/zero | tr '\0' ' ' \
  >> "${_h13f}/.claude/quality-pack/auto-tune-pending.json"
printf '\n' >> "${_h13f}/.claude/quality-pack/auto-tune-pending.json"
run_hook "${_h13f}" "t13-oversized-pending-recover" >/dev/null
assert_eq "T13: oversized but parseable pending receipt fails closed" "4" \
  "$(read_conf_val "${_h13f}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: oversized pending receipt is retained" "yes" \
  "$([[ -f "${_h13f}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

_h13g="$(mktemp -d)"; _cleanup_dirs+=("${_h13g}")
new_sandbox_home "${_h13g}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13g}/.claude/oh-my-claude.conf"
write_oc_events "${_h13g}" 12 8
printf '{"_v":1,"last_check_ts":0,"last_reason":"legacy",' \
  > "${_h13g}/.claude/quality-pack/auto-tune-state.json"
printf '"last_applied":false,"unexpected":true}\n' \
  >> "${_h13g}/.claude/quality-pack/auto-tune-state.json"
chmod 600 "${_h13g}/.claude/quality-pack/auto-tune-state.json"
run_hook "${_h13g}" "t13-extra-state" >/dev/null
assert_eq "T13: extra cadence key fails closed" "4" \
  "$(read_conf_val "${_h13g}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h13h="$(mktemp -d)"; _cleanup_dirs+=("${_h13h}")
new_sandbox_home "${_h13h}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13h}/.claude/oh-my-claude.conf"
write_oc_events "${_h13h}" 12 8
jq -nc --argjson ts "$(date +%s)" \
  '{_v:1,decision_id:("auto-tune-"+($ts|tostring)+"-1-1-1"),ts:$ts,
    flag:"objective_contract_min_files",old:4,new:5,evidence:"legacy",
    host:"testhost",unexpected:true}' \
  > "${_h13h}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13h}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13h}" "t13-extra-audit" >/dev/null
assert_eq "T13: extra audit key blocks mutation before it starts" "4" \
  "$(read_conf_val "${_h13h}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: invalid audit creates no pending receipt" "no" \
  "$([[ -e "${_h13h}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

_h13i="$(mktemp -d)"; _cleanup_dirs+=("${_h13i}")
new_sandbox_home "${_h13i}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13i}/.claude/oh-my-claude.conf"
write_oc_events "${_h13i}" 12 8
jq -nc --argjson ts "$(date +%s)" \
  '{_v:1,decision_id:("auto-tune-"+($ts|tostring)+"-1-1-1"),ts:$ts,
    flag:"objective_contract_min_files",old:4,new:5,evidence:"legacy",
    host:"testhost"}' \
  > "${_h13i}/.claude/quality-pack/auto-tune.jsonl"
head -c 4200000 /dev/zero | tr '\0' ' ' \
  >> "${_h13i}/.claude/quality-pack/auto-tune.jsonl"
printf '\n' >> "${_h13i}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13i}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13i}" "t13-oversized-audit" >/dev/null
assert_eq "T13: oversized parseable audit blocks mutation" "4" \
  "$(read_conf_val "${_h13i}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h13j="$(mktemp -d)"; _cleanup_dirs+=("${_h13j}")
new_sandbox_home "${_h13j}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13j}/.claude/oh-my-claude.conf"
write_oc_events "${_h13j}" 12 8
printf '%s\n' \
  '{"last_check_ts":0,"last_reason":"legacy","last_applied":false}' \
  > "${_h13j}/.claude/quality-pack/auto-tune-state.json"
_legacy_line13j='{"ts":1,"flag":"objective_contract_min_files","old":3,"new":4,"evidence":"legacy","host":"testhost"}'
printf '%s\n' "${_legacy_line13j}" \
  > "${_h13j}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13j}/.claude/quality-pack/auto-tune-state.json"
chmod 644 "${_h13j}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13j}" "t13-exact-legacy" >/dev/null
assert_eq "T13: exact documented legacy controls remain accepted" "5" \
  "$(read_conf_val "${_h13j}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: current audit appends after one exact legacy row" "2" \
  "$(wc -l < "${_h13j}/.claude/quality-pack/auto-tune.jsonl" \
    | tr -d '[:space:]')"
assert_eq "T13: historical 0644 audit is replaced by a private generation" \
  "600" "$(file_mode "${_h13j}/.claude/quality-pack/auto-tune.jsonl")"
assert_eq "T13: historical six-key row remains byte-identical" \
  "${_legacy_line13j}" \
  "$(head -n 1 "${_h13j}/.claude/quality-pack/auto-tune.jsonl")"

_h13k="$(mktemp -d)"; _cleanup_dirs+=("${_h13k}")
new_sandbox_home "${_h13k}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13k}/.claude/oh-my-claude.conf"
write_oc_events "${_h13k}" 12 8
printf '%s\n' "${_legacy_line13j}" \
  > "${_h13k}/.claude/quality-pack/auto-tune.jsonl"
chmod 666 "${_h13k}/.claude/quality-pack/auto-tune.jsonl"
run_hook "${_h13k}" "t13-writable-legacy" >/dev/null
assert_eq "T13: group/world-writable legacy audit is not trusted" "4" \
  "$(read_conf_val "${_h13k}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: unsafe legacy audit mode is not laundered" "666" \
  "$(file_mode "${_h13k}/.claude/quality-pack/auto-tune.jsonl")"

_h13l="$(mktemp -d)"; _cleanup_dirs+=("${_h13l}")
mkdir -p "${_h13l}/.claude/skills" "${_h13l}/redirected-quality-pack"
ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" \
  "${_h13l}/.claude/skills/autowork"
ln -s "${_h13l}/redirected-quality-pack" \
  "${_h13l}/.claude/quality-pack"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13l}/.claude/oh-my-claude.conf"
write_oc_events_file \
  "${_h13l}/redirected-quality-pack/gate_events.jsonl" 12 8
run_hook "${_h13l}" "t13-symlinked-root" >/dev/null
assert_eq "T13: symlinked quality-pack root cannot authorize mutation" "4" \
  "$(read_conf_val "${_h13l}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: symlinked root receives no auto-tune control artifacts" "0" \
  "$(find "${_h13l}/redirected-quality-pack" -maxdepth 1 \
    \( -name 'auto-tune.jsonl' -o -name 'auto-tune-state.json' \
       -o -name 'auto-tune-pending.json' \) -print | wc -l \
    | tr -d '[:space:]')"

_h13m="$(mktemp -d)"; _cleanup_dirs+=("${_h13m}")
new_sandbox_home "${_h13m}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h13m}/.claude/oh-my-claude.conf"
write_oc_events "${_h13m}" 12 8
_evidence13m="$(printf '%1024s' '' | tr ' ' a)"
_host13m="$(printf '%512s' '' | tr ' ' h)"
_row13m="$(jq -nc --arg evidence "${_evidence13m}" --arg host "${_host13m}" \
  '{ts:1,flag:"objective_contract_min_files",old:3,new:4,
    evidence:$evidence,host:$host}')"
_row_bytes13m="$(LC_ALL=C printf '%s\n' "${_row13m}" | wc -c \
  | tr -d '[:space:]')"
_repeat13m=$((4194304 / _row_bytes13m - 1))
: > "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
for ((_i13m = 0; _i13m < _repeat13m; _i13m++)); do
  printf '%s\n' "${_row13m}" \
    >> "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
done
_size13m="$(wc -c < "${_h13m}/.claude/quality-pack/auto-tune.jsonl" \
  | tr -d '[:space:]')"
_padding13m=$((4194304 - _size13m - _row_bytes13m))
printf '%s' "${_row13m}" \
  >> "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
head -c "${_padding13m}" /dev/zero | tr '\0' ' ' \
  >> "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
printf '\n' >> "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h13m}/.claude/quality-pack/auto-tune.jsonl"
_audit_digest13m="$(cksum \
  < "${_h13m}/.claude/quality-pack/auto-tune.jsonl")"
run_hook "${_h13m}" "t13-audit-capacity" >/dev/null
assert_eq "T13: full valid audit blocks before config mutation" "4" \
  "$(read_conf_val "${_h13m}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T13: full valid audit remains byte-identical" \
  "${_audit_digest13m}" \
  "$(cksum < "${_h13m}/.claude/quality-pack/auto-tune.jsonl")"
assert_eq "T13: capacity failure publishes no pending receipt" "no" \
  "$([[ -e "${_h13m}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 14: future/noncanonical evidence and corrupt cadence never tune\n'
_h14a="$(mktemp -d)"; _cleanup_dirs+=("${_h14a}")
new_sandbox_home "${_h14a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14a}/.claude/oh-my-claude.conf"
_future14="$(( $(date +%s) + 86400 ))"
for ((_i14 = 0; _i14 < 12; _i14++)); do
  printf '{"event_id":"ge:t14-future:%d","ts":%s,"gate":"objective-contract","event":"block"}\n' \
    "$((_i14 + 1))" "${_future14}" >> "${_h14a}/.claude/quality-pack/gate_events.jsonl"
done
for ((_i14 = 0; _i14 < 8; _i14++)); do
  printf '{"event_id":"ge:t14-future:%d","ts":"%s","gate":"objective-contract","event":"post-block-reprompt"}\n' \
    "$((_i14 + 13))" "${_future14}" >> "${_h14a}/.claude/quality-pack/gate_events.jsonl"
done
run_hook "${_h14a}" "t14-future" >/dev/null
assert_eq "T14: future/string evidence does not tune" "4" \
  "$(read_conf_val "${_h14a}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T14: future/string evidence creates no audit" "no" \
  "$([[ -e "${_h14a}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

_h14b="$(mktemp -d)"; _cleanup_dirs+=("${_h14b}")
new_sandbox_home "${_h14b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14b}/.claude/oh-my-claude.conf"
write_oc_events "${_h14b}" 12 8
printf '{"_v":1,"last_check_ts":9999999999,"last_reason":"future","last_applied":false}\n' \
  > "${_h14b}/.claude/quality-pack/auto-tune-state.json"
chmod 600 "${_h14b}/.claude/quality-pack/auto-tune-state.json"
run_hook "${_h14b}" "t14-cadence" >/dev/null
assert_eq "T14: future cadence fails closed" "4" \
  "$(read_conf_val "${_h14b}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h14bn="$(mktemp -d)"; _cleanup_dirs+=("${_h14bn}")
new_sandbox_home "${_h14bn}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14bn}/.claude/oh-my-claude.conf"
write_oc_events "${_h14bn}" 12 8
printf '{"_v":1,"last_check_ts":1\000,"last_reason":"poison","last_applied":false}\n' \
  > "${_h14bn}/.claude/quality-pack/auto-tune-state.json"
chmod 600 "${_h14bn}/.claude/quality-pack/auto-tune-state.json"
_raw_cadence_before="$(cksum \
  < "${_h14bn}/.claude/quality-pack/auto-tune-state.json")"
run_hook "${_h14bn}" "t14-raw-nul-cadence" >/dev/null
assert_eq "T14: raw-NUL cadence cannot authorize a tune" "4" \
  "$(read_conf_val "${_h14bn}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T14: raw-NUL cadence remains byte-identical" \
  "${_raw_cadence_before}" \
  "$(cksum < "${_h14bn}/.claude/quality-pack/auto-tune-state.json")"
assert_eq "T14: raw-NUL cadence creates no audit" "no" \
  "$([[ -e "${_h14bn}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

_h14c="$(mktemp -d)"; _cleanup_dirs+=("${_h14c}")
new_sandbox_home "${_h14c}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14c}/.claude/oh-my-claude.conf"
printf '{"ts":' > "${_h14c}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h14c}" "t14-truncated" >/dev/null
assert_eq "T14: truncated evidence does not stamp cadence" "no" \
  "$([[ -e "${_h14c}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"
write_oc_events "${_h14c}" 12 8
run_hook "${_h14c}" "t14-repaired" >/dev/null
assert_eq "T14: repaired evidence retries immediately" "5" \
  "$(read_conf_val "${_h14c}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h14cn="$(mktemp -d)"; _cleanup_dirs+=("${_h14cn}")
new_sandbox_home "${_h14cn}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14cn}/.claude/oh-my-claude.conf"
write_oc_events "${_h14cn}" 12 8
printf '\0' >> "${_h14cn}/.claude/quality-pack/gate_events.jsonl"
_nul_evidence_before="$(cksum \
  < "${_h14cn}/.claude/quality-pack/gate_events.jsonl")"
run_hook "${_h14cn}" "t14-raw-nul" >/dev/null
assert_eq "T14: raw-NUL evidence cannot authorize a tune" "4" \
  "$(read_conf_val "${_h14cn}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T14: raw-NUL evidence remains byte-identical" \
  "${_nul_evidence_before}" \
  "$(cksum < "${_h14cn}/.claude/quality-pack/gate_events.jsonl")"
assert_eq "T14: raw-NUL evidence does not stamp cadence" "no" \
  "$([[ -e "${_h14cn}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

_h14ca="$(mktemp -d)"; _cleanup_dirs+=("${_h14ca}")
new_sandbox_home "${_h14ca}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14ca}/.claude/oh-my-claude.conf"
write_oc_events "${_h14ca}" 12 8
printf '{"ts":1\000,"flag":"objective_contract_min_files","old":3,"new":4,"evidence":"prior evidence","host":"test-host"}\n' \
  > "${_h14ca}/.claude/quality-pack/auto-tune.jsonl"
chmod 600 "${_h14ca}/.claude/quality-pack/auto-tune.jsonl"
_raw_audit_before="$(cksum \
  < "${_h14ca}/.claude/quality-pack/auto-tune.jsonl")"
run_hook "${_h14ca}" "t14-raw-nul-audit" >/dev/null
assert_eq "T14: raw-NUL audit cannot authorize a tune" "4" \
  "$(read_conf_val "${_h14ca}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T14: raw-NUL audit remains byte-identical" \
  "${_raw_audit_before}" \
  "$(cksum < "${_h14ca}/.claude/quality-pack/auto-tune.jsonl")"
assert_eq "T14: raw-NUL audit publishes no cadence" "no" \
  "$([[ -e "${_h14ca}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

_h14d="$(mktemp -d)"; _cleanup_dirs+=("${_h14d}")
new_sandbox_home "${_h14d}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14d}/.claude/oh-my-claude.conf"
write_oc_events "${_h14d}" 12 8
chmod 666 "${_h14d}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h14d}" "t14-writable" >/dev/null
assert_eq "T14: world-writable evidence is rejected" "4" \
  "$(read_conf_val "${_h14d}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h14e="$(mktemp -d)"; _cleanup_dirs+=("${_h14e}")
new_sandbox_home "${_h14e}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h14e}/.claude/oh-my-claude.conf"
write_oc_events "${_h14e}" 12 8
run_hook "${_h14e}" "t14-pending-create" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_CONF=1 >/dev/null
chmod 666 "${_h14e}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h14e}" "t14-pending-recover" >/dev/null
assert_eq "T14: applied pending receipt settles despite later-unsafe evidence" "no" \
  "$([[ -e "${_h14e}/.claude/quality-pack/auto-tune-pending.json" ]] \
    && printf yes || printf no)"
assert_eq "T14: unsafe-evidence recovery publishes one audit" "1" \
  "$(wc -l < "${_h14e}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"
assert_eq "T14: unsafe-evidence recovery preserves applied config" "5" \
  "$(read_conf_val "${_h14e}/.claude/oh-my-claude.conf" objective_contract_min_files)"

# ---------------------------------------------------------------------
printf 'Test 15: higher-precedence threshold authorities are never shadow-written\n'
_h15a="$(mktemp -d)"; _cleanup_dirs+=("${_h15a}")
new_sandbox_home "${_h15a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h15a}/.claude/oh-my-claude.conf"
write_oc_events "${_h15a}" 12 8
run_hook "${_h15a}" "t15-env" OMC_OBJECTIVE_CONTRACT_MIN_FILES=9 >/dev/null
assert_eq "T15: environment-shadowed user threshold stays 4" "4" \
  "$(read_conf_val "${_h15a}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_contains "T15: environment shadow is recorded as cadence reason" \
  "higher-precedence" \
  "$(jq -r '.last_reason' "${_h15a}/.claude/quality-pack/auto-tune-state.json")"

_h15b="$(mktemp -d)"; _cleanup_dirs+=("${_h15b}")
new_sandbox_home "${_h15b}"
mkdir -p "${_h15b}/repo/.claude"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h15b}/.claude/oh-my-claude.conf"
printf 'objective_contract_min_files=9\n' \
  > "${_h15b}/repo/.claude/oh-my-claude.conf"
write_oc_events "${_h15b}" 12 8
(cd "${_h15b}/repo" && run_hook "${_h15b}" "t15-project" >/dev/null)
assert_eq "T15: project-shadowed user threshold stays 4" "4" \
  "$(read_conf_val "${_h15b}/.claude/oh-my-claude.conf" objective_contract_min_files)"

# ---------------------------------------------------------------------
printf 'Test 16: nested config writer registers a live lock participant\n'
_h16="$(mktemp -d)"; _cleanup_dirs+=("${_h16}")
new_sandbox_home "${_h16}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h16}/.claude/oh-my-claude.conf"
write_oc_events "${_h16}" 12 8
_ready16="${_h16}/child.ready"
_release16="${_h16}/child.release"
run_hook_raw "${_h16}" "t16-parent" \
  OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  "OMC_TEST_CONFIG_STAGE_READY_FILE=${_ready16}" \
  "OMC_TEST_CONFIG_STAGE_RELEASE_FILE=${_release16}" \
  > "${_h16}/hook.out" & _p16=$!
if wait_for_path "${_ready16}"; then
  _participants16="$(find "${_h16}/.claude/.install.lock" -maxdepth 1 \
    -name 'participant.*' -print | wc -l | tr -d '[:space:]')"
  assert_eq "T16: nested child publishes one participant" "1" \
    "${_participants16}"
  set +e
  HOME="${_h16}" OMC_TEST_CONFIG_LOCK_ATTEMPTS=1 \
    bash "${_h16}/.claude/skills/autowork/scripts/omc-config.sh" \
      set user gate_level=basic >/dev/null 2>&1
  _contended16=$?
  set -e
  if [[ "${_contended16}" -ne 0 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T16: competing writer entered while child participant was live\n' >&2
    fail=$((fail + 1))
  fi
  : > "${_release16}"
else
  printf '  FAIL: T16: nested config writer never reached stage barrier\n' >&2
  fail=$((fail + 1))
  : > "${_release16}"
fi
set +e
wait "${_p16}"
_r16=$?
set -e
assert_eq "T16: parent/child transaction completes" "0" "${_r16}"
assert_eq "T16: participant and owner lock are removed on completion" "no" \
  "$([[ -e "${_h16}/.claude/.install.lock" ]] && printf yes || printf no)"

printf 'Test 16a2: malformed shared-lock authority never normalizes into admission\n'
_h16a2="$(mktemp -d)"; _cleanup_dirs+=("${_h16a2}")
new_sandbox_home "${_h16a2}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h16a2}/.claude/oh-my-claude.conf"
write_oc_events "${_h16a2}" 12 8
mkdir "${_h16a2}/.claude/.install.lock"
printf '424242\000\n' > "${_h16a2}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${_h16a2}/.claude/.install.lock/token"
run_hook "${_h16a2}" "t16a2-nul" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 \
  OMC_PARENT_OPERATION_LOCK_PID=424242 \
  OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token >/dev/null
assert_eq "T16a2: raw-NUL PID cannot authorize nested tuning" "4" \
  "$(read_conf_val "${_h16a2}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T16a2: raw-NUL authority remains inspectable" "yes" \
  "$([[ -d "${_h16a2}/.claude/.install.lock" ]] \
    && printf yes || printf no)"
printf '424242\n' > "${_h16a2}/.claude/.install.lock/pid"
printf 'parent-token\n\n' > "${_h16a2}/.claude/.install.lock/token"
run_hook "${_h16a2}" "t16a2-blank" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 \
  OMC_PARENT_OPERATION_LOCK_PID=424242 \
  OMC_PARENT_OPERATION_LOCK_TOKEN=parent-token >/dev/null
assert_eq "T16a2: trailing blank token cannot authorize nested tuning" "4" \
  "$(read_conf_val "${_h16a2}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T16a2: malformed authority publishes no participant" "0" \
  "$(find "${_h16a2}/.claude/.install.lock" -maxdepth 1 \
    -name 'participant.*' -print | wc -l | tr -d '[:space:]')"
printf 'parent-token\n' > "${_h16a2}/.claude/.install.lock/token"
_lock_id16a2="$(stat -c '%d:%i' "${_h16a2}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${_h16a2}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\000\n' "${_lock_id16a2}" \
  > "${_h16a2}/.claude/.install.lock/owner-released"
chmod 600 "${_h16a2}/.claude/.install.lock/owner-released"
run_hook "${_h16a2}" "t16a2-release-nul" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 >/dev/null
assert_eq "T16a2: raw-NUL release marker cannot authorize reap" "4" \
  "$(read_conf_val "${_h16a2}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
printf 'v1\t%s\t424242\tparent-token\n\n' "${_lock_id16a2}" \
  > "${_h16a2}/.claude/.install.lock/owner-released"
run_hook "${_h16a2}" "t16a2-release-blank" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 >/dev/null
assert_eq "T16a2: extra blank release marker cannot authorize reap" "yes" \
  "$([[ -d "${_h16a2}/.claude/.install.lock" ]] \
    && printf yes || printf no)"

printf 'Test 16b: stranded released generation is reaped before takeover\n'
_h16b="$(mktemp -d)"; _cleanup_dirs+=("${_h16b}")
new_sandbox_home "${_h16b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h16b}/.claude/oh-my-claude.conf"
write_oc_events "${_h16b}" 12 8
mkdir "${_h16b}/.claude/.install.lock"
printf '424242\n' > "${_h16b}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${_h16b}/.claude/.install.lock/token"
_old16b="$(stat -c '%d:%i' "${_h16b}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${_h16b}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\n' "${_old16b}" \
  > "${_h16b}/.claude/.install.lock/owner-released"
chmod 600 "${_h16b}/.claude/.install.lock/owner-released"
run_hook "${_h16b}" "t16b-takeover" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 >/dev/null
assert_eq "T16b: takeover proceeds after exact stranded reap" "5" \
  "$(read_conf_val "${_h16b}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T16b: takeover releases the public lock" "no" \
  "$([[ -e "${_h16b}/.claude/.install.lock" ]] && printf yes || printf no)"
assert_eq "T16b: takeover leaves no retirement scratch" "0" \
  "$(find "${_h16b}/.claude" -maxdepth 1 \
    -name '.install-lock-retired.*' -print | wc -l | tr -d '[:space:]')"

printf 'Test 16c: retired cleanup tolerates an immediate next generation\n'
_h16c="$(mktemp -d)"; _cleanup_dirs+=("${_h16c}")
new_sandbox_home "${_h16c}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h16c}/.claude/oh-my-claude.conf"
write_oc_events "${_h16c}" 12 8
mkdir "${_h16c}/.claude/.install.lock"
printf '424242\n' > "${_h16c}/.claude/.install.lock/pid"
printf 'parent-token\n' > "${_h16c}/.claude/.install.lock/token"
_old16c="$(stat -c '%d:%i' "${_h16c}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${_h16c}/.claude/.install.lock")"
printf 'v1\t%s\t424242\tparent-token\n' "${_old16c}" \
  > "${_h16c}/.claude/.install.lock/owner-released"
chmod 600 "${_h16c}/.claude/.install.lock/owner-released"
_retired_ready16c="${_h16c}/retired.ready"
_retired_release16c="${_h16c}/retired.release"
run_hook_raw "${_h16c}" "t16c-old-reaper" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=1 \
  "OMC_TEST_AUTO_TUNE_LOCK_RETIRED_READY_FILE=${_retired_ready16c}" \
  "OMC_TEST_AUTO_TUNE_LOCK_RETIRED_RELEASE_FILE=${_retired_release16c}" \
  > "${_h16c}/old.out" & _old_reaper16c=$!
if wait_for_path "${_retired_ready16c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T16c: old generation never reached retired cleanup barrier\n' >&2
  fail=$((fail + 1))
fi
_next_ready16c="${_h16c}/next.ready"
_next_release16c="${_h16c}/next.release"
run_hook_raw "${_h16c}" "t16c-next-owner" \
  OMC_TEST_CONFIG_BARRIER_ENABLE=1 \
  "OMC_TEST_CONFIG_STAGE_READY_FILE=${_next_ready16c}" \
  "OMC_TEST_CONFIG_STAGE_RELEASE_FILE=${_next_release16c}" \
  > "${_h16c}/next.out" & _next_owner16c=$!
if wait_for_path "${_next_ready16c}"; then
  pass=$((pass + 1))
else
  printf '  FAIL: T16c: immediate next generation never acquired\n' >&2
  fail=$((fail + 1))
fi
_next_lock16c="$(stat -c '%d:%i' "${_h16c}/.claude/.install.lock" \
  2>/dev/null || stat -f '%d:%i' "${_h16c}/.claude/.install.lock" \
  2>/dev/null || true)"
: > "${_retired_release16c}"
set +e
wait "${_old_reaper16c}"; _old_rc16c=$?
set -e
assert_eq "T16c: old reaper exits without touching the next owner" "0" \
  "${_old_rc16c}"
assert_eq "T16c: public path keeps the immediate next generation" \
  "${_next_lock16c}" \
  "$(stat -c '%d:%i' "${_h16c}/.claude/.install.lock" \
    2>/dev/null || stat -f '%d:%i' "${_h16c}/.claude/.install.lock" \
    2>/dev/null || true)"
assert_eq "T16c: retired old generation leaves no scratch" "0" \
  "$(find "${_h16c}/.claude" -maxdepth 1 \
    -name '.install-lock-retired.*' -print | wc -l | tr -d '[:space:]')"
: > "${_next_release16c}"
set +e
wait "${_next_owner16c}"; _next_rc16c=$?
set -e
assert_eq "T16c: next owner completes normally" "0" "${_next_rc16c}"
assert_eq "T16c: next owner releases the public lock" "no" \
  "$([[ -e "${_h16c}/.claude/.install.lock" ]] && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 17: live-session evidence is complete and resume-safe\n'
_h17a="$(mktemp -d)"; _cleanup_dirs+=("${_h17a}")
new_sandbox_home "${_h17a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17a}/.claude/oh-my-claude.conf"
write_live_oc_events "${_h17a}" "t17-live-only" 10 5
run_hook "${_h17a}" "t17-live-only" >/dev/null
assert_eq "T17: live per-session evidence can trigger tuning" "5" \
  "$(read_conf_val "${_h17a}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T17: live evidence publishes exactly one audit row" "1" \
  "$(wc -l < "${_h17a}/.claude/quality-pack/auto-tune.jsonl" | tr -d '[:space:]')"

_h17b="$(mktemp -d)"; _cleanup_dirs+=("${_h17b}")
new_sandbox_home "${_h17b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17b}/.claude/oh-my-claude.conf"
write_live_oc_events "${_h17b}" "t17-source" 6 3 sourcehost
write_live_oc_events "${_h17b}" "t17-target" 6 3 targethost
printf '{"session_start_ts":%s,"resume_transferred_to":"t17-target"}\n' \
  "$(date +%s)" \
  > "${_h17b}/.claude/quality-pack/state/t17-source/session_state.json"
chmod 600 "${_h17b}/.claude/quality-pack/state/t17-source/session_state.json"
run_hook "${_h17b}" "t17-check-transfer" >/dev/null
assert_eq "T17: transferred source ledger is not double-counted" "4" \
  "$(read_conf_val "${_h17b}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_contains "T17: only the six target-owned blocks reach cadence" \
  "insufficient signal (6 objective-contract block(s)" \
  "$(jq -r '.last_reason' "${_h17b}/.claude/quality-pack/auto-tune-state.json")"

_h17b_nul="$(mktemp -d)"; _cleanup_dirs+=("${_h17b_nul}")
new_sandbox_home "${_h17b_nul}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17b_nul}/.claude/oh-my-claude.conf"
write_live_oc_events "${_h17b_nul}" "t17-nul-source" 6 3 sourcehost
write_live_oc_events "${_h17b_nul}" "t17-nul-target" 6 3 targethost
jq --argjson now "$(date +%s)" \
  '. = {session_start_ts:$now,
    resume_transferred_to:("t17-nul-target" + "\u0000")}' \
  "${_h17b_nul}/.claude/quality-pack/state/t17-nul-source/session_state.json" \
  > "${_h17b_nul}/nul-state.json"
mv "${_h17b_nul}/nul-state.json" \
  "${_h17b_nul}/.claude/quality-pack/state/t17-nul-source/session_state.json"
chmod 600 \
  "${_h17b_nul}/.claude/quality-pack/state/t17-nul-source/session_state.json"
run_hook "${_h17b_nul}" "t17-check-nul-transfer" >/dev/null
assert_eq "T17: NUL-bearing transfer marker cannot hide source evidence" "5" \
  "$(read_conf_val "${_h17b_nul}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"

_h17c="$(mktemp -d)"; _cleanup_dirs+=("${_h17c}")
new_sandbox_home "${_h17c}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17c}/.claude/oh-my-claude.conf"
write_live_oc_events "${_h17c}" "t17-copied-target" 6 3 copyhost
jq -c '. + {session_id:"t17-rolled-source"}' \
  "${_h17c}/.claude/quality-pack/state/t17-copied-target/gate_events.jsonl" \
  > "${_h17c}/.claude/quality-pack/gate_events.jsonl"
chmod 600 "${_h17c}/.claude/quality-pack/gate_events.jsonl"
printf '{"session_start_ts":%s,"resume_source_session_id":"t17-rolled-source"}\n' \
  "$(date +%s)" \
  > "${_h17c}/.claude/quality-pack/state/t17-copied-target/session_state.json"
run_hook "${_h17c}" "t17-check-copy" >/dev/null
assert_eq "T17: copied global/live event IDs are exactly deduplicated" "4" \
  "$(read_conf_val "${_h17c}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_contains "T17: copied event IDs retain a six-block effective sample" \
  "insufficient signal (6 objective-contract block(s)" \
  "$(jq -r '.last_reason' "${_h17c}/.claude/quality-pack/auto-tune-state.json")"

_h17d="$(mktemp -d)"; _cleanup_dirs+=("${_h17d}")
new_sandbox_home "${_h17d}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17d}/.claude/oh-my-claude.conf"
write_oc_events "${_h17d}" 4 2
write_live_oc_events "${_h17d}" "t17-additive-live" 6 3 livehost
run_hook "${_h17d}" "t17-check-additive" >/dev/null
assert_eq "T17: global and distinct live evidence combine in one snapshot" "5" \
  "$(read_conf_val "${_h17d}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h17e="$(mktemp -d)"; _cleanup_dirs+=("${_h17e}")
new_sandbox_home "${_h17e}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17e}/.claude/oh-my-claude.conf"
write_live_oc_events "${_h17e}" "t17-prefix" 10 5 prefixhost
_live17e="${_h17e}/.claude/quality-pack/state/t17-prefix/gate_events.jsonl"
{
  sed -n '1,6p' "${_live17e}"
  sed -n '11,13p' "${_live17e}"
} | jq -c '. + {session_id:"t17-prefix"}' \
  > "${_h17e}/.claude/quality-pack/gate_events.jsonl"
chmod 600 "${_h17e}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h17e}" "t17-prefix" >/dev/null
assert_eq "T17: global prefix plus live suffix reaches the full 10/5 union" "5" \
  "$(read_conf_val "${_h17e}/.claude/oh-my-claude.conf" objective_contract_min_files)"

_h17f="$(mktemp -d)"; _cleanup_dirs+=("${_h17f}")
new_sandbox_home "${_h17f}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17f}/.claude/oh-my-claude.conf"
# Rewrite the second session's first block to the first session's exact payload
# while retaining its own producer ID. Distinct identities must preserve
# both genuine events: 11 blocks / 5 reprompts = 45%, not the false 10/5 tune
# produced by payload-wide unique[].
write_live_oc_events "${_h17f}" "t17-collision-a" 6 3 collisionhost
write_live_oc_events "${_h17f}" "t17-collision-b" 5 2 collisionhost
_events17fa="${_h17f}/.claude/quality-pack/state/t17-collision-a/gate_events.jsonl"
_events17fb="${_h17f}/.claude/quality-pack/state/t17-collision-b/gate_events.jsonl"
_first17f="$(head -1 "${_events17fa}")"
jq -c --argjson twin "${_first17f}" \
  'if input_line_number == 1 then $twin + {event_id:.event_id} else . end' \
  "${_events17fb}" > "${_h17f}/collision-b-rewritten"
mv "${_h17f}/collision-b-rewritten" "${_events17fb}"
chmod 600 "${_events17fb}"
run_hook "${_h17f}" "t17-collision-check" >/dev/null
assert_eq "T17: genuine same-second events are not collapsed into a tune" "4" \
  "$(read_conf_val "${_h17f}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_contains "T17: preserved 11/5 sample remains below the rate bar" \
  "5/11 = 45%" \
  "$(jq -r '.last_reason' "${_h17f}/.claude/quality-pack/auto-tune-state.json")"

_h17g="$(mktemp -d)"; _cleanup_dirs+=("${_h17g}")
new_sandbox_home "${_h17g}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17g}/.claude/oh-my-claude.conf"
write_oc_events "${_h17g}" 12 8
_conflict17g="$(jq -c 'select(.event_id == "ge:testhost:1")
  | .event = "post-block-reprompt"' \
  "${_h17g}/.claude/quality-pack/gate_events.jsonl")"
printf '%s\n' "${_conflict17g}" \
  >> "${_h17g}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h17g}" "t17-conflicting-id" >/dev/null
assert_eq "T17: conflicting duplicate event ID poisons the evidence snapshot" "4" \
  "$(read_conf_val "${_h17g}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T17: poisoned evidence does not advance cadence" "no" \
  "$([[ -e "${_h17g}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

_h17h="$(mktemp -d)"; _cleanup_dirs+=("${_h17h}")
new_sandbox_home "${_h17h}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17h}/.claude/oh-my-claude.conf"
write_oc_events "${_h17h}" 12 8
jq -c 'del(.event_id)' \
  "${_h17h}/.claude/quality-pack/gate_events.jsonl" \
  > "${_h17h}/legacy-idless.jsonl"
mv "${_h17h}/legacy-idless.jsonl" \
  "${_h17h}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h17h}" "t17-legacy-idless" >/dev/null
assert_eq "T17: legacy ID-less evidence cannot authorize mutation" "4" \
  "$(read_conf_val "${_h17h}/.claude/oh-my-claude.conf" objective_contract_min_files)"
assert_eq "T17: ID-less-only evidence publishes no audit row" "no" \
  "$([[ -e "${_h17h}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

_invalid17i_index=0
for _invalid17i in '.' '...' 'a..b'; do
  _invalid17i_index=$((_invalid17i_index + 1))
  _h17i="$(mktemp -d)"; _cleanup_dirs+=("${_h17i}")
  new_sandbox_home "${_h17i}"
  printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
    > "${_h17i}/.claude/oh-my-claude.conf"
  write_oc_events "${_h17i}" 12 8
  jq -c --arg sid "${_invalid17i}" '
    .event_id = ("ge:" + $sid + ":" + (.event_id | split(":")[-1]))
  ' "${_h17i}/.claude/quality-pack/gate_events.jsonl" \
    >"${_h17i}/invalid-gate-ids.jsonl"
  mv "${_h17i}/invalid-gate-ids.jsonl" \
    "${_h17i}/.claude/quality-pack/gate_events.jsonl"
  chmod 600 "${_h17i}/.claude/quality-pack/gate_events.jsonl"
  run_hook "${_h17i}" "t17-invalid-id-${_invalid17i_index}" >/dev/null
  assert_eq "T17: embedded session ${_invalid17i} cannot authorize tuning" \
    "4" \
    "$(read_conf_val "${_h17i}/.claude/oh-my-claude.conf" \
      objective_contract_min_files)"
  assert_eq "T17: embedded session ${_invalid17i} publishes no audit row" \
    "no" \
    "$([[ -e "${_h17i}/.claude/quality-pack/auto-tune.jsonl" ]] \
      && printf yes || printf no)"
done

_h17i_seq="$(mktemp -d)"; _cleanup_dirs+=("${_h17i_seq}")
new_sandbox_home "${_h17i_seq}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17i_seq}/.claude/oh-my-claude.conf"
write_oc_events "${_h17i_seq}" 12 8
jq -c '
  .event_id = ("ge:t17-sequence-overflow:"
    + ((1000000000000000 + input_line_number) | tostring))
' "${_h17i_seq}/.claude/quality-pack/gate_events.jsonl" \
  >"${_h17i_seq}/oversized-gate-sequences.jsonl"
mv "${_h17i_seq}/oversized-gate-sequences.jsonl" \
  "${_h17i_seq}/.claude/quality-pack/gate_events.jsonl"
chmod 600 "${_h17i_seq}/.claude/quality-pack/gate_events.jsonl"
run_hook "${_h17i_seq}" "t17-invalid-sequence" >/dev/null
assert_eq "T17: oversized producer sequence cannot authorize tuning" "4" \
  "$(read_conf_val "${_h17i_seq}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T17: oversized producer sequence publishes no audit row" "no" \
  "$([[ -e "${_h17i_seq}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

_h17j="$(mktemp -d)"; _cleanup_dirs+=("${_h17j}")
new_sandbox_home "${_h17j}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17j}/.claude/oh-my-claude.conf"
write_oc_events "${_h17j}" 12 8
mkdir "${_h17j}/poison-bin"
cat >"${_h17j}/poison-bin/jq" <<MOCK
#!/usr/bin/env bash
printf 'poisoned\\n' >"${_h17j}/poison-ran"
exit 97
MOCK
chmod +x "${_h17j}/poison-bin/jq"
run_hook "${_h17j}" "t17-observer-path" \
  "PATH=${_h17j}/poison-bin:${PATH}" >/dev/null
assert_eq "T17: global mutation hook rejects caller PATH shims" "no" \
  "$([[ -e "${_h17j}/poison-ran" ]] && printf yes || printf no)"
assert_eq "T17: pinned observer path still permits the valid tune" "5" \
  "$(read_conf_val "${_h17j}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"

_h17k="$(mktemp -d)"; _cleanup_dirs+=("${_h17k}")
new_sandbox_home "${_h17k}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h17k}/.claude/oh-my-claude.conf"
write_oc_events "${_h17k}" 12 8
mkdir "${_h17k}/.claude/.install.lock"
printf '424242\n' >"${_h17k}/.claude/.install.lock/pid"
printf 'busy-owner\n' >"${_h17k}/.claude/.install.lock/token"
run_hook_raw "${_h17k}" "t17-bounded-lock-attempts" \
  OMC_TEST_AUTO_TUNE_LOCK_ATTEMPTS=999999999999999999999999 \
  >/dev/null &
_p17k=$!
_done17k=0
for _wait17k in $(seq 1 100); do
  if ! kill -0 "${_p17k}" 2>/dev/null; then
    _done17k=1
    break
  fi
  sleep 0.01
done
if [[ "${_done17k}" -ne 1 ]]; then
  kill "${_p17k}" 2>/dev/null || true
fi
wait "${_p17k}" 2>/dev/null || true
assert_eq "T17: oversized lock-attempt seam is rejected promptly" "1" \
  "${_done17k}"

# ---------------------------------------------------------------------
printf 'Test 18: pending recovery is bound to one captured inode generation\n'
_h18="$(mktemp -d)"; _cleanup_dirs+=("${_h18}")
new_sandbox_home "${_h18}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h18}/.claude/oh-my-claude.conf"
write_oc_events "${_h18}" 12 8
set +e
run_hook_raw "${_h18}" "t18-setup" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_RECEIPT=1 >/dev/null
_setup_rc18=$?
set -e
assert_eq "T18: setup leaves a prepared durable receipt" "75" \
  "${_setup_rc18}"
_pending18="${_h18}/.claude/quality-pack/auto-tune-pending.json"
_ready18="${_h18}/pending-snapshot.ready"
_release18="${_h18}/pending-snapshot.release"
run_hook_raw "${_h18}" "t18-recovery" \
  "OMC_TEST_AUTO_TUNE_PENDING_SNAPSHOT_READY_FILE=${_ready18}" \
  "OMC_TEST_AUTO_TUNE_PENDING_SNAPSHOT_RELEASE_FILE=${_release18}" \
  >"${_h18}/recovery.out" & _recovery18=$!
if wait_for_path "${_ready18}"; then
  cp "${_pending18}" "${_h18}/replacement-pending.json"
  chmod 600 "${_h18}/replacement-pending.json"
  mv "${_h18}/replacement-pending.json" "${_pending18}"
  _replacement_id18="$(file_identity "${_pending18}")"
  : >"${_release18}"
else
  printf '  FAIL: T18: recovery never reached the pending snapshot barrier\n' >&2
  fail=$((fail + 1))
  _replacement_id18="missing"
  : >"${_release18}"
fi
set +e
wait "${_recovery18}"
_recovery_rc18=$?
set -e
assert_eq "T18: generation swap fails closed without a hook error" "0" \
  "${_recovery_rc18}"
assert_eq "T18: replacement pending inode is not deleted" \
  "${_replacement_id18}" "$(file_identity "${_pending18}" 2>/dev/null || true)"
assert_eq "T18: swapped prepared receipt cannot mutate config" "4" \
  "$(read_conf_val "${_h18}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T18: swapped pending receipt publishes no audit" "no" \
  "$([[ -e "${_h18}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"
assert_eq "T18: swapped pending receipt advances no cadence" "no" \
  "$([[ -e "${_h18}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 19: pending publication and retirement preserve intervening generations\n'
_h19a="$(mktemp -d)"; _cleanup_dirs+=("${_h19a}")
new_sandbox_home "${_h19a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19a}/.claude/oh-my-claude.conf"
write_oc_events "${_h19a}" 12 8
_initial_ready19a="${_h19a}/pending-initial.ready"
_initial_release19a="${_h19a}/pending-initial.release"
run_hook_raw "${_h19a}" "t19-initial" \
  "OMC_TEST_AUTO_TUNE_PENDING_INITIAL_READY_FILE=${_initial_ready19a}" \
  "OMC_TEST_AUTO_TUNE_PENDING_INITIAL_RELEASE_FILE=${_initial_release19a}" \
  >"${_h19a}/initial.out" & _initial_pid19a=$!
_pending19a="${_h19a}/.claude/quality-pack/auto-tune-pending.json"
if wait_for_path "${_initial_ready19a}"; then
  printf '{"intervening":"fresh-generation"}\n' >"${_pending19a}"
  chmod 600 "${_pending19a}"
  _initial_id19a="$(file_identity "${_pending19a}")"
  _initial_digest19a="$(cksum <"${_pending19a}")"
  : >"${_initial_release19a}"
else
  printf '  FAIL: T19: initial publisher never reached absence barrier\n' >&2
  fail=$((fail + 1))
  _initial_id19a="missing"
  _initial_digest19a="missing"
  : >"${_initial_release19a}"
fi
set +e
wait "${_initial_pid19a}"
_initial_rc19a=$?
set -e
assert_eq "T19: initial presence conflict exits without a hook error" "0" \
  "${_initial_rc19a}"
assert_eq "T19: initial publish never overwrites an intervening inode" \
  "${_initial_id19a}" "$(file_identity "${_pending19a}" 2>/dev/null || true)"
assert_eq "T19: initial publish preserves intervening bytes" \
  "${_initial_digest19a}" "$(cksum <"${_pending19a}" 2>/dev/null || true)"
assert_eq "T19: initial presence conflict happens before config mutation" "4" \
  "$(read_conf_val "${_h19a}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T19: initial presence conflict publishes no audit" "no" \
  "$([[ -e "${_h19a}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

_h19b="$(mktemp -d)"; _cleanup_dirs+=("${_h19b}")
new_sandbox_home "${_h19b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19b}/.claude/oh-my-claude.conf"
write_oc_events "${_h19b}" 12 8
_advance_ready19b="${_h19b}/pending-advance.ready"
_advance_release19b="${_h19b}/pending-advance.release"
run_hook_raw "${_h19b}" "t19-advance" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_READY_FILE=${_advance_ready19b}" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_RELEASE_FILE=${_advance_release19b}" \
  >"${_h19b}/advance.out" & _advance_pid19b=$!
_pending19b="${_h19b}/.claude/quality-pack/auto-tune-pending.json"
if wait_for_path "${_advance_ready19b}"; then
  cp "${_pending19b}" "${_h19b}/replacement-prepared.json"
  chmod 600 "${_h19b}/replacement-prepared.json"
  mv "${_h19b}/replacement-prepared.json" "${_pending19b}"
  _advance_id19b="$(file_identity "${_pending19b}")"
  _advance_digest19b="$(cksum <"${_pending19b}")"
  : >"${_advance_release19b}"
else
  printf '  FAIL: T19: normal flow never reached phase-advance barrier\n' >&2
  fail=$((fail + 1))
  _advance_id19b="missing"
  _advance_digest19b="missing"
  : >"${_advance_release19b}"
fi
set +e
wait "${_advance_pid19b}"
_advance_rc19b=$?
set -e
assert_eq "T19: phase-generation conflict exits without a hook error" "0" \
  "${_advance_rc19b}"
assert_eq "T19: prepared-to-observed update preserves replacement inode" \
  "${_advance_id19b}" "$(file_identity "${_pending19b}" 2>/dev/null || true)"
assert_eq "T19: prepared-to-observed update preserves replacement bytes" \
  "${_advance_digest19b}" "$(cksum <"${_pending19b}" 2>/dev/null || true)"
assert_eq "T19: config child landed before the guarded phase advance" "5" \
  "$(read_conf_val "${_h19b}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T19: replacement remains in its prepared phase" "prepared" \
  "$(jq -r '.phase' "${_pending19b}")"
assert_eq "T19: failed phase advance publishes no audit" "no" \
  "$([[ -e "${_h19b}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"
assert_eq "T19: failed phase advance publishes no cadence" "no" \
  "$([[ -e "${_h19b}/.claude/quality-pack/auto-tune-state.json" ]] \
    && printf yes || printf no)"

_h19c="$(mktemp -d)"; _cleanup_dirs+=("${_h19c}")
new_sandbox_home "${_h19c}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19c}/.claude/oh-my-claude.conf"
write_oc_events "${_h19c}" 12 8
_retire_ready19c="${_h19c}/pending-retire.ready"
_retire_release19c="${_h19c}/pending-retire.release"
run_hook_raw "${_h19c}" "t19-retire" \
  "OMC_TEST_AUTO_TUNE_PENDING_RETIRE_READY_FILE=${_retire_ready19c}" \
  "OMC_TEST_AUTO_TUNE_PENDING_RETIRE_RELEASE_FILE=${_retire_release19c}" \
  >"${_h19c}/retire.out" & _retire_pid19c=$!
_pending19c="${_h19c}/.claude/quality-pack/auto-tune-pending.json"
_retired19c="${_h19c}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim19c="${_h19c}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
if wait_for_path "${_retire_ready19c}"; then
  cp "${_retired19c}" "${_pending19c}"
  chmod 600 "${_pending19c}"
  _replacement_id19c="$(file_identity "${_pending19c}")"
  _replacement_digest19c="$(cksum <"${_pending19c}")"
  : >"${_retire_release19c}"
else
  printf '  FAIL: T19: finalizer never reached retirement barrier\n' >&2
  fail=$((fail + 1))
  _replacement_id19c="missing"
  _replacement_digest19c="missing"
  : >"${_retire_release19c}"
fi
set +e
wait "${_retire_pid19c}"
_retire_rc19c=$?
set -e
assert_eq "T19: final-retirement race exits cleanly" "0" \
  "${_retire_rc19c}"
assert_eq "T19: finalizer never unlinks a replacement public inode" \
  "${_replacement_id19c}" \
  "$(file_identity "${_pending19c}" 2>/dev/null || true)"
assert_eq "T19: finalizer never changes replacement public bytes" \
  "${_replacement_digest19c}" \
  "$(cksum <"${_pending19c}" 2>/dev/null || true)"
assert_eq "T19: exact retired generation is cleared" "no" \
  "$([[ -e "${_retired19c}" || -L "${_retired19c}" ]] \
    && printf yes || printf no)"
assert_eq "T19: completed retirement clears its generation claim" "no" \
  "$([[ -e "${_retire_claim19c}" || -L "${_retire_claim19c}" ]] \
    && printf yes || printf no)"
assert_eq "T19: original decision remains audited exactly once" "1" \
  "$(wc -l <"${_h19c}/.claude/quality-pack/auto-tune.jsonl" \
    | tr -d '[:space:]')"

_h19d="$(mktemp -d)"; _cleanup_dirs+=("${_h19d}")
new_sandbox_home "${_h19d}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19d}/.claude/oh-my-claude.conf"
write_oc_events "${_h19d}" 12 8
set +e
run_hook_raw "${_h19d}" "t19-retire-crash" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_RETIRE=1 >/dev/null
_retire_crash_rc19d=$?
set -e
_pending19d="${_h19d}/.claude/quality-pack/auto-tune-pending.json"
_retired19d="${_h19d}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim19d="${_h19d}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
assert_eq "T19: interrupted retirement reaches the crash seam" "75" \
  "${_retire_crash_rc19d}"
assert_eq "T19: interrupted retirement vacates the public slot" "no" \
  "$([[ -e "${_pending19d}" || -L "${_pending19d}" ]] \
    && printf yes || printf no)"
assert_eq "T19: interrupted retirement leaves recoverable quarantine" "yes" \
  "$([[ -f "${_retired19d}" ]] && printf yes || printf no)"
assert_eq "T19: interrupted retirement retains exact generation claim" "yes" \
  "$([[ -f "${_retire_claim19d}" ]] && printf yes || printf no)"
printf 'auto_tune=off\n' >>"${_h19d}/.claude/oh-my-claude.conf"
run_hook "${_h19d}" "t19-retire-recover-disabled" >/dev/null
assert_eq "T19: disabled startup clears exact retired quarantine" "no" \
  "$([[ -e "${_retired19d}" || -L "${_retired19d}" ]] \
    && printf yes || printf no)"
assert_eq "T19: disabled startup clears settled retirement claim" "no" \
  "$([[ -e "${_retire_claim19d}" || -L "${_retire_claim19d}" ]] \
    && printf yes || printf no)"
assert_eq "T19: retired cleanup does not recreate a public receipt" "no" \
  "$([[ -e "${_pending19d}" || -L "${_pending19d}" ]] \
    && printf yes || printf no)"
assert_eq "T19: interrupted decision remains audited exactly once" "1" \
  "$(wc -l <"${_h19d}/.claude/quality-pack/auto-tune.jsonl" \
    | tr -d '[:space:]')"

_h19e="$(mktemp -d)"; _cleanup_dirs+=("${_h19e}")
new_sandbox_home "${_h19e}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19e}/.claude/oh-my-claude.conf"
write_oc_events "${_h19e}" 12 8
_pre_retire_ready19e="${_h19e}/pending-pre-retire.ready"
_pre_retire_release19e="${_h19e}/pending-pre-retire.release"
run_hook_raw "${_h19e}" "t19-pre-retire-swap" \
  "OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_READY_FILE=${_pre_retire_ready19e}" \
  "OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_RELEASE_FILE=${_pre_retire_release19e}" \
  >"${_h19e}/pre-retire.out" & _pre_retire_pid19e=$!
_pending19e="${_h19e}/.claude/quality-pack/auto-tune-pending.json"
_retired19e="${_h19e}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim19e="${_h19e}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
if wait_for_path "${_pre_retire_ready19e}"; then
  cp "${_pending19e}" "${_h19e}/pre-retire-replacement.json"
  chmod 600 "${_h19e}/pre-retire-replacement.json"
  mv "${_h19e}/pre-retire-replacement.json" "${_pending19e}"
  _pre_retire_id19e="$(file_identity "${_pending19e}")"
  _pre_retire_digest19e="$(cksum <"${_pending19e}")"
  : >"${_pre_retire_release19e}"
else
  printf '  FAIL: T19: finalizer never reached pre-rename source seam\n' >&2
  fail=$((fail + 1))
  _pre_retire_id19e="missing"
  _pre_retire_digest19e="missing"
  : >"${_pre_retire_release19e}"
fi
set +e
wait "${_pre_retire_pid19e}"
_pre_retire_rc19e=$?
set -e
assert_eq "T19: pre-rename source swap exits without a hook error" "0" \
  "${_pre_retire_rc19e}"
assert_eq "T19: wrongly quarantined replacement inode is restored" \
  "${_pre_retire_id19e}" \
  "$(file_identity "${_pending19e}" 2>/dev/null || true)"
assert_eq "T19: wrongly quarantined replacement bytes are restored" \
  "${_pre_retire_digest19e}" \
  "$(cksum <"${_pending19e}" 2>/dev/null || true)"
assert_eq "T19: wrong-generation quarantine is vacated after restore" "no" \
  "$([[ -e "${_retired19e}" || -L "${_retired19e}" ]] \
    && printf yes || printf no)"
assert_eq "T19: wrong-generation restore clears stale claim" "no" \
  "$([[ -e "${_retire_claim19e}" || -L "${_retire_claim19e}" ]] \
    && printf yes || printf no)"
assert_eq "T19: original decision is still audited exactly once" "1" \
  "$(wc -l <"${_h19e}/.claude/quality-pack/auto-tune.jsonl" \
    | tr -d '[:space:]')"

_h19f="$(mktemp -d)"; _cleanup_dirs+=("${_h19f}")
new_sandbox_home "${_h19f}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h19f}/.claude/oh-my-claude.conf"
write_oc_events "${_h19f}" 12 8
_pre_retire_ready19f="${_h19f}/pending-pre-retire-crash.ready"
_pre_retire_release19f="${_h19f}/pending-pre-retire-crash.release"
run_hook_raw "${_h19f}" "t19-pre-retire-crash" \
  "OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_READY_FILE=${_pre_retire_ready19f}" \
  "OMC_TEST_AUTO_TUNE_PENDING_PRE_RETIRE_RELEASE_FILE=${_pre_retire_release19f}" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_RETIRE_RENAME=1 \
  >"${_h19f}/pre-retire-crash.out" & _pre_retire_pid19f=$!
_pending19f="${_h19f}/.claude/quality-pack/auto-tune-pending.json"
_retired19f="${_h19f}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim19f="${_h19f}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
if wait_for_path "${_pre_retire_ready19f}"; then
  jq -c '.phase = "prepared"' "${_pending19f}" \
    >"${_h19f}/receipt-shaped-replacement.json"
  chmod 600 "${_h19f}/receipt-shaped-replacement.json"
  mv "${_h19f}/receipt-shaped-replacement.json" "${_pending19f}"
  _pre_retire_id19f="$(file_identity "${_pending19f}")"
  _pre_retire_digest19f="$(cksum <"${_pending19f}")"
  : >"${_pre_retire_release19f}"
else
  printf '  FAIL: T19: crash case never reached pre-rename source seam\n' >&2
  fail=$((fail + 1))
  _pre_retire_id19f="missing"
  _pre_retire_digest19f="missing"
  : >"${_pre_retire_release19f}"
fi
set +e
wait "${_pre_retire_pid19f}"
_pre_retire_rc19f=$?
set -e
assert_eq "T19: wrong-generation rename reaches crash seam" "75" \
  "${_pre_retire_rc19f}"
assert_eq "T19: crash leaves public slot vacant" "no" \
  "$([[ -e "${_pending19f}" || -L "${_pending19f}" ]] \
    && printf yes || printf no)"
assert_eq "T19: crash quarantine holds the replacement inode" \
  "${_pre_retire_id19f}" \
  "$(file_identity "${_retired19f}" 2>/dev/null || true)"
assert_eq "T19: crash retains the mismatched retirement claim" "yes" \
  "$([[ -f "${_retire_claim19f}" ]] && printf yes || printf no)"
run_hook "${_h19f}" "t19-pre-retire-crash-recover" >/dev/null
assert_eq "T19: recovery restores arbitrary receipt-shaped inode" \
  "${_pre_retire_id19f}" \
  "$(file_identity "${_pending19f}" 2>/dev/null || true)"
assert_eq "T19: recovery restores arbitrary receipt-shaped bytes" \
  "${_pre_retire_digest19f}" \
  "$(cksum <"${_pending19f}" 2>/dev/null || true)"
assert_eq "T19: recovery vacates wrong-generation quarantine" "no" \
  "$([[ -e "${_retired19f}" || -L "${_retired19f}" ]] \
    && printf yes || printf no)"
assert_eq "T19: recovery clears mismatched retirement claim" "no" \
  "$([[ -e "${_retire_claim19f}" || -L "${_retire_claim19f}" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf 'Test 20: atomic pending publication and phase advancement recover every durable edge\n'
_h20a="$(mktemp -d)"; _cleanup_dirs+=("${_h20a}")
new_sandbox_home "${_h20a}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h20a}/.claude/oh-my-claude.conf"
write_oc_events "${_h20a}" 12 8
set +e
run_hook_raw "${_h20a}" "t20-initial-link-crash" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_INITIAL_LINK=1 >/dev/null
_initial_link_rc20a=$?
set -e
_pending20a="${_h20a}/.claude/quality-pack/auto-tune-pending.json"
_initial_temp20a=""
_initial_temp_count20a=0
for _initial_candidate20a in \
    "${_h20a}/.claude/quality-pack"/.auto-tune-pending.json.auto-tune.*; do
  [[ -e "${_initial_candidate20a}" \
      || -L "${_initial_candidate20a}" ]] || continue
  _initial_temp_count20a=$((_initial_temp_count20a + 1))
  [[ -n "${_initial_temp20a}" ]] \
    || _initial_temp20a="${_initial_candidate20a}"
done
assert_eq "T20: initial hard-link crash reaches the failpoint" "75" \
  "${_initial_link_rc20a}"
assert_eq "T20: interrupted initial publication retains one stage" "1" \
  "${_initial_temp_count20a}"
assert_eq "T20: initial stage and public receipt are one inode" \
  "$(file_identity "${_pending20a}" 2>/dev/null || true)" \
  "$(file_identity "${_initial_temp20a}" 2>/dev/null || true)"
assert_eq "T20: interrupted initial publication has exactly two links" "2" \
  "$(file_link_count "${_pending20a}" 2>/dev/null || true)"
run_hook "${_h20a}" "t20-initial-link-recover" >/dev/null
assert_eq "T20: initial-link recovery completes the tune once" "5" \
  "$(read_conf_val "${_h20a}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T20: initial-link recovery publishes one audit row" "1" \
  "$(wc -l <"${_h20a}/.claude/quality-pack/auto-tune.jsonl" \
    | tr -d '[:space:]')"
_initial_temp_count20a=0
for _initial_candidate20a in \
    "${_h20a}/.claude/quality-pack"/.auto-tune-pending.json.auto-tune.*; do
  [[ -e "${_initial_candidate20a}" \
      || -L "${_initial_candidate20a}" ]] || continue
  _initial_temp_count20a=$((_initial_temp_count20a + 1))
done
assert_eq "T20: initial-link recovery removes reserved stages" "0" \
  "${_initial_temp_count20a}"

_h20b="$(mktemp -d)"; _cleanup_dirs+=("${_h20b}")
new_sandbox_home "${_h20b}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h20b}/.claude/oh-my-claude.conf"
write_oc_events "${_h20b}" 12 8
_advance_link_ready20b="${_h20b}/pending-advance-link.ready"
_advance_link_release20b="${_h20b}/pending-advance-link.release"
run_hook_raw "${_h20b}" "t20-advance-link-race" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_LINK_READY_FILE=${_advance_link_ready20b}" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_LINK_RELEASE_FILE=${_advance_link_release20b}" \
  >"${_h20b}/advance-link.out" & _advance_link_pid20b=$!
_pending20b="${_h20b}/.claude/quality-pack/auto-tune-pending.json"
_retired20b="${_h20b}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim20b="${_h20b}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
_advance_stage20b="${_h20b}/.claude/quality-pack/.auto-tune-pending.advance-stage"
if wait_for_path "${_advance_link_ready20b}"; then
  printf '{"intervening":"fresh"}\0tail\n' >"${_pending20b}"
  chmod 600 "${_pending20b}"
  _advance_link_id20b="$(file_identity "${_pending20b}")"
  _advance_link_digest20b="$(cksum <"${_pending20b}")"
  : >"${_advance_link_release20b}"
else
  printf '  FAIL: T20: phase publisher never reached post-validation link seam\n' >&2
  fail=$((fail + 1))
  _advance_link_id20b="missing"
  _advance_link_digest20b="missing"
  : >"${_advance_link_release20b}"
fi
set +e
wait "${_advance_link_pid20b}"
_advance_link_rc20b=$?
set -e
assert_eq "T20: advance destination conflict exits without hook error" "0" \
  "${_advance_link_rc20b}"
assert_eq "T20: atomic link never overwrites the intervening inode" \
  "${_advance_link_id20b}" \
  "$(file_identity "${_pending20b}" 2>/dev/null || true)"
assert_eq "T20: atomic link preserves NUL-bearing intervening bytes" \
  "${_advance_link_digest20b}" \
  "$(cksum <"${_pending20b}" 2>/dev/null || true)"
assert_eq "T20: destination race retains the old quarantine" "yes" \
  "$([[ -f "${_retired20b}" ]] && printf yes || printf no)"
assert_eq "T20: destination race retains its staged transaction" "staged" \
  "$(jq -r '.transition_phase' "${_retire_claim20b}" 2>/dev/null || true)"
assert_eq "T20: destination race retains the observed stage" "yes" \
  "$([[ -f "${_advance_stage20b}" ]] && printf yes || printf no)"
assert_eq "T20: destination conflict occurs after the config write" "5" \
  "$(read_conf_val "${_h20b}/.claude/oh-my-claude.conf" \
    objective_contract_min_files)"
assert_eq "T20: blocked phase publication emits no audit" "no" \
  "$([[ -e "${_h20b}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

for _phase20c in RENAME LINK CLAIM; do
  _h20c="$(mktemp -d)"; _cleanup_dirs+=("${_h20c}")
  new_sandbox_home "${_h20c}"
  printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
    > "${_h20c}/.claude/oh-my-claude.conf"
  write_oc_events "${_h20c}" 12 8
  set +e
  run_hook_raw "${_h20c}" "t20-advance-${_phase20c}" \
    "OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_${_phase20c}=1" \
    >/dev/null
  _advance_crash_rc20c=$?
  set -e
  _pending20c="${_h20c}/.claude/quality-pack/auto-tune-pending.json"
  _retired20c="${_h20c}/.claude/quality-pack/.auto-tune-pending.retired"
  _retire_claim20c="${_h20c}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
  _advance_stage20c="${_h20c}/.claude/quality-pack/.auto-tune-pending.advance-stage"
  assert_eq "T20 ${_phase20c}: phase crash reaches the failpoint" "75" \
    "${_advance_crash_rc20c}"
  assert_eq "T20 ${_phase20c}: config generation already landed" "5" \
    "$(read_conf_val "${_h20c}/.claude/oh-my-claude.conf" \
      objective_contract_min_files)"
  assert_eq "T20 ${_phase20c}: old prepared generation is quarantined" "yes" \
    "$([[ -f "${_retired20c}" ]] && printf yes || printf no)"
  case "${_phase20c}" in
    RENAME)
      assert_eq "T20 RENAME: claim records pre-stage phase" "claimed" \
        "$(jq -r '.transition_phase' "${_retire_claim20c}")"
      assert_eq "T20 RENAME: public slot is still vacant" "no" \
        "$([[ -e "${_pending20c}" || -L "${_pending20c}" ]] \
          && printf yes || printf no)"
      ;;
    LINK)
      assert_eq "T20 LINK: claim remains staged" "staged" \
        "$(jq -r '.transition_phase' "${_retire_claim20c}")"
      assert_eq "T20 LINK: stage/public inode has two names" "2" \
        "$(file_link_count "${_pending20c}")"
      assert_eq "T20 LINK: stage and public names bind one inode" \
        "$(file_identity "${_advance_stage20c}")" \
        "$(file_identity "${_pending20c}")"
      ;;
    CLAIM)
      assert_eq "T20 CLAIM: claim records published phase" "published" \
        "$(jq -r '.transition_phase' "${_retire_claim20c}")"
      assert_eq "T20 CLAIM: stage/public inode still has two names" "2" \
        "$(file_link_count "${_pending20c}")"
      ;;
  esac
  run_hook "${_h20c}" "t20-advance-${_phase20c}-recover" >/dev/null
  assert_eq "T20 ${_phase20c}: recovery publishes one audit row" "1" \
    "$(wc -l <"${_h20c}/.claude/quality-pack/auto-tune.jsonl" \
      | tr -d '[:space:]')"
  assert_eq "T20 ${_phase20c}: recovery clears the public receipt" "no" \
    "$([[ -e "${_pending20c}" || -L "${_pending20c}" ]] \
      && printf yes || printf no)"
  assert_eq "T20 ${_phase20c}: recovery clears old quarantine" "no" \
    "$([[ -e "${_retired20c}" || -L "${_retired20c}" ]] \
      && printf yes || printf no)"
  assert_eq "T20 ${_phase20c}: recovery clears advance claim" "no" \
    "$([[ -e "${_retire_claim20c}" || -L "${_retire_claim20c}" ]] \
      && printf yes || printf no)"
  assert_eq "T20 ${_phase20c}: recovery clears observed stage" "no" \
    "$([[ -e "${_advance_stage20c}" || -L "${_advance_stage20c}" ]] \
      && printf yes || printf no)"
done

_h20d="$(mktemp -d)"; _cleanup_dirs+=("${_h20d}")
new_sandbox_home "${_h20d}"
printf 'auto_tune=on\nobjective_contract_min_files=4\n' \
  > "${_h20d}/.claude/oh-my-claude.conf"
write_oc_events "${_h20d}" 12 8
_advance_ready20d="${_h20d}/pending-advance-wrong-rename.ready"
_advance_release20d="${_h20d}/pending-advance-wrong-rename.release"
run_hook_raw "${_h20d}" "t20-advance-wrong-rename" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_READY_FILE=${_advance_ready20d}" \
  "OMC_TEST_AUTO_TUNE_PENDING_ADVANCE_RELEASE_FILE=${_advance_release20d}" \
  OMC_TEST_AUTO_TUNE_FAIL_AFTER_PENDING_ADVANCE_RAW_RENAME=1 \
  >"${_h20d}/advance-wrong-rename.out" & _advance_pid20d=$!
_pending20d="${_h20d}/.claude/quality-pack/auto-tune-pending.json"
_retired20d="${_h20d}/.claude/quality-pack/.auto-tune-pending.retired"
_retire_claim20d="${_h20d}/.claude/quality-pack/.auto-tune-pending.retire-claim.json"
_advance_stage20d="${_h20d}/.claude/quality-pack/.auto-tune-pending.advance-stage"
if wait_for_path "${_advance_ready20d}"; then
  printf '{"intervening":"wrong-source"}\0tail\n' \
    >"${_h20d}/advance-replacement.json"
  chmod 600 "${_h20d}/advance-replacement.json"
  mv "${_h20d}/advance-replacement.json" "${_pending20d}"
  _advance_replacement_id20d="$(file_identity "${_pending20d}")"
  _advance_replacement_digest20d="$(cksum <"${_pending20d}")"
  : >"${_advance_release20d}"
else
  printf '  FAIL: T20: advance source never reached post-validation seam\n' >&2
  fail=$((fail + 1))
  _advance_replacement_id20d="missing"
  _advance_replacement_digest20d="missing"
  : >"${_advance_release20d}"
fi
set +e
wait "${_advance_pid20d}"
_advance_rc20d=$?
set -e
assert_eq "T20: wrong advance source reaches raw-rename crash seam" "75" \
  "${_advance_rc20d}"
assert_eq "T20: wrong source is durably quarantined by exact inode" \
  "${_advance_replacement_id20d}" \
  "$(file_identity "${_retired20d}" 2>/dev/null || true)"
assert_eq "T20: wrong-source crash retains its expected-generation claim" "yes" \
  "$([[ -f "${_retire_claim20d}" ]] && printf yes || printf no)"
run_hook "${_h20d}" "t20-advance-wrong-rename-recover" >/dev/null
assert_eq "T20: advance recovery restores wrong quarantined inode" \
  "${_advance_replacement_id20d}" \
  "$(file_identity "${_pending20d}" 2>/dev/null || true)"
assert_eq "T20: advance recovery restores wrong quarantined bytes" \
  "${_advance_replacement_digest20d}" \
  "$(cksum <"${_pending20d}" 2>/dev/null || true)"
assert_eq "T20: wrong-generation recovery clears quarantine" "no" \
  "$([[ -e "${_retired20d}" || -L "${_retired20d}" ]] \
    && printf yes || printf no)"
assert_eq "T20: wrong-generation recovery clears advance claim" "no" \
  "$([[ -e "${_retire_claim20d}" || -L "${_retire_claim20d}" ]] \
    && printf yes || printf no)"
assert_eq "T20: wrong-generation recovery publishes no observed stage" "no" \
  "$([[ -e "${_advance_stage20d}" || -L "${_advance_stage20d}" ]] \
    && printf yes || printf no)"
assert_eq "T20: wrong-generation recovery publishes no audit" "no" \
  "$([[ -e "${_h20d}/.claude/quality-pack/auto-tune.jsonl" ]] \
    && printf yes || printf no)"

# ---------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
