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
# Behavior:
#   - Skip when resume_watchdog is opt-out (default off; watchdog isn't
#     expected to be running, so no heartbeat ≠ failure).
#   - Skip when the heartbeat is fresh (< 3 × StartInterval = 360s).
#   - Emit a `systemMessage` warning when the heartbeat is stale OR
#     missing entirely.
#   - Per-session idempotent: fire once per SESSION_ID via
#     `watchdog_health_emitted=1` in session state so a SessionStart
#     fired multiple times (resume → compact → clear) does not spam.
#
# Soft-failure throughout: never blocks Stop, never propagates non-zero.

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

# Compose the warning. Concrete recovery actions ordered by likelihood:
# (1) re-register the agent (catches macOS-update / bootout), (2)
# re-run the installer to fix plist signature drift, (3) opt out if
# the user no longer wants auto-resume.
banner_head="─── resume-watchdog appears inactive ───"
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  warn_open=$'\033[33m'   # yellow
  warn_close=$'\033[0m'
  dim_open=$'\033[2m'
  dim_close=$'\033[0m'
else
  warn_open=""; warn_close=""; dim_open=""; dim_close=""
fi

case "${reason}" in
  never-started)
    age_line="${warn_open}No watchdog heartbeat has ever been written.${warn_close} The agent likely is not registered with launchd/systemd."
    ;;
  future-timestamp*)
    age_line="${warn_open}Watchdog heartbeat is in the future.${warn_close} ${reason}. This usually means a clock step (NTP correction after laptop wake, BIOS clock reset) — and the dead-watchdog signal is hidden behind it. Re-register the agent and confirm \`date\` matches a network time source."
    ;;
  *)
    age_line="${warn_open}Last watchdog tick was ${reason}.${warn_close} Threshold is ${threshold_secs}s (3× StartInterval=120s). The agent has stopped firing — typically a macOS update, \`launchctl bootout\`, or plist signature drift."
    ;;
esac

banner="${banner_head}

${age_line}

24/7 auto-resume after a rate-limit kill depends on this agent. To recover:

  ${dim_open}# Re-register the launchd/systemd agent${dim_close}
  bash \$HOME/.claude/install-resume-watchdog.sh

If you no longer want auto-resume, set \`resume_watchdog=off\` in
\`~/.claude/oh-my-claude.conf\` to silence this warning.

${dim_open}This warning fires once per session when the heartbeat is stale or missing. Threshold tuning: \`OMC_WATCHDOG_HEALTH_STALENESS_SECS\` (default 360).${dim_close}"

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

# Stamp idempotency BEFORE printing. Same crash-tolerance contract as
# session-start-welcome.sh: a partial-write crash mid-emit will re-show
# the warning on the next session (preferred over silent loss).
#
# One-shot-per-session contract (quality-reviewer Wave 2 F-003):
# The stamp persists until the session ends. If the watchdog dies, the
# alarm fires once, the user re-registers via install-resume-watchdog.sh,
# and the heartbeat goes fresh — the stamp does NOT clear, so the user
# never sees an in-session "recovered" message. This is intentional: a
# stale-then-fresh transition is fully visible via /ulw-report (next
# `watchdog-health` gate event will be absent, the heartbeat is fresh,
# and the patterns layer surfaces the recovery), so the in-session
# noise budget is better spent on the original alarm. The NEXT
# SessionStart will see a fresh heartbeat and stay silent — the
# implicit "recovered" signal.
write_state "watchdog_health_emitted" "1"

record_gate_event "watchdog-health" "stale" \
  "reason=${reason}" \
  "threshold_secs=${threshold_secs}" || true

printf '%s\n' "${payload}"
