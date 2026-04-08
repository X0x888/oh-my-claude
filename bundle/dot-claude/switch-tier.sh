#!/usr/bin/env bash
#
# switch-tier.sh — Switch oh-my-claude model tier without a full reinstall.
#
# Usage:
#   bash ~/.claude/switch-tier.sh quality    # all agents use Opus
#   bash ~/.claude/switch-tier.sh balanced   # default split (Opus for planning/review, Sonnet for execution)
#   bash ~/.claude/switch-tier.sh economy    # all agents use Sonnet
#   bash ~/.claude/switch-tier.sh            # show current tier
#
# Reads the repo path from ~/.claude/oh-my-claude.conf and delegates to
# install.sh --model-tier=<tier>. The installer handles backup, agent
# rewrite, and config persistence.

set -euo pipefail

CLAUDE_HOME="${HOME}/.claude"
CONF_PATH="${CLAUDE_HOME}/oh-my-claude.conf"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

get_conf() {
  local key="$1"
  [[ -f "${CONF_PATH}" ]] || return 1
  grep -E "^${key}=" "${CONF_PATH}" 2>/dev/null | head -1 | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Show current tier if no argument
# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  current="$(get_conf model_tier 2>/dev/null || true)"
  if [[ -n "${current}" ]]; then
    printf 'Current model tier: %s\n' "${current}"
  else
    printf 'Current model tier: balanced (default)\n'
  fi
  printf '\nUsage: bash %s <quality|balanced|economy>\n' "$0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate tier argument
# ---------------------------------------------------------------------------

TIER="$1"

case "${TIER}" in
  quality|balanced|economy) ;;
  *) die "Invalid tier '${TIER}'. Must be one of: quality, balanced, economy." ;;
esac

# ---------------------------------------------------------------------------
# Locate repo via saved config
# ---------------------------------------------------------------------------

REPO_PATH="$(get_conf repo_path 2>/dev/null || true)"

if [[ -z "${REPO_PATH}" ]]; then
  die "No repo_path found in ${CONF_PATH}. Re-run the full installer from the oh-my-claude repository."
fi

if [[ ! -f "${REPO_PATH}/install.sh" ]]; then
  die "install.sh not found at ${REPO_PATH}/install.sh. Has the repository moved? Re-run the full installer from the new location."
fi

# ---------------------------------------------------------------------------
# Delegate to installer
# ---------------------------------------------------------------------------

printf 'Switching to model tier: %s\n' "${TIER}"
exec bash "${REPO_PATH}/install.sh" --model-tier="${TIER}"
