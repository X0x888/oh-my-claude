#!/usr/bin/env bash
# test-self-audit-nudge.sh — regression net for the `self_audit_nudge`
# conf flag + session-start-self-audit-nudge.sh (v1.48-pre).
#
# CONTRIBUTING.md documents a quarterly `/council --self-audit` cadence
# that nothing enforces or reminds anyone about. This hook reads
# ~/.claude/quality-pack/last-self-audit.json ({"ts": <epoch>} — missing
# means "never") and emits a one-shot additionalContext nudge when the
# last audit is >90 days old (or never) AND the nudge itself has not
# fired in the last 7 days.
#
# Covers:
#   1. never-audited                 -> nudge fires once, additionalContext present
#   2. audit stale but nudged <7d ago -> silent (re-nudge window)
#   3. fresh audit recorded          -> silent (not stale)
#   4. flag off                      -> silent even when never-audited
#   5. per-session idempotency       -> second SessionStart fire in the
#      same session is silent even though the underlying condition is
#      still stale (matches whats-new/drift-check/watchdog-health)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/session-start-self-audit-nudge.sh"

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

declare -a _cleanup_dirs=()
_cleanup() {
  local d
  for d in ${_cleanup_dirs[@]+"${_cleanup_dirs[@]}"}; do
    rm -rf "${d}"
  done
}
trap _cleanup EXIT

# Fresh sandbox HOME with the real autowork/scripts tree symlinked in
# at the standard install path — mirrors test-watchdog-health.sh.
new_sandbox_home() {
  local home="$1"
  mkdir -p "${home}/.claude/quality-pack" "${home}/.claude/skills"
  ln -s "${REPO_ROOT}/bundle/dot-claude/skills/autowork" "${home}/.claude/skills/autowork"
}

run_hook() {
  local home="$1" sid="$2"
  local input
  input="$(printf '{"session_id":"%s","source":"startup"}' "${sid}")"
  printf '%s' "${input}" \
    | env -u OMC_SELF_AUDIT_NUDGE HOME="${home}" OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 \
        bash "${HOOK}" 2>/dev/null \
    || true
}

now_ts() { date +%s; }

# ---------------------------------------------------------------------
printf 'Test 1: never-audited -> nudge fires once, additionalContext present\n'
_h1="$(mktemp -d)"; _cleanup_dirs+=("${_h1}")
new_sandbox_home "${_h1}"
out1="$(run_hook "${_h1}" "t1")"
assert_contains "T1: additionalContext present" "hookSpecificOutput" "${out1}"
assert_contains "T1: message names the self-audit staleness" "Self-audit" "${out1}"
assert_contains "T1: message points at /council --self-audit" "/council --self-audit" "${out1}"
assert_contains "T1: message names the manual completion recorder" "record-self-audit.sh" "${out1}"

_t1_audit_file="${_h1}/.claude/quality-pack/last-self-audit.json"
if [[ -f "${_t1_audit_file}" ]]; then
  pass=$((pass + 1))
  _t1_nudge_ts="$(jq -r '.last_self_audit_nudge_ts // 0' "${_t1_audit_file}")"
  if [[ "${_t1_nudge_ts}" =~ ^[0-9]+$ ]] && (( _t1_nudge_ts > 0 )); then
    pass=$((pass + 1))
  else
    printf '  FAIL: T1: last_self_audit_nudge_ts must be stamped after emit\n' >&2
    fail=$((fail + 1))
  fi
  _t1_audit_ts="$(jq -r '.ts // "absent"' "${_t1_audit_file}")"
  assert_eq "T1: audit ts stays absent (never fabricates a completion it did not observe)" "absent" "${_t1_audit_ts}"
else
  printf '  FAIL: T1: last-self-audit.json must be written after the nudge fires\n' >&2
  fail=$((fail + 1))
fi

_t1_session_state="$(find "${_h1}/.claude/quality-pack/state" -maxdepth 2 -name session_state.json 2>/dev/null | head -1)"
if [[ -n "${_t1_session_state}" ]]; then
  _t1_flag="$(jq -r '.self_audit_nudge_emitted // ""' "${_t1_session_state}" 2>/dev/null)"
  assert_eq "T1: per-session self_audit_nudge_emitted flag written" "1" "${_t1_flag}"
else
  printf '  FAIL: T1: session_state.json not found under state root\n' >&2
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 2: audit stale but nudged <7 days ago -> silent (re-nudge window)\n'
_h2="$(mktemp -d)"; _cleanup_dirs+=("${_h2}")
new_sandbox_home "${_h2}"
_h2_audit_file="${_h2}/.claude/quality-pack/last-self-audit.json"
_very_stale_ts=$(( $(now_ts) - (200 * 86400) ))
_recent_nudge_ts=$(( $(now_ts) - (1 * 86400) ))
jq -nc --argjson ts "${_very_stale_ts}" --argjson nts "${_recent_nudge_ts}" \
  '{ts: $ts, last_self_audit_nudge_ts: $nts}' > "${_h2_audit_file}"
out2="$(run_hook "${_h2}" "t2")"
assert_eq "T2: silent — re-nudge window not yet elapsed" "" "${out2}"

# ---------------------------------------------------------------------
printf 'Test 3: fresh audit recorded -> silent (not stale)\n'
_h3="$(mktemp -d)"; _cleanup_dirs+=("${_h3}")
new_sandbox_home "${_h3}"
_h3_audit_file="${_h3}/.claude/quality-pack/last-self-audit.json"
jq -nc --argjson ts "$(now_ts)" '{ts: $ts}' > "${_h3_audit_file}"
out3="$(run_hook "${_h3}" "t3")"
assert_eq "T3: silent — audit is fresh" "" "${out3}"

# ---------------------------------------------------------------------
printf 'Test 4: flag off -> silent even when never-audited\n'
_h4="$(mktemp -d)"; _cleanup_dirs+=("${_h4}")
new_sandbox_home "${_h4}"
printf 'self_audit_nudge=off\n' > "${_h4}/.claude/oh-my-claude.conf"
out4="$(run_hook "${_h4}" "t4")"
assert_eq "T4: silent — flag off" "" "${out4}"
if [[ -f "${_h4}/.claude/quality-pack/last-self-audit.json" ]]; then
  printf '  FAIL: T4: last-self-audit.json must not be created/modified when the flag is off\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------
printf 'Test 5: per-session idempotency — second fire in the same session is silent\n'
_h5="$(mktemp -d)"; _cleanup_dirs+=("${_h5}")
new_sandbox_home "${_h5}"
first5="$(run_hook "${_h5}" "t5-same-session")"
assert_contains "T5a: first fire nudges" "Self-audit" "${first5}"
second5="$(run_hook "${_h5}" "t5-same-session")"
assert_eq "T5b: second fire (same session_id) is silent" "" "${second5}"

# A DIFFERENT session, still within the 7-day re-nudge window, must ALSO
# stay silent — proves the second run's silence in T5b is the intended
# cross-session re-nudge suppression, not merely the per-session guard.
third5="$(run_hook "${_h5}" "t5-different-session")"
assert_eq "T5c: a later session within the re-nudge window is also silent" "" "${third5}"

# ---------------------------------------------------------------------
printf '\n=== Results: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
