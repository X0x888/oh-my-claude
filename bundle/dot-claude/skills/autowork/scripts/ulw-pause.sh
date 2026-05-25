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
# v1.46-pre — 3-turn attempts gate for case-2 (external blocker) pauses,
# ported from openai/codex `continuation.md`. Reasons matching the
# external-blocker pattern (rate limit, API down, network failure,
# dependency upgrade, 5xx) must observe the same blocker on
# `pause_external_blocker_threshold` (default 3) consecutive attempts
# before the pause is allowed; below threshold the script exits 4 and
# the agent is expected to retry the failing path. Same-blocker
# detection uses normalized-significant-token overlap (≥2 tokens =
# same blocker). Exempt cases (binary blockers — retry doesn't help):
# credentials, destructive shared-state, unfamiliar in-progress state,
# stakeholder/legal/compliance approval, explicit user authorization.
# Gate disabled when threshold=0.
#
# Usage:
#   ulw-pause.sh "<reason>"
#
# Exit codes:
#   0 — pause flag set
#   2 — bad invocation (missing reason / no session / validator-rejected reason)
#   3 — pause cap reached (≥ 2)
#   4 — case-2 external-blocker attempt threshold not yet met (v1.46-pre)

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
_pause_judgment_pattern='\b(taste|aesthetic|aesthetics|look[- ]and[- ]feel|brand[[:space:]]+(voice|style|tone)|design[[:space:]]+direction|naming|library[[:space:]]+(choice|selection|decision)|framework[[:space:]]+(choice|selection|decision)|refactor[[:space:]]+scope|credible[- ]approach|approach[[:space:]]+split|x[- ]vs[- ]y|color|font|copy|data[[:space:]]+retention[[:space:]]+default|(pick|choose|decide)[[:space:]]+(library|framework|approach|option|tool|pattern|color|font|copy|name)|(pick|choose|decide)[^.!]*[[:space:]]+vs[[:space:]]+|[[:space:]]+vs[[:space:]]+[a-zA-Z])\b'
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

# Compute "would the validator reject this reason?" once so the
# refuse path AND the audit path can share the verdict. The force
# override (OMC_ULW_PAUSE_FORCE=1) doesn't change the validator's
# verdict — it just lets the call through. The audit path NEEDS the
# original verdict to know whether to emit a force-bypass event.
_pause_would_reject=false
if [[ "${OMC_ULW_PAUSE_VALIDATOR:-on}" == "on" ]] \
  && grep -Eiq "${_pause_judgment_pattern}" <<<"${reason}" \
  && { ! grep -Eiq "${_pause_operational_pattern}" <<<"${reason}" \
       || ! grep -Eiq "${_pause_externalizing_verb}" <<<"${reason}"; }; then
  _pause_would_reject=true
fi

if [[ "${_pause_would_reject}" == "true" ]] \
  && [[ "${OMC_ULW_PAUSE_FORCE:-}" != "1" ]]; then
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

# v1.42.x audit symmetry: when the force override flips the validator's
# rejection into a pass, emit a distinct force-bypass event AND
# increment a per-session counter so /ulw-status and /ulw-report can
# surface whether the escape valve is being used routinely. Mirrors
# the ulw-skip pattern at ulw-skip-register.sh:121-129.
if [[ "${_pause_would_reject}" == "true" ]] \
  && [[ "${OMC_ULW_PAUSE_FORCE:-}" == "1" ]]; then
  record_gate_event "ulw-pause" "force-bypass" \
    "reason_preview=${reason:0:200}" 2>/dev/null || true
  _pause_force_count="$(read_state "ulw_pause_force_count" 2>/dev/null || true)"
  _pause_force_count="${_pause_force_count:-0}"
  [[ "${_pause_force_count}" =~ ^[0-9]+$ ]] || _pause_force_count=0
  write_state "ulw_pause_force_count" "$((_pause_force_count + 1))" 2>/dev/null || true
fi

# v1.46-pre Codex /goal port — 3-turn attempts gate for case-2 (external
# blocker) pauses. Reasons that name a retry-applicable external blocker
# (rate limit, API down, service unreachable, network failure, dependency
# upgrade, 5xx, connection timeout) must repeat on N consecutive /ulw-pause
# attempts before the pause is allowed. The agent is expected to retry
# between attempts; transient failures self-resolve and the pause is
# never spent.
#
# Pattern intent: classify the reason into case-2 (apply gate) vs other
# (bypass gate). Exempt patterns are evaluated FIRST — a reason naming
# a credential / destructive action / unfamiliar state / stakeholder
# approval / user authorization signal is a binary blocker, retry does
# not help, and the gate does not apply.
_pause_gate_exempt_pattern='\b(credential|credentials|login|password|token|api[- ]?key|oauth|secret|external[[:space:]]+account|destructive|force[- ]push|push[[:space:]]+to[[:space:]]+main|rm[[:space:]]+-rf|drop[[:space:]]+table|prod[[:space:]]+data|untracked|stash(ed)?|unfamiliar|stakeholder[[:space:]]+(approval|decision|authorization)|legal[[:space:]]+(approval|review)|compliance[[:space:]]+(approval|review)|user[[:space:]]+(authorization|approval|confirmation|input|decision))\b'

# External-blocker pattern. Coverage broadened (v1.46-pre quality-review F2)
# to catch real-world phrasings: full 5xx HTTP range, standalone "timing
# out", "queueing"/"stuck"/"stalled"/"hung", and a looser DNS-failing
# match. Outer technical-judgment validator catches non-operational uses
# of generic words like "stuck" before this gate sees them.
# Negated character classes use [^.!] (not [^.!\n]): POSIX ERE does not
# interpret \n as newline inside a class — it literally excludes the
# letter 'n', which kills the dns…failing match because "intermittently"
# contains 'n'. The script rejects newlines in the reason at L50-53,
# so newline-exclusion in the class is unnecessary.
_pause_external_blocker_pattern='\b(rate[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|hit)|api[[:space:]]+(down|dead|unreachable|timeout|timing[[:space:]]+out)|service[[:space:]]+(down|dead|unreachable|unavailable)|infra(structure)?[[:space:]]+(down|dead|unreachable)|5[0-9]{2}|connection[[:space:]]+(refused|reset|timeout)|tim(ing|ed)[[:space:]]+out|network[[:space:]]+(error|down|unreachable|timeout|failure)|dns[[:space:]]+(failure|error|down)|dns[[:space:]][^.!]{0,40}fail(ing|ed|ure)?|dependency[[:space:]]+upgrade|upstream[[:space:]]+(error|down|5[0-9]{2})|queu(e|eing|ed|ing)|stuck|stall(ed|ing)?|hung|hang(ing)?)\b'

PAUSE_EXTERNAL_BLOCKER_THRESHOLD="${OMC_PAUSE_EXTERNAL_BLOCKER_THRESHOLD:-3}"
[[ "${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}" =~ ^[0-9]+$ ]] || PAUSE_EXTERNAL_BLOCKER_THRESHOLD=3

# Stopword list for signature normalization. Built as line-grouped
# concatenation so reviewers can audit one category at a time without
# scanning a 100-word inline alternation (v1.46-pre quality-review F5).
_pause_stopwords='^('
_pause_stopwords+='the|and|but|for|you|are|not|all|any|can|has|had|may|was|who|why|how'
_pause_stopwords+='|its|out|too|now|let|use|did|got|own|see|saw|say|him|her|with|from'
_pause_stopwords+='|that|this|have|been|will|when|cannot|because|while|since|than|then'
_pause_stopwords+='|just|like|over|onto|into|after|before|even|ever|also|much|still|until'
_pause_stopwords+='|where|which|whose|what|whom|here|there|same|each|other|most|both|either|neither'
_pause_stopwords+='|need|needs|needed|trying|tried'
_pause_stopwords+=')$'

# Normalize a blocker reason to a sorted, deduped string of significant
# tokens (lowercase alphanumeric, length ≥ 3, common English stopwords
# removed). Length-3 minimum keeps load-bearing tokens like "api", "dns",
# "503", "502", "504" in the signature while filtering single/double-char
# noise. Used for Jaccard-similarity comparison across attempts.
_normalize_blocker_signature() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 3' \
    | grep -vE "${_pause_stopwords}" \
    | sort -u \
    | tr '\n' ' ' \
    | sed -e 's/ *$//'
}

# Compute Jaccard similarity (|intersection| / |union|) of two whitespace-
# separated, sorted-deduped token signatures, returned as an integer
# percentage 0-100. Used to detect "same blocker" across paraphrasing.
#
# Calibration examples:
#   "api down"      vs "api unreachable"            → 33% (≥30 = same)
#   "rate limit"    vs "rate limit hit again"       → 50% (≥30 = same)
#   "rate limit openai" vs "rate limit anthropic"   → 50% (≥30 = same — both rate-limit)
#   "staging api"   vs "openai api rate limit"      → 17% (<30 = different)
#   "api down"      vs "database migration failing" → 0%
_sig_jaccard_pct() {
  local sig_a="$1" sig_b="$2"
  if [[ -z "${sig_a}" || -z "${sig_b}" ]]; then
    printf '0'
    return
  fi
  # Intentional word-splitting on signature tokens (sorted-deduped, no
  # internal duplicates). shellcheck disable for SC2086 + SC2206.
  local intersection=0 token
  # shellcheck disable=SC2086
  for token in ${sig_a}; do
    [[ " ${sig_b} " == *" ${token} "* ]] && intersection=$((intersection + 1))
  done
  # Word count via array length — cleaner than grep -c (v1.46-pre F6).
  # shellcheck disable=SC2206
  local arr_a=(${sig_a})
  # shellcheck disable=SC2206
  local arr_b=(${sig_b})
  local count_a="${#arr_a[@]}"
  local count_b="${#arr_b[@]}"
  local union=$((count_a + count_b - intersection))
  if [[ "${union}" -le 0 ]]; then
    printf '0'
    return
  fi
  printf '%d' $((intersection * 100 / union))
}

# Defensive: the gate block below mutates session state via
# with_state_lock_batch and depends on SESSION_ID being set (the L153
# guard above protects this today, but a future refactor moving that
# guard would silently break state writes here — v1.46-pre F3).
_gate_threshold_met=""
if [[ "${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}" -gt 0 ]] \
  && [[ -n "${SESSION_ID:-}" ]] \
  && ! grep -Eiq "${_pause_gate_exempt_pattern}" <<<"${reason}" \
  && grep -Eiq "${_pause_external_blocker_pattern}" <<<"${reason}"; then

  _current_sig="$(_normalize_blocker_signature "${reason}")"
  _previous_sig="$(read_state "pause_blocker_signature" 2>/dev/null || true)"
  _previous_attempts="$(read_state "pause_blocker_attempt_count" 2>/dev/null || true)"
  [[ "${_previous_attempts}" =~ ^[0-9]+$ ]] || _previous_attempts=0

  _jaccard_pct="$(_sig_jaccard_pct "${_current_sig}" "${_previous_sig}")"
  # Threshold 30% Jaccard chosen so 2-token signatures with one shared
  # significant token (e.g. "api down" + "api unreachable") match while
  # 3+-token signatures with only one common generic token (e.g.
  # "staging api down" + "openai api rate limit") do not.
  if [[ "${_jaccard_pct}" -ge 30 ]]; then
    _new_attempt=$((_previous_attempts + 1))
  else
    _new_attempt=1
  fi

  if [[ "${_new_attempt}" -lt "${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}" ]]; then
    # Below threshold — persist attempt counter, refuse the pause, leave
    # ulw_pause_active / ulw_pause_count / ulw_pause_reason untouched so
    # the legitimate pause cap is not spent on a refused attempt.
    with_state_lock_batch \
      "pause_blocker_signature" "${_current_sig}" \
      "pause_blocker_attempt_count" "${_new_attempt}"

    record_gate_event "ulw-pause" "external-blocker-threshold-refused" \
      "attempt=${_new_attempt}" \
      "threshold=${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}" \
      "signature=${_current_sig:0:120}" \
      "reason_preview=${reason:0:200}" 2>/dev/null || true

    cat >&2 <<EOF
ulw-pause: external-blocker pause refused — observed ${_new_attempt}/${PAUSE_EXTERNAL_BLOCKER_THRESHOLD} times this session.

Provided: ${reason}

Ported from openai/codex \`continuation.md\` (3-consecutive-turn blocked
threshold). External-blocker pauses (rate limit, dead infra, network
failure, dependency upgrade, 5xx) are RETRY-APPLICABLE — a transient
failure the agent retries twice avoids a wasted pause.

Recovery:
  1. Retry the failing path. The blocker may be transient (flap, DNS
     hiccup, restart, brief 503). Do real work between attempts.
  2. If the SAME blocker repeats, call /ulw-pause again with a reason
     that names the same concept — the counter compares Jaccard
     similarity of significant tokens (≥30% = same blocker). "API down"
     and "API unreachable" match (Jaccard 33%); "staging API down" and
     "staging API timeout" match (Jaccard 50%).
  3. The counter resets when /ulw-pause is called with a substantively
     different blocker (Jaccard <30%), or when the pause is allowed at
     threshold (${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}).
  4. Cases EXEMPT from this gate (binary blockers — retry doesn't help):
       - credentials / login / API key / oauth / secret
       - destructive shared-state action awaiting confirmation
       - unfamiliar in-progress state (untracked / stashed)
       - stakeholder / legal / compliance approval
       - explicit user authorization / decision / input

Override:
  - Disable for this call: OMC_PAUSE_EXTERNAL_BLOCKER_THRESHOLD=0 bash <script>
  - Set in conf:           pause_external_blocker_threshold=<N> (0 disables)
EOF
    exit 4
  fi

  # Threshold met — DEFER the state clear and threshold-met event until
  # AFTER the cap check passes. v1.46-pre quality-review F1 caught the
  # bug: clearing pause_blocker_* here unconditionally meant a third
  # legitimate attempt that hit the pause cap would lose the earned
  # counter AND emit a threshold-met event without a pause actually
  # firing. The flag below carries the verdict; the actual mutation
  # happens once we know the pause is going through.
  _gate_threshold_met=1
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

# Cap check passed → the pause will fire. Commit any deferred
# threshold-met state mutation now (v1.46-pre F1 fix).
if [[ -n "${_gate_threshold_met:-}" ]]; then
  with_state_lock_batch \
    "pause_blocker_signature" "" \
    "pause_blocker_attempt_count" "0"
  record_gate_event "ulw-pause" "external-blocker-threshold-met" \
    "attempt=${_new_attempt}" \
    "threshold=${PAUSE_EXTERNAL_BLOCKER_THRESHOLD}" \
    "signature=${_current_sig:0:120}" 2>/dev/null || true
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
