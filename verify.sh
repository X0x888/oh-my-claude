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

# v1.32.16 (4-attacker security review): --strict escalates Step 8
# (foreign hook detection) and Step 9 (SHA-256 drift) from `warn` to
# `fail`. Default `warn` preserves the existing UX for users with
# legitimate custom hook entries (CI integrations, personal automation
# layered on top of the harness). --strict is the security-conscious
# default for users who want their `verify.sh` exit code to fail on
# any foreign content; this is the right setting for incident-response
# audits and for shared/regulated machines.
STRICT_MODE="false"
for arg in "$@"; do
  case "${arg}" in
    --strict)
      STRICT_MODE="true"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

errors=0
warnings=0
# v1.36.0 (item #7): split warning total into informational vs actionable.
# Tool-absence skips (jq missing, sha256sum missing) and optional-config
# misses (Ghostty config not present) are info-only and don't gate ship-
# readiness. Foreign hooks, agent-list mismatches, drift detection
# fires, and statusline hijacks are actionable — saved to
# ~/.claude/last-verify-warnings.txt for follow-up.
info_warnings=0
actionable_warnings=0
ACTIONABLE_LOG="${TARGET_HOME:-$HOME}/.claude/last-verify-warnings.txt"
# Truncate the actionable log up-front so each verify.sh run starts
# fresh. If the directory does not exist (running against a wholly
# empty ~/.claude/ on a tmpdir target), the rm is a no-op.
rm -f "${ACTIONABLE_LOG}" 2>/dev/null || true

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
  actionable_warnings=$(( actionable_warnings + 1 ))
  # Append to the actionable log lazily — the file is created on first
  # actionable warn so a clean install with zero actionable warnings
  # leaves no stale file. Errors here are non-fatal (the warn itself
  # already printed).
  printf '%s\n' "$1" >> "${ACTIONABLE_LOG}" 2>/dev/null || true
}

# v1.36.0 (item #7): info_warn for tool-absence skips and optional
# checks that produce a warning but don't gate ship-readiness. Same
# `[info]` prefix used by the post-install footer in install.sh so
# the visual hierarchy is consistent across surfaces.
info_warn() {
  printf '  [info] %s\n' "$1"
  warnings=$(( warnings + 1 ))
  info_warnings=$(( info_warnings + 1 ))
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
  "${CLAUDE_HOME}/output-styles/oh-my-claude.md"
  "${CLAUDE_HOME}/output-styles/executive-brief.md"
  "${CLAUDE_HOME}/quality-pack/scripts/prompt-intent-router.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-compact-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-hint.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-drift-check.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-welcome.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/pre-compact-snapshot.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/post-compact-summary.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/stop-failure-handler.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  "${CLAUDE_HOME}/install-resume-watchdog.sh"
  "${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  "${CLAUDE_HOME}/quality-pack/memory/core.md"
  "${CLAUDE_HOME}/quality-pack/memory/skills.md"
  "${CLAUDE_HOME}/quality-pack/memory/compact.md"
  "${CLAUDE_HOME}/quality-pack/memory/auto-memory.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/reflect-after-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-advisory-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-delivery-action.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-edit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-intent-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/state-io.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/classifier.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/canary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/posttool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-time-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/canary-claim-audit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-time.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/blindspot-inventory.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/check-latency-budgets.sh"
  "${CLAUDE_HOME}/skills/ulw-time/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-serendipity.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-reviewer.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-subagent-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-pending-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-plan.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-scope-checklist.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-deactivate.sh"
  "${CLAUDE_HOME}/skills/autowork/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-status/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
  "${CLAUDE_HOME}/skills/ulw-report/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-report.sh"
  "${CLAUDE_HOME}/agents/quality-planner.md"
  "${CLAUDE_HOME}/agents/quality-reviewer.md"
  "${CLAUDE_HOME}/agents/release-reviewer.md"
  "${CLAUDE_HOME}/agents/writing-architect.md"
  "${CLAUDE_HOME}/agents/prometheus.md"
  "${CLAUDE_HOME}/agents/abstraction-critic.md"
  "${CLAUDE_HOME}/agents/divergent-framer.md"
  "${CLAUDE_HOME}/skills/council/SKILL.md"
  "${CLAUDE_HOME}/skills/diverge/SKILL.md"
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
  "${CLAUDE_HOME}/skills/autowork/scripts/claim-resume-request.sh"
  "${CLAUDE_HOME}/skills/ulw-resume/SKILL.md"
  "${CLAUDE_HOME}/skills/omc-config/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/omc-config.sh"
  "${CLAUDE_HOME}/skills/whats-new/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-whats-new.sh"
  "${CLAUDE_HOME}/oh-my-claude.conf.example"
)

for path in "${required_paths[@]}"; do
  if [[ -e "${path}" ]]; then
    pass "${path}"
  else
    fail "Missing: ${path}"
  fi
done

# Output-style frontmatter integrity. The paths were already verified
# above; here we additionally confirm the frontmatter `name:` field
# matches the expected literal for each bundled style file. Drift between
# the file and the literal would let a corrupted or renamed file pass
# existence-only verification while silently failing at session start
# when Claude Code tries to resolve outputStyle. The active patch style
# (config/settings.patch.json's outputStyle) is `oh-my-claude` —
# `executive-brief.md` is shipped as an opt-in alternative selected via
# the `output_style=executive` conf flag.
#
# Robust to CRLF line endings, multi-space-after-colon, and embedded
# colons in the name itself. The naive `awk -F': ' '{print $2}'` form
# would carry a trailing \r on Windows-edited files and break the
# equality check below — silently identical to the F-010 leak path
# this verifier is supposed to catch.
for bundled_style in "oh-my-claude:oh-my-claude" "executive-brief:executive-brief"; do
  style_basename="${bundled_style%%:*}"
  expected_name="${bundled_style##*:}"
  style_path="${CLAUDE_HOME}/output-styles/${style_basename}.md"
  if [[ -f "${style_path}" ]]; then
    style_name="$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${style_path}" 2>/dev/null || true)"
    if [[ "${style_name}" == "${expected_name}" ]]; then
      pass "output-style frontmatter name: ${style_name}"
    else
      fail "output-style frontmatter name '${style_name}' in ${style_path} does not match expected '${expected_name}' (file may be corrupted)"
    fi
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
    info_warn "Skipping JSON validation (neither python3 nor jq available)"
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
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-drift-check.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-welcome.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/stop-failure-handler.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-edit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-intent-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-advisory-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-reviewer.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-subagent-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-pending-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-delivery-action.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/reflect-after-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-plan.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-deactivate.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/find-design-contract.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-archetype.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/posttool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-time-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/canary-claim-audit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-time.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/blindspot-inventory.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/check-latency-budgets.sh"
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
    "SessionStart:session-start-drift-check.sh"
    "SessionStart:session-start-welcome.sh"
    "UserPromptSubmit:prompt-intent-router.sh"
    "PreToolUse:record-pending-agent.sh"
    "PreToolUse:pretool-intent-guard.sh"
    "PostToolUse:mark-edit.sh"
    "PostToolUse:record-verification.sh"
    "PostToolUse:record-delivery-action.sh"
    "PostToolUse:reflect-after-agent.sh"
    "PostToolUse:record-advisory-verification.sh"
    "PreToolUse:pretool-timing.sh"
    "PostToolUse:posttool-timing.sh"
    "PreCompact:pre-compact-snapshot.sh"
    "PostCompact:post-compact-summary.sh"
    "StopFailure:stop-failure-handler.sh"
    "SubagentStop:record-subagent-summary.sh"
    "SubagentStop:record-plan.sh"
    "SubagentStop:record-reviewer.sh"
    "Stop:stop-guard.sh"
    "Stop:stop-time-summary.sh"
    "Stop:canary-claim-audit.sh"
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
    info_warn "Ghostty config file not found at ${ghostty_config}"
  fi
else
  info_warn "Ghostty theme not installed (this is optional)"
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
  info_warn "claude CLI not found; skipping agent availability check"
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

# ---------------------------------------------------------------------------
# 8. Foreign hook detection (A2-HIGH-2 from 4-attacker security review)
# ---------------------------------------------------------------------------
#
# Step 4 above checks "are the bundled hooks present?" — but never asks
# the inverse "is anything ELSE wired into settings.json?". An A2
# attacker (write-inside-`~/.claude/`) who appends a non-bundled hook
# entry (e.g. {matcher: "*", command: "bash /tmp/persistence.sh"})
# survives every install.sh run silently because the merge is additive.
# Step 8 enumerates every hook command in settings.json and FAILs on
# any path not under the bundled allowlist. This turns verify.sh into
# the recovery boundary the user expects: "no foreign content has been
# injected since install" rather than just "the install ran".

printf '8. Foreign hook detection\n'

# Default UX: warn on detect (preserves the verify.sh flow for users
# with legitimate custom hooks layered on top of the harness — CI
# integrations, personal automation, dev-loop hooks). --strict
# escalates to fail for security-conscious audits where any foreign
# content should break the verify exit code.
foreign_report() {
  if [[ "${STRICT_MODE}" == "true" ]]; then
    fail "$1"
  else
    warn "$1"
  fi
}

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json missing; cannot check for foreign hooks"
elif ! command -v jq >/dev/null 2>&1; then
  info_warn "jq not available; foreign-hook check skipped"
else
  # Distinguish jq parse failure from "no foreign entries". A
  # malformed settings.json is itself an A2 indicator that warrants a
  # loud signal — not a silent skip.
  jq_err="$(jq -r '
    [
      (.hooks // {}) | to_entries[] |
      .value[]? |
      (.hooks // [])[]? |
      .command // empty
    ] | unique | .[]
  ' "${CLAUDE_HOME}/settings.json" 2>&1)"
  jq_rc=$?

  if [[ ${jq_rc} -ne 0 ]]; then
    fail "settings.json failed jq parse: ${jq_err}"
  else
    # FULL-string match; tight character classes for path/args
    # structurally reject `..` traversal, `;`/`&&`/`|`/newline command
    # chaining, and command substitution. The optional interpreter
    # prefix is restricted to known shells/Python tokens (no absolute
    # interpreter paths — those could be attacker-shimmed without
    # flagging the path-allowlist). Whitespace pre-normalization
    # collapses `bash  $HOME` cosmetic variants to `bash $HOME`.
    bundled_re='^(bash |sh |dash |python3 )?([$]HOME|~)/\.claude/(skills/autowork/scripts/[A-Za-z0-9_-]+\.sh|quality-pack/scripts/[A-Za-z0-9_-]+\.sh|statusline\.py)( [A-Za-z0-9_-]+)*$'
    foreign_count=0
    while IFS= read -r cmd; do
      [[ -z "${cmd}" ]] && continue
      norm="$(printf '%s' "${cmd}" | tr -s '[:space:]' ' ')"
      if [[ ! "${norm}" =~ ${bundled_re} ]]; then
        foreign_report "Foreign hook command: ${cmd}"
        foreign_count=$((foreign_count + 1))
      fi
    done <<< "${jq_err}"

    if [[ "${foreign_count}" -eq 0 ]]; then
      pass "No foreign hook commands"
    elif [[ "${STRICT_MODE}" != "true" ]]; then
      printf '  [info] Re-run with --strict to fail verify on foreign hooks.\n'
    fi
  fi
fi

# v1.32.16 Wave 6 (release-reviewer follow-up): .statusLine.command
# is a code-execution surface Claude Code execs every status-bar
# refresh — between installs the user's settings.json could carry an
# attacker-replaced value. The bundled patch ships a single fixed
# value (`~/.claude/statusline.py`); equality check covers it. Same
# default-warn / --strict-fail pattern as Step 8.
if [[ -f "${CLAUDE_HOME}/settings.json" ]] && command -v jq >/dev/null 2>&1; then
  status_cmd="$(jq -r '.statusLine.command // empty' \
    "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
  # shellcheck disable=SC2088 # comparing unexpanded `~` literal — bundled patch ships the unexpanded form, Claude Code expands at exec time
  if [[ -n "${status_cmd}" && "${status_cmd}" != "~/.claude/statusline.py" ]]; then
    foreign_report ".statusLine.command differs from bundled (got: ${status_cmd}; expected: ~/.claude/statusline.py)"
    if [[ "${STRICT_MODE}" != "true" ]]; then
      printf '  [info] Re-run install.sh to restore the bundled value, or --strict to fail verify on this divergence.\n'
    fi
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 9. Drift detection via SHA-256 manifest (A2-MED-4 from 4-attacker review)
# ---------------------------------------------------------------------------
#
# Step 3 above checks "do hook scripts pass bash -n syntax?" — but
# `bash -n` accepts any syntactically-valid script, including a hostile
# replacement (e.g. stop-guard.sh swapped for an exfiltration shim).
# install.sh writes ${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt
# with one `<sha256>  <relative-path>` line per bundled file. Step 9
# re-hashes each tracked path and FAILs on mismatch. An attacker who
# tampered with installed-hashes.txt itself after editing a script is
# a more sophisticated case; we don't claim full integrity (that needs
# OS-level immutability — `chflags uchg` on macOS, `chattr +i` on Linux
# ext4 — which require root and break legitimate updates). The drift
# check raises the bar from "passes structural validation" to "matches
# the bytes that shipped" for 95% of real-world A2 actors.

printf '9. Drift detection (SHA-256 manifest)\n'

HASHES_PATH="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"

if [[ ! -f "${HASHES_PATH}" ]]; then
  info_warn "installed-hashes.txt missing (drift detection unavailable; reinstall to generate)"
else
  hash_check_tool=""
  if command -v shasum >/dev/null 2>&1; then
    hash_check_tool="shasum -a 256 -c"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash_check_tool="sha256sum -c"
  fi

  if [[ -z "${hash_check_tool}" ]]; then
    info_warn "Neither shasum nor sha256sum available; drift detection skipped"
  else
    # The hashes file's paths are relative to the bundle root. After
    # rsync -a, the same relative paths exist under CLAUDE_HOME. Run the
    # check from CLAUDE_HOME so each path resolves correctly. Force
    # `LC_ALL=C` so the `FAILED` token is not localized — the grep
    # filter relies on the English string emitted by shasum/sha256sum.
    drift_output=""
    drift_output="$(cd "${CLAUDE_HOME}" && LC_ALL=C ${hash_check_tool} "${HASHES_PATH}" 2>&1 \
      | grep -E ': (FAILED|FAILED open or read)$' || true)"

    if [[ -z "${drift_output}" ]]; then
      pass "No drift detected on installed bundle files"
    else
      drift_lines=0
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        foreign_report "Drift: ${line}"
        drift_lines=$((drift_lines + 1))
      done <<< "${drift_output}"
      if [[ "${drift_lines}" -gt 0 && "${STRICT_MODE}" != "true" ]]; then
        printf '  [info] Re-run with --strict to fail verify on drift.\n'
      fi
    fi
  fi
fi

printf '\n'

# ===========================================================================
# Result
# ===========================================================================

printf '=== Verification complete ===\n'
printf '  Version:       %s\n' "${omc_version}"
printf '  Errors:        %d\n' "${errors}"
# v1.36.0 (item #7): split warnings into informational vs actionable so
# the user can tell at a glance whether the warnings need follow-up. The
# legacy "Warnings: N" line is preserved as a sub-line for backwards
# compatibility with any tooling that grepped it.
printf '  Warnings:      %d  (informational: %d, actionable: %d)\n' \
  "${warnings}" "${info_warnings}" "${actionable_warnings}"
if [[ "${actionable_warnings}" -gt 0 ]] && [[ -f "${ACTIONABLE_LOG}" ]]; then
  printf '  Actionable log: %s\n' "${ACTIONABLE_LOG}"
fi
printf '\n'

if [[ "${errors}" -gt 0 ]]; then
  printf 'Verification FAILED. Re-run the installer and check the errors above.\n' >&2
  exit 1
fi

printf 'oh-my-claude verification passed.\n'
printf '\n'
# v1.31.0 Wave 5 (visual-craft F-6 partial): TTY-guard the bold escapes.
# Log redirects (verify.sh > verify.log) and CI dumps now get plain
# text instead of literal `\033[1m...` markers.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  printf '\033[1mRestart Claude Code (or open a new session)\033[0m before testing — already-running\n'
else
  printf 'Restart Claude Code (or open a new session) before testing — already-running\n'
fi
printf '  sessions keep the previous hook wiring. Verify above only confirms the on-disk\n'
printf '  install, not the live hook activation.\n'
printf '\n'
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  printf '\033[1mNext: type /ulw-demo\033[0m (about 90 seconds — fires the gates on a real edit so you see them work).\n'
else
  printf 'Next: type /ulw-demo (about 90 seconds — fires the gates on a real edit so you see them work).\n'
fi
printf '\n'
printf 'Then, when you are ready:\n'
printf '  /ulw <your real task>     -- runs work through the full quality gates\n'
printf '  /omc-config               -- inspect or change settings (optional)\n'
printf '\n'
printf 'Tip: specialist agents activate automatically based on your task — just describe\n'
printf "     what you want to accomplish; you don't need to learn agent names.\n"
printf '\n'
printf 'Upgrading from a prior release?\n'
printf '  The live hooks in ~/.claude/ do not auto-upgrade. After git pull, re-run bash install.sh\n'
printf '  to sync agents, skills, and memory files. settings.json merges and omc-user/ are preserved;\n'
printf '  unedited memory files are refreshed in place. (v1.36.0+) hand-edited memory files trigger a\n'
printf '  pre-rsync warning so you can migrate edits to %s/omc-user/overrides.md.\n' "${CLAUDE_HOME}"
printf '  Run /omc-config afterwards to review your current settings — see CHANGELOG.md for the new-flag list.\n'
