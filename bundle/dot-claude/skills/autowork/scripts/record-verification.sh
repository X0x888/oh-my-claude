#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

# v1.27.0 (F-020 / F-021): record/edit hooks have no classifier or timing-lib
# dependency — opt out of eager source for both libs.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
# v1.47 (sre-lens R-1): observable fail-open for verification-evidence capture.
omc_arm_failopen_err_trap "record-verification" "(verification evidence for this tool result was not recorded)"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi
capture_ulw_enforcement_interval || exit 0

# Determine verification source: Bash command or MCP tool
tool_name="$(json_get '.tool_name' 2>/dev/null || true)"
command_text=""
mcp_verify_type=""
tool_use_id="$(json_get '.tool_use_id' 2>/dev/null || true)"

if [[ "${tool_name}" == "Bash" || -z "${tool_name}" ]]; then
  command_text="$(json_get '.tool_input.command' 2>/dev/null || true)"
else
  # Check if this MCP tool qualifies as verification
  mcp_verify_type="$(classify_mcp_verification_tool "${tool_name}")"
fi

_verification_start_path() {
  local _id="$1" _digest=""
  [[ -n "${_id}" ]] || return 1
  _digest="$(_omc_token_digest "${_id}" 2>/dev/null || true)"
  [[ -n "${_digest}" ]] || return 1
  printf '%s/%s/.verification-starts/%s.json\n' \
    "${STATE_ROOT}" "${SESSION_ID}" "${_digest}"
}

_discard_verification_start_locked() {
  local _path=""
  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  [[ -n "${_path}" ]] && rm -f "${_path}" 2>/dev/null || true
}

# Consume the PreToolUse snapshot and persist the result under one state lock.
# Return codes 10-13 are expected fail-closed rejections, not hook crashes.
# In every rejection path, prior last_verify_* evidence stays untouched.
_record_verification_state() {
  local _path="" _start_revision="" _stored_id="" _stored_tool=""
  local _current_revision="" _reason="" _stale_count=""

  # Stop or /ulw-off may have finalized this interval while the PostToolUse
  # callback waited for the session lock. Never publish late proof.
  is_ultrawork_mode || return 20

  _path="$(_verification_start_path "${tool_use_id}" 2>/dev/null || true)"
  _current_revision="$(read_state "last_code_edit_revision")"
  [[ "${_current_revision}" =~ ^[0-9]+$ ]] || _current_revision="0"

  if [[ -z "${tool_use_id}" ]] || [[ -z "${_path}" ]] || [[ ! -f "${_path}" ]]; then
    _reason="missing_start_snapshot"
  else
    _stored_id="$(jq -r '.tool_use_id // empty' "${_path}" 2>/dev/null || true)"
    _stored_tool="$(jq -r '.tool_name // empty' "${_path}" 2>/dev/null || true)"
    _start_revision="$(jq -r '.code_revision // empty' "${_path}" 2>/dev/null || true)"
    # Consume before any state write so a duplicate completion cannot replay
    # the same dispatch evidence. The enclosing state lock serializes peers.
    rm -f "${_path}" 2>/dev/null || true

    if [[ "${_stored_id}" != "${tool_use_id}" ]] \
        || [[ "${_stored_tool}" != "${tool_name}" ]]; then
      _reason="start_snapshot_identity_mismatch"
    elif [[ ! "${_start_revision}" =~ ^[0-9]+$ ]]; then
      _reason="invalid_start_snapshot"
    elif [[ "${_start_revision}" != "${_current_revision}" ]]; then
      _reason="code_revision_changed"
    fi
  fi

  if [[ -n "${_reason}" ]]; then
    _stale_count="$(read_state "stale_verify_count")"
    [[ "${_stale_count}" =~ ^[0-9]+$ ]] || _stale_count="0"
    _stale_count=$((_stale_count + 1))
    _write_state_batch_unlocked \
      "last_stale_verify_ts" "$(now_epoch)" \
      "last_stale_verify_tool" "${tool_name}" \
      "last_stale_verify_reason" "${_reason}" \
      "last_stale_verify_start_code_revision" "${_start_revision}" \
      "last_stale_verify_current_code_revision" "${_current_revision}" \
      "stale_verify_count" "${_stale_count}"
    _OMC_VERIFY_REJECTION_REASON="${_reason}"
    _OMC_VERIFY_REJECTION_START="${_start_revision}"
    _OMC_VERIFY_REJECTION_CURRENT="${_current_revision}"
    case "${_reason}" in
      missing_start_snapshot) return 10 ;;
      code_revision_changed) return 11 ;;
      invalid_start_snapshot) return 12 ;;
      *) return 13 ;;
    esac
  fi

  _write_state_batch_unlocked "$@" \
    "last_verify_code_revision" "${_start_revision}"
}

_persist_verification_state() {
  local _rc=0
  _OMC_VERIFY_REJECTION_REASON=""
  _OMC_VERIFY_REJECTION_START=""
  _OMC_VERIFY_REJECTION_CURRENT=""
  with_state_lock _record_verification_state "$@" || _rc=$?

  if [[ "${_rc}" -ge 10 && "${_rc}" -le 13 ]]; then
    log_hook "record-verification" \
      "rejected result tool=${tool_name} reason=${_OMC_VERIFY_REJECTION_REASON} start_revision=${_OMC_VERIFY_REJECTION_START} current_revision=${_OMC_VERIFY_REJECTION_CURRENT}"
    record_gate_event "verification" "stale-result-rejected" \
      "tool=${tool_name}" \
      "reason=${_OMC_VERIFY_REJECTION_REASON}" \
      "start_revision=${_OMC_VERIFY_REJECTION_START}" \
      "current_revision=${_OMC_VERIFY_REJECTION_CURRENT}" \
      2>/dev/null || true
    return 1
  elif [[ "${_rc}" -ne 0 ]]; then
    log_anomaly "record-verification" \
      "failed to atomically consume start snapshot and persist result rc=${_rc}"
    return 1
  fi
  return 0
}

_record_verification_receipt() {
  local command_safe="${1:-}" outcome="${2:-unknown}" confidence="${3:-unknown}"
  local method="${4:-unknown}" scope="${5:-unknown}" result_raw="${6:-}" result_excerpt row
  command_safe="$(printf '%s' "${command_safe}" | omc_redact_secrets | tr -d '\000')"
  command_safe="$(truncate_chars 500 "${command_safe}")"
  result_excerpt="$(printf '%s\n' "${result_raw}" \
    | omc_redact_secrets \
    | tr -d '\000' \
    | grep -Ei '([0-9]+[[:space:]]+(passed|failed|errors?|tests?|specs?|checks?)|pass(ed)?|fail(ed)?|error|exit (code|status)|success)' 2>/dev/null \
    | tail -5 \
    | tr '\n\r\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g' || true)"
  result_excerpt="$(truncate_chars 500 "${result_excerpt:-${outcome}}")"
  row="$(jq -nc \
    --argjson ts "$(now_epoch)" \
    --arg cycle "$(read_state "review_cycle_id" 2>/dev/null || true)" \
    --arg command "${command_safe}" \
    --arg outcome "${outcome}" \
    --arg confidence "${confidence}" \
    --arg method "${method}" \
    --arg scope "${scope}" \
    --arg result "${result_excerpt}" \
    --arg revision "$(read_state "last_code_edit_revision" 2>/dev/null || true)" \
    '{ts:$ts,review_cycle_id:$cycle,command:$command,outcome:$outcome,confidence:$confidence,method:$method,scope:$scope,result:$result,code_revision:$revision}')" || return 0
  append_limited_state "verification_receipts.jsonl" "${row}" "20" 2>/dev/null || true
}

# The dispatcher runs mark-edit before this handler. When that handler proved
# (or conservatively recorded) an edit-bearing Bash call, it leaves a per-tool marker here.
# A compound `tests; mutate` call must not count as verification of the bytes
# written after the tests; conservatively require a separate verification
# call for every edit-bearing Bash invocation, regardless of segment order.
if [[ "${tool_name}" == "Bash" ]] && [[ -n "${command_text}" ]]; then
  tool_cwd="$(json_get '.cwd' 2>/dev/null || true)"
  tool_cwd="${tool_cwd:-${PWD}}"
  if consume_bash_edit_outcome "${tool_use_id}" "${tool_cwd}" "${command_text}"; then
    with_state_lock _discard_verification_start_locked || true
    log_hook "record-verification" "skipped compound Bash verification because the same tool call changed the worktree"
    exit 0
  fi
fi

# Exit if neither Bash verification command nor MCP verification tool
if [[ -z "${command_text}" && -z "${mcp_verify_type}" ]]; then
  with_state_lock _discard_verification_start_locked || true
  exit 0
fi

# Extract tool output (shared by both paths)
tool_output="$(json_get '.tool_response' 2>/dev/null || true)"
if [[ -z "${tool_output}" ]]; then
  tool_output="$(json_get '.tool_result' 2>/dev/null || true)"
fi

# --- Path 1: Bash command verification ---
if [[ -n "${command_text}" ]]; then

  custom_patterns=""
  conf_file="${HOME}/.claude/oh-my-claude.conf"
  if [[ -f "${conf_file}" ]]; then
    custom_patterns="$(grep -E '^custom_verify_patterns=' "${conf_file}" | head -1 | cut -d= -f2-)" || true
  fi

  builtin_pattern='(^|[[:space:]])(npm|pnpm|yarn|bun|cargo|go|pytest|python|uv|ruff|mypy|eslint|tsc|vitest|jest|phpunit|rspec|gradle|xcodebuild|swift|make|just|bash|docker|terraform|ansible|helm|kubectl|mvn|maven|dotnet|mix|elixir|ruby|bundle|rake|zig|deno|nix|markdownlint|mdl|vale|textlint|alex|aspell|hunspell|languagetool|write-good)([[:space:]].*)?(test|tests|check|lint|typecheck|build|validate|verify|plan|apply)|\b(pytest|vitest|jest|cargo test|go test|swift test|swift build|ruff check|mypy|eslint|tsc|typecheck|phpunit|rspec|gradle test|xcodebuild test|shellcheck|bash -n|docker build|docker compose build|terraform plan|terraform validate|ansible-lint|helm lint|mvn test|mvn verify|dotnet test|mix test|bundle exec rspec|rake test|zig build|deno test|nix build|markdownlint|mdl|vale|textlint|alex|write-good)\b'
  if [[ -n "${custom_patterns}" ]]; then
    _custom_rc=0
    printf 'test' | grep -Eq "${custom_patterns}" 2>/dev/null || _custom_rc=$?
    if [[ "${_custom_rc}" -eq 2 ]]; then
      log_hook "record-verification" "invalid custom_verify_patterns syntax, ignoring"
    else
      builtin_pattern="${builtin_pattern}|${custom_patterns}"
    fi
  fi

  if grep -Eiq "${builtin_pattern}" <<<"${command_text}" 2>/dev/null; then

    verify_outcome="passed"
    if [[ -n "${tool_output}" ]]; then
      if printf '%s' "${tool_output}" | grep -Eq '\b(FAIL(ED)?|ERROR(S)?|FAILURE(S)?)\b|error\[E[0-9]' \
        || printf '%s' "${tool_output}" | grep -Eiq 'exit (code|status)[: ]*[1-9]|[1-9][0-9]* (failed|failing|failures?|errors?)'; then
        verify_outcome="failed"
      fi
    fi
    if omc_hook_tool_failed "${HOOK_JSON}"; then
      verify_outcome="failed"
    fi

    project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
    if [[ -z "${project_test_cmd}" ]]; then
      project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
    fi

    verify_confidence="$(score_verification_confidence "${command_text}" "${tool_output}" "${project_test_cmd}")"
    verify_method="$(detect_verification_method "${command_text}" "${tool_output}" "${project_test_cmd}")"
    verify_scope="$(classify_verification_scope "${command_text}" "${project_test_cmd}")"
    # v1.27.0 (F-023): persist per-factor breakdown so /ulw-status can
    # explain WHY a verification scored what it did. Empty/short cmds
    # produce "test_match:0|framework:0|output_counts:0|clear_outcome:0|total:0".
    verify_factors="$(score_verification_confidence_factors "${command_text}" "${tool_output}" "${project_test_cmd}")"

    # v1.34.1+ (security-lens Z-003): redact obvious secret patterns
    # from the captured verification command BEFORE persisting to state.
    # Closes a real leak: a model running `pytest --auth-token=$X tests/`
    # would otherwise land $X verbatim in last_verify_cmd, where
    # omc-repro bundles it for support tarballs. Cap to 500 chars too.
    last_verify_cmd_safe="$(printf '%s' "${command_text}" | omc_redact_secrets | tr -d '\000')"
    last_verify_cmd_safe="$(truncate_chars 500 "${last_verify_cmd_safe}")"
    if _persist_verification_state \
      "last_verify_ts" "$(now_epoch)" \
      "last_verify_cmd" "${last_verify_cmd_safe}" \
      "last_verify_outcome" "${verify_outcome}" \
      "last_verify_confidence" "${verify_confidence}" \
      "last_verify_factors" "${verify_factors}" \
      "last_verify_method" "${verify_method}" \
      "last_verify_scope" "${verify_scope}" \
      "project_test_cmd" "${project_test_cmd}" \
      "stop_guard_blocks" "0" \
      "session_handoff_blocks" "0" \
      "stall_counter" "0"; then
      _record_verification_receipt "${last_verify_cmd_safe}" "${verify_outcome}" \
        "${verify_confidence}" "${verify_method}" "${verify_scope}" "${tool_output}"
      log_hook "record-verification" "cmd=${command_text} outcome=${verify_outcome} confidence=${verify_confidence} method=${verify_method} scope=${verify_scope}"
    fi
  else
    # The PreToolUse recorder snapshots all Bash calls because command
    # classification can evolve independently. Non-verification completions
    # consume their snapshot so long sessions do not accumulate sidecars.
    with_state_lock _discard_verification_start_locked || true
  fi

# --- Path 2: MCP tool verification ---
elif [[ -n "${mcp_verify_type}" ]]; then

  # Determine UI context: did recent edits include UI files?
  has_ui_context="false"
  edited_log="$(session_file "edited_files.log" 2>/dev/null || true)"
  if [[ -f "${edited_log}" ]]; then
    while IFS= read -r _path; do
      if is_ui_path "${_path}"; then
        has_ui_context="true"
        break
      fi
    done < <(sort -u "${edited_log}" 2>/dev/null || true)
  fi

  verify_outcome="$(detect_mcp_verification_outcome "${tool_output}" "${mcp_verify_type}")"
  verify_confidence="$(score_mcp_verification_confidence "${mcp_verify_type}" "${tool_output}" "${has_ui_context}")"
  verify_scope="mcp_${mcp_verify_type}"

  # Detect project test command for remediation messaging (shared with Bash path)
  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  if [[ -z "${project_test_cmd}" ]]; then
    project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  fi

  if _persist_verification_state \
    "last_verify_ts" "$(now_epoch)" \
    "last_verify_cmd" "${tool_name}" \
    "last_verify_outcome" "${verify_outcome}" \
    "last_verify_confidence" "${verify_confidence}" \
    "last_verify_method" "mcp_${mcp_verify_type}" \
    "last_verify_scope" "${verify_scope}" \
    "project_test_cmd" "${project_test_cmd}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "stall_counter" "0"; then
    _record_verification_receipt "${tool_name}" "${verify_outcome}" \
      "${verify_confidence}" "mcp_${mcp_verify_type}" "${verify_scope}" "${tool_output}"
    log_hook "record-verification" "mcp_tool=${tool_name} type=${mcp_verify_type} outcome=${verify_outcome} confidence=${verify_confidence} scope=${verify_scope}"
  fi
fi
