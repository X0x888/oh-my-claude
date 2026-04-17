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
  assert_json_count "${impl}: fresh — PreToolUse hooks" \
    "${work}/settings.json" '.hooks.PreToolUse' "2"
  assert_json_count "${impl}: fresh — PostToolUse hooks" \
    "${work}/settings.json" '.hooks.PostToolUse' "5"
  assert_json_count "${impl}: fresh — SubagentStop hooks" \
    "${work}/settings.json" '.hooks.SubagentStop' "11"
  assert_json_count "${impl}: fresh — PreCompact hooks" \
    "${work}/settings.json" '.hooks.PreCompact' "1"
  assert_json_count "${impl}: fresh — PostCompact hooks" \
    "${work}/settings.json" '.hooks.PostCompact' "1"
  assert_json_count "${impl}: fresh — Stop hooks" \
    "${work}/settings.json" '.hooks.Stop' "1"

  # PreToolUse must wire the Agent matcher to record-pending-agent.sh
  assert_json_eq "${impl}: fresh — PreToolUse Agent matcher wired" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[0].command] | .[0] | tostring | contains("record-pending-agent.sh")' \
    "true"

  # PreToolUse must wire the Bash matcher to pretool-intent-guard.sh
  # This is the enforcement backstop for advisory/session-management/checkpoint
  # intent — blocks destructive git ops when the classifier says the user
  # asked for an opinion, not for changes.
  assert_json_eq "${impl}: fresh — PreToolUse Bash matcher wired" \
    "${work}/settings.json" \
    '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command] | .[0] | tostring | contains("pretool-intent-guard.sh")' \
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

  assert_json_count "${impl}: idempotent — SessionStart hooks still 2" \
    "${work}/settings.json" '.hooks.SessionStart' "2"
  assert_json_count "${impl}: idempotent — SubagentStop hooks still 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "11"
  assert_json_count "${impl}: idempotent — PostToolUse hooks still 5" \
    "${work}/settings.json" '.hooks.PostToolUse' "5"
  assert_json_count "${impl}: idempotent — PreToolUse hooks still 2" \
    "${work}/settings.json" '.hooks.PreToolUse' "2"

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

  # After merge, SubagentStop should have exactly 11 entries (no duplicates).
  assert_json_count "${impl}: upgrade — no duplicate editor-critic/excellence-reviewer" \
    "${work}/settings.json" '.hooks.SubagentStop' "11"

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
    "${work}/settings.json" '.hooks.SubagentStop' "11"

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
    "${work}/settings.json" '.hooks.SubagentStop' "11"
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
    "${work}/settings.json" '.hooks.SubagentStop' "11"

  # Idempotency: re-merging must preserve the consolidated state and
  # not re-introduce duplicates. The normalize_base_entries pre-pass
  # is the regression target — it must be a no-op on an already-
  # normalized base.
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: multi-base — idempotent SubagentStop still 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "11"
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
    "${work}/settings.json" '.hooks.SubagentStop' "11"

  work="${TEST_DIR}/${impl}-null-event"
  mkdir -p "${work}"
  printf '%s\n' '{"hooks": {"SubagentStop": null}}' > "${work}/settings.json"
  run_merge "${impl}" "${work}/settings.json" "${SETTINGS_PATCH}" "false"
  assert_json_count "${impl}: null-event — SubagentStop count is 11" \
    "${work}/settings.json" '.hooks.SubagentStop' "11"

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
    "${work}/settings.json" '.hooks.SubagentStop' "12"
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
  # installs its 11 entries alongside.
  assert_json_count "${impl}: null-entry — SubagentStop total" \
    "${work}/settings.json" '.hooks.SubagentStop' "12"

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
