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

if grep -Eiq '(^|[[:space:]])(npm|pnpm|yarn|bun|cargo|go|pytest|python|uv|ruff|mypy|eslint|tsc|vitest|jest|phpunit|rspec|gradle|xcodebuild|swift|make|just|bash)([[:space:]].*)?(test|tests|check|lint|typecheck|build)|\b(pytest|vitest|jest|cargo test|go test|swift test|swift build|ruff check|mypy|eslint|tsc|typecheck|phpunit|rspec|gradle test|xcodebuild test|shellcheck|bash -n)\b' <<<"${command_text}"; then

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

  write_state_batch \
    "last_verify_ts" "$(now_epoch)" \
    "last_verify_cmd" "${command_text}" \
    "last_verify_outcome" "${verify_outcome}" \
    "stop_guard_blocks" "0" \
    "session_handoff_blocks" "0" \
    "stall_counter" "0"
fi
