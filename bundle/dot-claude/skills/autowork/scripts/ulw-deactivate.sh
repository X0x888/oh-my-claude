#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Find the most recent session directory
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # shellcheck disable=SC2010
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1 || true)"
fi

# Clear the sentinel
rm -f "${STATE_ROOT}/.ulw_active"

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found. Sentinel cleared.\n'
  exit 0
fi

# Clear workflow_mode in the latest session state, along with all the
# compact-continuity flags that would otherwise linger and surprise the user
# on a later compact resume. In particular, a stale review_pending_at_compact
# flag would re-inject a "MUST run quality-reviewer" directive on the next
# compact cycle *after* the user explicitly turned ULW off — that is exactly
# the kind of spooky action at a distance ulw-off is meant to prevent.
SESSION_ID="${latest_session}"
ensure_session_dir

write_state_batch \
  "workflow_mode" "" \
  "just_compacted" "" \
  "just_compacted_ts" "" \
  "review_pending_at_compact" "" \
  "compact_race_count" "" \
  "pretool_intent_blocks" ""

# Delete the pending-agents queue so a subsequent compact does not render or
# re-dispatch agents that were dispatched under the now-deactivated session.
pending_file="$(session_file "pending_agents.jsonl")"
[[ -f "${pending_file}" ]] && rm -f "${pending_file}"

printf 'Ultrawork mode deactivated for session %s.\n' "${latest_session}"
