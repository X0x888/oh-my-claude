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
#   ulw_pause_active=1            # the FLAG is cleared at next user prompt
#                                 # (so the session-handoff gate stops carving
#                                 # the exception); the COUNT below is NOT.
#   ulw_pause_count=N+1           # capped at PAUSE_CAP (2) per SESSION —
#                                 # never resets within a session, regardless
#                                 # of user prompts in between.
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

# v1.42.x stop-guard bypass closure (Bypass-Surface F-003 — preventive
# hardening): reject reasons that name technical-judgment categories
# the agent is supposed to OWN under ULW v1.40.0. The pause carve-out
# is OPERATIONAL-ONLY (credentials, rate limits, dead infra, destructive
# shared-state confirmation, unfamiliar in-progress state) — taste,
# library choice, brand voice, naming, refactor scope, credible-approach
# split are explicitly the agent's call.
#
# Telemetry (last 30 days): only 2 pause events, both legitimately
# operational ("awaiting user authorization to git push --tags") — no
# abuse observed. This validator is preventive: documents the
# operational-only contract at the entry point and surfaces telemetry
# when the agent tries a non-operational reason. Audit-fires the gate
# event whether the call is refused or override'd via
# OMC_ULW_PAUSE_FORCE=1.
#
# Pattern intent: only reject reasons that EXCLUSIVELY name technical
# judgment without ALSO naming an operational signal. "library choice
# blocked by stakeholder approval" PASSES — it names a real external
# blocker. Bare "library choice" REJECTS.
_pause_judgment_pattern='\b(taste|aesthetic|aesthetics|look[- ]and[- ]feel|brand[[:space:]]+(voice|style|tone)|design[[:space:]]+direction|naming|library[[:space:]]+(choice|selection|decision)|framework[[:space:]]+(choice|selection|decision)|refactor[[:space:]]+scope|credible[- ]approach|approach[[:space:]]+split|x[- ]vs[- ]y|color|font|copy|data[[:space:]]+retention[[:space:]]+default|(pick|choose|decide)[[:space:]]+(library|framework|approach|option|tool|pattern|color|font|copy|name)|(pick|choose|decide)[^.!\n]*[[:space:]]+vs[[:space:]]+|[[:space:]]+vs[[:space:]]+[a-zA-Z])\b'
_pause_operational_pattern='\b(credential|credentials|login|password|token|api[- ]?key|oauth|secret|external[[:space:]]+account|third[- ]party|vendor|partner|rate[[:space:]]+limit|quota|api[[:space:]]+(down|dead)|infra(structure)?[[:space:]]+(down|dead)|dependency[[:space:]]+upgrade|destructive|force[- ]push|push[[:space:]]+to[[:space:]]+main|rm[[:space:]]+-rf|drop[[:space:]]+table|prod[[:space:]]+data|untracked|stash(ed)?|unfamiliar|stakeholder[[:space:]]+(approval|decision|authorization)|legal[[:space:]]+(approval|review)|compliance[[:space:]]+(approval|review)|user[[:space:]]+(authorization|approval|confirmation|input|decision))\b'
# v1.42.x quality-reviewer F-5: when judgment-token is present, require
# an externalizing verb (`blocked by` / `awaiting` / `pending` /
# `requires` / `superseded by`) IN ADDITION to the operational signal.
# Pre-fix, "library choice — needs user input" passed because
# `user[[:space:]]+input` matched operationally — but "needs user
# input" is the agent ASKING the user to make a judgment call, which is
# the v1.40.0 anti-pattern. With the externalizing verb required,
# "library choice — blocked by stakeholder approval" passes (real
# external decider) while "library choice — needs user input" rejects
# (agent escaping to non-expert user).
_pause_externalizing_verb='\b(blocked[[:space:]]+by|awaiting|pending|requires?|superseded[[:space:]]+by|tracks?[[:space:]]+to|tracked[[:space:]]+(in|at)|because)\b'

if [[ "${OMC_ULW_PAUSE_VALIDATOR:-on}" == "on" ]] \
  && [[ "${OMC_ULW_PAUSE_FORCE:-}" != "1" ]] \
  && grep -Eiq "${_pause_judgment_pattern}" <<<"${reason}" \
  && { ! grep -Eiq "${_pause_operational_pattern}" <<<"${reason}" \
       || ! grep -Eiq "${_pause_externalizing_verb}" <<<"${reason}"; }; then
  record_gate_event "ulw-pause" "non-operational-refused" \
    "reason_preview=${reason:0:200}" 2>/dev/null || true
  cat >&2 <<EOF
ulw-pause: reason rejected — names technical judgment without an operational signal.

Provided: ${reason}

Under ULW v1.40.0 the agent OWNS technical-judgment calls — library
choice, refactor scope, brand voice, naming, credible-approach split,
taste, design direction, data-retention default. Routing these to a
non-expert user is the failure mode the v1.40.0 contract closes.

The /ulw-pause carve-out is operational-only:
  - credentials / login / password / token / api key / oauth / secret
  - external account / third-party / vendor / partner integration
  - destructive shared state (force-push, push to main, rm -rf, drop
    table, prod data)
  - hard external blocker (rate limit, quota exhausted, api down,
    infra dead, dependency upgrade in flight)
  - unfamiliar in-progress state (untracked files, stashed changes)
  - stakeholder/legal/compliance approval (named external decider)

Recovery:
  1. Pick the option a senior practitioner would defend, name the
     alternative you considered and ruled out in one line, ship. The
     user redirects cheaply if wrong.
  2. If your reason has BOTH a judgment-token AND an operational
     blocker, rephrase to lead with the operational one (e.g.,
     "library choice — blocked by stakeholder approval on framework
     license terms" PASSES because it names the real external blocker).
  3. Last-resort override (audited): \`OMC_ULW_PAUSE_FORCE=1 bash <script>\`.
EOF
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
  printf 'ulw-pause: pause cap reached (%d/%d for this session).\n' "${current_count}" "${PAUSE_CAP}" >&2
  printf '  At this point a stop is structurally a session handoff, not a pause.\n' >&2
  printf '  Options:\n' >&2
  printf '    1. Resume the work in this session (the pause cap is fixed for the\n' >&2
  printf '       lifetime of the session; user prompts do NOT reset it).\n' >&2
  printf '    2. Ask the user explicitly whether to checkpoint — they may want\n' >&2
  printf '       to wrap up the session intentionally.\n' >&2
  printf '    3. If a gate is genuinely blocking and the work is complete, run\n' >&2
  printf '       /ulw-skip <reason> as the one-shot escape valve.\n' >&2
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
printf '  in your summary. The pause flag clears at the next user prompt; the\n'
printf '  count (%d/%d used) is fixed for the lifetime of this session.\n' "${new_count}" "${PAUSE_CAP}"
# Visibility: warn pre-emptively when the user is one pause away from the
# cap so they have agency BEFORE hitting the wall on a future legitimate
# pause. Closes product-lens P1-7 (cap was invisible until exhausted).
if [[ "${new_count}" -ge "${PAUSE_CAP}" ]]; then
  printf '  Note: this is your final pause for the session. The next pause attempt\n'
  printf '        will be denied — consider /mark-deferred for follow-on findings.\n'
fi

exit 0
