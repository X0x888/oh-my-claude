#!/usr/bin/env bash
#
# SessionStart watchdog-health probe — closes the v1.43 sre-lens F-001
# silent-failure trap.
#
# The resume watchdog runs as a launchd/systemd agent on a 120-second
# StartInterval. Pre-v1.43 there was no read path for its heartbeat —
# the heartbeat itself existed (resume-watchdog.sh:478 writes
# ${STATE_ROOT}/_watchdog/last_tick_completed_ts at tick top and end)
# but nothing alarmed when it went stale.
#
# Real-world failure modes that produce a silent dead watchdog:
#   - macOS update unloads the launchd agent
#   - `launchctl bootout` from a tooling script (homebrew, mise, etc.)
#   - plist signature change after agent rotation
#   - `claude` CLI upgrade that breaks --version validation
#   - laptop suspended too long → launchd debounces the catch-up
#   - the user reinstalled the harness but skipped install-resume-watchdog.sh
#
# Without an alarm, the user discovers the dead watchdog the next time
# auto-resume *should* have fired — which is exactly the 24/7-autonomy
# break the watchdog exists to prevent.
#
# Behavior (v1.47 — guarded self-heal, was warn-only in v1.43):
#   - Skip when resume_watchdog is opt-out (default off; watchdog isn't
#     expected to be running, so no heartbeat ≠ failure).
#   - Skip when the heartbeat is fresh (< 3 × StartInterval = 360s).
#   - When the heartbeat is stale OR missing AND it is SAFE, attempt ONE
#     guarded auto-re-registration (`install-resume-watchdog.sh
#     --reregister`) to revive the agent without the user hand-running the
#     installer. Emits a green "self-healed" notice on success.
#   - "SAFE" means NO claimable resume_request.json exists. Re-registering
#     fires a RunAtLoad/Persistent tick that would CLAIM a pending artifact
#     and spawn an orphan `claude --resume` (the foot-gun documented in
#     project_watchdog_reregister_claims_artifacts.md). When an artifact
#     exists the hook does NOT re-register — it warns and tells the user to
#     handle the artifact via /ulw-resume first. Fail-CLOSED: if the
#     claimable-artifact check cannot run, treat as unsafe (warn, no
#     re-register).
#   - Falls back to the warning (with the right recovery message) when the
#     re-register fails, is blocked by an artifact, or was already attempted
#     this session (`watchdog_selfheal_attempted_ts` — once-per-session, so
#     a persistently-broken scheduler is not churned every SessionStart).
#   - Output is `hookSpecificOutput.additionalContext` (SessionStart
#     supports it; unlike Stop/SubagentStop).
#   - Per-session idempotent message: fire once per SESSION_ID via
#     `watchdog_health_emitted=1` in session state so a SessionStart
#     fired multiple times (resume → compact → clear) does not spam.
#
# Soft-failure throughout: never blocks Stop, never propagates non-zero.
# A self-heal failure degrades to the warning — it must never break
# SessionStart.

set -euo pipefail

. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

# Watchdog opt-out — skip silently. The user has not opted in to
# auto-resume; a missing heartbeat tells us nothing.
if ! is_resume_watchdog_enabled; then
  exit 0
fi

ensure_session_dir

# Per-session idempotency. Stale-watchdog is a session-level signal;
# repeated SessionStart firings (resume/compact/clear) don't re-emit.
if [[ "$(read_state "watchdog_health_emitted")" == "1" ]]; then
  exit 0
fi

# Heartbeat location is the synthetic _watchdog session dir written by
# resume-watchdog.sh:477-478. Reading it is filesystem-only — no lock,
# no cross-session ledger touch.
#
# The `_watchdog` literal matches resume-watchdog.sh:90
# `SYNTHETIC_SESSION_ID="${SESSION_ID:-_watchdog}"` — launchd / systemd
# spawns the watchdog without SESSION_ID set, so the fallback wins and
# the heartbeat always lands here in normal operation. Manual diagnostic
# runs (`SESSION_ID=foo bash resume-watchdog.sh`) write the heartbeat
# elsewhere; out-of-scope for this alarm (those runs are interactive
# debug, not autonomy).
hb_file="${STATE_ROOT}/_watchdog/last_tick_completed_ts"
now_ts="$(now_epoch)"

# Alarm threshold = 3 × StartInterval. The launchd plist pins
# StartInterval=120s; 3× gives a generous window for one missed tick
# (a tick can legitimately run long on cold-cache disk reads or while
# claim contention blocks under-lock) without triggering on the normal
# inter-tick gap.
#
# `OMC_WATCHDOG_HEALTH_STALENESS_SECS` is env-only by design (not
# wired through `_parse_conf_file` + conf.example + omc-config.sh).
# Per the conf-flag coordination rule in CLAUDE.md, conf surface is
# warranted when (a) the flag changes BEHAVIOR (resume_watchdog on/off,
# quality_policy strict/lenient) or (b) tuning is anticipated to be
# common enough to warrant discoverability. This threshold is a
# defensive alarm window the harness picks correctly for ~99% of users;
# the rare host that needs tightening (latency-sensitive autonomy) or
# loosening (very-slow disk) is best served by an env override in the
# user's shell rc rather than a conf flag that adds noise to the
# 58-flag surface most users will never touch.
threshold_secs="${OMC_WATCHDOG_HEALTH_STALENESS_SECS:-360}"
[[ "${threshold_secs}" =~ ^[1-9][0-9]*$ ]] || threshold_secs=360

stale=0
reason=""
if [[ ! -f "${hb_file}" ]]; then
  stale=1
  reason="never-started"
else
  hb_ts="$(cat "${hb_file}" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ ! "${hb_ts}" =~ ^[1-9][0-9]*$ ]]; then
    # Corrupt content — log + skip (alarm would be misleading).
    log_anomaly "session-start-watchdog-health" "non-numeric heartbeat: ${hb_ts:-empty}"
    exit 0
  fi
  age_secs=$(( now_ts - hb_ts ))
  # Future-timestamp guard (quality-reviewer Wave 2 F-001).
  # `age_secs` can go NEGATIVE on three real-world causes:
  #   (a) NTP step-back after `ntpd` corrects a forward-skewed clock,
  #   (b) laptop suspend-then-clock-reset-on-wake (rare, depends on
  #       BIOS/UEFI behavior — observed on some Apple Silicon machines
  #       after long battery-flat sleeps),
  #   (c) clock-manipulation attacks (low priority — would require
  #       local code execution AND ability to forge a heartbeat write).
  # Without this guard, `-ge ${threshold_secs}` is FALSE for negatives
  # and a dead watchdog whose last tick happens to predate a clock
  # step-back is silently treated as fresh. The alarm fires with a
  # distinct reason so the user can recognize the clock-skew shape.
  if [[ "${age_secs}" -lt 0 ]]; then
    stale=1
    reason="future-timestamp (clock skew; heartbeat ${hb_ts} > now ${now_ts})"
  elif [[ "${age_secs}" -ge "${threshold_secs}" ]]; then
    stale=1
    # Render age as "Nm" / "NhM m" / "NdM h" for legible reporting.
    if [[ "${age_secs}" -lt 3600 ]]; then
      reason="${age_secs}s ago"
    elif [[ "${age_secs}" -lt 86400 ]]; then
      _h=$(( age_secs / 3600 ))
      _m=$(( (age_secs % 3600) / 60 ))
      reason="${_h}h${_m}m ago"
    else
      _d=$(( age_secs / 86400 ))
      _h=$(( (age_secs % 86400) / 3600 ))
      reason="${_d}d${_h}h ago"
    fi
  fi
fi

if [[ "${stale}" -ne 1 ]]; then
  # Fresh heartbeat — silent. Don't stamp the emitted flag; if the
  # watchdog dies later in the session, the NEXT SessionStart re-checks.
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# v1.47 (SRE-lens): guarded self-heal. The watchdog's whole job is to
# REDUCE babysitting; requiring the user to hand-run the installer to
# recover is the exact failure the feature exists to prevent. So instead
# of warn-only, the hook now attempts ONE guarded re-registration per
# session when it is SAFE, and falls back to the warning otherwise.
#
# THE ORPHAN-PREVENTION GUARD (load-bearing — see
# project_watchdog_reregister_claims_artifacts.md): re-registering fires a
# RunAtLoad / Persistent catch-up tick, and a tick CLAIMS any claimable
# resume_request.json and launches `claude --resume` in tmux. Re-register
# while a claimable artifact exists → an ORPHAN agent spawns mid-session,
# burning rate-limit budget and possibly committing unexpected work.
# Therefore the hook checks find_claimable_resume_requests FIRST and does
# NOT even invoke the installer when an artifact exists — the user must
# clear it via /ulw-resume before re-registering. (The installer's
# --reregister mode ALSO refuses on a claimable artifact as a backstop,
# but the hook's own check is the primary guard and keeps the installer
# out of the call path entirely in the unsafe case.)
# ─────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  warn_open=$'\033[33m'   # yellow
  warn_close=$'\033[0m'
  ok_open=$'\033[32m'     # green
  ok_close=$'\033[0m'
  dim_open=$'\033[2m'
  dim_close=$'\033[0m'
else
  warn_open=""; warn_close=""; ok_open=""; ok_close=""; dim_open=""; dim_close=""
fi

case "${reason}" in
  never-started)
    age_line="${warn_open}No watchdog heartbeat has ever been written.${warn_close} The agent likely is not registered with launchd/systemd."
    ;;
  future-timestamp*)
    age_line="${warn_open}Watchdog heartbeat is in the future.${warn_close} ${reason}. This usually means a clock step (NTP correction after laptop wake, BIOS clock reset) — and the dead-watchdog signal is hidden behind it."
    ;;
  *)
    age_line="${warn_open}Last watchdog tick was ${reason}.${warn_close} Threshold is ${threshold_secs}s (3× StartInterval=120s). The agent has stopped firing — typically a macOS update, \`launchctl bootout\`, laptop sleep, or plist signature drift."
    ;;
esac

# --- decide the recovery outcome ---
# outcome ∈ {recovered, attempt-failed, blocked-artifact, attempted-earlier}
banner_head="─── resume-watchdog appears inactive ───"
outcome=""
selfheal_rc=""

selfheal_attempted="$(read_state "watchdog_selfheal_attempted_ts")"
if [[ -n "${selfheal_attempted}" ]]; then
  # A self-heal was already attempted this session. Whatever its result,
  # do NOT churn the platform scheduler on every SessionStart of a session
  # where the watchdog stays stale — fall back to the warning. (The flag is
  # per-session state; a new session re-attempts from scratch.)
  outcome="attempted-earlier"
else
  # Orphan-prevention check (PRIMARY GUARD). Fail-CLOSED: if the helper
  # cannot run or errors, treat as artifact-present and DO NOT re-register.
  claimable=""
  claim_rc=0
  claimable="$(find_claimable_resume_requests 2>/dev/null)" || claim_rc=$?
  if [[ "${claim_rc}" -ne 0 ]] || [[ -n "${claimable}" ]]; then
    outcome="blocked-artifact"
  else
    # SAFE to re-register. Stamp the attempt BEFORE invoking so a crash or
    # hang in the installer cannot produce an unstamped retry loop across
    # SessionStart firings within this session.
    write_state "watchdog_selfheal_attempted_ts" "$(now_epoch)"
    installer="${HOME}/.claude/install-resume-watchdog.sh"
    selfheal_rc=0
    if [[ -f "${installer}" ]]; then
      bash "${installer}" --reregister >/dev/null 2>&1 || selfheal_rc=$?
    else
      selfheal_rc=127
    fi
    if [[ "${selfheal_rc}" -eq 0 ]]; then
      outcome="recovered"
    elif [[ "${selfheal_rc}" -eq 3 ]]; then
      # Installer's backstop refused on a claimable artifact — a race where
      # one appeared between our check and the installer's. Treat as blocked.
      outcome="blocked-artifact"
    else
      outcome="attempt-failed"
    fi
  fi
fi

# --- compose the outcome-specific message ---
case "${outcome}" in
  recovered)
    banner="─── resume-watchdog self-healed ───

${ok_open}The resume-watchdog was inactive (${reason}) and has been re-registered automatically.${ok_close} 24/7 auto-resume is restored; the next tick will refresh the heartbeat.

${dim_open}No claimable resume artifact was pending, so the re-register tick had nothing to claim. If this recurs every session, the scheduler is not surviving sleep/reboot — inspect: tail \$HOME/.claude/quality-pack/state/.watchdog-logs/resume-watchdog.err${dim_close}"
    ;;
  blocked-artifact)
    banner="${banner_head}

${age_line}

${warn_open}A pending resume artifact exists, so the watchdog was NOT auto-re-registered${warn_close} — re-registering now would claim it and spawn an unattended \`claude --resume\`. Handle it first:

  ${dim_open}# Inspect / claim / dismiss the pending resume${dim_close}
  /ulw-resume --peek
  /ulw-resume            ${dim_open}# resume it${dim_close}   ·   /ulw-resume --dismiss   ${dim_open}# shelve it${dim_close}

Then re-register the agent:

  bash \$HOME/.claude/install-resume-watchdog.sh

${dim_open}This warning fires once per session. Threshold tuning: \`OMC_WATCHDOG_HEALTH_STALENESS_SECS\` (default 360).${dim_close}"
    ;;
  attempt-failed)
    banner="${banner_head}

${age_line}

${warn_open}An automatic re-registration was attempted but the platform scheduler command failed${warn_close} (exit ${selfheal_rc}). Recover manually:

  bash \$HOME/.claude/install-resume-watchdog.sh

If you no longer want auto-resume, set \`resume_watchdog=off\` in
\`~/.claude/oh-my-claude.conf\` to silence this warning.

${dim_open}This warning fires once per session. Threshold tuning: \`OMC_WATCHDOG_HEALTH_STALENESS_SECS\` (default 360).${dim_close}"
    ;;
  *)
    # attempted-earlier — a self-heal already ran this session and the
    # heartbeat is still stale (likely the scheduler needs a manual fix).
    banner="${banner_head}

${age_line}

${warn_open}An automatic re-registration was already attempted this session and the watchdog is still inactive.${warn_close} A manual recovery is needed:

  bash \$HOME/.claude/install-resume-watchdog.sh

If you no longer want auto-resume, set \`resume_watchdog=off\` in
\`~/.claude/oh-my-claude.conf\` to silence this warning.

${dim_open}This warning fires once per session. Threshold tuning: \`OMC_WATCHDOG_HEALTH_STALENESS_SECS\` (default 360).${dim_close}"
    ;;
esac

payload="$(jq -nc --arg context "${banner}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${payload}" ]]; then
  log_anomaly "session-start-watchdog-health" "failed to compose payload"
  exit 0
fi

# Emit FIRST, stamp the one-shot LAST (SRE-lens P1a ordering, preserved):
# if the print fails (closed stdout, SIGPIPE, hook timeout), the
# `watchdog_health_emitted` stamp also fails to commit, so the next
# SessionStart re-shows rather than silently swallowing the alarm.
#
# Note the two distinct one-shot flags:
#   - watchdog_selfheal_attempted_ts (stamped above, BEFORE the installer
#     ran) gates the re-register ACTION so a failing reregister cannot
#     churn the scheduler every SessionStart.
#   - watchdog_health_emitted (stamped below, AFTER a successful print)
#     gates the MESSAGE so the banner shows once per session.
# They are separate because the action must be guarded even when the
# message print later fails.
printf '%s\n' "${payload}"

record_gate_event "watchdog-health" "${outcome}" \
  "reason=${reason}" \
  "threshold_secs=${threshold_secs}" || true

write_state "watchdog_health_emitted" "1"
