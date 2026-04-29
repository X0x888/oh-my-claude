#!/usr/bin/env bash
#
# StopFailure hook handler — captures the moment Claude Code terminates the
# session due to a rate cap, billing failure, auth failure, etc., and writes
# a per-session resume_request.json so a future watchdog (Wave 3) or the
# next session-resume can act on the rate-limit window without losing the
# original objective.
#
# Hook output is documented as ignored by Claude Code at this event — this
# script is for side-effect persistence only. Never block, never error.
# Reads the rate_limit_status.json sidecar that statusline.py writes during
# the active session (the StopFailure hook payload itself does not carry
# rate_limits).

set -euo pipefail

HOOK_JSON="$(cat)"

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
MATCHER="$(json_get '.matcher')"
HOOK_EVENT_NAME="$(json_get '.hook_event_name')"
TRANSCRIPT_PATH="$(json_get '.transcript_path')"
HOOK_CWD="$(json_get '.cwd')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

# Honor the stop_failure_capture=off opt-out for shared-machine and
# regulated-codebase users. The artifact contains the original prompt
# and objective verbatim — same privacy surface as auto-memory.
if ! is_stop_failure_capture_enabled; then
  exit 0
fi

ensure_session_dir

if is_hook_debug; then
  debug_file="$(session_file "stop_failure_debug.log")"
  {
    printf '=== StopFailure @ %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "${HOOK_JSON}"
  } >>"${debug_file}" 2>/dev/null || true
fi

# Normalize matcher; treat empty as "unknown" so the row is still useful for
# auditability even if Claude Code drops the matcher field on this event.
matcher_norm="${MATCHER:-unknown}"

if [[ "${matcher_norm}" == "rate_limit" ]]; then
  rate_limited="true"
else
  rate_limited="false"
fi

# Read the sidecar staged by statusline.py during the active session. The
# sidecar exists only on Pro/Max sessions where Claude Code emits rate_limits
# in the statusLine payload.
sidecar_file="$(session_file "rate_limit_status.json")"
if [[ -f "${sidecar_file}" ]] && jq -e . "${sidecar_file}" >/dev/null 2>&1; then
  rl_sidecar_json="$(cat "${sidecar_file}")"
else
  rl_sidecar_json="null"
fi

# Pick the earliest known reset epoch as the canonical resume target. On a
# rate-limited stop, that's the soonest moment a watchdog should re-attempt.
# On a non-rate-limit stop, this is informational only.
resets_at_ts="$(printf '%s' "${rl_sidecar_json}" | jq -r '
  [
    (.five_hour.resets_at_ts // empty),
    (.seven_day.resets_at_ts // empty)
  ]
  | map(select(. != null and . > 0))
  | if length == 0 then "" else (min | tostring) end
' 2>/dev/null || printf '')"

current_objective="$(read_state "current_objective")"
last_user_prompt="$(read_state "last_user_prompt")"
captured_at_ts="$(now_epoch)"

state_cwd="$(read_state "cwd")"
record_cwd="${HOOK_CWD:-${state_cwd}}"

# Atomic write: build the JSON via jq into a tmp file, then mv into place.
target_file="$(session_file "resume_request.json")"
tmp_file="${target_file}.tmp.$$"

# Forward-compat fields for the Wave 3 watchdog: a schema_version so
# additive shape changes don't require a migration of artifacts already
# on disk; a resume_attempts counter the watchdog will increment without
# first having to read-then-rewrite an absent field; and the active
# model_id (if recorded) so a future re-dispatch reuses the same model.
model_id="$(read_state "current_model_id")"

if ! jq -n \
  --argjson rate_limited "${rate_limited}" \
  --arg matcher "${matcher_norm}" \
  --arg event "${HOOK_EVENT_NAME:-StopFailure}" \
  --arg session_id "${SESSION_ID}" \
  --arg cwd "${record_cwd}" \
  --arg transcript "${TRANSCRIPT_PATH:-}" \
  --arg objective "${current_objective:-}" \
  --arg last_prompt "${last_user_prompt:-}" \
  --arg resets_at "${resets_at_ts:-}" \
  --arg captured "${captured_at_ts}" \
  --arg model_id "${model_id:-}" \
  --argjson rl_sidecar "${rl_sidecar_json}" \
  '{
    schema_version: 1,
    rate_limited: $rate_limited,
    matcher: $matcher,
    hook_event_name: $event,
    session_id: $session_id,
    cwd: $cwd,
    transcript_path: $transcript,
    original_objective: $objective,
    last_user_prompt: $last_prompt,
    resets_at_ts: (if $resets_at == "" then null else ($resets_at | tonumber) end),
    captured_at_ts: ($captured | tonumber),
    model_id: (if $model_id == "" then null else $model_id end),
    resume_attempts: 0,
    rate_limit_snapshot: $rl_sidecar
  }' >"${tmp_file}" 2>/dev/null; then
  rm -f "${tmp_file}" 2>/dev/null || true
  log_hook "stop-failure-handler" "warn: failed to compose resume_request.json"
  exit 0
fi

mv -f "${tmp_file}" "${target_file}"

# Record a gate event so /ulw-report can surface stop-failure patterns.
# record_gate_event applies the per-session cap (OMC_GATE_EVENTS_PER_SESSION_MAX,
# default 500) and emits the canonical {ts, gate, event, details} shape that
# show-report.sh / statusline.gate_summary expect.
record_gate_event "stop-failure" "stop-failure-captured" \
  matcher="${matcher_norm}" \
  rate_limited="${rate_limited}" \
  resets_at_ts="${resets_at_ts:-}"

log_hook "stop-failure-handler" "captured matcher=${matcher_norm} rate_limited=${rate_limited} resets_at=${resets_at_ts:-none}"

exit 0
