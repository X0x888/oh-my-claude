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

# Advisory verification tracking (advisory intent only)
if [[ "${task_intent}" == "advisory" ]]; then
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

  # Skip ~/.claude/ paths — reading Claude's own config isn't codebase inspection
  if [[ -n "${target_path}" ]]; then
    case "${target_path}" in
      "${HOME}/.claude/"*)
        ;;
      *)
        write_state "last_advisory_verify_ts" "$(now_epoch)"
        ;;
    esac
  fi
fi

# P4: Stall detection — increment counter for non-progress tool calls
stall_counter="$(read_state "stall_counter")"
stall_counter="${stall_counter:-0}"
stall_counter=$((stall_counter + 1))
write_state "stall_counter" "${stall_counter}"

# Nudge if stall counter exceeds threshold
if [[ "${stall_counter}" -ge 12 ]]; then
  write_state "stall_counter" "0"
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "STALL CHECK: You have made 12+ consecutive Read/Grep calls without editing a file, running a test, or delegating to a specialist. This pattern often signals analysis paralysis. Decide on a concrete action: edit a file, run a command, delegate to a specialist, or explain to the user what is blocking you. If you are genuinely exploring, state what you are looking for and what you have found so far."
    }
  }'
fi
