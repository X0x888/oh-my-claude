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
#   bash install.sh --no-ghostty         # skip Ghostty theme/config (v1.36.0)
#   bash install.sh --with-ghostty       # force-install Ghostty even if not detected (v1.36.0)
#   bash install.sh --keep-backups=N     # prune oh-my-claude-* backups, keep N newest (default 10; v1.36.0)
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
INSTALL_GIT_HOOKS=false
# v1.36.0: ghostty install is now auto-detect by default. "" = auto
# (install only when ${GHOSTTY_HOME} already exists), "yes" = force
# install, "no" = skip. Closes the silent ~/.config/ghostty/ side
# effect on hosts that don't run Ghostty terminal.
INSTALL_GHOSTTY_FLAG=""
# Track which ghostty flags appeared so we can detect the mutually-
# exclusive case. Pre-fix the arg loop accepted both flags and silently
# last-wins; the explicit pair-tracking lets us refuse the combination
# instead of guessing user intent.
_OMC_GHOSTTY_NO_SEEN=0
_OMC_GHOSTTY_YES_SEEN=0
# v1.36.0: backup retention. 10 newest oh-my-claude-* dirs in
# ${CLAUDE_HOME}/backups/ are kept; older ones pruned after install
# completes. Set to 0 to disable retention; set --keep-backups=all
# to skip pruning entirely.
KEEP_BACKUPS="10"

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
    --git-hooks)
      INSTALL_GIT_HOOKS=true
      ;;
    --no-ghostty)
      INSTALL_GHOSTTY_FLAG="no"
      _OMC_GHOSTTY_NO_SEEN=1
      ;;
    --with-ghostty)
      INSTALL_GHOSTTY_FLAG="yes"
      _OMC_GHOSTTY_YES_SEEN=1
      ;;
    --keep-backups=*)
      KEEP_BACKUPS="${arg#*=}"
      ;;
    --keep-backups)
      printf 'Missing value for --keep-backups. Usage: --keep-backups=N (or --keep-backups=all to disable pruning)\n' >&2
      exit 1
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: bash install.sh [--bypass-permissions] [--no-ios] [--model-tier=TIER] [--git-hooks] [--no-ghostty] [--with-ghostty] [--keep-backups=N] [--uninstall]\n' >&2
      exit 1
      ;;
  esac
done

# Validate --keep-backups value (must be "all" or a non-negative integer).
if [[ -n "${KEEP_BACKUPS}" ]] && [[ "${KEEP_BACKUPS}" != "all" ]] && ! [[ "${KEEP_BACKUPS}" =~ ^[0-9]+$ ]]; then
  printf 'Invalid --keep-backups value: %s. Must be "all" or a non-negative integer.\n' "${KEEP_BACKUPS}" >&2
  exit 1
fi

# Refuse --no-ghostty + --with-ghostty in the same invocation. The two
# flags express opposite intents and last-wins would silently ignore one;
# better to surface the conflict so the user picks deliberately. Use
# `%s\n` because the bash builtin printf treats a leading `--` in the
# format string as end-of-options and rejects it as an invalid flag.
if [[ "${_OMC_GHOSTTY_NO_SEEN}" -eq 1 ]] && [[ "${_OMC_GHOSTTY_YES_SEEN}" -eq 1 ]]; then
  printf '%s\n' '--no-ghostty and --with-ghostty are mutually exclusive — pick one.' >&2
  exit 1
fi

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

# Two-hop stat helper (BSD then GNU) — same portability shape as
# session-start-welcome.sh:_lock_mtime / common.sh state-io. Returns
# the file's mtime epoch on stdout, empty string when unsupported.
# Note on busybox/Alpine consumers below: `date -r` interprets its
# argument as a FILENAME on busybox, not an epoch, so the formatted-
# date branch in warn_modified_memory_files falls back to `epoch=N`
# via the `||` operator there. This is a documented degradation,
# not a bug.
_install_file_mtime() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  if stat -f '%m' "${path}" >/dev/null 2>&1; then
    stat -f '%m' "${path}" 2>/dev/null
  elif stat -c '%Y' "${path}" >/dev/null 2>&1; then
    stat -c '%Y' "${path}" 2>/dev/null
  fi
}

# v1.36.0: warn before overwriting memory files the user has hand-edited.
# The end-of-install message used to advertise "settings.json merges and
# omc-user/ are preserved" without mentioning that quality-pack/memory/*.md
# is overwritten on every install. Users who hand-edited core.md or
# skills.md to adjust their workflow lost those edits silently. This
# helper compares each memory file's mtime against the previous
# install-stamp; files modified post-install are listed BEFORE rsync
# runs so the user can Ctrl-C and migrate edits to omc-user/overrides.md.
warn_modified_memory_files() {
  local install_stamp="${CLAUDE_HOME}/.install-stamp"
  local memory_dir="${CLAUDE_HOME}/quality-pack/memory"
  local stamp_ts=""

  [[ -d "${memory_dir}" ]] || return 0
  stamp_ts="$(_install_file_mtime "${install_stamp}" || true)"
  # First install (no stamp) or unsupported stat — silent skip.
  [[ -z "${stamp_ts}" ]] && return 0
  [[ "${stamp_ts}" =~ ^[0-9]+$ ]] || return 0
  [[ "${stamp_ts}" -le 0 ]] && return 0

  local warned=0
  local mem_file file_ts
  while IFS= read -r mem_file; do
    [[ -z "${mem_file}" ]] && continue
    [[ -f "${mem_file}" ]] || continue
    file_ts="$(_install_file_mtime "${mem_file}" || true)"
    [[ "${file_ts}" =~ ^[0-9]+$ ]] || continue
    if [[ "${file_ts}" -gt "${stamp_ts}" ]]; then
      if [[ "${warned}" -eq 0 ]]; then
        printf '\n  [warn] User edits detected in %s — these files will be overwritten.\n' "${memory_dir}"
        printf '         To preserve your customizations across installs, move them to:\n'
        printf '           %s/omc-user/overrides.md  (loaded after defaults; never overwritten)\n' "${CLAUDE_HOME}"
        printf '         A copy of each modified file IS saved in %s before rsync, so\n' "${BACKUP_DIR}"
        printf '         recovery is possible after-the-fact via:\n'
        printf '           cp %s/quality-pack/memory/<file>.md \\\n' "${BACKUP_DIR}"
        printf '              %s/omc-user/overrides.md   # then re-edit as additive overrides\n' "${CLAUDE_HOME}"
        printf '         Modified files:\n'
        warned=1
      fi
      printf '           - %s (modified %s)\n' \
        "$(basename "${mem_file}")" \
        "$(date -r "${file_ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'epoch=%s' "${file_ts}")"
    fi
  done < <(find "${memory_dir}" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

  if [[ "${warned}" -eq 1 ]]; then
    # F-2 fix (Wave 1 review): only sleep when interactive AND not in CI.
    # `bash install.sh < /dev/null` (curl-pipe-bash) and CI runs cannot
    # Ctrl-C, so a 5s wait there is pure dead time; same surface where
    # the bypass-permissions banner skips its prompt. Test runs (CI=1
    # in GitHub Actions) and stdin-redirected installs print the warning
    # and proceed immediately.
    if [[ -t 0 ]] && [[ -z "${CI:-}" ]]; then
      printf '         Continuing with install in 5 seconds — Ctrl-C to abort and migrate first.\n'
      sleep 5 2>/dev/null || true
    else
      printf '         Non-interactive install — proceeding immediately. Migrate edits before the next install run.\n'
    fi
  fi
}

# v1.36.0: prune oh-my-claude-${STAMP} backup directories after install.
# Keeps the most recent ${KEEP_BACKUPS} dirs (default 10); set
# --keep-backups=all to disable. At the project's release cadence
# (multiple installs per day during cascades) backups otherwise
# accumulate ~30/month with no surface to surface or rotate them.
#
# Conservative pruning (newest-first by name; the timestamp is
# embedded in the directory name so lexical sort == newest-first
# under normal clock conditions). F-1 (Wave 1 review) defense:
# even when prior dirs sort lexically AHEAD of ${BACKUP_DIR} (clock
# skew, hand-renamed dirs, future-dated stamps from rolled-back hosts),
# the just-created backup is ALWAYS preserved by an explicit
# `[[ "${dir}" == "${BACKUP_DIR}" ]] && continue` guard inside the
# prune loop. The guard is cheap and forecloses any ordering pathology.
prune_old_backups() {
  local keep="${KEEP_BACKUPS:-10}"
  [[ "${keep}" == "all" ]] && return 0
  [[ "${keep}" =~ ^[0-9]+$ ]] || return 0

  local backups_root="${CLAUDE_HOME}/backups"
  [[ -d "${backups_root}" ]] || return 0

  local -a backups=()
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] && backups+=("${dir}")
  done < <(find "${backups_root}" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null \
              | LC_ALL=C sort -r)

  if [[ "${#backups[@]}" -le "${keep}" ]]; then
    return 0
  fi

  local pruned=0 i
  for ((i=keep; i<${#backups[@]}; i++)); do
    # Hard guard: never prune the just-created backup, regardless of
    # where it landed in the lexical-sort window. If clock-skew /
    # future-dated prior dirs pushed ${BACKUP_DIR} past the keep
    # threshold, this `continue` keeps the recovery surface intact.
    if [[ "${backups[i]}" == "${BACKUP_DIR}" ]]; then
      continue
    fi
    if rm -rf "${backups[i]}" 2>/dev/null; then
      pruned=$((pruned + 1))
    fi
  done

  if [[ "${pruned}" -gt 0 ]]; then
    printf '  Backup retention: kept %d most recent oh-my-claude-* dir(s), pruned %d older.\n' \
      "${keep}" "${pruned}"
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
import os
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
#
# OMC_OUTPUT_STYLE_PREF (set by the parent shell from oh-my-claude.conf)
# selects which bundled style settings.outputStyle points at:
#   opencode   → "oh-my-claude"   (default, compact CLI presentation)
#   executive  → "executive-brief" (CEO-style status report)
#   preserve   → never touch settings.outputStyle (user has a custom style)
# A user-set outputStyle that does NOT match one of the bundled style
# names is always preserved — only bundled-name values are auto-synced
# when the conf flag changes (so /omc-config can switch between bundled
# styles), and the legacy "OpenCode Compact" name is migrated.
settings["statusLine"] = patch["statusLine"]
output_style_pref = os.environ.get("OMC_OUTPUT_STYLE_PREF", "opencode")
_BUNDLED_STYLES_CURRENT = {"oh-my-claude", "executive-brief"}
_STYLE_FOR_PREF = {"opencode": "oh-my-claude", "executive": "executive-brief"}
if settings.get("outputStyle") == "OpenCode Compact":
    # Legacy migration: pre-v1.26.0 installs left "OpenCode Compact" in
    # settings, but the underlying style file was renamed to oh-my-claude
    # and the legacy file removed. Leaving the legacy name would orphan
    # the user (Claude Code cannot resolve it). Always migrate, even
    # under preserve — preserve protects user choices, not installer
    # artifacts pointing at a deleted style file. Honor the conf-resolved
    # target when one is available; fall back to oh-my-claude otherwise.
    settings["outputStyle"] = _STYLE_FOR_PREF.get(output_style_pref, patch["outputStyle"])
elif output_style_pref != "preserve":
    _target_style = _STYLE_FOR_PREF.get(output_style_pref, patch["outputStyle"])
    _current_style = settings.get("outputStyle")
    if _current_style is None or _current_style in _BUNDLED_STYLES_CURRENT:
        settings["outputStyle"] = _target_style
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

  # OMC_OUTPUT_STYLE_PREF=preserve skips the outputStyle merge so a user
  # with their own style is never overwritten. Default "opencode" keeps
  # the historical "// default" behavior.
  local output_style_pref="${OMC_OUTPUT_STYLE_PREF:-opencode}"

  jq -s --arg output_style_pref "${output_style_pref}" '
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
    | (
        # Resolve OMC_OUTPUT_STYLE_PREF to a target bundled style name.
        # Used by both the legacy-migration path and the bundled-sync path
        # below.
        (if $output_style_pref == "executive" then "executive-brief"
         elif $output_style_pref == "opencode" then "oh-my-claude"
         else $patch.outputStyle
         end) as $target
        # Legacy migration: pre-v1.26.0 installs left "OpenCode Compact"
        # in settings, but the underlying style file was renamed to
        # oh-my-claude and the legacy file removed. Leaving the legacy
        # name would orphan the user (Claude Code cannot resolve it).
        # Always migrate, even under preserve — preserve protects user
        # choices, not installer artifacts pointing at a deleted style.
        | if .outputStyle == "OpenCode Compact" then
            .outputStyle = $target
          elif $output_style_pref == "preserve" then
            .
          else
            # Bundled-sync path: a user-set outputStyle that does NOT
            # match a current bundled style name is preserved (custom
            # styles win); bundled-name values are auto-synced so
            # /omc-config can switch between bundled styles.
            (.outputStyle) as $current
            | if ($current == null) or ($current == "oh-my-claude") or ($current == "executive-brief")
              then .outputStyle = $target
              else .
              end
          end
      )
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

  # Back up any Ghostty files that will be touched. v1.36.0: respect
  # the --no-ghostty / auto-detect gate so backups don't pull in
  # ghostty paths the install will not touch.
  if [[ -d "${BUNDLE_GHOSTTY}" ]] && should_install_ghostty; then
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
  if [[ -f "${CLAUDE_HOME}/install-resume-watchdog.sh" ]]; then
    chmod +x "${CLAUDE_HOME}/install-resume-watchdog.sh"
  fi
}

# ---------------------------------------------------------------------------
# Install the opt-in post-merge git hook
# ---------------------------------------------------------------------------
#
# A git pull on the oh-my-claude source repo updates the bundle but doesn't
# sync the changes to `~/.claude/`. Users who forget to re-run `install.sh`
# end up running a stale installed harness against a newer source, which
# defeats the stale-install indicator and produces subtle drift.
#
# Enabling `--git-hooks` writes `.git/hooks/post-merge` in the oh-my-claude
# source checkout. After every merge (which includes `git pull`), the hook
# compares `installed-manifest.txt` against the current bundle and prompts
# the user to re-install if any files differ. The prompt is non-blocking and
# honored via `OMC_AUTO_INSTALL=1` for CI or confident users.
install_git_hooks() {
  local source_repo="${SCRIPT_DIR}"

  if ! command -v git >/dev/null 2>&1; then
    printf '  Git hooks:     skipped (git not found)\n'
    return
  fi
  if [[ ! -d "${source_repo}/.git" ]]; then
    printf '  Git hooks:     skipped (%s is not a git worktree)\n' "${source_repo}"
    return
  fi

  local hooks_dir="${source_repo}/.git/hooks"
  local hook_path="${hooks_dir}/post-merge"

  # If something is already at post-merge that isn't ours, do not overwrite
  # — the user may have a custom hook. Refuse and tell them.
  if [[ -e "${hook_path}" ]] && ! grep -q '# oh-my-claude post-merge auto-sync' "${hook_path}" 2>/dev/null; then
    printf '  Git hooks:     skipped (existing %s is not an oh-my-claude hook)\n' "${hook_path}"
    printf '                 Move or delete it, then re-run with --git-hooks to install.\n'
    return
  fi

  mkdir -p "${hooks_dir}"
  cat > "${hook_path}" <<'HOOK'
#!/usr/bin/env bash
# oh-my-claude post-merge auto-sync
#
# Compares this repo's bundle against the installed manifest at
# ~/.claude/quality-pack/state/installed-manifest.txt. If any bundle file
# differs from what was installed last time, prompts the user to re-run
# install.sh. Set OMC_AUTO_INSTALL=1 to skip the prompt and install
# automatically (useful for CI / trusted environments).
#
# Non-blocking: a skipped install simply means the user runs `bash
# install.sh` when they're ready. The hook never aborts the git operation.

set -euo pipefail

# Locate the repo root. The post-merge hook runs inside .git/hooks/, so
# git rev-parse gives us the actual worktree.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || exit 0

bundle_dir="${repo_root}/bundle/dot-claude"
installer="${repo_root}/install.sh"
manifest="${HOME}/.claude/quality-pack/state/installed-manifest.txt"

# Abort cleanly if the repo doesn't have the expected oh-my-claude layout.
[[ -f "${installer}" && -d "${bundle_dir}" ]] || exit 0

# No manifest yet → user hasn't installed from this checkout. Don't prompt.
[[ -f "${manifest}" ]] || exit 0

# Build the current bundle file list with the same ordering the installer uses.
current_tmp="$(mktemp)"
trap 'rm -f "${current_tmp}"' EXIT
(cd "${bundle_dir}" && find . -type f ! -name '.DS_Store' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort) > "${current_tmp}"

# Fast check: if the set of files changed at all, warn.
added_or_removed=0
if ! LC_ALL=C diff -q "${manifest}" "${current_tmp}" >/dev/null 2>&1; then
  added_or_removed=1
fi

# Also check content changes: any file newer than the install stamp means
# the bundle was modified since we last installed.
stamp="${HOME}/.claude/.install-stamp"
content_changed=0
if [[ -f "${stamp}" ]]; then
  if find "${bundle_dir}" -type f -newer "${stamp}" -print -quit 2>/dev/null | grep -q .; then
    content_changed=1
  fi
fi

if [[ "${added_or_removed}" -eq 0 && "${content_changed}" -eq 0 ]]; then
  exit 0
fi

printf '\n'
# v1.31.0 Wave 5 (visual-craft F-6 partial): TTY-guard the colored prefix.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  printf '\033[1;33m[oh-my-claude]\033[0m Bundle changes detected after merge.\n'
else
  printf '[oh-my-claude] Bundle changes detected after merge.\n'
fi
if [[ "${added_or_removed}" -eq 1 ]]; then
  printf '  - File set changed (additions or removals).\n'
fi
if [[ "${content_changed}" -eq 1 ]]; then
  printf '  - One or more bundle files newer than last install.\n'
fi

if [[ "${OMC_AUTO_INSTALL:-0}" == "1" ]]; then
  printf '  OMC_AUTO_INSTALL=1 — running installer now...\n'
  bash "${installer}"
  exit 0
fi

printf '\n  Re-run the installer to sync these changes into ~/.claude/:\n'
printf '    bash %s\n' "${installer}"
printf '\n  Set OMC_AUTO_INSTALL=1 to run the installer automatically from this hook.\n'
printf '\n'
HOOK
  chmod +x "${hook_path}"
  printf '  Git hooks:     installed post-merge auto-sync at %s\n' "${hook_path}"
}

# ---------------------------------------------------------------------------
# Remove the post-merge hook (called when --git-hooks is NOT set and a
# stale oh-my-claude-authored hook already exists, so users can opt out
# by re-running install without the flag).
# ---------------------------------------------------------------------------
remove_git_hooks_if_ours() {
  local hook_path="${SCRIPT_DIR}/.git/hooks/post-merge"
  [[ -f "${hook_path}" ]] || return
  if grep -q '# oh-my-claude post-merge auto-sync' "${hook_path}" 2>/dev/null; then
    # Leave it in place silently — users who explicitly installed it once
    # would be surprised if a subsequent install removed it. Toggling off
    # is a manual step (delete the hook file).
    :
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

  # If no flag was passed, read from config file. Use `tail -1` (last-
  # write-wins) to match common.sh's runtime parser and omc-config.sh's
  # writer — both append on update, so the most-recent value is the
  # source of truth. (Pre-existing `head -1` was inconsistent with the
  # rest of the codebase; fixed alongside the same-pattern fix at the
  # output_style conf-read site introduced in v1.24.0 wave 3.)
  if [[ -z "${tier}" && -f "${conf_path}" ]]; then
    tier="$(grep -E '^model_tier=' "${conf_path}" 2>/dev/null | tail -1 | cut -d= -f2)" || true
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

should_install_ghostty() {
  case "${INSTALL_GHOSTTY_FLAG}" in
    yes) return 0 ;;
    no)  return 1 ;;
    *)
      # Auto-detect (default): install only when the user already has
      # a ~/.config/ghostty/ directory. Closes the silent side-effect
      # on hosts that don't run Ghostty terminal — pre-v1.36.0 every
      # install seeded the dir even on iTerm/Terminal/Alacritty hosts.
      #
      # Limitation: this checks for the dir, not the binary. A user
      # who removed Ghostty.app but left ~/.config/ghostty/ behind
      # will still get the seed. The benign cost is an orphan config
      # update; the alternative (binary probe) hits portability traps
      # (path differences across Linux distros, App Store sandbox vs
      # cask installs on macOS, etc.). Power users who want strict
      # control pass --no-ghostty / --with-ghostty explicitly.
      [[ -d "${GHOSTTY_HOME}" ]]
      ;;
  esac
}

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

# Up-front notice about --bypass-permissions. Shown BEFORE any filesystem
# changes so users who wanted maximum-autonomy mode can Ctrl-C and re-run
# with the flag rather than discover the option only in the post-install
# tip. The old placement (banner after install completed) meant power users
# ran the installer twice on their first day — once to "see what happens,"
# and once with the flag. Surface the choice before commitment instead.
#
# Only printed on interactive terminals (TTY stdin) — curl-pipe-bash and
# CI runs have no interactive cancel and would see a misleading "press
# Ctrl-C now" message from a stream they can't intercept anyway.
# CI detection: `-z "${CI:-}"` catches `CI=true` (GitHub Actions, GitLab,
# CircleCI, Travis, Buildkite), `CI=1` (custom runners), and anything else
# truthy. The prior `!= "1"` check was dead — no mainstream CI sets CI=1.
if [[ "${BYPASS_PERMISSIONS}" != "true" ]] && [[ -z "${CI:-}" ]] && [[ -t 0 ]]; then
  printf '\n'
  printf "  Installing with Claude Code's per-tool permission prompts on by default.\n"
  printf "  Once you've run /ulw-demo and trust the harness, --bypass-permissions removes\n"
  printf "  the prompts. Quality gates apply either way.\n"
  printf '\n'
fi

printf 'Installing oh-my-claude into %s ...\n' "${CLAUDE_HOME}"

# Step 1 — Create directories and back up existing files.
# Security: BACKUP_DIR holds copies of prior settings.json + oh-my-claude.conf
# (which carries claude_bin pin, model_tier, and other host-specific values).
# A2-MED-6 (4-attacker security review): chmod 700 the backup tree so a
# read-anywhere-in-${HOME} attacker cannot mine prior state for credentials,
# tokens, or oracle the user's PATH layout. The parent tree (${CLAUDE_HOME})
# is not blanket-700 (Claude Code itself reads files there), so harden the
# backup directly. The chmod runs before backup_existing_targets writes to
# the dir so the perms apply to the freshly-created tree.
mkdir -p "${CLAUDE_HOME}" "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}" 2>/dev/null || true
# v1.36.0: surface user edits in memory/ before rsync overwrites them.
# Runs BEFORE backup_existing_targets and BEFORE rsync — the warning
# fires while the live edit is still untouched on disk, so a Ctrl-C
# during the 5s wait (interactive only) leaves the file intact for the
# user to migrate. The subsequent backup_existing_targets does eventually
# preserve a copy under ${BACKUP_DIR}, but that recovery path is the
# fallback, not the contract surfaced in the warn message.
warn_modified_memory_files
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

# Step 2c — Save repo path, installed version, and installed SHA for
# easy updates. The SHA lets the stale-install indicator detect a
# commits-ahead state even when VERSION hasn't been bumped (e.g. the
# repo has unreleased commits on main past the last tag). Silently
# clears installed_sha when the install source is not a git worktree
# (tarball, extracted zip) so a prior worktree install's SHA does not
# linger as a false comparator.
#
# v1.30.0: capture the prior installed_version BEFORE overwriting so the
# post-install summary can render a "What's new since v$prev" block.
# Empty on first install, on tarball / zip extracts without a prior conf,
# and on the unusual case where a custom build cleared the conf.
PRIOR_INSTALLED_VERSION=""
if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
  PRIOR_INSTALLED_VERSION="$(grep -E '^installed_version=' "${CLAUDE_HOME}/oh-my-claude.conf" 2>/dev/null \
    | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
fi

set_conf "repo_path" "${SCRIPT_DIR}"
set_conf "installed_version" "${OMC_VERSION}"

installed_sha=""
if command -v git >/dev/null 2>&1 && [[ -d "${SCRIPT_DIR}/.git" ]]; then
  installed_sha="$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -n "${installed_sha}" ]]; then
  set_conf "installed_sha" "${installed_sha}"
else
  # Source is not a git worktree (tarball, extracted zip) — remove any
  # stale installed_sha left from a previous worktree-based install so
  # the statusline's commit-distance probe fails closed (returns None)
  # instead of reading an orphaned SHA and producing a misleading
  # `(+?)` marker against the next worktree this repo path maps to.
  _conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  if [[ -f "${_conf_path}" ]] && grep -q '^installed_sha=' "${_conf_path}"; then
    _tmp="${_conf_path}.tmp"
    grep -v '^installed_sha=' "${_conf_path}" > "${_tmp}" 2>/dev/null || true
    mv "${_tmp}" "${_conf_path}"
  fi
fi

# Ensure quality-pack state directory exists (not in the bundle).
mkdir -p "${CLAUDE_HOME}/quality-pack/state"

# Tighten quality-pack directory permissions to 700. Files inside are
# created with `umask 077` (set by common.sh) so they're already 600,
# but the parent directories default to 755 from `mkdir -p` under the
# user's umask. On shared machines this lets local peers list session
# UUIDs and time-correlate harness activity even when the file contents
# are unreadable. Tightening the parent dirs to 700 closes that
# exposure. Idempotent — re-running install on an already-700 dir is
# a no-op. Soft-failure (`|| true`) so a permission-restricted parent
# (synced volume, mounted FUSE) does not abort the install.
chmod 700 "${CLAUDE_HOME}/quality-pack" "${CLAUDE_HOME}/quality-pack/state" 2>/dev/null || true

# Step 2c-manifest — Orphan detection via bundle-file manifest.
# rsync -a without --delete leaves files from prior releases sitting in
# ~/.claude/ if the new bundle removed them (e.g. a renamed script). The
# manifest snapshot compares what was in the previous install against
# what's in the new bundle and warns about files that no longer ship so
# the user can decide whether to keep, delete, or clean-reinstall.
MANIFEST_PATH="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
NEW_MANIFEST_TMP="$(mktemp)"
# Collect bundle's relative file list from the new source, sorted. Used
# both to diff against the previous manifest (orphan detection) and to
# persist as the new manifest for the next install cycle.
#
# Locale discipline matters here: `comm -23` requires identically-sorted
# inputs, but `sort` (and `comm`) honor LC_COLLATE. A user who installs
# under `LC_ALL=en_US.UTF-8` and later re-installs under `LC_ALL=C`
# would see every mixed-case filename mis-ordered relative to the
# on-disk manifest, producing spurious orphan warnings. Pinning both
# the manifest build AND the comm comparison to `LC_ALL=C` gives a
# stable byte-order key that matches across install runs regardless of
# the user's environment.
(cd "${BUNDLE_CLAUDE}" && find . -type f ! -name '.DS_Store' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort) > "${NEW_MANIFEST_TMP}"

orphan_count=0
orphan_list=""
if [[ -f "${MANIFEST_PATH}" ]]; then
  # `comm -23 OLD NEW` prints lines in OLD that are not in NEW — i.e.
  # files that shipped in a prior release but are no longer in the new
  # bundle. We only warn when the orphan file still exists on disk; a
  # user may have already cleaned it up manually.
  while IFS= read -r orphan_rel; do
    [[ -z "${orphan_rel}" ]] && continue
    if [[ -f "${CLAUDE_HOME}/${orphan_rel}" ]]; then
      orphan_count=$((orphan_count + 1))
      orphan_list="${orphan_list}    ${orphan_rel}"$'\n'
    fi
  done < <(LC_ALL=C comm -23 "${MANIFEST_PATH}" "${NEW_MANIFEST_TMP}")
fi

mv "${NEW_MANIFEST_TMP}" "${MANIFEST_PATH}"

# Step 2c-hash — SHA-256 manifest for drift detection (A2-MED-4 from
# 4-attacker security review).
#
# The path-only manifest above tells verify.sh "these files should
# exist". It does NOT tell verify.sh "these files should still contain
# their bundled bytes". An A2 attacker (write-inside-`~/.claude/`)
# who replaces an installed script (e.g., stop-guard.sh swapped for an
# exfiltration shim that still passes `bash -n`) goes undetected by the
# existing existence-and-syntax checks. The hashes file closes that gap:
# verify.sh re-hashes each tracked path and fails on mismatch.
#
# Best-effort: if neither shasum nor sha256sum is available, skip the
# write. verify.sh treats a missing hashes file as "drift-detection
# unavailable" (a [warn], not a [FAIL]) so we don't break installs on
# minimal containers without coreutils.
#
# v1.36.0 (item #16): hash CLAUDE_HOME bytes (not BUNDLE_CLAUDE).
#
# The pre-fix design hashed BUNDLE_CLAUDE under the assumption that
# rsync -a preserves bytes faithfully so bundle hash == at-rest hash.
# This was broken-by-design for any user with model_tier=quality or
# model_tier=economy: apply_model_tier() runs AFTER rsync and rewrites
# the `model:` field of every agent file in CLAUDE_HOME. The hash
# manifest still reflects the bundle bytes (sonnet/opus original),
# but the live files now carry the rewritten tier — so verify.sh
# drift detection fired FAILED on every model-tier-customized install.
# Symptom: 21 spurious actionable warnings on a clean install for a
# user on quality tier (one per agent file with a `model:` field).
#
# Fix: hash the live CLAUDE_HOME files AFTER all post-rsync mutations
# (apply_model_tier, --no-ios removals). The hash manifest now reflects
# what's actually on disk. The MANIFEST_PATH file (written above)
# enumerates the bundle file list; we filter to "still exists in
# CLAUDE_HOME" so --no-ios removals are not treated as drift.
HASHES_PATH="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
NEW_HASHES_TMP="$(mktemp)"
# Compose the hash-input list: every line in MANIFEST_PATH that still
# resolves to an existing file under CLAUDE_HOME. mktemp form because
# the count can be ~150 paths and we want a single batched xargs.
HASH_INPUT_TMP="$(mktemp)"
if [[ -f "${MANIFEST_PATH}" ]]; then
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    [[ -f "${CLAUDE_HOME}/${p}" ]] && printf '%s\n' "${p}"
  done < "${MANIFEST_PATH}" | LC_ALL=C sort > "${HASH_INPUT_TMP}"
fi
# Hash via xargs (single batched invocation) instead of one fork-exec
# per file. Both shasum and sha256sum accept multiple paths and emit
# `<hash>  <path>` per file in argv order.
if [[ -s "${HASH_INPUT_TMP}" ]]; then
  if command -v shasum >/dev/null 2>&1; then
    (cd "${CLAUDE_HOME}" && xargs shasum -a 256 < "${HASH_INPUT_TMP}") > "${NEW_HASHES_TMP}" 2>/dev/null || true
  elif command -v sha256sum >/dev/null 2>&1; then
    (cd "${CLAUDE_HOME}" && xargs sha256sum < "${HASH_INPUT_TMP}") > "${NEW_HASHES_TMP}" 2>/dev/null || true
  fi
fi
rm -f "${HASH_INPUT_TMP}"
if [[ -s "${NEW_HASHES_TMP}" ]]; then
  mv "${NEW_HASHES_TMP}" "${HASHES_PATH}"
else
  rm -f "${NEW_HASHES_TMP}"
fi

# Step 2d — Create user-override directory (never overwritten by rsync).
# Files in omc-user/ survive updates. Existing user content is preserved.
# The template is seeded on first install; subsequent installs only ensure
# overrides.md exists (the bundle CLAUDE.md @-references it unconditionally).
OMC_USER_DIR="${CLAUDE_HOME}/omc-user"
OMC_USER_TEMPLATE="${SCRIPT_DIR}/bundle/omc-user-template"
if [[ ! -d "${OMC_USER_DIR}" ]]; then
  mkdir -p "${OMC_USER_DIR}"
  if [[ -d "${OMC_USER_TEMPLATE}" ]]; then
    rsync -a "${OMC_USER_TEMPLATE}/" "${OMC_USER_DIR}/"
    printf '  Created user-override directory: %s\n' "${OMC_USER_DIR}"
  fi
elif [[ ! -f "${OMC_USER_DIR}/overrides.md" ]]; then
  # Ensure overrides.md exists even if user deleted it or upgraded from
  # a version that didn't create it — the @-reference in CLAUDE.md needs it.
  if [[ -f "${OMC_USER_TEMPLATE}/overrides.md" ]]; then
    cp "${OMC_USER_TEMPLATE}/overrides.md" "${OMC_USER_DIR}/overrides.md"
  else
    printf '# User Overrides\n' > "${OMC_USER_DIR}/overrides.md"
  fi
fi

# Step 3 — Install Ghostty theme/config (no-op if bundle has none, or
# if --no-ghostty / auto-detect skipped it).
if should_install_ghostty; then
  install_ghostty
fi

# Step 4 — Merge settings.json (idempotent).
#
# Honor the user's `output_style` preference if they set one previously
# (in ~/.claude/oh-my-claude.conf, written by /omc-config or hand-edit).
# `preserve` skips the outputStyle merge so install never touches the
# user's setting (or absence of it). `opencode` (default, also unset) is
# the existing behavior.
OMC_OUTPUT_STYLE_PREF="${OMC_OUTPUT_STYLE:-opencode}"
if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]] && [[ -z "${OMC_OUTPUT_STYLE:-}" ]]; then
  # Use `tail -1` (last-write-wins) to match the runtime parser in
  # bundle/dot-claude/skills/autowork/scripts/common.sh and the conf
  # writer in omc-config.sh — both append on update, so the most-recent
  # value is the source of truth. Pre-existing `head -1` at line ~766
  # for model_tier diverges from this contract; tracked as a follow-up.
  _pref_from_conf="$(grep -E '^output_style=' "${CLAUDE_HOME}/oh-my-claude.conf" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  if [[ "${_pref_from_conf}" =~ ^(opencode|executive|preserve)$ ]]; then
    OMC_OUTPUT_STYLE_PREF="${_pref_from_conf}"
  fi
fi
export OMC_OUTPUT_STYLE_PREF

# v1.32.16 Wave 6 (release-reviewer follow-up): capture .statusLine.command
# pre-merge so warn_foreign_statusline can compare. The merge_settings_*
# functions OVERWRITE .statusLine with the bundled patch value, so a
# post-merge read always returns the bundle. Capturing here is the only
# point at which the user's pre-install value is visible.
PRE_MERGE_STATUSLINE_CMD=""
# Tool-detection ladder mirrors the merger below (python3 first, jq
# fallback). Pre-fix this only checked jq, silently skipping the warn
# on python3-only hosts even though the merger ran successfully via
# python3 — the recovery-boundary signal was missed for users on
# minimal containers without jq.
if [[ -f "${CLAUDE_HOME}/settings.json" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PRE_MERGE_STATUSLINE_CMD="$(python3 -c '
import json, sys
try:
  with open(sys.argv[1]) as f:
    data = json.load(f)
  sl = data.get("statusLine") or {}
  if isinstance(sl, dict):
    cmd = sl.get("command") or ""
    sys.stdout.write(cmd if isinstance(cmd, str) else "")
except Exception:
  pass
' "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
  elif command -v jq >/dev/null 2>&1; then
    PRE_MERGE_STATUSLINE_CMD="$(jq -r '.statusLine.command // empty' \
      "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  merge_settings_python "${CLAUDE_HOME}/settings.json" "${SETTINGS_PATCH}" "${BYPASS_PERMISSIONS}"
elif command -v jq >/dev/null 2>&1; then
  merge_settings_jq "${CLAUDE_HOME}/settings.json" "${SETTINGS_PATCH}" "${BYPASS_PERMISSIONS}"
else
  printf 'Need either python3 or jq to merge settings.\n' >&2
  exit 1
fi

# Step 4a — Foreign hook detection (A2-HIGH-1 from 4-attacker security
# review).
#
# The settings-merge above is purely additive: any hook entry already
# present in settings.json that doesn't conflict with a bundled patch
# entry (matcher- AND basename-disjoint) survives every reinstall. An
# A2 attacker (write-inside-`~/.claude/`) who plants
#   { "matcher": "*", "command": "bash /tmp/persistence.sh" }
# inside ~/.claude/settings.json gains a hook that fires on every event
# AND survives every reinstall the user runs to "fix" their environment.
# Without this warning the survival is silent: the user's natural
# recovery action (re-install) returns no signal of foreign content.
#
# We do not DELETE foreign entries here because (a) the user may
# legitimately have non-bundled hooks (custom integrations), and (b)
# destructive automation at install time would be alarming. We surface
# them so the user can audit and prune. The verify.sh-side equivalent
# (Step 8 in verify.sh) reports the same detection (default-warn or
# --strict-fail), giving the user a clear "your install passes
# structural checks but contains unexpected hook commands" signal.
#
# Allowlist (FULL-STRING match, ALL of these must hold):
#   1. Optional interpreter prefix: `bash `, `sh `, `dash `, or
#      `python3 ` (single space, no absolute interpreter paths — those
#      could be attacker-shimmed without flagging the path-allowlist).
#   2. Path root: `$HOME/.claude/` or `~/.claude/` (literal `$HOME` or
#      `~`, not the expanded form — Claude Code expands at hook-fire).
#   3. Bundled subpath: `skills/autowork/scripts/<name>.sh`,
#      `quality-pack/scripts/<name>.sh`, or `statusline.py`. `<name>`
#      restricted to `[A-Za-z0-9_-]` so `..` traversal is structurally
#      rejected (`.` is not in the class).
#   4. Optional positional args: each `[A-Za-z0-9_-]+`, space-separated.
#      Bundled patch ships `record-reviewer.sh design_quality` shape.
#   5. End anchor: nothing after the last positional arg. `;`, `&&`,
#      `||`, `|`, `>`, `<`, `` ` ``, `$(`, newline, tab, multi-line —
#      all structurally rejected because they're not in the args class
#      AND they appear after the path/args region the regex consumes.
#
# Whitespace pre-normalization at line below collapses runs of space/
# tab to single space so cosmetic variants of legitimate bundled
# commands (e.g. `bash  $HOME/...` with a double space) don't false-
# positive. This is sound because shell command parsing collapses the
# same way at exec time.
warn_foreign_hooks() {
  local settings_file="$1"
  [[ -f "${settings_file}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Distinguish jq parse failure (malformed JSON — itself an A2
  # indicator that warrants a loud signal) from "no foreign entries
  # found" (silence is correct).
  local cmds jq_err jq_rc
  jq_err="$(jq -r '
    [
      (.hooks // {}) | to_entries[] |
      .value[]? |
      (.hooks // [])[]? |
      .command // empty
    ] | unique | .[]
  ' "${settings_file}" 2>&1)"
  jq_rc=$?

  if [[ ${jq_rc} -ne 0 ]]; then
    printf '\n'
    printf '  [warn] settings.json could not be parsed by jq:\n'
    printf '    %s\n' "${jq_err}"
    printf '  Foreign-hook detection skipped on this install. Re-check\n'
    printf '  the file and re-run install.sh.\n'
    printf '\n'
    return 0
  fi
  cmds="${jq_err}"

  # FULL-string match anchors. `[$]HOME` is the unambiguous form for a
  # literal `$HOME` token (vs `\$HOME` whose ERE escape semantics are
  # implementation-dependent across bash versions).
  local bundled_re='^(bash |sh |dash |python3 )?([$]HOME|~)/\.claude/(skills/autowork/scripts/[A-Za-z0-9_-]+\.sh|quality-pack/scripts/[A-Za-z0-9_-]+\.sh|statusline\.py)( [A-Za-z0-9_-]+)*$'
  local foreign="" cmd norm
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    # Collapse whitespace runs to single spaces (handles `bash  $HOME/`
    # double-space and tab-separated cosmetic variants).
    norm="$(printf '%s' "${cmd}" | tr -s '[:space:]' ' ')"
    if [[ ! "${norm}" =~ ${bundled_re} ]]; then
      foreign+="    ${cmd}"$'\n'
    fi
  done <<< "${cmds}"

  if [[ -n "${foreign}" ]]; then
    printf '\n'
    printf '  [warn] Detected non-bundled hook commands in settings.json:\n'
    printf '%s' "${foreign}"
    printf '  These survive reinstalls. They may be legitimate custom hooks,\n'
    printf '  but warrant a manual audit. Inspect with:\n'
    printf '    jq .hooks %s\n' "${settings_file}"
    printf '\n'
  fi

}

# warn_foreign_statusline — paired with warn_foreign_hooks, fires
# AFTER merge_settings_*. Compares the PRE_MERGE_STATUSLINE_CMD
# value (captured BEFORE the merge above) against the bundled value;
# if they differed, surface a warning so the user knows install.sh
# just thwarted (or normalized) a divergence. .statusLine.command is
# a code-execution surface Claude Code execs every status-bar
# refresh; the bundled patch is a single fixed value
# (`~/.claude/statusline.py`) — equality check is cheaper than the
# foreign-hook regex.
warn_foreign_statusline() {
  # shellcheck disable=SC2088 # comparing unexpanded `~` literal — bundled patch ships the unexpanded form, Claude Code expands at exec time
  if [[ -n "${PRE_MERGE_STATUSLINE_CMD}" \
     && "${PRE_MERGE_STATUSLINE_CMD}" != "~/.claude/statusline.py" ]]; then
    printf '\n'
    printf '  [warn] .statusLine.command differed from bundled value pre-install.\n'
    printf '    Pre-install: %s\n' "${PRE_MERGE_STATUSLINE_CMD}"
    printf '    Restored to: ~/.claude/statusline.py\n'
    printf '  install.sh always overwrites .statusLine on merge, but the\n'
    printf '  divergence has been logged so you can investigate whether\n'
    printf '  it was intentional or a sign of tampering.\n'
    printf '\n'
  fi
}

warn_foreign_hooks "${CLAUDE_HOME}/settings.json"
warn_foreign_statusline

# Step 5 — Set executable bits on scripts.
ensure_executable_bits

# Step 6 — Install stamp. Gives users a reliable "what changed in this
# install" reference (find ~/.claude -newer ~/.claude/.install-stamp).
# rsync -a preserves the bundle's mtimes rather than setting them to now,
# so without an explicit stamp no tooling can distinguish "touched by this
# install" from "cloned at this time". Uses `touch` with no flags so both
# BSD (macOS) and GNU (Linux) touch behave identically (-d is a GNU-ism).
touch "${CLAUDE_HOME}/.install-stamp"

# Step 7 — Optional: install the post-merge git hook in the source checkout.
if [[ "${INSTALL_GIT_HOOKS}" == "true" ]]; then
  install_git_hooks
fi

# Step 8 (v1.36.0) — Prune old backup directories. Runs LAST so an
# install that aborts mid-flight leaves the just-created backup intact
# for recovery; only runs when the install completed past the executable
# bits + stamp steps.
prune_old_backups

# ===========================================================================
# Summary
# ===========================================================================

printf '\n'
# v1.31.0 Wave 5 (visual-craft F-1): unified box-rule card head matching
# /ulw-time, show-status, and the welcome banner. Pre-Wave-5 used the
# generic `=== title ===` form which reads as "default-Bash-tutorial"
# in the visual-craft assessment.
printf '─── oh-my-claude install complete ───\n'
printf '\n'
printf '  Version:       %s\n' "${OMC_VERSION}"
if [[ -n "${installed_sha}" ]]; then
  printf '  Commit:        %s\n' "${installed_sha:0:12}"
fi
# v1.30.0: when the installed_version changed, surface the version
# headings between PRIOR_INSTALLED_VERSION and OMC_VERSION extracted
# from CHANGELOG.md. Closes the v1.29.0 product-lens P2-10 / growth-lens
# P2-10 deferred item — users running `git pull && bash install.sh`
# weekly previously got zero in-context awareness of what changed.
# Silent on: first install (PRIOR empty), same-version reinstall (no
# upgrade), missing CHANGELOG, awk extraction failure. Caps at 30 entries
# (v1.32.7 raised from 15 to end the recurring cap-bump cycle that
# broke install-whats-new tests in v1.31.1 / v1.32.1 / v1.32.3 /
# v1.32.5 / v1.32.6 — every 3-5 patches the cap had to be re-bumped
# because adding entries pushed a real 1.27.0 → head upgrade past it.
# 30 covers any reasonable upgrade span without the periodic bump
# pressure. The deeper "derive from tag count" answer doesn't work
# reliably because install-remote.sh defaults to a shallow clone
# (--depth=1) without --tags, so `git tag --list` is unreliable.
# user can read CHANGELOG.md for full detail.
if [[ -n "${PRIOR_INSTALLED_VERSION}" ]] \
    && [[ "${PRIOR_INSTALLED_VERSION}" != "${OMC_VERSION}" ]] \
    && [[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]]; then
  # v1.36.0 (item #6): collapse same-X.Y patches into one summary line.
  # Pre-v1.36.0 the awk listed every CHANGELOG `## [X.Y.Z]` heading
  # individually — e.g., a 1.27.0 → 1.34.x upgrade rendered 16 separate
  # 1.32.x patch lines, dominating the install footer with low-signal
  # noise. New shape:
  #   - 1.34.0  (date)              ← single-entry minor: full line
  #   - 1.32.x  (16 entries — see CHANGELOG.md, range 1.32.0 → 1.32.16)
  #
  # Two-pass logic kept inside one awk invocation: pass 1 walks lines
  # in the file's natural reverse-chronological order, accumulates a
  # current minor (X.Y), counts patches, and flushes one line per
  # minor (or per individual entry if the minor has only one). Stops
  # at the prior version. The 40-entry cap from v1.34.2 stays in
  # place but now bounds the number of UNIQUE minors that can be
  # emitted, which is more forgiving than the old per-patch cap.
  #
  # OMC_INSTALL_VERBOSE=1 toggles the full per-patch view back on for
  # users who specifically want it (e.g., debugging which exact patch
  # fixed something).
  if [[ "${OMC_INSTALL_VERBOSE:-0}" == "1" ]]; then
    _whats_new="$(awk -v prev="${PRIOR_INSTALLED_VERSION}" -v curr="${OMC_VERSION}" '
      /^## \[/ {
        ver = $0
        sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
        datepart = $0
        sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)
        if (ver == prev) { exit }
        kept++
        if (kept > 40) { truncated = 1; exit }
        if (ver == "Unreleased") {
          printf "                   - %s\n", ver
        } else {
          printf "                   - %s%s\n", ver, (datepart == "" ? "" : "  (" datepart ")")
        }
      }
      END { if (truncated) print "                   - ... (older entries — see CHANGELOG.md)" }
    ' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  else
    _whats_new="$(awk -v prev="${PRIOR_INSTALLED_VERSION}" -v curr="${OMC_VERSION}" '
      function flush(   line) {
        if (current_minor == "") return
        if (current_count == 1) {
          line = current_first
          if (current_first_date != "") { line = line "  (" current_first_date ")" }
          printf "                   - %s\n", line
        } else {
          # current_first is the FIRST seen (highest patch since CHANGELOG
          # is reverse-chronological); current_last is the LAST seen
          # (lowest patch in the run). Emit the inclusive range so users
          # know the span at a glance without reading the full CHANGELOG.
          printf "                   - %s.x  (%d entries — range %s → %s)\n", \
            current_minor, current_count, current_last, current_first
        }
        current_minor = ""; current_count = 0
        current_first = ""; current_first_date = ""; current_last = ""
      }
      /^## \[/ {
        ver = $0
        sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
        datepart = $0
        sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)

        # Stop at the prior version — flush any pending group first
        # so the trailing minor is rendered before exit.
        if (ver == prev) { flush(); exit }

        if (ver == "Unreleased") {
          flush()
          printf "                   - %s\n", ver
          next
        }

        # Extract minor (X.Y) from X.Y.Z. Non-semver versions go
        # through unchanged as their own minor.
        n = split(ver, parts, ".")
        if (n >= 2) {
          minor = parts[1] "." parts[2]
        } else {
          minor = ver
        }

        if (minor != current_minor) {
          flush()
          # Cap on UNIQUE minors emitted (was 40 per-patch; now 40 minors).
          minors_emitted++
          if (minors_emitted > 40) { truncated = 1; exit }
          current_minor = minor
          current_count = 1
          current_first = ver
          current_first_date = datepart
          current_last = ver
        } else {
          current_count++
          current_last = ver
        }
      }
      END {
        flush()
        if (truncated) print "                   - ... (older entries — see CHANGELOG.md)"
      }
    ' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  fi
  if [[ -n "${_whats_new}" ]]; then
    printf '  What'\''s new:    versions since v%s:\n' "${PRIOR_INSTALLED_VERSION}"
    printf '%s' "${_whats_new}"
    printf '                   See %s/CHANGELOG.md for details.\n' "${SCRIPT_DIR}"
  fi
fi

# v1.36.0 (item #14): surface the v1.34.0 omc-repro.sh redaction
# advisory if the user is upgrading from a version inside the affected
# range (v1.29.0 ≤ prior ≤ v1.33.2). Pre-v1.34.0 omc-repro.sh tarballs
# may carry prompt-text fragments under state-corruption rows in the
# bundled gate_events.jsonl — the advisory was buried mid-CHANGELOG and
# easily missed. Surface as a [security] line in the install footer so
# users who are likely to be affected see it during upgrade rather than
# discovering it later.
#
# Affected range encoding: a simple lexical-by-component check. Matches
# 1.29.x, 1.30.x, 1.31.x, 1.32.x, 1.33.0, 1.33.1, 1.33.2 — and excludes
# 1.33.3+ and 1.34.x+. Custom builds outside the semver shape silently
# skip — the BASH_REMATCH check below returns 1 on non-`X.Y.Z` input,
# so suffixed versions like `1.30.0-beta` and pre-tag dev strings are
# treated as out-of-range (conservative — no advisory fires).
_omc_in_affected_repro_range() {
  local v="$1"
  [[ -z "${v}" ]] && return 1
  # Must match X.Y.Z numeric.
  [[ "${v}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[2]}" pat="${BASH_REMATCH[3]}"
  # Only major=1 is relevant.
  [[ "${maj}" -eq 1 ]] || return 1
  # 1.29 to 1.32 — entire minor window.
  if [[ "${min}" -ge 29 ]] && [[ "${min}" -le 32 ]]; then return 0; fi
  # 1.33.0 to 1.33.2 inclusive.
  if [[ "${min}" -eq 33 ]] && [[ "${pat}" -le 2 ]]; then return 0; fi
  return 1
}

if [[ -n "${PRIOR_INSTALLED_VERSION}" ]] \
    && _omc_in_affected_repro_range "${PRIOR_INSTALLED_VERSION}"; then
  printf '\n'
  printf '  [security]     Upgrading from v%s — affected by the v1.34.0 omc-repro.sh advisory.\n' "${PRIOR_INSTALLED_VERSION}"
  printf '                 If you ran `omc-repro.sh` on v1.29.0–v1.33.2 AND shared the output,\n'
  printf '                 the bundled gate_events.jsonl may carry prompt-text fragments under\n'
  printf '                 state-corruption rows. Rotate or redact any tarball you have already\n'
  printf '                 shared. The cross-session ledger in this install is already scrubbed.\n'
  printf '                 See CHANGELOG.md v1.34.0 entry for full details.\n'
fi
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
# Clean up old-name output-style file from pre-v1.26.0 installs.
if [[ -f "${CLAUDE_HOME}/output-styles/opencode-compact.md" ]]; then
  rm -f "${CLAUDE_HOME}/output-styles/opencode-compact.md"
fi
if [[ -f "${CLAUDE_HOME}/output-styles/oh-my-claude.md" || -f "${CLAUDE_HOME}/output-styles/executive-brief.md" ]]; then
  # Print the style that's actually active in settings.json — not the
  # bundled file's frontmatter — so the summary tells the truth under
  # output_style=preserve (where settings.json may carry a different
  # value or no value at all). Fallback chain: settings.outputStyle →
  # conf-resolved bundled file frontmatter → silent skip.
  _active_style=""
  if [[ -f "${CLAUDE_HOME}/settings.json" ]] && command -v jq >/dev/null 2>&1; then
    _active_style="$(jq -r '.outputStyle // empty' "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
  fi
  if [[ -z "${_active_style}" ]]; then
    case "${OMC_OUTPUT_STYLE_PREF:-opencode}" in
      executive) _fallback_style_file="${CLAUDE_HOME}/output-styles/executive-brief.md" ;;
      *)         _fallback_style_file="${CLAUDE_HOME}/output-styles/oh-my-claude.md" ;;
    esac
    if [[ -f "${_fallback_style_file}" ]]; then
      _active_style="$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${_fallback_style_file}" 2>/dev/null || true)"
      if [[ -n "${_active_style}" && "${OMC_OUTPUT_STYLE_PREF:-opencode}" == "preserve" ]]; then
        _active_style="${_active_style} (bundle file; settings.json untouched per output_style=preserve)"
      fi
    fi
  fi
  if [[ -n "${_active_style}" ]]; then
    printf '  Output style:  %s\n' "${_active_style}"
    # Onboarding nudge: when the active style is the default oh-my-claude,
    # mention the executive-brief alternative once. Skipped under preserve
    # (the user has already chosen) and on executive (already on the
    # alternative). Single line so it does not dominate the summary.
    case "${_active_style}" in
      "oh-my-claude")
        printf '                 Tip: try the executive-brief style for CEO-grade status reports — `/omc-config` → cluster 5, or set output_style=executive in oh-my-claude.conf and re-run install.\n'
        ;;
    esac
  fi
fi

# Orphan warning: surface files that were in a prior bundle but removed
# in this release. These linger in ~/.claude/ because rsync -a has no
# --delete flag (removing --delete would wipe user-created files too).
if [[ "${orphan_count}" -gt 0 ]]; then
  printf '\n'
  printf '  Orphans:       %d file(s) from a prior release remain in %s\n' "${orphan_count}" "${CLAUDE_HOME}"
  printf '                 (rsync preserves them; the new bundle no longer ships them):\n'
  printf '%s' "${orphan_list}"
  printf '                 Review and delete manually, or run:\n'
  printf '                   bash %s/uninstall.sh && bash %s/install.sh\n' "${SCRIPT_DIR}" "${SCRIPT_DIR}"
fi

printf '\n'
# v1.31.0 Wave 5 (visual-craft F-6 partial): TTY-guard the bold escape
# so log-redirected installs (`bash install.sh > install.log`) get
# plain text instead of literal `\033[1m...`. NO_COLOR env honored
# per the de-facto convention.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  printf '\033[1mRestart Claude Code now (or open a new session).\033[0m Required — hooks load at\n'
else
  printf 'Restart Claude Code now (or open a new session). Required — hooks load at\n'
fi
printf '  session start; already-running sessions keep the previous wiring, so /ulw will\n'
printf '  silently no-op until you restart.\n'
printf '\n'
printf 'Then:\n'
printf '  1. Verify the install:  bash %s/verify.sh\n' "${SCRIPT_DIR}"
printf '  2. Configure:           /omc-config  (multi-choice walkthrough — pick a profile\n'
printf '                          or fine-tune individual flags; auto-detects setup vs update)\n'
printf '  3. See gates fire:      /ulw-demo  (under 2 minutes — guided walkthrough)\n'
printf '  4. Real work:           /ulw fix the failing test and add regression coverage\n'
printf '\n'

if [[ "${BYPASS_PERMISSIONS}" != "true" ]]; then
  printf 'Once /ulw-demo confirms the harness is firing, re-run with --bypass-permissions\n'
  printf "to skip Claude Code's per-tool prompts. Quality gates apply either way.\n"
fi
