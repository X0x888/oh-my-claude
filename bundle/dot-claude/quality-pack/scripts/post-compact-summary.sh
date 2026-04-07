#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
TRIGGER="$(json_get '.trigger')"
COMPACT_SUMMARY="$(json_get '.compact_summary')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

write_state_batch \
  "last_compact_trigger" "${TRIGGER:-unknown}" \
  "last_compact_summary" "${COMPACT_SUMMARY}" \
  "last_compact_summary_ts" "$(now_epoch)"

combined_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"

{
  printf '# Compact Handoff\n\n'
  printf '## Native Compact Summary\n%s\n' "${COMPACT_SUMMARY}"

  if [[ -f "${snapshot_file}" ]]; then
    printf '\n## Preserved Live State\n'
    cat "${snapshot_file}"
    printf '\n'
  fi
} >"${combined_file}"
