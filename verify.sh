#!/usr/bin/env bash
#
# oh-my-claude verifier
#
# Validates that the oh-my-claude harness is correctly installed:
#   - Required files and directories exist
#   - settings.json is valid JSON
#   - All hook scripts pass bash syntax checking
#   - Required hooks are registered in settings.json
#   - Ghostty theme is present (if applicable)
#
# Usage:
#   bash verify.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
CLAUDE_HOME="${TARGET_HOME}/.claude"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

errors=0
warnings=0

pass() {
  printf '  [ok]   %s\n' "$1"
}

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  errors=$(( errors + 1 ))
}

warn() {
  printf '  [warn] %s\n' "$1"
  warnings=$(( warnings + 1 ))
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

omc_version="unknown"

# Try VERSION file first (canonical), then CHANGELOG.md as fallback.
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  omc_version="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
elif [[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]]; then
  ver_line="$(grep -m1 -E '^##\s+\[?v?[0-9]' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  if [[ -n "${ver_line}" ]]; then
    omc_version="$(printf '%s' "${ver_line}" | sed 's/^##[[:space:]]*//' | sed 's/^\[//' | sed 's/].*//' | sed 's/^v//' | sed 's/[[:space:]].*//')"
  fi
fi

# ===========================================================================
# Checks
# ===========================================================================

printf 'oh-my-claude verification (%s)\n' "${omc_version}"
printf 'Checking installation under %s\n\n' "${CLAUDE_HOME}"

# ---------------------------------------------------------------------------
# 1. Required files and directories
# ---------------------------------------------------------------------------

printf '1. Required paths\n'

required_paths=(
  "${CLAUDE_HOME}/settings.json"
  "${CLAUDE_HOME}/CLAUDE.md"
  "${CLAUDE_HOME}/statusline.py"
  "${CLAUDE_HOME}/omc-repro.sh"
  "${CLAUDE_HOME}/output-styles/opencode-compact.md"
  "${CLAUDE_HOME}/quality-pack/scripts/prompt-intent-router.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-compact-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-hint.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/pre-compact-snapshot.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/post-compact-summary.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/stop-failure-handler.sh"
  "${CLAUDE_HOME}/quality-pack/memory/core.md"
  "${CLAUDE_HOME}/quality-pack/memory/skills.md"
  "${CLAUDE_HOME}/quality-pack/memory/compact.md"
  "${CLAUDE_HOME}/quality-pack/memory/auto-memory.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/reflect-after-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-advisory-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-edit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-intent-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/state-io.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/classifier.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-serendipity.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-reviewer.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-subagent-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-pending-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-plan.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-deactivate.sh"
  "${CLAUDE_HOME}/skills/autowork/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-status/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
  "${CLAUDE_HOME}/skills/ulw-report/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-report.sh"
  "${CLAUDE_HOME}/agents/quality-planner.md"
  "${CLAUDE_HOME}/agents/quality-reviewer.md"
  "${CLAUDE_HOME}/agents/writing-architect.md"
  "${CLAUDE_HOME}/agents/prometheus.md"
  "${CLAUDE_HOME}/agents/abstraction-critic.md"
  "${CLAUDE_HOME}/skills/council/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-demo/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-skip/SKILL.md"
  "${CLAUDE_HOME}/skills/mark-deferred/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-pause/SKILL.md"
  "${CLAUDE_HOME}/skills/memory-audit/SKILL.md"
  "${CLAUDE_HOME}/skills/frontend-design/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-skip-register.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-finding-list.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/find-design-contract.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-archetype.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-deferred.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-pause.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/audit-memory.sh"
)

for path in "${required_paths[@]}"; do
  if [[ -e "${path}" ]]; then
    pass "${path}"
  else
    fail "Missing: ${path}"
  fi
done

printf '\n'

# ---------------------------------------------------------------------------
# 2. JSON syntax of settings.json
# ---------------------------------------------------------------------------

printf '2. Settings JSON syntax\n'

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json does not exist; cannot validate"
else
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "${CLAUDE_HOME}/settings.json" >/dev/null 2>&1; then
      pass "settings.json is valid JSON"
    else
      fail "settings.json has invalid JSON syntax"
    fi
  elif command -v jq >/dev/null 2>&1; then
    if jq empty "${CLAUDE_HOME}/settings.json" 2>/dev/null; then
      pass "settings.json is valid JSON"
    else
      fail "settings.json has invalid JSON syntax"
    fi
  else
    warn "Skipping JSON validation (neither python3 nor jq available)"
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 3. Bash syntax check on all hook scripts
# ---------------------------------------------------------------------------

printf '3. Hook script syntax (bash -n)\n'

hook_scripts=(
  "${CLAUDE_HOME}/quality-pack/scripts/post-compact-summary.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/pre-compact-snapshot.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/prompt-intent-router.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-compact-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-hint.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/stop-failure-handler.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-edit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-intent-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-advisory-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-reviewer.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-subagent-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-pending-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/reflect-after-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-plan.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-deactivate.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/find-design-contract.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-archetype.sh"
)

for script in "${hook_scripts[@]}"; do
  if [[ ! -f "${script}" ]]; then
    fail "Cannot check (missing): ${script}"
    continue
  fi
  if bash -n "${script}" 2>/dev/null; then
    pass "${script##*/}"
  else
    fail "Syntax error in: ${script}"
  fi
done

printf '\n'

# ---------------------------------------------------------------------------
# 4. Required hooks present in settings.json
# ---------------------------------------------------------------------------

printf '4. Required hooks in settings.json\n'

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json missing; cannot check hooks"
else
  # Each entry: "event_name:command_fragment"
  required_hooks=(
    "SessionStart:session-start-resume-handoff.sh"
    "SessionStart:session-start-compact-handoff.sh"
    "SessionStart:session-start-resume-hint.sh"
    "UserPromptSubmit:prompt-intent-router.sh"
    "PreToolUse:record-pending-agent.sh"
    "PreToolUse:pretool-intent-guard.sh"
    "PostToolUse:mark-edit.sh"
    "PostToolUse:record-verification.sh"
    "PostToolUse:reflect-after-agent.sh"
    "PostToolUse:record-advisory-verification.sh"
    "PreCompact:pre-compact-snapshot.sh"
    "PostCompact:post-compact-summary.sh"
    "StopFailure:stop-failure-handler.sh"
    "SubagentStop:record-subagent-summary.sh"
    "SubagentStop:record-plan.sh"
    "SubagentStop:record-reviewer.sh"
    "Stop:stop-guard.sh"
  )

  # Scoped check: require the command fragment to appear under the correct
  # event key, not just anywhere in settings.json. The previous substring
  # grep would have passed even if a hook script had been wired under the
  # wrong event (e.g. record-pending-agent.sh moved from PreToolUse to
  # PostToolUse). A jq-scoped query catches that class of regression.
  for entry in "${required_hooks[@]}"; do
    event="${entry%%:*}"
    fragment="${entry##*:}"

    hook_found="false"
    if command -v jq >/dev/null 2>&1; then
      hook_found="$(jq -r --arg ev "${event}" --arg frag "${fragment}" '
        (.hooks[$ev] // [])
        | map(.hooks // [])
        | flatten
        | map(.command // "")
        | any(contains($frag))
      ' "${CLAUDE_HOME}/settings.json" 2>/dev/null || printf 'false')"
    else
      # Fallback: plain substring match when jq is not available.
      if grep -q "${fragment}" "${CLAUDE_HOME}/settings.json" 2>/dev/null; then
        hook_found="true"
      fi
    fi

    if [[ "${hook_found}" == "true" ]]; then
      pass "Hook: ${event} -> ${fragment}"
    else
      fail "Missing hook: ${event} -> ${fragment}"
    fi
  done
fi

printf '\n'

# ---------------------------------------------------------------------------
# 5. Ghostty theme (optional)
# ---------------------------------------------------------------------------

printf '5. Ghostty theme (optional)\n'

ghostty_theme="${TARGET_HOME}/.config/ghostty/themes/Claude OpenCode"
ghostty_config="${TARGET_HOME}/.config/ghostty/config"

if [[ -f "${ghostty_theme}" ]]; then
  pass "Ghostty theme file exists"
  if [[ -f "${ghostty_config}" ]]; then
    if grep -Fqx 'theme = Claude OpenCode' "${ghostty_config}" 2>/dev/null; then
      pass "Ghostty config references theme"
    else
      fail "Ghostty config is missing: theme = Claude OpenCode"
    fi
  else
    warn "Ghostty config file not found at ${ghostty_config}"
  fi
else
  warn "Ghostty theme not installed (this is optional)"
fi

printf '\n'

# ---------------------------------------------------------------------------
# 6. Agent availability (optional, requires claude CLI)
# ---------------------------------------------------------------------------

printf '6. Agent availability\n'

if command -v claude >/dev/null 2>&1; then
  agents_output="$(claude agents 2>/dev/null || true)"
  if [[ -n "${agents_output}" ]]; then
    for agent_name in quality-planner quality-reviewer prometheus writing-architect; do
      if printf '%s' "${agents_output}" | grep -q "${agent_name}"; then
        pass "Agent: ${agent_name}"
      else
        warn "Agent not listed by claude CLI: ${agent_name}"
      fi
    done
  else
    warn "claude agents returned no output"
  fi
else
  warn "claude CLI not found; skipping agent availability check"
fi

printf '\n'

# ---------------------------------------------------------------------------
# 7. Model tier configuration (informational)
# ---------------------------------------------------------------------------

printf '7. Model tier\n'

conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
if [[ -f "${conf_path}" ]]; then
  active_tier="$(grep -E '^model_tier=' "${conf_path}" 2>/dev/null | head -1 | cut -d= -f2)" || true
  if [[ -n "${active_tier:-}" ]]; then
    pass "Active model tier: ${active_tier}"
  else
    pass "No model tier set (using default: balanced)"
  fi
else
  pass "No config file (using default: balanced)"
fi

# Count current agent model assignments.
opus_count=0
sonnet_count=0
for agent_file in "${CLAUDE_HOME}/agents/"*.md; do
  [[ -f "${agent_file}" ]] || continue
  if grep -qE '^model: opus$' "${agent_file}"; then
    opus_count=$((opus_count + 1))
  elif grep -qE '^model: sonnet$' "${agent_file}"; then
    sonnet_count=$((sonnet_count + 1))
  fi
done
printf '  [info] Agent models: %d opus, %d sonnet\n' "${opus_count}" "${sonnet_count}"

printf '\n'

# ===========================================================================
# Result
# ===========================================================================

printf '=== Verification complete ===\n'
printf '  Version:  %s\n' "${omc_version}"
printf '  Errors:   %d\n' "${errors}"
printf '  Warnings: %d\n' "${warnings}"
printf '\n'

if [[ "${errors}" -gt 0 ]]; then
  printf 'Verification FAILED. Re-run the installer and check the errors above.\n' >&2
  exit 1
fi

printf 'oh-my-claude verification passed.\n'
printf '\n'
printf '\033[1mRestart Claude Code (or open a new session)\033[0m before testing — already-running\n'
printf '  sessions keep the previous hook wiring. Verify above only confirms the on-disk\n'
printf '  install, not the live hook activation.\n'
printf '\n'
printf 'What next?\n'
printf '  /ulw-demo                                            -- see quality gates fire (recommended first step)\n'
printf '  /ulw fix the failing test and add regression coverage  -- start real work\n'
printf '\n'
printf 'Tip: specialist agents activate automatically based on your task — just describe\n'
printf "     what you want to accomplish; you don't need to learn agent names.\n"
printf '\n'
printf 'Upgrading from a prior release?\n'
printf '  The live hooks in ~/.claude/ do not auto-upgrade. After git pull, re-run bash install.sh\n'
printf '  to sync agents, skills, and memory files. settings.json merges and omc-user/ are preserved.\n'
