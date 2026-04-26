#!/usr/bin/env bash
# ulw-pause.sh — flip the ulw_pause_active flag for the current session
# so the session-handoff gate (stop-guard.sh) recognizes the upcoming
# stop as a legitimate user-decision pause rather than a lazy session
# handoff.
#
# Backs the /ulw-pause skill. Closes the user-reported gap from the
# v1.18.0 source note: the session-handoff gate distinguishes nothing
# between "I gave up early" and "the user needs to decide X". This
# script gives the assistant a structured way to declare the latter
# without weakening the gate's protection against the former.
#
# State writes:
#   ulw_pause_active=1            # cleared at next user prompt
#   ulw_pause_count=N+1           # capped at 2 per session
#   ulw_pause_reason=<reason>     # most-recent reason (informational)
#
# Cap: 2 pauses per session (mirrors session-handoff cap). Past the cap
# the script refuses; at that point a stop is structurally a session
# handoff, not a pause, and the assistant should either resume or ask
# the user whether to checkpoint.
#
# Usage:
#   ulw-pause.sh "<reason>"
#
# Exit codes:
#   0 — pause flag set
#   2 — bad invocation (missing reason / no session)
#   3 — pause cap reached (≥ 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

reason="${1:-}"
if [[ -z "${reason//[[:space:]]/}" ]]; then
  printf 'ulw-pause: a non-empty reason is required.\n' >&2
  printf 'usage: ulw-pause.sh "<reason — what user decision are you waiting on?>"\n' >&2
  exit 2
fi

# Reject newlines so the gate-event row stays single-line. Same rule as
# mark-user-decision; multi-line reasons go in the assistant's summary.
if [[ "${reason}" == *$'\n'* ]]; then
  printf 'ulw-pause: reason cannot contain newlines (single-line only).\n' >&2
  exit 2
fi

if [[ -z "${SESSION_ID:-}" ]]; then
  printf 'ulw-pause: no active session (SESSION_ID unset)\n' >&2
  exit 2
fi

PAUSE_CAP=2
current_count="$(read_state "ulw_pause_count" 2>/dev/null || true)"
current_count="${current_count:-0}"

if [[ "${current_count}" -ge "${PAUSE_CAP}" ]]; then
  printf 'ulw-pause: pause cap reached (%d/%d).\n' "${current_count}" "${PAUSE_CAP}" >&2
  printf '  At this point a stop is a session handoff, not a pause. Either resume the\n' >&2
  printf '  work in this session or ask the user explicitly whether to checkpoint.\n' >&2
  exit 3
fi

new_count=$((current_count + 1))

# Use the multi-key atomic helper so the three flags land together —
# stop-guard checks ulw_pause_active, /ulw-status reads the count, and
# the reason is written for audit visibility. A partial write that set
# ulw_pause_active without incrementing the count would let the gate
# pass once but break cap accounting on the next pause.
with_state_lock_batch \
  "ulw_pause_active" "1" \
  "ulw_pause_count" "${new_count}" \
  "ulw_pause_reason" "${reason}"

record_gate_event "ulw-pause" "ulw-pause" \
  "pause_count=${new_count}" \
  "pause_cap=${PAUSE_CAP}" \
  "reason=${reason}"

printf 'ulw-pause: pause %d/%d active for this session.\n' "${new_count}" "${PAUSE_CAP}"
printf '  Reason: %s\n' "${reason}"
printf '  Session-handoff gate will allow your next stop. Surface the decision\n'
printf '  in your summary; the next user prompt clears the pause flag automatically.\n'

exit 0
