#!/usr/bin/env bash
# canary-claim-audit.sh — Stop hook: model-drift canary (v1.26.0 Wave 2).
#
# Runs at Stop time AFTER stop-guard.sh (which captures
# last_assistant_message into session state) and AFTER stop-time-summary
# (which doesn't touch state). Reads the model's last response and
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
# Always exit 0. The canary is INFORMATIONAL — it must never block
# Stop, even if the audit itself errors out. Hook ordering ensures it
# runs after stop-guard's last_assistant_message capture.

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
HOOK_JSON="$(cat)"
SESSION_ID="$(printf '%s' "${HOOK_JSON}" | jq -r '.session_id // empty' 2>/dev/null || true)"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

if ! validate_session_id "${SESSION_ID}" 2>/dev/null; then
  exit 0
fi

if ! is_model_drift_canary_enabled; then
  exit 0
fi

# Skip outside ULW mode — the canary tracks ULW sessions only because
# only ULW sessions accrue the time-tracking and gate-events
# infrastructure that powers /ulw-report's drift surface.
if ! is_ultrawork_mode; then
  exit 0
fi

# Run the audit. canary_run_audit always returns 0 — even on internal
# error paths it logs to hooks.log and exits cleanly.
canary_run_audit "${SESSION_ID}" || true

# Soft alert: if the per-session unverified count crosses threshold
# AND the alert has not yet been emitted, output a systemMessage card.
# Exits with the JSON on stdout so Claude Code surfaces it; the alert
# itself is non-blocking (no decision: "block").
#
# One-shot per session: drift_warning_emitted state flag prevents
# repetition. The flag persists for the lifetime of session_state.json
# — a fresh session resets it implicitly because it gets a fresh state
# file. Mirrors the memory_drift_hint_emitted shape; both rely on per-
# session state file lifetime rather than an explicit clear pass.
if canary_should_alert "${SESSION_ID}"; then
  unverified_count="$(canary_session_unverified_count "${SESSION_ID}")"
  alert_text="DRIFT WARNING (model-drift canary, v1.26.0): ${unverified_count} unverified-claim turns this session. **What to do now:** spot-check the claims — pick 2-3 file paths the model named in this session and \`git diff\` / \`Read\` them yourself to confirm the claimed verification actually happened; if the claims match reality, dismiss this warning. **What the canary saw:** the model's prose asserted verification work (\"I read X\", \"I verified Y\", \"I checked Z\") but the turn fired zero verification tool calls (Read/Bash/Grep/Glob/WebFetch/NotebookRead) for those named anchors — the silent-confabulation pattern. **What the model should do for the rest of the session:** define the search universe explicitly, enumerate each candidate, and verify each — do not declare 'verified' / 'checked' / 'read' without naming the tool call that produced the verification. See \`/ulw-report\` for cross-session canary trends."
  emit_stop_message "${alert_text}"
  write_state "drift_warning_emitted" "1"
  log_hook "canary" "drift warning emitted (count=${unverified_count})"
fi

exit 0
