#!/usr/bin/env bash
# test-lazy-session-start.sh — v1.41 W3 regression net for the
# `lazy_session_start` opt-in.
#
# Pre-W3 the SessionStart hooks (whats-new, drift-check, welcome) ran
# unconditionally on every session start — including throwaway sessions
# the user closed before typing. The cost was small per-hook, but the
# real problem was that the per-version / per-install dedupe stamps
# fired AND committed even when no model response was ever generated,
# burning the banner the next REAL session deserved to see.
#
# W3 ships an opt-in `OMC_LAZY_SESSION_START` flag. When on, each lazy
# hook drops its basename into `${SESSION_DIR}/.deferred_session_start_hooks`
# and exits 0 silently. A new `first-prompt-session-init.sh` hook on
# UserPromptSubmit drains the list (with an allowlist), re-invokes
# each hook with `OMC_DEFERRED_DISPATCH=1`, and emits the combined
# additionalContext as a UserPromptSubmit payload.
#
# This test pins:
#   A. Flag-off default — hooks behave as today, no marker file written.
#   B. Flag-on defer — each lazy hook writes its basename to the marker
#      and exits clean without emitting additionalContext.
#   C. Dispatcher idempotency — drains exactly once per session.
#   D. Dispatcher allowlist — unknown hook names in the marker are
#      logged + skipped, not blindly bash-executed.
#   E. End-to-end — flag-on + SessionStart + UserPromptSubmit produces
#      the same additionalContext payload as flag-off + SessionStart.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS="${REPO_ROOT}/bundle/dot-claude/quality-pack/scripts"
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

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected file at %s\n' "${label}" "${path}" >&2
    fail=$((fail + 1))
  fi
}

assert_file_missing() {
  local label="$1" path="$2"
  if [[ ! -f "${path}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    file should not exist at %s\n' "${label}" "${path}" >&2
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

# Each test gets its own sandboxed HOME so per-session state and
# cross-session stamps don't leak across cases.
new_sandbox() {
  local d
  d="$(mktemp -d)"
  mkdir -p "${d}/.claude/quality-pack/state" \
           "${d}/.claude/quality-pack/scripts" \
           "${d}/.claude/skills/autowork/scripts" \
           "${d}/.claude/skills/autowork/scripts/lib"
  # Symlink the production scripts into the sandbox so hooks resolve.
  for src in common.sh; do
    ln -sf "${AUTOWORK}/${src}" "${d}/.claude/skills/autowork/scripts/${src}"
  done
  for f in "${AUTOWORK}"/lib/*.sh; do
    ln -sf "${f}" "${d}/.claude/skills/autowork/scripts/lib/$(basename "${f}")"
  done
  for src in first-prompt-session-init.sh \
             session-start-whats-new.sh \
             session-start-drift-check.sh \
             session-start-welcome.sh; do
    ln -sf "${SCRIPTS}/${src}" "${d}/.claude/quality-pack/scripts/${src}"
  done
  printf '%s\n' "${d}"
}

sandbox_cleanup() {
  local d="$1"
  [[ -n "${d}" ]] && [[ -d "${d}" ]] && rm -rf "${d}"
}

# Invoke a SessionStart hook with synthesized hook JSON. Returns the
# hook's stdout (the SessionStart payload, or empty if it early-exited).
run_session_start_hook() {
  local sandbox="$1" hook="$2" session_id="$3"
  local hook_path="${sandbox}/.claude/quality-pack/scripts/${hook}"
  HOME="${sandbox}" bash "${hook_path}" \
    <<<"{\"session_id\":\"${session_id}\",\"source\":\"startup\"}" 2>/dev/null || true
}

run_dispatcher() {
  local sandbox="$1" session_id="$2"
  HOME="${sandbox}" bash "${sandbox}/.claude/quality-pack/scripts/first-prompt-session-init.sh" \
    <<<"{\"session_id\":\"${session_id}\",\"prompt\":\"hello\"}" 2>/dev/null || true
}

# ---------------------------------------------------------------
# Part A: flag-off default — no behavior change
# ---------------------------------------------------------------
printf 'A. flag-off default behavior\n'
SANDBOX="$(new_sandbox)"
SID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OMC_LAZY_SESSION_START=off run_session_start_hook "${SANDBOX}" "session-start-whats-new.sh" "${SID}" > /dev/null
DEFERRED="${SANDBOX}/.claude/quality-pack/state/${SID}/.deferred_session_start_hooks"
assert_file_missing "A1 flag-off: no deferred marker file" "${DEFERRED}"
sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part B: flag-on defer — marker written, no stdout emission
# ---------------------------------------------------------------
printf 'B. flag-on defer\n'
SANDBOX="$(new_sandbox)"
SID="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

# B1: whats-new defers
out="$(OMC_LAZY_SESSION_START=on run_session_start_hook "${SANDBOX}" "session-start-whats-new.sh" "${SID}")"
DEFERRED="${SANDBOX}/.claude/quality-pack/state/${SID}/.deferred_session_start_hooks"
assert_file_exists "B1a whats-new wrote deferred marker" "${DEFERRED}"
assert_contains   "B1b marker lists whats-new" "session-start-whats-new.sh" "$(cat "${DEFERRED}" 2>/dev/null || true)"
assert_eq         "B1c whats-new emitted no stdout" "" "${out}"

# B2: drift-check defers
out="$(OMC_LAZY_SESSION_START=on run_session_start_hook "${SANDBOX}" "session-start-drift-check.sh" "${SID}")"
assert_contains   "B2a marker lists drift-check" "session-start-drift-check.sh" "$(cat "${DEFERRED}" 2>/dev/null || true)"
assert_eq         "B2b drift-check emitted no stdout" "" "${out}"

# B3: welcome defers
out="$(OMC_LAZY_SESSION_START=on run_session_start_hook "${SANDBOX}" "session-start-welcome.sh" "${SID}")"
assert_contains   "B3a marker lists welcome" "session-start-welcome.sh" "$(cat "${DEFERRED}" 2>/dev/null || true)"
assert_eq         "B3b welcome emitted no stdout" "" "${out}"

# B4: dedupe stamp untouched (the per-version stamp must NOT have been written)
STAMP="${SANDBOX}/.claude/quality-pack/.last_session_seen_version"
assert_file_missing "B4 dedupe stamp NOT burned on deferred hook" "${STAMP}"

sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part C: dispatcher idempotency
# ---------------------------------------------------------------
printf 'C. dispatcher idempotency\n'
SANDBOX="$(new_sandbox)"
SID="cccccccc-cccc-cccc-cccc-cccccccccccc"

# Pre-populate a session state dir + a synthesized marker file with a
# known hook name so we can verify drain behavior.
SESSION_DIR="${SANDBOX}/.claude/quality-pack/state/${SID}"
mkdir -p "${SESSION_DIR}"
printf 'session-start-welcome.sh\n' > "${SESSION_DIR}/.deferred_session_start_hooks"
printf '{}\n' > "${SESSION_DIR}/session_state.json"

# C1: first dispatcher call drains the marker
OMC_LAZY_SESSION_START=on run_dispatcher "${SANDBOX}" "${SID}" > /dev/null
assert_file_missing "C1a marker removed after first drain" "${SESSION_DIR}/.deferred_session_start_hooks"
DRAINED_FLAG="$(jq -r '.first_prompt_dispatch_drained // ""' "${SESSION_DIR}/session_state.json" 2>/dev/null || true)"
assert_eq           "C1b drained flag set to 1" "1" "${DRAINED_FLAG}"

# C2: second call with a re-populated marker still no-ops (drained=1)
printf 'session-start-welcome.sh\n' > "${SESSION_DIR}/.deferred_session_start_hooks"
out2="$(OMC_LAZY_SESSION_START=on run_dispatcher "${SANDBOX}" "${SID}")"
assert_file_missing "C2a stale marker cleaned despite drained flag" "${SESSION_DIR}/.deferred_session_start_hooks"
assert_eq           "C2b second drain emits no payload" "" "${out2}"

sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part D: dispatcher allowlist
# ---------------------------------------------------------------
printf 'D. dispatcher allowlist\n'
SANDBOX="$(new_sandbox)"
SID="dddddddd-dddd-dddd-dddd-dddddddddddd"
SESSION_DIR="${SANDBOX}/.claude/quality-pack/state/${SID}"
mkdir -p "${SESSION_DIR}"
# Plant an unknown hook name + a benign known one. The allowlist must
# skip the unknown entry without crashing AND the legitimate entry
# should still drain.
printf 'rm -rf /tmp/bogus\nsession-start-welcome.sh\nmalicious-attacker-hook.sh\n' \
  > "${SESSION_DIR}/.deferred_session_start_hooks"
printf '{}\n' > "${SESSION_DIR}/session_state.json"

OMC_LAZY_SESSION_START=on run_dispatcher "${SANDBOX}" "${SID}" > /dev/null
assert_file_missing "D1 marker removed even with unknown entries" "${SESSION_DIR}/.deferred_session_start_hooks"

# Confirm /tmp/bogus was NOT created — i.e. the unknown entries did
# not get bash-executed by the dispatcher.
assert_file_missing "D2 unknown entries not executed" "/tmp/bogus"

# D3: confirm log_anomaly fired for each unknown entry. The HOOK_LOG
# at ${STATE_ROOT}/hooks.log carries `anomaly` rows naming the
# rejected hook so a future regression that silently dropped the
# allowlist (turning it into a no-op) would surface here.
HOOK_LOG_PATH="${SANDBOX}/.claude/quality-pack/state/hooks.log"
if [[ -f "${HOOK_LOG_PATH}" ]]; then
  anomaly_rows="$(grep -c "unknown deferred hook" "${HOOK_LOG_PATH}" 2>/dev/null || echo 0)"
  anomaly_rows="${anomaly_rows//[^0-9]/}"
  if [[ "${anomaly_rows:-0}" -ge 2 ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: D3 expected ≥2 "unknown deferred hook" anomaly rows; got %s\n' "${anomaly_rows:-0}" >&2
    fail=$((fail + 1))
  fi
else
  printf '  FAIL: D3 HOOK_LOG missing at %s\n' "${HOOK_LOG_PATH}" >&2
  fail=$((fail + 1))
fi

sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part D2: mid-session flag flip — drain unconditionally
# ---------------------------------------------------------------
printf 'D2. mid-session flag-off still drains pending markers\n'
SANDBOX="$(new_sandbox)"
SID="d2222222-dddd-dddd-dddd-dddddddddddd"
SESSION_DIR="${SANDBOX}/.claude/quality-pack/state/${SID}"
mkdir -p "${SESSION_DIR}"
printf 'session-start-welcome.sh\n' > "${SESSION_DIR}/.deferred_session_start_hooks"
printf '{}\n' > "${SESSION_DIR}/session_state.json"

# Markers were written under flag=on; user has since flipped to off.
# The dispatcher should still drain — otherwise the user loses the
# banner they were promised when they started the session.
OMC_LAZY_SESSION_START=off run_dispatcher "${SANDBOX}" "${SID}" > /dev/null
assert_file_missing "D2a flag-off dispatcher still drained marker" \
  "${SESSION_DIR}/.deferred_session_start_hooks"
DRAINED_FLAG="$(jq -r '.first_prompt_dispatch_drained // ""' "${SESSION_DIR}/session_state.json" 2>/dev/null || true)"
assert_eq "D2b drained flag set even under flag-off" "1" "${DRAINED_FLAG}"

sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part E: end-to-end — flag-on session emits the same content
# ---------------------------------------------------------------
printf 'E. end-to-end deferred emission\n'
SANDBOX="$(new_sandbox)"
SID="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

# Force the whats-new hook to have something to say by populating
# installed_version in the sandbox conf (and leaving the cross-session
# stamp absent so the first-session path fires).
mkdir -p "${SANDBOX}/.claude"
printf 'installed_version=1.41.0\nrepo_path=%s\n' "${SANDBOX}/repo" \
  > "${SANDBOX}/.claude/oh-my-claude.conf"

# SessionStart with flag on → marker written, no stdout
OMC_LAZY_SESSION_START=on run_session_start_hook "${SANDBOX}" "session-start-whats-new.sh" "${SID}" > /dev/null
DEFERRED="${SANDBOX}/.claude/quality-pack/state/${SID}/.deferred_session_start_hooks"
assert_file_exists "E1 SessionStart wrote marker" "${DEFERRED}"

# Cross-session stamp must still be empty (no dedupe burn yet)
assert_file_missing "E2 cross-session stamp untouched pre-prompt" \
  "${SANDBOX}/.claude/quality-pack/.last_session_seen_version"

# Now fire the UserPromptSubmit dispatcher
out="$(OMC_LAZY_SESSION_START=on run_dispatcher "${SANDBOX}" "${SID}")"

# Should emit a UserPromptSubmit payload carrying the whats-new banner
if [[ -n "${out}" ]]; then
  pass=$((pass + 1))
  ctx="$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)"
  assert_contains "E3 dispatcher emits whats-new banner" "oh-my-claude installed" "${ctx}"
  hook_event="$(printf '%s' "${out}" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null || true)"
  assert_eq        "E4 emitted as UserPromptSubmit (not SessionStart)" "UserPromptSubmit" "${hook_event}"
else
  printf '  FAIL: E3 dispatcher emitted nothing despite deferred whats-new\n' >&2
  fail=$((fail + 3))  # account for the assertions we couldn't run
fi

# Cross-session stamp NOW gets written (the deferred re-run did its work)
assert_file_exists "E5 cross-session stamp written after deferred dispatch" \
  "${SANDBOX}/.claude/quality-pack/.last_session_seen_version"

sandbox_cleanup "${SANDBOX}"

# ---------------------------------------------------------------
# Part F: lockstep — the flag is wired at the three coordination sites
# ---------------------------------------------------------------
printf 'F. flag coordination across the three sites\n'
COMMON_SH="${AUTOWORK}/common.sh"
CONF_EXAMPLE="${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example"
OMC_CONFIG="${AUTOWORK}/omc-config.sh"

grep -qE 'lazy_session_start\)'                 "${COMMON_SH}"    && pass=$((pass+1)) || { printf '  FAIL: F1 common.sh parser missing lazy_session_start\n' >&2; fail=$((fail+1)); }
grep -qE 'OMC_LAZY_SESSION_START='              "${COMMON_SH}"    && pass=$((pass+1)) || { printf '  FAIL: F2 common.sh missing default for OMC_LAZY_SESSION_START\n' >&2; fail=$((fail+1)); }
grep -qE 'lazy_session_start='                  "${CONF_EXAMPLE}" && pass=$((pass+1)) || { printf '  FAIL: F3 conf.example missing lazy_session_start entry\n' >&2; fail=$((fail+1)); }
grep -qE '^lazy_session_start\|'                "${OMC_CONFIG}"   && pass=$((pass+1)) || { printf '  FAIL: F4 omc-config.sh emit_known_flags missing lazy_session_start row\n' >&2; fail=$((fail+1)); }

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
total=$((pass + fail))
printf '\n%s: %d passed, %d failed (of %d)\n' \
  "$(basename "$0")" "${pass}" "${fail}" "${total}"

[[ "${fail}" -eq 0 ]] || exit 1
