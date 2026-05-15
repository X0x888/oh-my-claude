#!/usr/bin/env bash
#
# Orphan-resume cleanup.
#
# Detects and kills stale `omc-resume-*` tmux sessions left behind by the
# resume-watchdog mechanism (`bundle/dot-claude/quality-pack/scripts/
# resume-watchdog.sh:launch_in_tmux`). Each watchdog-spawned session runs
# `claude --resume <sid> "<prompt>"` inside a detached tmux session named
# `omc-resume-<sid_short>`. The spawned `claude` process completes its
# task and then sits idle at a prompt forever — the tmux session won't
# terminate until the inner `claude` exits.
#
# Observed in the wild: 4 omc-resume-* sessions on a single host with
# elapsed times of 8–11 days, accumulating tens of CPU-minutes each. The
# user reported this as a hygiene issue: "two possible orphan shells
# running in the background when this sessions ends … has happened
# multiple times."
#
# Strategy:
#   1. List every `omc-resume-*` tmux session via `tmux list-sessions`.
#   2. Skip if `session_attached >= 1` (someone has it open right now).
#   3. Skip if the session name matches the *current* SESSION_ID's
#      expected `sess_name` (computed via the same algorithm as
#      `launch_in_tmux` so we never kill the live session this hook is
#      firing inside of).
#   4. Skip if age (now - session_created) is below threshold
#      (default 4 hours; configurable via `omc_resume_max_age_hours`
#      conf flag or `OMC_ORPHAN_RESUME_MAX_AGE_HOURS` env).
#   5. Kill remaining sessions with `tmux kill-session -t <name>`.
#   6. Log each kill + each skip to gate_events.jsonl for cross-session
#      observability.
#
# Safety rails:
#   - Pattern `omc-resume-*` is the only thing we touch; no user-named
#     tmux sessions can be affected.
#   - Exits 0 on any error (fail-safe in SessionStart context). Errors
#     are logged but never block the parent hook chain.
#   - Hard cap of 50 kills per invocation as a runaway guard.
#   - `tmux` binary absence is a clean no-op.
#   - SESSION_ID absence is a clean no-op (we can't compute the
#     exclude pattern; better to skip than to risk killing the live
#     session).
#
# Invocation:
#   - SessionStart hook (added to bundle/dot-claude/config/
#     settings.patch.json after session-start-resume-hint).
#   - Standalone: `bash cleanup-orphan-resume.sh` from any shell.
#
# Override: `cleanup_orphan_resume=off` in oh-my-claude.conf skips the
# pass entirely (default on).

set -euo pipefail

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

# Allow standalone invocation: read hook stdin if present, otherwise
# fall back to SESSION_ID env var (empty is fine — we'll then skip
# nothing because we can't compute the exclude).
if [[ -t 0 ]]; then
  HOOK_JSON=""
else
  HOOK_JSON="$(_omc_read_hook_stdin 2>/dev/null || printf '')"
fi

if [[ -n "${HOOK_JSON}" ]]; then
  SESSION_ID="$(printf '%s' "${HOOK_JSON}" | jq -r '.session_id // empty' 2>/dev/null || printf '')"
fi
SESSION_ID="${SESSION_ID:-}"

# Conf opt-out: respect `cleanup_orphan_resume=off`.
if ! is_cleanup_orphan_resume_enabled; then
  exit 0
fi

# Resolve the max-age threshold (hours → seconds). 4h is conservative;
# anything still running 4 hours after spawn is almost certainly a
# claude-at-prompt zombie, not active work.
_orphan_max_age_hours="$(orphan_resume_max_age_hours)"
_orphan_max_age_seconds=$(( _orphan_max_age_hours * 3600 ))

# tmux absence = clean no-op.
if ! command -v tmux >/dev/null 2>&1; then
  exit 0
fi

# Compute the current session's expected sess_name. Mirrors the
# `sid_short` derivation in resume-watchdog.sh:301-303 byte-for-byte so
# the exclude is exact.
_current_sess_name=""
if [[ -n "${SESSION_ID}" ]]; then
  _sid_short="$(printf '%s' "${SESSION_ID}" | tr -c 'a-zA-Z0-9_-' '_')"
  _sid_short="${_sid_short:0:24}"
  _current_sess_name="omc-resume-${_sid_short}"
fi

# Snapshot tmux sessions. Tolerate the "no server running" exit-1
# silently — no tmux server means no orphans, clean exit.
_sessions_raw="$(tmux list-sessions -F '#{session_name}|#{session_created}|#{session_attached}' 2>/dev/null || printf '')"
if [[ -z "${_sessions_raw}" ]]; then
  exit 0
fi

_now_epoch="$(date +%s)"
_killed=0
_skipped_attached=0
_skipped_recent=0
_skipped_current=0
_max_kills=50

while IFS='|' read -r _name _created _attached; do
  [[ -z "${_name}" ]] && continue

  # Only act on watchdog-spawned sessions.
  case "${_name}" in
    omc-resume-*) : ;;
    *) continue ;;
  esac

  # Skip if it's the current session's spawn.
  if [[ -n "${_current_sess_name}" && "${_name}" == "${_current_sess_name}" ]]; then
    _skipped_current=$((_skipped_current + 1))
    continue
  fi

  # Skip if someone is attached to this session right now.
  if [[ "${_attached:-0}" =~ ^[0-9]+$ ]] && [[ "${_attached}" -ge 1 ]]; then
    _skipped_attached=$((_skipped_attached + 1))
    continue
  fi

  # Skip if creation time is missing or unparseable.
  if [[ ! "${_created}" =~ ^[0-9]+$ ]]; then
    continue
  fi

  _age=$(( _now_epoch - _created ))
  if [[ "${_age}" -lt "${_orphan_max_age_seconds}" ]]; then
    _skipped_recent=$((_skipped_recent + 1))
    continue
  fi

  # Hit the kill cap — log and stop. Defensive against a runaway tmux
  # state we don't understand yet.
  if [[ "${_killed}" -ge "${_max_kills}" ]]; then
    record_gate_event "cleanup-orphan-resume" "kill-cap-reached" \
      "killed=${_killed}" "cap=${_max_kills}" 2>/dev/null || true
    break
  fi

  # Kill. Tolerate failure quietly — the session may have terminated
  # between our list and our kill (race).
  if tmux kill-session -t "${_name}" 2>/dev/null; then
    _killed=$((_killed + 1))
    record_gate_event "cleanup-orphan-resume" "killed" \
      "name=${_name}" "age_seconds=${_age}" 2>/dev/null || true
  fi
done <<<"${_sessions_raw}"

# Summary event — useful for `/ulw-report` to aggregate "how often
# does cleanup actually find orphans" over time.
if [[ "${_killed}" -gt 0 || "${_skipped_recent}" -gt 0 || "${_skipped_attached}" -gt 0 ]]; then
  record_gate_event "cleanup-orphan-resume" "summary" \
    "killed=${_killed}" \
    "skipped_attached=${_skipped_attached}" \
    "skipped_recent=${_skipped_recent}" \
    "skipped_current=${_skipped_current}" \
    "threshold_hours=${_orphan_max_age_hours}" 2>/dev/null || true
fi

# Surface to the user via additionalContext when running under
# SessionStart — gives them visibility into what was cleaned without
# being noisy on zero-kill ticks. Standalone invocations get the same
# summary on stderr for shell-side visibility.
if [[ "${_killed}" -gt 0 ]]; then
  _msg="oh-my-claude cleanup: killed ${_killed} orphan resume-watchdog tmux session(s) older than ${_orphan_max_age_hours}h."
  if [[ -n "${HOOK_JSON}" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
      "$(printf '%s' "${_msg}" | jq -Rs .)" 2>/dev/null || true
  else
    printf '%s\n' "${_msg}" >&2
  fi
fi

exit 0
