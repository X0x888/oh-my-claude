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

# --- T1: record_gate_event emits _v:1 ---
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
