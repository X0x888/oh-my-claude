#!/usr/bin/env bash
# omc-config.sh — backend for the /omc-config skill.
#
# Inspects and mutates user/project oh-my-claude.conf via cleanly-named
# subcommands. The /omc-config skill markdown calls this script and the
# AskUserQuestion tool to produce a multi-choice setup/update/change UX.
#
# Atomic writes use tmp+mv. Reads tolerate missing files. Validation
# refuses unknown flags and out-of-range values BEFORE any write lands,
# so a malformed `set` invocation never half-writes the conf.
#
# Subcommands:
#   detect-mode                          Print setup|update|change|not-installed
#   show                                 Pretty-print current effective config
#   list-flags                           Emit known flags as JSON (for skill)
#   set <user|project> <k=v>...          Atomic write of one or more keys
#   apply-preset <user|project> <name>   Apply preset (maximum|balanced|minimal)
#   presets <name>                       Print preset key=value pairs to stdout
#   apply-tier <tier>                    Run switch-tier.sh (rewrites agent files)
#   install-watchdog                     Run install-resume-watchdog.sh
#   mark-completed [user|project]        Stamp omc_config_completed=<ISO date>
#
# Exit codes:
#   0 — success
#   1 — runtime failure (missing dependency, IO error)
#   2 — invalid invocation (unknown flag, bad enum value, bad scope)

set -euo pipefail

USER_CONF="${HOME}/.claude/oh-my-claude.conf"
SENTINEL_KEY="omc_config_completed"

get_project_conf() {
  printf '%s/.claude/oh-my-claude.conf' "$(pwd)"
}

# --- Static metadata about every flag this skill understands ---
#
# Format per line: name|type|default|category|description
#
# Types:
#   bool         — on|off
#   true_false   — true|false
#   int          — non-negative integer
#   enum:a/b/c   — must be one of the listed values
#   str          — free-form (validation skipped)
#
# Categories drive the grouping in `show` output and the skill's
# AskUserQuestion clusters. Order is display-order (most user-facing
# first; exotic tuning knobs last).
emit_known_flags() {
  cat <<'EOF'
gate_level|enum:basic/standard/full|full|gates|Quality-gate enforcement depth
guard_exhaustion_mode|enum:silent/scorecard/block|scorecard|gates|Behavior when gate-block cap is reached
verify_confidence_threshold|int|40|gates|Minimum verification confidence (0-100)
discovered_scope|bool|on|gates|Capture advisory findings + gate stop until addressed
pretool_intent_guard|true_false|true|gates|Block destructive git/gh under non-execution intent
stall_threshold|int|12|gates|Consecutive read/grep before stall fires
excellence_file_count|int|3|gates|Edited-file count that triggers excellence-reviewer
dimension_gate_file_count|int|3|gates|Edited-file count that triggers dimension gate
traceability_file_count|int|6|gates|Edited-file count that requires briefing-analyst
wave_override_ttl_seconds|int|1800|gates|Wave-plan freshness window for pretool guard
custom_verify_mcp_tools|str||gates|Pipe-separated MCP tool patterns that count as verification
metis_on_plan_gate|bool|off|advisory|Block stop on complex plan until metis stress-test
prometheus_suggest|bool|off|advisory|Declare-and-proceed scope interpretation on short product-shaped prompts
intent_verify_directive|bool|off|advisory|Declare-and-proceed goal interpretation on short unanchored prompts
exemplifying_directive|bool|on|advisory|Completeness/coverage directive — enumerate the search universe, verify each (v1.26.0 broadens to completeness verbs + advisory turns)
exemplifying_scope_gate|bool|on|gates|Require checklist for example-marker prompts before stop
prompt_text_override|bool|on|gates|PreTool guard trusts prompt-text imperative when classifier disagrees
mark_deferred_strict|bool|on|gates|Reject low-information defer reasons (out of scope / follow-up)
installation_drift_check|true_false|true|advisory|Statusline yellow arrow when bundle is behind source
auto_memory|bool|on|memory|Cross-session auto-memory writes (project/feedback/user/reference)
classifier_telemetry|bool|on|telemetry|Per-turn classifier telemetry to session state
model_tier|enum:quality/balanced/economy|balanced|cost|Agent model tier (quality=opus, economy=sonnet)
council_deep_default|bool|off|cost|Auto-triggered council uses opus per lens (--deep)
stop_failure_capture|bool|on|watchdog|Capture resume_request.json on rate-limit / fatal stop
resume_request_ttl_days|int|7|watchdog|Days a resume_request stays claimable
resume_watchdog|bool|off|watchdog|Headless daemon launches claude --resume after cap clears
resume_watchdog_cooldown_secs|int|600|watchdog|Per-artifact cooldown between watchdog launches
time_tracking|bool|on|telemetry|Per-tool / per-subagent timing capture; backs Stop epilogue + /ulw-time
time_tracking_xs_retain_days|pint|30|telemetry|Cross-session timing log retention (days)
state_ttl_days|int|7|cleanup|Days before stale session-state dirs are swept
output_style|enum:opencode/preserve|opencode|cost|Bundle the oh-my-claude style (opencode) or leave settings.json untouched (preserve)
model_drift_canary|bool|on|telemetry|Stop-hook canary detects silent confabulation (claims-vs-tool-calls audit; surfaces in /ulw-report)
blindspot_inventory|bool|on|gates|Project-surface scanner backing the intent-broadening directive (lazy-cached, 24h TTL)
intent_broadening|bool|on|advisory|Inject project-context reconciliation directive on complex execution prompts (defends against language-as-limitation failure)
blindspot_ttl_seconds|pint|86400|gates|Cache TTL (seconds) for blindspot inventory; default 86400 = 24h
EOF
}

# --- Preset definitions ---
#
# `maximum`: quality + max automation (this project's intended posture).
#   Internally consistent with `model_tier=quality` — every quality lever
#   is pulled, including `council_deep_default=on` so auto-triggered
#   council dispatches use opus per lens (matches the user's accepted
#   "Opus everywhere" stance under model_tier=quality).
# `balanced`: close to install-time defaults; safe for most users. Cost
#   caps live here, not in `maximum` — `council_deep_default=off` keeps
#   auto-council on sonnet for the typical user.
# `minimal`: lightest footprint while keeping core gates working.
#
# stop_failure_capture stays on across all presets — it is privacy-aware,
# tiny, and the only thing that makes /ulw-resume work after a Claude
# Code rate-limit kill. Users who actually need it off should set it
# explicitly, not adopt a preset.
emit_preset() {
  local profile="$1"
  case "${profile}" in
    maximum)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=block
auto_memory=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=on
prometheus_suggest=on
intent_verify_directive=on
exemplifying_directive=on
exemplifying_scope_gate=on
prompt_text_override=on
mark_deferred_strict=on
metis_on_plan_gate=on
stop_failure_capture=on
resume_watchdog=on
time_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
model_tier=quality
EOF
      ;;
    balanced)
      cat <<'EOF'
gate_level=full
guard_exhaustion_mode=scorecard
auto_memory=on
classifier_telemetry=on
discovered_scope=on
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=on
exemplifying_scope_gate=on
prompt_text_override=on
mark_deferred_strict=on
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=on
model_drift_canary=on
blindspot_inventory=on
intent_broadening=on
model_tier=balanced
EOF
      ;;
    minimal)
      cat <<'EOF'
gate_level=basic
guard_exhaustion_mode=silent
auto_memory=off
classifier_telemetry=off
discovered_scope=off
council_deep_default=off
prometheus_suggest=off
intent_verify_directive=off
exemplifying_directive=off
exemplifying_scope_gate=off
prompt_text_override=on
mark_deferred_strict=off
metis_on_plan_gate=off
stop_failure_capture=on
resume_watchdog=off
time_tracking=off
model_drift_canary=off
blindspot_inventory=off
intent_broadening=off
model_tier=economy
EOF
      ;;
    *)
      printf 'omc-config: unknown preset: %s (expected maximum|balanced|minimal)\n' "${profile}" >&2
      return 2
      ;;
  esac
}

# Read a single key from a conf file, tolerating absence.
# Last-occurrence wins (matches install.sh `set_conf` semantics).
read_conf_value() {
  local conf="$1" key="$2"
  [[ -f "${conf}" ]] || return 0
  grep -E "^${key}=" "${conf}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Find the nearest project-scope conf by walking up from PWD, capped at
# 10 levels — same logic as `load_conf` in common.sh. Skips $HOME so the
# user conf is not double-counted as project. Prints the path and exits 0
# if found; exits 1 if no project conf exists in the walked chain.
find_project_conf() {
  local dir="${PWD}" depth=0
  while [[ "${dir}" != "/" && "${depth}" -lt 10 ]]; do
    if [[ "${dir}" != "${HOME}" && -f "${dir}/.claude/oh-my-claude.conf" ]]; then
      printf '%s' "${dir}/.claude/oh-my-claude.conf"
      return 0
    fi
    dir="$(dirname "${dir}")"
    depth=$((depth + 1))
  done
  return 1
}

# Read a value with project-overrides-user precedence, matching the
# behavior of `load_conf` in common.sh. Used by `show` so the table
# reflects what the harness will actually see at runtime, not just what
# the user wrote at user scope.
read_effective_value() {
  local key="$1"
  local proj_conf proj_val user_val
  if proj_conf="$(find_project_conf)"; then
    proj_val="$(read_conf_value "${proj_conf}" "${key}")"
    if [[ -n "${proj_val}" ]]; then
      printf '%s' "${proj_val}"
      return 0
    fi
  fi
  user_val="$(read_conf_value "${USER_CONF}" "${key}")"
  printf '%s' "${user_val}"
}

# Resolve the bundle's VERSION via the conf's repo_path. Only accepts the
# semver shape `MAJOR.MINOR.PATCH` (with optional `-prerelease`); anything
# else returns `unknown` so detect-mode never compares garbage against
# `installed_version` and lands in the wrong branch on a malformed file.
resolve_bundle_version() {
  local repo_path raw
  repo_path="$(read_conf_value "${USER_CONF}" repo_path)"
  if [[ -n "${repo_path}" && -f "${repo_path}/VERSION" ]]; then
    raw="$(tr -d '[:space:]' < "${repo_path}/VERSION")"
    if [[ "${raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
      printf '%s' "${raw}"
      return 0
    fi
  fi
  printf 'unknown'
}

# Validate one key=value pair against the KNOWN_FLAGS table.
# Exits the script on failure (preserves atomic-write semantics —
# no partial conf writes when an apply-preset has one bad value).
validate_kv() {
  local kv="$1"
  if [[ "${kv}" != *"="* ]]; then
    printf 'omc-config: malformed pair (no =): %s\n' "${kv}" >&2
    return 2
  fi
  local key="${kv%%=*}"
  local value="${kv#*=}"

  local flag_type=""
  local found=false
  local name typ
  while IFS='|' read -r name typ _default _category _desc; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == "${key}" ]]; then
      flag_type="${typ}"
      found=true
      break
    fi
  done < <(emit_known_flags)

  if [[ "${found}" != "true" ]]; then
    printf 'omc-config: unknown flag: %s\n' "${key}" >&2
    return 2
  fi

  case "${flag_type}" in
    bool)
      if [[ ! "${value}" =~ ^(on|off)$ ]]; then
        printf 'omc-config: %s must be on|off (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    true_false)
      if [[ ! "${value}" =~ ^(true|false)$ ]]; then
        printf 'omc-config: %s must be true|false (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    int)
      if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        printf 'omc-config: %s must be a non-negative integer (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    pint)
      # Positive integer (>= 1). Use this for retention windows / TTLs
      # where 0 would silently be rejected by common.sh's parser regex
      # (^[1-9][0-9]*$) and the user would get the default instead — a
      # silent-fallback footgun the strict validator prevents.
      if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'omc-config: %s must be a positive integer (got: %s)\n' "${key}" "${value}" >&2
        return 2
      fi
      ;;
    enum:*)
      local raw="${flag_type#enum:}"
      local pattern="^(${raw//\//|})$"
      if [[ ! "${value}" =~ ${pattern} ]]; then
        printf 'omc-config: %s must be one of %s (got: %s)\n' "${key}" "${raw}" "${value}" >&2
        return 2
      fi
      ;;
    str)
      # Free-form values still must not contain control chars — a value
      # carrying a literal newline would smuggle a second `key=value` line
      # into the conf at write time, bypassing validation entirely. This
      # is the conf-equivalent of CRLF injection.
      if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
        printf 'omc-config: %s value cannot contain newlines or carriage returns\n' "${key}" >&2
        return 2
      fi
      ;;
  esac
  return 0
}

# Atomic multi-key conf write. Strips any prior occurrence of each key
# (last-write-wins semantics matching install.sh) and appends the new
# values in a single tmp file, then rename-replaces the conf.
#
# Within-batch dedup: when the same key appears multiple times in the
# argument list (e.g. `set user gate_level=full gate_level=basic`), only
# the LAST occurrence is appended. Without this, repeated invocations
# would accumulate dead lines in the conf even though the parser's
# `tail -1` resolution masks the user impact.
#
# tmp filename uses both `$$` and `$RANDOM` so two concurrent invocations
# from background-spawned shells with identical PIDs (rare but possible)
# do not race for the same scratch file. Last-mv-wins is still the outer
# concurrency model — the helper assumes single-writer and the skill is
# interactive, so writers do not contend in practice.
write_conf_atomic() {
  local conf="$1"
  shift
  mkdir -p "$(dirname "${conf}")"
  local tmp
  tmp="${conf}.tmp.$$.${RANDOM}"

  # Walk args, keeping the LAST kv per key. Bash 3-compat (no associative
  # arrays — macOS ships /bin/bash 3.2). Order of preserved keys follows
  # last-occurrence insertion order so the conf stays reasonable to read.
  local -a deduped_keys=()
  local -a deduped_values=()
  local kv key value i found
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    found=-1
    for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
      if [[ "${deduped_keys[$i]}" == "${key}" ]]; then
        found=$i
        break
      fi
    done
    if [[ $found -ge 0 ]]; then
      deduped_values[$found]="${value}"
    else
      deduped_keys+=( "${key}" )
      deduped_values+=( "${value}" )
    fi
  done

  local strip_pattern=""
  local k
  for k in "${deduped_keys[@]}"; do
    if [[ -z "${strip_pattern}" ]]; then
      strip_pattern="^${k}="
    else
      strip_pattern="${strip_pattern}|^${k}="
    fi
  done

  if [[ -f "${conf}" ]]; then
    grep -vE "${strip_pattern}" "${conf}" > "${tmp}" 2>/dev/null || true
  else
    : > "${tmp}"
  fi

  for ((i = 0; i < ${#deduped_keys[@]}; i++)); do
    printf '%s=%s\n' "${deduped_keys[$i]}" "${deduped_values[$i]}" >> "${tmp}"
  done

  mv "${tmp}" "${conf}"
}

# Resolve scope label to a conf path. Refuses unknown scopes.
resolve_scope_conf() {
  local scope="$1"
  case "${scope}" in
    user)    printf '%s' "${USER_CONF}" ;;
    project) get_project_conf ;;
    *)
      printf 'omc-config: unknown scope: %s (expected user|project)\n' "${scope}" >&2
      return 2 ;;
  esac
}

# --- Subcommands ---

cmd_detect_mode() {
  if [[ ! -f "${USER_CONF}" ]]; then
    printf 'not-installed\n'
    return 0
  fi
  local installed_v
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  if [[ -z "${installed_v}" ]]; then
    printf 'not-installed\n'
    return 0
  fi

  local completed
  completed="$(read_conf_value "${USER_CONF}" "${SENTINEL_KEY}")"
  if [[ -z "${completed}" ]]; then
    printf 'setup\n'
    return 0
  fi

  local bundle_v
  bundle_v="$(resolve_bundle_version)"
  if [[ -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    local first
    first="$(printf '%s\n%s\n' "${installed_v}" "${bundle_v}" | sort -V | head -1)"
    if [[ "${first}" == "${installed_v}" ]]; then
      printf 'update\n'
      return 0
    fi
  fi
  printf 'change\n'
}

cmd_show() {
  local installed_v bundle_v conf_marker="" proj_conf=""
  installed_v="$(read_conf_value "${USER_CONF}" installed_version)"
  bundle_v="$(resolve_bundle_version)"
  [[ -f "${USER_CONF}" ]] || conf_marker=" (missing)"
  proj_conf="$(find_project_conf || true)"

  printf 'oh-my-claude config\n'
  printf '  user conf:    %s%s\n' "${USER_CONF}" "${conf_marker}"
  if [[ -n "${proj_conf}" ]]; then
    printf '  project conf: %s (overrides user)\n' "${proj_conf}"
  fi
  printf '  installed:    %s\n' "${installed_v:-unknown}"
  printf '  bundle:       %s\n' "${bundle_v:-unknown}"
  if [[ -n "${installed_v}" && -n "${bundle_v}" && "${bundle_v}" != "unknown" && "${bundle_v}" != "${installed_v}" ]]; then
    printf '  ! bundle differs from installed — run install.sh in the source repo to sync.\n'
  fi
  printf '\n'
  printf '  %-32s %-10s %-10s  %s\n' "FLAG" "VALUE" "DEFAULT" "DESCRIPTION"
  printf '  %-32s %-10s %-10s  %s\n' "----" "-----" "-------" "-----------"

  local prev_category=""
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    # Effective value uses project>user>default precedence (matches
    # load_conf in common.sh). Without this, project-scope users would
    # see the wrong "current value" — the user-conf value masking the
    # project override they actually wrote.
    local val
    val="$(read_effective_value "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    if [[ "${category}" != "${prev_category}" ]]; then
      printf '  -- %s --\n' "${category}"
      prev_category="${category}"
    fi
    # Build the source annotation (P=project, U=user, D=default) so the
    # user can see *where* the effective value comes from when both
    # confs have entries.
    local marker="  " source_tag=""
    if [[ -n "${proj_conf}" ]] && [[ -n "$(read_conf_value "${proj_conf}" "${name}")" ]]; then
      source_tag=" [P]"
    elif [[ -n "$(read_conf_value "${USER_CONF}" "${name}")" ]]; then
      source_tag=" [U]"
    fi
    if [[ -n "${val}" && "${val}" != "${default}" ]]; then
      marker="* "
    fi
    printf '  %s%-30s %-10s %-10s  %s%s\n' "${marker}" "${name}" "${val:-(unset)}" "${default:-(none)}" "${desc}" "${source_tag}"
  done < <(emit_known_flags)

  printf '\n  Marked * = differs from default.'
  if [[ -n "${proj_conf}" ]]; then
    printf '   [P]=project override, [U]=user setting'
  fi
  printf '\n'
}

cmd_list_flags_json() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'omc-config: jq is required for list-flags --json\n' >&2
    return 1
  fi
  local out='[]'
  local name flag_type default category desc
  while IFS='|' read -r name flag_type default category desc; do
    [[ -z "${name}" ]] && continue
    local val
    val="$(read_conf_value "${USER_CONF}" "${name}")"
    [[ -z "${val}" ]] && val="${default}"
    out="$(printf '%s' "${out}" | jq \
      --arg name "${name}" \
      --arg type "${flag_type}" \
      --arg default "${default}" \
      --arg category "${category}" \
      --arg desc "${desc}" \
      --arg current "${val}" \
      '. += [{name: $name, type: $type, default: $default, category: $category, description: $desc, current: $current}]')"
  done < <(emit_known_flags)
  printf '%s\n' "${out}"
}

cmd_set() {
  if [[ $# -lt 2 ]]; then
    printf 'omc-config: set requires <scope> and at least one key=value pair\n' >&2
    printf 'usage: omc-config.sh set <user|project> <k=v> [<k=v>...]\n' >&2
    return 2
  fi
  local scope="$1"
  shift
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  # Validate all pairs first; commit only when every value is sound.
  local kv
  for kv in "$@"; do
    validate_kv "${kv}"
  done

  # Mirror `apply-preset`'s defense-in-depth: if this batch sets a new
  # `model_tier`, capture the prior value before the write so we can
  # auto-invoke `apply-tier` after. Without this, a fine-tune flow that
  # writes `model_tier=quality` via `set` (rather than via a preset)
  # would leave the conf claiming quality while agent files still say
  # sonnet — silent quality regression. The SKILL flow's "explicitly
  # call apply-tier" instruction relies on the model remembering across
  # turns; this backstops that.
  local prior_tier="" new_tier=""
  for kv in "$@"; do
    if [[ "${kv%%=*}" == "model_tier" ]]; then
      new_tier="${kv#*=}"
      break
    fi
  done
  if [[ -n "${new_tier}" ]]; then
    prior_tier="$(read_conf_value "${conf}" model_tier)"
  fi

  write_conf_atomic "${conf}" "$@"
  printf 'omc-config: wrote %d key(s) to %s\n' "$#" "${conf}"

  if [[ -n "${new_tier}" && "${new_tier}" != "${prior_tier}" ]]; then
    printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
      "${prior_tier:-unset}" "${new_tier}"
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      cmd_apply_tier "${new_tier}" || \
        printf 'omc-config: WARNING: apply-tier failed; agent files may be out of sync with conf\n' >&2
    else
      printf 'omc-config: WARNING: switch-tier.sh not installed; run `bash %s/.claude/switch-tier.sh %s` manually\n' \
        "${HOME}" "${new_tier}" >&2
    fi
  fi
}

cmd_apply_preset() {
  if [[ $# -ne 2 ]]; then
    printf 'omc-config: apply-preset requires <scope> <profile>\n' >&2
    printf 'usage: omc-config.sh apply-preset <user|project> <maximum|balanced|minimal>\n' >&2
    return 2
  fi
  local scope="$1" profile="$2"
  local conf
  conf="$(resolve_scope_conf "${scope}")"

  local pairs=()
  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    pairs+=( "${line}" )
  done < <(emit_preset "${profile}")

  if [[ ${#pairs[@]} -eq 0 ]]; then
    printf 'omc-config: preset %s produced no entries\n' "${profile}" >&2
    return 2
  fi

  local kv
  for kv in "${pairs[@]}"; do
    validate_kv "${kv}"
  done

  # Capture the prior model_tier (from the same scope's conf) BEFORE the
  # write so we can detect whether the preset is changing the tier. If it
  # is, the helper invokes `apply-tier` itself — defense-in-depth for the
  # case where the SKILL flow's "Step 5a — invoke apply-tier when tier
  # changed" instruction is skipped. Without this, the conf could claim
  # `model_tier=quality` while every agent file still says `sonnet`.
  local prior_tier new_tier
  prior_tier="$(read_conf_value "${conf}" model_tier)"
  new_tier=""
  for kv in "${pairs[@]}"; do
    if [[ "${kv%%=*}" == "model_tier" ]]; then
      new_tier="${kv#*=}"
      break
    fi
  done

  write_conf_atomic "${conf}" "${pairs[@]}"
  printf 'omc-config: applied preset "%s" (%d keys) to %s\n' "${profile}" "${#pairs[@]}" "${conf}"

  # Auto-fire the agent-file rewrite when the tier changed. Skip when
  # unchanged or when the switcher is missing (apply-tier surfaces its
  # own error in that case). Best-effort — preset write already
  # succeeded; a switcher failure here should warn but not unwind.
  if [[ -n "${new_tier}" && "${new_tier}" != "${prior_tier}" ]]; then
    printf 'omc-config: model_tier changed (%s -> %s); rewriting agents...\n' \
      "${prior_tier:-unset}" "${new_tier}"
    if [[ -x "${HOME}/.claude/switch-tier.sh" ]]; then
      cmd_apply_tier "${new_tier}" || \
        printf 'omc-config: WARNING: apply-tier failed; agent files may be out of sync with conf\n' >&2
    else
      printf 'omc-config: WARNING: switch-tier.sh not installed; run `bash %s/.claude/switch-tier.sh %s` manually\n' \
        "${HOME}" "${new_tier}" >&2
    fi
  fi
}

cmd_mark_completed() {
  # Sentinel is "this user has been through the wizard once" — a
  # per-machine flag, not per-project. `detect-mode` only reads
  # USER_CONF for this key, so writing it to the project conf would
  # leave the user stuck in `setup` mode forever. Ignore any scope
  # argument and always stamp USER_CONF; the scope arg is preserved
  # for backward-compat with callers that pass it (the SKILL flow did
  # before the fix landed) but the scope no longer changes the path.
  local _scope_ignored="${1:-user}"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_conf_atomic "${USER_CONF}" "${SENTINEL_KEY}=${stamp}"
  printf 'omc-config: stamped %s=%s in %s (always user scope)\n' \
    "${SENTINEL_KEY}" "${stamp}" "${USER_CONF}"
}

cmd_apply_tier() {
  local tier="${1:-}"
  if [[ -z "${tier}" ]]; then
    printf 'omc-config: apply-tier requires <quality|balanced|economy>\n' >&2
    return 2
  fi
  if [[ ! "${tier}" =~ ^(quality|balanced|economy)$ ]]; then
    printf 'omc-config: tier must be quality|balanced|economy (got: %s)\n' "${tier}" >&2
    return 2
  fi
  local switcher="${HOME}/.claude/switch-tier.sh"
  if [[ ! -x "${switcher}" ]]; then
    printf 'omc-config: switch-tier.sh not found at %s\n' "${switcher}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  bash "${switcher}" "${tier}"
}

cmd_install_watchdog() {
  local installer="${HOME}/.claude/install-resume-watchdog.sh"
  if [[ ! -x "${installer}" ]]; then
    printf 'omc-config: watchdog installer not found at %s\n' "${installer}" >&2
    printf '            Re-run install.sh to refresh the bundle, then retry.\n' >&2
    return 1
  fi
  bash "${installer}"
}

usage() {
  cat <<'EOF'
omc-config.sh — backend for /omc-config skill.

Subcommands:
  detect-mode                          Print setup|update|change|not-installed
  show                                 Pretty-print current effective config
  list-flags                           Emit known flags as JSON (for skill)
  set <user|project> <k=v>...          Atomic write of one or more keys
  apply-preset <user|project> <name>   Apply preset (maximum|balanced|minimal)
  presets <name>                       Print preset key=value pairs to stdout
  apply-tier <quality|balanced|economy>  Run switch-tier.sh (rewrites agent files)
  install-watchdog                     Run install-resume-watchdog.sh
  mark-completed [user|project]        Stamp omc_config_completed=<ISO date>

Conventions:
  user scope    -> ~/.claude/oh-my-claude.conf
  project scope -> $(pwd)/.claude/oh-my-claude.conf

Exit codes:
  0 success | 1 runtime failure | 2 invalid invocation
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    detect-mode)      cmd_detect_mode ;;
    show)             cmd_show ;;
    list-flags)       cmd_list_flags_json ;;
    set)              cmd_set "$@" ;;
    apply-preset)     cmd_apply_preset "$@" ;;
    presets)          emit_preset "${1:-}" ;;
    apply-tier)       cmd_apply_tier "${1:-}" ;;
    install-watchdog) cmd_install_watchdog ;;
    mark-completed)   cmd_mark_completed "$@" ;;
    ""|-h|--help)     usage ;;
    *)
      printf 'omc-config: unknown subcommand: %s\n' "${cmd}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
