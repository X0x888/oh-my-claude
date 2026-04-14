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

command_text="$(json_get '.tool_input.command')"
if [[ -z "${command_text}" ]]; then
  exit 0
fi

custom_patterns=""
conf_file="${HOME}/.claude/oh-my-claude.conf"
if [[ -f "${conf_file}" ]]; then
  custom_patterns="$(grep -E '^custom_verify_patterns=' "${conf_file}" | head -1 | cut -d= -f2-)" || true
fi

builtin_pattern='(^|[[:space:]])(npm|pnpm|yarn|bun|cargo|go|pytest|python|uv|ruff|mypy|eslint|tsc|vitest|jest|phpunit|rspec|gradle|xcodebuild|swift|make|just|bash|docker|terraform|ansible|helm|kubectl|mvn|maven|dotnet|mix|elixir|ruby|bundle|rake|zig|deno|nix|markdownlint|mdl|vale|textlint|alex|aspell|hunspell|languagetool|write-good)([[:space:]].*)?(test|tests|check|lint|typecheck|build|validate|verify|plan|apply)|\b(pytest|vitest|jest|cargo test|go test|swift test|swift build|ruff check|mypy|eslint|tsc|typecheck|phpunit|rspec|gradle test|xcodebuild test|shellcheck|bash -n|docker build|docker compose build|terraform plan|terraform validate|ansible-lint|helm lint|mvn test|mvn verify|dotnet test|mix test|bundle exec rspec|rake test|zig build|deno test|nix build|markdownlint|mdl|vale|textlint|alex|write-good)\b'
if [[ -n "${custom_patterns}" ]]; then
  # Validate the custom pattern syntax before concatenating. grep -E
  # returns exit 2 for invalid regex (vs 1 for "no match"). We test
  # against a dummy string to distinguish syntax errors from no-match.
  _custom_rc=0
  printf 'test' | grep -Eq "${custom_patterns}" 2>/dev/null || _custom_rc=$?
  if [[ "${_custom_rc}" -eq 2 ]]; then
    log_hook "record-verification" "invalid custom_verify_patterns syntax, ignoring"
  else
    builtin_pattern="${builtin_pattern}|${custom_patterns}"
  fi
fi

if grep -Eiq "${builtin_pattern}" <<<"${command_text}" 2>/dev/null; then

  # Detect test outcome from tool response (field may be tool_response or tool_result)
  tool_output="$(json_get '.tool_response' 2>/dev/null || true)"
  if [[ -z "${tool_output}" ]]; then
    tool_output="$(json_get '.tool_result' 2>/dev/null || true)"
  fi

  verify_outcome="passed"
  if [[ -n "${tool_output}" ]]; then
    # Case-sensitive: uppercase framework indicators (FAIL, FAILED, ERROR, FAILURES)
    # Case-sensitive: Rust compiler errors (error[E0308])
    # Case-insensitive: count patterns ("3 failed", "2 failures") and exit codes
    if printf '%s' "${tool_output}" | grep -Eq '\b(FAIL(ED)?|ERROR(S)?|FAILURE(S)?)\b|error\[E[0-9]' \
      || printf '%s' "${tool_output}" | grep -Eiq 'exit (code|status)[: ]*[1-9]|[1-9][0-9]* (failed|failing|failures?|errors?)'; then
      verify_outcome="failed"
    fi
  fi

  # Compute verification confidence score (0-100)
  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  if [[ -z "${project_test_cmd}" ]]; then
    project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  fi

  verify_confidence="$(score_verification_confidence "${command_text}" "${tool_output}" "${project_test_cmd}")"
  verify_method="$(detect_verification_method "${command_text}" "${tool_output}" "${project_test_cmd}")"

  with_state_lock_batch \
    "last_verify_ts" "$(now_epoch)" \
    "last_verify_cmd" "${command_text}" \
    "last_verify_outcome" "${verify_outcome}" \
    "last_verify_confidence" "${verify_confidence}" \
    "last_verify_method" "${verify_method}" \
    "project_test_cmd" "${project_test_cmd}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "stall_counter" "0"
  log_hook "record-verification" "cmd=${command_text} outcome=${verify_outcome} confidence=${verify_confidence} method=${verify_method}"
fi
