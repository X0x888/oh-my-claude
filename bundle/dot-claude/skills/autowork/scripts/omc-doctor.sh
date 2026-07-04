#!/usr/bin/env bash
#
# omc-doctor.sh — one-shot install health check for oh-my-claude, runnable
# from any directory, days after install, with no source clone around.
#
# v1.48 W2 (harvested from archived fairlead's `doctor`): verify.sh covers
# the fresh-install moment but lives in the source clone; users hitting
# "the harness feels off" mid-life had no self-service diagnostic. This
# script checks the INSTALLED tree at ~/.claude directly.
#
# Standalone by design: no common.sh source, no SESSION_ID requirement —
# a broken install is exactly the situation where sourcing harness code
# would mask the problem. Needs only bash + jq.
#
# Exit: 0 when no FAIL lines were emitted, 1 otherwise (warns don't fail).

set -euo pipefail

CLAUDE_HOME="${OMC_DOCTOR_CLAUDE_HOME:-${HOME}/.claude}"

ok_n=0
warn_n=0
fail_n=0

ok()   { printf 'ok    %s\n' "$*"; ok_n=$((ok_n + 1)); }
warn() { printf 'warn  %s\n' "$*"; warn_n=$((warn_n + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; fail_n=$((fail_n + 1)); }

# --- deps -------------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  ok "jq: $(jq --version 2>/dev/null)"
else
  bad "jq: not found — the harness cannot run without it"
fi
command -v git >/dev/null 2>&1 \
  && ok "git: $(git --version | head -1)" \
  || warn "git: not found — verification and omc goals degrade without it"

# --- install root ------------------------------------------------------

if [[ ! -d "${CLAUDE_HOME}" ]]; then
  bad "install root missing: ${CLAUDE_HOME}"
  printf '\n%d ok, %d warn, %d FAIL\n' "${ok_n}" "${warn_n}" "${fail_n}"
  exit 1
fi

conf="${CLAUDE_HOME}/oh-my-claude.conf"
if [[ -f "${conf}" ]]; then
  iv="$(grep -E '^installed_version=' "${conf}" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  [[ -n "${iv}" ]] && ok "installed version: ${iv}" || warn "oh-my-claude.conf has no installed_version line"
else
  bad "oh-my-claude.conf missing — install has never completed"
fi

# Load-bearing files: one representative per subsystem. A missing one
# means a partial or clobbered install.
core_paths="
skills/autowork/scripts/common.sh
skills/autowork/scripts/stop-guard.sh
skills/autowork/scripts/lib/classifier.sh
quality-pack/scripts/prompt-intent-router.sh
quality-pack/memory/core.md
quality-pack/memory/skills.md
CLAUDE.md
settings.json
"
missing=0
while IFS= read -r p; do
  [[ -n "${p}" ]] || continue
  if [[ ! -f "${CLAUDE_HOME}/${p}" ]]; then
    bad "missing: ~/.claude/${p}"
    missing=$((missing + 1))
  fi
done <<<"${core_paths}"
[[ "${missing}" -eq 0 ]] && ok "core files present (8/8 subsystem representatives)"

# --- CLAUDE.md @-include integrity -------------------------------------
# A broken @-include silently drops doctrine from every session.

if [[ -f "${CLAUDE_HOME}/CLAUDE.md" ]]; then
  broken=0
  while IFS= read -r inc; do
    [[ -n "${inc}" ]] || continue
    local_path="${inc/#~/${HOME}}"
    if [[ ! -f "${local_path}" ]]; then
      bad "broken @-include in CLAUDE.md: ${inc}"
      broken=$((broken + 1))
    fi
  done < <(grep -E '^@' "${CLAUDE_HOME}/CLAUDE.md" | sed 's/^@//')
  [[ "${broken}" -eq 0 ]] \
    && ok "CLAUDE.md @-includes: all $(grep -cE '^@' "${CLAUDE_HOME}/CLAUDE.md" || echo 0) resolve"
fi

# --- hook wiring --------------------------------------------------------
# The silent-no-op failure class: settings.json references a hook script
# that is missing or not executable. Claude Code fails open, so nothing
# visibly breaks — enforcement just quietly stops happening.

settings="${CLAUDE_HOME}/settings.json"
if [[ -f "${settings}" ]]; then
  if jq -e . "${settings}" >/dev/null 2>&1; then
    hook_cmds="$(jq -r '
      (.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command // empty
    ' "${settings}" 2>/dev/null || true)"
    total=0
    broken_hooks=0
    while IFS= read -r cmd; do
      [[ -n "${cmd}" ]] || continue
      total=$((total + 1))
      # Extract the first $HOME/.claude/...-shaped path token.
      script_path="$(printf '%s' "${cmd}" | grep -oE '\$HOME/\.claude/[^" ]+\.(sh|py)' | head -1 || true)"
      [[ -n "${script_path}" ]] || continue
      resolved="${script_path/\$HOME/${HOME}}"
      if [[ ! -f "${resolved}" ]]; then
        bad "hook references missing script: ${script_path}"
        broken_hooks=$((broken_hooks + 1))
      elif [[ ! -x "${resolved}" && "${resolved}" == *.sh ]]; then
        warn "hook script not executable: ${script_path}"
      fi
    done <<<"${hook_cmds}"
    if [[ "${total}" -eq 0 ]]; then
      warn "settings.json defines no hooks — the harness is installed but inert"
    elif [[ "${broken_hooks}" -eq 0 ]]; then
      ok "hook wiring: ${total} hook command(s), all referenced scripts present"
    fi
  else
    bad "settings.json is not valid JSON"
  fi
else
  bad "settings.json missing"
fi

# --- surface counts (informational) -------------------------------------

agents_n="$(find "${CLAUDE_HOME}/agents" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c . || true)"
skills_n="$(find "${CLAUDE_HOME}/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null | grep -c . || true)"
ok "surfaces: ${agents_n} agents, ${skills_n} skills installed"

# --- state root ----------------------------------------------------------

state_root="${CLAUDE_HOME}/quality-pack/state"
if [[ -d "${state_root}" && -w "${state_root}" ]]; then
  sessions_n="$(find "${state_root}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
  ok "state root writable (${sessions_n} session dirs)"
else
  bad "state root missing or not writable: ${state_root}"
fi

# --- summary --------------------------------------------------------------

printf '\n%d ok, %d warn, %d FAIL\n' "${ok_n}" "${warn_n}" "${fail_n}"
if [[ "${fail_n}" -gt 0 ]]; then
  printf 'Recovery: re-run install.sh from the source clone, or reinstall:\n'
  printf '  curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh | bash\n'
  exit 1
fi
