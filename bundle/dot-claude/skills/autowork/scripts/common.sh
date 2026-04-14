#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
STATE_JSON="session_state.json"
HOOK_LOG="${STATE_ROOT}/hooks.log"

# --- Configurable thresholds (tunable via oh-my-claude.conf) ---
# Precedence: env var > conf file > built-in default.
# Track which vars were set via env before applying defaults.
_omc_env_stall="${OMC_STALL_THRESHOLD:-}"
_omc_env_excellence="${OMC_EXCELLENCE_FILE_COUNT:-}"
_omc_env_ttl="${OMC_STATE_TTL_DAYS:-}"
_omc_env_dimgate="${OMC_DIMENSION_GATE_FILE_COUNT:-}"
_omc_env_traceability="${OMC_TRACEABILITY_FILE_COUNT:-}"

OMC_STALL_THRESHOLD="${OMC_STALL_THRESHOLD:-12}"
OMC_EXCELLENCE_FILE_COUNT="${OMC_EXCELLENCE_FILE_COUNT:-3}"
OMC_STATE_TTL_DAYS="${OMC_STATE_TTL_DAYS:-7}"
OMC_DIMENSION_GATE_FILE_COUNT="${OMC_DIMENSION_GATE_FILE_COUNT:-3}"
OMC_TRACEABILITY_FILE_COUNT="${OMC_TRACEABILITY_FILE_COUNT:-6}"

_omc_conf_loaded=0

load_conf() {
  if [[ "${_omc_conf_loaded}" -eq 1 ]]; then return; fi
  _omc_conf_loaded=1

  local conf="${HOME}/.claude/oh-my-claude.conf"
  [[ -f "${conf}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line}" ]] && continue
    [[ "${line}" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    # Only override if: value is a positive integer (>0) AND no env override was set.
    case "${key}" in
      stall_threshold)
        [[ -z "${_omc_env_stall}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_STALL_THRESHOLD="${value}" || true ;;
      excellence_file_count)
        [[ -z "${_omc_env_excellence}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_EXCELLENCE_FILE_COUNT="${value}" || true ;;
      state_ttl_days)
        [[ -z "${_omc_env_ttl}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_STATE_TTL_DAYS="${value}" || true ;;
      dimension_gate_file_count)
        [[ -z "${_omc_env_dimgate}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_DIMENSION_GATE_FILE_COUNT="${value}" || true ;;
      traceability_file_count)
        [[ -z "${_omc_env_traceability}" && "${value}" =~ ^[1-9][0-9]*$ ]] && OMC_TRACEABILITY_FILE_COUNT="${value}" || true ;;
    esac
  done < "${conf}"
}

# Load conf at source time so all scripts get configured values.
load_conf

# Optional hook execution logging. Enable via oh-my-claude.conf: hook_debug=true
_hook_debug_enabled=""
_hook_debug_checked=0

is_hook_debug() {
  if [[ "${_hook_debug_checked}" -eq 0 ]]; then
    _hook_debug_checked=1
    local conf="${HOME}/.claude/oh-my-claude.conf"
    if [[ "${HOOK_DEBUG:-}" == "1" ]]; then
      _hook_debug_enabled=1
    elif [[ -f "${conf}" ]]; then
      _hook_debug_enabled="$(grep -E '^hook_debug=true$' "${conf}" >/dev/null 2>&1 && echo 1 || echo "")"
    fi
  fi
  [[ -n "${_hook_debug_enabled}" ]]
}

log_hook() {
  if is_hook_debug; then
    local hook_name="${1:-unknown}"
    local detail="${2:-}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "${STATE_ROOT}"
    printf '%s  %s  %s\n' "${ts}" "${hook_name}" "${detail}" >>"${HOOK_LOG}"

    # Rotate hooks.log to prevent unbounded growth when debug mode is
    # left on. Truncate to 1500 lines when exceeding 2000.
    local _line_count
    _line_count="$(wc -l < "${HOOK_LOG}" 2>/dev/null || echo 0)"
    _line_count="${_line_count##* }"
    if [[ "${_line_count}" -gt 2000 ]]; then
      local _temp
      _temp="$(mktemp "${HOOK_LOG}.XXXXXX")"
      tail -n 1500 "${HOOK_LOG}" >"${_temp}" 2>/dev/null && mv "${_temp}" "${HOOK_LOG}" || rm -f "${_temp}"
    fi
  fi
}

json_get() {
  local query="$1"
  jq -r "${query} // empty" <<<"${HOOK_JSON}"
}

# --- Session ID validation ---
# SESSION_ID comes from Claude Code's hook JSON. Validate it as a safe
# filesystem identifier (alphanumeric, hyphens, underscores, dots, 1-128
# chars) to prevent path traversal via session_file(). Rejects slashes,
# null bytes, and the ".." sequence. Claude Code uses UUIDs, but we
# accept shorter IDs for test compatibility.
validate_session_id() {
  local id="$1"
  [[ "${id}" =~ ^[a-zA-Z0-9_.-]{1,128}$ ]] && [[ "${id}" != *".."* ]]
}

ensure_session_dir() {
  if ! validate_session_id "${SESSION_ID}"; then
    log_hook "common" "invalid session_id format, skipping: ${SESSION_ID:0:40}"
    exit 0
  fi
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
}

session_file() {
  printf '%s/%s/%s\n' "${STATE_ROOT}" "${SESSION_ID}" "$1"
}

# --- P2: JSON-backed state ---

# Validate and recover state file. If the state file exists but is not
# valid JSON, archive the corrupt file and reset to empty object. This
# prevents the cascade where corrupt state → all read_state returns
# empty → stop-guard silently bypasses all quality gates.
#
# Cached per-process: the validation runs once per hook invocation (each
# hook is a fresh bash process). Subsequent write_state/write_state_batch
# calls in the same process skip the jq validation — they trust their own
# writes from this process, which went through jq already.
_state_validated=0

_ensure_valid_state() {
  if [[ "${_state_validated}" -eq 1 ]]; then
    return
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"

  if [[ ! -f "${state_file}" ]]; then
    printf '{}\n' >"${state_file}"
    _state_validated=1
    return
  fi

  if ! jq empty "${state_file}" 2>/dev/null; then
    local archive
    archive="$(session_file "${STATE_JSON}.corrupt.$(date +%s)")"
    mv "${state_file}" "${archive}" 2>/dev/null || true
    printf '{}\n' >"${state_file}"
    log_hook "common" "corrupt state detected and archived: ${archive}"
  fi

  _state_validated=1
}

write_state() {
  local key="$1"
  local value="$2"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  _ensure_valid_state

  jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" >"${temp_file}" \
    && mv "${temp_file}" "${state_file}" \
    || rm -f "${temp_file}"
}

write_state_batch() {
  if [[ $(( $# % 2 )) -ne 0 ]]; then
    printf 'write_state_batch: odd number of arguments (%d)\n' "$#" >&2
    return 1
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  _ensure_valid_state

  local jq_filter="."
  local args=()
  local idx=0

  while [[ $# -ge 2 ]]; do
    args+=(--arg "k${idx}" "$1" --arg "v${idx}" "$2")
    jq_filter="${jq_filter} | .[(\$k${idx})] = \$v${idx}"
    shift 2
    idx=$((idx + 1))
  done

  jq "${args[@]}" "${jq_filter}" "${state_file}" >"${temp_file}" \
    && mv "${temp_file}" "${state_file}" \
    || rm -f "${temp_file}"
}

append_state() {
  local key="$1"
  local value="$2"
  printf '%s\n' "${value}" >>"$(session_file "${key}")"
}

append_limited_state() {
  local key="$1"
  local value="$2"
  local max_lines="${3:-20}"
  local target
  local temp

  target="$(session_file "${key}")"
  temp="$(mktemp "${target}.XXXXXX")"

  printf '%s\n' "${value}" >>"${target}"
  tail -n "${max_lines}" "${target}" >"${temp}" 2>/dev/null || cp "${target}" "${temp}"
  mv "${temp}" "${target}"
}

read_state() {
  local key="$1"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local result=""

  if [[ -f "${state_file}" ]]; then
    result="$(jq -r --arg k "${key}" '.[$k] // empty' "${state_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${result}" ]]; then
    printf '%s' "${result}"
    return
  fi

  # Fallback: individual file (backwards compat or JSON key missing)
  cat "$(session_file "${key}")" 2>/dev/null || true
}

# --- end P2 ---

# --- Portable state lock (mkdir primitive, BSD/GNU stat compat) ---
#
# Wraps a function call with a mutex held against the session's state
# directory. Uses mkdir as the atomic lock primitive (portable across
# macOS and Linux — flock is non-standard on BSD). A stale-lock timeout
# prevents a crashed hook from holding the lock forever: if the lockdir
# is older than OMC_STATE_LOCK_STALE_SECS (default 5), force-release it.
#
# Usage: with_state_lock my_function arg1 arg2 ...
#
# Returns the wrapped function's exit status, or 1 if the lock cannot
# be acquired within OMC_STATE_LOCK_MAX_ATTEMPTS polls (default 200).

OMC_STATE_LOCK_STALE_SECS="${OMC_STATE_LOCK_STALE_SECS:-5}"
OMC_STATE_LOCK_MAX_ATTEMPTS="${OMC_STATE_LOCK_MAX_ATTEMPTS:-200}"

_lock_mtime() {
  # Echoes mtime epoch of $1, or 0 on error. Tries BSD stat -f, then GNU stat -c.
  local target="$1"
  local ts
  ts="$(stat -f %m "${target}" 2>/dev/null)" || ts=""
  if [[ -z "${ts}" ]]; then
    ts="$(stat -c %Y "${target}" 2>/dev/null)" || ts="0"
  fi
  printf '%s' "${ts:-0}"
}

with_state_lock() {
  local lockdir
  lockdir="$(session_file ".state.lock")"
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))

    # Stale-lock recovery: if the dir has been held too long, force-release.
    if [[ -d "${lockdir}" ]]; then
      local now
      now="$(date +%s)"
      local held_since
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
    fi

    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null || true
  return "${rc}"
}

# --- end state lock ---

now_epoch() {
  date +%s
}

# --- State directory TTL sweep ---
# Deletes session state dirs older than OMC_STATE_TTL_DAYS (default 7).
# Runs at most once per day, gated by a marker file timestamp.

sweep_stale_sessions() {
  local marker="${STATE_ROOT}/.last_sweep"
  local now
  now="$(date +%s)"

  # Skip if swept within the last 24 hours
  if [[ -f "${marker}" ]]; then
    local last_sweep
    last_sweep="$(cat "${marker}" 2>/dev/null || echo 0)"
    if [[ $(( now - last_sweep )) -lt 86400 ]]; then
      return
    fi
  fi

  # Sweep directories older than configured TTL (exclude dotfiles like .ulw_active, .last_sweep)
  if [[ -d "${STATE_ROOT}" ]]; then
    find "${STATE_ROOT}" -maxdepth 1 -type d -mtime +"${OMC_STATE_TTL_DAYS}" \
      ! -name '.' ! -name '..' ! -name '.*' ! -path "${STATE_ROOT}" \
      -exec rm -rf {} + 2>/dev/null || true
  fi

  printf '%s\n' "${now}" > "${marker}"
}

# --- end TTL sweep ---

is_maintenance_prompt() {
  local text="$1"
  [[ "${text}" =~ ^[[:space:]]*/(compact|clear|resume|memory|hooks|config|help|permissions|model|doctor|status)([[:space:]]|$) ]]
}

truncate_chars() {
  local limit="$1"
  local text="$2"

  if [[ "${#text}" -le "${limit}" ]]; then
    printf '%s' "${text}"
    return
  fi

  printf '%s...' "${text:0:limit}"
}

trim_whitespace() {
  local text="$1"

  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"

  printf '%s' "${text}"
}

normalize_task_prompt() {
  local text="$1"
  local changed=1
  local nocasematch_was_set=0

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  while [[ "${changed}" -eq 1 ]]; do
    changed=0

    if [[ "${text}" =~ ^[[:space:]]*/?(ulw|autowork|ultrawork|sisyphus)[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[2]}"
      changed=1
      continue
    fi

    if [[ "${text}" =~ ^[[:space:]]*ultrathink[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      changed=1
    fi
  done

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  printf '%s' "${text}"
}

# Extract the user's task body from a /ulw or /autowork skill-body expansion.
# When the CLI expands a slash command like `/ulw <task>`, the hook sees the full
# skill body starting with "Base directory for this skill: ..." followed by
# "Primary task:" and the user's actual task, then a trailing "Follow the
# `/autowork` operating rules" instruction. Classifying the full expansion
# misfires because embedded quoted content in the task body can trip SM/advisory
# regexes. This helper returns just the user's task body (between the two
# markers), or exit 1 if the primary-task marker isn't present.
#
# The "Primary task:" marker must be line-anchored (preceded by a newline or at
# the very start of the text). Real skill bodies always put the marker on its
# own line; a mid-sentence mention like "the docs say Primary task: should..."
# would otherwise false-positive and extract the wrong slice of the prompt.
extract_skill_primary_task() {
  local text="$1"
  local head_marker='Primary task:'
  local tail_marker='Follow the `/autowork`'

  # Line-anchored marker check: either at the start of text, or after a newline.
  if [[ "${text}" != "${head_marker}"* ]] && [[ "${text}" != *$'\n'"${head_marker}"* ]]; then
    return 1
  fi

  local after="${text#*"${head_marker}"}"
  local body="${after%%"${tail_marker}"*}"

  body="$(trim_whitespace "${body}")"
  [[ -n "${body}" ]] || return 1

  printf '%s' "${body}"
}

is_continuation_request() {
  local text="$1"
  local normalized
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1
  if [[ "${normalized}" =~ ^[[:space:]]*((continue|resume)([[:space:]]+(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off))?|carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))([[:space:][:punct:]].*)?$ ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

extract_continuation_directive() {
  local text="$1"
  local normalized
  local remainder=""
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  if [[ "${normalized}" =~ ^(continue|resume)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[2]}"
    if [[ "${remainder}" =~ ^(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
      remainder="${BASH_REMATCH[2]}"
    fi
  elif [[ "${normalized}" =~ ^(carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[3]}"
  elif [[ "${normalized}" =~ ^(next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[4]}"
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  remainder="$(trim_whitespace "${remainder}")"
  remainder="${remainder#[,:;.-]}"
  remainder="$(trim_whitespace "${remainder}")"

  printf '%s' "${remainder}"
}

workflow_mode() {
  read_state "workflow_mode"
}

is_ultrawork_mode() {
  [[ "$(workflow_mode)" == "ultrawork" ]]
}

task_domain() {
  read_state "task_domain"
}

is_internal_claude_path() {
  local path="$1"

  [[ -z "${path}" ]] && return 1

  case "${path}" in
    "${HOME}/.claude/projects/"*|\
    "${HOME}/.claude/quality-pack/state/"*|\
    "${HOME}/.claude/tasks/"*|\
    "${HOME}/.claude/todos/"*|\
    "${HOME}/.claude/transcripts/"*|\
    "${HOME}/.claude/debug/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Doc vs code edit classification ---
#
# is_doc_path returns 0 if the given path is a documentation artifact
# (markdown, CHANGELOG, README, anything under a docs/ path component).
# The dimension gate routes doc-only edits to editor-critic rather than
# quality-reviewer, preventing CHANGELOG tweaks from re-opening the
# full code-review loop.
#
# Rules:
#   - Extensions match case-insensitively: md, mdx, txt, rst, adoc, markdown
#   - Basename patterns match well-known doc files (lowercased):
#     changelog*, release*, readme*, authors*, contributing*,
#     license*, notice*, copying*
#   - Path component docs/ or doc/ (not substring: src/docs-examples/foo.ts
#     is NOT a doc; /project/docs/foo.ts IS)

is_doc_path() {
  local path="$1"
  [[ -z "${path}" ]] && return 1

  # Lowercase basename for case-insensitive matching
  local base="${path##*/}"
  local base_lc
  base_lc="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"

  case "${base_lc}" in
    *.md|*.mdx|*.txt|*.rst|*.adoc|*.markdown) return 0 ;;
    changelog*|release*|readme*|authors*|contributing*|license*|notice*|copying*) return 0 ;;
  esac

  # Path-component docs/ or doc/ — require slash boundary, not substring
  case "/${path}/" in
    */docs/*|*/doc/*) return 0 ;;
  esac

  return 1
}

# is_ui_path — returns 0 for files that produce visible UI output.
#   - Component files: tsx, jsx, vue, svelte, astro
#   - Stylesheets: css, scss, sass, less, styl
#   - Markup: html, htm
# UI paths are a subset of code paths (not docs). A file can be both
# "code" (for code_edit_count) and "ui" (for ui_edit_count).

is_ui_path() {
  local path="$1"
  [[ -z "${path}" ]] && return 1

  local base="${path##*/}"
  local base_lc
  base_lc="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"

  case "${base_lc}" in
    *.tsx|*.jsx|*.vue|*.svelte|*.astro) return 0 ;;
    *.css|*.scss|*.sass|*.less|*.styl) return 0 ;;
    *.html|*.htm) return 0 ;;
  esac

  return 1
}

# --- Dimension tracking helpers ---
#
# Dimensions are stored as individual state keys of the form
# `dim_<name>_ts` holding the epoch at which the reviewer ticked them.
# Validity is determined by comparing that epoch to the relevant edit
# clock (last_code_edit_ts for code dims, last_doc_edit_ts for prose).
# This gives implicit invalidation — no mark-edit clearing needed.
#
# The canonical dimension set:
#   bug_hunt       — quality-reviewer (code correctness, regressions, edge cases)
#   code_quality   — quality-reviewer (conventions, dead code, comments)
#   stress_test    — metis (hidden assumptions, unsafe paths)
#   prose          — editor-critic (doc clarity, accuracy, tone)
#   completeness   — excellence-reviewer (fresh-eyes holistic review)
#   traceability   — briefing-analyst (deferrals, decisions, synthesis)
#   design_quality — design-reviewer (visual craft, distinctiveness, anti-generic)

_dim_key() {
  printf 'dim_%s_ts' "$1"
}

tick_dimension() {
  # Records a dimension tick under the state lock to prevent lost updates
  # when multiple reviewer SubagentStop hooks fire concurrently.
  local dim="$1"
  local ts="${2:-$(now_epoch)}"
  local key
  key="$(_dim_key "${dim}")"
  with_state_lock write_state "${key}" "${ts}"
}

is_dimension_valid() {
  # Returns 0 if the dimension was ticked at or after the most recent
  # edit of the relevant type. For 'prose', compare to last_doc_edit_ts;
  # all other dimensions compare to last_code_edit_ts (then last_edit_ts
  # as a legacy fallback for resumed sessions).
  #
  # Uses >= (not >) so same-second tick-after-edit sequences count as
  # valid. The production semantics are: "reviewer that ran at time T
  # saw the edit at time T", which is the natural interpretation. In
  # tests, this lets single-second sequences work without sleep calls.
  # Post-tick edits in strict ordering (edit clearly after tick) still
  # invalidate because the edit clock advances at least one second.
  local dim="$1"
  local tick_ts
  tick_ts="$(read_state "$(_dim_key "${dim}")")"
  [[ -z "${tick_ts}" ]] && return 1

  local relevant_edit_ts
  if [[ "${dim}" == "prose" ]]; then
    relevant_edit_ts="$(read_state "last_doc_edit_ts")"
  else
    relevant_edit_ts="$(read_state "last_code_edit_ts")"
    [[ -z "${relevant_edit_ts}" ]] && relevant_edit_ts="$(read_state "last_edit_ts")"
  fi

  # No relevant edit recorded: tick is valid by default.
  [[ -z "${relevant_edit_ts}" ]] && return 0

  [[ "${tick_ts}" -ge "${relevant_edit_ts}" ]]
}

reviewer_for_dimension() {
  case "$1" in
    bug_hunt|code_quality) printf 'quality-reviewer' ;;
    stress_test)           printf 'metis' ;;
    prose)                 printf 'editor-critic' ;;
    completeness)          printf 'excellence-reviewer' ;;
    traceability)          printf 'briefing-analyst' ;;
    design_quality)        printf 'design-reviewer' ;;
    *)                     printf 'quality-reviewer' ;;
  esac
}

describe_dimension() {
  case "$1" in
    bug_hunt)        printf 'bug hunt (correctness, regressions, edge cases)' ;;
    code_quality)    printf 'code quality (conventions, dead code, comments)' ;;
    stress_test)     printf 'stress-test (hidden assumptions, unsafe paths)' ;;
    prose)           printf 'prose review (doc clarity, accuracy, tone)' ;;
    completeness)    printf 'completeness (fresh-eyes holistic review)' ;;
    traceability)    printf 'traceability (deferrals, decisions, synthesis)' ;;
    design_quality)  printf 'design quality (visual craft, distinctiveness, anti-generic)' ;;
    *)               printf '%s' "$1" ;;
  esac
}

# Computes the set of required dimensions for the current session based
# on the edit counters (maintained by mark-edit.sh at write time — no
# O(N) re-classification at stop time). Echoes a csv. Empty string
# means no dimension requirement (legacy path for simple tasks).
#
# Thresholds:
#   unique_count < OMC_DIMENSION_GATE_FILE_COUNT → empty (simple task)
#   Otherwise:                                   → bug_hunt,code_quality,stress_test,completeness
#   If doc_count > 0 or task_domain=writing:     → append prose
#   If ui_count > 0:                             → append design_quality
#   If unique_count >= OMC_TRACEABILITY_FILE_COUNT → append traceability

get_required_dimensions() {
  local code_count doc_count ui_count unique_count
  code_count="$(read_state "code_edit_count")"
  doc_count="$(read_state "doc_edit_count")"
  ui_count="$(read_state "ui_edit_count")"
  code_count="${code_count:-0}"
  doc_count="${doc_count:-0}"
  ui_count="${ui_count:-0}"
  unique_count=$((code_count + doc_count))

  # Legacy fallback: if the counters are not populated (resumed session
  # from pre-dimension-gate state), derive counts AND classification
  # from edited_files.log by scanning each unique path. Without this
  # classification, a resumed doc-only session would route to the code
  # dimension set.
  if [[ "${unique_count}" -eq 0 ]]; then
    local edited_log
    edited_log="$(session_file "edited_files.log")"
    if [[ -f "${edited_log}" ]]; then
      local _path
      while IFS= read -r _path; do
        [[ -z "${_path}" ]] && continue
        unique_count=$((unique_count + 1))
        if is_doc_path "${_path}"; then
          doc_count=$((doc_count + 1))
        else
          code_count=$((code_count + 1))
          if is_ui_path "${_path}"; then
            ui_count=$((ui_count + 1))
          fi
        fi
      done < <(sort -u "${edited_log}")
    fi
  fi

  if [[ "${unique_count}" -lt "${OMC_DIMENSION_GATE_FILE_COUNT}" ]]; then
    printf ''
    return
  fi

  local dims=""
  if [[ "${code_count}" -gt 0 ]] || [[ "${unique_count}" -gt 0 && "${doc_count}" -eq 0 ]]; then
    dims="bug_hunt,code_quality,stress_test,completeness"
  fi

  local td
  td="$(task_domain)"
  if [[ "${doc_count}" -gt 0 ]] || [[ "${td}" == "writing" ]]; then
    if [[ -n "${dims}" ]]; then
      dims="${dims},prose"
    else
      dims="prose,completeness"
    fi
  fi

  # design_quality: appended when UI files (tsx, jsx, vue, css, etc.) were
  # edited. Since UI is a subset of code (both counters increment), dims
  # will always be non-empty when ui_count > 0.
  if [[ "${ui_count}" -gt 0 && -n "${dims}" ]]; then
    dims="${dims},design_quality"
  fi

  if [[ "${unique_count}" -ge "${OMC_TRACEABILITY_FILE_COUNT}" ]]; then
    if [[ -n "${dims}" ]]; then
      dims="${dims},traceability"
    else
      dims="traceability"
    fi
  fi

  printf '%s' "${dims}"
}

# Echoes a csv of dimensions that are NOT currently valid (missing or
# invalidated by post-tick edits). Empty string means all required
# dimensions are satisfied.
missing_dimensions() {
  local required="$1"
  local missing=""
  local tok
  for tok in ${required//,/ }; do
    [[ -z "${tok}" ]] && continue
    if ! is_dimension_valid "${tok}"; then
      if [[ -n "${missing}" ]]; then
        missing="${missing},${tok}"
      else
        missing="${tok}"
      fi
    fi
  done
  printf '%s' "${missing}"
}

# --- end dimension helpers ---

is_checkpoint_request() {
  local text="$1"

  grep -Eiq '\b(checkpoint|pause here|stop here|for now|continue later|pick up later|resume later|for this session|one wave at a time|one phase at a time|wave [0-9]+ only|phase [0-9]+ only|first wave only|first phase only|just wave [0-9]+|just phase [0-9]+)\b' <<<"${text}"
}

is_session_management_request() {
  local text="$1"

  # An explicit imperative at the top of the prompt beats any embedded SM
  # keywords. Without this, a prompt like "Please evaluate ..." whose quoted
  # body contains "this session's" + "worth fixing" gets misrouted to SM.
  if is_imperative_request "${text}"; then
    return 1
  fi

  # Scope the session-keyword scan to the first 400 chars. Real SM queries
  # state their framing near the top; embedded/quoted content later in the
  # prompt (e.g., /ulw command bodies that reference "this session") should
  # not force SM routing.
  local head="${text:0:400}"

  grep -Eiq '\b(new session|fresh session|same session|this session|continue here|continue in this session|stop here|pause here|resume later|pick up later|context budget|context window|context limit|usage limit|token limit|limit hit|compaction|compact)\b' <<<"${head}" \
    && grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\b|worth\b|prefer\b|advice\b|suggest\b)' <<<"${text}"
}

is_advisory_request() {
  local text="$1"

  grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\b|worth\b|prefer\b|advice\b|suggest\b|tradeoff\b|tradeoffs\b|pros and cons\b|should we\b|would it be better\b|is it better\b|do you think\b)' <<<"${text}"
}

# --- P0: Imperative detection (checked before advisory in classify_task_intent) ---

is_imperative_request() {
  local text="$1"
  local nocasematch_was_set=0

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1

  # "Can/Could/Would you [verb]..." — polite imperatives
  if [[ "${text}" =~ ^[[:space:]]*(can|could|would)[[:space:]]+you[[:space:]]+(please[[:space:]]+)?(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|set[[:space:]]+up|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|review|start|stop|enable|disable|open|close|evaluate|plan|audit|investigate|research|analyze|analyse|assess|execute|document|extend|raise|design|style|redesign) ]]; then
    result=0
  # "Please [adverb?] [verb]..." patterns — single optional -ly adverb between please and verb
  elif [[ "${text}" =~ ^[[:space:]]*(please)[[:space:]]+([a-z]+ly[[:space:]]+)?(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|proceed|go|evaluate|plan|audit|investigate|research|analyze|analyse|assess|execute|document|extend|raise|design|style|redesign) ]]; then
    result=0
  # "Go ahead and..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*go[[:space:]]+ahead ]]; then
    result=0
  # "I need/want you to..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*i[[:space:]]+(need|want)[[:space:]]+(you[[:space:]]+to|to)[[:space:]] ]]; then
    result=0
  # Bare imperative: starts with unambiguous action verb, no trailing question mark
  # Excludes: check, test, help, review, plan, research, evaluate — too ambiguous as bare starts
  # (evaluate/plan/research can be nouns; kept to polite/please forms only)
  # Excludes: check, test, help, review, plan, research, evaluate, design, style — too ambiguous as bare starts
  elif [[ ! "${text}" =~ \?[[:space:]]*$ ]] && [[ "${text}" =~ ^[[:space:]]*(fix|implement|add|create|build|update|refactor|debug|deploy|write|make|change|modify|remove|delete|move|rename|install|configure|run|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|start|stop|enable|disable|open|close|set[[:space:]]+up|proceed|audit|investigate|analyze|analyse|execute|document|extend|raise|redesign)[[:space:]] ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

# --- end P0 ---

has_unfinished_session_handoff() {
  local text="$1"

  grep -Eiq '\b(ready for a new session|ready for another session|continue in a new session|continue in another session|new session\b|another session\b|next wave\b|next phase\b|wave [0-9]+[^.!\n]* is next|phase [0-9]+[^.!\n]* is next|remaining work\b|the rest\b|pick up .* later|continue .* later)\b' <<<"${text}"
}

# --- P1: Scoring-based domain classification ---

count_keyword_matches() {
  local pattern="$1"
  local text="$2"
  { grep -oEi "${pattern}" <<<"${text}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

infer_domain() {
  local text="$1"

  local coding_score
  local writing_score
  local research_score
  local operations_score

  # --- Bigram matching: compound phrases that disambiguate domain ---
  # Action + coding-object → strong coding signal
  local coding_bigrams
  coding_bigrams=$(count_keyword_matches '\b(writ(e|ing)|add(ing)?|creat(e|ing)|run(ning)?|fix(ing)?|updat(e|ing))\s+((unit|integration|e2e|end.to.end|acceptance)\s+)?(tests?|test\s*suites?|specs?|code|functions?|class(es)?|components?|endpoints?|modules?|handlers?|middleware|routes?|migrations?|schemas?)\b' "${text}")
  coding_bigrams=${coding_bigrams:-0}

  # Design/style + UI-object → coding signal (not general)
  local design_bigrams
  design_bigrams=$(count_keyword_matches '\b(design(ing)?|style|styl(e|ing)|redesign(ing)?|restyle|theme)\s+(a\s+|the\s+|my\s+|our\s+)?(\w+\s+){0,2}(pages?|forms?|buttons?|cards?|modals?|dropdowns?|nav(igation|bar)?|sidebars?|headers?|footers?|heros?|layouts?|components?|interfaces?|screens?|dashboards?|landing.?pages?|sections?|menus?|tabs?|panels?)\b' "${text}")
  design_bigrams=${design_bigrams:-0}
  coding_bigrams=$((coding_bigrams + design_bigrams))

  # Action + writing-object → writing signal
  local writing_bigrams
  writing_bigrams=$(count_keyword_matches '\b(writ(e|ing)|draft(ing)?|compos(e|ing)|author(ing)?)\s+(papers?|essays?|reports?|emails?|memos?|articles?|letters?|proposals?|manuscripts?|blogs?\s*posts?)\b' "${text}")
  writing_bigrams=${writing_bigrams:-0}

  # --- Negative keywords: subtract false positives ---
  # "report" after bug/error/test/crash → coding context, not writing
  # "post" in HTTP context → not writing
  local writing_negatives
  writing_negatives=$(count_keyword_matches '\b(bug|error|test|crash|status|coverage)\s+reports?\b|\bpost\s+(requests?|endpoints?|methods?|routes?|data)\b' "${text}")
  writing_negatives=${writing_negatives:-0}

  # --- Unigram scoring ---
  local coding_strong
  coding_strong=$(count_keyword_matches '\b(bugs?|fix(es|ed|ing)?|debug(ging)?|refactor(ing)?|implement(ation|ed|ing)?|repos?(itory)?|function|class(es)?|component|endpoints?|apis?|schema|database|quer(y|ies)|migration|lint(ing)?|compile|tsc|typescript|javascript|python|swift|xcode|react|next\.?js|css|html|webhooks?|codebase|source.?code|ci/?cd|docker|container|backend|frontend|fullstack|tailwind|vue(\.?js)?|angular|svelte|ui|ux|layout|landing.?page|dashboard|responsive|animation)\b' "${text}")
  coding_strong=$(( ${coding_strong:-0} + coding_bigrams ))

  local coding_weak
  coding_weak=$(count_keyword_matches '\b(tests?|build|scripts?|config(uration)?|hooks?|deploy(ed|ing|ment)?|server|commit(s|ted|ting)?|push(ed|ing)?|merge[dr]?|rebase[dr]?|branch(es|ed|ing)?|cherry.?pick|stash(ed|ing)?|tag(ged|ging)?)\b' "${text}")
  coding_weak=${coding_weak:-0}

  # Weak coding keywords only count when a strong signal is present,
  # OR when 3+ weak signals cluster together (multiple weak = strong).
  if [[ "${coding_strong}" -gt 0 ]]; then
    coding_score=$((coding_strong + coding_weak))
  elif [[ "${coding_weak}" -ge 3 ]]; then
    coding_score="${coding_weak}"
  else
    coding_score=0
  fi

  writing_score=$(count_keyword_matches '\b(paper|draft(ing)?|essay|article|report|proposal|email|memo|letter|statement|abstract|introduction|conclusion|outline|rewrite|polish(ing)?|paragraph|manuscript|cover.?letter|sop|personal.?statement|blog|post)\b' "${text}")
  writing_score=$(( ${writing_score:-0} + writing_bigrams - writing_negatives ))
  if [[ "${writing_score}" -lt 0 ]]; then writing_score=0; fi

  research_score=$(count_keyword_matches '\b(research(ing)?|investigate|investigation|analy(sis|ze|zing)|compare|comparison|survey|literature|sources|citations?|references?|benchmark(ing)?|brief(ing)?|recommendation|summarize|summary|pros.?and.?cons|tradeoffs?|audit(ing)?|assess(ment|ing)?|evaluat(e|ion|ing)|inspect(ion|ing)?)\b' "${text}")
  research_score=${research_score:-0}

  operations_score=$(count_keyword_matches '\b(plan(ning)?|roadmap|timeline|agenda|meeting|follow[- ]?up|checklist|prioriti(es|se|ze)|project.?plan|travel.?plan|itinerary|reply(ing)?|respond(ing)?|application|submission)\b' "${text}")
  operations_score=${operations_score:-0}

  local max_score=0
  local primary_domain="general"

  if [[ "${coding_score}" -gt "${max_score}" ]]; then
    max_score="${coding_score}"
    primary_domain="coding"
  fi
  if [[ "${writing_score}" -gt "${max_score}" ]]; then
    max_score="${writing_score}"
    primary_domain="writing"
  fi
  if [[ "${research_score}" -gt "${max_score}" ]]; then
    max_score="${research_score}"
    primary_domain="research"
  fi
  if [[ "${operations_score}" -gt "${max_score}" ]]; then
    max_score="${operations_score}"
    primary_domain="operations"
  fi

  if [[ "${max_score}" -eq 0 ]]; then
    printf '%s\n' "general"
    return
  fi

  # Mixed: requires coding involvement with a second significant domain
  if [[ "${coding_score}" -gt 0 ]]; then
    local second_max=0
    if [[ "${primary_domain}" == "coding" ]]; then
      for s in "${writing_score}" "${research_score}" "${operations_score}"; do
        [[ "${s}" -gt "${second_max}" ]] && second_max="${s}"
      done
    else
      second_max="${coding_score}"
    fi
    if [[ "${second_max}" -gt 0 && "${max_score}" -gt 0 ]] \
      && [[ "$(( second_max * 100 / max_score ))" -ge 40 ]]; then
      printf '%s\n' "mixed"
      return
    fi
  fi

  printf '%s\n' "${primary_domain}"
}

# --- end P1 ---

classify_task_intent() {
  local text="$1"
  local normalized

  # If the prompt is a /ulw or /autowork skill-body expansion, classify on the
  # user's task body rather than the skill header. Without this, embedded SM
  # or advisory keywords in a quoted task body (e.g., a /ulw command pasting a
  # previous session's feedback) can mis-route an obvious execution request.
  local task_body
  if task_body="$(extract_skill_primary_task "${text}")"; then
    text="${task_body}"
  fi

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if [[ -z "${normalized}" ]]; then
    printf '%s\n' "execution"
    return
  fi

  if is_continuation_request "${text}"; then
    printf '%s\n' "continuation"
  elif is_checkpoint_request "${normalized}"; then
    printf '%s\n' "checkpoint"
  elif is_session_management_request "${normalized}"; then
    printf '%s\n' "session_management"
  elif is_imperative_request "${normalized}"; then
    printf '%s\n' "execution"
  elif is_advisory_request "${normalized}"; then
    printf '%s\n' "advisory"
  else
    printf '%s\n' "execution"
  fi
}

is_execution_intent_value() {
  local intent="$1"

  case "${intent}" in
    execution|continuation)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# --- P2: Council evaluation detection ---
# Detects broad whole-project evaluation requests that benefit from
# multi-role perspective dispatch (product, design, security, data, SRE, growth).
# Intentionally strict: must reference the project/codebase/app as a whole,
# or use holistic qualifiers, or ask "what should I improve" type questions.
# Does NOT match focused requests like "evaluate this function" or "review this PR."

# Helper for is_council_evaluation_request: detects narrowing qualifiers that
# scope a request to a specific code artifact or subsystem concept, signaling
# the request is focused rather than whole-project.
# Three tiers:
#   A: [preposition] [demonstrative] [artifact] — "in this function", "to the handler"
#   B: [this|that] [artifact] — "this function", "that endpoint" (no preposition)
#   C: [preposition] [subsystem concept] — "in error handling", "about architecture"
#      (no demonstrative needed for well-known subsystem scoping)
_has_narrow_scope() {
  local text="$1"

  # Tier A + B: preposition+demonstrative+artifact, or bare this/that+artifact
  # Note: "pr" replaced with "pull.?requests?" to avoid matching "project" via pr\w*
  grep -Eiq '(\b(to|in|from|about|with)\s+(this|the|that|my)|\b(this|that))\s+(function|method|class|module|component|endpoint|file|handler|test|route|flow|section|line|block|hook|script|page|view|query|model|schema|table|api|service|controller|middleware|error|auth|database|config|pull.?requests?|commit|branch|migration|architecture|design|handling|layer|logic|workflow|pipeline|infrastructure|deployment|navigation|layout|rendering|setup)\w*\b' <<<"${text}" \
    && return 0

  # Tier C: preposition + subsystem concept (no demonstrative required)
  # Catches "in error handling", "about authentication", "from architecture"
  grep -Eiq '\b(to|in|from|about|with)\s+(error|auth|api|security|data|cache|session|payment|frontend|backend|infrastructure|architecture|performance|reliability|deployment|navigation|rendering|logging|caching|routing|networking|authentication|authorization|observability|monitoring|testing|validation|serialization|scheduling)\w*\b' <<<"${text}" \
    && return 0

  # Tier D: Short abbreviations (too short for the \w*-suffixed artifact list)
  # "this PR", "in this PR", "that PR" — exact word match to avoid matching "project"
  grep -Eiq '(\b(to|in|from|about|with)\s+(this|the|that|my)|\b(this|that))\s+prs?\b' <<<"${text}" \
    && return 0

  return 1
}

# Helper for Pattern 5: detects when "improve" or "improvements" targets a specific
# area rather than the whole project.
# - "improvements to [non-project-word]" → scoped ("to the login flow")
# - "improvements to the project/codebase" → NOT scoped (whole-project target)
# - "review and improve the [non-project-word]" → scoped ("improve the tests")
# - "review and improve" (no object) → NOT scoped (broad intent)
_has_scoped_improve_target() {
  local text="$1"

  # "improvements to [word]" where [word] is NOT a project-level noun
  if grep -Eiq '\bimprovements?\s+to\s+' <<<"${text}" \
     && ! grep -Eiq '\bimprovements?\s+to\s+(the\s+|my\s+|our\s+)?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [the|my] [non-project-word]" — direct object after improve
  if grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+\w' <<<"${text}" \
     && ! grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [subsystem-concept]" — bare noun without determiner
  grep -Eiq '\bimprove\s+(error|auth|api|security|data|cache|session|payment|frontend|backend|infrastructure|architecture|performance|reliability|deployment|navigation|rendering|logging|caching|routing|networking|authentication|authorization|observability|monitoring|testing|validation)\w*\b' <<<"${text}" \
    && return 0

  return 1
}

is_council_evaluation_request() {
  local text="$1"

  # Pattern 1: "[evaluate|assess|audit|review] [my|the|this|our] [entire|whole]? [project|codebase|app|product|repo]"
  # Guarded: reject if the project-level word is part of a compound noun
  # (e.g., "project manager", "project plan", "product team")
  if grep -Eiq '(evaluat|assess|audit|review|inspect|analyz)\w*\s+(my|the|this|our|entire|whole|full)\s+((entire|whole|full|complete)\s+)?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system)\b' <<<"${text}" \
     && ! grep -Eiq '\b(project|product)\s+(manager|management|plan|planning|structure|timeline|scope|lead|owner|director|description|proposal|requirements?|specification|charter|budget|schedule|board|team|files?|folders?|documentation|dependencies|configuration|roadmap|backlog|strategy|design|review)\b' <<<"${text}"; then
    return 0
  fi

  # Pattern 2: "[full|holistic|comprehensive] [review|evaluation|assessment]"
  grep -Eiq '\b(full|holistic|comprehensive|complete|whole|broad|overall)\s+(project\s+)?(review|evaluation|assessment|audit|analysis)\b' <<<"${text}" \
    && return 0

  # Pattern 3: "what [should I improve | needs improvement | am I missing]"
  if grep -Eiq '\bwhat\s+(should\s+(i|we)\s+improve|needs?\s+(to\s+be\s+)?(improv|fix|chang)|am\s+i\s+miss|are\s+(we|the)\s+miss|could\s+(be\s+)?(improv|better))' <<<"${text}" \
     && ! _has_narrow_scope "${text}"; then
    return 0
  fi

  # Pattern 4: "[find|surface|identify] [blind spots|gaps|weaknesses|what is missing]"
  if grep -Eiq '\b(find|surface|identify|spot|uncover)\s+(blind\s+spots?|gaps?|weaknesses?|what\s+(is|are)\s+missing)\b' <<<"${text}" \
     && ! _has_narrow_scope "${text}"; then
    return 0
  fi

  # Pattern 5: "evaluate and plan" / "plan for improvements" / "review and improve"
  # Three sub-guards:
  #   a) _has_narrow_scope — rejects scoping to specific artifacts/subsystems
  #   b) "improvements to [non-project-word]" — "improvements to the login" is scoped
  #   c) "review/improve" with a direct object that's not a project-level word — scoped
  if grep -Eiq '\b(plan\s+for\s+improvements?|evaluat\w*.*and\s+(then\s+)?plan|review.*and\s+improve|evaluat\w*.*improv)\b' <<<"${text}" \
     && ! _has_narrow_scope "${text}" \
     && ! _has_scoped_improve_target "${text}"; then
    return 0
  fi

  return 1
}

# --- end P2 ---
