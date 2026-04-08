#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

edited_path="$(json_get '.tool_input.file_path')"
if [[ -n "${edited_path}" ]] && is_internal_claude_path "${edited_path}"; then
  append_limited_state "internal_edits.log" "${edited_path}" "20"
  exit 0
fi

write_state_batch \
  "last_edit_ts" "$(now_epoch)" \
  "stop_guard_blocks" "0" \
  "session_handoff_blocks" "0" \
  "advisory_guard_blocks" "0" \
  "stall_counter" "0"
if [[ -n "${edited_path}" ]]; then
  printf '%s\n' "${edited_path}" >>"$(session_file "edited_files.log")"
  log_hook "mark-edit" "file=${edited_path}"
fi
