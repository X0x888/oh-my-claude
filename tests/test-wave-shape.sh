#!/usr/bin/env bash
# Wave-shape tests (F-013/F-014/F-011/F-012):
#   - is_wave_plan_under_segmented predicate
#   - record-finding-list.sh assign-wave gate-event telemetry (F-011)
#   - record-finding-list.sh assign-wave narrow-wave warning (F-012)
#   - stop-guard.sh discovered-scope cap polarity (F-014)
#
# The stop-guard wave-shape gate (F-013) itself is exercised end-to-end
# via test-e2e-hook-sequence.sh / test-quality-gates.sh; this file
# focuses on the predicate + the assign-wave instrumentation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RFL="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-finding-list.sh"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
export STATE_ROOT="${TEST_STATE_ROOT}"
export SESSION_ID="wave-shape-test-session"
ensure_session_dir
mkdir -p "${STATE_ROOT}/${SESSION_ID}"

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected NOT to contain: %s\n    actual: %s\n' "${label}" "${needle}" "${haystack}" >&2
    fail=$((fail + 1))
  fi
}

reset_findings() {
  rm -f "$(session_file "findings.json")"
  rm -f "$(session_file "gate_events.jsonl")"
}

# Build a findings.json with N findings split into K waves of (N/K) each.
# This is a programmatic builder so each test can dial the shape.
build_plan() {
  local n_findings="$1" n_waves="$2"
  reset_findings

  # Build the bare findings array
  local findings_json='['
  local i
  for ((i = 1; i <= n_findings; i++)); do
    [[ $i -gt 1 ]] && findings_json+=','
    findings_json+=$(printf '{"id":"F-%03d","summary":"f%d","severity":"high","surface":"surface-%d"}' "$i" "$i" "$i")
  done
  findings_json+=']'

  printf '%s' "${findings_json}" | "${RFL}" init >/dev/null 2>&1

  # Distribute findings across waves (round-robin so each wave roughly
  # has n_findings/n_waves findings)
  local per_wave=$((n_findings / n_waves))
  local remainder=$((n_findings % n_waves))
  local cursor=1
  local w
  for ((w = 1; w <= n_waves; w++)); do
    local count=$per_wave
    if [[ $w -le $remainder ]]; then count=$((count + 1)); fi
    local ids=()
    local j
    for ((j = 0; j < count; j++)); do
      ids+=("$(printf 'F-%03d' "${cursor}")")
      cursor=$((cursor + 1))
    done
    "${RFL}" assign-wave "${w}" "${n_waves}" "surface-${w}" "${ids[@]}" >/dev/null 2>&1
  done
}

# ----------------------------------------------------------------------
printf 'Test 1: is_wave_plan_under_segmented — empty/missing returns false\n'

reset_findings
if is_wave_plan_under_segmented; then
  printf '  FAIL: empty plan should NOT be under-segmented\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 2: is_wave_plan_under_segmented — small finding lists exempt\n'

# 4 findings in 4 waves (1/wave) — exempt because total <5
build_plan 4 4
if is_wave_plan_under_segmented; then
  printf '  FAIL: 4 findings in 4 waves should be exempt (total <5)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 3 findings in 3 waves — exempt (total <5)
build_plan 3 3
if is_wave_plan_under_segmented; then
  printf '  FAIL: 3 findings in 3 waves should be exempt\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 3: is_wave_plan_under_segmented — single-wave plans exempt\n'

# 10 findings in 1 wave — exempt regardless of size
build_plan 10 1
if is_wave_plan_under_segmented; then
  printf '  FAIL: 10 findings in 1 wave should be exempt (1-wave plans never under-segmented)\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 4: is_wave_plan_under_segmented — fires on the regression case\n'

# 5 findings in 5 waves (1/wave) — under-segmented (avg=1, total=5, waves=5)
# This is the EXACT v1.21.0 regression pattern.
build_plan 5 5
if is_wave_plan_under_segmented; then
  pass=$((pass + 1))
else
  printf '  FAIL: 5 findings in 5 waves should be under-segmented\n' >&2
  fail=$((fail + 1))
fi

# 10 findings in 5 waves (2/wave) — under-segmented (avg=2 <3)
build_plan 10 5
if is_wave_plan_under_segmented; then
  pass=$((pass + 1))
else
  printf '  FAIL: 10 findings in 5 waves should be under-segmented (avg=2)\n' >&2
  fail=$((fail + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 5: is_wave_plan_under_segmented — substantive plans pass\n'

# 20 findings in 4 waves (5/wave) — substantive (matches THIS regression's wave plan)
build_plan 20 4
if is_wave_plan_under_segmented; then
  printf '  FAIL: 20 findings in 4 waves (avg=5) should NOT be under-segmented\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 15 findings in 5 waves (3/wave) — exactly at the boundary (avg=3, NOT <3)
build_plan 15 5
if is_wave_plan_under_segmented; then
  printf '  FAIL: 15 findings in 5 waves (avg=3 — at boundary, should pass) should NOT fire\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# 9 findings in 3 waves (3/wave) — boundary
build_plan 9 3
if is_wave_plan_under_segmented; then
  printf '  FAIL: 9 findings in 3 waves (avg=3) should NOT be under-segmented\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ----------------------------------------------------------------------
printf 'Test 6: F-011 — assign-wave emits gate_event with finding_count\n'

build_plan 6 2
events_file="$(session_file "gate_events.jsonl")"
assert_eq "gate_events.jsonl exists after assign-wave" "yes" "$([[ -f "${events_file}" ]] && echo yes || echo no)"

if [[ -f "${events_file}" ]]; then
  # Should have 2 wave-assigned events (one per wave)
  wave_assigned_count="$(grep -c '"event":"wave-assigned"' "${events_file}" || true)"
  assert_eq "2 wave-assigned events" "2" "${wave_assigned_count}"

  # Each event must carry finding_count + wave_idx + wave_total. JSON
  # numerics are unquoted; record_gate_event renders integers without
  # string-wrapping.
  if grep -q '"finding_count":3' "${events_file}" \
     && grep -q '"wave_idx":1' "${events_file}" \
     && grep -q '"wave_total":2' "${events_file}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: gate event missing finding_count/wave_idx/wave_total\n' >&2
    printf '  events:\n' >&2
    cat "${events_file}" >&2
    fail=$((fail + 1))
  fi
fi

# ----------------------------------------------------------------------
printf 'Test 7: F-012 — assign-wave emits narrow-wave warning on the regression case\n'

# Build a 5×1 plan (the v1.21.0 regression), capturing stderr.
reset_findings
echo '[
  {"id":"F-001","summary":"a","severity":"high","surface":"a"},
  {"id":"F-002","summary":"b","severity":"high","surface":"b"},
  {"id":"F-003","summary":"c","severity":"high","surface":"c"},
  {"id":"F-004","summary":"d","severity":"high","surface":"d"},
  {"id":"F-005","summary":"e","severity":"high","surface":"e"}
]' | "${RFL}" init >/dev/null

# First wave: cap=5, 1 finding — should warn
warning_output="$("${RFL}" assign-wave 1 5 "surface-a" F-001 2>&1 1>/dev/null || true)"
assert_contains "narrow-wave warning fires on 1-finding wave (total=5)" \
  "WARNING" "${warning_output}"
assert_contains "warning names the canonical bar" \
  "5-10/wave" "${warning_output}"

# Verify gate event captures the warning
events_file="$(session_file "gate_events.jsonl")"
narrow_event_count="$(grep -c '"event":"narrow-wave-warning"' "${events_file}" || true)"
assert_eq "1 narrow-wave-warning event recorded" "1" "${narrow_event_count}"

# ----------------------------------------------------------------------
printf 'Test 8: F-012 — narrow-wave warning is silent on small finding lists\n'

# 3 findings in 3 single-finding waves — total <5, should NOT warn
reset_findings
echo '[
  {"id":"F-100","summary":"x","severity":"high","surface":"x"},
  {"id":"F-101","summary":"y","severity":"high","surface":"y"},
  {"id":"F-102","summary":"z","severity":"high","surface":"z"}
]' | "${RFL}" init >/dev/null

warning_output="$("${RFL}" assign-wave 1 3 "surface-x" F-100 2>&1 1>/dev/null || true)"
assert_not_contains "no warning when total <5" "WARNING" "${warning_output}"

# ----------------------------------------------------------------------
printf 'Test 9: F-012 — substantive waves do not warn\n'

reset_findings
echo '[
  {"id":"F-200","summary":"a","severity":"high","surface":"a"},
  {"id":"F-201","summary":"b","severity":"high","surface":"a"},
  {"id":"F-202","summary":"c","severity":"high","surface":"a"},
  {"id":"F-203","summary":"d","severity":"high","surface":"b"},
  {"id":"F-204","summary":"e","severity":"high","surface":"b"},
  {"id":"F-205","summary":"f","severity":"high","surface":"b"}
]' | "${RFL}" init >/dev/null

warning_output="$("${RFL}" assign-wave 1 2 "surface-a" F-200 F-201 F-202 2>&1 1>/dev/null || true)"
assert_not_contains "no warning when wave has 3 findings" "WARNING" "${warning_output}"

# ----------------------------------------------------------------------
printf 'Test 10: F-014 — read_active_wave_total still returns total wave count regardless of shape\n'

# Helper sanity: read_active_wave_total counts ALL waves, not just substantive ones.
# This guards the cap-polarity fix in stop-guard.sh — it relies on
# is_wave_plan_under_segmented to differentiate, not on read_active_wave_total
# itself filtering.
build_plan 5 5
total_waves="$(read_active_wave_total)"
assert_eq "read_active_wave_total returns 5 even on under-segmented plan" "5" "${total_waves}"

build_plan 20 4
total_waves="$(read_active_wave_total)"
assert_eq "read_active_wave_total returns 4 on substantive plan" "4" "${total_waves}"

# ----------------------------------------------------------------------
printf '\n=== Wave-Shape Tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
