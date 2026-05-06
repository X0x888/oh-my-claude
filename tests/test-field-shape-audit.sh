#!/usr/bin/env bash
# tests/test-field-shape-audit.sh — regression net for
# show-report.sh --field-shape-audit.
#
# Why this exists. The audit is a runtime field-shape sanity check
# over ~/.claude/quality-pack/gate_events.jsonl that would have
# flagged the 4 leaked Bug B rows in v1.29.0 (state-corruption
# rows whose archive_path field carried prompt-text fragments
# instead of the path-shaped contract). Without a regression net
# proving the audit fires on every contract violation it claims
# to catch, the audit can silently degrade and the lesson goes
# unlearned.
#
# Tests:
#   T1 — clean ledger → exit 0, success message
#   T2 — state-corruption row with non-path archive_path → flagged
#   T3 — state-corruption row with non-numeric recovered_ts → flagged
#   T4 — wave-plan row with non-numeric wave_idx → flagged
#   T5 — finding-status row with unknown finding_status enum → flagged
#   T6 — bias-defense row with unknown directive enum → flagged
#   T7 — Bug B replay: prompt-text fragment in archive_path → flagged
#   T8 — non-typed gate (e.g. quality.block) passes through unflagged
#   T9 — empty ledger → exit 0 with empty-state message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHOW_REPORT="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/show-report.sh"

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
    printf '  FAIL: %s\n    expected to contain=%q\n    actual=%q\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

# Sandbox the audit by pointing HOME at a temp dir; the audit reads
# from $HOME/.claude/quality-pack/gate_events.jsonl. This isolates
# tests from the developer's real ledger.
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
mkdir -p "${TMP_HOME}/.claude/quality-pack"
LEDGER="${TMP_HOME}/.claude/quality-pack/gate_events.jsonl"

# Helper: run the audit with HOME=${TMP_HOME}, capture stdout +
# exit code separately. The audit writes the report to stdout and
# exits 0 (clean) or 1 (violations).
run_audit() {
  local mode="${1:-week}"
  local _rc=0
  HOME="${TMP_HOME}" bash "${SHOW_REPORT}" "${mode}" --field-shape-audit 2>&1 || _rc=$?
  printf '%s\n' "${_rc}"
}

# Helper: write a JSONL row to the ledger.
write_row() {
  printf '%s\n' "$1" >> "${LEDGER}"
}

# ----------------------------------------------------------------------
printf 'T1: clean ledger → audit exits 0 with success message\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"state-corruption","event":"recovered","details":{"archive_path":"/tmp/sess/session_state.json.corrupt.1777640000","recovered_ts":"1777640000"}}'
write_row '{"ts":1777640100,"gate":"wave-plan","event":"wave-assigned","details":{"wave_idx":1,"wave_total":3,"surface":"auth/login","finding_count":5}}'
write_row '{"ts":1777640200,"gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-001","finding_status":"shipped","commit_sha":"abc123"}}'
write_row '{"ts":1777640300,"gate":"bias-defense","event":"directive_fired","details":{"directive":"intent-verify"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T1: exit 0 on clean ledger" "0" "${rc}"
assert_contains "T1: clean banner emitted" "✅ clean" "${output}"
assert_contains "T1: row count surfaced" "Audited 4" "${output}"

# ----------------------------------------------------------------------
printf 'T2: archive_path not ending in .corrupt.<epoch> → flagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"state-corruption","event":"recovered","details":{"archive_path":"/tmp/wrong/path.json","recovered_ts":"1777640000"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T2: exit 1 on archive_path violation" "1" "${rc}"
assert_contains "T2: violation cites field" "archive_path" "${output}"
assert_contains "T2: violation cites contract" "ends in .corrupt" "${output}"

# ----------------------------------------------------------------------
printf 'T3: recovered_ts non-numeric → flagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"state-corruption","event":"recovered","details":{"archive_path":"/tmp/sess/session_state.json.corrupt.1777640000","recovered_ts":"not-a-number"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T3: exit 1 on recovered_ts violation" "1" "${rc}"
assert_contains "T3: violation names ts field" "recovered_ts" "${output}"
assert_contains "T3: violation names epoch shape" "Unix epoch" "${output}"

# ----------------------------------------------------------------------
printf 'T4: wave-plan.wave_idx non-numeric → flagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"wave-plan","event":"wave-assigned","details":{"wave_idx":"abc","wave_total":3,"surface":"x","finding_count":5}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T4: exit 1 on wave_idx violation" "1" "${rc}"
assert_contains "T4: violation cites wave_idx field" "wave_idx" "${output}"

# ----------------------------------------------------------------------
printf 'T5: unknown finding_status enum → flagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"finding-status","event":"finding-status-change","details":{"finding_id":"F-001","finding_status":"bogus_status"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T5: exit 1 on finding_status enum violation" "1" "${rc}"
assert_contains "T5: violation surfaces enum" "shipped,deferred,rejected" "${output}"

# ----------------------------------------------------------------------
printf 'T6: unknown bias-defense directive enum → flagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"bias-defense","event":"directive_fired","details":{"directive":"made-up-directive"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T6: exit 1 on directive enum violation" "1" "${rc}"
assert_contains "T6: violation cites directive field" "directive" "${output}"
assert_contains "T6: violation surfaces offending value" "made-up-directive" "${output}"

# ----------------------------------------------------------------------
printf 'T7: Bug B replay — prompt-text fragment in archive_path → flagged\n'
# Reproduces the EXACT shape of the leaked v1.29.0 → v1.34.0 rows: a
# multi-line user prompt fragment lands in archive_path because
# read_state_keys positional misalignment overflowed key 0 (multi-line
# current_objective) into key 5 (recovered_from_corrupt_archive).
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"state-corruption","event":"recovered","details":{"archive_path":"line two of a multi-line prompt that should never be a path","recovered_ts":"1777640000"}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T7: Bug B replay exits 1" "1" "${rc}"
assert_contains "T7: prompt-text fragment surfaces in violation" "line two" "${output}"

# ----------------------------------------------------------------------
printf 'T8: non-typed gates (e.g. quality.block) pass through unflagged\n'
: > "${LEDGER}"
write_row '{"ts":1777640000,"gate":"quality","event":"block","block_count":1,"block_cap":1,"details":{"reason":"some prose reason that is not enum-shape-checked"}}'
write_row '{"ts":1777640100,"gate":"discovered-scope","event":"block","details":{"file_count":3}}'
write_row '{"ts":1777640200,"gate":"session-handoff","event":"block","details":{}}'
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T8: non-typed gates exit 0" "0" "${rc}"
assert_contains "T8: success banner" "✅ clean" "${output}"

# ----------------------------------------------------------------------
printf 'T9: empty ledger → exit 0 with empty-state message\n'
: > "${LEDGER}"
output="$(HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit 2>&1 || true)"
rc=0
HOME="${TMP_HOME}" bash "${SHOW_REPORT}" all --field-shape-audit >/dev/null 2>&1 || rc=$?
assert_eq "T9: empty ledger exits 0" "0" "${rc}"
assert_contains "T9: empty-state message" "No \`gate_events.jsonl\` ledger" "${output}"

# ----------------------------------------------------------------------
printf '\n=== Field-Shape Audit Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
