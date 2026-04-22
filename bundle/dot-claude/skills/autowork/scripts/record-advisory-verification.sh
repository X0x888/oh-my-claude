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
# Wrapped in with_state_lock to serialize against concurrent state writes
# from parallel PostToolUse / SubagentStop hooks that share the session
# state file. Without the lock, this write can be lost when a sibling
# hook's write_state_batch races the temp-file rename.
if [[ "${task_intent}" == "advisory" && -n "${target_path}" && "${is_internal_path}" -eq 0 ]]; then
  with_state_lock write_state "last_advisory_verify_ts" "$(now_epoch)"
fi

# P4: Stall detection — track call count and unique file paths
# Wrapped in state lock to prevent concurrent Read/Grep from racing.
_increment_stall_counter() {
  local stall_counter
  stall_counter="$(read_state "stall_counter")"
  stall_counter="${stall_counter:-0}"

  # Clear paths window when counter was reset (by edit or agent action)
  if [[ "${stall_counter}" -eq 0 ]]; then
    : > "$(session_file "stall_paths.log")" 2>/dev/null || true
  fi

  stall_counter=$((stall_counter + 1))
  write_state "stall_counter" "${stall_counter}"
  printf '%s' "${stall_counter}"
}
stall_counter="$(with_state_lock _increment_stall_counter)"

# Track file path for unique-path analysis (skip internal paths)
if [[ -n "${target_path}" && "${is_internal_path}" -eq 0 ]]; then
  append_limited_state "stall_paths.log" "${target_path}" "${OMC_STALL_THRESHOLD}"
fi

# Compute dynamic stall threshold based on task complexity
edited_files_log="$(session_file "edited_files.log")"
unique_edited=0
if [[ -f "${edited_files_log}" ]]; then
  unique_edited="$(sort -u "${edited_files_log}" | wc -l | tr -d '[:space:]')"
fi
unique_edited="${unique_edited:-0}"
has_plan="$(read_state "has_plan")"
has_plan="${has_plan:-false}"
effective_threshold="$(compute_stall_threshold "${unique_edited}" "${has_plan}")"

# Analyze at threshold
if [[ "${stall_counter}" -ge "${effective_threshold}" ]]; then
  unique_paths=0
  paths_file="$(session_file "stall_paths.log")"
  if [[ -f "${paths_file}" ]]; then
    unique_paths="$(sort -u "${paths_file}" | wc -l | tr -d '[:space:]')"
  fi
  unique_paths="${unique_paths:-0}"

  # Reset under lock — races with the concurrent _increment_stall_counter
  # path (which is itself already locked) otherwise drop the reset.
  with_state_lock write_state "stall_counter" "0"
  : > "${paths_file}" 2>/dev/null || true

  # Compute progress score for context-aware messaging
  progress="$(compute_progress_score)"

  if [[ "${unique_paths}" -ge 8 ]]; then
    # Wide exploration (8+ unique files) — reset silently
    :
  elif [[ "${unique_paths}" -lt 4 ]]; then
    # Spinning on same files — warning severity depends on progress
    if [[ "${progress}" -ge 50 ]]; then
      jq -nc --arg unique "${unique_paths}" --arg threshold "${effective_threshold}" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("EXPLORATION CHECK: " + $threshold + "+ consecutive Read/Grep calls touching only " + $unique + " unique files. Good progress so far, but you appear to be re-reading familiar code. Take your next concrete action: edit, test, delegate, or explain the blocker.")
        }
      }'
    else
      jq -nc --arg unique "${unique_paths}" --arg threshold "${effective_threshold}" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("STALL DETECTED: " + $threshold + "+ consecutive Read/Grep calls touching only " + $unique + " unique files. You are re-reading the same files without making progress. Take a concrete action: edit a file, run a command, delegate to a specialist, or explain to the user what is blocking you.")
        }
      }'
    fi
  else
    # Moderate exploration (4-7 unique files) — lighter nudge
    jq -nc --arg unique "${unique_paths}" --arg threshold "${effective_threshold}" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("EXPLORATION CHECK: " + $threshold + "+ consecutive Read/Grep calls across " + $unique + " unique files without editing, testing, or delegating. If you are gathering context, briefly state what you have found and what you still need. If you have enough context, take action.")
      }
    }'
  fi
fi
