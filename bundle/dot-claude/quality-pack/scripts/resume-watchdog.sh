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
if ! ensure_session_dir 2>/dev/null \
    && ! mkdir -p "${STATE_ROOT}/${SYNTHETIC_SESSION_ID}" 2>/dev/null; then
  # STATE_ROOT itself is unwritable (read-only mount, missing parent,
  # permissions). Telemetry rows from this tick will silently no-op
  # in record_gate_event — surface the cause to stderr so a launchd /
  # systemd / cron stdout-capture file shows the reason. The watchdog
  # can still serve a useful tick (notify the user) without telemetry,
  # so we degrade rather than abort.
  printf 'resume-watchdog: STATE_ROOT %s is not writable; telemetry disabled this tick\n' \
    "${STATE_ROOT}" >&2
fi

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

# Verify a path is owned by the current uid. An attacker who can write
# under STATE_ROOT (e.g., shared-machine peer, restored-from-backup
# stale artifact, or a synced .claude/ directory) could otherwise drop
# a hostile resume_request.json with a `cwd` pointing at an attacker-
# controlled directory. The resumed `claude` would then inherit that
# cwd's environment (.envrc, .git/config with includeIf, etc.), giving
# the attacker effective code execution at the moment the watchdog
# launches. Pair with find_claimable_resume_requests symlink rejection.
# Returns 0 when target exists and uid matches; non-zero otherwise.
_cwd_owned_by_self() {
  local target="$1"
  local owner_uid
  # GNU stat -c first (per the v1.28.1 portability pattern); falls
  # through cleanly to BSD stat -f when -c is rejected (macOS).
  owner_uid="$(stat -c %u "${target}" 2>/dev/null)" || owner_uid=""
  if [[ -z "${owner_uid}" ]]; then
    owner_uid="$(stat -f %u "${target}" 2>/dev/null)" || owner_uid=""
  fi
  # Three-valued return so a sysadmin debugging "why didn't my
  # legitimate session resume?" can distinguish stat-failure (exotic
  # filesystem, unmounted between read and check) from foreign-
  # ownership (the actual security signal). Conflating them sent
  # debuggers down the wrong investigation path.
  #   0 → owned by self
  #   1 → owned by another uid
  #   2 → stat failed (unknown owner)
  if [[ -z "${owner_uid}" ]]; then
    return 2
  fi
  if [[ "${owner_uid}" == "$(id -u)" ]]; then
    return 0
  fi
  return 1
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

  # Validate the JSON-derived session_id before any use. The producer
  # (find_claimable_resume_requests in common.sh) only validates the
  # parent directory name; the artifact's internal `.session_id` field
  # is read raw via read_str_field. An attacker who can write a hostile
  # resume_request.json could otherwise inject a crafted sid into the
  # tmux session-name slug or the `claude --resume` argv. validate_
  # session_id allows only canonical UUID and synthetic _watchdog forms.
  if ! validate_session_id "${sid}"; then
    log_anomaly "resume-watchdog" "rejecting launch: invalid session_id from artifact: ${sid:0:60}"
    return 5
  fi

  # tmux session names disallow `:` and `.`; sanitize the sid to a
  # 24-char slug for the session-name. Bash 3.2-safe. tr replaces every
  # non-allowed byte (including any multi-byte sequences) with `_`, so
  # the post-tr output is pure ASCII; `${var:0:24}` then truncates by
  # character (== byte at this point). Avoids `head -c 24` because
  # `head -c` is non-POSIX and behaves inconsistently on minimal
  # coreutils variants the daemon may encounter under launchd/systemd.
  local sid_short
  sid_short="$(printf '%s' "${sid}" | tr -c 'a-zA-Z0-9_-' '_')"
  sid_short="${sid_short:0:24}"
  local sess_name="omc-resume-${sid_short}"

  # Check we don't already have a tmux session named this — if a prior
  # tick launched and the session is still running, skip silently.
  if tmux has-session -t "${sess_name}" 2>/dev/null; then
    return 4
  fi

  # Pass the command as separate argv tokens after `--`. tmux's
  # cmd_stringify_argv internally shell-escapes each token via
  # args_escape() before joining for sh -c, so this is safe against
  # shell metacharacters in `${prompt}` — including embedded `'`, `"`,
  # `$`, `` ` ``, `&`, `|`, `;`, and tmux format-string sequences. A
  # prior implementation interpolated a single command-string with
  # hand-rolled single-quote escaping; while the escape pattern was
  # correct in isolation, the surface was fragile against future edits
  # and exposed any subtle escape bug to direct shell injection.
  tmux new-session -d -s "${sess_name}" -c "${cwd}" -- \
    claude --resume "${sid}" "${prompt}" >/dev/null 2>&1
}

# Revert a watchdog claim when the post-claim launch fails. Without this,
# `last_attempt_ts=now` plus `resume_attempts++` would block retry for
# `cooldown_secs` (default 600s) — a silent 10-minute black hole on a
# host where tmux is on PATH but cannot start a new session (TMUX_TMPDIR
# unwritable, $TMPDIR full, signal trap, launchd no-TTY edge case, etc.).
# Restores `resumed_at_ts: null`, the prior `resume_attempts` count, and
# the prior `last_attempt_ts` so the next tick re-evaluates this artifact
# from a clean slate. Runs under the same cross-session lock the claim
# helper used so a concurrent /ulw-resume cannot race the revert.
revert_watchdog_claim() {
  local target="$1"
  local prev_attempts="$2"
  local prev_last_ts="$3"
  with_resume_lock _do_watchdog_revert "${target}" "${prev_attempts}" "${prev_last_ts}"
}

# shellcheck disable=SC2329 # invoked indirectly via with_resume_lock
_do_watchdog_revert() {
  local target="$1"
  local prev_attempts="$2"
  local prev_last_ts="$3"
  local tmp jq_err

  [[ -f "${target}" ]] || return 0
  tmp="$(mktemp "${target}.XXXXXX")" || return 1

  # Capture jq stderr so a malformed-artifact failure surfaces in
  # log_anomaly with the actual cause. `2>&1 >"${tmp}"` puts stderr
  # in the $() capture and stdout in tmp — the order matters; reversing
  # the redirections collapses both streams into the capture and breaks
  # the diff write.
  if [[ "${prev_last_ts}" -gt 0 ]]; then
    if ! jq_err="$(jq --argjson n "${prev_attempts}" --argjson t "${prev_last_ts}" \
         '. + {resumed_at_ts: null, resume_attempts: $n, last_attempt_ts: $t,
               last_attempt_outcome: "tmux-launch-reverted"}' \
         "${target}" 2>&1 >"${tmp}")"; then
      rm -f "${tmp}"
      log_anomaly "resume-watchdog" "revert jq failed for ${target}: ${jq_err:-no stderr}"
      return 1
    fi
  else
    if ! jq_err="$(jq --argjson n "${prev_attempts}" \
         'del(.last_attempt_ts) | . + {resumed_at_ts: null, resume_attempts: $n,
                                         last_attempt_outcome: "tmux-launch-reverted"}' \
         "${target}" 2>&1 >"${tmp}")"; then
      rm -f "${tmp}"
      log_anomaly "resume-watchdog" "revert jq failed for ${target}: ${jq_err:-no stderr}"
      return 1
    fi
  fi

  if [[ -s "${tmp}" ]]; then
    mv -f "${tmp}" "${target}"
  else
    rm -f "${tmp}"
    log_anomaly "resume-watchdog" "revert produced empty output for ${target}"
    return 1
  fi
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

  # Skip when the cwd is empty, missing, or not owned by the current
  # uid. The ownership check is the security defense — see
  # _cwd_owned_by_self comment for the threat model. An unowned cwd
  # is treated as "missing" for telemetry-counter parity, but the
  # `reason` detail field distinguishes the cause so /ulw-report can
  # surface ownership rejections separately.
  cwd_skip_reason=""
  if [[ -z "${cwd}" ]]; then
    cwd_skip_reason="empty"
  elif [[ ! -d "${cwd}" ]]; then
    cwd_skip_reason="missing"
  else
    # Capture the rc explicitly — `! cmd` collapses non-zero codes to 1,
    # losing the stat-failed (rc=2) vs foreign-owned (rc=1) distinction.
    _cwd_owned_by_self "${cwd}"
    _cwd_rc=$?
    case "${_cwd_rc}" in
      0) ;; # owned by self — no skip
      2) cwd_skip_reason="cwd-stat-failed" ;;
      *) cwd_skip_reason="not-owned-by-self" ;;
    esac
  fi
  if [[ -n "${cwd_skip_reason}" ]]; then
    total_skipped_missing_cwd=$((total_skipped_missing_cwd + 1))
    record_gate_event "resume-watchdog" "skipped-missing-cwd" \
      origin_session="${origin_sid}" \
      missing_cwd="${cwd:-EMPTY}" \
      reason="${cwd_skip_reason}"
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
    # Capture pre-claim state so the launch-failure branch can revert.
    # Read before the claim mutates the file. read_num_field returns 0
    # for missing/null fields, which is the correct neutral default for
    # both prior_resume_attempts (a fresh artifact has 0 attempts) and
    # prior_last_attempt_ts (no prior attempt = field absent).
    prior_resume_attempts="$(read_num_field "${artifact_path}" "resume_attempts")"
    prior_last_attempt_ts="$(read_num_field "${artifact_path}" "last_attempt_ts")"

    # Atomically claim BEFORE launching. Order is critical: claim first
    # so a parallel watchdog tick or /ulw-resume can't double-launch.
    # If the post-claim launch fails, we revert below so the artifact
    # remains eligible for the next tick instead of being silently
    # quarantined for a full cooldown window.
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
      # Launch failed AFTER successful claim. Revert the claim so the
      # next tick re-evaluates this artifact from clean slate; otherwise
      # the cooldown (default 600s) blocks retry for 10 minutes with no
      # recovery, even though the user's tmux/claude may have come back
      # online a second later. Lock-protected: a concurrent /ulw-resume
      # cannot race the revert.
      if revert_watchdog_claim "${artifact_path}" \
            "${prior_resume_attempts}" "${prior_last_attempt_ts}"; then
        record_gate_event "resume-watchdog" "tmux-launch-failed-reverted" \
          origin_session="${origin_sid}"
        log_hook "resume-watchdog" "tmux-launch-failed-reverted origin=${origin_sid}"
      else
        # Revert itself failed (lock contention timeout, mv failure on
        # a read-only mount, malformed artifact). Surface the unhealed
        # state as a distinct event so /ulw-report shows the user the
        # artifact is now stuck and needs manual cleanup.
        record_gate_event "resume-watchdog" "tmux-launch-failed-revert-failed" \
          origin_session="${origin_sid}"
        log_anomaly "resume-watchdog" "revert failed for ${artifact_path}"
      fi
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
