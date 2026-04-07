#!/usr/bin/env bash
#
# oh-my-claude installer
#
# Installs the oh-my-claude cognitive quality harness into ~/.claude/.
# Backs up existing files before overwriting, merges settings.json safely,
# and optionally installs Ghostty theme/config.
#
# Usage:
#   bash install.sh                    # standard install
#   bash install.sh --bypass-permissions  # also enable bypass-permissions mode
#   bash install.sh --model-tier=economy  # all agents use Sonnet (cheaper)
#   bash install.sh --uninstall          # remove oh-my-claude (delegates to uninstall.sh)
#
# Requires: rsync, and either python3 or jq for JSON merging.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
CLAUDE_HOME="${TARGET_HOME}/.claude"
BUNDLE_CLAUDE="${SCRIPT_DIR}/bundle/dot-claude"
BUNDLE_GHOSTTY="${SCRIPT_DIR}/config/ghostty"
GHOSTTY_HOME="${TARGET_HOME}/.config/ghostty"
SETTINGS_PATCH="${SCRIPT_DIR}/config/settings.patch.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${CLAUDE_HOME}/backups/oh-my-claude-${STAMP}"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

BYPASS_PERMISSIONS=false
EXCLUDE_IOS=false
MODEL_TIER=""

# Handle --uninstall early (mutually exclusive with install flags).
if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  exec bash "${SCRIPT_DIR}/uninstall.sh" "$@"
fi

for arg in "$@"; do
  case "${arg}" in
    --bypass-permissions)
      BYPASS_PERMISSIONS=true
      ;;
    --no-ios)
      EXCLUDE_IOS=true
      ;;
    --model-tier=*)
      MODEL_TIER="${arg#*=}"
      ;;
    --model-tier)
      printf 'Missing value for --model-tier. Usage: --model-tier=quality|balanced|economy\n' >&2
      exit 1
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: bash install.sh [--bypass-permissions] [--no-ios] [--model-tier=TIER] [--uninstall]\n' >&2
      exit 1
      ;;
  esac
done

# Validate --model-tier value if provided.
if [[ -n "${MODEL_TIER}" ]] && [[ "${MODEL_TIER}" != "quality" && "${MODEL_TIER}" != "balanced" && "${MODEL_TIER}" != "economy" ]]; then
  printf 'Invalid model tier: %s. Must be quality, balanced, or economy.\n' "${MODEL_TIER}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

need_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${cmd}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Settings merge — Python implementation
# ---------------------------------------------------------------------------

merge_settings_python() {
  local settings_path="$1"
  local patch_path="$2"
  local bypass="$3"

  python3 - "${settings_path}" "${patch_path}" "${bypass}" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
patch_path = pathlib.Path(sys.argv[2])
bypass = sys.argv[3] == "true"

if settings_path.exists():
    with settings_path.open() as f:
        settings = json.load(f)
else:
    settings = {}

with patch_path.open() as f:
    patch = json.load(f)

# Copy top-level keys from patch
settings["statusLine"] = patch["statusLine"]
settings.setdefault("outputStyle", patch["outputStyle"])
settings.setdefault("effortLevel", patch["effortLevel"])
settings["spinnerTipsEnabled"] = patch["spinnerTipsEnabled"]
settings["spinnerVerbs"] = patch["spinnerVerbs"]

# Bypass-permissions mode (only when explicitly requested)
if bypass:
    permissions = settings.setdefault("permissions", {})
    permissions["defaultMode"] = "bypassPermissions"
    settings["skipDangerousModePermissionPrompt"] = True
else:
    # Do not set these keys when bypass is not requested.
    # If they already exist from a previous install, leave them alone --
    # the user may have set them independently.
    pass

# Merge hooks by signature (idempotent)
hooks = settings.setdefault("hooks", {})

def signature(entry):
    matcher = entry.get("matcher", "")
    hook_sigs = tuple(
        (hook.get("type", ""), hook.get("command", ""))
        for hook in entry.get("hooks", [])
    )
    return (matcher, hook_sigs)

for event, patch_entries in patch.get("hooks", {}).items():
    existing_entries = hooks.setdefault(event, [])
    index = {}
    for i, existing in enumerate(existing_entries):
        if isinstance(existing, dict):
            index[signature(existing)] = i
    for entry in patch_entries:
        sig = signature(entry)
        if sig in index:
            existing_entries[index[sig]] = entry
        else:
            existing_entries.append(entry)

settings_path.parent.mkdir(parents=True, exist_ok=True)
with settings_path.open("w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
}

# ---------------------------------------------------------------------------
# Settings merge — jq implementation (fallback)
# ---------------------------------------------------------------------------

merge_settings_jq() {
  local settings_path="$1"
  local patch_path="$2"
  local bypass="$3"
  local temp_path="${settings_path}.tmp"
  local base_path="${settings_path}"

  if [[ ! -f "${base_path}" ]]; then
    printf '{}\n' > "${base_path}"
  fi

  local bypass_filter=""
  if [[ "${bypass}" == "true" ]]; then
    bypass_filter='
    | .permissions = ((.permissions // {}) + {"defaultMode": "bypassPermissions"})
    | .skipDangerousModePermissionPrompt = true'
  fi

  jq -s '
    def entry_sig:
      {
        matcher: (.matcher // ""),
        hooks: [(.hooks // [])[] | {type: (.type // ""), command: (.command // "")}]
      };
    def merge_hooks($base; $patch):
      reduce ($patch | to_entries[]) as $item ($base;
        .[$item.key] = (
          ((.[ $item.key ] // []) + $item.value)
          | unique_by(entry_sig)
        )
      );
    .[0] as $base
    | .[1] as $patch
    | $base
    | .statusLine = $patch.statusLine
    | .outputStyle = (.outputStyle // $patch.outputStyle)
    | .effortLevel = (.effortLevel // $patch.effortLevel)
    | .spinnerTipsEnabled = $patch.spinnerTipsEnabled
    | .spinnerVerbs = $patch.spinnerVerbs
    | .hooks = merge_hooks((.hooks // {}); ($patch.hooks // {}))
    '"${bypass_filter}"'
  ' "${base_path}" "${patch_path}" > "${temp_path}"

  mv "${temp_path}" "${settings_path}"
}

# ---------------------------------------------------------------------------
# Backup existing targets before overwriting
# ---------------------------------------------------------------------------

backup_existing_targets() {
  # Back up bundle files that already exist at the destination.
  while IFS= read -r source_path; do
    local rel_path
    local target_path
    local backup_path

    rel_path="${source_path#"${BUNDLE_CLAUDE}"/}"
    target_path="${CLAUDE_HOME}/${rel_path}"
    backup_path="${BACKUP_DIR}/${rel_path}"

    if [[ -f "${target_path}" ]]; then
      mkdir -p "$(dirname "${backup_path}")"
      rsync -a "${target_path}" "${backup_path}"
    fi
  done < <(find "${BUNDLE_CLAUDE}" -type f ! -name '.DS_Store' | sort)

  # Back up settings.json separately (it is merged, not overwritten).
  if [[ -f "${CLAUDE_HOME}/settings.json" ]]; then
    mkdir -p "${BACKUP_DIR}"
    rsync -a "${CLAUDE_HOME}/settings.json" "${BACKUP_DIR}/settings.json"
  fi

  # Back up any Ghostty files that will be touched.
  if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
    while IFS= read -r source_path; do
      local rel_path
      local target_path
      local backup_path

      rel_path="${source_path#"${BUNDLE_GHOSTTY}"/}"
      target_path="${GHOSTTY_HOME}/${rel_path}"
      backup_path="${BACKUP_DIR}/ghostty/${rel_path}"

      if [[ -f "${target_path}" ]]; then
        mkdir -p "$(dirname "${backup_path}")"
        rsync -a "${target_path}" "${backup_path}"
      fi
    done < <(find "${BUNDLE_GHOSTTY}" -type f ! -name '.DS_Store' | sort)
  fi
}

# ---------------------------------------------------------------------------
# Ensure scripts are executable
# ---------------------------------------------------------------------------

ensure_executable_bits() {
  if [[ -f "${CLAUDE_HOME}/statusline.py" ]]; then
    chmod +x "${CLAUDE_HOME}/statusline.py"
  fi
  if [[ -d "${CLAUDE_HOME}/quality-pack/scripts" ]]; then
    find "${CLAUDE_HOME}/quality-pack/scripts" -type f -name '*.sh' -exec chmod +x {} +
  fi
  if [[ -d "${CLAUDE_HOME}/skills/autowork/scripts" ]]; then
    find "${CLAUDE_HOME}/skills/autowork/scripts" -type f -name '*.sh' -exec chmod +x {} +
  fi
}

# ---------------------------------------------------------------------------
# Append a line to a file if not already present
# ---------------------------------------------------------------------------

append_if_missing() {
  local file_path="$1"
  local line="$2"

  mkdir -p "$(dirname "${file_path}")"
  touch "${file_path}"
  if ! grep -Fqx "${line}" "${file_path}" 2>/dev/null; then
    printf '%s\n' "${line}" >> "${file_path}"
  fi
}

# ---------------------------------------------------------------------------
# Configuration file helpers
# ---------------------------------------------------------------------------

# Set a key=value pair in oh-my-claude.conf (creates or updates).
set_conf() {
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local key="$1"
  local value="$2"

  if [[ -f "${conf_path}" ]]; then
    local tmp="${conf_path}.tmp"
    grep -v "^${key}=" "${conf_path}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${conf_path}"
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${conf_path}"
}

# ---------------------------------------------------------------------------
# Apply model tier to installed agent definitions
# ---------------------------------------------------------------------------

apply_model_tier() {
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local tier="${MODEL_TIER}"

  # If no flag was passed, read from config file.
  if [[ -z "${tier}" && -f "${conf_path}" ]]; then
    tier="$(grep -E '^model_tier=' "${conf_path}" 2>/dev/null | head -1 | cut -d= -f2)" || true
  fi

  # If still empty, the user never opted in — use bundle defaults silently.
  if [[ -z "${tier}" ]]; then
    return
  fi

  # Persist the tier for future installs.
  set_conf "model_tier" "${tier}"

  # balanced = bundle defaults, nothing to rewrite.
  if [[ "${tier}" == "balanced" ]]; then
    printf '  Model tier:    balanced (default — opus for planning/review, sonnet for execution)\n'
    return
  fi

  local from to
  if [[ "${tier}" == "quality" ]]; then
    from="sonnet"
    to="opus"
  else
    from="opus"
    to="sonnet"
  fi

  local changed=0
  for agent_file in "${CLAUDE_HOME}/agents/"*.md; do
    [[ -f "${agent_file}" ]] || continue
    if grep -qE "^model: ${from}$" "${agent_file}"; then
      local tmp="${agent_file}.tmp"
      sed "s/^model: ${from}$/model: ${to}/" "${agent_file}" > "${tmp}"
      mv "${tmp}" "${agent_file}"
      changed=$((changed + 1))
    fi
  done

  printf '  Model tier:    %s (all agents → %s, %d changed)\n' "${tier}" "${to}" "${changed}"
}

# ---------------------------------------------------------------------------
# Install Ghostty theme and config snippet
# ---------------------------------------------------------------------------

install_ghostty() {
  local snippet_path="${BUNDLE_GHOSTTY}/config.snippet.ini"
  local theme_source="${BUNDLE_GHOSTTY}/themes/Claude OpenCode"
  local theme_target_dir="${GHOSTTY_HOME}/themes"
  local config_target="${GHOSTTY_HOME}/config"

  if [[ ! -d "${BUNDLE_GHOSTTY}" ]]; then
    return
  fi

  mkdir -p "${theme_target_dir}"

  if [[ -f "${theme_source}" ]]; then
    rsync -a "${theme_source}" "${theme_target_dir}/Claude OpenCode"
  fi

  if [[ -f "${snippet_path}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      append_if_missing "${config_target}" "${line}"
    done < "${snippet_path}"
  fi
}

# ===========================================================================
# Main
# ===========================================================================

need_cmd rsync

if [[ ! -d "${BUNDLE_CLAUDE}" ]]; then
  printf 'Missing bundle directory: %s\n' "${BUNDLE_CLAUDE}" >&2
  exit 1
fi

if [[ ! -f "${SETTINGS_PATCH}" ]]; then
  printf 'Missing settings patch: %s\n' "${SETTINGS_PATCH}" >&2
  exit 1
fi

printf 'Installing oh-my-claude into %s ...\n' "${CLAUDE_HOME}"

# Step 1 — Create directories and back up existing files.
mkdir -p "${CLAUDE_HOME}" "${BACKUP_DIR}"
backup_existing_targets

# Step 2 — Copy bundle into ~/.claude/.
rsync -a --exclude='.DS_Store' "${BUNDLE_CLAUDE}/" "${CLAUDE_HOME}/"

# Remove iOS agents if --no-ios was specified.
if [[ "${EXCLUDE_IOS}" == "true" ]]; then
  for ios_agent in "${CLAUDE_HOME}/agents/ios-"*.md; do
    if [[ -f "${ios_agent}" ]]; then
      rm "${ios_agent}"
      printf '  Excluded: %s\n' "$(basename "${ios_agent}")"
    fi
  done
fi

# Step 2b — Apply model tier (rewrite agent model assignments if needed).
apply_model_tier

# Step 2c — Save repo path for easy updates.
set_conf "repo_path" "${SCRIPT_DIR}"

# Ensure quality-pack state directory exists (not in the bundle).
mkdir -p "${CLAUDE_HOME}/quality-pack/state"

# Step 3 — Install Ghostty theme/config (no-op if bundle has none).
install_ghostty

# Step 4 — Merge settings.json (idempotent).
if command -v python3 >/dev/null 2>&1; then
  merge_settings_python "${CLAUDE_HOME}/settings.json" "${SETTINGS_PATCH}" "${BYPASS_PERMISSIONS}"
elif command -v jq >/dev/null 2>&1; then
  merge_settings_jq "${CLAUDE_HOME}/settings.json" "${SETTINGS_PATCH}" "${BYPASS_PERMISSIONS}"
else
  printf 'Need either python3 or jq to merge settings.\n' >&2
  exit 1
fi

# Step 5 — Set executable bits on scripts.
ensure_executable_bits

# ===========================================================================
# Summary
# ===========================================================================

printf '\n'
printf '=== oh-my-claude install complete ===\n'
printf '\n'
printf '  Destination:   %s\n' "${CLAUDE_HOME}"
printf '  Backup:        %s\n' "${BACKUP_DIR}"
if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
  printf '  Ghostty:       %s\n' "${GHOSTTY_HOME}"
fi
if [[ "${BYPASS_PERMISSIONS}" == "true" ]]; then
  printf '  Permissions:   bypass-permissions mode enabled\n'
fi
if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
  _tier="$(grep -E '^model_tier=' "${CLAUDE_HOME}/oh-my-claude.conf" | cut -d= -f2)" || true
  if [[ -n "${_tier}" ]]; then
    printf '  Model tier:    %s\n' "${_tier}"
  fi
fi
printf '\n'
printf 'Next steps:\n'
printf '  1. Restart Claude Code (or open a new session).\n'
printf '  2. Run: bash %s/verify.sh\n' "${SCRIPT_DIR}"
printf '\n'

if [[ "${BYPASS_PERMISSIONS}" != "true" ]]; then
  printf 'Tip: For maximum autonomy, re-run with: bash install.sh --bypass-permissions\n'
fi
