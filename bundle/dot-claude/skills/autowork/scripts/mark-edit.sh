#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or
# timing-lib dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

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

# Classify the edit: doc or code. Doc edits maintain a separate clock
# so that CHANGELOG/README tweaks don't re-trigger code verification or
# code-review gates. Code edits reset code-oriented dimensions; doc
# edits only reset the prose dimension. The classification happens
# once here so the stop-hook doesn't need to re-scan edited_files.log
# every time the agent attempts to stop.

now="$(now_epoch)"
is_doc=0
if [[ -n "${edited_path}" ]] && is_doc_path "${edited_path}"; then
  is_doc=1
fi

# last_edit_ts is still updated for every edit (doc or code) to preserve
# backward compatibility with the legacy review_unremediated path and
# any pre-dimension-gate tests / consumers.
#
# Wrapped in with_state_lock_batch to serialize against concurrent
# SubagentStop reviewer writes (record-reviewer.sh), which share the
# stop_guard_blocks / session_handoff_blocks keys. Without the lock,
# a reviewer batch racing with this batch could lose updates to
# dimension_guard_blocks and the edit-timestamp clocks.
if [[ "${is_doc}" -eq 1 ]]; then
  with_state_lock_batch \
    "last_edit_ts" "${now}" \
    "last_doc_edit_ts" "${now}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "advisory_guard_blocks" "0" \
    "stall_counter" "0"
else
  with_state_lock_batch \
    "last_edit_ts" "${now}" \
    "last_code_edit_ts" "${now}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "advisory_guard_blocks" "0" \
    "stall_counter" "0"
fi

if [[ -n "${edited_path}" ]]; then
  log_path="$(session_file "edited_files.log")"
  # Update the unique-edit counters only if this path hasn't been
  # recorded before. This keeps code_edit_count / doc_edit_count in
  # sync with `sort -u edited_files.log | wc -l` without requiring the
  # stop-hook to re-run that pipeline.
  #
  # The dedup check + counter increment is wrapped in with_state_lock
  # to prevent lost updates when concurrent PostToolUse hooks fire
  # simultaneously (e.g., parallel agent panels completing near-
  # simultaneously). Without the lock, two concurrent invocations can
  # both read the same count and write count+1, losing an increment
  # and potentially preventing the dimension gate from activating.
  _increment_edit_counter() {
    local _seen=0
    if [[ -f "${log_path}" ]] && grep -Fxq -- "${edited_path}" "${log_path}"; then
      _seen=1
    fi
    printf '%s\n' "${edited_path}" >>"${log_path}"

    if [[ "${_seen}" -eq 0 ]]; then
      if [[ "${is_doc}" -eq 1 ]]; then
        local _doc_count
        _doc_count="$(read_state "doc_edit_count")"
        _doc_count="${_doc_count:-0}"
        write_state "doc_edit_count" "$((_doc_count + 1))"
      else
        local _code_count
        _code_count="$(read_state "code_edit_count")"
        _code_count="${_code_count:-0}"
        write_state "code_edit_count" "$((_code_count + 1))"
        # Track UI file edits separately for the design_quality dimension.
        # UI is a subset of code — both counters increment.
        if is_ui_path "${edited_path}"; then
          local _ui_count
          _ui_count="$(read_state "ui_edit_count")"
          _ui_count="${_ui_count:-0}"
          write_state "ui_edit_count" "$((_ui_count + 1))"
        fi
      fi
    fi
    printf '%s' "${_seen}"
  }
  _seen_result="$(with_state_lock _increment_edit_counter)"

  # Delivery Contract v2 (v1.34.0): refresh inferred-surface contract
  # when a NEW unique path landed. Skipping when _seen=1 keeps the
  # per-edit overhead low — re-derivation is O(unique-paths) on
  # edited_files.log, so we only pay it when the input set changed.
  # `refresh_inferred_contract` is itself gated by
  # `is_inferred_contract_enabled` and re-entrant against the state
  # lock via `_OMC_STATE_LOCK_HELD`.
  if [[ "${_seen_result}" == "0" ]]; then
    refresh_inferred_contract || true
  fi

  log_hook "mark-edit" "file=${edited_path} is_doc=${is_doc}"
fi
