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

# Capture the project key (git-remote-first, cwd-hash fallback) so the
# Wave 1 SessionStart resume hint can match the artifact to the correct
# project even when the user resumes from a different worktree or clone
# path. Computed in a subshell so the cd does not affect the rest of
# the hook; failure is silently tolerated (returns empty) — same shape
# as the model_id fallback.
project_key=""
if [[ -n "${record_cwd}" && -d "${record_cwd}" ]]; then
  project_key="$(cd "${record_cwd}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
fi

# Wave 3 chain-depth propagation. When session-start-resume-handoff
# wrote `origin_session_id` + `origin_chain_depth` into state (because
# this session was launched by `claude --resume`), forward them onto
# the new resume_request.json so the watchdog's 3-attempt cap
# accumulates across the chain. The first session in any chain has
# no origin_session_id in state — fall back to the current
# SESSION_ID so the producer always emits a self-consistent record.
origin_session_id="$(read_state "origin_session_id")"
[[ -z "${origin_session_id}" ]] && origin_session_id="${SESSION_ID}"
origin_chain_depth="$(read_state "origin_chain_depth")"
origin_chain_depth="${origin_chain_depth%%.*}"
origin_chain_depth="${origin_chain_depth//[!0-9]/}"
origin_chain_depth="${origin_chain_depth:-0}"

# Atomic write: build the JSON via jq into a tmp file, then mv into place.
# mktemp instead of `${target_file}.tmp.$$` — the $$ form is predictable
# (process PID is enumerable) and a racer can pre-create the path as a
# symlink to redirect the write. mktemp generates 6 random suffix chars
# and uses O_CREAT|O_EXCL semantics; safe TOCTOU primitive across BSD
# and GNU coreutils.
target_file="$(session_file "resume_request.json")"
if ! tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"; then
  log_hook "stop-failure-handler" "warn: mktemp failed for resume_request.json"
  exit 0
fi

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
  --arg project_key "${project_key:-}" \
  --arg origin_session_id "${origin_session_id:-}" \
  --argjson origin_chain_depth "${origin_chain_depth}" \
  --argjson rl_sidecar "${rl_sidecar_json}" \
  '{
    schema_version: 1,
    rate_limited: $rate_limited,
    matcher: $matcher,
    hook_event_name: $event,
    session_id: $session_id,
    cwd: $cwd,
    project_key: (if $project_key == "" then null else $project_key end),
    origin_session_id: (if $origin_session_id == "" then $session_id else $origin_session_id end),
    origin_chain_depth: $origin_chain_depth,
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

# v1.31.0 Wave 1: per-cwd cap on resume_request.json artifacts.
# A user who hits N rate-limits in N days accumulates N artifacts.
# The SessionStart resume-hint surfaces the most-relevant one; the
# rest live on disk and only age out via resume_request_ttl_days
# (default 7d). Sweep older artifacts for the same cwd here so the
# producer-side cap stays atomic with the write. Cap is 3 by default
# (OMC_RESUME_REQUEST_PER_CWD_CAP env override; 0 disables the sweep).
# Honors stop_failure_capture=off implicitly because this code is
# only reached after the producer-side opt-out check above.
_per_cwd_cap="${OMC_RESUME_REQUEST_PER_CWD_CAP:-3}"
if [[ "${_per_cwd_cap}" =~ ^[0-9]+$ ]] \
   && [[ "${_per_cwd_cap}" -gt 0 ]] \
   && [[ -n "${record_cwd}" ]]; then
  # Enumerate other resume_request.json files in STATE_ROOT, filter to
  # the same cwd (exact match), sort by captured_at_ts desc, drop the
  # newest N (kept), and rm the rest. find -newer mtime semantics are
  # unreliable across BSD/GNU; sort the timestamp field within jq for
  # cross-platform correctness. Skips silently on jq/find failures so
  # an extra artifact is harmless — never blocks the producer.
  _state_root="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
  _kept=0
  while IFS= read -r _other_artifact; do
    [[ -z "${_other_artifact}" ]] && continue
    [[ "${_other_artifact}" == "${target_file}" ]] && continue
    [[ ! -f "${_other_artifact}" ]] && continue
    # Match by exact cwd. project_key match would over-aggressively
    # delete cross-worktree artifacts that the user might still want
    # to claim from a sibling checkout.
    _other_cwd="$(jq -r '.cwd // ""' "${_other_artifact}" 2>/dev/null || true)"
    [[ "${_other_cwd}" != "${record_cwd}" ]] && continue
    _kept=$((_kept + 1))
    # Cap counts TOTAL artifacts (the just-written one is always kept,
    # so only (cap - 1) older OTHERS may remain). When _kept reaches
    # cap, the next survivor would push total over the cap → delete.
    if [[ "${_kept}" -ge "${_per_cwd_cap}" ]]; then
      rm -f "${_other_artifact}" 2>/dev/null || true
      log_hook "stop-failure-handler" "per-cwd cap pruned: ${_other_artifact}"
    fi
  done < <(
    find "${_state_root}" -mindepth 2 -maxdepth 2 -name 'resume_request.json' -type f 2>/dev/null \
      | while IFS= read -r _f; do
          _ts="$(jq -r '(.captured_at_ts // 0) | tostring' "${_f}" 2>/dev/null || echo 0)"
          printf '%s\t%s\n' "${_ts}" "${_f}"
        done \
      | sort -rn -t$'\t' -k1,1 \
      | cut -f2-
  )
fi

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
