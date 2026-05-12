#!/usr/bin/env bash
# test-no-defer-mode.sh — regression coverage for the v1.40.0
# no_defer_mode flag.
#
# The flag closes three deferral call sites under ULW execution intent:
#   1. /mark-deferred (mark-deferred.sh entry guard)
#   2. record-finding-list.sh status <id> deferred
#   3. stop-guard.sh hard-block on findings.json deferred entries
#
# Coverage:
#   T1  — is_no_defer_active: flag on + ULW + execution → active
#   T2  — is_no_defer_active: flag off → inactive
#   T3  — is_no_defer_active: not ULW → inactive
#   T4  — is_no_defer_active: advisory intent → inactive
#   T5  — mark-deferred.sh refused under ULW execution
#   T6  — mark-deferred.sh allowed when no_defer_mode=off
#   T7  — mark-deferred.sh allowed under advisory intent
#   T8  — mark-deferred.sh allowed when not ULW
#   T9  — record-finding-list.sh status deferred refused under ULW
#   T10 — record-finding-list.sh status shipped allowed under ULW
#   T11 — record-finding-list.sh status rejected allowed under ULW (with WHY)
#   T12 — Stop-guard simulation: deferred entry → block, no deferred → allow
#   T13 — Stop-guard simulation: fail-open on missing findings.json
#   T14 — gate-event row written when mark-deferred refused

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../bundle/dot-claude/skills/autowork/scripts/common.sh
source "${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"

pass=0
fail=0

TEST_STATE_ROOT="$(mktemp -d)"
STATE_ROOT="${TEST_STATE_ROOT}"
SESSION_ID="ndm-test-session"
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

# Reset state between tests. workflow_mode reads `is_ultrawork` state key
# (see common.sh:is_ultrawork_mode → workflow_mode); task_intent state
# key drives is_execution_intent_value.
reset_state() {
  rm -f "$(session_file "findings.json")"
  rm -f "$(session_file "discovered_scope.jsonl")"
  rm -f "$(session_file "${STATE_JSON}")"
  rm -f "$(session_file "gate_events.jsonl")"
  printf '{}\n' > "$(session_file "${STATE_JSON}")"
}

set_session_mode() {
  local mode="$1" intent="$2"
  reset_state
  write_state "workflow_mode" "${mode}"
  write_state "task_intent" "${intent}"
}

# Inline simulation of the stop-guard no_defer_mode hard-block. Mirrors
# the block in stop-guard.sh ~line 511 — keep in sync if that gate
# changes. Returns one of: block:<deferred_count>, allow:flag_off,
# allow:not_ulw, allow:non_execution, allow:no_file, allow:no_deferred.
run_no_defer_stop_gate() {
  if ! is_no_defer_active; then
    if [[ "${OMC_NO_DEFER_MODE:-on}" != "on" ]]; then
      printf 'allow:flag_off'; return
    fi
    if ! is_ultrawork_mode; then
      printf 'allow:not_ulw'; return
    fi
    printf 'allow:non_execution'; return
  fi
  local file
  file="$(session_file "findings.json")"
  if [[ ! -f "${file}" ]]; then
    printf 'allow:no_file'; return
  fi
  local count
  count="$(jq -r '[(.findings // [])[] | select(.status == "deferred")] | length' "${file}" 2>/dev/null || printf '0')"
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  if [[ "${count}" -le 0 ]]; then
    printf 'allow:no_deferred'; return
  fi
  printf 'block:%s' "${count}"
}

# Build a synthetic findings.json with the requested deferred count.
build_findings_with_deferred() {
  local deferred="$1"
  local file
  file="$(session_file "findings.json")"
  printf '{"version":1,"created_ts":1000,"updated_ts":1000,"findings":[' > "${file}"
  local first=1
  local i=1
  for ((j=0; j<deferred; j++)); do
    [[ "${first}" -eq 0 ]] && printf ',' >> "${file}" || first=0
    printf '{"id":"F-%03d","summary":"deferred item","severity":"medium","status":"deferred","notes":"blocked by F-042"}' "${i}" >> "${file}"
    i=$((i + 1))
  done
  printf '],"waves":[]}\n' >> "${file}"
}

# Empty discovered_scope.jsonl + one pending row so mark-deferred has
# something to operate on (otherwise it would short-circuit on "no
# pending rows to defer"). Reason text validates under
# OMC_MARK_DEFERRED_STRICT=on regardless of intent.
seed_discovered_scope() {
  local file
  file="$(session_file "discovered_scope.jsonl")"
  printf '{"id":"DS-001","summary":"adv finding","status":"pending","severity":"medium","ts":1000,"source":"product-lens"}\n' > "${file}"
}

DEFER_REASON="blocked by F-042 shipping first"

printf '== test-no-defer-mode ==\n'

# -- is_no_defer_active predicate truth table -----------------------------

# T1 — flag on + ULW + execution → active
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
if is_no_defer_active; then
  pass=$((pass + 1))
else
  printf '  FAIL: T1 — is_no_defer_active should be true under ULW+execution\n' >&2
  fail=$((fail + 1))
fi

# T2 — flag off → inactive
OMC_NO_DEFER_MODE=off
set_session_mode "ultrawork" "execution"
if ! is_no_defer_active; then
  pass=$((pass + 1))
else
  printf '  FAIL: T2 — is_no_defer_active should be false when flag off\n' >&2
  fail=$((fail + 1))
fi

# T3 — not ULW → inactive
OMC_NO_DEFER_MODE=on
set_session_mode "default" "execution"
if ! is_no_defer_active; then
  pass=$((pass + 1))
else
  printf '  FAIL: T3 — is_no_defer_active should be false outside ULW\n' >&2
  fail=$((fail + 1))
fi

# T4 — advisory intent → inactive
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "advisory"
if ! is_no_defer_active; then
  pass=$((pass + 1))
else
  printf '  FAIL: T4 — is_no_defer_active should be false on advisory intent\n' >&2
  fail=$((fail + 1))
fi

# -- mark-deferred.sh entry guard -----------------------------------------

MD="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/mark-deferred.sh"

# T5 — refused under ULW execution
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
seed_discovered_scope
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
assert_eq "T5 — mark-deferred refused under ULW exits 2" "2" "${rc}"
assert_contains "T5 — message names refusal cause" "refused under ULW execution intent" "${out}"

# T6 — allowed when no_defer_mode=off (still subject to strict validator,
# but our reason has a valid WHY)
OMC_NO_DEFER_MODE=off
set_session_mode "ultrawork" "execution"
seed_discovered_scope
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=off bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
assert_eq "T6 — mark-deferred allowed when flag off" "0" "${rc}"

# T7 — allowed under advisory intent (with flag on)
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "advisory"
seed_discovered_scope
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
assert_eq "T7 — mark-deferred allowed under advisory intent" "0" "${rc}"

# T8 — allowed when not ULW (with flag on, execution intent — outside
# ULW mode the flag has no effect by design; defer is still gated by
# strict validator only)
OMC_NO_DEFER_MODE=on
set_session_mode "default" "execution"
seed_discovered_scope
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
assert_eq "T8 — mark-deferred allowed outside ULW" "0" "${rc}"

# -- record-finding-list.sh status deferred guard -------------------------

RFL="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/record-finding-list.sh"

# Initialize a findings.json with one pending finding we can flip status on.
# STATE_ROOT must be passed explicitly because the test harness sets it
# locally (not exported) and `bash "${RFL}" init` runs in a subshell that
# would otherwise default to $HOME/.claude/quality-pack/state.
init_finding() {
  rm -f "$(session_file "findings.json")"
  STATE_ROOT="${STATE_ROOT}" SESSION_ID="${SESSION_ID}" \
    bash "${RFL}" init <<EOF >/dev/null 2>&1 || true
[{"id":"F-001","summary":"x","severity":"high","surface":"core"}]
EOF
}

# T9 — record-finding-list status deferred refused under ULW
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" status F-001 deferred "" "blocked by F-042" 2>&1)" || rc=$?
assert_eq "T9 — finding status=deferred refused under ULW exits 2" "2" "${rc}"
assert_contains "T9 — message names refusal cause" "refused for F=F-001 under ULW execution" "${out}"

# T10 — record-finding-list status shipped allowed under ULW
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" status F-001 shipped "abc1234" "fix landed" 2>&1)" || rc=$?
assert_eq "T10 — finding status=shipped allowed under ULW" "0" "${rc}"

# T11 — record-finding-list status rejected allowed with WHY under ULW
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" status F-001 rejected "" "false positive" 2>&1)" || rc=$?
assert_eq "T11 — finding status=rejected allowed under ULW" "0" "${rc}"

# -- Stop-guard simulation -------------------------------------------------

# T12 — deferred entry in findings.json under ULW → block
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
build_findings_with_deferred 3
result="$(run_no_defer_stop_gate)"
assert_eq "T12a — stop-gate blocks with deferred entries" "block:3" "${result}"
build_findings_with_deferred 0
result="$(run_no_defer_stop_gate)"
assert_eq "T12b — stop-gate allows with no deferred entries" "allow:no_deferred" "${result}"

# T13 — fail-open on missing findings.json under ULW
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
rm -f "$(session_file "findings.json")"
result="$(run_no_defer_stop_gate)"
assert_eq "T13 — stop-gate fails open on missing findings.json" "allow:no_file" "${result}"

# T13b — no_defer guard does not crash when SESSION_ID is unset but
# discoverable. Regression coverage for the reviewer-flagged defect that
# moving the guard above SESSION_ID resolution would have surfaced under
# `set -u` via session_file's bare ${SESSION_ID} reference. Mirrors the
# Test 3b protection in test-mark-deferred.sh.
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
seed_discovered_scope
rc=0
out="$(env -u SESSION_ID STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
assert_eq "T13b — mark-deferred refuses cleanly with unset SESSION_ID (discoverable)" "2" "${rc}"
assert_contains "T13b — refusal message reaches the user (no crash)" "refused under ULW execution intent" "${out}"

# T13c — no_defer guard exits with no-active-session error (not crash)
# when SESSION_ID unset AND no session discoverable.
OMC_NO_DEFER_MODE=on
EMPTY_STATE_ROOT="$(mktemp -d)"
rc=0
out="$(env -u SESSION_ID STATE_ROOT="${EMPTY_STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${MD}" "${DEFER_REASON}" 2>&1)" || rc=$?
rm -rf "${EMPTY_STATE_ROOT}"
assert_eq "T13c — mark-deferred exits 2 with no-session message (not crash)" "2" "${rc}"
assert_contains "T13c — message names 'no active session'" "no active session" "${out}"

# T14 — gate-event row written when mark-deferred refused
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
seed_discovered_scope
rm -f "$(session_file "gate_events.jsonl")"
SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${MD}" "${DEFER_REASON}" >/dev/null 2>&1 || true
events_file="$(session_file "gate_events.jsonl")"
if [[ -f "${events_file}" ]]; then
  refused_count="$(grep -c '"event":"mark-deferred-refused"' "${events_file}" 2>/dev/null || printf '0')"
  assert_eq "T14 — gate-event row recorded on mark-deferred refusal" "1" "${refused_count}"
else
  printf '  FAIL: T14 — gate_events.jsonl not written\n' >&2
  fail=$((fail + 1))
fi

# -- mark-user-decision validator (v1.40.0 Wave 7) ------------------------

# T15 — mark-user-decision rejects taste/policy reasons under ULW execution
# (Reason uses ASCII only — em-dash bytes trip _omc_strip_render_unsafe's tr
# under C locale, which is a pre-existing edge case in the harness's
# rendering layer, not part of this wave's scope.)
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" mark-user-decision F-001 "brand voice call: copy A or copy B" 2>&1)" || rc=$?
assert_eq "T15 — mark-user-decision rejects taste/policy reason under ULW exits 2" "2" "${rc}"
assert_contains "T15 — message names operational-only criterion" "operational-only" "${out}"

# T16 — mark-user-decision accepts a real operational-block reason
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" mark-user-decision F-001 "credentials needed in STRIPE_SECRET_KEY env var" 2>&1)" || rc=$?
assert_eq "T16 — mark-user-decision accepts credentials reason under ULW" "0" "${rc}"

# T17 — mark-user-decision falls through under no_defer_mode=off (legacy)
OMC_NO_DEFER_MODE=off
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=off \
  bash "${RFL}" mark-user-decision F-001 "brand voice call: copy A or copy B" 2>&1)" || rc=$?
assert_eq "T17 — mark-user-decision accepts taste reason under no_defer_mode=off (legacy)" "0" "${rc}"

# T18 — mark-user-decision accepts destructive-shared-state reason under ULW
OMC_NO_DEFER_MODE=on
set_session_mode "ultrawork" "execution"
init_finding
rc=0
out="$(SESSION_ID="${SESSION_ID}" STATE_ROOT="${STATE_ROOT}" OMC_NO_DEFER_MODE=on \
  bash "${RFL}" mark-user-decision F-001 "awaiting confirmation before force-push to main" 2>&1)" || rc=$?
assert_eq "T18 — mark-user-decision accepts destructive-state reason under ULW" "0" "${rc}"

# T19 — predicate accepts known operational shapes
operational_examples=(
  "credentials needed for API access"
  "login required for the third-party service"
  "rate limit hit on upstream API"
  "untracked files in repo — intent unclear"
  "destructive: drop table users awaiting confirmation"
  "external account access for the partner integration"
)
for r in "${operational_examples[@]}"; do
  if omc_reason_names_operational_block "${r}"; then
    pass=$((pass + 1))
  else
    printf '  FAIL: T19 — predicate should accept operational example: %s\n' "${r}" >&2
    fail=$((fail + 1))
  fi
done

# T20 — predicate rejects technical-judgment shapes
judgment_examples=(
  "brand voice — copy A or copy B"
  "library choice between React and Vue"
  "which color for the CTA button"
  "credible-approach split on cache strategy"
  "taste — pick the typography"
)
for r in "${judgment_examples[@]}"; do
  if omc_reason_names_operational_block "${r}"; then
    printf '  FAIL: T20 — predicate should reject technical example: %s\n' "${r}" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done

# -- summary --------------------------------------------------------------

printf '\nResults: %d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
