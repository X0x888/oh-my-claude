#!/usr/bin/env bash
#
# SessionStart whats-new hook.
#
# v1.37.x W2 F-007 (Item 3). Symmetric counterpart to
# session-start-drift-check.sh: when `bash install.sh` re-runs (the
# user just upgraded), the install footer prints "What's new since
# v<prev>: ..." once. After Claude Code restart the user has no
# in-session reminder of what changed — they need to remember to
# run `/whats-new` manually. This hook surfaces the delta
# automatically the first time a session starts after the installed
# version changes.
#
# How it works:
#   1. Read installed_version from ~/.claude/oh-my-claude.conf.
#   2. Read last_session_seen_version from
#      ~/.claude/quality-pack/.last_session_seen_version (cross-session).
#   3. If they differ, emit a one-shot additionalContext naming the
#      change and pointing at /whats-new for the full delta.
#   4. Stamp the new version into .last_session_seen_version so this
#      fires exactly once per version transition.
#
# Disable via `whats_new_session_hint=false` in the conf or
# `OMC_WHATS_NEW_SESSION_HINT=false` env. Both follow the standard
# load_conf precedence in common.sh.
#
# Idempotency: per-session `whats_new_emitted` state key prevents
# re-emission across SessionStart matchers (resume / compact /
# catchall all fire). Cross-session: the
# .last_session_seen_version stamp dedupes per-version.
#
# Failure modes (all soft-exit clean — never block session start):
# - conf missing or installed_version empty → exit silently
# - cross-session state dir not writable → still emit notice but
#   skip the dedupe write so future fires retry
# - jq missing → log_anomaly + exit 0

set -euo pipefail

HOOK_JSON="$(cat 2>/dev/null || true)"

# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# Honor the disable flag. load_conf already populated env vars, so
# OMC_WHATS_NEW_SESSION_HINT is the source-of-truth value.
if [[ "${OMC_WHATS_NEW_SESSION_HINT:-true}" == "false" ]]; then
  exit 0
fi

ensure_session_dir
existing_emitted="$(read_state "whats_new_emitted" 2>/dev/null || true)"
if [[ "${existing_emitted}" == "1" ]]; then
  exit 0
fi

CONF="${HOME}/.claude/oh-my-claude.conf"
[[ -f "${CONF}" ]] || exit 0

installed_version="$(grep -E '^installed_version=' "${CONF}" 2>/dev/null \
  | tail -1 | cut -d= -f2- | tr -d '[:space:]' | tr -d '"' | tr -d "'")"
[[ -z "${installed_version}" ]] && exit 0

# Cross-session dedupe stamp. The file lives outside per-session state
# (so a SessionStart in a fresh session can read what the prior session
# wrote). One line: the version string of the install the most-recent
# session saw. Empty/missing means "never seen" → fire on first run.
STAMP_DIR="${HOME}/.claude/quality-pack"
STAMP_FILE="${STAMP_DIR}/.last_session_seen_version"
last_seen=""
if [[ -f "${STAMP_FILE}" ]]; then
  last_seen="$(head -1 "${STAMP_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi

if [[ "${last_seen}" == "${installed_version}" ]]; then
  exit 0
fi

# Compose the additionalContext. Calmer framing than drift-check —
# this is "you upgraded, here's the proactive nudge", not "your
# install is out of sync". Two-line shape: lead with the version
# transition; recommend the skill in the second line.
if [[ -n "${last_seen}" ]]; then
  whats_new_msg="**oh-my-claude updated.** \`${last_seen}\` → \`${installed_version}\` (this is the first session after the install). Run \`/whats-new\` to see the changelog delta — features, gates, and skills that landed since your previous install."
else
  whats_new_msg="**oh-my-claude installed.** Running \`v${installed_version}\`. Run \`/whats-new\` to see what's in this version, or \`/skills\` for the full skill index. \`/ulw-demo\` runs a guided 90-second walkthrough on a throwaway file in /tmp."
fi

payload="$(jq -nc --arg context "${whats_new_msg}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${payload}" ]]; then
  log_anomaly "session-start-whats-new" "failed to compose payload"
  exit 0
fi

# Emit BEFORE stamping the dedupe file so a failed printf leaves the
# stamp unchanged and retries next session — same pattern as
# session-start-drift-check.sh.
if ! printf '%s\n' "${payload}"; then
  log_anomaly "session-start-whats-new" "failed to emit payload to stdout"
  exit 0
fi

write_state "whats_new_emitted" "1"

# Cross-session stamp write. Soft-fail: if the write fails (read-only
# filesystem, permission), the next SessionStart re-fires the notice —
# acceptable degraded behavior, the user just sees the upgrade banner
# twice instead of being silenced incorrectly.
mkdir -p "${STAMP_DIR}" 2>/dev/null || true
if ! printf '%s\n' "${installed_version}" > "${STAMP_FILE}" 2>/dev/null; then
  log_anomaly "session-start-whats-new" "failed to write ${STAMP_FILE}"
fi

# Emit a gate event so /ulw-report can count whats-new surfacings.
record_gate_event "whats-new" "version-transition" \
  "from=${last_seen:-fresh-install}" \
  "to=${installed_version}"

log_hook "session-start-whats-new" "version transition ${last_seen:-fresh-install} → ${installed_version}"
