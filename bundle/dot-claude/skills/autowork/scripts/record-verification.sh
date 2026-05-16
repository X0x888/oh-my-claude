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
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

# Determine verification source: Bash command or MCP tool
tool_name="$(json_get '.tool_name' 2>/dev/null || true)"
command_text=""
mcp_verify_type=""

if [[ "${tool_name}" == "Bash" || -z "${tool_name}" ]]; then
  command_text="$(json_get '.tool_input.command' 2>/dev/null || true)"
else
  # Check if this MCP tool qualifies as verification
  mcp_verify_type="$(classify_mcp_verification_tool "${tool_name}")"
fi

# Exit if neither Bash verification command nor MCP verification tool
if [[ -z "${command_text}" && -z "${mcp_verify_type}" ]]; then
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
    with_state_lock_batch \
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
      "stall_counter" "0"
    log_hook "record-verification" "cmd=${command_text} outcome=${verify_outcome} confidence=${verify_confidence} method=${verify_method} scope=${verify_scope}"
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

  with_state_lock_batch \
    "last_verify_ts" "$(now_epoch)" \
    "last_verify_cmd" "${tool_name}" \
    "last_verify_outcome" "${verify_outcome}" \
    "last_verify_confidence" "${verify_confidence}" \
    "last_verify_method" "mcp_${mcp_verify_type}" \
    "last_verify_scope" "${verify_scope}" \
    "project_test_cmd" "${project_test_cmd}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "stall_counter" "0"
  log_hook "record-verification" "mcp_tool=${tool_name} type=${mcp_verify_type} outcome=${verify_outcome} confidence=${verify_confidence} scope=${verify_scope}"
fi
