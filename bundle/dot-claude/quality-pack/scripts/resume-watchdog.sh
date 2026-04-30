#!/usr/bin/env bash
#
# resume-watchdog.sh — headless resume daemon (Wave 3 of the
# auto-resume harness). Polled by a LaunchAgent (macOS), systemd user
# timer (Linux), or cron at ~2-minute cadence. For each unclaimed
# `resume_request.json` whose rate-limit window has cleared, atomically
# claims via claim-resume-request.sh --watchdog-launch and launches
# `claude --resume <session_id>` in a detached tmux session.
#
# When tmux is not available, the watchdog falls back to emitting an
# OS notification (macOS osascript / Linux notify-send) so the user
# knows a resume is ready, then exits without claiming — the user can
# manually invoke /ulw-resume from their terminal.
#
# Stateless. Idempotent. Cap of 1 launch per invocation (prevents a
# resume storm if multiple sessions rate-limited at once). Per-artifact
# cooldown via the artifact's `last_attempt_ts` field (default 600s)
# prevents repeated launches for the same session within a window.
# Per-artifact attempt cap (3) is enforced by the claim helper.
#
# Privacy: respects is_stop_failure_capture_enabled — opt-out at the
# producer means no artifacts to act on. Also gated by
# is_resume_watchdog_enabled (default off — opt-in via
# `resume_watchdog=on` in oh-my-claude.conf or OMC_RESUME_WATCHDOG=on).
#
# Logging: every tick records gate-events for `/ulw-report` visibility.
# Hooks log goes to ${HOOK_LOG} (~/.claude/quality-pack/state/hooks.log).

set -euo pipefail

# shellcheck source=/dev/null
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

CLAIM_HELPER="${HOME}/.claude/skills/autowork/scripts/claim-resume-request.sh"

# --- guards ---

if ! is_resume_watchdog_enabled; then
  exit 0
fi

if ! is_stop_failure_capture_enabled; then
  exit 0
fi

if [[ ! -x "${CLAIM_HELPER}" ]] && [[ ! -f "${CLAIM_HELPER}" ]]; then
  log_anomaly "resume-watchdog" "claim helper missing at ${CLAIM_HELPER}"
  exit 0
fi

# The watchdog runs as a daemon, not inside any user session. record_gate_event
# is a no-op without a SESSION_ID (per its docstring). Use a synthetic session
# id `_watchdog` (passes validate_session_id; underscore prefix avoids collision
# with any UUID-shaped real session) so telemetry rows land somewhere stable
# and `/ulw-report` can scan a known path.
SYNTHETIC_SESSION_ID="${SESSION_ID:-_watchdog}"
export SESSION_ID="${SYNTHETIC_SESSION_ID}"
ensure_session_dir 2>/dev/null || mkdir -p "${STATE_ROOT}/${SYNTHETIC_SESSION_ID}" 2>/dev/null || true

# --- helpers ---

# Emit a desktop notification. macOS uses osascript; Linux uses
# notify-send. Both fail-soft — the watchdog never errors out on a
# missing notifier, since the gate-event row is the durable signal.
notify_resume_ready() {
  local sid="$1"
  local objective="$2"
  local cwd="$3"
  local title="oh-my-claude resume ready"
  local body
  if [[ -n "${objective}" ]]; then
    body="${cwd}: ${objective}"
  else
    body="${cwd}: rate-limit cleared"
  fi
  if [[ "$(uname 2>/dev/null || echo "")" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    # Escape backslashes and double quotes for AppleScript.
    local body_esc title_esc
    body_esc="${body//\\/\\\\}"; body_esc="${body_esc//\"/\\\"}"
    title_esc="${title//\\/\\\\}"; title_esc="${title_esc//\"/\\\"}"
    osascript -e "display notification \"${body_esc}\" with title \"${title_esc}\"" \
      >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "${title}" "${body}" >/dev/null 2>&1 || true
  fi
}

# Read a numeric field from an artifact, defaulting to 0 on miss.
read_num_field() {
  local path="$1" field="$2"
  local v
  v="$(jq -r "(.${field} // 0) | tostring" "${path}" 2>/dev/null || echo 0)"
  v="${v%%.*}"
  v="${v//[!0-9]/}"
  printf '%s' "${v:-0}"
}

# Read a string field from an artifact.
read_str_field() {
  local path="$1" field="$2"
  jq -r "(.${field} // \"\")" "${path}" 2>/dev/null || true
}

# Spawn `claude --resume <sid> "<prompt>"` in a detached tmux session
# rooted at <cwd>. Returns 0 on launch, non-zero on failure.
launch_in_tmux() {
  local sid="$1"
  local cwd="$2"
  local prompt="$3"

  command -v tmux >/dev/null 2>&1 || return 2
  command -v claude >/dev/null 2>&1 || return 3

  # tmux session names disallow `:` and `.`; sanitize the sid to a
  # 12-char hex slug for the session-name. Bash 3.2-safe.
  local sid_short
  sid_short="$(printf '%s' "${sid}" | tr -c 'a-zA-Z0-9_-' '_' | head -c 24)"
  local sess_name="omc-resume-${sid_short}"

  # Check we don't already have a tmux session named this — if a prior
  # tick launched and the session is still running, skip silently.
  if tmux has-session -t "${sess_name}" 2>/dev/null; then
    return 4
  fi

  # Build the tmux launch command. Single-quote-escape the prompt to
  # survive the shell interpolation tmux performs on the command-string.
  local prompt_esc
  prompt_esc="${prompt//\'/\'\\\'\'}"
  tmux new-session -d -s "${sess_name}" -c "${cwd}" \
    "claude --resume '${sid}' '${prompt_esc}'" >/dev/null 2>&1
}

# --- main loop ---

now_ts="$(now_epoch)"
cooldown_secs="${OMC_RESUME_WATCHDOG_COOLDOWN_SECS:-600}"
total_scanned=0
total_skipped_cooldown=0
total_skipped_future=0
total_skipped_missing_cwd=0
total_skipped_empty=0
total_launched=0
total_notified=0

# Enumerate via the canonical helper. --list returns:
#   <scope>\t<session_id>\t<captured_at_ts>\t<artifact_path>
# one row per claimable artifact.
list_output="$(bash "${CLAIM_HELPER}" --list 2>/dev/null || true)"

if [[ -z "${list_output}" ]]; then
  exit 0
fi

while IFS=$'\t' read -r _scope sid captured_ts artifact_path; do
  # Defensive: skip empty rows (helper may emit a trailing newline).
  [[ -z "${artifact_path}" ]] && continue
  [[ ! -f "${artifact_path}" ]] && continue

  total_scanned=$((total_scanned + 1))

  resets_at="$(read_num_field "${artifact_path}" "resets_at_ts")"
  cwd="$(read_str_field "${artifact_path}" "cwd")"
  origin_sid="$(read_str_field "${artifact_path}" "session_id")"
  last_prompt="$(read_str_field "${artifact_path}" "last_user_prompt")"
  objective="$(read_str_field "${artifact_path}" "original_objective")"
  last_attempt_ts="$(read_num_field "${artifact_path}" "last_attempt_ts")"

  # Cooldown: skip if a prior tick attempted launch within the cooldown
  # window. Lets a launched tmux session run unmolested for at least
  # cooldown_secs before the next retry.
  if [[ "${last_attempt_ts}" -gt 0 ]] \
     && (( now_ts - last_attempt_ts < cooldown_secs )); then
    total_skipped_cooldown=$((total_skipped_cooldown + 1))
    record_gate_event "resume-watchdog" "skipped-cooldown" \
      origin_session="${origin_sid}" \
      seconds_remaining="$(( cooldown_secs - (now_ts - last_attempt_ts) ))"
    continue
  fi

  # Skip if the rate-limit window has not yet cleared (with a 60s
  # safety buffer — relaunching at the exact reset epoch sometimes
  # lands inside the still-active window per platform clock skew).
  if [[ "${resets_at}" -gt 0 ]] && (( resets_at > now_ts - 60 )); then
    total_skipped_future=$((total_skipped_future + 1))
    record_gate_event "resume-watchdog" "skipped-future-reset" \
      origin_session="${origin_sid}" \
      seconds_until_reset="$(( resets_at - now_ts ))"
    continue
  fi

  # Skip if the cwd has gone missing — the relaunched session would
  # fail immediately with a no-such-directory error.
  if [[ -z "${cwd}" ]] || [[ ! -d "${cwd}" ]]; then
    total_skipped_missing_cwd=$((total_skipped_missing_cwd + 1))
    record_gate_event "resume-watchdog" "skipped-missing-cwd" \
      origin_session="${origin_sid}" \
      missing_cwd="${cwd:-EMPTY}"
    continue
  fi

  # Resolve the prompt to replay. Prefer the verbatim last user prompt
  # (carries exhaustive-auth markers and council triggers); fall back
  # to objective; skip if both are empty (helper would refuse anyway).
  prompt="${last_prompt}"
  if [[ -z "${prompt}" ]]; then
    prompt="${objective}"
  fi
  if [[ -z "${prompt}" ]]; then
    total_skipped_empty=$((total_skipped_empty + 1))
    record_gate_event "resume-watchdog" "skipped-empty-payload" \
      origin_session="${origin_sid}"
    continue
  fi

  # tmux is the preferred launch substrate — survives the watchdog
  # process exit, gives the user a path to attach later (`tmux attach
  # -t omc-resume-<sid>`), and avoids the launchd-no-TTY question by
  # running inside a tmux server that owns its own pseudo-tty.
  if command -v tmux >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
    # Atomically claim BEFORE launching. Order is critical: claim first
    # so a parallel watchdog tick or /ulw-resume can't double-launch.
    # If launch fails after claim, the artifact is marked attempted
    # and the cooldown prevents immediate retry.
    if ! bash "${CLAIM_HELPER}" --watchdog-launch "$$" --target "${artifact_path}" >/dev/null 2>&1; then
      record_gate_event "resume-watchdog" "claim-failed" \
        origin_session="${origin_sid}"
      continue
    fi

    if launch_in_tmux "${origin_sid}" "${cwd}" "${prompt}"; then
      total_launched=$((total_launched + 1))
      record_gate_event "resume-watchdog" "launched-tmux" \
        origin_session="${origin_sid}" \
        cwd="${cwd}" \
        scope="${_scope}"
      log_hook "resume-watchdog" "launched-tmux origin=${origin_sid} cwd=${cwd}"

      # Cap: 1 launch per invocation. Other claimable artifacts wait
      # until the next tick (they will not race, because the lock
      # serializes them).
      break
    else
      record_gate_event "resume-watchdog" "tmux-launch-failed" \
        origin_session="${origin_sid}"
      log_hook "resume-watchdog" "tmux-launch-failed origin=${origin_sid}"
    fi
  else
    # No tmux (or claude not on PATH) → notification fallback. Do NOT
    # claim — the user must invoke /ulw-resume manually after seeing
    # the notification, so the claim is single-shot and intentional.
    notify_resume_ready "${origin_sid}" "${objective}" "${cwd}"
    total_notified=$((total_notified + 1))
    record_gate_event "resume-watchdog" "notified-no-tmux" \
      origin_session="${origin_sid}" \
      cwd="${cwd}"
    log_hook "resume-watchdog" "notified origin=${origin_sid} (no tmux)"
    break
  fi
done <<<"${list_output}"

record_gate_event "resume-watchdog" "tick-complete" \
  total_scanned="${total_scanned}" \
  launched="${total_launched}" \
  notified="${total_notified}" \
  skipped_cooldown="${total_skipped_cooldown}" \
  skipped_future="${total_skipped_future}" \
  skipped_missing_cwd="${total_skipped_missing_cwd}" \
  skipped_empty="${total_skipped_empty}"

exit 0
