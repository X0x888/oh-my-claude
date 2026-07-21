#!/usr/bin/env bash
# tests/test-schema-versioning.sh — regression net for the `_v:1`
# schema-version convention on cross-session JSONL ledgers (v1.42.x F-009).
#
# Background. v1.31.0 W4 introduced `_v: 1` on every ledger row so
# future schema migrations can read both old and new shapes side-by-
# side. The data-lens F-009 found `gate_events.jsonl` was the heaviest
# ledger (318KB live) with 0/1345 rows carrying `_v` — but the *source*
# (`record_gate_event` in common.sh) already emits `_v:1` (v1.36.x W2);
# only pre-existing rows lacked the field. This test asserts the
# convention does not silently regress.
#
# Asserted invariants:
#   - record_gate_event() emits a row with `_v: 1`
#   - record_serendipity.sh emits a row with `_v: 1`
#   - record-archetype.sh emits a row with `_v: 1`
#   - ulw-correct-record.sh emits a row with `_v: 1`
#   - show-report.sh:1298 documents the directive_apply_rate formula
#     (verifies F-012 "half-shipped telemetry" is closed)
#
# CI-pinned in .github/workflows/validate.yml.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
SCRIPTS_DIR="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

PASS=0
FAIL=0

_pass() {
  printf '  PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

_fail() {
  printf >&2 '  FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
}

# --- T1: record_gate_event emits _v:1 and durable event identities ---
#
# Sourcing common.sh requires SESSION_ID / STATE_ROOT to be safe.
# Simulate a hook environment in a sterile temp dir.

setup_sterile_env() {
  TEST_TMPDIR="$(mktemp -d)"
  STATE_DIR="${TEST_TMPDIR}/state/test-session"
  mkdir -p "${STATE_DIR}"
  printf '{}' >"${STATE_DIR}/session_state.json"

  export HOME="${TEST_TMPDIR}/home"
  export SESSION_ID="test-session"
  mkdir -p "${HOME}/.claude/quality-pack/state/test-session"
  cp "${STATE_DIR}/session_state.json" "${HOME}/.claude/quality-pack/state/test-session/session_state.json"
}

teardown_sterile_env() {
  if [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

trap teardown_sterile_env EXIT

setup_sterile_env

# Source common.sh; bypass classifier eager-load to keep the test fast.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

# shellcheck source=/dev/null
. "${SCRIPTS_DIR}/common.sh"

# Smoke-fire the gate-event recorder.
GATE_EVENTS_FILE="${HOME}/.claude/quality-pack/state/test-session/gate_events.jsonl"
record_gate_event "t1_gate" "t1_event" 2>/dev/null || true
record_gate_event "t1_gate" "t1_event" 2>/dev/null || true

if [[ -s "${GATE_EVENTS_FILE}" ]]; then
  v_val="$(tail -1 "${GATE_EVENTS_FILE}" | jq -r '._v // "missing"' 2>/dev/null || echo "parse-error")"
  if [[ "${v_val}" == "1" ]]; then
    _pass "record_gate_event emits _v:1"
  else
    _fail "record_gate_event _v=${v_val} (expected 1)"
  fi
  ts_type="$(tail -1 "${GATE_EVENTS_FILE}" | jq -r '.ts | type' 2>/dev/null || echo "parse-error")"
  if [[ "${ts_type}" == "number" ]]; then
    _pass "record_gate_event ts is integer (number)"
  else
    _fail "record_gate_event ts type=${ts_type} (expected number)"
  fi
  event_ids="$(jq -r '.event_id // "missing"' "${GATE_EVENTS_FILE}" \
    2>/dev/null | paste -sd ',' -)"
  if [[ "${event_ids}" == "ge:test-session:1,ge:test-session:2" ]]; then
    _pass "record_gate_event emits unique monotonic event_id values"
  else
    _fail "record_gate_event event_ids=${event_ids} (expected ge:test-session:1,ge:test-session:2)"
  fi
  gate_seq="$(jq -r '.gate_event_seq // "missing"' \
    "${HOME}/.claude/quality-pack/state/test-session/session_state.json" \
    2>/dev/null || echo "parse-error")"
  if [[ "${gate_seq}" == "2" ]]; then
    _pass "record_gate_event durably advances gate_event_seq"
  else
    _fail "record_gate_event gate_event_seq=${gate_seq} (expected 2)"
  fi

  # A valid-looking state counter can lag a surviving ledger after manual
  # restore. The allocator must take max(counter, ledger), not trust syntax.
  printf '%s\n' \
    '{"_v":1,"event_id":"ge:test-session:3","ts":1,"host":"test","gate":"legacy","event":"block","details":{}}' \
    >> "${GATE_EVENTS_FILE}"
  record_gate_event "t1_gate" "t1_event" 2>/dev/null || true
  stale_counter_recovered_id="$(tail -1 "${GATE_EVENTS_FILE}" \
    | jq -r '.event_id // "missing"' 2>/dev/null || echo "parse-error")"
  if [[ "${stale_counter_recovered_id}" == "ge:test-session:4" ]]; then
    _pass "record_gate_event advances past a ledger-newer valid counter"
  else
    _fail "record_gate_event stale-counter recovery=${stale_counter_recovered_id} (expected ge:test-session:4)"
  fi

  # Upgrade/corrupt-state recovery: a missing counter must resume after the
  # largest surviving ID instead of reusing ge:<sid>:1.
  jq 'del(.gate_event_seq)' \
    "${HOME}/.claude/quality-pack/state/test-session/session_state.json" \
    > "${TEST_TMPDIR}/state-without-gate-seq.json"
  mv "${TEST_TMPDIR}/state-without-gate-seq.json" \
    "${HOME}/.claude/quality-pack/state/test-session/session_state.json"
  printf '%s\n' \
    '{"_v":1,"event_id":"ge:test-session:7","ts":1,"host":"test","gate":"legacy","event":"block","details":{}}' \
    >> "${GATE_EVENTS_FILE}"
  record_gate_event "t1_gate" "t1_event" 2>/dev/null || true
  recovered_id="$(tail -1 "${GATE_EVENTS_FILE}" \
    | jq -r '.event_id // "missing"' 2>/dev/null || echo "parse-error")"
  if [[ "${recovered_id}" == "ge:test-session:8" ]]; then
    _pass "record_gate_event recovers sequence after surviving ledger IDs"
  else
    _fail "record_gate_event recovered event_id=${recovered_id} (expected ge:test-session:8)"
  fi

  parallel_pids=""
  for _gate_writer in 1 2 3 4 5 6 7 8; do
    (record_gate_event "parallel" "block" 2>/dev/null) &
    parallel_pids="${parallel_pids} $!"
  done
  for _gate_pid in ${parallel_pids}; do
    wait "${_gate_pid}"
  done
  id_counts="$(jq -s '
    {rows:length,unique:([.[].event_id] | unique | length)}
    | "\(.rows):\(.unique)"
  ' "${GATE_EVENTS_FILE}" 2>/dev/null || echo "parse-error")"
  if [[ "${id_counts}" == "14:14" ]]; then
    _pass "parallel gate-event writers retain unique identities"
  else
    _fail "parallel gate-event identity counts=${id_counts} (expected 14:14)"
  fi

  OMC_GATE_EVENTS_PER_SESSION_MAX=2
  record_gate_event "cap" "block" 2>/dev/null || true
  record_gate_event "cap" "block" 2>/dev/null || true
  record_gate_event "cap" "block" 2>/dev/null || true
  jq 'del(.gate_event_seq)' \
    "${HOME}/.claude/quality-pack/state/test-session/session_state.json" \
    > "${TEST_TMPDIR}/capped-state-without-seq.json"
  mv "${TEST_TMPDIR}/capped-state-without-seq.json" \
    "${HOME}/.claude/quality-pack/state/test-session/session_state.json"
  record_gate_event "cap" "block" 2>/dev/null || true
  capped_ids="$(jq -r '.event_id' "${GATE_EVENTS_FILE}" | paste -sd ',' -)"
  if [[ "${capped_ids}" == "ge:test-session:19,ge:test-session:20" ]]; then
    _pass "capped ledger recovery continues after the largest surviving ID"
  else
    _fail "capped ledger IDs=${capped_ids} (expected ge:test-session:19,ge:test-session:20)"
  fi

  SESSION_ID="resume-target"
  mkdir -p "${HOME}/.claude/quality-pack/state/${SESSION_ID}"
  printf '{}\n' \
    > "${HOME}/.claude/quality-pack/state/${SESSION_ID}/session_state.json"
  cp "${GATE_EVENTS_FILE}" \
    "${HOME}/.claude/quality-pack/state/${SESSION_ID}/gate_events.jsonl"
  record_gate_event "resume" "block" 2>/dev/null || true
  resume_ids="$(jq -r '.event_id' \
    "${HOME}/.claude/quality-pack/state/${SESSION_ID}/gate_events.jsonl" \
    | paste -sd ',' -)"
  if [[ "${resume_ids}" == "ge:test-session:20,ge:resume-target:1" ]]; then
    _pass "resume copy preserves source identity and starts target namespace"
  else
    _fail "resume-copy IDs=${resume_ids}"
  fi
  SESSION_ID="test-session"
  unset OMC_GATE_EVENTS_PER_SESSION_MAX
else
  _fail "record_gate_event produced no output at ${GATE_EVENTS_FILE}"
fi

# --- T2: source-level grep that other ledger writers emit `_v: 1` ---

check_v_emission() {
  local file="$1"
  local label="$2"
  if grep -q '_v[ ]*:[ ]*1' "${file}"; then
    _pass "${label}: emits _v:1 (source assertion)"
  else
    _fail "${label}: no _v:1 emission found in ${file}"
  fi
}

check_v_emission "${SCRIPTS_DIR}/record-serendipity.sh" "record-serendipity.sh"
check_v_emission "${SCRIPTS_DIR}/record-archetype.sh" "record-archetype.sh"
check_v_emission "${SCRIPTS_DIR}/ulw-correct-record.sh" "ulw-correct-record.sh"

# --- T3: timing-row session_summary _v:1 ---
TIMING_LIB="${SCRIPTS_DIR}/lib/timing.sh"
if [[ -f "${TIMING_LIB}" ]] && grep -q '_v[ ]*:[ ]*1' "${TIMING_LIB}"; then
  _pass "lib/timing.sh: emits _v:1 (session_summary)"
else
  _fail "lib/timing.sh: no _v:1 emission (or file missing)"
fi

# --- T4: F-012 close — directive_apply_rate formula documented ---
# show-report.sh:1298 (line drifts; grep) renders the apply-rate formula.
# Confirms the "half-shipped telemetry" pattern is closed for directive cost.
SHOW_REPORT="${SCRIPTS_DIR}/show-report.sh"
if grep -q 'Apply rate = shipped' "${SHOW_REPORT}"; then
  _pass "show-report.sh: directive_apply_rate formula documented (F-012 closed as already-shipped)"
else
  _fail "show-report.sh: 'Apply rate = shipped' string missing — F-012 panel may have regressed"
fi

# --- Summary ---
printf '\n=== schema-versioning: %d passed, %d failed ===\n' "${PASS}" "${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
exit 0
