#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_PATCH="${REPO_ROOT}/config/settings.patch.json"

pass=0
fail=0

TEST_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s\n    expected=%s actual=%s\n' "${label}" "${expected}" "${actual}" >&2
    fail=$((fail + 1))
  fi
}

assert_json_eq() {
  local label="$1"
  local file="$2"
  local query="$3"
  local expected="$4"
  local actual
  actual="$(jq -r "${query}" "${file}" 2>/dev/null || echo "__JQ_ERROR__")"
  assert_eq "${label}" "${expected}" "${actual}"
}

assert_json_count() {
  local label="$1"
  local file="$2"
  local query="$3"
  local expected="$4"
  local actual
  actual="$(jq "${query} | length" "${file}" 2>/dev/null || echo "-1")"
  assert_eq "${label}" "${expected}" "${actual}"
}

# ---------------------------------------------------------------------------
# Extract merge functions from install.sh
# ---------------------------------------------------------------------------

# Source only the merge functions by extracting them.
# merge_settings_python() and merge_settings_jq() are self-contained.
# The sed pattern relies on the closing } at column 0. If extraction breaks
# (e.g. due to a refactor adding } at column 0 mid-function), the declare
# check below will catch it immediately.
eval "$(sed -n '/^merge_settings_python()/,/^}/p' "${REPO_ROOT}/install.sh")"
eval "$(sed -n '/^merge_settings_jq()/,/^}/p' "${REPO_ROOT}/install.sh")"

if ! declare -f merge_settings_python >/dev/null 2>&1; then
  printf 'ERROR: Failed to extract merge_settings_python from install.sh\n' >&2
  exit 1
fi
if ! declare -f merge_settings_jq >/dev/null 2>&1; then
  printf 'ERROR: Failed to extract merge_settings_jq from install.sh\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect available merge implementations
# ---------------------------------------------------------------------------

implementations=()
if command -v python3 >/dev/null 2>&1; then
  implementations+=("python")
fi
if command -v jq >/dev/null 2>&1; then
  implementations+=("jq")
fi

if [[ ${#implementations[@]} -eq 0 ]]; then
  printf 'ERROR: Need python3 or jq to run settings merge tests.\n' >&2
  exit 1
fi

run_merge() {
  local impl="$1"
  local settings_path="$2"
  local patch_path="$3"
  local bypass="$4"
  if [[ "${impl}" == "python" ]]; then
    merge_settings_python "${settings_path}" "${patch_path}" "${bypass}"
  else
    merge_settings_jq "${settings_path}" "${patch_path}" "${bypass}"
  fi
}

# ===========================================================================
# Test suite — run once per available implementation
# ===========================================================================

for impl in "${implementations[@]}"; do
  printf 'Testing %s implementation...\n' "${impl}"

  # -----------------------------------------------------------------------
  # Test 1: Fresh install (no existing settings.json)
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-fresh"
  mkdir -p "${work}"

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  assert_json_eq "${impl}: fresh — statusLine.type" \
    "${work}/settings.json" '.statusLine.type' "command"
  assert_json_eq "${impl}: fresh — outputStyle" \
    "${work}/settings.json" '.outputStyle' "OpenCode Compact"
  assert_json_eq "${impl}: fresh — effortLevel" \
    "${work}/settings.json" '.effortLevel' "high"
  assert_json_eq "${impl}: fresh — spinnerTipsEnabled" \
    "${work}/settings.json" '.spinnerTipsEnabled' "false"
  assert_json_count "${impl}: fresh — spinnerVerbs.verbs count" \
    "${work}/settings.json" '.spinnerVerbs.verbs' "4"

  # Hooks should be present for all registered events
  assert_json_count "${impl}: fresh — SessionStart hooks" \
    "${work}/settings.json" '.hooks.SessionStart' "2"
  assert_json_count "${impl}: fresh — UserPromptSubmit hooks" \
    "${work}/settings.json" '.hooks.UserPromptSubmit' "1"
  assert_json_count "${impl}: fresh — PostToolUse hooks" \
    "${work}/settings.json" '.hooks.PostToolUse' "4"
  assert_json_count "${impl}: fresh — SubagentStop hooks" \
    "${work}/settings.json" '.hooks.SubagentStop' "10"
  assert_json_count "${impl}: fresh — PreCompact hooks" \
    "${work}/settings.json" '.hooks.PreCompact' "1"
  assert_json_count "${impl}: fresh — PostCompact hooks" \
    "${work}/settings.json" '.hooks.PostCompact' "1"
  assert_json_count "${impl}: fresh — Stop hooks" \
    "${work}/settings.json" '.hooks.Stop' "1"

  # No bypass keys should be set
  assert_json_eq "${impl}: fresh — no defaultMode" \
    "${work}/settings.json" '.permissions.defaultMode // "null"' "null"
  assert_json_eq "${impl}: fresh — no skipDangerousMode" \
    "${work}/settings.json" '.skipDangerousModePermissionPrompt // "null"' "null"

  # -----------------------------------------------------------------------
  # Test 2: Idempotency — merge again, counts should not double
  # -----------------------------------------------------------------------
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  assert_json_count "${impl}: idempotent — SessionStart hooks still 2" \
    "${work}/settings.json" '.hooks.SessionStart' "2"
  assert_json_count "${impl}: idempotent — SubagentStop hooks still 10" \
    "${work}/settings.json" '.hooks.SubagentStop' "10"
  assert_json_count "${impl}: idempotent — PostToolUse hooks still 4" \
    "${work}/settings.json" '.hooks.PostToolUse' "4"

  # Verify the new dimension-tracker matchers are present
  assert_json_eq "${impl}: fresh — metis matcher wired" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "metis") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh stress_test")' \
    "true"
  assert_json_eq "${impl}: fresh — briefing-analyst matcher wired" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "briefing-analyst") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh traceability")' \
    "true"
  assert_json_eq "${impl}: fresh — editor-critic uses prose arg" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh prose")' \
    "true"

  # -----------------------------------------------------------------------
  # Test 3: Bypass-permissions mode
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-bypass"
  mkdir -p "${work}"

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "true"

  assert_json_eq "${impl}: bypass — defaultMode set" \
    "${work}/settings.json" '.permissions.defaultMode' "bypassPermissions"
  assert_json_eq "${impl}: bypass — skipDangerousMode set" \
    "${work}/settings.json" '.skipDangerousModePermissionPrompt' "true"

  # -----------------------------------------------------------------------
  # Test 4: Preserves user's existing outputStyle and effortLevel
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-preserve"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "outputStyle": "Custom User Style",
  "effortLevel": "low",
  "userSetting": "should-survive"
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  assert_json_eq "${impl}: preserve — outputStyle kept" \
    "${work}/settings.json" '.outputStyle' "Custom User Style"
  assert_json_eq "${impl}: preserve — effortLevel kept" \
    "${work}/settings.json" '.effortLevel' "low"
  assert_json_eq "${impl}: preserve — user setting survives" \
    "${work}/settings.json" '.userSetting' "should-survive"

  # statusLine is always overwritten (not setdefault)
  assert_json_eq "${impl}: preserve — statusLine overwritten" \
    "${work}/settings.json" '.statusLine.type' "command"

  # -----------------------------------------------------------------------
  # Test 5: Pre-existing hooks from another plugin are preserved
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-existing-hooks"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "custom-matcher",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom-hook"
          }
        ]
      }
    ],
    "CustomEvent": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo my-custom-event"
          }
        ]
      }
    ]
  }
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  # Our hook is added alongside the custom one
  assert_json_count "${impl}: existing hooks — UserPromptSubmit has both" \
    "${work}/settings.json" '.hooks.UserPromptSubmit' "2"

  # Custom event is preserved
  assert_json_count "${impl}: existing hooks — CustomEvent preserved" \
    "${work}/settings.json" '.hooks.CustomEvent' "1"

  # -----------------------------------------------------------------------
  # Test 6: Output is valid JSON
  # -----------------------------------------------------------------------
  if jq empty "${work}/settings.json" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf '  FAIL: %s: output is not valid JSON\n' "${impl}" >&2
    fail=$((fail + 1))
  fi

  printf '  %s implementation done.\n' "${impl}"
done

# ===========================================================================
# Cross-implementation consistency (if both are available)
# ===========================================================================

if [[ ${#implementations[@]} -eq 2 ]]; then
  printf 'Testing cross-implementation consistency...\n'

  work_py="${TEST_DIR}/cross-python"
  work_jq="${TEST_DIR}/cross-jq"
  mkdir -p "${work_py}" "${work_jq}"

  # Same input: fresh install without bypass
  run_merge "python" "${work_py}/settings.json" "${SETTINGS_PATCH}" "false"
  run_merge "jq" "${work_jq}/settings.json" "${SETTINGS_PATCH}" "false"

  # Compare hook counts (structural equivalence — key ordering may differ)
  for event in SessionStart UserPromptSubmit PostToolUse PreCompact PostCompact SubagentStop Stop; do
    py_count="$(jq ".hooks.${event} | length" "${work_py}/settings.json" 2>/dev/null || echo "-1")"
    jq_count="$(jq ".hooks.${event} | length" "${work_jq}/settings.json" 2>/dev/null || echo "-1")"
    assert_eq "cross: ${event} hook count matches" "${py_count}" "${jq_count}"
  done

  # Compare top-level keys
  for key in outputStyle effortLevel spinnerTipsEnabled; do
    py_val="$(jq -r ".${key}" "${work_py}/settings.json")"
    jq_val="$(jq -r ".${key}" "${work_jq}/settings.json")"
    assert_eq "cross: ${key} matches" "${py_val}" "${jq_val}"
  done

  printf '  Cross-implementation tests done.\n'
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Settings merge tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
