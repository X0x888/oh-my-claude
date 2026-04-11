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
# Requires: rsync, jq. Uses python3 for JSON merging when available, falls back to jq.

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
# Version (read from VERSION file, fallback to CHANGELOG.md)
# ---------------------------------------------------------------------------

OMC_VERSION="unknown"
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  OMC_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
elif [[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]]; then
  ver_line="$(grep -m1 -E '^##\s+\[?v?[0-9]' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  if [[ -n "${ver_line}" ]]; then
    OMC_VERSION="$(printf '%s' "${ver_line}" | sed 's/^##[[:space:]]*//' | sed 's/^\[//' | sed 's/].*//' | sed 's/^v//' | sed 's/[[:space:]].*//')"
  fi
fi

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

# Copy top-level keys from patch. outputStyle and effortLevel are
# preserved if the user has set them, but we explicitly guard against
# present-but-null values here rather than using setdefault, because
# setdefault only fills missing keys — it leaves an explicit `null`
# unchanged, diverging from jq's `// default` semantics. Without this
# guard, a user with `{"outputStyle": null}` in settings.json would
# end up with the null persisting under python but getting coerced
# to the patch value under jq.
settings["statusLine"] = patch["statusLine"]
if settings.get("outputStyle") is None:
    settings["outputStyle"] = patch["outputStyle"]
if settings.get("effortLevel") is None:
    settings["effortLevel"] = patch["effortLevel"]
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

# Merge hooks by signature (idempotent). Uses null-safe accessors so
# an explicit null at `hooks`, `<event>`, `matcher`, `command`, or
# `hooks[].hooks` in base settings never crashes Python — preserving
# parity with jq's `// default` coalesce behavior.
if settings.get("hooks") is None:
    settings["hooks"] = {}
hooks = settings["hooks"]

def script_basename(command):
    """Extract the script basename from a hook command, stripping any
    'bash ' prefix and trailing arguments. Used so that upgrades where
    only a trailing argument changed (e.g. record-reviewer.sh adding a
    ' prose' suffix) are detected as the same entry and the patch
    version replaces the base version instead of being appended."""
    tokens = (command or "").strip().split()
    if not tokens:
        return ""
    first = tokens[0]
    if first == "bash" and len(tokens) > 1:
        first = tokens[1]
    return first.rsplit("/", 1)[-1]

def entry_hooks(entry):
    # Filter out non-dict hook entries (explicit `null`, arrays, scalars)
    # so malformed settings.json input never crashes basename extraction
    # or deduplication. Matches jq's `select(type == "object")` filter.
    return [h for h in (entry.get("hooks") or []) if isinstance(h, dict)]

def entry_basenames(entry):
    return [script_basename(hook.get("command")) for hook in entry_hooks(entry)]

def entry_matcher(entry):
    # Coalesce missing, explicit-None, and any falsy matcher to "". Matches
    # jq's `.matcher // ""` behavior so empty-matcher patch entries (the
    # record-subagent-summary.sh entry) can be identified identically.
    return entry.get("matcher") or ""

def dedupe_entry_hooks(entry):
    """Return a copy of `entry` with hooks collapsed by script basename,
    later occurrence wins. Closes a parity divergence where Python's
    `frozenset` treated duplicate-basename hooks as one signature but
    jq's list-sort compare saw them as distinct, and a dedup hole in
    Phase 2's hook-level merge where stale duplicates survived a patch."""
    seen = {}
    for hook in entry_hooks(entry):
        seen[script_basename(hook.get("command"))] = hook
    new_entry = dict(entry)
    new_entry["hooks"] = list(seen.values())
    return new_entry

def normalize_base_entries(entries):
    """Pre-normalize base entries before the three-phase merge loop:

    1. Within each dict entry, dedupe hooks by script basename
       (later-wins). Preserves the insertion order of each distinct
       basename's first occurrence.
    2. Collapse multiple same-matcher entries whose basename sets
       overlap into a single canonical entry. The first such entry
       becomes the canonical target; subsequent overlapping entries
       have their hooks merged in (replacing matching basenames,
       appending new ones). Entries with disjoint basenames remain
       separate to preserve intentional user customization (Test 8).

    Closes metis finding #1: a migration path where an older buggy
    installer left two `editor-critic` entries in base settings would,
    under the bare three-phase loop, have Phase 1 match only the first
    entry and leave the second with a stale record-reviewer.sh — still
    firing twice per SubagentStop. Normalizing the base first eliminates
    the pre-existing duplication so the three-phase loop always operates
    on a canonical base."""
    result = []
    for raw in entries:
        if not isinstance(raw, dict):
            result.append(raw)
            continue
        entry = dedupe_entry_hooks(raw)
        m = entry_matcher(entry)
        e_basenames = frozenset(entry_basenames(entry))
        merged_into = None
        for i, r in enumerate(result):
            if not isinstance(r, dict):
                continue
            if entry_matcher(r) != m:
                continue
            if frozenset(entry_basenames(r)) & e_basenames:
                merged_into = i
                break
        if merged_into is None:
            result.append(entry)
            continue
        # target is a reference into result; mutating target["hooks"]
        # below updates the result entry in place. Safe because
        # dedupe_entry_hooks returned a shallow copy of each base entry,
        # so the caller's original hooks[event] list is never mutated.
        target = result[merged_into]
        target_hooks = list(entry_hooks(target))
        basename_to_index = {}
        for j, h in enumerate(target_hooks):
            basename_to_index[script_basename(h.get("command"))] = j
        for hook in entry_hooks(entry):
            b = script_basename(hook.get("command"))
            if b in basename_to_index:
                target_hooks[basename_to_index[b]] = hook
            else:
                basename_to_index[b] = len(target_hooks)
                target_hooks.append(hook)
        target["hooks"] = target_hooks
    return result

for event, patch_entries in (patch.get("hooks") or {}).items():
    if hooks.get(event) is None:
        hooks[event] = []
    # Normalize base first so the three-phase loop operates on a
    # canonical, dedup-free base.
    existing_entries = normalize_base_entries(hooks[event])
    hooks[event] = existing_entries

    for patch_entry in patch_entries or []:
        if not isinstance(patch_entry, dict):
            existing_entries.append(patch_entry)
            continue

        p_matcher = entry_matcher(patch_entry)
        p_basenames = entry_basenames(patch_entry)
        p_basename_set = frozenset(p_basenames)

        # Phase 1: exact match on (matcher, basename set) — fast path for
        # fresh installs and idempotent re-merges. Replaces whole entry.
        exact_idx = None
        for i, existing in enumerate(existing_entries):
            if not isinstance(existing, dict):
                continue
            if entry_matcher(existing) != p_matcher:
                continue
            if frozenset(entry_basenames(existing)) == p_basename_set:
                exact_idx = i
                break
        if exact_idx is not None:
            existing_entries[exact_idx] = patch_entry
            continue

        # Phase 2: same matcher + non-empty basename intersection. Merge
        # at the hook level: patch hooks replace base hooks that share a
        # basename; new basenames are appended to the first overlapping
        # base entry. This closes the multi-hook matcher collision where
        # a base entry with two hooks and a patch entry with one hook
        # would otherwise signature-differ and both survive, causing
        # duplicate fires of the shared script.
        overlap_idx = None
        for i, existing in enumerate(existing_entries):
            if not isinstance(existing, dict):
                continue
            if entry_matcher(existing) != p_matcher:
                continue
            if frozenset(entry_basenames(existing)) & p_basename_set:
                overlap_idx = i
                break
        if overlap_idx is not None:
            target = existing_entries[overlap_idx]
            merged_hooks = list(entry_hooks(target))
            basename_to_index = {}
            for i, hook in enumerate(merged_hooks):
                basename_to_index[script_basename(hook.get("command"))] = i
            for patch_hook in entry_hooks(patch_entry):
                b = script_basename(patch_hook.get("command"))
                if b in basename_to_index:
                    merged_hooks[basename_to_index[b]] = patch_hook
                else:
                    basename_to_index[b] = len(merged_hooks)
                    merged_hooks.append(patch_hook)
            target["hooks"] = merged_hooks
            continue

        # Phase 3: disjoint matcher/basenames — append as a new entry.
        existing_entries.append(patch_entry)

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
    # Extract the script basename from a hook command. Strips leading
    # "bash " prefix and trailing arguments so that upgrades where only
    # a trailing argument changed (e.g. record-reviewer.sh → record-reviewer.sh prose)
    # are detected as the same entry and the patch version replaces the
    # base version instead of being appended.
    def script_basename:
      . as $cmd
      # Split on any whitespace run — space, tab, CR, LF, FF, VT — to
      # match Python `.split()` behavior (which splits on any whitespace
      # including newlines). A narrower `[ \\t]+` would diverge from
      # Python for pathological commands containing embedded newlines,
      # because Python would split on `\n` and jq would not, producing
      # different basename grouping keys and different merge outcomes.
      | ($cmd | [splits("[ \\t\\r\\n\\f\\v]+")] | map(select(length > 0))) as $toks
      | (if ($toks | length) == 0 then ""
         elif $toks[0] == "bash" and ($toks | length) > 1 then $toks[1]
         else $toks[0]
         end)
      # Coalesce null to "" so empty-command inputs produce "", matching
      # python `rsplit("/", 1)[-1]` behavior on the empty string.
      | (split("/") | .[-1] // "");
    def entry_basenames:
      [(.hooks // [])[] | select(type == "object") | (.command // "") | script_basename];
    def entry_matcher:
      (.matcher // "");
    # Set equality via unique list compare (order- and dup-independent).
    def sets_equal($a; $b):
      ($a | unique) == ($b | unique);
    # Non-empty set intersection (any element of $a appears in $b).
    def sets_overlap($a; $b):
      any($a[]; . as $x | ($b | index($x)) != null);
    # Dedupe an entry''s hooks by script basename, later occurrence wins.
    # Preserves the position of each basename''s most recent occurrence.
    # Non-object hooks (explicit null, arrays, scalars) are filtered out
    # to match the Python `isinstance(h, dict)` guard.
    def dedupe_entry_hooks:
      .hooks = (
        reduce ((.hooks // [])[] | select(type == "object")) as $h ([];
          ($h.command // "" | script_basename) as $b
          | [range(0; length) as $i
             | select((.[$i].command // "" | script_basename) == $b)
             | $i] as $matches
          | if ($matches | length) > 0 then
              .[$matches[0]] = $h
            else
              . + [$h]
            end
        )
      );
    # Hook-level merge: input is a base entry, $patch_hooks is an array
    # of patch hook objects. Returns the base entry with hooks updated —
    # patch hooks replace base hooks sharing a basename, new basenames
    # are appended. Closes the multi-hook matcher collision bug. Non-
    # object patch hooks are filtered out for parity with Python.
    def merge_hook_level($patch_hooks):
      .hooks = (
        reduce ($patch_hooks[] | select(type == "object")) as $p_hook ((.hooks // []);
          ($p_hook.command // "" | script_basename) as $p_base
          | [range(0; length) as $i
             | select((.[$i].command // "" | script_basename) == $p_base)
             | $i] as $matches
          | if ($matches | length) > 0 then
              .[$matches[0]] = $p_hook
            else
              . + [$p_hook]
            end
        )
      );
    # Normalize base entries before the three-phase merge loop:
    # 1. Dedupe within each entry''s hooks by script basename (later wins).
    # 2. Collapse multiple same-matcher entries whose basename sets
    #    overlap into a single canonical entry. Disjoint same-matcher
    #    entries are left separate (preserves intentional user customization).
    # Closes metis finding #1 (migration path where an older buggy
    # installer left duplicate same-matcher entries in base settings).
    def normalize_base_entries:
      reduce .[] as $raw ([];
        if ($raw | type) != "object" then
          . + [$raw]
        else
          ($raw | dedupe_entry_hooks) as $entry
          | ($entry | entry_matcher) as $m
          | ($entry | entry_basenames) as $e_basenames
          | [range(0; length) as $i
             | select((.[$i] | type) == "object")
             | select((.[$i] | entry_matcher) == $m)
             | select(sets_overlap((.[$i] | entry_basenames); $e_basenames))
             | $i] as $matches
          | if ($matches | length) == 0 then
              . + [$entry]
            else
              .[$matches[0]] |= merge_hook_level($entry.hooks // [])
            end
        end
      );
    # Merge a list of patch entries into a base entries array using the
    # three-phase algorithm: exact match → overlap → append.
    def merge_entries($patch_entries):
      reduce $patch_entries[] as $p_entry (.;
        ($p_entry | entry_matcher) as $p_matcher
        | ($p_entry | entry_basenames) as $p_basenames
        # Phase 1: exact match on (matcher, basename set).
        | [range(0; length) as $i
           | select((.[$i] | type) == "object")
           | select((.[$i] | entry_matcher) == $p_matcher)
           | select(sets_equal((.[$i] | entry_basenames); $p_basenames))
           | $i] as $exact
        | if ($exact | length) > 0 then
            .[$exact[0]] = $p_entry
          else
            # Phase 2: same matcher + non-empty basename intersection →
            # hook-level merge on the first overlapping base entry.
            [range(0; length) as $i
             | select((.[$i] | type) == "object")
             | select((.[$i] | entry_matcher) == $p_matcher)
             | select(sets_overlap((.[$i] | entry_basenames); $p_basenames))
             | $i] as $overlap
            | if ($overlap | length) > 0 then
                .[$overlap[0]] |= merge_hook_level($p_entry.hooks // [])
              else
                # Phase 3: disjoint → append as a new entry.
                . + [$p_entry]
              end
          end
      );
    def merge_hooks($base; $patch):
      reduce ($patch | to_entries[]) as $item ($base;
        .[$item.key] = ((.[$item.key] // []) | normalize_base_entries | merge_entries($item.value // []))
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
  if [[ -f "${CLAUDE_HOME}/switch-tier.sh" ]]; then
    chmod +x "${CLAUDE_HOME}/switch-tier.sh"
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

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for runtime hook scripts but was not found.\n' >&2
  printf 'Install it with your package manager (e.g. brew install jq, apt install jq).\n' >&2
  exit 1
fi

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

# Step 2c — Save repo path and installed version for easy updates.
set_conf "repo_path" "${SCRIPT_DIR}"
set_conf "installed_version" "${OMC_VERSION}"

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
printf '  Version:       %s\n' "${OMC_VERSION}"
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
