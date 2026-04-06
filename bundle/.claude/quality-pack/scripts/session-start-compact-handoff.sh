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

snapshot_file="$(session_file "precompact_snapshot.md")"

if [[ ! -f "${snapshot_file}" ]]; then
  exit 0
fi

snapshot_text="$(cat "${snapshot_file}")"
snapshot_text="$(truncate_chars 9000 "${snapshot_text}")"

write_state "last_compact_rehydrate_ts" "$(now_epoch)"

compact_context="A compaction just occurred. Continue from the preserved state below instead of restarting the task. Use the native compact summary plus this live handoff to keep continuity high. Do not fall back to a broad recap unless the user asks for one."

workflow_mode_value="$(workflow_mode)"
if [[ "${workflow_mode_value}" == "ultrawork" ]]; then
  compact_context="${compact_context}"$'\n'"THINKING DIRECTIVE: Plan before each significant action and reflect after each result — proportional to the task's complexity. Do not chain tool calls without interleaved reasoning. When stuck: think harder, not faster. Track progress with tasks. Prioritize technical accuracy over validating beliefs."
fi

jq -nc --arg context "${compact_context}"$'\n\n'"${snapshot_text}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
