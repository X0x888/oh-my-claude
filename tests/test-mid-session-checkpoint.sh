#!/usr/bin/env bash
# test-mid-session-checkpoint.sh — v1.41 W4 regression net for the
# MID-SESSION CHECKPOINT directive in prompt-intent-router.sh.
#
# Telemetry showed ~16% of sessions live past 6 hours, often parked
# across idle gaps. Auto-memory wrap-up only fires at session Stop;
# a session killed mid-stretch loses everything since the last write.
# When the user returns after ≥30 min, the router now nudges the
# model to sweep the just-closed stretch for memory-worthy signal
# BEFORE responding to the new prompt.
#
# This test pins:
#   A. Gap below threshold (<30min) — no directive emitted.
#   B. Gap above threshold + execution intent — directive fires; ts stamped.
#   C. Gap above threshold + advisory intent — suppressed (matches
#      auto_memory_skip semantics).
#   D. Throttle: a SECOND prompt within the same idle period does not
#      re-fire the directive (state already stamped).
#   E. Auto-memory off — suppressed (no rule to checkpoint against).
#   F. Flag off — suppressed regardless of gap or intent.
#   G. First-ever prompt (no previous_last_prompt_ts) — no directive.
#   H. New gap after activity: previously-fired session can fire AGAIN
#      after the user activity resets the gap boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUTER="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts/prompt-intent-router.sh"
AUTOWORK="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts"

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
    printf '  FAIL: %s — needle %q not in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s — needle %q UNEXPECTEDLY in output\n' "${label}" "${needle}" >&2
    fail=$((fail + 1))
  fi
}

# Sandbox HOME with all bundle/dot-claude installed
new_sandbox() {
  local d
  d="$(mktemp -d)"
  cp -R "${REPO_ROOT}/bundle/dot-claude/" "${d}/.claude/"
  mkdir -p "${d}/.claude/quality-pack/state"
  printf '%s\n' "${d}"
}

sandbox_cleanup() {
  local d="$1"
  [[ -n "${d}" ]] && [[ -d "${d}" ]] && rm -rf "${d}"
}

# Seed per-session state with previous_last_prompt_ts (so the gap
# computation has something to compare against). Optionally seed the
# last-fired timestamp.
seed_session() {
  local sandbox="$1" session_id="$2" prev_ts="$3" last_fired_ts="${4:-}"
  local sdir="${sandbox}/.claude/quality-pack/state/${session_id}"
  mkdir -p "${sdir}"
  if [[ -n "${last_fired_ts}" ]]; then
    jq -n --arg p "${prev_ts}" --arg f "${last_fired_ts}" \
      '{last_user_prompt_ts:$p, midsession_checkpoint_last_fired_ts:$f}' \
      > "${sdir}/session_state.json"
  else
    jq -n --arg p "${prev_ts}" \
      '{last_user_prompt_ts:$p}' \
      > "${sdir}/session_state.json"
  fi
}

# Invoke the router with a synthesized UserPromptSubmit JSON.
# `cd "${sandbox}"` before invoking — load_conf's Layer-2 walks up
# from $PWD looking for `.claude/oh-my-claude.conf`; without this
# step the test's CWD (typically the repo root) would let the real
# user-level conf at `/Users/<u>/.claude/oh-my-claude.conf` leak in
# as a "project conf" and override the sandbox.
run_router() {
  local sandbox="$1" session_id="$2" prompt="$3"
  ( cd "${sandbox}" && HOME="${sandbox}" bash "${ROUTER}" \
    <<<"$(jq -nc --arg sid "${session_id}" --arg p "${prompt}" \
      '{session_id:$sid, prompt:$p, hook_event_name:"UserPromptSubmit"}')" \
    2>/dev/null ) || true
}

# Extract additionalContext from router stdout (jq returns empty if no
# directive fired and the router exited 0 before emission).
ctx_from_router() {
  jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true
}

CHECKPOINT_NEEDLE="MID-SESSION CHECKPOINT"

# ---------------------------------------------------------------
# Part A: gap below threshold
# ---------------------------------------------------------------
printf 'A. gap below threshold — no fire\n'
SANDBOX="$(new_sandbox)"
SID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
NOW="$(date +%s)"
PREV=$(( NOW - 60 ))  # 1 minute ago
seed_session "${SANDBOX}" "${SID}" "${PREV}"
out="$(run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "A1 1-min gap → no checkpoint directive" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part B: gap above threshold + execution intent — fires
# ---------------------------------------------------------------
printf 'B. gap above threshold + execution intent — fires\n'
SANDBOX="$(new_sandbox)"
SID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))  # 1h ago
seed_session "${SANDBOX}" "${SID}" "${PREV}"
out="$(run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_contains "B1 60-min gap → checkpoint directive fires" "${CHECKPOINT_NEEDLE}" "${ctx}"
assert_contains "B2 directive mentions elapsed time" "60 min" "${ctx}"
# State stamp: midsession_checkpoint_last_fired_ts should be roughly NOW.
STATE_FILE="${SANDBOX}/.claude/quality-pack/state/${SID}/session_state.json"
LAST_FIRED="$(jq -r '.midsession_checkpoint_last_fired_ts // ""' "${STATE_FILE}" 2>/dev/null || true)"
if [[ "${LAST_FIRED}" =~ ^[0-9]+$ ]] && (( LAST_FIRED >= PREV )); then
  pass=$((pass + 1))
else
  printf '  FAIL: B3 midsession_checkpoint_last_fired_ts not stamped (got %q)\n' "${LAST_FIRED}" >&2
  fail=$((fail + 1))
fi
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part C: gap above threshold + advisory intent — suppressed
# ---------------------------------------------------------------
printf 'C. advisory intent — suppressed\n'
SANDBOX="$(new_sandbox)"
SID="cccccccc-cccc-cccc-cccc-cccccccccccc"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))
seed_session "${SANDBOX}" "${SID}" "${PREV}"
# Advisory-shaped prompt — "what do you think" classifies as advisory
out="$(run_router "${SANDBOX}" "${SID}" "what do you think about the parser approach?")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "C1 advisory intent → no checkpoint" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part D: throttle — second prompt in same gap doesn't re-fire
# ---------------------------------------------------------------
printf 'D. throttle — second prompt in same gap suppressed\n'
SANDBOX="$(new_sandbox)"
SID="dddddddd-dddd-dddd-dddd-dddddddddddd"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))
# Seed BOTH prev_ts AND last_fired_ts to simulate "already fired".
# `last_fired_ts >= previous_last_prompt_ts` → throttled.
seed_session "${SANDBOX}" "${SID}" "${PREV}" "${PREV}"
out="$(run_router "${SANDBOX}" "${SID}" "implement next step")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "D1 throttle: same gap → no re-fire" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part E: auto_memory=off — suppressed
# ---------------------------------------------------------------
printf 'E. auto_memory=off — suppressed\n'
SANDBOX="$(new_sandbox)"
SID="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))
seed_session "${SANDBOX}" "${SID}" "${PREV}"
printf 'auto_memory=off\n' > "${SANDBOX}/.claude/oh-my-claude.conf"
out="$(run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "E1 auto_memory=off → no checkpoint" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part F: flag off — suppressed
# ---------------------------------------------------------------
printf 'F. flag off — suppressed\n'
SANDBOX="$(new_sandbox)"
SID="ffffffff-ffff-ffff-ffff-ffffffffffff"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))
seed_session "${SANDBOX}" "${SID}" "${PREV}"
out="$(OMC_MID_SESSION_MEMORY_CHECKPOINT=off run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "F1 flag=off → no checkpoint regardless of gap" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part G: first prompt (no previous_last_prompt_ts) — no fire
# ---------------------------------------------------------------
printf 'G. first prompt — no prior ts → no fire\n'
SANDBOX="$(new_sandbox)"
SID="11111111-1111-1111-1111-111111111111"
# No seed — session_state.json doesn't exist yet (ensure_session_dir
# will create it but it'll be empty)
out="$(run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "G1 first prompt → no checkpoint (no prior ts)" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part H: new gap after activity — fires again
# ---------------------------------------------------------------
printf 'H. new gap after activity — fires again\n'
SANDBOX="$(new_sandbox)"
SID="22222222-2222-2222-2222-222222222222"
NOW="$(date +%s)"
# Simulate: fired 90 minutes ago at T-5400; user typed a follow-up
# prompt 60 min ago (T-3600); now they're typing again. New 60-min
# gap → should fire.
LAST_FIRED=$(( NOW - 5400 ))   # 90 min ago
PREV=$(( NOW - 3600 ))         # 60 min ago (after the previous fire)
seed_session "${SANDBOX}" "${SID}" "${PREV}" "${LAST_FIRED}"
out="$(run_router "${SANDBOX}" "${SID}" "implement the parser fix")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_contains "H1 new gap after activity → fires again" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part H2: throttle edge case — last_fired > prev (post-prev fire)
# ---------------------------------------------------------------
#
# The throttle uses `last_fired_ts >= previous_last_prompt_ts`. The
# strict-equal case is pinned by Part D; this case pins the strict-
# greater case (i.e. the fire timestamp is AFTER the previous prompt's
# timestamp, which happens any time a prompt arrived in the
# same-or-prior gap and updated last_fired before it overwrote
# last_user_prompt_ts). Should suppress identically.
printf 'H2. throttle — last_fired strictly > prev → no fire\n'
SANDBOX="$(new_sandbox)"
SID="33333333-3333-3333-3333-333333333333"
NOW="$(date +%s)"
PREV=$(( NOW - 3600 ))         # 60 min ago
LAST_FIRED=$(( PREV + 1 ))     # 1 sec AFTER prev — strict-greater case
seed_session "${SANDBOX}" "${SID}" "${PREV}" "${LAST_FIRED}"
out="$(run_router "${SANDBOX}" "${SID}" "implement next step")"
ctx="$(printf '%s' "${out}" | ctx_from_router)"
assert_not_contains "H2 last_fired>prev → no re-fire" "${CHECKPOINT_NEEDLE}" "${ctx}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part I: lockstep — the flag is wired at the three coordination sites
# ---------------------------------------------------------------
printf 'I. flag coordination across the three sites\n'
COMMON_SH="${AUTOWORK}/common.sh"
CONF_EXAMPLE="${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example"
OMC_CONFIG="${AUTOWORK}/omc-config.sh"

grep -qE 'mid_session_memory_checkpoint\)' "${COMMON_SH}"        && pass=$((pass+1)) || { printf '  FAIL: I1 common.sh parser missing mid_session_memory_checkpoint\n' >&2; fail=$((fail+1)); }
grep -qE 'OMC_MID_SESSION_MEMORY_CHECKPOINT=' "${COMMON_SH}"      && pass=$((pass+1)) || { printf '  FAIL: I2 common.sh missing default for OMC_MID_SESSION_MEMORY_CHECKPOINT\n' >&2; fail=$((fail+1)); }
grep -qE 'mid_session_memory_checkpoint=' "${CONF_EXAMPLE}"       && pass=$((pass+1)) || { printf '  FAIL: I3 conf.example missing entry\n' >&2; fail=$((fail+1)); }
grep -qE '^mid_session_memory_checkpoint\|' "${OMC_CONFIG}"        && pass=$((pass+1)) || { printf '  FAIL: I4 omc-config.sh emit_known_flags missing row\n' >&2; fail=$((fail+1)); }

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
total=$((pass + fail))
printf '\n%s: %d passed, %d failed (of %d)\n' \
  "$(basename "$0")" "${pass}" "${fail}" "${total}"

[[ "${fail}" -eq 0 ]] || exit 1
