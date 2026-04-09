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

task_intent="$(read_state "task_intent")"

# Extract tool target path (used by both advisory verification and stall detection)
tool_name="$(json_get '.tool_name')"
target_path=""

case "${tool_name}" in
  Read)
    target_path="$(json_get '.tool_input.file_path')"
    ;;
  Grep)
    target_path="$(json_get '.tool_input.path')"
    ;;
esac

is_internal_path=0
if [[ -n "${target_path}" ]]; then
  case "${target_path}" in
    "${HOME}/.claude/"*)
      is_internal_path=1
      ;;
  esac
fi

# Advisory verification tracking (advisory intent only)
if [[ "${task_intent}" == "advisory" && -n "${target_path}" && "${is_internal_path}" -eq 0 ]]; then
  write_state "last_advisory_verify_ts" "$(now_epoch)"
fi

# P4: Stall detection — track call count and unique file paths
stall_counter="$(read_state "stall_counter")"
stall_counter="${stall_counter:-0}"

# Clear paths window when counter was reset (by edit or agent action)
if [[ "${stall_counter}" -eq 0 ]]; then
  : > "$(session_file "stall_paths.log")" 2>/dev/null || true
fi

stall_counter=$((stall_counter + 1))
write_state "stall_counter" "${stall_counter}"

# Track file path for unique-path analysis (skip internal paths)
if [[ -n "${target_path}" && "${is_internal_path}" -eq 0 ]]; then
  append_limited_state "stall_paths.log" "${target_path}" "${OMC_STALL_THRESHOLD}"
fi

# Analyze at threshold
if [[ "${stall_counter}" -ge "${OMC_STALL_THRESHOLD}" ]]; then
  unique_paths=0
  paths_file="$(session_file "stall_paths.log")"
  if [[ -f "${paths_file}" ]]; then
    unique_paths="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"
  fi
  unique_paths="${unique_paths:-0}"

  write_state "stall_counter" "0"
  : > "${paths_file}" 2>/dev/null || true

  if [[ "${unique_paths}" -ge 8 ]]; then
    # Wide exploration (8+ unique files in 12 reads) — reset silently
    :
  elif [[ "${unique_paths}" -lt 4 ]]; then
    # Spinning on same files — strong warning
    jq -nc --arg unique "${unique_paths}" --arg threshold "${OMC_STALL_THRESHOLD}" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("STALL DETECTED: " + $threshold + "+ consecutive Read/Grep calls touching only " + $unique + " unique files. You are re-reading the same files without making progress. Take a concrete action: edit a file, run a command, delegate to a specialist, or explain to the user what is blocking you.")
      }
    }'
  else
    # Moderate exploration (4-7 unique files) — lighter nudge
    jq -nc --arg unique "${unique_paths}" --arg threshold "${OMC_STALL_THRESHOLD}" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("EXPLORATION CHECK: " + $threshold + "+ consecutive Read/Grep calls across " + $unique + " unique files without editing, testing, or delegating. If you are gathering context, briefly state what you have found and what you still need. If you have enough context, take action.")
      }
    }'
  fi
fi
