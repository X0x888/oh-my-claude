#!/usr/bin/env bash
# test-shortcut-ratio-gate.sh — regression coverage for the shortcut-ratio
# gate added in v1.35.0.
#
# The gate fires a one-time soft block when the active wave plan has
# total≥10 findings AND deferred/decided ≥ 0.5. It catches the
# shortcut-on-big-tasks pattern the user named: even when every
# individual deferral has a valid WHY, ship-vs-defer balance on a big
# plan is itself a signal that the model satisfied gate counts by
# deferring the hard half of the work.
#
# Coverage:
#   T1 — flag off → no fire
#   T2 — total < 10 → no fire (small plan)
#   T3 — decided < 5 → no fire (insufficient decisions)
#   T4 — ratio < 50% → no fire (majority shipped)
#   T5 — ratio == 50% on threshold-sized plan → fires once
#   T6 — ratio > 50% → fires
#   T7 — block_cap=1: second invocation does not re-fire
#   T8 — non-execution intent → no fire
#   T9 — no findings.json → no fire (fail-open)
#   T10 — gate-event row written on fire
#   T11 — scorecard lists deferred set
#   T12 — fail-open on malformed findings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="srg-test-session"
ensure_session_dir

cleanup() { rm -rf "${TEST_STATE_ROOT}"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
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

reset_state() {
  rm -f "$(session_file "findings.json")"
  rm -f "$(session_file "${STATE_JSON}")"
  rm -f "$(session_file "gate_events.jsonl")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

# Build a synthetic findings.json with the requested mix of statuses.
# Args: <total_count> <shipped_count> <deferred_count> [pending_count]
build_findings() {
  local total="$1" shipped="$2" deferred="$3" pending="${4:-0}"
  local file
  file="$(session_file "findings.json")"
  local i=1
  printf '{"version":1,"created_ts":1000,"updated_ts":1000,"findings":[' > "${file}"
  local first=1
  for ((j=0; j<shipped; j++)); do
    [[ "${first}" -eq 0 ]] && printf ',' >> "${file}" || first=0
    printf '{"id":"F-%03d","summary":"shipped item","severity":"high","status":"shipped","notes":"done"}' "${i}" >> "${file}"
    i=$((i + 1))
  done
  for ((j=0; j<deferred; j++)); do
    [[ "${first}" -eq 0 ]] && printf ',' >> "${file}" || first=0
    printf '{"id":"F-%03d","summary":"deferred item","severity":"medium","status":"deferred","notes":"requires database migration"}' "${i}" >> "${file}"
    i=$((i + 1))
  done
  for ((j=0; j<pending; j++)); do
    [[ "${first}" -eq 0 ]] && printf ',' >> "${file}" || first=0
    printf '{"id":"F-%03d","summary":"pending item","severity":"low","status":"pending"}' "${i}" >> "${file}"
    i=$((i + 1))
  done
  printf '],"waves":[]}\n' >> "${file}"
}

# Inline simulation of the shortcut-ratio gate. Mirrors the block in
# stop-guard.sh — keep in sync if that gate changes. Returns one of:
#   block:<ratio_pct>%, allow:flag_off, allow:non_execution,
#   allow:no_file, allow:total_low, allow:decided_low,
#   allow:ratio_low, allow:already_blocked
run_ratio_gate() {
  local task_intent="$1"
  if [[ "${OMC_SHORTCUT_RATIO_GATE}" != "on" ]]; then
    printf 'allow:flag_off'; return
  fi
  if ! is_execution_intent_value "${task_intent}"; then
    printf 'allow:non_execution'; return
  fi
  local file
  file="$(session_file "findings.json")"
  if [[ ! -f "${file}" ]]; then
    printf 'allow:no_file'; return
  fi
  local total
  total="$(read_total_findings_count)"
  if ! [[ "${total}" =~ ^[0-9]+$ ]] || [[ "${total}" -lt 10 ]]; then
    printf 'allow:total_low'; return
  fi
  local shipped deferred decided ratio_pct blocks
  shipped="$(jq -r '[(.findings // [])[] | select(.status == "shipped")] | length' "${file}" 2>/dev/null || printf '0')"
  deferred="$(jq -r '[(.findings // [])[] | select(.status == "deferred")] | length' "${file}" 2>/dev/null || printf '0')"
  shipped="${shipped:-0}"
  deferred="${deferred:-0}"
  [[ "${shipped}" =~ ^[0-9]+$ ]] || shipped=0
  [[ "${deferred}" =~ ^[0-9]+$ ]] || deferred=0
  decided=$((shipped + deferred))
  if [[ "${decided}" -lt 5 ]]; then
    printf 'allow:decided_low'; return
  fi
  ratio_pct=$(( deferred * 100 / decided ))
  blocks="$(read_state "shortcut_ratio_blocks")"
  blocks="${blocks:-0}"
  [[ "${blocks}" =~ ^[0-9]+$ ]] || blocks=0
  if [[ "${ratio_pct}" -ge 50 ]] && [[ "${blocks}" -lt 1 ]]; then
    write_state "shortcut_ratio_blocks" "$((blocks + 1))"
    record_gate_event "shortcut-ratio" "block" \
      "total=${total}" "shipped=${shipped}" "deferred=${deferred}" "ratio_pct=${ratio_pct}"
    printf 'block:%s%%' "${ratio_pct}"; return
  fi
  if [[ "${ratio_pct}" -lt 50 ]]; then
    printf 'allow:ratio_low'; return
  fi
  printf 'allow:already_blocked'
}

# T1 — flag off → no fire
reset_state
build_findings 12 4 6 2
OMC_SHORTCUT_RATIO_GATE=off
result="$(run_ratio_gate "execution")"
assert_eq "T1: flag off bypasses gate" "allow:flag_off" "${result}"

# T2 — total < 10 → no fire (small plan)
reset_state
build_findings 8 3 5 0
OMC_SHORTCUT_RATIO_GATE=on
result="$(run_ratio_gate "execution")"
assert_eq "T2: small plan total<10 → no fire" "allow:total_low" "${result}"

# T3 — decided < 5 → no fire (only 3 decisions made)
reset_state
build_findings 12 1 2 9
result="$(run_ratio_gate "execution")"
assert_eq "T3: decided<5 → no fire" "allow:decided_low" "${result}"

# T4 — ratio < 50% → no fire (majority shipped)
reset_state
build_findings 12 7 3 2
result="$(run_ratio_gate "execution")"
assert_eq "T4: ratio<50% → no fire" "allow:ratio_low" "${result}"

# T5 — ratio == 50% on threshold-sized plan → fires once
reset_state
build_findings 10 5 5 0
result="$(run_ratio_gate "execution")"
assert_eq "T5: ratio=50% on 10-finding plan → fires" "block:50%" "${result}"

# T6 — ratio > 50% → fires
reset_state
build_findings 12 4 6 2
result="$(run_ratio_gate "execution")"
assert_eq "T6: ratio>50% → fires" "block:60%" "${result}"

# T7 — block_cap=1: second invocation does not re-fire
result="$(run_ratio_gate "execution")"
assert_eq "T7: second invocation → no re-fire" "allow:already_blocked" "${result}"

# T8 — non-execution intent → no fire
reset_state
build_findings 12 4 6 2
result="$(run_ratio_gate "advisory")"
assert_eq "T8: advisory intent → no fire" "allow:non_execution" "${result}"

# T9 — no findings.json → no fire (fail-open)
reset_state
result="$(run_ratio_gate "execution")"
assert_eq "T9: no findings.json → fail-open" "allow:no_file" "${result}"

# T10 — gate-event row written on fire
reset_state
build_findings 12 4 6 2
result="$(run_ratio_gate "execution")"
assert_eq "T10 setup: fired" "block:60%" "${result}"
events_file="$(session_file "gate_events.jsonl")"
events_content="$(cat "${events_file}" 2>/dev/null || echo '')"
assert_contains "T10: gate=shortcut-ratio in events" '"gate":"shortcut-ratio"' "${events_content}"
assert_contains "T10: event=block in events" '"event":"block"' "${events_content}"
assert_contains "T10: total captured in details" '"total":12' "${events_content}"
assert_contains "T10: deferred captured in details" '"deferred":6' "${events_content}"
assert_contains "T10: ratio_pct captured in details" '"ratio_pct":60' "${events_content}"

# T11 — scorecard lists deferred set (test the inline scorecard logic
# that stop-guard.sh embeds in the block message)
reset_state
build_findings 12 4 6 2
findings_file="$(session_file "findings.json")"
scorecard="$(jq -r '
  [(.findings // [])[] | select(.status == "deferred")]
  | sort_by(.severity)
  | .[0:8]
  | .[]
  | "  - " + .id + " [" + (.severity // "?") + "] " + (.summary // "(no summary)")
    + (if (.notes // "") != "" then " — " + .notes else "" end)
' "${findings_file}")"
assert_contains "T11: scorecard lists F-005" "F-005" "${scorecard}"
assert_contains "T11: scorecard includes deferred summary" "deferred item" "${scorecard}"
assert_contains "T11: scorecard includes notes" "requires database migration" "${scorecard}"
# Top 8 cap: build 10 deferred and confirm scorecard truncates
reset_state
build_findings 15 0 12 3
scorecard_count="$(jq -r '
  [(.findings // [])[] | select(.status == "deferred")]
  | sort_by(.severity)
  | .[0:8]
  | length
' "${findings_file}")"
assert_eq "T11: scorecard caps at 8 lines" "8" "${scorecard_count}"

# T12 — fail-open on malformed findings.json (no crash, gate doesn't fire)
reset_state
printf 'this is not valid JSON {{{ }}}\n' > "$(session_file "findings.json")"
total="$(read_total_findings_count)"
# Either returns 0 (jq error) or empty — both should be treated as "no plan"
if [[ "${total}" =~ ^[0-9]+$ ]] && [[ "${total}" -ge 10 ]]; then
  printf '  FAIL: T12: malformed findings.json should not produce total>=10\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf '\n=== Shortcut-Ratio Gate Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
