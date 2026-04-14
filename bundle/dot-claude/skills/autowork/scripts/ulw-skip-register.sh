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
  "gate_skip_edit_ts" "${current_edit_ts}"

printf 'Gate skip registered. The next stop attempt will pass.\n'
printf 'Reason: %s\n' "${SKIP_REASON}"
printf 'Note: If you make further edits, the skip will be invalidated.\n'
