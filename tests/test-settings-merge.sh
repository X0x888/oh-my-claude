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
    "${work}/settings.json" '.outputStyle' "oh-my-claude"
  assert_json_eq "${impl}: fresh — effortLevel" \
    "${work}/settings.json" '.effortLevel' "high"
  assert_json_eq "${impl}: fresh — spinnerTipsEnabled" \
    "${work}/settings.json" '.spinnerTipsEnabled' "false"
  assert_json_count "${impl}: fresh — spinnerVerbs.verbs count" \
    "${work}/settings.json" '.spinnerVerbs.verbs' "4"

  # Hooks should be present for all registered events. v1.30.0 added
  # session-start-welcome.sh as the 4th SessionStart entry. v1.36.x W1
  # F-005 added session-start-drift-check.sh as the 5th — surfaces
  # installed-vs-source bundle drift via additionalContext so the model
  # sees stale-bundle risk before relying on /ulw gates. v1.37.x W2
  # F-007 added session-start-whats-new.sh as the 6th — surfaces a
  # one-shot "you upgraded — run /whats-new" notice the first session
  # after the installed_version changes.
  assert_json_count "${impl}: fresh — SessionStart hooks" \
    "${work}/settings.json" '.hooks.SessionStart' "6"
  assert_json_eq "${impl}: fresh — SessionStart wires session-start-resume-hint.sh" \
    "${work}/settings.json" \
    '[.hooks.SessionStart[] | .hooks[0].command] | any(. | tostring | contains("session-start-resume-hint.sh"))' \
    "true"
  assert_json_eq "${impl}: fresh — SessionStart wires session-start-welcome.sh" \
    "${work}/settings.json" \
    '[.hooks.SessionStart[] | .hooks[0].command] | any(. | tostring | contains("session-start-welcome.sh"))' \
    "true"
  assert_json_eq "${impl}: fresh — SessionStart wires session-start-drift-check.sh" \
    "${work}/settings.json" \
    '[.hooks.SessionStart[] | .hooks[0].command] | any(. | tostring | contains("session-start-drift-check.sh"))' \
    "true"
  assert_json_eq "${impl}: fresh — SessionStart wires session-start-whats-new.sh" \
    "${work}/settings.json" \
    '[.hooks.SessionStart[] | .hooks[0].command] | any(. | tostring | contains("session-start-whats-new.sh"))' \
    "true"
  assert_json_count "${impl}: fresh — UserPromptSubmit hooks" \
    "${work}/settings.json" '.hooks.UserPromptSubmit' "1"
  assert_json_count "${impl}: fresh — PreToolUse hooks" \
    "${work}/settings.json" '.hooks.PreToolUse' "3"
  assert_json_count "${impl}: fresh — PostToolUse hooks" \
    "${work}/settings.json" '.hooks.PostToolUse' "7"
  assert_json_count "${impl}: fresh — SubagentStop hooks" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"
  assert_json_count "${impl}: fresh — PreCompact hooks" \
    "${work}/settings.json" '.hooks.PreCompact' "1"
  assert_json_count "${impl}: fresh — PostCompact hooks" \
    "${work}/settings.json" '.hooks.PostCompact' "1"
  assert_json_count "${impl}: fresh — Stop hooks" \
    "${work}/settings.json" '.hooks.Stop' "3"
  assert_json_count "${impl}: fresh — StopFailure hooks" \
    "${work}/settings.json" '.hooks.StopFailure' "1"
  assert_json_eq "${impl}: fresh — StopFailure wires stop-failure-handler.sh" \
    "${work}/settings.json" \
    '[.hooks.StopFailure[] | .hooks[0].command] | .[0] | tostring | contains("stop-failure-handler.sh")' \
    "true"

  # PreToolUse must wire the Agent matcher to record-pending-agent.sh
  assert_json_eq "${impl}: fresh — PreToolUse Agent matcher wired" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[0].command] | .[0] | tostring | contains("record-pending-agent.sh")' \
    "true"

  # PreToolUse must wire the Bash/Edit matcher to pretool-intent-guard.sh.
  # This is the enforcement backstop for advisory/session-management/checkpoint
  # intent, plus the agent-first floor for /ulw execution mutations.
  assert_json_eq "${impl}: fresh — PreToolUse mutation guard matcher wired" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select((.matcher // "") | test("Bash") and test("Edit") and test("Write") and test("MultiEdit")) | .hooks[0].command] | .[0] | tostring | contains("pretool-intent-guard.sh")' \
    "true"
  assert_json_eq "${impl}: fresh — PostToolUse Bash wires record-delivery-action.sh" \
    "${work}/settings.json" \
    '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[0].command] | any(. | tostring | contains("record-delivery-action.sh"))' \
    "true"
  assert_json_eq "${impl}: fresh — PostToolUse broad MCP matcher wires record-verification.sh" \
    "${work}/settings.json" \
    '[.hooks.PostToolUse[] | select(.matcher == "mcp__.*") | .hooks[0].command] | any(. | tostring | contains("record-verification.sh"))' \
    "true"

  # No bypass keys should be set
  assert_json_eq "${impl}: fresh — no defaultMode" \
    "${work}/settings.json" '.permissions.defaultMode // "null"' "null"
  assert_json_eq "${impl}: fresh — no skipDangerousMode" \
    "${work}/settings.json" '.skipDangerousModePermissionPrompt // "null"' "null"

  # -----------------------------------------------------------------------
  # Test 2: Idempotency — merge again, counts should not double
  # -----------------------------------------------------------------------
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  assert_json_count "${impl}: idempotent — SessionStart hooks still 6" \
    "${work}/settings.json" '.hooks.SessionStart' "6"
  assert_json_count "${impl}: idempotent — SubagentStop hooks still 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"
  assert_json_count "${impl}: idempotent — PostToolUse hooks still 7" \
    "${work}/settings.json" '.hooks.PostToolUse' "7"
  assert_json_count "${impl}: idempotent — PreToolUse hooks still 3" \
    "${work}/settings.json" '.hooks.PreToolUse' "3"
  assert_json_count "${impl}: idempotent — StopFailure hooks still 1" \
    "${work}/settings.json" '.hooks.StopFailure' "1"

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
  assert_json_eq "${impl}: fresh — design-reviewer matcher wired" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "design-reviewer") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh design_quality")' \
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
  # F-005: OMC_OUTPUT_STYLE_PREF=preserve skips the outputStyle merge
  # entirely, even on a fresh install where the key is unset. This is
  # the opt-out path for users who want install.sh to never touch their
  # outputStyle setting (or absence of it).
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-output-style-preserve-fresh"
  mkdir -p "${work}"
  printf '{}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="preserve" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005 — preserve skips outputStyle on fresh install" \
    "${work}/settings.json" '.outputStyle // "absent"' "absent"

  # -----------------------------------------------------------------------
  # F-005: OMC_OUTPUT_STYLE_PREF=preserve also leaves an existing custom
  # value alone (regression of Test 4 under the preserve flag — same
  # outcome, different code path).
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-output-style-preserve-custom"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "outputStyle": "Learning"
}
JSON
  OMC_OUTPUT_STYLE_PREF="preserve" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005 — preserve does not touch existing custom outputStyle" \
    "${work}/settings.json" '.outputStyle' "Learning"

  # -----------------------------------------------------------------------
  # F-005: OMC_OUTPUT_STYLE_PREF=opencode (or unset) keeps the historical
  # behavior — outputStyle merges when absent.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-output-style-opencode-default"
  mkdir -p "${work}"
  printf '{}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="opencode" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005 — opencode merges oh-my-claude" \
    "${work}/settings.json" '.outputStyle' "oh-my-claude"

  # -----------------------------------------------------------------------
  # F-005b: Legacy "OpenCode Compact" is migrated to "oh-my-claude" on
  # upgrade, regardless of output_style_pref.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-output-style-migration"
  mkdir -p "${work}"
  printf '{"outputStyle": "OpenCode Compact"}' > "${work}/settings.json"
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005b — legacy OpenCode Compact migrated to oh-my-claude" \
    "${work}/settings.json" '.outputStyle' "oh-my-claude"

  # Same migration should fire even under output_style=preserve.
  work="${TEST_DIR}/${impl}-output-style-migration-preserve"
  mkdir -p "${work}"
  printf '{"outputStyle": "OpenCode Compact"}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="preserve" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005b — legacy name migrated even under preserve" \
    "${work}/settings.json" '.outputStyle' "oh-my-claude"

  # -----------------------------------------------------------------------
  # F-005c: OMC_OUTPUT_STYLE_PREF=executive selects the bundled
  # executive-brief style on a fresh install. Three sub-cases pin the
  # bundled-sync semantics introduced when the second bundled style
  # shipped.
  # -----------------------------------------------------------------------

  # Sub-case 1: fresh install with executive pref → executive-brief.
  work="${TEST_DIR}/${impl}-output-style-executive-fresh"
  mkdir -p "${work}"
  printf '{}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="executive" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005c — executive merges executive-brief on fresh install" \
    "${work}/settings.json" '.outputStyle' "executive-brief"

  # Sub-case 2: existing oh-my-claude flips to executive-brief when the
  # conf flag is changed (the bundled-sync behavior — switching enums
  # should swap settings.outputStyle so /omc-config can move users
  # between bundled styles without manual settings.json edits).
  work="${TEST_DIR}/${impl}-output-style-executive-flip"
  mkdir -p "${work}"
  printf '{"outputStyle": "oh-my-claude"}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="executive" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005c — executive flips an existing oh-my-claude to executive-brief" \
    "${work}/settings.json" '.outputStyle' "executive-brief"

  # Sub-case 2b: existing executive-brief flips back to oh-my-claude
  # under the default opencode pref. Symmetric to sub-case 2.
  work="${TEST_DIR}/${impl}-output-style-opencode-flip-back"
  mkdir -p "${work}"
  printf '{"outputStyle": "executive-brief"}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="opencode" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005c — opencode flips an existing executive-brief back to oh-my-claude" \
    "${work}/settings.json" '.outputStyle' "oh-my-claude"

  # Sub-case 3: a custom user style is preserved even when executive
  # pref is set. The bundled-sync only fires for bundled-name values;
  # custom strings (Learning, Explanatory, user-named styles) are never
  # overwritten. This is the load-bearing "custom styles win" guarantee.
  work="${TEST_DIR}/${impl}-output-style-executive-custom-preserved"
  mkdir -p "${work}"
  printf '{"outputStyle": "Learning"}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="executive" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005c — executive preserves a custom user style" \
    "${work}/settings.json" '.outputStyle' "Learning"

  # Sub-case 4: legacy "OpenCode Compact" migrates to executive-brief
  # when the executive pref is set. Symmetric to F-005b's preserve case
  # — legacy names always migrate, but the target follows the
  # conf-resolved pref.
  work="${TEST_DIR}/${impl}-output-style-legacy-to-executive"
  mkdir -p "${work}"
  printf '{"outputStyle": "OpenCode Compact"}' > "${work}/settings.json"
  OMC_OUTPUT_STYLE_PREF="executive" run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: F-005c — legacy OpenCode Compact migrates to executive-brief under executive pref" \
    "${work}/settings.json" '.outputStyle' "executive-brief"

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

  # -----------------------------------------------------------------------
  # Test 7: Upgrade-merge regression — same matcher, different command.
  # Regression test for a bug where upgrading from an older install with
  # pre-existing SubagentStop matchers (e.g. editor-critic pointing to
  # record-reviewer.sh without args) would APPEND the new version (with
  # args) instead of REPLACING, producing duplicate entries that fire
  # incorrect dimension ticks. Signature must treat same-matcher + same
  # script basename as the same entry regardless of trailing arguments.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-upgrade"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"
          }
        ]
      },
      {
        "matcher": "excellence-reviewer",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"
          }
        ]
      }
    ]
  }
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  # After merge, SubagentStop should have exactly 12 entries (no duplicates).
  # v1.32.x added release-reviewer for cumulative-diff release-prep reviews.
  assert_json_count "${impl}: upgrade — no duplicate editor-critic/excellence-reviewer" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

  # The editor-critic matcher should appear exactly ONCE, with the new 'prose' arg.
  assert_json_eq "${impl}: upgrade — editor-critic count is 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"
  assert_json_eq "${impl}: upgrade — editor-critic command uses prose arg" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh prose")' \
    "true"

  # The excellence-reviewer matcher should appear exactly ONCE, with the new 'excellence' arg.
  assert_json_eq "${impl}: upgrade — excellence-reviewer count is 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "excellence-reviewer")] | length' \
    "1"
  assert_json_eq "${impl}: upgrade — excellence-reviewer command uses excellence arg" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "excellence-reviewer") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh excellence")' \
    "true"

  # metis and briefing-analyst should be present (fresh additions, no duplicate conflict).
  assert_json_eq "${impl}: upgrade — metis matcher present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "metis")] | length' \
    "1"
  assert_json_eq "${impl}: upgrade — briefing-analyst matcher present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "briefing-analyst")] | length' \
    "1"
  assert_json_eq "${impl}: upgrade — design-reviewer matcher present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "design-reviewer")] | length' \
    "1"

  # v1.32.x R2 fork: release-reviewer matcher present + uses release arg.
  assert_json_eq "${impl}: upgrade — release-reviewer matcher present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "release-reviewer")] | length' \
    "1"
  assert_json_eq "${impl}: upgrade — release-reviewer command uses release arg" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "release-reviewer") | .hooks[0].command] | .[0] | tostring | contains("record-reviewer.sh release")' \
    "true"

  # -----------------------------------------------------------------------
  # Test 8: Customization preservation — a user matcher with the same name
  # but pointing to a DIFFERENT script should NOT be clobbered by the
  # upgrade-merge logic (different script_basename → different signature).
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-user-custom"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "quality-reviewer",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/my-custom-hook.sh"
          }
        ]
      }
    ]
  }
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  # Both the user's custom quality-reviewer matcher AND our record-reviewer.sh
  # version should be preserved (different scripts → different signatures).
  assert_json_eq "${impl}: custom — user's custom script preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "quality-reviewer") | .hooks[0].command] | any(tostring | contains("my-custom-hook.sh"))' \
    "true"
  assert_json_eq "${impl}: custom — our record-reviewer.sh also present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "quality-reviewer") | .hooks[0].command] | any(tostring | contains("record-reviewer.sh"))' \
    "true"

  # -----------------------------------------------------------------------
  # Test 9: Multi-hook matcher collision (metis finding #1).
  # Pre-existing bug class: under the old tuple-based signature, a base
  # entry containing multiple hooks and a patch entry containing fewer
  # hooks (but sharing one of the base's script basenames) would
  # signature-differ because the hook-tuple sizes differed. Both entries
  # would survive the merge, causing the shared script to fire twice
  # per SubagentStop event (once via the base entry's copy, once via
  # the patch entry's copy). The fix consolidates them via the phase-2
  # overlap-based hook-level merge: the patch hook replaces the base
  # hook with the matching basename in place, and the base's
  # non-overlapping hooks (e.g., a user's legacy logger) are preserved.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-multi-hook-collision"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/custom-prose-logger.sh"
          },
          {
            "type": "command",
            "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"
          }
        ]
      }
    ]
  }
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  # After merge, SubagentStop should have exactly 11 entries — same as
  # a fresh install. No duplicate editor-critic entry survives.
  assert_json_count "${impl}: multi-hook — SubagentStop count is 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

  # editor-critic appears exactly ONCE in the merged entries.
  assert_json_eq "${impl}: multi-hook — editor-critic count is 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"

  # The consolidated editor-critic entry has exactly 2 hooks: the user's
  # preserved custom-prose-logger.sh and the patch's record-reviewer.sh
  # with the 'prose' arg. The old record-reviewer.sh (no args) must be
  # GONE — it was replaced in place, not appended alongside.
  assert_json_eq "${impl}: multi-hook — editor-critic has 2 hooks" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")][0].hooks | length' \
    "2"

  # The user's custom logger is preserved.
  assert_json_eq "${impl}: multi-hook — custom logger preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("custom-prose-logger.sh"))' \
    "true"

  # The patch version of record-reviewer.sh (with 'prose' arg) is present.
  assert_json_eq "${impl}: multi-hook — record-reviewer.sh prose present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("record-reviewer.sh prose"))' \
    "true"

  # Critically: record-reviewer.sh appears exactly ONCE across all
  # editor-critic hooks. Two matches would indicate the old duplicate-
  # fire bug (base + patch entries both survived).
  assert_json_eq "${impl}: multi-hook — record-reviewer.sh exactly once" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command | select(tostring | contains("record-reviewer.sh"))] | length' \
    "1"

  # Idempotency under the new algorithm: re-merging must not re-duplicate.
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: multi-hook — idempotent SubagentStop still 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"
  assert_json_eq "${impl}: multi-hook — idempotent editor-critic still 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"
  assert_json_eq "${impl}: multi-hook — idempotent editor-critic still 2 hooks" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")][0].hooks | length' \
    "2"

  # -----------------------------------------------------------------------
  # Test 10: Multi-base-entry migration gap (metis finding #1, deeper).
  # The shallow Test 9 case (one base entry, one patch entry) was closed
  # by the three-phase merge. This test exercises the migration path
  # where an older buggy installer left TWO `editor-critic` entries in
  # base settings — the first matching the patch's basename set exactly
  # (so Phase 1 would short-circuit), the second still containing the
  # raw record-reviewer.sh alongside a user-preserved extra hook. Under
  # the bare three-phase loop, Phase 1 would replace the first entry
  # and leave the second with a stale record-reviewer.sh, so the shared
  # script would fire TWICE per SubagentStop event — the exact bug the
  # fix claims to close. Fix: normalize_base_entries pre-pass collapses
  # overlapping same-matcher entries before the three-phase loop runs.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-multi-base-entry"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"
          }
        ]
      },
      {
        "matcher": "editor-critic",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"
          },
          {
            "type": "command",
            "command": "$HOME/.claude/legacy-extra.sh"
          }
        ]
      }
    ]
  }
}
JSON

  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"

  # After merge, editor-critic must appear exactly ONCE — both
  # pre-existing duplicates consolidated into one canonical entry.
  assert_json_eq "${impl}: multi-base — editor-critic count is 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"

  # record-reviewer.sh appears exactly ONCE across all editor-critic
  # hooks (no duplicate fires). If the normalization pass failed, this
  # would be 2 — the stale raw record-reviewer.sh in the second base
  # entry plus the patch version in a replaced first entry.
  assert_json_eq "${impl}: multi-base — record-reviewer.sh exactly once" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command | select(tostring | contains("record-reviewer.sh"))] | length' \
    "1"

  # The patch version (with prose arg) wins.
  assert_json_eq "${impl}: multi-base — record-reviewer.sh prose present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("record-reviewer.sh prose"))' \
    "true"

  # The user's legacy-extra.sh is preserved from the second base entry.
  assert_json_eq "${impl}: multi-base — legacy-extra.sh preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("legacy-extra.sh"))' \
    "true"

  # SubagentStop total is 10 (consolidated to the fresh install count).
  assert_json_count "${impl}: multi-base — SubagentStop count is 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

  # Idempotency: re-merging must preserve the consolidated state and
  # not re-introduce duplicates. The normalize_base_entries pre-pass
  # is the regression target — it must be a no-op on an already-
  # normalized base.
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: multi-base — idempotent SubagentStop still 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"
  assert_json_eq "${impl}: multi-base — idempotent editor-critic still 1" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic")] | length' \
    "1"
  assert_json_eq "${impl}: multi-base — idempotent record-reviewer.sh exactly once" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command | select(tostring | contains("record-reviewer.sh"))] | length' \
    "1"

  # -----------------------------------------------------------------------
  # Test 11: Null-safety and explicit-null parity (metis finding #4).
  # Python previously crashed on `.hooks: null`, `.hooks.SubagentStop: null`,
  # `.matcher: null`, and `.command: null` because `dict.get(key, default)`
  # only substitutes the default for missing keys, not present-but-null.
  # jq's `// default` handles both. The fix switches Python to `.get() or
  # default` patterns for cross-impl parity.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-null-hooks"
  mkdir -p "${work}"
  printf '%s\n' '{"hooks": null}' > "${work}/settings.json"
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: null-hooks — SubagentStop count is 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

  work="${TEST_DIR}/${impl}-null-event"
  mkdir -p "${work}"
  printf '%s\n' '{"hooks": {"SubagentStop": null}}' > "${work}/settings.json"
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: null-event — SubagentStop count is 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

  work="${TEST_DIR}/${impl}-null-matcher"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": null,
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/user-null-matcher.sh"}
        ]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  # null-matcher coalesces to "" which is the same matcher as our
  # record-subagent-summary.sh entry → phase-2 overlap hook-level merge
  # should land the user's hook in the same entry as ours.
  assert_json_eq "${impl}: null-matcher — user hook preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select((.matcher // "") == "") | .hooks[] | .command] | any(tostring | contains("user-null-matcher.sh"))' \
    "true"

  work="${TEST_DIR}/${impl}-null-command"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          {"type": "command", "command": null}
        ]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  # null-command coalesces to basename "" which is disjoint from the
  # patch's "record-reviewer.sh" basename, so Phase 3 appends the patch
  # entry alongside the user's broken one (Test 8 customization-
  # preservation semantics applied to the null-command edge case).
  # What matters is: merger does not crash, the patch lands, and both
  # implementations produce identical output.
  assert_json_eq "${impl}: null-command — record-reviewer.sh prose present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("record-reviewer.sh prose"))' \
    "true"
  assert_json_eq "${impl}: null-command — user null-command hook preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(. == null)' \
    "true"

  # -----------------------------------------------------------------------
  # Test 12: Malformed-hook filtering. An explicit `null` inside a hook
  # entry''s `hooks` array (or a null entry in an event''s hooks array)
  # must not crash either merger. The fix filters non-object hooks at
  # ingress (Python `isinstance(h, dict)`, jq `select(type == "object")`)
  # so malformed settings.json never produces a Python `AttributeError`
  # on `None.get()`. Both impls should produce byte-identical output.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-null-hook-in-entry"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [null]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  # The null hook is filtered out, leaving an empty-hooks entry. The
  # patch''s editor-critic entry is appended alongside.
  assert_json_count "${impl}: null-hook — SubagentStop total" \
    "${work}/settings.json" '.hooks.SubagentStop' "13"
  assert_json_eq "${impl}: null-hook — record-reviewer.sh prose present" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("record-reviewer.sh prose"))' \
    "true"

  work="${TEST_DIR}/${impl}-null-entry-in-event"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [null]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  # A null entry in the event array is preserved as-is (non-dict entries
  # are passed through in normalize_base_entries), but the patch still
  # installs its 12 entries alongside (v1.32.x R2 added release-reviewer).
  assert_json_count "${impl}: null-entry — SubagentStop total" \
    "${work}/settings.json" '.hooks.SubagentStop' "13"

  work="${TEST_DIR}/${impl}-mixed-null-and-valid-hooks"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "editor-critic",
        "hooks": [
          null,
          {"type": "command", "command": "$HOME/.claude/valid-user-hook.sh"}
        ]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  # The valid user hook is preserved; the null hook is dropped.
  assert_json_eq "${impl}: mixed-null — user valid-user-hook.sh preserved" \
    "${work}/settings.json" \
    '[.hooks.SubagentStop[] | select(.matcher == "editor-critic") | .hooks[] | .command] | any(tostring | contains("valid-user-hook.sh"))' \
    "true"

  # -----------------------------------------------------------------------
  # Test 13: Matcher rename. When a previous install wired a hook under one
  # matcher (e.g. "Bash") and a later patch widens that matcher
  # (e.g. "Bash|Edit|Write|MultiEdit") for the same script basename, the
  # merge MUST replace the old entry rather than append a duplicate. Two
  # entries pointing at the same script would fire the hook twice on every
  # tool call covered by both matchers — corrupting block counters and
  # producing duplicate deny responses.
  # -----------------------------------------------------------------------
  work="${TEST_DIR}/${impl}-matcher-rename"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash $HOME/.claude/skills/autowork/scripts/pretool-intent-guard.sh" }
        ]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: matcher-rename — single pretool-intent-guard.sh entry" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.hooks[]?.command | tostring | contains("pretool-intent-guard.sh"))]' \
    "1"
  assert_json_eq "${impl}: matcher-rename — entry uses new widened matcher" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.hooks[]?.command | tostring | contains("pretool-intent-guard.sh")) | .matcher] | .[0]' \
    "Bash|Edit|Write|MultiEdit"
  assert_json_eq "${impl}: matcher-rename — no leftover bare Bash entry for the renamed script" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select((.matcher // "") == "Bash") | select(.hooks[]?.command | tostring | contains("pretool-intent-guard.sh"))] | length' \
    "0"

  # Matcher rename must not clobber an unrelated entry that happens to share
  # the OLD matcher value but a disjoint basename set. User customization at
  # the old matcher value with different scripts stays intact.
  work="${TEST_DIR}/${impl}-matcher-rename-isolation"
  mkdir -p "${work}"
  cat > "${work}/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash $HOME/.claude/skills/autowork/scripts/pretool-intent-guard.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/user-hook.sh" }
        ]
      }
    ]
  }
}
JSON
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_eq "${impl}: matcher-rename isolation — unrelated user-hook.sh preserved on old matcher" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.hooks[]?.command | tostring | contains("user-hook.sh"))] | length' \
    "1"
  assert_json_eq "${impl}: matcher-rename isolation — single pretool-intent-guard.sh entry" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.hooks[]?.command | tostring | contains("pretool-intent-guard.sh"))] | length' \
    "1"

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
  for event in SessionStart UserPromptSubmit PreToolUse PostToolUse PreCompact PostCompact SubagentStop Stop; do
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

  # -----------------------------------------------------------------------
  # Structural cross-implementation parity: run the same non-trivial
  # base fixtures through both implementations and diff their full
  # output with `jq -S` (sort keys) so any structural divergence —
  # e.g. one impl preserving a stale duplicate hook the other dedupes —
  # fails the test. The fresh-install diff above only checks hook
  # counts, which would let a divergence like "py: 1 hook, jq: 2 hooks"
  # slip through if both events still have the same entry count.
  # -----------------------------------------------------------------------
  cross_structural_assert() {
    local label="$1"
    local fixture_json="$2"
    local py_path="${TEST_DIR}/cross-struct-py-${label//[^a-zA-Z0-9]/-}"
    local jq_path="${TEST_DIR}/cross-struct-jq-${label//[^a-zA-Z0-9]/-}"
    printf '%s\n' "${fixture_json}" > "${py_path}"
    printf '%s\n' "${fixture_json}" > "${jq_path}"
    run_merge "python" "${py_path}" "${SETTINGS_PATCH}" "false"
    run_merge "jq" "${jq_path}" "${SETTINGS_PATCH}" "false"
    if diff <(jq -S . "${py_path}") <(jq -S . "${jq_path}") > /dev/null 2>&1; then
      pass=$((pass + 1))
    else
      printf '  FAIL: cross-struct: %s — python and jq diverge\n' "${label}" >&2
      diff <(jq -S . "${py_path}") <(jq -S . "${jq_path}") >&2 || true
      fail=$((fail + 1))
    fi
  }

  # Fresh install: py and jq must produce byte-for-byte identical output.
  cross_structural_assert "fresh-install" '{}'

  # Multi-hook collision (Test 9 scenario).
  cross_structural_assert "multi-hook-collision" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/custom-prose-logger.sh"},
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"}
          ]
        }
      ]
    }
  }'

  # Multi-base-entry migration (Test 10 scenario).
  cross_structural_assert "multi-base-entry" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"}
          ]
        },
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},
            {"type": "command", "command": "$HOME/.claude/legacy-extra.sh"}
          ]
        }
      ]
    }
  }'

  # Duplicate basenames within a single entry (Finding 2 scenario).
  cross_structural_assert "duplicate-basenames" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh old-suffix"}
          ]
        }
      ]
    }
  }'

  # Null-safety scenarios.
  cross_structural_assert "null-hooks" '{"hooks": null}'
  cross_structural_assert "null-event" '{"hooks": {"SubagentStop": null}}'
  cross_structural_assert "null-matcher" '{
    "hooks": {
      "SubagentStop": [
        {"matcher": null, "hooks": [{"type": "command", "command": "$HOME/.claude/u.sh"}]}
      ]
    }
  }'
  cross_structural_assert "null-command" '{
    "hooks": {
      "SubagentStop": [
        {"matcher": "editor-critic", "hooks": [{"type": "command", "command": null}]}
      ]
    }
  }'
  cross_structural_assert "null-hook-in-entry" '{
    "hooks": {
      "SubagentStop": [
        {"matcher": "editor-critic", "hooks": [null]}
      ]
    }
  }'
  cross_structural_assert "null-entry-in-event" '{
    "hooks": {"SubagentStop": [null]}
  }'
  cross_structural_assert "mixed-null-and-valid" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            null,
            {"type": "command", "command": "$HOME/.claude/valid-user-hook.sh"}
          ]
        }
      ]
    }
  }'

  # Three same-matcher base entries, all with overlapping basenames —
  # the deeper migration state where an older buggy installer appended
  # the same matcher multiple times. normalize_base_entries must
  # collapse all three into one canonical entry.
  cross_structural_assert "three-base-entries" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"}
          ]
        },
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},
            {"type": "command", "command": "$HOME/.claude/extra-one.sh"}
          ]
        },
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/skills/autowork/scripts/record-reviewer.sh"},
            {"type": "command", "command": "$HOME/.claude/extra-two.sh"}
          ]
        }
      ]
    }
  }'

  # Embedded-newline command — pathological input that previously
  # diverged between Python (splits on `\n`) and jq (did not). Fixed by
  # aligning jq splits pattern to `[ \\t\\r\\n\\f\\v]+`.
  cross_structural_assert "embedded-newline-command" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "record-reviewer.sh\njunk"}
          ]
        }
      ]
    }
  }'

  # Disjoint same-matcher entries — two editor-critic entries with
  # completely disjoint basename sets must NOT be collapsed by
  # normalize_base_entries. This is the Test 8 customization-
  # preservation invariant as exercised through the new pre-pass.
  # Both impls should preserve both entries as separate.
  cross_structural_assert "disjoint-same-matcher" '{
    "hooks": {
      "SubagentStop": [
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/user-alpha.sh"}
          ]
        },
        {
          "matcher": "editor-critic",
          "hooks": [
            {"type": "command", "command": "$HOME/.claude/user-beta.sh"}
          ]
        }
      ]
    }
  }'

  # Null top-level keys — explicit null on outputStyle/effortLevel must
  # be coalesced to the patch default by both impls. Previously Python
  # used `setdefault` which only guards missing keys, leaving explicit
  # null unchanged while jq coalesced via `//`. Fixed by switching
  # Python to `.get(key) is None` guard.
  cross_structural_assert "null-top-level-keys" '{
    "outputStyle": null,
    "effortLevel": null
  }'

  printf '  Cross-implementation tests done.\n'
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n=== Settings merge tests: %d passed, %d failed ===\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
