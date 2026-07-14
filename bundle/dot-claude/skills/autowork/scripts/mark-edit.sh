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
# v1.47 (sre-lens R-1): observable fail-open for edit-clock/delivery-contract
# state writes (a silent abort here desyncs review/verify clocks).
omc_arm_failopen_err_trap "mark-edit" "(edit clocks / delivery-contract inference skipped for this edit)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
tool_name="$(json_get '.tool_name')"
hook_event_name="$(json_get '.hook_event_name')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

edited_path="$(json_get '.tool_input.file_path')"
if [[ "${tool_name}" == "NotebookEdit" ]] && [[ -z "${edited_path}" ]]; then
  edited_path="$(json_get '.tool_input.notebook_path')"
fi

# Bash has no file_path field. The PreTool hook captured before-state for each
# non-trivially-read-only candidate; consume it here and advance the generic
# code clock on a changed snapshot or conservative recognized-write fallback.
# This includes ignored/unobservable/asynchronous cases where Git cannot prove
# a diff, so the clock can intentionally fail closed.
if [[ "${tool_name}" == "Bash" ]]; then
  bash_command="$(json_get '.tool_input.command')"
  tool_use_id="$(json_get '.tool_use_id')"
  tool_cwd="$(json_get '.cwd')"
  tool_cwd="${tool_cwd:-${PWD}}"
  if ! bash_worktree_edit_detected "${tool_use_id}" "${tool_cwd}" "${bash_command}"; then
    exit 0
  fi
  # Leave the same-call verification veto before any state write. If a later
  # clock write fails open, record-verification still cannot certify bytes from
  # a compound call that this handler already classified as edit-bearing.
  if [[ "${hook_event_name}" != "PostToolUseFailure" ]]; then
    record_bash_edit_outcome "${tool_use_id}" "${tool_cwd}" "${bash_command}" || true
  fi
fi

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
is_ui=0
if [[ -n "${edited_path}" ]] && is_doc_path "${edited_path}"; then
  is_doc=1
elif [[ -n "${edited_path}" ]] && is_ui_path "${edited_path}"; then
  is_ui=1
fi

_record_first_mutation_from_edit() {
  local existing
  existing="$(read_state "first_mutation_ts")"
  if [[ -z "${existing}" ]]; then
    # v1.43+ (data-lens P0): stamp the gate state AT THE MOMENT of
    # capture so /ulw-report can compare opt-in vs opt-out outcomes
    # per-row, and so stop-guard's backstop can read the state-at-
    # mutation-time rather than the (possibly toggled) state-at-Stop-
    # time. The check is "on" vs anything-else; legacy rows that
    # predate this field read empty and are treated as "off" by the
    # Stop backstop.
    local _gate_state="${OMC_AGENT_FIRST_GATE:-off}"
    write_state_batch \
      "first_mutation_ts" "${now}" \
      "first_mutation_tool" "${tool_name:-Edit}" \
      "agent_first_gate_state" "${_gate_state}"
  fi
}
with_state_lock _record_first_mutation_from_edit || true

# last_edit_ts is still updated for every edit (doc or code) to preserve
# backward compatibility with the legacy review_unremediated path and
# any pre-dimension-gate tests / consumers.
#
# Written by one locked read-modify-write to serialize against concurrent
# SubagentStop reviewer writes (record-reviewer.sh), which share the
# stop_guard_blocks / session_handoff_blocks keys. Without the lock,
# a reviewer batch racing with this batch could lose updates to
# dimension_guard_blocks, timestamp clocks, and monotonic freshness revisions.
_record_edit_clocks() {
  local _edit_revision _next_revision _bash_event_count
  _edit_revision="$(read_state "edit_revision")"
  [[ "${_edit_revision}" =~ ^[0-9]+$ ]] || _edit_revision=0
  _next_revision=$((_edit_revision + 1))

  if [[ "${is_doc}" -eq 1 ]]; then
    write_state_batch \
      "last_edit_ts" "${now}" \
      "last_doc_edit_ts" "${now}" \
      "edit_revision" "${_next_revision}" \
      "last_doc_edit_revision" "${_next_revision}" \
      "stop_guard_blocks" "0" \
      "session_handoff_blocks" "0" \
      "advisory_guard_blocks" "0" \
      "stall_counter" "0"
  elif [[ "${tool_name}" == "Bash" ]] && [[ -z "${edited_path}" ]]; then
    # A monotonic event counter, not the second-resolution timestamp, scopes
    # unknown-path Bash work to a fresh review objective. The global edit
    # revision independently makes reviews/tests stale even in the same second.
    _bash_event_count="$(read_state "bash_edit_event_count")"
    [[ "${_bash_event_count}" =~ ^[0-9]+$ ]] || _bash_event_count=0
    local _unknown_args=(
      "last_edit_ts" "${now}"
      "last_code_edit_ts" "${now}"
      "last_bash_edit_ts" "${now}"
      "edit_revision" "${_next_revision}"
      "last_code_edit_revision" "${_next_revision}"
      "last_bash_edit_revision" "${_next_revision}"
      "bash_edit_event_count" "$((_bash_event_count + 1))"
      "bash_unknown_edit_scope" "1"
      "stop_guard_blocks" "0"
      "session_handoff_blocks" "0"
      "advisory_guard_blocks" "0"
      "stall_counter" "0"
    )
    if [[ "$(read_state "review_cycle_ui_semantic")" == "1" ]]; then
      _unknown_args+=("last_ui_edit_ts" "${now}" "last_ui_edit_revision" "${_next_revision}")
    fi
    if [[ "$(read_state "review_cycle_prose_semantic")" == "1" ]]; then
      _unknown_args+=("last_doc_edit_ts" "${now}" "last_doc_edit_revision" "${_next_revision}")
    fi
    write_state_batch "${_unknown_args[@]}"
  else
    local _code_args=(
      "last_edit_ts" "${now}"
      "last_code_edit_ts" "${now}"
      "edit_revision" "${_next_revision}"
      "last_code_edit_revision" "${_next_revision}"
      "stop_guard_blocks" "0"
      "session_handoff_blocks" "0"
      "advisory_guard_blocks" "0"
      "stall_counter" "0"
    )
    if [[ "${is_ui}" -eq 1 ]]; then
      _code_args+=("last_ui_edit_ts" "${now}" "last_ui_edit_revision" "${_next_revision}")
    fi
    write_state_batch "${_code_args[@]}"
  fi
}
with_state_lock _record_edit_clocks

# Bash worktree scope is unknown: keep exact unique-file counters untouched so
# a later Edit of the same path cannot turn one real file into count=2. The
# separate state flag above records uncertainty without lying to count-based
# gates. Successful PostToolUse already left a per-tool outcome marker before
# the clock writes so the next dispatcher handler cannot accept a
# `test; mutate` compound call as post-edit verification. Failed calls have no
# verification handler.
if [[ "${tool_name}" == "Bash" ]] && [[ -z "${edited_path}" ]]; then
  log_hook "mark-edit" "file=(bash-worktree) is_doc=0"
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
        if [[ "${is_ui}" -eq 1 ]]; then
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
