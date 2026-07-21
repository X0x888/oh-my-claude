#!/usr/bin/env bash
# canary-claim-audit.sh — Stop hook: model-drift canary (v1.26.0 Wave 2).
#
# Runs after an accepted stop-guard disposition inside stop-dispatch.sh
# (which has captured last_assistant_message into session state), after the
# timing checkpoint. Reads the model's last response and
# audits assertive verification claims against the turn's actual
# verification tool calls. Records per-event canary rows to
# `<session>/canary.jsonl` and `~/.claude/quality-pack/canary.jsonl`,
# emits a `gate=canary event=unverified_claim` row when the verdict
# is unverified, and surfaces a one-shot `systemMessage` soft alert
# when the per-session unverified count crosses threshold (>= 2).
#
# Pre-mortem context: metis flagged the original Wave 2 design as
# silent on the user's stated failure mode ("shit code, landmines,
# technical debt without even realising it" — the user shipped it).
# This audit catches the failure REAL-TIME (within the turn) by
# comparing claim counts to tool counts, which is structural and
# Goodhart-resistant. The post-hoc git-log lookback (commits authored
# during ULW sessions → revert/hotfix follow-ups within 7 days) is a
# v1.27.x candidate; v1.26.0 ships only the real-time signal so the
# scope stays bounded and the backtest gate can validate it before
# expanding.
#
# Standalone invocation is informational and fail-open. An accepted dispatcher
# child propagates a publication/claim failure so the exact finalizer lease is
# abandoned and retried; it still never changes the stop-guard disposition.

set -euo pipefail

# v1.27.0 (F-020 / F-021): canary reads timing.jsonl directly (file IO,
# not via lib/timing.sh) and does not call any classifier function.
# Opt out of both eager sources.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
. "${SCRIPT_DIR}/lib/canary.sh"

# Stop-hook payload includes session_id at the top level.
HOOK_JSON="$(_omc_read_hook_stdin)"
SESSION_ID="$(json_get '.session_id' 2>/dev/null || true)"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

if ! validate_session_id "${SESSION_ID}" 2>/dev/null; then
  exit 0
fi
omc_enforcement_generation_matches_capture || exit 0

if ! is_model_drift_canary_enabled; then
  exit 0
fi

# Skip outside ULW mode — the canary tracks ULW sessions only because
# only ULW sessions accrue the time-tracking and gate-events
# infrastructure that powers /ulw-report's drift surface.
if [[ "${OMC_STOP_ACCEPTED:-0}" != "1" ]] && ! is_ultrawork_mode; then
  exit 0
fi

# Standalone Stop hooks are informational and remain fail-open. The dispatcher
# marks accepted children explicitly; there a publish failure must propagate so
# its finalizer lease is abandoned and retried.
canary_rc=0
canary_run_audit "${SESSION_ID}" || canary_rc=$?
if [[ "${canary_rc}" -ne 0 ]]; then
  [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && exit "${canary_rc}"
fi

# Soft alert: atomically claim the one-shot warning after the per-session
# threshold is crossed, then output a systemMessage card.
# Exits with the JSON on stdout so Claude Code surfaces it; the alert
# itself is non-blocking (no decision: "block").
#
# One-shot per session: canary_claim_alert evaluates the threshold and writes
# drift_warning_emitted in one generation-fenced state critical section. A
# stale G1 callback or a concurrent Stop therefore cannot emit/claim G2's
# warning after merely winning an outside-lock check.
claim_alert_rc=0
unverified_count="$(canary_claim_alert "${SESSION_ID}" 2>/dev/null)" \
  || claim_alert_rc=$?
if [[ "${claim_alert_rc}" -ne 0 && "${claim_alert_rc}" -ne 2 \
    && "${OMC_STOP_ACCEPTED:-0}" == "1" ]]; then
  exit "${claim_alert_rc}"
fi
if [[ "${unverified_count}" =~ ^[0-9]+$ ]]; then
  alert_text="DRIFT WARNING (model-drift canary, v1.26.0): ${unverified_count} unverified-claim turns this session. **What to do now:** spot-check the claims — pick 2-3 file paths the model named in this session and \`git diff\` / \`Read\` them yourself to confirm the claimed verification actually happened; if the claims match reality, dismiss this warning. **What the canary saw:** the model's prose asserted verification work (\"I read X\", \"I verified Y\", \"I checked Z\") but the turn fired zero verification tool calls (Read/Bash/Grep/Glob/WebFetch/NotebookRead) for those named anchors — the silent-confabulation pattern. **What the model should do for the rest of the session:** define the search universe explicitly, enumerate each candidate, and verify each — do not declare 'verified' / 'checked' / 'read' without naming the tool call that produced the verification. See \`/ulw-report\` for cross-session canary trends."
  emit_stop_message "${alert_text}"
  log_hook "canary" "drift warning emitted (count=${unverified_count})"
fi

exit 0
