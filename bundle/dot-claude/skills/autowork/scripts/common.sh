#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
STATE_JSON="session_state.json"
HOOK_LOG="${STATE_ROOT}/hooks.log"

# Guard: jq is required for all hook operations. If missing, exit gracefully
# so hooks don't break Claude Code's operation.
if ! command -v jq >/dev/null 2>&1; then
  printf 'oh-my-claude: jq is required but not found in PATH. Hooks disabled.\n' >&2
  exit 0
fi

# --- Configurable thresholds (tunable via oh-my-claude.conf) ---
# Precedence: env var > conf file > built-in default.
# Track which vars were set via env before applying defaults.
_omc_env_stall="${OMC_STALL_THRESHOLD:-}"
_omc_env_excellence="${OMC_EXCELLENCE_FILE_COUNT:-}"
_omc_env_ttl="${OMC_STATE_TTL_DAYS:-}"
_omc_env_dimgate="${OMC_DIMENSION_GATE_FILE_COUNT:-}"
_omc_env_traceability="${OMC_TRACEABILITY_FILE_COUNT:-}"
_omc_env_exhaustion="${OMC_GUARD_EXHAUSTION_MODE:-}"
_omc_env_verify_conf="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-}"
_omc_env_gate_level="${OMC_GATE_LEVEL:-}"
_omc_env_verify_mcp="${OMC_CUSTOM_VERIFY_MCP_TOOLS:-}"

OMC_STALL_THRESHOLD="${OMC_STALL_THRESHOLD:-12}"
OMC_EXCELLENCE_FILE_COUNT="${OMC_EXCELLENCE_FILE_COUNT:-3}"
OMC_STATE_TTL_DAYS="${OMC_STATE_TTL_DAYS:-7}"
OMC_DIMENSION_GATE_FILE_COUNT="${OMC_DIMENSION_GATE_FILE_COUNT:-3}"
OMC_TRACEABILITY_FILE_COUNT="${OMC_TRACEABILITY_FILE_COUNT:-6}"
# Guard exhaustion mode: scorecard (default, legacy: warn), block (legacy: strict), silent (legacy: release)
OMC_GUARD_EXHAUSTION_MODE="${OMC_GUARD_EXHAUSTION_MODE:-warn}"
# Minimum verification confidence (0-100) to satisfy the verify gate.
# Default 40: blocks lint-only checks (shellcheck=30, bash -n=30) while
# accepting project test suites (npm test=70+) and framework runs (jest=50+).
OMC_VERIFY_CONFIDENCE_THRESHOLD="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
# Gate level: basic (quality gate only), standard (+ excellence), full (+ dimensions)
OMC_GATE_LEVEL="${OMC_GATE_LEVEL:-full}"
# Pipe-separated glob patterns for additional MCP tools that count as verification.
# Example: mcp__my_cypress__*|mcp__custom_api_tester__*
# NOTE: Custom MCP tools also require a matching PostToolUse hook entry in
# settings.json to trigger record-verification.sh. The builtin matcher only
# covers Playwright and computer-use tools.
OMC_CUSTOM_VERIFY_MCP_TOOLS="${OMC_CUSTOM_VERIFY_MCP_TOOLS:-}"

_omc_conf_loaded=0

# Parse a single conf file, applying values that pass validation.
# Env vars always take precedence (checked via _omc_env_* guards).
_parse_conf_file() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line}" ]] && continue
    [[ "${line}" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

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
      guard_exhaustion_mode)
        [[ -z "${_omc_env_exhaustion}" && "${value}" =~ ^(release|warn|strict|silent|scorecard|block)$ ]] && OMC_GUARD_EXHAUSTION_MODE="${value}" || true ;;
      verify_confidence_threshold)
        [[ -z "${_omc_env_verify_conf}" && "${value}" =~ ^[0-9]+$ && "${value}" -le 100 ]] && OMC_VERIFY_CONFIDENCE_THRESHOLD="${value}" || true ;;
      gate_level)
        [[ -z "${_omc_env_gate_level}" && "${value}" =~ ^(basic|standard|full)$ ]] && OMC_GATE_LEVEL="${value}" || true ;;
      custom_verify_mcp_tools)
        [[ -z "${_omc_env_verify_mcp}" && -n "${value}" ]] && OMC_CUSTOM_VERIFY_MCP_TOOLS="${value}" || true ;;
    esac
  done < "${conf}"
}

load_conf() {
  if [[ "${_omc_conf_loaded}" -eq 1 ]]; then return; fi
  _omc_conf_loaded=1

  # Layer 1: User-level config
  _parse_conf_file "${HOME}/.claude/oh-my-claude.conf"

  # Layer 2: Project-level config (overrides user-level).
  # Walk up from $PWD looking for .claude/oh-my-claude.conf, capped at 10
  # levels. Skip $HOME to avoid double-reading the user conf.
  local _dir="${PWD}"
  local _depth=0
  while [[ "${_dir}" != "/" && "${_depth}" -lt 10 ]]; do
    if [[ "${_dir}" != "${HOME}" && -f "${_dir}/.claude/oh-my-claude.conf" ]]; then
      _parse_conf_file "${_dir}/.claude/oh-my-claude.conf"
      break
    fi
    _dir="$(dirname "${_dir}")"
    _depth=$((_depth + 1))
  done
}

# Load conf at source time so all scripts get configured values.
load_conf

# Normalize legacy exhaustion mode names to new canonical names.
# Accepts both old (release/warn/strict) and new (silent/scorecard/block).
case "${OMC_GUARD_EXHAUSTION_MODE}" in
  release) OMC_GUARD_EXHAUSTION_MODE="silent" ;;
  warn)    OMC_GUARD_EXHAUSTION_MODE="scorecard" ;;
  strict)  OMC_GUARD_EXHAUSTION_MODE="block" ;;
esac

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
      if tail -n 1500 "${HOOK_LOG}" >"${_temp}" 2>/dev/null; then
        mv "${_temp}" "${HOOK_LOG}"
      else
        rm -f "${_temp}"
      fi
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
  chmod 700 "${STATE_ROOT}/${SESSION_ID}" 2>/dev/null || true
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

  if jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" >"${temp_file}"; then
    mv "${temp_file}" "${state_file}"
  else
    rm -f "${temp_file}"
    return 1
  fi
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

  if jq "${args[@]}" "${jq_filter}" "${state_file}" >"${temp_file}"; then
    mv "${temp_file}" "${state_file}"
  else
    rm -f "${temp_file}"
    return 1
  fi
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

# Convenience wrapper: atomic write_state_batch inside with_state_lock.
# Usage: with_state_lock_batch k1 v1 k2 v2 ...
with_state_lock_batch() {
  with_state_lock write_state_batch "$@"
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

  # Pre-sweep aggregation: capture a summary line per session before deletion.
  # This preserves longitudinal data for quality analysis.
  # No lock needed: sweep is gated by the daily marker file, so only one
  # process runs it at a time. Concurrent writes are structurally impossible.
  local summary_file="${HOME}/.claude/quality-pack/session_summary.jsonl"

  if [[ -d "${STATE_ROOT}" ]]; then
    find "${STATE_ROOT}" -maxdepth 1 -type d -mtime +"${OMC_STATE_TTL_DAYS}" \
      ! -name '.' ! -name '..' ! -name '.*' ! -path "${STATE_ROOT}" \
      -print 2>/dev/null | while IFS= read -r _sweep_dir; do
        local _sweep_state="${_sweep_dir}/session_state.json"
        if [[ -f "${_sweep_state}" ]]; then
          local _sweep_sid _sweep_ec=0
          _sweep_sid="$(basename "${_sweep_dir}")"
          local _sweep_edits="${_sweep_dir}/edited_files.log"
          [[ -f "${_sweep_edits}" ]] && _sweep_ec="$(sort -u "${_sweep_edits}" | wc -l | tr -d '[:space:]')"
          jq -c --arg sid "${_sweep_sid}" --argjson ec "${_sweep_ec:-0}" '
            {
              session_id: $sid,
              start_ts: (.session_start_ts // .last_user_prompt_ts // null),
              end_ts: (.last_edit_ts // .last_review_ts // null),
              domain: (.task_domain // "unknown"),
              intent: (.task_intent // "unknown"),
              edit_count: $ec,
              code_edits: ((.code_edit_count // "0") | tonumber),
              doc_edits: ((.doc_edit_count // "0") | tonumber),
              verified: (if .last_verify_ts then true else false end),
              verify_outcome: (.last_verify_outcome // null),
              verify_confidence: ((.last_verify_confidence // "0") | tonumber),
              reviewed: (if .last_review_ts then true else false end),
              guard_blocks: ((.stop_guard_blocks // "0") | tonumber),
              dim_blocks: ((.dimension_guard_blocks // "0") | tonumber),
              exhausted: (if .guard_exhausted then true else false end),
              dispatches: ((.subagent_dispatch_count // "0") | tonumber)
            }
          ' "${_sweep_state}" >> "${summary_file}" 2>/dev/null || true
        fi
        rm -rf "${_sweep_dir}" 2>/dev/null || true
      done

    # Cap session_summary.jsonl at 500 lines
    if [[ -f "${summary_file}" ]]; then
      local _sum_lines
      _sum_lines="$(wc -l < "${summary_file}" 2>/dev/null || echo 0)"
      _sum_lines="${_sum_lines##* }"
      if [[ "${_sum_lines}" -gt 500 ]]; then
        local _sum_temp
        _sum_temp="$(mktemp "${summary_file}.XXXXXX")"
        if tail -n 400 "${summary_file}" > "${_sum_temp}" 2>/dev/null; then
          mv "${_sum_temp}" "${summary_file}"
        else
          rm -f "${_sum_temp}"
        fi
      fi
    fi
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
  local tail_marker="Follow the \`/autowork\`"

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

tick_dimensions_with_verdict() {
  local verdict="$1"
  local ts="${2:-$(now_epoch)}"
  shift 2

  [[ "$#" -gt 0 ]] || return 0

  local args=()
  local dim
  for dim in "$@"; do
    args+=("$(_dim_key "${dim}")" "${ts}" "dim_${dim}_verdict" "${verdict}")
  done

  with_state_lock_batch "${args[@]}"
}

set_dimension_verdicts() {
  local verdict="$1"
  shift

  [[ "$#" -gt 0 ]] || return 0

  local args=()
  local dim
  for dim in "$@"; do
    args+=("dim_${dim}_verdict" "${verdict}")
  done

  with_state_lock_batch "${args[@]}"
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

# order_dimensions_by_risk: Reorder a comma-separated list of dimensions
# so higher-risk dimensions come first. Returns reordered csv on stdout.
# Priority ordering:
#   1. stress_test (security/edge-case bugs are highest risk)
#   2. bug_hunt (logic bugs)
#   3. code_quality (code health)
#   4. design_quality (UI correctness)
#   5. prose (documentation)
#   6. completeness (holistic review)
#   7. traceability (cross-cutting, lowest risk)
# Within each priority level, the order is stable.
order_dimensions_by_risk() {
  local dims="$1"
  local project_profile="${2:-}"
  local ordered=""

  # Define priority tiers. If project has UI, promote design_quality.
  local priority_order="stress_test,bug_hunt,code_quality"
  if [[ -n "${project_profile}" ]] && project_profile_has "ui" "${project_profile}"; then
    priority_order="${priority_order},design_quality"
  fi
  priority_order="${priority_order},prose,completeness"
  if [[ -n "${project_profile}" ]] && ! project_profile_has "ui" "${project_profile}"; then
    priority_order="${priority_order},design_quality"
  fi
  priority_order="${priority_order},traceability"

  # Select only dims that are in the input list, preserving priority order
  local d
  for d in ${priority_order//,/ }; do
    if [[ ",${dims}," == *",${d},"* ]]; then
      ordered="${ordered:+${ordered},}${d}"
    fi
  done

  # Append any dims not in our priority list (future-proof)
  for d in ${dims//,/ }; do
    if [[ ",${ordered}," != *",${d},"* ]]; then
      ordered="${ordered:+${ordered},}${d}"
    fi
  done

  printf '%s' "${ordered}"
}

# check_clean_sweep: Check if ALL previously-ticked dimensions had CLEAN
# verdicts. Returns 0 (true) if all were clean, 1 otherwise.
# Used for fast-path: if all completed dims were clean, remaining low-risk
# dims can be deferred (logged as skipped in the scorecard).
check_clean_sweep() {
  local required_dims="$1"
  local _dim _verdict _tick_ts
  local any_ticked=0
  local any_findings=0

  for _dim in ${required_dims//,/ }; do
    _tick_ts="$(read_state "$(_dim_key "${_dim}")")"
    if [[ -n "${_tick_ts}" ]]; then
      any_ticked=1
      _verdict="$(read_state "dim_${_dim}_verdict")"
      if [[ "${_verdict}" == "FINDINGS" ]]; then
        any_findings=1
        break
      fi
    fi
  done

  # Clean sweep requires at least one dimension ticked and no findings
  [[ "${any_ticked}" -eq 1 && "${any_findings}" -eq 0 ]]
}

# --- end dimension helpers ---

# --- Verification confidence helpers ---

# detect_project_test_command: Inspect project files to discover the canonical
# test command. Returns the command string on stdout or empty if not detected.
# Looks at package.json, Makefile, Cargo.toml, pyproject.toml, etc.
detect_project_test_command() {
  local project_dir="${1:-.}"
  local test_cmd=""

  # package.json → npm/pnpm/yarn test
  if [[ -f "${project_dir}/package.json" ]]; then
    local scripts_test
    scripts_test="$(jq -r '.scripts.test // empty' "${project_dir}/package.json" 2>/dev/null || true)"
    if [[ -n "${scripts_test}" && "${scripts_test}" != "echo \"Error: no test specified\" && exit 1" ]]; then
      # Detect package manager
      if [[ -f "${project_dir}/pnpm-lock.yaml" ]]; then
        test_cmd="pnpm test"
      elif [[ -f "${project_dir}/yarn.lock" ]]; then
        test_cmd="yarn test"
      elif [[ -f "${project_dir}/bun.lockb" ]]; then
        test_cmd="bun test"
      else
        test_cmd="npm test"
      fi
    fi
  fi

  # Cargo.toml → cargo test
  if [[ -z "${test_cmd}" && -f "${project_dir}/Cargo.toml" ]]; then
    test_cmd="cargo test"
  fi

  # go.mod → go test ./...
  if [[ -z "${test_cmd}" && -f "${project_dir}/go.mod" ]]; then
    test_cmd="go test ./..."
  fi

  # pyproject.toml or setup.py → pytest
  if [[ -z "${test_cmd}" ]]; then
    if [[ -f "${project_dir}/pyproject.toml" ]] || [[ -f "${project_dir}/setup.py" ]]; then
      if [[ -f "${project_dir}/pyproject.toml" ]] \
        && grep -q 'pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
        test_cmd="pytest"
      elif command -v pytest &>/dev/null || [[ -f "${project_dir}/pytest.ini" ]] \
        || [[ -f "${project_dir}/setup.cfg" ]]; then
        test_cmd="pytest"
      fi
    fi
  fi

  # Makefile with test target
  if [[ -z "${test_cmd}" && -f "${project_dir}/Makefile" ]]; then
    if grep -qE '^test[[:space:]]*:' "${project_dir}/Makefile" 2>/dev/null; then
      test_cmd="make test"
    fi
  fi

  # mix.exs → mix test
  if [[ -z "${test_cmd}" && -f "${project_dir}/mix.exs" ]]; then
    test_cmd="mix test"
  fi

  # Gemfile → bundle exec rspec or rake test
  if [[ -z "${test_cmd}" && -f "${project_dir}/Gemfile" ]]; then
    if [[ -d "${project_dir}/spec" ]]; then
      test_cmd="bundle exec rspec"
    else
      test_cmd="rake test"
    fi
  fi

  printf '%s' "${test_cmd}"
}

verification_matches_project_test_command() {
  local cmd="${1:-}"
  local project_test_cmd="${2:-}"

  [[ -n "${cmd}" && -n "${project_test_cmd}" ]] || return 1

  local norm_cmd norm_ptc
  norm_cmd="$(printf '%s' "${cmd}" | sed 's/^[[:space:]]*//' | sed 's/^[A-Z_][A-Z0-9_]*=[^ ]* //')"
  norm_ptc="$(printf '%s' "${project_test_cmd}" | sed 's/^[[:space:]]*//')"

  [[ "${norm_cmd}" == "${norm_ptc}"* ]] || [[ "${norm_cmd}" == *"${norm_ptc}"* ]]
}

verification_has_framework_keyword() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || return 1
  printf '%s' "${cmd}" | grep -Eiq '\b(pytest|vitest|jest|mocha|cargo test|go test|npm test|pnpm test|yarn test|bun test|rspec|phpunit|xcodebuild test|swift test|mix test|gradle test|mvn test|dotnet test|rake test|deno test|shellcheck|bash -n)\b'
}

verification_output_has_counts() {
  local output="${1:-}"
  [[ -n "${output}" ]] || return 1
  printf '%s' "${output}" | grep -Eiq '[0-9]+ (passed|tests?|specs?|assertions?|examples?|ok)\b|Tests:[[:space:]]*[0-9]+|test result:'
}

verification_output_has_clear_outcome() {
  local output="${1:-}"
  [[ -n "${output}" ]] || return 1
  printf '%s' "${output}" | grep -Eiq '\b(PASS(ED)?|FAIL(ED)?|SUCCESS|OK|ALL.*PASSED|0 failures)\b|exit (code|status)[: ]*[0-9]'
}

detect_verification_method() {
  local cmd="${1:-}"
  local output="${2:-}"
  local project_test_cmd="${3:-}"

  if verification_matches_project_test_command "${cmd}" "${project_test_cmd}"; then
    printf 'project_test_command'
  elif verification_has_framework_keyword "${cmd}"; then
    printf 'framework_keyword'
  elif verification_output_has_counts "${output}" || verification_output_has_clear_outcome "${output}"; then
    printf 'output_signal'
  else
    printf 'builtin_verification'
  fi
}

# score_verification_confidence: Score how confident we are that a command
# actually exercised project-relevant verification. Returns a value 0-100
# on stdout. Scoring factors:
#   - Exact match with project test command: +40
#   - Contains known test framework keyword: +30
#   - Output contains assertion/test count: +20
#   - Output indicates pass/fail (not ambiguous): +10
score_verification_confidence() {
  local cmd="${1:-}"
  local output="${2:-}"
  local project_test_cmd="${3:-}"
  local score=0

  [[ -z "${cmd}" ]] && { printf '0'; return; }

  # Factor 1: Exact/prefix match with detected project test command
  if verification_matches_project_test_command "${cmd}" "${project_test_cmd}"; then
    score=$((score + 40))
  fi

  # Factor 2: Known test framework keywords in the command
  if verification_has_framework_keyword "${cmd}"; then
    score=$((score + 30))
  fi

  # Factor 3: Output contains test counts (e.g. "42 passed", "Tests: 10")
  if verification_output_has_counts "${output}"; then
    score=$((score + 20))
  fi

  # Factor 4: Clear pass/fail outcome in output
  if verification_output_has_clear_outcome "${output}"; then
    score=$((score + 10))
  fi

  printf '%s' "${score}"
}

# --- MCP verification helpers ---

# Builtin MCP tool names recognized as verification. Matches against the full
# tool_name from the hook JSON (e.g. mcp__plugin_playwright_playwright__browser_snapshot).
# Pattern uses bash glob-style matching via case statements, not regex.
readonly MCP_VERIFY_SNAPSHOT='*playwright*__browser_snapshot'
readonly MCP_VERIFY_SCREENSHOT='*playwright*__browser_take_screenshot'
readonly MCP_VERIFY_CONSOLE='*playwright*__browser_console_messages'
readonly MCP_VERIFY_NETWORK='*playwright*__browser_network_requests'
readonly MCP_VERIFY_EVALUATE='*playwright*__browser_evaluate'
readonly MCP_VERIFY_RUN_CODE='*playwright*__browser_run_code'
readonly MCP_VERIFY_CU_SCREENSHOT='mcp__computer-use__screenshot'

# classify_mcp_verification_tool: Given a tool_name, return a verification
# category string if the tool is verification-grade, or empty string if not.
classify_mcp_verification_tool() {
  local tool_name="${1:-}"
  [[ -n "${tool_name}" ]] || return 0

  # Check custom MCP verification tools from config
  if [[ -n "${OMC_CUSTOM_VERIFY_MCP_TOOLS}" ]]; then
    local custom_mcp_tools="${OMC_CUSTOM_VERIFY_MCP_TOOLS}"
    # custom_verify_mcp_tools is a pipe-separated list of glob patterns
    local _old_IFS="${IFS}"
    IFS='|'
    for pattern in ${custom_mcp_tools}; do
      # shellcheck disable=SC2254
      case "${tool_name}" in ${pattern}) IFS="${_old_IFS}"; printf 'custom_mcp_tool'; return 0 ;; esac
    done
    IFS="${_old_IFS}"
  fi

  # Builtin classifications (patterns are globs — expansion is intentional)
  # shellcheck disable=SC2254
  case "${tool_name}" in
    ${MCP_VERIFY_SNAPSHOT})     printf 'browser_dom_check' ;;
    ${MCP_VERIFY_SCREENSHOT})   printf 'browser_visual_check' ;;
    ${MCP_VERIFY_CONSOLE})      printf 'browser_console_check' ;;
    ${MCP_VERIFY_NETWORK})      printf 'browser_network_check' ;;
    ${MCP_VERIFY_EVALUATE})     printf 'browser_eval_check' ;;
    ${MCP_VERIFY_RUN_CODE})     printf 'browser_eval_check' ;;
    ${MCP_VERIFY_CU_SCREENSHOT}) printf 'visual_check' ;;
    *) printf '' ;;
  esac
}

# score_mcp_verification_confidence: Score how confident we are that an MCP
# tool call constitutes meaningful verification. Returns 0-100 on stdout.
#
# Base scores are deliberately below the default threshold (40) so that a
# single passive observation (e.g. an empty browser_snapshot) cannot clear
# the verify gate on its own. Passing the gate requires either:
#   - Output that carries assertion/pass-fail signals (+15/+10 bonuses), OR
#   - A UI-edit context bonus (+20) when recent edits were to UI files.
#
# Args: verify_type, output, has_ui_context ("true"/"false")
score_mcp_verification_confidence() {
  local verify_type="${1:-}"
  local output="${2:-}"
  local has_ui_context="${3:-false}"
  local score=0

  # Base scores — all below default threshold of 40
  case "${verify_type}" in
    browser_dom_check)     score=25 ;;  # DOM snapshot — passive observation
    browser_visual_check)  score=20 ;;  # Screenshot — most passive
    browser_console_check) score=30 ;;  # Console errors — targeted check
    browser_network_check) score=30 ;;  # Network requests — targeted check
    browser_eval_check)    score=35 ;;  # JS evaluation — closest to assertions
    visual_check)          score=15 ;;  # Computer-use screenshot — least targeted
    custom_mcp_tool)       score=35 ;;  # User-configured — some trust
    *)                     score=10 ;;
  esac

  # UI-context bonus: if recent edits include UI files, browser-based
  # verification becomes meaningfully more relevant.
  if [[ "${has_ui_context}" == "true" ]]; then
    score=$((score + 20))
  fi

  # Bonus: output contains assertion-like content or test counts
  if [[ -n "${output}" ]]; then
    if printf '%s' "${output}" | grep -Eiq '[0-9]+ (passed|tests?|errors?|warnings?)\b'; then
      score=$((score + 15))
    fi
    if printf '%s' "${output}" | grep -Eiq '\b(PASS(ED)?|SUCCESS|OK|no errors|0 errors)\b'; then
      score=$((score + 10))
    fi
  fi

  # Cap at 100
  [[ "${score}" -gt 100 ]] && score=100
  printf '%s' "${score}"
}

# detect_mcp_verification_outcome: Detect pass/fail from MCP tool output.
# Returns "passed" or "failed" on stdout.
detect_mcp_verification_outcome() {
  local output="${1:-}"
  local verify_type="${2:-}"

  # Default: passed (MCP observation tools don't inherently "fail")
  [[ -n "${output}" ]] || { printf 'passed'; return; }

  # Check for explicit error signals in output
  case "${verify_type}" in
    browser_console_check)
      # Console messages: look for JS error types, uncaught exceptions, and
      # generic "Error:" prefix (common in console.error output).
      if printf '%s' "${output}" | grep -Eq '\b(TypeError|ReferenceError|SyntaxError|RangeError|URIError|EvalError|uncaught|Uncaught)\b|^Error:|[[:space:]]Error:'; then
        printf 'failed'; return
      fi
      ;;
    browser_network_check)
      # Network: look for failed HTTP statuses and connection errors.
      # Uses "timed? out" instead of bare "timeout" to avoid matching config values.
      if printf '%s' "${output}" | grep -Eiq '\b(401|403|404|500|502|503|failed|timed? out|CORS|ERR_|Unauthorized|Forbidden)\b'; then
        printf 'failed'; return
      fi
      ;;
    browser_eval_check)
      # JS evaluation: look for specific error types, assertion failures, and
      # generic "Error:" prefix (thrown errors stringify as "Error: message").
      if printf '%s' "${output}" | grep -Eq '\b(AssertionError|TypeError|ReferenceError|SyntaxError|RangeError)\b|Uncaught|FAIL|^Error:|[[:space:]]Error:'; then
        printf 'failed'; return
      fi
      ;;
    *)
      # DOM snapshots and screenshots: check for error page indicators
      if printf '%s' "${output}" | grep -Eiq '\b(500 Internal Server Error|404 Not Found|Application Error|Something went wrong)\b'; then
        printf 'failed'; return
      fi
      ;;
  esac

  printf 'passed'
}

# --- end verification helpers ---

# --- Stall detection helpers ---

# compute_stall_threshold: Scale the stall threshold based on task complexity.
# A simple 1-file edit should stall at the default (12 reads), while a large
# multi-file task gets more leeway (up to 2x the base threshold).
# Returns integer threshold on stdout.
compute_stall_threshold() {
  local base_threshold="${OMC_STALL_THRESHOLD}"
  local edited_count="${1:-0}"
  local has_plan="${2:-false}"

  # Plans legitimately require more exploration
  local plan_bonus=0
  if [[ "${has_plan}" == "true" ]]; then
    plan_bonus=4
  fi

  # Scale by complexity: 1-2 files=base, 3-5=+4, 6+=+8
  local complexity_bonus=0
  if [[ "${edited_count}" -ge 6 ]]; then
    complexity_bonus=8
  elif [[ "${edited_count}" -ge 3 ]]; then
    complexity_bonus=4
  fi

  printf '%s' "$(( base_threshold + plan_bonus + complexity_bonus ))"
}

# compute_progress_score: Compute a 0-100 progress score for the current session.
# Considers edits made, verifications run, reviews completed, and dimensions ticked.
# Higher scores mean more progress — used to soften stall messages when real work
# is being done alongside exploration.
compute_progress_score() {
  local score=0

  local last_edit_ts last_verify_ts last_review_ts
  last_edit_ts="$(read_state "last_edit_ts")"
  last_verify_ts="$(read_state "last_verify_ts")"
  last_review_ts="$(read_state "last_review_ts")"

  # Edit count from log
  local edited_count=0
  local edited_log
  edited_log="$(session_file "edited_files.log")"
  if [[ -f "${edited_log}" ]]; then
    edited_count="$(sort -u "${edited_log}" | wc -l | tr -d '[:space:]')"
  fi
  edited_count="${edited_count:-0}"

  # Points for edits (up to 30)
  if [[ "${edited_count}" -ge 5 ]]; then
    score=$((score + 30))
  elif [[ "${edited_count}" -ge 1 ]]; then
    score=$((score + edited_count * 6))
  fi

  # Points for verification (up to 20)
  if [[ -n "${last_verify_ts}" ]]; then
    score=$((score + 20))
  fi

  # Points for review (up to 20)
  if [[ -n "${last_review_ts}" ]]; then
    score=$((score + 20))
  fi

  # Points for plan (10)
  local has_plan
  has_plan="$(read_state "has_plan")"
  if [[ "${has_plan}" == "true" ]]; then
    score=$((score + 10))
  fi

  # Points for dimension ticks (up to 20)
  local dim_ticks=0
  local _dim
  for _dim in bug_hunt code_quality stress_test completeness prose traceability design_quality; do
    local _ts
    _ts="$(read_state "$(_dim_key "${_dim}")")"
    if [[ -n "${_ts}" ]]; then
      dim_ticks=$((dim_ticks + 1))
    fi
  done
  if [[ "${dim_ticks}" -ge 4 ]]; then
    score=$((score + 20))
  elif [[ "${dim_ticks}" -ge 1 ]]; then
    score=$((score + dim_ticks * 5))
  fi

  # Cap at 100
  if [[ "${score}" -gt 100 ]]; then
    score=100
  fi

  printf '%s' "${score}"
}

# --- end stall detection helpers ---

# --- Quality scorecard ---

# build_quality_scorecard: Build a human-readable quality scorecard summarizing
# the current quality gate status. Returns a multi-line string on stdout.
# Used when guards exhaust to give visibility into what was completed vs skipped.
build_quality_scorecard() {
  local sc=""
  local check_mark="✓"
  local cross_mark="✗"
  local dash_mark="–"

  # Verification status
  local last_verify_ts last_verify_outcome last_verify_cmd verify_confidence
  last_verify_ts="$(read_state "last_verify_ts")"
  last_verify_outcome="$(read_state "last_verify_outcome")"
  last_verify_cmd="$(read_state "last_verify_cmd")"
  verify_confidence="$(read_state "last_verify_confidence")"

  if [[ -n "${last_verify_ts}" ]]; then
    if [[ "${last_verify_outcome}" == "passed" ]]; then
      sc="${sc}${check_mark} Verification: passed"
      if [[ -n "${last_verify_cmd}" ]]; then
        sc="${sc} (${last_verify_cmd})"
      fi
      if [[ -n "${verify_confidence}" && "${verify_confidence}" -lt 50 ]]; then
        sc="${sc} [low confidence: ${verify_confidence}%]"
      fi
    else
      sc="${sc}${cross_mark} Verification: FAILED"
      [[ -n "${last_verify_cmd}" ]] && sc="${sc} (${last_verify_cmd})"
    fi
  else
    sc="${sc}${cross_mark} Verification: not run"
  fi
  sc="${sc}\n"

  # Review status
  local last_review_ts review_had_findings
  last_review_ts="$(read_state "last_review_ts")"
  review_had_findings="$(read_state "review_had_findings")"

  if [[ -n "${last_review_ts}" ]]; then
    if [[ "${review_had_findings}" == "true" ]]; then
      sc="${sc}${cross_mark} Code review: findings reported"
    else
      sc="${sc}${check_mark} Code review: clean"
    fi
  else
    sc="${sc}${cross_mark} Code review: not run"
  fi
  sc="${sc}\n"

  # Dimension status
  local required_dims
  required_dims="$(get_required_dimensions 2>/dev/null || true)"
  if [[ -n "${required_dims}" ]]; then
    local _dim _dim_ts _dim_label _dim_verdict
    for _dim in ${required_dims//,/ }; do
      _dim_ts="$(read_state "$(_dim_key "${_dim}")")"
      _dim_verdict="$(read_state "dim_${_dim}_verdict")"
      _dim_label="$(describe_dimension "${_dim}" 2>/dev/null || printf '%s' "${_dim}")"
      if is_dimension_valid "${_dim}"; then
        sc="${sc}${check_mark} ${_dim_label}\n"
      elif [[ "${_dim_verdict}" == "FINDINGS" ]]; then
        sc="${sc}${cross_mark} ${_dim_label}: findings reported\n"
      elif [[ -n "${_dim_ts}" ]]; then
        sc="${sc}${cross_mark} ${_dim_label}: stale after subsequent edits\n"
      else
        sc="${sc}${dash_mark} ${_dim_label}: skipped\n"
      fi
    done
  fi

  # Excellence review
  local last_excellence_ts
  last_excellence_ts="$(read_state "last_excellence_review_ts")"
  if [[ -n "${last_excellence_ts}" ]]; then
    sc="${sc}${check_mark} Excellence review: done\n"
  fi

  printf '%b' "${sc}"
}

# --- end quality scorecard ---

# --- Agent performance metrics (cross-session) ---
# Stored in ~/.claude/quality-pack/agent-metrics.json
# Structure: { "agent_name": { "invocations": N, "clean_verdicts": N,
#   "finding_verdicts": N, "last_used_ts": N, "avg_confidence": N } }

_AGENT_METRICS_FILE="${HOME}/.claude/quality-pack/agent-metrics.json"
_AGENT_METRICS_LOCK="${HOME}/.claude/quality-pack/.agent-metrics.lock"

# with_metrics_lock: Run a command under the agent metrics file lock.
with_metrics_lock() {
  local max_attempts=100
  local attempt=0
  local acquired=0
  while ! mkdir "${_AGENT_METRICS_LOCK}" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      # Stale lock recovery — remove and re-acquire
      rmdir "${_AGENT_METRICS_LOCK}" 2>/dev/null || true
      if mkdir "${_AGENT_METRICS_LOCK}" 2>/dev/null; then
        acquired=1
      fi
      break
    fi
    sleep 0.05
  done
  if [[ "${acquired}" -eq 0 && "${attempt}" -lt "${max_attempts}" ]]; then
    acquired=1
  fi
  if [[ "${acquired}" -eq 0 ]]; then
    log_hook "with_metrics_lock" "WARNING: lock not acquired after ${max_attempts} attempts, proceeding unprotected"
  fi
  "$@"
  local rc=$?
  if [[ "${acquired}" -eq 1 ]]; then
    rmdir "${_AGENT_METRICS_LOCK}" 2>/dev/null || true
  fi
  return "${rc}"
}

# record_agent_metric: Record an agent invocation outcome.
# Usage: record_agent_metric <agent_name> <verdict> [confidence]
# verdict: "clean" or "findings"
record_agent_metric() {
  local agent_name="$1"
  local verdict="$2"
  local confidence="${3:-0}"
  # Sanitize confidence input (may be float or non-numeric)
  confidence="${confidence%%.*}"; confidence="${confidence//[!0-9]/}"; confidence="${confidence:-0}"

  [[ -z "${agent_name}" ]] && return 0

  _do_record_metric() {
    local metrics_file="${_AGENT_METRICS_FILE}"
    local now_ts
    now_ts="$(now_epoch)"

    # Initialize if missing
    if [[ ! -f "${metrics_file}" ]]; then
      printf '{}' > "${metrics_file}"
    fi

    local current
    current="$(jq -c --arg a "${agent_name}" '.[$a] // {invocations:0, clean_verdicts:0, finding_verdicts:0, last_used_ts:0, avg_confidence:0}' "${metrics_file}" 2>/dev/null || printf '{"invocations":0,"clean_verdicts":0,"finding_verdicts":0,"last_used_ts":0,"avg_confidence":0}')"

    local invocations clean_v finding_v avg_conf
    invocations="$(jq -r '.invocations' <<<"${current}")"
    clean_v="$(jq -r '.clean_verdicts' <<<"${current}")"
    finding_v="$(jq -r '.finding_verdicts' <<<"${current}")"
    avg_conf="$(jq -r '.avg_confidence' <<<"${current}")"

    # Sanitize to integers (jq may return floats or null)
    invocations="${invocations%%.*}"; invocations="${invocations//[!0-9]/}"; invocations="${invocations:-0}"
    clean_v="${clean_v%%.*}"; clean_v="${clean_v//[!0-9]/}"; clean_v="${clean_v:-0}"
    finding_v="${finding_v%%.*}"; finding_v="${finding_v//[!0-9]/}"; finding_v="${finding_v:-0}"
    avg_conf="${avg_conf%%.*}"; avg_conf="${avg_conf//[!0-9]/}"; avg_conf="${avg_conf:-0}"

    invocations=$((invocations + 1))
    if [[ "${verdict}" == "clean" ]]; then
      clean_v=$((clean_v + 1))
    else
      finding_v=$((finding_v + 1))
    fi

    # Rolling average confidence
    if [[ "${confidence}" -gt 0 && "${invocations}" -gt 0 ]]; then
      avg_conf="$(( (avg_conf * (invocations - 1) + confidence) / invocations ))"
    fi

    local tmp_file
    tmp_file="$(mktemp "${metrics_file}.XXXXXX")"
    jq --arg a "${agent_name}" \
       --argjson inv "${invocations}" \
       --argjson cv "${clean_v}" \
       --argjson fv "${finding_v}" \
       --argjson ts "${now_ts}" \
       --argjson ac "${avg_conf}" \
       --arg pid "$(_omc_project_id 2>/dev/null || echo "unknown")" \
       '.[$a] = {invocations:$inv, clean_verdicts:$cv, finding_verdicts:$fv, last_used_ts:$ts, avg_confidence:$ac, last_project_id:$pid} | ._schema_version = 2' \
       "${metrics_file}" > "${tmp_file}" 2>/dev/null
    if ! mv "${tmp_file}" "${metrics_file}" 2>/dev/null; then
      rm -f "${tmp_file}"
    fi
  }

  with_metrics_lock _do_record_metric
}

# read_agent_metric: Read metrics for a specific agent.
# Returns JSON object on stdout, empty if no data.
read_agent_metric() {
  local agent_name="$1"
  [[ -f "${_AGENT_METRICS_FILE}" ]] || return 0
  jq -c --arg a "${agent_name}" '.[$a] // empty' "${_AGENT_METRICS_FILE}" 2>/dev/null || true
}

# get_all_agent_metrics: Return all agent metrics as JSON.
get_all_agent_metrics() {
  [[ -f "${_AGENT_METRICS_FILE}" ]] || { printf '{}'; return; }
  cat "${_AGENT_METRICS_FILE}" 2>/dev/null || printf '{}'
}

# --- end agent metrics ---

# --- Cross-session learning: defect pattern tracking ---
# Stored in ~/.claude/quality-pack/defect-patterns.json
# Structure: { "category": { "count": N, "last_seen_ts": N, "examples": ["desc1", ...] } }
# Categories: missing_test, type_error, null_check, edge_case, race_condition,
#   api_contract, error_handling, security, performance, docs_stale, style

_DEFECT_PATTERNS_FILE="${HOME}/.claude/quality-pack/defect-patterns.json"
_DEFECT_PATTERNS_LOCK="${HOME}/.claude/quality-pack/.defect-patterns.lock"

# with_defect_lock: Run a command under the defect patterns file lock.
# Separate from with_metrics_lock to avoid unnecessary contention.
with_defect_lock() {
  local max_attempts=100
  local attempt=0
  local acquired=0
  while ! mkdir "${_DEFECT_PATTERNS_LOCK}" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      rmdir "${_DEFECT_PATTERNS_LOCK}" 2>/dev/null || true
      if mkdir "${_DEFECT_PATTERNS_LOCK}" 2>/dev/null; then
        acquired=1
      fi
      break
    fi
    sleep 0.05
  done
  if [[ "${acquired}" -eq 0 && "${attempt}" -lt "${max_attempts}" ]]; then
    acquired=1
  fi
  if [[ "${acquired}" -eq 0 ]]; then
    log_hook "with_defect_lock" "WARNING: lock not acquired after ${max_attempts} attempts, proceeding unprotected"
  fi
  "$@"
  local rc=$?
  if [[ "${acquired}" -eq 1 ]]; then
    rmdir "${_DEFECT_PATTERNS_LOCK}" 2>/dev/null || true
  fi
  return "${rc}"
}

# _ensure_valid_defect_patterns: Validate and recover the defect-patterns file.
# If the file exists but is not valid JSON, archive it and reset to empty object.
# Uses a per-process cache to avoid re-validating on every call.
_defect_patterns_validated=0

_ensure_valid_defect_patterns() {
  [[ "${_defect_patterns_validated}" -eq 1 ]] && return 0
  _defect_patterns_validated=1
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  if ! jq empty "${_DEFECT_PATTERNS_FILE}" 2>/dev/null; then
    local archive
    archive="${_DEFECT_PATTERNS_FILE}.corrupt.$(date +%s)"
    cp "${_DEFECT_PATTERNS_FILE}" "${archive}" 2>/dev/null || true
    printf '{}' > "${_DEFECT_PATTERNS_FILE}"
    log_hook "common" "defect-patterns.json was corrupt, archived to ${archive}, reset to {}"
  fi
}

# classify_finding_category: Classify a finding description into a defect category.
# Usage: classify_finding_category "description text"
# Returns: category string on stdout
classify_finding_category() {
  local desc
  desc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${desc}" ]] && { printf 'unknown'; return; }

  # Order matters — most specific first. Word boundaries (\b) prevent
  # collision on common words (e.g., "atomic" in "atomic CSS", "error" in
  # any finding description).
  if printf '%s' "${desc}" | grep -Eq '\b(race.?condition|concurrent|deadlock|mutex|data.?race)\b'; then
    printf 'race_condition'
  elif printf '%s' "${desc}" | grep -Eq '\b(missing.?test|no.?test|untested|test.?coverage|add.?test|no.*(unit|integration)?\s*tests?)\b|\b(tests?|spec|assert|coverage)\b'; then
    printf 'missing_test'
  elif printf '%s' "${desc}" | grep -Eq '\btype.?error\b|typescript|cast|coercion|\bNaN\b|type.?mismatch'; then
    printf 'type_error'
  elif printf '%s' "${desc}" | grep -Eq '\b(null|undefined|nil)\b.*(check|guard|safe|handle)|null.?pointer|optional.?chain'; then
    printf 'null_check'
  elif printf '%s' "${desc}" | grep -Eq '\b(edge.?case|boundary|overflow|underflow|off.by|corner.?case)\b'; then
    printf 'edge_case'
  elif printf '%s' "${desc}" | grep -Eq '\b(api|contract|schema|endpoint|payload|response).*(mismatch|break|invalid|missing)\b|\bapi\b.*\b(contract|schema)\b'; then
    printf 'api_contract'
  elif printf '%s' "${desc}" | grep -Eq '\b(unhandled|uncaught|missing).*(error|exception)\b|error.?handling|catch.*(missing|empty)|panic|abort'; then
    printf 'error_handling'
  elif printf '%s' "${desc}" | grep -Eq 'secur|auth|inject|xss|csrf|sanitiz|escap|vuln|credential|token'; then
    printf 'security'
  elif printf '%s' "${desc}" | grep -Eq 'perform|\bperf\b|slow|memory|leak|cache|optimi|latency|O\(n'; then
    printf 'performance'
  elif printf '%s' "${desc}" | grep -Eq 'visual.?design|design.?quality|gradient|palette|generic.*ui|cookie.cutter|typograph|aesthetic|spacing.*layout|color.*scheme|design.?system|design.?token|symmetrical|\btemplated\b|feature.?cards|identical.?cards|uniform.*padding|uniform.*spacing|visual.*signature|hero.*cta|cta.*hero|framework.*default|stock.?illustrat|saas.*landing'; then
    printf 'design_issues'
  elif printf '%s' "${desc}" | grep -Eq 'accessib|a11y|aria|alt.text|screen.reader|keyboard.nav|contrast.ratio|wcag|focus.ring|tab.order'; then
    printf 'accessibility'
  elif printf '%s' "${desc}" | grep -Eq 'doc|readme|comment|stale|outdated|changelog'; then
    printf 'docs_stale'
  elif printf '%s' "${desc}" | grep -Eq 'style|format|lint|naming|convention|indent'; then
    printf 'style'
  else
    printf 'unknown'
  fi
}

# record_defect_pattern: Record a defect pattern for cross-session learning.
# Usage: record_defect_pattern <category> [example_description]
record_defect_pattern() {
  local category="${1:-unknown}"
  local example="${2:-}"

  _do_record_defect() {
    local pf="${_DEFECT_PATTERNS_FILE}"
    local now_ts
    now_ts="$(now_epoch)"

    if [[ ! -f "${pf}" ]]; then
      mkdir -p "$(dirname "${pf}")"
      printf '{}' > "${pf}"
    else
      _ensure_valid_defect_patterns
    fi

    local current
    current="$(jq -c --arg c "${category}" '.[$c] // {count:0, last_seen_ts:0, examples:[]}' "${pf}" 2>/dev/null || printf '{"count":0,"last_seen_ts":0,"examples":[]}')"

    local count
    count="$(jq -r '.count' <<<"${current}")"
    count=$((count + 1))

    local tmp_file
    tmp_file="$(mktemp "${pf}.XXXXXX")"
    if [[ -n "${example}" ]]; then
      # Keep at most 5 recent examples per category
      local _pid
      _pid="$(_omc_project_id 2>/dev/null || echo "unknown")"
      jq --arg c "${category}" \
         --argjson cnt "${count}" \
         --argjson ts "${now_ts}" \
         --arg ex "${example}" \
         --arg pid "${_pid}" \
         '.[$c] = (.[$c] // {count:0,last_seen_ts:0,examples:[]}) |
          .[$c].count = $cnt |
          .[$c].last_seen_ts = $ts |
          .[$c].last_project_id = $pid |
          .[$c].examples = ((.[$c].examples + [$ex]) | .[-5:]) |
          ._schema_version = 2' \
         "${pf}" > "${tmp_file}" 2>/dev/null
      if ! mv "${tmp_file}" "${pf}" 2>/dev/null; then
        rm -f "${tmp_file}"
      fi
    else
      jq --arg c "${category}" \
         --argjson cnt "${count}" \
         --argjson ts "${now_ts}" \
         '.[$c] = (.[$c] // {count:0,last_seen_ts:0,examples:[]}) |
          .[$c].count = $cnt |
          .[$c].last_seen_ts = $ts' \
         "${pf}" > "${tmp_file}" 2>/dev/null
      if ! mv "${tmp_file}" "${pf}" 2>/dev/null; then
        rm -f "${tmp_file}"
      fi
    fi
  }

  with_defect_lock _do_record_defect
}

# get_top_defect_patterns: Return the top N defect categories by frequency,
# filtered to patterns seen within the last 90 days.
# Usage: get_top_defect_patterns [n] — defaults to 3
# Returns: newline-separated "category (count)" strings on stdout
get_top_defect_patterns() {
  local n="${1:-3}"
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  _ensure_valid_defect_patterns
  local cutoff_ts
  cutoff_ts="$(( $(now_epoch) - 90 * 86400 ))"
  jq -r --argjson n "${n}" --argjson cutoff "${cutoff_ts}" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    .[0:$n] |
    .[] | "\(.key) (\(.value.count))"
  ' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null || true
}

# get_defect_watch_list: Return an actionable watch-list string for injection
# into prompts. Includes concrete examples from past findings so the model
# understands WHAT to watch for, not just abstract category names.
# Filters out patterns not seen in the last 90 days.
# Usage: get_defect_watch_list [n] — defaults to 3
get_defect_watch_list() {
  local n="${1:-3}"
  [[ -f "${_DEFECT_PATTERNS_FILE}" ]] || return 0
  _ensure_valid_defect_patterns
  local list
  list="$(jq -r --argjson n "${n}" --argjson cutoff "$(( $(now_epoch) - 90 * 86400 ))" '
    to_entries |
    map(select(.key | startswith("_") | not)) |
    map(select(.value | type == "object")) |
    map(select(.value.last_seen_ts > $cutoff)) |
    sort_by(-.value.count) |
    .[0:$n] |
    map(
      .key + " ×" + (.value.count | tostring) +
      if ((.value.examples // []) | length) > 0
      then " (e.g. \"" + ((.value.examples // [])[-1] | .[0:80]) + "\")"
      else ""
      end
    ) |
    join("; ")
  ' "${_DEFECT_PATTERNS_FILE}" 2>/dev/null || true)"
  [[ -n "${list}" ]] && printf 'Watch for: %s' "${list}" || true
}

# --- end cross-session learning ---

# --- Gate skip tracking ---
#
# Records gate skips to a JSONL file for threshold tuning analysis.
# Called in the background from stop-guard.sh when a /ulw-skip is honored.

_GATE_SKIPS_FILE="${HOME}/.claude/quality-pack/gate-skips.jsonl"
_GATE_SKIPS_LOCK="${HOME}/.claude/quality-pack/.gate-skips.lock"

with_skips_lock() {
  local lockdir="${_GATE_SKIPS_LOCK}"
  local attempts=0
  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then break; fi
    attempts=$((attempts + 1))
    # Time-based stale-lock recovery (same pattern as with_state_lock)
    if [[ -d "${lockdir}" ]]; then
      local _now _held
      _now="$(date +%s)"
      _held="$(_lock_mtime "${lockdir}")"
      if [[ "${_held}" -gt 0 ]] \
          && [[ $(( _now - _held )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
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

record_gate_skip() {
  local reason="${1:-}"

  _do_record_skip() {
    local skip_file="${_GATE_SKIPS_FILE}"
    mkdir -p "$(dirname "${skip_file}")"
    local ts
    ts="$(now_epoch)"
    local pid
    pid="$(_omc_project_id 2>/dev/null || echo "unknown")"
    jq -nc --arg reason "${reason}" --argjson ts "${ts}" --arg project "${pid}" \
      '{ts:$ts,reason:$reason,project:$project}' >> "${skip_file}" 2>/dev/null || true
    # Cap at 200 lines
    local _lines
    _lines="$(wc -l < "${skip_file}" 2>/dev/null || echo 0)"
    _lines="${_lines##* }"
    if [[ "${_lines}" -gt 200 ]]; then
      local _temp
      _temp="$(mktemp "${skip_file}.XXXXXX")"
      if tail -n 150 "${skip_file}" > "${_temp}" 2>/dev/null; then
        mv "${_temp}" "${skip_file}"
      else
        rm -f "${_temp}"
      fi
    fi
  }

  with_skips_lock _do_record_skip
}

# --- end gate skip tracking ---

# --- Project identity ---
#
# Generates a short hash of $PWD for use in cross-session data stores.
# Allows filtering cross-session metrics by project without storing full paths.

_omc_project_id() {
  printf '%s' "${PWD}" | shasum -a 256 2>/dev/null | cut -c1-12
}

# --- end project identity ---

# --- Project profile detection ---

# detect_project_profile: Scan the project directory for stack indicators.
# Returns a comma-separated list of stack tags on stdout, e.g.:
#   "node,typescript,react,tailwind"
# Used to boost domain scoring and inform dimension ordering.
# Result is cached in session state as "project_profile".
detect_project_profile() {
  local project_dir="${1:-.}"
  local tags=""

  _add_tag() { tags="${tags:+${tags},}$1"; }

  # Node.js ecosystem
  [[ -f "${project_dir}/package.json" ]] && _add_tag "node"
  [[ -f "${project_dir}/tsconfig.json" ]] && _add_tag "typescript"
  [[ -f "${project_dir}/bun.lockb" ]] && _add_tag "bun"

  # Frontend frameworks (check package.json dependencies)
  if [[ -f "${project_dir}/package.json" ]]; then
    local deps
    deps="$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "${project_dir}/package.json" 2>/dev/null || true)"
    if [[ -n "${deps}" ]]; then
      printf '%s' "${deps}" | grep -q '^react$' && _add_tag "react"
      printf '%s' "${deps}" | grep -q '^vue$' && _add_tag "vue"
      printf '%s' "${deps}" | grep -q '^svelte$' && _add_tag "svelte"
      printf '%s' "${deps}" | grep -q '^next$' && _add_tag "next"
      printf '%s' "${deps}" | grep -q '^nuxt$' && _add_tag "nuxt"
      printf '%s' "${deps}" | grep -q '^tailwindcss$' && _add_tag "tailwind"
      printf '%s' "${deps}" | grep -qE '^(vitest|jest|mocha)$' && _add_tag "js-test"
    fi
  fi

  # Python ecosystem
  [[ -f "${project_dir}/pyproject.toml" ]] && _add_tag "python"
  [[ -f "${project_dir}/setup.py" ]] && _add_tag "python"
  [[ -f "${project_dir}/requirements.txt" ]] && _add_tag "python"

  # Rust
  [[ -f "${project_dir}/Cargo.toml" ]] && _add_tag "rust"

  # Go
  [[ -f "${project_dir}/go.mod" ]] && _add_tag "go"

  # Ruby
  [[ -f "${project_dir}/Gemfile" ]] && _add_tag "ruby"

  # Elixir
  [[ -f "${project_dir}/mix.exs" ]] && _add_tag "elixir"

  # Swift / iOS
  if ls "${project_dir}"/*.xcodeproj &>/dev/null 2>&1 || ls "${project_dir}"/*.xcworkspace &>/dev/null 2>&1 \
    || [[ -f "${project_dir}/Package.swift" ]]; then
    _add_tag "swift"
  fi

  # Docker / Infrastructure
  if [[ -f "${project_dir}/Dockerfile" ]] || [[ -f "${project_dir}/docker-compose.yml" ]] \
    || [[ -f "${project_dir}/docker-compose.yaml" ]]; then
    _add_tag "docker"
  fi
  if [[ -d "${project_dir}/terraform" ]] || [[ -f "${project_dir}/main.tf" ]]; then
    _add_tag "terraform"
  fi
  if [[ -f "${project_dir}/ansible.cfg" ]] || [[ -d "${project_dir}/playbooks" ]]; then
    _add_tag "ansible"
  fi

  # Shell-heavy projects
  local sh_count=0
  sh_count="$(find "${project_dir}" -maxdepth 2 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "${sh_count}" -ge 3 ]] && _add_tag "shell"

  # Documentation-heavy (README, docs/)
  [[ -d "${project_dir}/docs" ]] && _add_tag "docs"

  # UI presence indicators
  if [[ -d "${project_dir}/src/components" ]] \
    || [[ -d "${project_dir}/app/components" ]] \
    || [[ -d "${project_dir}/components" ]] \
    || ls "${project_dir}"/src/**/*.css &>/dev/null 2>&1 \
    || ls "${project_dir}"/src/**/*.scss &>/dev/null 2>&1; then
    _add_tag "ui"
  fi

  printf '%s' "${tags}"
}

# get_project_profile: Cached wrapper around detect_project_profile.
# Reads from session state first; if missing, detects and caches.
get_project_profile() {
  local cached
  cached="$(read_state "project_profile" 2>/dev/null || true)"
  if [[ -n "${cached}" ]]; then
    printf '%s' "${cached}"
    return
  fi

  local profile
  profile="$(detect_project_profile "." 2>/dev/null || true)"
  if [[ -n "${profile}" ]]; then
    with_state_lock write_state "project_profile" "${profile}"
  fi
  printf '%s' "${profile}"
}

# project_profile_has: Check if a project profile contains a specific tag.
# Usage: project_profile_has "react" "$profile" && ...
project_profile_has() {
  local tag="$1"
  local profile="${2:-}"
  [[ ",${profile}," == *",${tag},"* ]]
}

# --- end project profile ---

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

is_ui_request() {
  local text="$1"
  [[ -z "${text}" ]] && return 1

  # Split UI detection from domain scoring. The router needs to spot common
  # frontend asks ("create a login page", "style an empty state") without
  # turning design-analysis or writing prompts into coding work.
  local structural_ui_actions
  local qualified_form_actions
  local visual_ui_actions
  local motion_ui_actions
  local explicit_ui_terms

  structural_ui_actions='\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|dashboards?|screens?|modals?|dialogs?|drawers?|heroes?|nav(igation|bar)?|sidebars?|headers?|footers?|menus?|tabs?|panels?|layouts?|components?|empty.?states?|tables?|charts?|filters?|accordions?|wizards?|steppers?|banners?)\b'
  qualified_form_actions='\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(login|signup|sign[- ]?up|sign[- ]?in|checkout|contact|search|settings|profile|feedback|payment|registration|onboarding|responsive)\s+forms?\b'
  visual_ui_actions='\b(design(ing)?|style|styl(e|ing)|redesign(ing)?|restyle|theme)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|forms?|buttons?|cards?|modals?|dialogs?|drawers?|dropdowns?|nav(igation|bar)?|sidebars?|headers?|footers?|heroes?|layouts?|components?|interfaces?|screens?|dashboards?|sections?|menus?|tabs?|panels?|empty.?states?|tables?|charts?|filters?|banners?|tooltips?|toasts?)\b'
  motion_ui_actions='\b(add(ing)?|create|creat(e|ing)|build(ing)?|make|implement(ing)?|update(ing)?)\s+(a\s+|an\s+|the\s+|some\s+|subtle\s+|micro\s+)?animations?\s+(to|for|on|in)\s+(the\s+|a\s+|an\s+|this\s+|that\s+|my\s+|our\s+)?(\w+\s+){0,2}(heroes?|nav(igation|bar)?|sidebars?|buttons?|cards?|modals?|menus?|tabs?|panels?|pages?|screens?|components?|sections?)\b'
  explicit_ui_terms='\b(landing.?page|modal|navbar|sidebar|tailwind|ui|ux)\b'

  if grep -Eiq "${structural_ui_actions}" <<<"${text}" \
    || grep -Eiq "${qualified_form_actions}" <<<"${text}" \
    || grep -Eiq "${visual_ui_actions}" <<<"${text}" \
    || grep -Eiq "${motion_ui_actions}" <<<"${text}" \
    || grep -Eiq "${explicit_ui_terms}" <<<"${text}"; then
    return 0
  fi

  return 1
}

infer_domain() {
  local text="$1"
  local project_profile="${2:-}"

  local coding_score
  local writing_score
  local research_score
  local operations_score

  # --- Bigram matching: compound phrases that disambiguate domain ---
  # Action + coding-object → strong coding signal
  local coding_bigrams
  coding_bigrams=$(count_keyword_matches '\b(writ(e|ing)|add(ing)?|creat(e|ing)|run(ning)?|fix(ing)?|updat(e|ing))\s+((unit|integration|e2e|end.to.end|acceptance)\s+)?(tests?|test\s*suites?|specs?|code|functions?|class(es)?|components?|endpoints?|modules?|handlers?|middleware|routes?|migrations?|schemas?)\b' "${text}")
  coding_bigrams=${coding_bigrams:-0}

  # Action + user-facing UI-object → coding signal.
  local ui_bigrams
  ui_bigrams=$(count_keyword_matches '\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(landing.?pages?|home.?pages?|pages?|dashboards?|screens?|modals?|dialogs?|drawers?|heroes?|nav(igation|bar)?|sidebars?|headers?|footers?|menus?|tabs?|panels?|layouts?|components?|empty.?states?|tables?|charts?|filters?|accordions?|wizards?|steppers?|banners?)\b' "${text}")
  ui_bigrams=${ui_bigrams:-0}
  coding_bigrams=$((coding_bigrams + ui_bigrams))

  # Form-building prompts are common UI work, but "form" alone is too
  # ambiguous, so require a UI-ish qualifier.
  local form_bigrams
  form_bigrams=$(count_keyword_matches '\b(build(ing)?|create|creat(e|ing)|add(ing)?|make|implement(ing)?|update(ing)?|fix(ing)?|refactor(ing)?)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(login|signup|sign[- ]?up|sign[- ]?in|checkout|contact|search|settings|profile|feedback|payment|registration|onboarding|responsive)\s+forms?\b' "${text}")
  form_bigrams=${form_bigrams:-0}
  coding_bigrams=$((coding_bigrams + form_bigrams))

  local motion_bigrams
  motion_bigrams=$(count_keyword_matches '\b(add(ing)?|create|creat(e|ing)|build(ing)?|make|implement(ing)?|update(ing)?)\s+(a\s+|an\s+|the\s+|some\s+|subtle\s+|micro\s+)?animations?\s+(to|for|on|in)\s+(the\s+|a\s+|an\s+|this\s+|that\s+|my\s+|our\s+)?(\w+\s+){0,2}(heroes?|nav(igation|bar)?|sidebars?|buttons?|cards?|modals?|menus?|tabs?|panels?|pages?|screens?|components?|sections?)\b' "${text}")
  motion_bigrams=${motion_bigrams:-0}
  coding_bigrams=$((coding_bigrams + motion_bigrams))

  # Design/style + UI-object → coding signal (not general)
  local design_bigrams
  design_bigrams=$(count_keyword_matches '\b(design(ing)?|style|styl(e|ing)|redesign(ing)?|restyle|theme)\s+(a\s+|an\s+|the\s+|this\s+|that\s+|these\s+|those\s+|my\s+|our\s+)?(\w+\s+){0,2}(pages?|forms?|buttons?|cards?|modals?|dialogs?|drawers?|dropdowns?|nav(igation|bar)?|sidebars?|headers?|footers?|heroes?|layouts?|components?|interfaces?|screens?|dashboards?|landing.?pages?|sections?|menus?|tabs?|panels?|empty.?states?|tables?|charts?|filters?)\b' "${text}")
  design_bigrams=${design_bigrams:-0}
  coding_bigrams=$((coding_bigrams + design_bigrams))

  # Action + writing-object → writing signal
  local writing_bigrams
  writing_bigrams=$(count_keyword_matches '\b(writ(e|ing)|draft(ing)?|compos(e|ing)|author(ing)?)\s+(papers?|essays?|reports?|emails?|memos?|articles?|letters?|proposals?|manuscripts?|blogs?\s*posts?)\b' "${text}")
  writing_bigrams=${writing_bigrams:-0}
  local writing_topic_bigrams
  writing_topic_bigrams=$(count_keyword_matches '\b(writ(e|ing)|draft(ing)?|compos(e|ing)|author(ing)?)\s+(about|on)\b' "${text}")
  writing_topic_bigrams=${writing_topic_bigrams:-0}
  writing_bigrams=$((writing_bigrams + writing_topic_bigrams))

  # Action + research-object → research signal
  local research_bigrams
  research_bigrams=$(count_keyword_matches '\b(investigate|research|compare|analy[zs]e|evaluat(e|ing))\s+(why|how|whether|alternatives?|options?|approaches?|strategies?|tools?|frameworks?|solutions?|vendors?|platforms?)\b' "${text}")
  research_bigrams=${research_bigrams:-0}
  local research_topic_bigrams
  research_topic_bigrams=$(count_keyword_matches '\b(find|gather|collect)\s+(data|evidence|sources|information|references?)\s+(on|about|for|regarding)\b' "${text}")
  research_topic_bigrams=${research_topic_bigrams:-0}
  research_bigrams=$((research_bigrams + research_topic_bigrams))

  # Action + operations-object → operations signal
  local operations_bigrams
  operations_bigrams=$(count_keyword_matches '\b(plan|create|build|draft|prepare|make)\s+(a\s+|an\s+|the\s+|my\s+|our\s+)?(project\s+plan|roadmap|timeline|agenda|checklist|action.?plan|schedule|rollout|migration\s+plan|deployment\s+plan|release\s+plan|sprint\s+plan|backlog|kanban|standup|retro)\b' "${text}")
  operations_bigrams=${operations_bigrams:-0}
  local operations_action_bigrams
  operations_action_bigrams=$(count_keyword_matches '\b(turn|convert|transform)\s+.{0,30}\s+(into|to)\s+(a\s+|an\s+)?(action.?plan|checklist|task.?list|follow.?up|decision|memo)\b' "${text}")
  operations_action_bigrams=${operations_action_bigrams:-0}
  operations_bigrams=$((operations_bigrams + operations_action_bigrams))

  # --- Negative keywords: subtract false positives ---
  # "report" after bug/error/test/crash → coding context, not writing
  # "post" in HTTP context → not writing
  local writing_negatives
  writing_negatives=$(count_keyword_matches '\b(bug|error|test|crash|status|coverage)\s+reports?\b|\bpost\s+(requests?|endpoints?|methods?|routes?|data)\b' "${text}")
  writing_negatives=${writing_negatives:-0}

  # --- Unigram scoring ---
  local coding_strong
  coding_strong=$(count_keyword_matches '\b(bugs?|fix(es|ed|ing)?|debug(ging)?|refactor(ing)?|implement(ation|ed|ing)?|repos?(itory)?|function|class(es)?|component|endpoints?|apis?|schema|database|quer(y|ies)|migration|lint(ing)?|compile|tsc|typescript|javascript|python|swift|xcode|react|next\.?js|css|html|webhooks?|codebase|source.?code|ci/?cd|docker|container|backend|frontend|fullstack|tailwind|vue(\.?js)?|angular|svelte)\b' "${text}")
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

  research_score=$(count_keyword_matches '\b(research(ing)?|investigate|investigation|analy(sis|ze|zing)|compare|comparison|survey|literature|sources|citations?|references?|benchmark(ing)?|brief(ing)?|recommendations?|summarize|summary|pros.?and.?cons|tradeoffs?|audit(ing)?|assess(ment|ing)?|evaluat(e|ion|ing)|inspect(ion|ing)?)\b' "${text}")
  research_score=$(( ${research_score:-0} + research_bigrams ))

  operations_score=$(count_keyword_matches '\b(plan(ning)?|roadmap|timeline|agenda|meeting|follow[- ]?up|checklist|prioriti(es|se|ze)|project.?plan|travel.?plan|itinerary|reply(ing)?|respond(ing)?|application|submission)\b' "${text}")
  operations_score=$(( ${operations_score:-0} + operations_bigrams ))

  # Project profile boost: when a project has known stack indicators,
  # add a small bonus to coding (if the project is code-heavy) or writing
  # (if docs-heavy). This acts as a tiebreaker, not a dominant signal.
  if [[ -n "${project_profile}" ]]; then
    local _tag
    local code_boost=0
    for _tag in node typescript python rust go ruby elixir swift react vue svelte next bun shell; do
      if project_profile_has "${_tag}" "${project_profile}"; then
        code_boost=$((code_boost + 1))
      fi
    done
    # Cap boost at 2 to prevent project-type from overriding clear intent
    if [[ "${code_boost}" -gt 2 ]]; then code_boost=2; fi
    coding_score=$((coding_score + code_boost))

    if project_profile_has "docs" "${project_profile}"; then
      writing_score=$((writing_score + 1))
    fi
  fi

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
