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
# Locate repo for balanced tier (needs bundle defaults)
# ---------------------------------------------------------------------------

REPO_PATH="$(get_conf repo_path 2>/dev/null || true)"
AGENTS_DIR="${CLAUDE_HOME}/agents"

if [[ ! -d "${AGENTS_DIR}" ]]; then
  die "No agents directory at ${AGENTS_DIR}. Run the full installer first."
fi

# ---------------------------------------------------------------------------
# Persist tier choice
# ---------------------------------------------------------------------------

set_conf() {
  local key="$1" value="$2"
  if [[ -f "${CONF_PATH}" ]]; then
    local tmp="${CONF_PATH}.tmp"
    grep -v "^${key}=" "${CONF_PATH}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${CONF_PATH}"
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${CONF_PATH}"
}

# ---------------------------------------------------------------------------
# Apply tier
# ---------------------------------------------------------------------------

printf 'Switching to model tier: %s\n' "${TIER}"

changed=0

if [[ "${TIER}" == "balanced" ]]; then
  # Restore bundle defaults by reading model: lines from the repo copy
  if [[ -z "${REPO_PATH}" || ! -d "${REPO_PATH}/bundle/dot-claude/agents" ]]; then
    die "Cannot switch to balanced: repo not found at '${REPO_PATH}'. Re-run the full installer to set balanced defaults."
  fi
  for bundle_file in "${REPO_PATH}/bundle/dot-claude/agents/"*.md; do
    [[ -f "${bundle_file}" ]] || continue
    agent_name="$(basename "${bundle_file}")"
    installed_file="${AGENTS_DIR}/${agent_name}"
    [[ -f "${installed_file}" ]] || continue

    bundle_model="$(grep -E '^model: ' "${bundle_file}" | head -1)" || true
    installed_model="$(grep -E '^model: ' "${installed_file}" | head -1)" || true

    if [[ -n "${bundle_model}" && "${bundle_model}" != "${installed_model}" ]]; then
      tmp="${installed_file}.tmp"
      sed "s/^model: .*$/${bundle_model}/" "${installed_file}" > "${tmp}"
      mv "${tmp}" "${installed_file}"
      changed=$((changed + 1))
    fi
  done
else
  if [[ "${TIER}" == "quality" ]]; then
    from="sonnet"; to="opus"
  else
    from="opus"; to="sonnet"
  fi

  for agent_file in "${AGENTS_DIR}/"*.md; do
    [[ -f "${agent_file}" ]] || continue
    if grep -qE "^model: ${from}$" "${agent_file}"; then
      tmp="${agent_file}.tmp"
      sed "s/^model: ${from}$/model: ${to}/" "${agent_file}" > "${tmp}"
      mv "${tmp}" "${agent_file}"
      changed=$((changed + 1))
    fi
  done
fi

set_conf "model_tier" "${TIER}"
printf 'Done. %d agent(s) updated to %s tier.\n' "${changed}" "${TIER}"
