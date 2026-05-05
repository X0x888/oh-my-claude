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
  # v1.29.0 sre-lens P2-10: write a tombstone to a known fallback path
  # so /ulw-report can surface the watchdog as unhealthy. Without this,
  # absence-of-events looks identical to "watchdog not installed" and
  # the user has no signal to investigate. Best-effort soft-failure;
  # the cache dir is conventional and almost always writable even when
  # STATE_ROOT is not (e.g., user mounted ~/.claude on a read-only
  # network share but ~/.cache stays local).
  #
  # v1.32.16 (4-attacker security review, A1-MED-4): the prior path
  # `${HOME}/.cache/omc-watchdog.last-error` was vulnerable to an
  # unprivileged-shell attacker (A1) pre-creating it as a symlink to
  # `~/.bash_history` (or any user-readable file). The `>` redirect
  # follows symlinks and overwrites the target — a low-effort A1
  # data-destruction primitive. Defense:
  #   1. Move the file inside a 700-mode subdirectory the harness
  #      controls (`${HOME}/.cache/omc/`), so the parent's mode locks
  #      out same-uid attackers (or at least requires them to first
  #      defeat the parent perms — a louder signal).
  #   2. Refuse to write through a symlink at the parent OR the
  #      target — explicit `[[ -L ]]` rejection before redirect.
  #   3. Use mktemp + mv-f for the actual write so any prior content
  #      (incl. a symlink the attacker raced in) is replaced
  #      atomically without following it.
  _watchdog_tombstone_dir="${HOME}/.cache/omc"
  _watchdog_tombstone="${_watchdog_tombstone_dir}/watchdog-last-error"
  if [[ ! -L "${HOME}/.cache" && ! -L "${_watchdog_tombstone_dir}" ]]; then
    mkdir -p "${_watchdog_tombstone_dir}" 2>/dev/null || true
    chmod 700 "${_watchdog_tombstone_dir}" 2>/dev/null || true
    _tomb_tmp="$(mktemp "${_watchdog_tombstone_dir}/.last-error.XXXXXX" 2>/dev/null || true)"
    if [[ -n "${_tomb_tmp}" ]]; then
      printf '{"ts":%s,"reason":"state_root_unwritable","state_root":"%s"}\n' \
        "$(date +%s)" "${STATE_ROOT//\"/\\\"}" \
        > "${_tomb_tmp}" 2>/dev/null || true
      mv -f "${_tomb_tmp}" "${_watchdog_tombstone}" 2>/dev/null || rm -f "${_tomb_tmp}"
    fi
  fi
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

  # Sanitize objective (model-controllable in the resume artifact —
  # could carry control characters, terminal escapes, or AppleScript
  # constructs from a jailbroken/malicious model output). Truncate to
  # 200 chars (notifications display short bodies anyway) and strip
  # control bytes so a hostile body cannot inject escape sequences
  # rendered by the notification tool. Bash 3.2-safe via tr + cut.
  local safe_objective
  safe_objective="$(printf '%s' "${objective}" | tr -d '[:cntrl:]' 2>/dev/null | cut -c -200)"

  local body
  if [[ -n "${safe_objective}" ]]; then
    body="${cwd}: ${safe_objective}"
  else
    body="${cwd}: rate-limit cleared"
  fi
  if [[ "$(uname 2>/dev/null || echo "")" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    # Escape backslashes and double quotes for AppleScript. Control
    # characters were stripped above so the AppleScript runtime cannot
    # see embedded `\n`/`\r`/`\t` that older osascript versions have
    # historically misparsed (CVE-style notification-sanitization gap
    # closed by v1.29.0 security-lens audit).
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

# Resolve the `claude` binary path for launch. Prefers OMC_CLAUDE_BIN
# pin (set by install-resume-watchdog.sh) when present and validation
# passes; falls back to live `command -v claude` on any failure to
# avoid stale-pin silent breakage (npm/nvm/Homebrew updates, manual
# uninstall, host migration). When neither the pin nor live lookup
# yields a usable binary, returns rc=1 — the caller falls through to
# notification mode. Defends against the security-lens F-5 PATH-hijack:
# an attacker who drops ~/.local/bin/claude ahead of the real binary
# in the daemon's PATH cannot execute their shim because the pinned
# path is the absolute install-time path, not a PATH lookup.
#
# Validation: when pin is set, run `${pinned} --version` with a 5s
# `timeout` (when available). Failure → fall back to live `command -v`
# without overwriting the pin (transient nvm switch, etc.; the next
# tick re-validates and may succeed). When no pin is set, returns the
# live `command -v` lookup unchanged (pre-v1.31.0 behavior preserved
# for users who never opt in via install-resume-watchdog.sh).
#
# Stdout: absolute path to claude binary, OR empty when unresolvable.
# Returns 0 on success, 1 when neither pin nor live lookup yields a
# usable binary (caller falls through to notification mode).
resolve_claude_binary() {
  local pinned="${OMC_CLAUDE_BIN:-}"
  local live=""

  if [[ -n "${pinned}" ]] && [[ -x "${pinned}" ]]; then
    # Validate via --version. The 5s cap defends against a hung wrapper
    # (e.g., a Homebrew unlink left the pin pointing at a script that
    # tries to refetch). On systems without `timeout`, run unguarded —
    # the user can clear the pin manually if a hang surfaces.
    local validate_rc=0
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 "${pinned}" --version >/dev/null 2>&1 || validate_rc=$?
    else
      "${pinned}" --version >/dev/null 2>&1 || validate_rc=$?
    fi
    if [[ "${validate_rc}" -eq 0 ]]; then
      printf '%s' "${pinned}"
      return 0
    fi
    log_anomaly "resume-watchdog" "claude_bin pin failed --version (pinned=${pinned}); falling back to live command -v"
  elif [[ -n "${pinned}" ]]; then
    log_anomaly "resume-watchdog" "claude_bin pin not executable (pinned=${pinned}); falling back to live command -v"
  fi

  # Live fallback. command -v -p restricts to the secure system path on
  # POSIX systems, but we deliberately use unrestricted command -v
  # because the user's `claude` install may be in ~/.npm-global,
  # ~/.local/bin, or a Node-version-manager path the system PATH
  # doesn't include. The PATH-hijack defense lives in the pin (when
  # set); when no pin exists, the user has implicitly accepted live
  # PATH resolution by not opting in via install-resume-watchdog.sh.
  live="$(command -v claude 2>/dev/null || true)"
  if [[ -n "${live}" ]]; then
    printf '%s' "${live}"
    return 0
  fi
  return 1
}

# Spawn `claude --resume <sid> "<prompt>"` in a detached tmux session
# rooted at <cwd>. Returns 0 on launch, non-zero on failure.
launch_in_tmux() {
  local sid="$1"
  local cwd="$2"
  local prompt="$3"

  command -v tmux >/dev/null 2>&1 || return 2
  local claude_bin
  claude_bin="$(resolve_claude_binary)" || return 3
  [[ -n "${claude_bin}" ]] || return 3

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
    "${claude_bin}" --resume "${sid}" "${prompt}" >/dev/null 2>&1
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
  if command -v tmux >/dev/null 2>&1 && resolve_claude_binary >/dev/null 2>&1; then
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
    #
    # --cooldown-secs is passed so the claim helper can re-validate the
    # cooldown window UNDER THE LOCK (v1.31.0 metis F-7 fix). Two
    # parallel watchdog ticks (LaunchAgent + manual cron, or two
    # LaunchAgent ticks landing close together) can both pass the
    # unlocked pre-check at line 326, then serially acquire the lock
    # and both claim. The under-lock cooldown rejects the second peer
    # deterministically with rc=3.
    claim_rc=0
    bash "${CLAIM_HELPER}" --watchdog-launch "$$" --target "${artifact_path}" \
      --cooldown-secs "${cooldown_secs}" >/dev/null 2>&1 || claim_rc=$?
    if [[ "${claim_rc}" -ne 0 ]]; then
      case "${claim_rc}" in
        3)
          # Under-lock cooldown violation. Peer claimed within window.
          # Telemetry already recorded by claim helper; bump local
          # counter via the existing skipped-cooldown bucket so the
          # operational summary stays consistent with the unlocked
          # pre-check path.
          total_skipped_cooldown=$((total_skipped_cooldown + 1))
          ;;
        *)
          record_gate_event "resume-watchdog" "claim-failed" \
            origin_session="${origin_sid}"
          ;;
      esac
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
