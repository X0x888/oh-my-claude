#!/usr/bin/env bash
#
# oh-my-claude uninstaller
#
# Cleanly removes oh-my-claude files from ~/.claude/ without touching
# user-created content, other hooks, or backup directories.
#
# Usage:
#   bash uninstall.sh           # interactive (asks for confirmation)
#   bash uninstall.sh --yes     # non-interactive (skip confirmation)

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

TARGET_HOME="${TARGET_HOME:-$HOME}"
CLAUDE_HOME="${TARGET_HOME}/.claude"
SETTINGS="${CLAUDE_HOME}/settings.json"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

AUTO_CONFIRM=false

for arg in "$@"; do
  case "${arg}" in
    --yes|-y)
      AUTO_CONFIRM=true
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: bash uninstall.sh [--yes]\n' >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Directories and files installed by oh-my-claude
# ---------------------------------------------------------------------------

# Skill directories (entire trees).
SKILL_DIRS=(
  "${CLAUDE_HOME}/skills/autowork"
  "${CLAUDE_HOME}/skills/ulw"
  "${CLAUDE_HOME}/skills/ultrawork"
  "${CLAUDE_HOME}/skills/sisyphus"
  "${CLAUDE_HOME}/skills/atlas"
  "${CLAUDE_HOME}/skills/council"
  "${CLAUDE_HOME}/skills/librarian"
  "${CLAUDE_HOME}/skills/metis"
  "${CLAUDE_HOME}/skills/oracle"
  "${CLAUDE_HOME}/skills/plan-hard"
  "${CLAUDE_HOME}/skills/prometheus"
  "${CLAUDE_HOME}/skills/research-hard"
  "${CLAUDE_HOME}/skills/review-hard"
  "${CLAUDE_HOME}/skills/skills"
  "${CLAUDE_HOME}/skills/ulw-demo"
  "${CLAUDE_HOME}/skills/ulw-off"
  "${CLAUDE_HOME}/skills/ulw-report"
  "${CLAUDE_HOME}/skills/ulw-skip"
  "${CLAUDE_HOME}/skills/ulw-status"
  "${CLAUDE_HOME}/skills/ulw-time"
  "${CLAUDE_HOME}/skills/mark-deferred"
  "${CLAUDE_HOME}/skills/ulw-pause"
  "${CLAUDE_HOME}/skills/ulw-resume"
  "${CLAUDE_HOME}/skills/memory-audit"
  "${CLAUDE_HOME}/skills/frontend-design"
  "${CLAUDE_HOME}/skills/omc-config"
)

# Quality pack (scripts, memory, state, README).
QP_DIR="${CLAUDE_HOME}/quality-pack"

# Agent files installed by oh-my-claude.
AGENT_FILES=(
  "${CLAUDE_HOME}/agents/abstraction-critic.md"
  "${CLAUDE_HOME}/agents/atlas.md"
  "${CLAUDE_HOME}/agents/backend-api-developer.md"
  "${CLAUDE_HOME}/agents/briefing-analyst.md"
  "${CLAUDE_HOME}/agents/chief-of-staff.md"
  "${CLAUDE_HOME}/agents/data-lens.md"
  "${CLAUDE_HOME}/agents/design-lens.md"
  "${CLAUDE_HOME}/agents/devops-infrastructure-engineer.md"
  "${CLAUDE_HOME}/agents/draft-writer.md"
  "${CLAUDE_HOME}/agents/editor-critic.md"
  "${CLAUDE_HOME}/agents/excellence-reviewer.md"
  "${CLAUDE_HOME}/agents/frontend-developer.md"
  "${CLAUDE_HOME}/agents/fullstack-feature-builder.md"
  "${CLAUDE_HOME}/agents/growth-lens.md"
  "${CLAUDE_HOME}/agents/ios-core-engineer.md"
  "${CLAUDE_HOME}/agents/ios-deployment-specialist.md"
  "${CLAUDE_HOME}/agents/ios-ecosystem-integrator.md"
  "${CLAUDE_HOME}/agents/ios-ui-developer.md"
  "${CLAUDE_HOME}/agents/librarian.md"
  "${CLAUDE_HOME}/agents/metis.md"
  "${CLAUDE_HOME}/agents/oracle.md"
  "${CLAUDE_HOME}/agents/product-lens.md"
  "${CLAUDE_HOME}/agents/prometheus.md"
  "${CLAUDE_HOME}/agents/quality-planner.md"
  "${CLAUDE_HOME}/agents/quality-researcher.md"
  "${CLAUDE_HOME}/agents/quality-reviewer.md"
  "${CLAUDE_HOME}/agents/security-lens.md"
  "${CLAUDE_HOME}/agents/sre-lens.md"
  "${CLAUDE_HOME}/agents/test-automation-engineer.md"
  "${CLAUDE_HOME}/agents/visual-craft-lens.md"
  "${CLAUDE_HOME}/agents/writing-architect.md"
  "${CLAUDE_HOME}/agents/design-reviewer.md"
)

# Standalone files.
STANDALONE_FILES=(
  "${CLAUDE_HOME}/output-styles/oh-my-claude.md"
  "${CLAUDE_HOME}/output-styles/executive-brief.md"
  "${CLAUDE_HOME}/output-styles/opencode-compact.md"
  "${CLAUDE_HOME}/statusline.py"
  "${CLAUDE_HOME}/switch-tier.sh"
  "${CLAUDE_HOME}/omc-repro.sh"
  "${CLAUDE_HOME}/oh-my-claude.conf"
  "${CLAUDE_HOME}/oh-my-claude.conf.example"
  "${CLAUDE_HOME}/.install-stamp"
  "${CLAUDE_HOME}/install-resume-watchdog.sh"
)

# Wave 3 resume-watchdog scheduler templates. Removed wholesale during
# uninstall; the user-installed LaunchAgent / systemd unit / cron entry
# is removed via `install-resume-watchdog.sh --uninstall` separately
# (uninstall.sh prints a reminder before removing the bundle so a user
# with a live watchdog gets a clean shutdown path).
WATCHDOG_DIRS=(
  "${CLAUDE_HOME}/launchd"
  "${CLAUDE_HOME}/systemd"
)

# ---------------------------------------------------------------------------
# Detect whether oh-my-claude is installed
# ---------------------------------------------------------------------------

omc_installed=false

if [[ -d "${QP_DIR}" ]]; then
  omc_installed=true
fi
for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    omc_installed=true
    break
  fi
done
for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    omc_installed=true
    break
  fi
done

if [[ "${omc_installed}" != "true" ]]; then
  printf 'oh-my-claude does not appear to be installed under %s.\n' "${CLAUDE_HOME}"
  printf 'Nothing to do.\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Preview what will be removed
# ---------------------------------------------------------------------------

printf 'oh-my-claude uninstaller\n'
printf '=======================\n\n'
printf 'The following will be removed from %s:\n\n' "${CLAUDE_HOME}"

# Collect items for preview.
items_to_remove=()

for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    items_to_remove+=("  [dir]  ${dir}")
  fi
done

if [[ -d "${QP_DIR}" ]]; then
  items_to_remove+=("  [dir]  ${QP_DIR}")
fi

for wdir in "${WATCHDOG_DIRS[@]}"; do
  if [[ -d "${wdir}" ]]; then
    items_to_remove+=("  [dir]  ${wdir}")
  fi
done

for f in "${AGENT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    items_to_remove+=("  [file] ${f}")
  fi
done

for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    items_to_remove+=("  [file] ${f}")
  fi
done

if [[ -f "${SETTINGS}" ]]; then
  items_to_remove+=("  [edit] ${SETTINGS} (remove oh-my-claude hooks and settings)")
fi

for item in "${items_to_remove[@]}"; do
  printf '%s\n' "${item}"
done

printf '\nThe following will NOT be removed:\n'
printf '  - CLAUDE.md (may contain user content)\n'
printf '  - omc-user/ (user customizations)\n'
printf '  - Backup directories under %s/backups/\n' "${CLAUDE_HOME}"
printf '  - Other hooks or settings not installed by oh-my-claude\n'
printf '\n'

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ "${AUTO_CONFIRM}" != "true" ]]; then
  printf 'Proceed with uninstall? [y/N] '
  read -r confirm
  case "${confirm}" in
    [yY]|[yY][eE][sS])
      ;;
    *)
      printf 'Aborted.\n'
      exit 0
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Remove files and directories
# ---------------------------------------------------------------------------

removed=()

# Capture each bundled output-style file's frontmatter `name:` BEFORE we
# remove the files, so the settings cleanup (below) can value-gate against
# the user's actual current name (which may have been customized in place
# per docs/customization.md guidance) rather than a hardcoded literal.
# Without this, a user who edited a bundled file's frontmatter to
# something like "oh-my-claude v2" and updated their settings to
# match would have the file removed but the orphaned outputStyle entry
# left pointing at a missing style. Falls back to the historical default
# names when a file is absent or the parse returns empty. Both bundled
# names are captured separately so cleanup recognizes either; the legacy
# "OpenCode Compact" name is also accepted for pre-v1.26.0 installs.
OMC_BUNDLED_STYLE_NAME="oh-my-claude"
OMC_BUNDLED_STYLE_NAME_EXECUTIVE="executive-brief"
_parse_style_name() {
  # Robust parser: strips trailing \r (CRLF defense — without it, a
  # Windows-edited customized file would re-introduce the exact orphan
  # leak F-010 was meant to fix), tolerates multi-space-after-colon, and
  # preserves embedded colons in the name itself.
  awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "$1" 2>/dev/null || true
}
_bundled_style_path="${CLAUDE_HOME}/output-styles/oh-my-claude.md"
if [[ -f "${_bundled_style_path}" ]]; then
  _parsed_style_name="$(_parse_style_name "${_bundled_style_path}")"
  if [[ -n "${_parsed_style_name}" ]]; then
    OMC_BUNDLED_STYLE_NAME="${_parsed_style_name}"
  fi
fi
_bundled_style_path_exec="${CLAUDE_HOME}/output-styles/executive-brief.md"
if [[ -f "${_bundled_style_path_exec}" ]]; then
  _parsed_style_name_exec="$(_parse_style_name "${_bundled_style_path_exec}")"
  if [[ -n "${_parsed_style_name_exec}" ]]; then
    OMC_BUNDLED_STYLE_NAME_EXECUTIVE="${_parsed_style_name_exec}"
  fi
fi
export OMC_BUNDLED_STYLE_NAME
export OMC_BUNDLED_STYLE_NAME_EXECUTIVE

# Remove the oh-my-claude-authored post-merge git hook, if the installer
# wrote one. We find the source repo via `repo_path` in oh-my-claude.conf
# (written by install.sh), then remove `<repo>/.git/hooks/post-merge`
# only if it carries the oh-my-claude signature. A foreign hook stays
# untouched. Must happen BEFORE oh-my-claude.conf itself is removed from
# STANDALONE_FILES below, otherwise repo_path is lost.
conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
if [[ -f "${conf_path}" ]]; then
  _repo_path="$(grep -E '^repo_path=' "${conf_path}" 2>/dev/null | head -1 | cut -d= -f2-)" || _repo_path=""
  if [[ -n "${_repo_path}" ]]; then
    _hook_path="${_repo_path}/.git/hooks/post-merge"
    if [[ -f "${_hook_path}" ]] && grep -q '# oh-my-claude post-merge auto-sync' "${_hook_path}" 2>/dev/null; then
      rm -f "${_hook_path}"
      removed+=("Removed git hook: ${_hook_path}")
    fi
  fi
fi

for dir in "${SKILL_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    rm -rf "${dir}"
    removed+=("Removed directory: ${dir}")
  fi
done

for wdir in "${WATCHDOG_DIRS[@]}"; do
  if [[ -d "${wdir}" ]]; then
    rm -rf "${wdir}"
    removed+=("Removed directory: ${wdir}")
  fi
done

if [[ -d "${QP_DIR}" ]]; then
  rm -rf "${QP_DIR}"
  removed+=("Removed directory: ${QP_DIR}")
fi

for f in "${AGENT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    rm -f "${f}"
    removed+=("Removed file: ${f}")
  fi
done

for f in "${STANDALONE_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    rm -f "${f}"
    removed+=("Removed file: ${f}")
  fi
done

# Remove empty parent directories if we emptied them.
for dir in "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/output-styles" "${CLAUDE_HOME}/skills"; do
  if [[ -d "${dir}" ]] && [[ -z "$(ls -A "${dir}" 2>/dev/null)" ]]; then
    rmdir "${dir}" 2>/dev/null || true
    removed+=("Removed empty directory: ${dir}")
  fi
done

# ---------------------------------------------------------------------------
# Clean settings.json — remove oh-my-claude hooks and keys
# ---------------------------------------------------------------------------

clean_settings() {
  if [[ ! -f "${SETTINGS}" ]]; then
    return
  fi

  # Require python3 or jq. If neither is available, skip with a warning.
  if command -v python3 >/dev/null 2>&1; then
    clean_settings_python
  elif command -v jq >/dev/null 2>&1; then
    clean_settings_jq
  else
    printf 'Warning: neither python3 nor jq available; skipping settings.json cleanup.\n' >&2
    printf 'You may want to manually remove oh-my-claude entries from %s.\n' "${SETTINGS}" >&2
    return
  fi

  removed+=("Cleaned settings.json: removed oh-my-claude hooks and keys")
}

clean_settings_python() {
  python3 - "${SETTINGS}" <<'PY'
import json
import os
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])

with settings_path.open() as f:
    settings = json.load(f)

# Bundled style names captured by the parent shell before the .md files
# were removed. Falls back to historical defaults if the parent did not
# export them (e.g. when this function is invoked outside the normal
# uninstall flow). Also accepts the legacy "OpenCode Compact" name.
omc_style_name = os.environ.get("OMC_BUNDLED_STYLE_NAME", "oh-my-claude")
omc_style_name_executive = os.environ.get("OMC_BUNDLED_STYLE_NAME_EXECUTIVE", "executive-brief")

# ---- Remove hooks whose commands reference oh-my-claude paths ----
# Patterns that identify oh-my-claude hooks. Null-safe accessors via
# `.get() or default` match jq's `// default` coalesce so explicit
# `null` at hooks/<event>/entry/hooks[]/command positions doesn't
# crash Python while jq handles them gracefully (parity with the
# install.sh settings merger fixes).
omc_patterns = [
    "quality-pack/scripts",
    "autowork/scripts",
]

def is_omc_hook_entry(entry):
    """Return True if all hooks in this entry reference oh-my-claude.

    Non-dict entries (explicit null, scalars) are treated as non-OMC
    and preserved. Non-dict hooks inside a valid entry are filtered
    out before the all() check; a valid entry consisting entirely of
    filtered-out hooks becomes an empty-hooks case and is preserved."""
    if not isinstance(entry, dict):
        return False
    hooks = [h for h in (entry.get("hooks") or []) if isinstance(h, dict)]
    if not hooks:
        return False
    return all(
        any(pat in (hook.get("command") or "") for pat in omc_patterns)
        for hook in hooks
    )

settings_hooks = settings.get("hooks") or {}
if settings_hooks:
    for event in list(settings_hooks.keys()):
        entries = settings_hooks.get(event) or []
        settings_hooks[event] = [
            e for e in entries if not is_omc_hook_entry(e)
        ]
        # Remove the event key entirely if no entries remain.
        if not settings_hooks[event]:
            del settings_hooks[event]
    # Remove hooks key if empty.
    if not settings_hooks:
        settings.pop("hooks", None)
    else:
        settings["hooks"] = settings_hooks
elif "hooks" in settings:
    # hooks was present but null/empty — drop the key for parity with
    # jq's `if (.hooks | length) == 0 then del(.hooks) else . end`.
    settings.pop("hooks", None)

# ---- Remove oh-my-claude settings keys (only if they match our values) ----

# outputStyle — only remove if set to one of the bundled styles'
# frontmatter names (captured before removal so in-place customizations
# are matched). Both the compact `oh-my-claude` style and the
# `executive-brief` CEO-report style are recognized, plus the legacy
# "OpenCode Compact" name from pre-v1.26.0 installs. A custom user style
# that does NOT match any bundled name is preserved (orphaned but at
# least the user's choice is not silently overwritten).
if settings.get("outputStyle") in (omc_style_name, omc_style_name_executive, "OpenCode Compact"):
    del settings["outputStyle"]

# effortLevel — only remove if set to our value.
if settings.get("effortLevel") == "high":
    del settings["effortLevel"]

# spinnerTipsEnabled — only remove if set to our value.
if settings.get("spinnerTipsEnabled") is False:
    del settings["spinnerTipsEnabled"]

# spinnerVerbs — only remove if it contains our verbs.
sv = settings.get("spinnerVerbs", {})
if isinstance(sv, dict) and sv.get("mode") == "replace":
    omc_verbs = {"Inspecting", "Sketching", "Refining", "Verifying"}
    if set(sv.get("verbs", [])) == omc_verbs:
        del settings["spinnerVerbs"]

# statusLine — only remove if it references our statusline.py.
sl = settings.get("statusLine", {})
if isinstance(sl, dict) and "statusline.py" in sl.get("command", ""):
    del settings["statusLine"]

with settings_path.open("w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
}

clean_settings_jq() {
  local temp_path="${SETTINGS}.tmp"
  local omc_style_name="${OMC_BUNDLED_STYLE_NAME:-oh-my-claude}"
  local omc_style_name_executive="${OMC_BUNDLED_STYLE_NAME_EXECUTIVE:-executive-brief}"

  jq --arg omc_style "${omc_style_name}" \
     --arg omc_style_executive "${omc_style_name_executive}" '
    # Remove hooks whose commands reference oh-my-claude paths.
    # Non-object entries (explicit null, scalars) are passed through
    # unchanged to match the Python path, which treats them as
    # non-OMC and preserves them. Non-object hooks inside a valid
    # entry are filtered from the OMC-detection check so malformed
    # hook arrays never crash the inner contains probe. This matches
    # install.sh parity fixes for null-hook edge cases.
    .hooks = (
      (.hooks // {}) | to_entries | map(
        .value = [
          (.value // [])[] |
          select(
            (type != "object") or (
              [(.hooks // [])[] | select(type == "object") | .command // "" |
                (contains("quality-pack/scripts") or contains("autowork/scripts"))
              ] | length > 0 and all | not
            )
          )
        ]
      ) | map(select(.value | length > 0)) | from_entries
    )
    # Remove hooks key if empty.
    | if (.hooks | length) == 0 then del(.hooks) else . end
    # Remove oh-my-claude settings keys only if they match our values.
    # outputStyle is matched against either bundled style frontmatter name
    # captured before removal (env $omc_style for oh-my-claude.md,
    # $omc_style_executive for executive-brief.md), so in-place
    # customizations are correctly cleaned rather than orphaned. The
    # legacy "OpenCode Compact" name is also recognized for pre-v1.26.0
    # installs. Custom user outputStyle values are preserved (cannot be
    # cleaned without false positives).
    | if (.outputStyle == $omc_style or .outputStyle == $omc_style_executive or .outputStyle == "OpenCode Compact") then del(.outputStyle) else . end
    | if .effortLevel == "high" then del(.effortLevel) else . end
    | if .spinnerTipsEnabled == false then del(.spinnerTipsEnabled) else . end
    | if (.spinnerVerbs.mode == "replace" and (.spinnerVerbs.verbs | sort) == ["Inspecting","Refining","Sketching","Verifying"]) then del(.spinnerVerbs) else . end
    | if (.statusLine.command // "" | contains("statusline.py")) then del(.statusLine) else . end
  ' "${SETTINGS}" > "${temp_path}"

  mv "${temp_path}" "${SETTINGS}"
}

clean_settings

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '=== oh-my-claude uninstall complete ===\n'
printf '\n'
for msg in "${removed[@]}"; do
  printf '  %s\n' "${msg}"
done
printf '\n'
printf 'Your CLAUDE.md and backup directories were preserved.\n'
printf '\n'
printf 'Note: If ~/.claude/CLAUDE.md still contains oh-my-claude references\n'
printf '(lines starting with @~/.claude/quality-pack/), you may want to\n'
printf 'remove those lines or restore your original from the backup directory.\n'
printf '\n'
printf 'Restart Claude Code for changes to take effect.\n'
