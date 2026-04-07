#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
SOURCE="$(json_get '.source')"

if [[ -z "${SESSION_ID}" || "${SOURCE}" != "compact" ]]; then
  exit 0
fi

ensure_session_dir

handoff_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"

# Prefer compact_handoff.md (includes native summary + snapshot) over raw snapshot
if [[ -f "${handoff_file}" ]]; then
  snapshot_text="$(cat "${handoff_file}")"
elif [[ -f "${snapshot_file}" ]]; then
  snapshot_text="$(cat "${snapshot_file}")"
else
  exit 0
fi
snapshot_text="$(truncate_chars 9000 "${snapshot_text}")"

write_state "last_compact_rehydrate_ts" "$(now_epoch)"

compact_context="A compaction just occurred. Continue from the preserved state below instead of restarting the task. Use the native compact summary plus this live handoff to keep continuity high. Do not fall back to a broad recap unless the user asks for one."

jq -nc --arg context "${compact_context}"$'\n\n'"${snapshot_text}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
