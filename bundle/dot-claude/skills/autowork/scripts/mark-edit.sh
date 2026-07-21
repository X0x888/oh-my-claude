#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or
# timing-lib dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE
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
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_interrupted_dispatch_transaction_present "${SESSION_ID}" && exit 0

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi
capture_ulw_enforcement_interval || exit 0

edited_path="$(json_get '.tool_input.file_path')"
if [[ "${tool_name}" == "NotebookEdit" ]] && [[ -z "${edited_path}" ]]; then
  edited_path="$(json_get '.tool_input.notebook_path')"
fi

# Connector tools are pathless. Ignore only operations the shared classifier
# can prove observational; unknown calls fail closed and advance the relevant
# native/document/UI generations so review cannot certify pre-mutation bytes.
is_external_mcp=0
external_surface=""
if [[ "${tool_name}" == mcp__* ]]; then
  tool_input_json="$(jq -c '.tool_input // {}' <<<"${HOOK_JSON}" 2>/dev/null || printf '{}')"
  if ! mcp_tool_attempts_artifact_mutation "${tool_name}" "${tool_input_json}"; then
    exit 0
  fi
  is_external_mcp=1
  _mcp_lower="$(printf '%s' "${tool_name}" | tr '[:upper:]-' '[:lower:]_')"
  case "${_mcp_lower}" in
    *sheet*|*workbook*|*excel*) external_surface="native" ;;
    *doc*|*word*|*notion*|*confluence*) external_surface="doc" ;;
    *slide*|*deck*|*powerpoint*|*figma*|*canvas*|*browser*|*playwright*|*computer_use*) external_surface="ui" ;;
    *) external_surface="unknown" ;;
  esac
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
if [[ "${external_surface}" == "doc" ]]; then
  is_doc=1
elif [[ "${external_surface}" == "ui" ]]; then
  is_ui=1
elif [[ -n "${edited_path}" ]] && is_doc_path "${edited_path}"; then
  is_doc=1
elif [[ -n "${edited_path}" ]] && is_ui_path "${edited_path}"; then
  is_ui=1
fi

_MARK_EDIT_UINT_MAX=999999999999999999
_MARK_EDIT_UINT_INCREMENT_MAX=999999999999999998

# State is cooperative and may carry interrupted-migration or hand-edited
# text. A mutation clock must never feed that text to Bash arithmetic. Soft
# activity counters saturate rather than reset. A causal revision cannot safely
# saturate, however: a second edit at the ceiling would reuse the same revision
# and could make old review evidence look fresh. Publish a nonnumeric sentinel
# instead so Stop and proof consumers fail closed until explicit recovery.
_mark_edit_next_counter() {
  local current="${1:-}"
  [[ -n "${current}" ]] || current=0
  if _omc_canonical_uint_in_range \
      "${current}" 0 "${_MARK_EDIT_UINT_INCREMENT_MAX}"; then
    printf '%s' "$((current + 1))"
  else
    printf '%s' "${_MARK_EDIT_UINT_MAX}"
  fi
}

_mark_edit_next_revision() {
  local current="${1:-}"
  [[ -n "${current}" ]] || current=0
  if _omc_canonical_uint_in_range \
      "${current}" 0 "${_MARK_EDIT_UINT_INCREMENT_MAX}"; then
    printf '%s' "$((current + 1))"
  else
    printf '%s' "overflow"
  fi
}

_record_first_mutation_from_edit() {
  local existing
  is_ultrawork_mode || return 0
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
  local _edit_revision _next_revision _bash_event_count _prompt_revision
  local _external_event_count=0 _external_doc_count=0
  local _external_ui_count=0 _external_native_count=0
  local _external_unknown_count=0
  local -a _external_event_args=()
  is_ultrawork_mode || return 0
  _edit_revision="$(read_state "edit_revision")"
  _next_revision="$(_mark_edit_next_revision "${_edit_revision}")"
  _prompt_revision="$(read_state "prompt_revision")"
  _omc_canonical_uint_in_range \
    "${_prompt_revision}" 0 "${_MARK_EDIT_UINT_MAX}" \
    || _prompt_revision=""

  if [[ "${is_external_mcp}" -eq 1 ]]; then
    # Connector mutations have no repository path, but they are not Bash.
    # Maintain their own monotonic event portfolio so fresh-objective adaptive
    # review can see remote document/UI/native activity without contaminating
    # Bash-only risk, freshness, or telemetry keys.
    _external_event_count="$(read_state "external_edit_event_count")"
    _external_doc_count="$(read_state "external_doc_edit_event_count")"
    _external_ui_count="$(read_state "external_ui_edit_event_count")"
    _external_native_count="$(read_state "external_native_edit_event_count")"
    _external_unknown_count="$(read_state "external_unknown_edit_event_count")"
    _external_event_count="$(_mark_edit_next_counter \
      "${_external_event_count}")"
    case "${external_surface}" in
      doc) _external_doc_count="$(_mark_edit_next_counter \
        "${_external_doc_count}")" ;;
      ui) _external_ui_count="$(_mark_edit_next_counter \
        "${_external_ui_count}")" ;;
      native) _external_native_count="$(_mark_edit_next_counter \
        "${_external_native_count}")" ;;
      *) _external_unknown_count="$(_mark_edit_next_counter \
        "${_external_unknown_count}")" ;;
    esac
    _omc_canonical_uint_in_range \
      "${_external_doc_count}" 0 "${_MARK_EDIT_UINT_MAX}" \
      || _external_doc_count=0
    _omc_canonical_uint_in_range \
      "${_external_ui_count}" 0 "${_MARK_EDIT_UINT_MAX}" \
      || _external_ui_count=0
    _omc_canonical_uint_in_range \
      "${_external_native_count}" 0 "${_MARK_EDIT_UINT_MAX}" \
      || _external_native_count=0
    _omc_canonical_uint_in_range \
      "${_external_unknown_count}" 0 "${_MARK_EDIT_UINT_MAX}" \
      || _external_unknown_count=0
    _external_event_args=(
      "last_external_edit_ts" "${now}"
      "last_external_edit_revision" "${_next_revision}"
      "external_edit_scope" "${external_surface}"
      "external_edit_event_count" "${_external_event_count}"
      "external_doc_edit_event_count" "${_external_doc_count}"
      "external_ui_edit_event_count" "${_external_ui_count}"
      "external_native_edit_event_count" "${_external_native_count}"
      "external_unknown_edit_event_count" "${_external_unknown_count}"
    )

    local -a _external_args=(
      "last_edit_ts" "${now}"
      "edit_revision" "${_next_revision}"
      "last_edit_prompt_revision" "${_prompt_revision}"
      "stop_guard_blocks" "0"
      "session_handoff_blocks" "0"
      "advisory_guard_blocks" "0"
      "stall_counter" "0"
      "${_external_event_args[@]}"
    )
    case "${external_surface}" in
      doc)
        _external_args+=(
          "last_doc_edit_ts" "${now}"
          "last_doc_edit_revision" "${_next_revision}"
        )
        ;;
      ui)
        _external_args+=(
          "last_code_edit_ts" "${now}"
          "last_code_edit_revision" "${_next_revision}"
          "last_ui_edit_ts" "${now}"
          "last_ui_edit_revision" "${_next_revision}"
        )
        ;;
      native)
        _external_args+=(
          "last_code_edit_ts" "${now}"
          "last_code_edit_revision" "${_next_revision}"
          "last_doc_edit_ts" "${now}"
          "last_doc_edit_revision" "${_next_revision}"
          "last_ui_edit_ts" "${now}"
          "last_ui_edit_revision" "${_next_revision}"
        )
        ;;
      *)
        _external_args+=(
          "last_code_edit_ts" "${now}"
          "last_code_edit_revision" "${_next_revision}"
        )
        if [[ "$(read_state "review_cycle_ui_semantic")" == "1" ]]; then
          _external_args+=(
            "last_ui_edit_ts" "${now}"
            "last_ui_edit_revision" "${_next_revision}"
          )
        fi
        if [[ "$(read_state "review_cycle_prose_semantic")" == "1" ]]; then
          _external_args+=(
            "last_doc_edit_ts" "${now}"
            "last_doc_edit_revision" "${_next_revision}"
          )
        fi
        ;;
    esac
    write_state_batch "${_external_args[@]}"
  elif [[ "${is_doc}" -eq 1 ]]; then
    local _doc_args=(
      "last_edit_ts" "${now}"
      "last_doc_edit_ts" "${now}"
      "edit_revision" "${_next_revision}"
      "last_edit_prompt_revision" "${_prompt_revision}"
      "last_doc_edit_revision" "${_next_revision}"
      "stop_guard_blocks" "0"
      "session_handoff_blocks" "0"
      "advisory_guard_blocks" "0"
      "stall_counter" "0"
    )
    write_state_batch "${_doc_args[@]}"
  elif [[ "${tool_name}" == "Bash" && -z "${edited_path}" ]]; then
    # A monotonic event counter, not the second-resolution timestamp, scopes
    # unknown-path Bash work to a fresh review objective. The global edit
    # revision independently makes reviews/tests stale even in the same second.
    _bash_event_count="$(read_state "bash_edit_event_count")"
    _bash_event_count="$(_mark_edit_next_counter "${_bash_event_count}")"
    local _unknown_args=(
      "last_edit_ts" "${now}"
      "last_code_edit_ts" "${now}"
      "last_bash_edit_ts" "${now}"
      "edit_revision" "${_next_revision}"
      "last_edit_prompt_revision" "${_prompt_revision}"
      "last_code_edit_revision" "${_next_revision}"
      "last_bash_edit_revision" "${_next_revision}"
      "bash_edit_event_count" "${_bash_event_count}"
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
      "last_edit_prompt_revision" "${_prompt_revision}"
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
    is_ultrawork_mode || return 0
    if [[ -f "${log_path}" ]] && grep -Fxq -- "${edited_path}" "${log_path}"; then
      _seen=1
    fi
    printf '%s\n' "${edited_path}" >>"${log_path}"

    if [[ "${_seen}" -eq 0 ]]; then
      if [[ "${is_doc}" -eq 1 ]]; then
        local _doc_count
        _doc_count="$(read_state "doc_edit_count")"
        _doc_count="$(_mark_edit_next_counter "${_doc_count}")"
        write_state "doc_edit_count" "${_doc_count}"
      else
        local _code_count
        _code_count="$(read_state "code_edit_count")"
        _code_count="$(_mark_edit_next_counter "${_code_count}")"
        write_state "code_edit_count" "${_code_count}"
        # Track UI file edits separately for the design_quality dimension.
        # UI is a subset of code — both counters increment.
        if [[ "${is_ui}" -eq 1 ]]; then
          local _ui_count
          _ui_count="$(read_state "ui_edit_count")"
          _ui_count="$(_mark_edit_next_counter "${_ui_count}")"
          write_state "ui_edit_count" "${_ui_count}"
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
