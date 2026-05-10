#!/usr/bin/env bash

set -euo pipefail

# Register a gate skip for the current ULW session.
# Usage: bash ulw-skip-register.sh "reason text"
#
# Writes gate_skip_reason, gate_skip_ts, and gate_skip_edit_ts (the edit
# clock at registration time) into session state under the state lock.
# The stop-guard checks that the edit clock has not advanced since the
# skip was registered — if new edits happened, the skip is stale.

SKIP_REASON="${1:-user override}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Find the most recent session directory
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # shellcheck disable=SC2010
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1 || true)"
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

SESSION_ID="${latest_session}"
ensure_session_dir

if ! is_ultrawork_mode; then
  printf 'ULW mode is not active. No skip registered.\n'
  exit 0
fi

# Capture the current edit clock so stop-guard can detect stale skips.
current_edit_ts="$(read_state "last_edit_ts")"
current_edit_ts="${current_edit_ts:-0}"

with_state_lock_batch \
  "gate_skip_reason" "${SKIP_REASON}" \
  "gate_skip_ts" "$(now_epoch)" \
  "gate_skip_edit_ts" "${current_edit_ts}" \
  "discovered_scope_blocks" "0"

# v1.37.x W4 (Item 6): catch-quality logging for share-card weighting
# revisit. Pre-fix the skip count was global — wave-shape and discovered-
# scope blocks were weighted identically (360s) in the share-card with
# no signal as to whether wave-shape was actually catching real defects
# (under-decomposed plans) vs firing on every large plan submission.
# The /ulw-skip bypass is the user's "you got this wrong" feedback
# signal; joining skip → gate name lets future analysis re-weight the
# share card based on actual catch quality (skip-rate as false-positive
# proxy). The data path: tail the in-session gate_events.jsonl, find
# the most recent block event, record an `ulw-skip:registered` event
# referencing that gate. /ulw-report can then aggregate per-gate skip
# rates over a 2-week window.
events_file="$(session_file "gate_events.jsonl")"
recent_block_gate=""
if [[ -f "${events_file}" ]] && [[ -s "${events_file}" ]]; then
  # Tail-scan the latest 50 events for the most recent block. jq's
  # `select(.event == "block") | .gate` picks the gate name from the
  # last matching row. Fail-soft: a missing or malformed events file
  # leaves recent_block_gate empty and the catch-quality field reads
  # `unknown` — never blocks the skip.
  recent_block_gate="$(tail -50 "${events_file}" 2>/dev/null \
    | jq -rs 'map(select(.event == "block")) | last | .gate // empty' 2>/dev/null \
    || true)"
fi

if [[ -n "${recent_block_gate}" ]]; then
  record_gate_event "ulw-skip" "registered" \
    "skipped_gate=${recent_block_gate}" \
    "reason=${SKIP_REASON}"
else
  record_gate_event "ulw-skip" "registered" \
    "skipped_gate=unknown" \
    "reason=${SKIP_REASON}"
fi

printf 'Gate skip registered. The next stop attempt will pass.\n'
printf 'Reason: %s\n' "${SKIP_REASON}"
if [[ -n "${recent_block_gate}" ]]; then
  printf 'Skipped gate: %s (catch-quality logging — see /ulw-report when data accumulates).\n' "${recent_block_gate}"
fi
printf 'Note: If you make further edits, the skip will be invalidated.\n'
