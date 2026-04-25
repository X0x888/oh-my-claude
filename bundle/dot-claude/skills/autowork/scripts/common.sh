#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
STATE_JSON="session_state.json"
HOOK_LOG="${STATE_ROOT}/hooks.log"

# Restrict file permissions for all state files, temp files, and logs.
# Session state contains user prompts and assistant messages — keep
# them owner-readable only, especially on shared systems.
umask 077

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
_omc_env_pretool_intent="${OMC_PRETOOL_INTENT_GUARD:-}"
_omc_env_classifier_tel="${OMC_CLASSIFIER_TELEMETRY:-}"
_omc_env_discovered_scope="${OMC_DISCOVERED_SCOPE:-}"
_omc_env_council_deep_default="${OMC_COUNCIL_DEEP_DEFAULT:-}"
_omc_env_auto_memory="${OMC_AUTO_MEMORY:-}"

OMC_STALL_THRESHOLD="${OMC_STALL_THRESHOLD:-12}"
OMC_EXCELLENCE_FILE_COUNT="${OMC_EXCELLENCE_FILE_COUNT:-3}"
OMC_STATE_TTL_DAYS="${OMC_STATE_TTL_DAYS:-7}"
OMC_DIMENSION_GATE_FILE_COUNT="${OMC_DIMENSION_GATE_FILE_COUNT:-3}"
OMC_TRACEABILITY_FILE_COUNT="${OMC_TRACEABILITY_FILE_COUNT:-6}"
# Guard exhaustion mode: scorecard (default, legacy: warn), block (legacy: strict), silent (legacy: release)
OMC_GUARD_EXHAUSTION_MODE="${OMC_GUARD_EXHAUSTION_MODE:-scorecard}"
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
# PreToolUse intent guard: when `true` (default), the guard denies destructive
# git/gh operations while task_intent is advisory/session-management/checkpoint.
# Set to `false` to disable enforcement and rely on the directive layer alone
# (e.g. for users who prefer the model to make its own judgement calls and
# accept the risk of the 2026-04-17-class incident).
OMC_PRETOOL_INTENT_GUARD="${OMC_PRETOOL_INTENT_GUARD:-true}"
# Classifier telemetry capture: when `on` (default), every UserPromptSubmit
# records a row to `<session>/classifier_telemetry.jsonl` and the follow-up
# prompt's hook may annotate misfire rows. The prompt preview (first 200
# chars) is captured. Set to `off` to disable all recording — useful for
# shared machines, regulated codebases, or any context where writing user
# prompt previews to disk is unwanted. Cross-session aggregation at TTL
# sweep also becomes a no-op because per-session files won't exist.
OMC_CLASSIFIER_TELEMETRY="${OMC_CLASSIFIER_TELEMETRY:-on}"
# Discovered-scope tracking: when `on` (default), advisory specialists
# (council lenses, metis, briefing-analyst) have their findings extracted
# and recorded to `<session>/discovered_scope.jsonl`. Stop-guard then
# blocks a session that captured findings but stops without addressing
# or deferring each one. Set to `off` to disable both capture and gate
# (kill switch) — useful when heuristic extraction proves noisy on a
# specific project's prose style.
OMC_DISCOVERED_SCOPE="${OMC_DISCOVERED_SCOPE:-on}"
# Council deep-default: when `on`, auto-triggered council dispatches (via the
# prompt-intent-router's `is_council_evaluation_request` detection) inherit
# the equivalent of `/council --deep` — lens dispatches get `model: "opus"`
# instead of the default `sonnet`. Default is `off` because opus per-lens is
# meaningfully more expensive; quality-first users on `model_tier=quality`
# are the typical opt-in. Explicit `/council --deep` invocations are
# unaffected by this flag (they always escalate). Direct `/council` without
# `--deep` also remains unchanged — only the AUTO-detected dispatch path
# (broad project-evaluation prompts under /ulw) is affected.
OMC_COUNCIL_DEEP_DEFAULT="${OMC_COUNCIL_DEEP_DEFAULT:-off}"
# Auto-memory wrap-up: when `on` (default), the auto-memory.md and
# compact.md memory-sweep rules write project_*/feedback_*/user_*/
# reference_*.md files at session-stop and pre-compact moments. Set to
# `off` for shared machines, regulated codebases, or projects where
# session memory should not accrue across runs. Explicit user requests
# ("remember that...") still apply regardless of this flag.
OMC_AUTO_MEMORY="${OMC_AUTO_MEMORY:-on}"

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
      pretool_intent_guard)
        [[ -z "${_omc_env_pretool_intent}" && "${value}" =~ ^(true|false)$ ]] && OMC_PRETOOL_INTENT_GUARD="${value}" || true ;;
      classifier_telemetry)
        [[ -z "${_omc_env_classifier_tel}" && "${value}" =~ ^(on|off)$ ]] && OMC_CLASSIFIER_TELEMETRY="${value}" || true ;;
      discovered_scope)
        [[ -z "${_omc_env_discovered_scope}" && "${value}" =~ ^(on|off)$ ]] && OMC_DISCOVERED_SCOPE="${value}" || true ;;
      council_deep_default)
        [[ -z "${_omc_env_council_deep_default}" && "${value}" =~ ^(on|off)$ ]] && OMC_COUNCIL_DEEP_DEFAULT="${value}" || true ;;
      auto_memory)
        [[ -z "${_omc_env_auto_memory}" && "${value}" =~ ^(on|off)$ ]] && OMC_AUTO_MEMORY="${value}" || true ;;
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

# Returns 0 (true) when auto-memory is enabled, 1 (false) when explicitly
# disabled via conf. The auto-memory.md and compact.md rules use this to
# decide whether to write memory at session-stop and pre-compact moments.
is_auto_memory_enabled() {
  [[ "${OMC_AUTO_MEMORY:-on}" != "off" ]]
}

# Hook logging — two channels, one file (${HOOK_LOG}).
#
#   log_anomaly  — always on. Use for rare warnings: state corruption,
#                  lock exhaustion, invalid session ids, schema drift.
#                  These are the events worth seeing in a bug report
#                  without asking the user to opt into a debug mode.
#                  Tagged `[anomaly]`.
#
#   log_hook     — debug-gated (hook_debug=true in oh-my-claude.conf
#                  or HOOK_DEBUG=1 env). Use for verbose per-hook
#                  traces ("mark-edit file=x is_doc=0"). Noisy in a
#                  long session, which is why it stays opt-in.
#                  Tagged `[debug]`.
#
# Both channels share the same rotation: truncate to 1500 lines once
# the log exceeds 2000, so the default-on anomaly channel cannot grow
# unbounded even on a machine where something misbehaves every session.
# Grep `[anomaly]` to see only warnings; `[debug]` for verbose traces.
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

_write_hook_log() {
  local tag="$1"
  local hook_name="${2:-unknown}"
  local detail="${3:-}"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "${STATE_ROOT}" 2>/dev/null || return 0
  printf '%s  [%s]  %s  %s\n' "${ts}" "${tag}" "${hook_name}" "${detail}" >>"${HOOK_LOG}" 2>/dev/null || return 0

  local _line_count
  _line_count="$(wc -l < "${HOOK_LOG}" 2>/dev/null || echo 0)"
  _line_count="${_line_count##* }"
  if [[ "${_line_count}" -gt 2000 ]]; then
    local _temp
    _temp="$(mktemp "${HOOK_LOG}.XXXXXX" 2>/dev/null)" || return 0
    if tail -n 1500 "${HOOK_LOG}" >"${_temp}" 2>/dev/null; then
      mv "${_temp}" "${HOOK_LOG}" 2>/dev/null || rm -f "${_temp}"
    else
      rm -f "${_temp}"
    fi
  fi
}

log_anomaly() {
  _write_hook_log "anomaly" "$@"
}

log_hook() {
  if is_hook_debug; then
    _write_hook_log "debug" "$@"
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

# state-io.sh provides ensure_session_dir, session_file, read_state,
# write_state, write_state_batch, append_state, append_limited_state,
# with_state_lock, and with_state_lock_batch. Sourced after
# validate_session_id and log_anomaly are defined (the lib calls
# both) so dependencies are in scope at source time.
#
# Resolve potentially-symlinked common.sh path so the lib loads from
# the real bundle location even when common.sh is symlinked (e.g.
# tests symlink common.sh to a temp HOME; users may symlink to custom
# locations). Portable readlink loop — works with BSD readlink (macOS)
# and GNU readlink (Linux) without depending on `realpath`.
_omc_resolve_path() {
  local p="$1"
  local i=0
  # Cap at 16 hops as a defense-in-depth bound against circular symlinks
  # (e.g. a → b → a). Real-world install layouts never hit this; the bound
  # exists so a malformed symlink can't cause a hook to spin indefinitely.
  while [[ -L "${p}" && "${i}" -lt 16 ]]; do
    local target
    target="$(readlink "${p}")"
    case "${target}" in
      /*) p="${target}" ;;
      *)  p="$(cd "$(dirname "${p}")" && pwd)/${target}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "${p}"
}
_omc_self="$(_omc_resolve_path "${BASH_SOURCE[0]}")"
_omc_self_dir="$(cd "$(dirname "${_omc_self}")" && pwd -P)"
source "${_omc_self_dir}/lib/state-io.sh"
# classifier.sh is sourced later (after its dependencies — project_profile_has,
# is_advisory_request, etc. — are defined). _omc_self_dir stays in scope until
# the bottom of this file, where every source statement has finished running.
unset -f _omc_resolve_path

now_epoch() {
  date +%s
}

# --- State directory TTL sweep ---
# Deletes session state dirs older than OMC_STATE_TTL_DAYS (default 7).
# Runs at most once per day, gated by a marker file timestamp.

# _cap_cross_session_jsonl <file> <cap> <retain>
# Caps a cross-session JSONL aggregate. No-op when the file is missing or
# at/below cap. On overflow, truncates to the last <retain> lines via
# atomic rename; on tail failure, leaves the original untouched.
#
# Concurrency: the cap itself is single-writer — every call site runs
# inside sweep_stale_sessions, which is gated by a daily marker file, so
# two cap operations cannot overlap. Writers to the underlying file
# (e.g. record-serendipity.sh) append unlocked, relying on POSIX line
# atomicity. The tail+mv window is the one race that exists: an in-flight
# append landing between tail and mv would be silently dropped. Cap fires
# at most once per 24h after overflow, so the realistic loss is ≤ one
# analytics row per cap-fire — acceptable for this data class.
_cap_cross_session_jsonl() {
  local file="$1" cap="$2" retain="$3"
  [[ -f "${file}" ]] || return 0
  local lines temp
  lines="$(wc -l < "${file}" 2>/dev/null || echo 0)"
  lines="${lines##* }"
  [[ "${lines}" -le "${cap}" ]] && return 0
  temp="$(mktemp "${file}.XXXXXX")" || return 0
  if tail -n "${retain}" "${file}" > "${temp}" 2>/dev/null; then
    mv "${temp}" "${file}"
  else
    rm -f "${temp}"
  fi
}

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
  local misfires_file="${HOME}/.claude/quality-pack/classifier_misfires.jsonl"

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
              dispatches: ((.subagent_dispatch_count // "0") | tonumber),
              outcome: (.session_outcome // "abandoned")
            }
          ' "${_sweep_state}" >> "${summary_file}" 2>/dev/null || true

          # Classifier telemetry: append this session's misfire rows to the
          # cross-session ledger. Tagged with session id so post-hoc
          # analysis can group by session, intent, reason, etc.
          local _sweep_telemetry="${_sweep_dir}/classifier_telemetry.jsonl"
          if [[ -f "${_sweep_telemetry}" ]]; then
            grep '"misfire":true' "${_sweep_telemetry}" 2>/dev/null | \
              jq -c --arg sid "${_sweep_sid}" '. + {session_id: $sid}' 2>/dev/null >> "${misfires_file}" || true
          fi
        fi
        rm -rf "${_sweep_dir}" 2>/dev/null || true
      done

    # Cross-session JSONL caps. Each session produces 0-few misfire rows;
    # session_summary gets one row per swept session; serendipity-log accrues
    # whenever the Serendipity Rule fires (rare). Caps are sized to the
    # respective row-rate and an O(years) horizon.
    _cap_cross_session_jsonl "${misfires_file}" 1000 800
    _cap_cross_session_jsonl "${summary_file}" 500 400
    _cap_cross_session_jsonl "${HOME}/.claude/quality-pack/serendipity-log.jsonl" 2000 1500
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
# "Primary task:" and the user's actual task, then a trailing skill-footer
# instruction. Classifying the full expansion misfires because embedded quoted
# content in the task body can trip SM/advisory regexes. This helper returns
# just the user's task body (between the head marker and the first known
# skill-footer), or exit 1 if the primary-task marker isn't present.
#
# The "Primary task:" marker must be line-anchored (preceded by a newline or at
# the very start of the text). Real skill bodies always put the marker on its
# own line; a mid-sentence mention like "the docs say Primary task: should..."
# would otherwise false-positive and extract the wrong slice of the prompt.
#
# Tail-marker list must cover every known ulw/autowork skill footer. Each
# marker is matched with a leading newline so a user task body that quotes the
# footer phrase mid-sentence does not get truncated prematurely. When the ulw
# or autowork SKILL.md footer text changes, add the new literal here so
# extraction stays aligned with the rendered skill body.
extract_skill_primary_task() {
  local text="$1"
  local head_marker='Primary task:'
  local tail_markers=(
    "Follow the \`/autowork\`"
    "Apply the autowork rules to the task above."
  )

  # Line-anchored marker check: either at the start of text, or after a newline.
  if [[ "${text}" != "${head_marker}"* ]] && [[ "${text}" != *$'\n'"${head_marker}"* ]]; then
    return 1
  fi

  local body="${text#*"${head_marker}"}"
  local tm anchored
  for tm in "${tail_markers[@]}"; do
    anchored=$'\n'"${tm}"
    body="${body%%"${anchored}"*}"
  done

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

# Return 0 if the prompt text contains a ULW activation trigger.
#
# The boundary class [^[:alnum:]_-] around each keyword prevents false
# positives on compound tokens like "ulwtastic" or "preulwalar". Because
# `-` is in that class, the bare `ulw` keyword cannot match `/ulw-demo`
# on its own — the `-` after `ulw` fails the right-boundary check — so
# `ulw-demo` is listed as its own alternative. Ordering within the
# alternation is not load-bearing for correctness.
is_ulw_trigger() {
  local prompt="$1"
  grep -Eiq '(^|[^[:alnum:]_-])(ulw-demo|ultrawork|ulw|autowork|sisyphus)([^[:alnum:]_-]|$)' <<<"${prompt}"
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

  # justfile with test recipe → just test
  if [[ -z "${test_cmd}" ]]; then
    local _justfile=""
    for _cand in justfile Justfile .justfile; do
      if [[ -f "${project_dir}/${_cand}" ]]; then
        _justfile="${project_dir}/${_cand}"
        break
      fi
    done
    if [[ -n "${_justfile}" ]] && grep -qE '^test[[:space:]]*:' "${_justfile}" 2>/dev/null; then
      test_cmd="just test"
    fi
  fi

  # Taskfile.yml with test task → task test. We match the Go-Task v3
  # canonical layout — `tasks:` at column 0 followed by an indented
  # `test:` key — instead of loose "any test: line" because a Taskfile
  # can reference `test:` inside `vars:`, `env:`, `requires:`, `deps:`,
  # etc. A loose match would return `task test` for projects whose
  # actual test task has a different name, producing confusing
  # "task: task 'test' not found" errors during stop-guard UX.
  if [[ -z "${test_cmd}" ]]; then
    local _taskfile=""
    for _cand in Taskfile.yml Taskfile.yaml taskfile.yml taskfile.yaml; do
      if [[ -f "${project_dir}/${_cand}" ]]; then
        _taskfile="${project_dir}/${_cand}"
        break
      fi
    done
    if [[ -n "${_taskfile}" ]]; then
      # awk walks the file once: enter the `tasks:` block on a
      # zero-indent `tasks:` line, leave it when a new zero-indent key
      # appears, and inside the block accept an indented `test:` key
      # whose indentation is strictly greater than `tasks:`. Exits 0
      # on find, 1 otherwise.
      if awk '
        /^tasks:[[:space:]]*$/ { in_tasks = 1; next }
        /^[^[:space:]]/ { in_tasks = 0 }
        in_tasks && /^[[:space:]]+test[[:space:]]*:/ { found = 1; exit }
        END { exit found ? 0 : 1 }
      ' "${_taskfile}" 2>/dev/null; then
        test_cmd="task test"
      fi
    fi
  fi

  # Pure-bash projects: look for test orchestrators or a tests/ directory
  # that contains shell test scripts. This tier catches harness-style repos
  # (oh-my-claude itself, dotfiles projects, other pure-shell tooling) where
  # no language manifest exists but a conventional test layout does.
  #
  # Detection precedence:
  #   1. Explicit orchestrator in repo root or scripts/:
  #        run-tests.sh, run_tests.sh, test.sh, tests.sh, run-all.sh
  #   2. Explicit orchestrator inside tests/:
  #        run.sh, runner.sh, run-all.sh, all.sh
  #   3. Alphabetically-first tests/test-*.sh / tests/test_*.sh / tests/*_test.sh
  #      as a concrete starting point. Users running a different test file
  #      from the same directory still score above threshold via the
  #      framework-keyword rule in verification_has_framework_keyword (which
  #      recognizes `bash tests/...sh` as a test framework signal).
  #
  # We never emit `bash tests/test-*.sh` with a literal glob — the shell
  # wouldn't run all files, only the first arg. Emitting a concrete file
  # keeps the advice copy-pasteable.
  if [[ -z "${test_cmd}" ]]; then
    local _orchestrator=""
    for _cand in \
        "${project_dir}/run-tests.sh" \
        "${project_dir}/run_tests.sh" \
        "${project_dir}/test.sh" \
        "${project_dir}/tests.sh" \
        "${project_dir}/run-all.sh" \
        "${project_dir}/scripts/test.sh" \
        "${project_dir}/scripts/run-tests.sh" \
        "${project_dir}/scripts/run_tests.sh" \
        "${project_dir}/tests/run.sh" \
        "${project_dir}/tests/runner.sh" \
        "${project_dir}/tests/run-all.sh" \
        "${project_dir}/tests/run_all.sh" \
        "${project_dir}/tests/all.sh"; do
      if [[ -f "${_cand}" ]]; then
        _orchestrator="${_cand#"${project_dir}/"}"
        break
      fi
    done
    if [[ -n "${_orchestrator}" ]]; then
      test_cmd="bash ${_orchestrator}"
    fi
  fi

  if [[ -z "${test_cmd}" && -d "${project_dir}/tests" ]]; then
    # Alphabetically-first shell test file under tests/. Sort in C locale
    # so the selection is deterministic across environments (same failure
    # mode as the install manifest comparator — sort key differs under
    # different LC_COLLATE).
    local _first_test
    _first_test="$(
      LC_ALL=C find "${project_dir}/tests" -maxdepth 1 -type f \
        \( -name 'test-*.sh' -o -name 'test_*.sh' -o -name '*_test.sh' \) \
        2>/dev/null | LC_ALL=C sort | head -n 1 || true
    )"
    if [[ -n "${_first_test}" ]]; then
      test_cmd="bash ${_first_test#"${project_dir}/"}"
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

  # Direct prefix/substring match first — covers the common case.
  if [[ "${norm_cmd}" == "${norm_ptc}"* ]] || [[ "${norm_cmd}" == *"${norm_ptc}"* ]]; then
    return 0
  fi

  # Bash-project family match: when the detected project_test_cmd is a
  # concrete `bash tests/<file>.sh` invocation, a user running *any* other
  # `bash tests/<file>.sh` from the same directory is exercising the same
  # test family and should get the +40 project-test bonus. Without this,
  # pure-bash projects (where our detector picks the alphabetically first
  # file) would lose the bonus whenever the user runs a different test
  # file, even though they are demonstrably running the project's test
  # suite. Narrow to the exact `bash <dir>/<file>.sh` shape:
  #
  #   - Reject captured `_dir` containing `..` (path traversal) or any
  #     regex metacharacter we don't intend to interpret literally.
  #   - Escape the captured dir's regex metachars (`.`, `[`, `*`, `^`,
  #     `$`, `+`, `?`, `(`, `)`, `|`, `\`, `/`) before interpolating into
  #     the second regex, so e.g. a ptc of `bash t.sts/foo.sh` does not
  #     also match `bash txsts/other.sh`.
  #   - Require the user's cmd's directory to contain no `/` beyond the
  #     captured prefix, so `bash tests/nested/foo.sh` still matches
  #     `bash tests/foo.sh` (same root) but not `bash other/x.sh`.
  if [[ "${norm_ptc}" =~ ^bash[[:space:]]+([^[:space:]]+/)[^[:space:]]*\.sh$ ]]; then
    local _dir="${BASH_REMATCH[1]}"
    # Path-traversal guard: ../ segments in the ptc are either a
    # misconfigured project root or a malicious input (detection comes
    # from filesystem probing, so the former is more likely, but either
    # way we don't want to over-credit).
    if [[ "${_dir}" == *"../"* ]] || [[ "${_dir}" == "../"* ]]; then
      return 1
    fi
    # Any unusual metachar in a directory name is so uncommon in real
    # project layouts that we reject rather than try to escape. Without
    # this, a ptc like `bash t.sts/foo.sh` would over-match `bash
    # txsts/other.sh` because `.` in a bash regex matches any character.
    # The only metachar we've observed in real test dir names is `.`,
    # which we escape below (bash pattern and ERE agree on `\.`); any
    # other metachar falls through to `return 1` (no bonus), which is
    # the safe default — the user's cmd still scores via the framework-
    # keyword rule.
    case "${_dir}" in
      *[!A-Za-z0-9._/\ -]*) return 1 ;;
    esac
    # Escape `.` using bash parameter expansion — portable across
    # BSD/GNU sed variants, no subshell, no shell-metachar hazards.
    local _dir_esc="${_dir//./\\.}"
    if [[ "${norm_cmd}" =~ ^bash[[:space:]]+${_dir_esc}[^[:space:]]*\.sh($|[[:space:]]) ]]; then
      return 0
    fi
  fi

  return 1
}

verification_has_framework_keyword() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || return 1
  if printf '%s' "${cmd}" | grep -Eiq '\b(pytest|vitest|jest|mocha|cargo test|go test|npm test|pnpm test|yarn test|bun test|rspec|phpunit|xcodebuild test|swift test|mix test|gradle test|mvn test|dotnet test|rake test|deno test|shellcheck|bash -n)\b'; then
    return 0
  fi
  # Shell-native project test scripts — closes the shell-only confidence
  # gap where a project's own bash test runner (e.g.
  # `bash tests/test-install-artifacts.sh`) scored the same as a bare
  # `bash -n`, starving the quality gate of trustworthy signal on
  # harness-style repos. Matches two shapes:
  #   (a) a `tests/` or `test/` directory segment followed by a `.sh`
  #       file — the dominant convention ("bash tests/test-x.sh",
  #       "./tests/runner.sh", "/abs/path/tests/foo.sh").
  #   (b) a filename that itself names it as a test script — `test-x.sh`,
  #       `test_x.sh`, `x_test.sh`, `tests.sh` — invoked via bash/sh
  #       or a relative path.
  # Narrow by design: requires `.sh` terminus (so `bash tests/data.json`
  # is not a test), and requires a bash/sh/./ prefix so `cat tests/x.sh`
  # isn't mistaken for a test run. Word boundaries on `test` prevent
  # matches on `testing`, `testdata`, etc.
  # Word-boundary `\btests?/` is critical: without it, `bash contests/foo.sh`,
  # `bash latests/foo.sh`, `bash greatestsmod/foo.sh` all false-positive
  # because `tests/` appears as a substring inside a non-test directory
  # name. `\b` requires a non-word→word transition before `t`, which is
  # satisfied by `/tests/` (slash → word) and ` tests/` (space → word) but
  # not by `contests/` (n → t). Applies to `test[-_]` and `_test` already.
  printf '%s' "${cmd}" | grep -Eiq '(^|[[:space:]]|;|&|\||\()(bash|sh|\./)[[:space:]]*[^[:space:]]*(\btests?/|\btest[-_]|_test\b)[^[:space:]]*\.sh\b'
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

_AGENT_METRICS_FILE="${_AGENT_METRICS_FILE:-${HOME}/.claude/quality-pack/agent-metrics.json}"
_AGENT_METRICS_LOCK="${_AGENT_METRICS_LOCK:-${HOME}/.claude/quality-pack/.agent-metrics.lock}"

# with_metrics_lock: Run a command under the agent metrics file lock.
# Uses time-based stale-lock recovery (same pattern as with_state_lock)
# and fails closed (returns 1 without executing) on lock exhaustion.
with_metrics_lock() {
  local lockdir="${_AGENT_METRICS_LOCK}"
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))

    if [[ -d "${lockdir}" ]]; then
      local now held_since
      now="$(date +%s)"
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
    fi

    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      log_anomaly "with_metrics_lock" "lock not acquired after ${OMC_STATE_LOCK_MAX_ATTEMPTS} attempts"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null || true
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

  with_metrics_lock _do_record_metric || true
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

_DEFECT_PATTERNS_FILE="${_DEFECT_PATTERNS_FILE:-${HOME}/.claude/quality-pack/defect-patterns.json}"
_DEFECT_PATTERNS_LOCK="${_DEFECT_PATTERNS_LOCK:-${HOME}/.claude/quality-pack/.defect-patterns.lock}"

# with_defect_lock: Run a command under the defect patterns file lock.
# Separate from with_metrics_lock to avoid unnecessary contention.
# Uses time-based stale-lock recovery and fails closed on exhaustion.
with_defect_lock() {
  local lockdir="${_DEFECT_PATTERNS_LOCK}"
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))

    if [[ -d "${lockdir}" ]]; then
      local now held_since
      now="$(date +%s)"
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
    fi

    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      log_anomaly "with_defect_lock" "lock not acquired after ${OMC_STATE_LOCK_MAX_ATTEMPTS} attempts"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null || true
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
    log_anomaly "common" "defect-patterns.json was corrupt, archived to ${archive}, reset to {}"
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

  with_defect_lock _do_record_defect || true
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
    _cap_cross_session_jsonl "${skip_file}" 200 150
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

  # ── Phase 1: position-independent unambiguous signals ──
  # These fire BEFORE the imperative guard because they are always checkpoint,
  # even when embedded after an imperative verb (e.g., "Fix the bug, then
  # stop here"). "stop here" and "pause here" are explicit session-control
  # directives — the user IS asking to stop regardless of context.
  grep -Eiq '\b(checkpoint|pause here|stop here|let.s stop here|one wave at a time|one phase at a time|wave [0-9]+ only|phase [0-9]+ only|first wave only|first phase only|just wave [0-9]+|just phase [0-9]+)\b' <<<"${text}" \
    && return 0

  # ── Phase 2: start-of-text checkpoint phrases ──
  # Fire before the imperative guard because "stop for now" is checkpoint
  # even though "stop" is also an imperative verb.
  if [[ "${text}" =~ ^[[:space:]]*(stop|pause|hold)[[:space:]]+(for[[:space:]]+now) ]]; then
    return 0
  fi
  # Specific stop/pause compound phrases at start of text
  if grep -Eiq '^[[:space:]]*(that.s enough|that.s all|that.s good|wrap up|leave it|park it|park this)\s+for\s+now\b' <<<"${text}"; then
    return 0
  fi
  # "let's stop here" at start (also caught by Phase 1, but explicit for clarity)
  if grep -Eiq '^[[:space:]]*(let.s stop here|let.s pause here)\b' <<<"${text}"; then
    return 0
  fi

  # ── Phase 3: imperative guard ──
  # An explicit imperative at the top of the prompt beats any remaining
  # embedded checkpoint keywords. Without this, "Fix X … unchanged for now"
  # is wrongly routed to checkpoint instead of execution.
  if is_imperative_request "${text}"; then
    return 1
  fi

  # ── Phase 4: end-of-text checkpoint signals ──
  # Only fire for non-imperative prompts (guard already filtered above).
  # Require stop/pause verb context before "for now" to avoid matching
  # scope-qualifiers like "remain unchanged for now".
  if grep -Eiq '\b(stop|pause|done|halt|hold)\s+for\s+now[.!]?[[:space:]]*$' <<<"${text}"; then
    return 0
  fi
  if grep -Eiq '\b(that.s enough|that.s all|that.s good|wrap up|leave it|park it)\s+for\s+now[.!]?[[:space:]]*$' <<<"${text}"; then
    return 0
  fi

  # ── Phase 5: boundary-scoped ambiguous keywords ──
  # Scope to first/last 200 chars to prevent embedded occurrences from triggering.
  local head="${text:0:200}"
  local tail="${text: -200}"
  if grep -Eiq '\b(continue later|pick up later|resume later)\b' <<<"${head}${tail}"; then
    return 0
  fi

  # Note: "for this session" removed — already covered by
  # is_session_management_request with stronger guards (imperative guard +
  # dual-gate + 400-char head scope).

  return 1
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
    && grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\w*|prefer\b|advice\b|\bworth\s+(it|doing|trying|fixing|changing|considering|exploring|investigating|the\s+effort|a\s+)|\b(suggest\s+(we|you|i|they|an?|the|that|instead)|suggestion|suggestions|suggested|suggesting)\b)' <<<"${text}"
  # Note: SM intentionally keeps standalone "better" — the dual-gate (SM keyword
  # AND advisory framing) makes it safe here. "Is it better to start a new
  # session?" needs both "new session" + "better" to match. The standalone
  # advisory pattern removed "better" because it lacks this dual-gate protection.
}

is_advisory_request() {
  local text="$1"

  # Line-start question words and specific advisory phrases are strong signals.
  # Standalone "better" removed — too broad ("better for real users" is comparative,
  # not advisory). Covered by specific patterns: "would it be better", "is it better".
  # "worth" tightened — "net worth calculator" is not advisory. Require gerund/object.
  # "suggest" tightened — "auto-suggest feature" is not advisory. Require advisory framing.
  grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|recommend\w*|prefer\b|advice\b|tradeoff\b|tradeoffs\b|pros and cons\b|should we\b|would it be better\b|is it better\b|do you think\b|\bworth\s+(it|doing|trying|fixing|changing|considering|exploring|investigating|the\s+effort|a\s+)|\b(suggest\s+(we|you|i|they|an?|the|that|instead)|suggestion|suggestions|suggested|suggesting)\b)' <<<"${text}"
}

# Source the classifier subsystem (P0 imperative detection, P1 domain scoring,
# classify_task_intent, telemetry, misfire detection, is_execution_intent_value).
# All required helpers — project_profile_has, normalize_task_prompt,
# extract_skill_primary_task, is_continuation_request, is_checkpoint_request,
# is_session_management_request, is_advisory_request, session_file (lib),
# log_hook, log_anomaly, now_epoch, truncate_chars, trim_whitespace — are
# defined above this point.
source "${_omc_self_dir}/lib/classifier.sh"

has_unfinished_session_handoff() {
  local text="$1"

  grep -Eiq '\b(ready for a new session|ready for another session|continue in a new session|continue in another session|new session\b|another session\b|next wave\b|next phase\b|wave [0-9]+[^.!\n]* is next|phase [0-9]+[^.!\n]* is next|remaining work\b|the rest\b|pick up .* later|continue .* later)\b' <<<"${text}"
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
     && ! grep -Eiq '\bimprovements?\s+to\s+(the\s+|my\s+|our\s+)?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [the|my] [non-project-word]" — direct object after improve
  if grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+\w' <<<"${text}" \
     && ! grep -Eiq '\bimprove\s+(the|my|our|this|that)\s+(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?|whole|entire)\b' <<<"${text}"; then
    return 0
  fi

  # "improve [subsystem-concept]" — bare noun without determiner
  grep -Eiq '\bimprove\s+(error|auth|api|security|data|cache|session|payment|frontend|backend|infrastructure|architecture|performance|reliability|deployment|navigation|rendering|logging|caching|routing|networking|authentication|authorization|observability|monitoring|testing|validation)\w*\b' <<<"${text}" \
    && return 0

  return 1
}

is_council_evaluation_request() {
  local text="$1"

  # Pattern 1: "[evaluate|assess|audit|review] [my|the|this|our] [entire|whole]? [project|codebase|app|product|repo|extension|site|...]"
  # Guarded: reject if the project-level word is part of a compound noun
  # (e.g., "project manager", "project plan", "product team", "extension manager")
  if grep -Eiq '(evaluat|assess|audit|review|inspect|analyz)\w*\s+(my|the|this|our|entire|whole|full)\s+((\w+\s+){0,2})?(projects?|codebase|code.?base|app(lication)?|products?|repo(sitory)?|software|system|extensions?|sites?|websites?|platforms?|librar(y|ies)|packages?|plugins?|frameworks?)\b' <<<"${text}" \
     && ! grep -Eiq '\b(project|product)\s+(manager|management|plan|planning|structure|timeline|scope|lead|owner|director|description|proposal|requirements?|specification|charter|budget|schedule|board|team|files?|folders?|documentation|dependencies|configuration|roadmap|backlog|strategy|design|review)\b' <<<"${text}" \
     && ! grep -Eiq '\b(extension|package|plugin|site|platform|framework|library)\s+(manager|management|registry|store|marketplace|directory|map|version|settings|manifest)\b' <<<"${text}"; then
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

# --- Discovered-scope tracking ---
#
# Captures findings emitted by advisory specialists (council lenses, metis,
# briefing-analyst) into a per-session JSONL file. The stop-guard reads the
# pending count to detect the "shipped 25 / deferred 8 / silently skipped 15"
# anti-pattern documented in the v1.10.0 council-completeness audit.
#
# State surface: <session>/discovered_scope.jsonl (one JSON object per line)
#   { id, source, summary, severity, status, reason, ts }
# Lifecycle: written by record-subagent-summary.sh on SubagentStop for
# whitelisted agents, read by stop-guard.sh on session stop, consumed by
# excellence-reviewer.md as a completeness checklist axis.
#
# Failure mode: heuristic extraction MUST fail open. A noisy parse that
# captures nothing is preferable to a blocked stop. All entry points wrap
# parsing in `|| true` and log_anomaly only on lock exhaustion.

# Whitelist of agent names whose output is parsed for findings. Excludes
# excellence-reviewer / quality-reviewer (those are verifiers, not
# discoverers — their findings already have dedicated dimensions).
discovered_scope_capture_targets() {
  printf '%s\n' \
    "metis" \
    "briefing-analyst" \
    "security-lens" \
    "data-lens" \
    "product-lens" \
    "growth-lens" \
    "sre-lens" \
    "design-lens"
}

_severity_from_bullet() {
  local s="$1"
  if grep -Eiq '\b(critical|high|p0|severe|blocker)\b' <<<"${s}"; then
    printf 'high'
  elif grep -Eiq '\b(medium|p1|moderate|important)\b' <<<"${s}"; then
    printf 'medium'
  else
    printf 'low'
  fi
}

_finding_id() {
  local source_name="$1"
  local summary="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s|%s' "${source_name}" "${summary}" \
      | shasum -a 256 2>/dev/null \
      | awk '{print substr($1,1,12)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s|%s' "${source_name}" "${summary}" \
      | sha256sum 2>/dev/null \
      | awk '{print substr($1,1,12)}'
  else
    # Fallback: deterministic hex based on cksum (much weaker but stable).
    printf '%s|%s' "${source_name}" "${summary}" \
      | cksum 2>/dev/null \
      | awk '{printf "%012x", $1}'
  fi
}

# extract_discovered_findings <agent_name> <message>
# Emits one JSONL row per detected bullet on stdout.
# Heuristic:
#   1. Strip fenced code blocks.
#   2. Walk markdown headings; when a heading matches a known anchor
#      (findings, risks, concerns, recommendations, unknowns, action items),
#      capture subsequent top-level numbered list items until the next
#      heading.
#   3. If anchored search yields nothing AND the body has >=3 top-level
#      numbered items, capture all of them as fallback.
# Cap output at 10 bullets per single capture.
extract_discovered_findings() {
  local agent_name="$1"
  local message="$2"
  [[ -z "${message}" ]] && return 0

  local now_ts cleaned bullets
  now_ts="$(now_epoch)"

  cleaned="$(printf '%s\n' "${message}" | awk '
    /^```/ { in_code = !in_code; next }
    !in_code { print }
  ')"

  # Anchor headings: case-insensitive match by lowercasing the line.
  # IGNORECASE=1 is GNU-awk-only and a silent no-op on BSD awk (macOS), so
  # tolower() is the portable approach. target_re is intentionally a single
  # alternation rather than nested groups — easier to extend.
  bullets="$(printf '%s\n' "${cleaned}" | awk '
    BEGIN {
      in_target = 0
      target_re = "(findings|concerns|issues|risks|recommendations|unknowns?|action[[:space:]]+items|blockers|gaps|opportunities|critical[[:space:]]+findings|unknown[[:space:]]+unknowns)"
    }
    /^#+[[:space:]]/ {
      if (tolower($0) ~ target_re) { in_target = 1 } else { in_target = 0 }
      next
    }
    # Capture both numbered (1. / 1) / 1:) AND dash/star/plus markers under
    # anchor headings. Specialists vary in convention — recall over precision
    # when an explicit Findings/Risks/Concerns heading is in scope.
    in_target && /^[[:space:]]*[0-9]+[.):]/ {
      sub(/^[[:space:]]*[0-9]+[.):]+[[:space:]]*/, "")
      print
      next
    }
    in_target && /^[[:space:]]*[-*+][[:space:]]/ {
      sub(/^[[:space:]]*[-*+][[:space:]]+/, "")
      print
    }
  ' || true)"

  if [[ -z "${bullets}" ]]; then
    # Fallback: capture top-level numbered list when no anchor heading exists
    # AND the message body suggests findings. Without the keyword gate the
    # extractor would capture step-by-step instructions, plan milestones,
    # and reference lists as if they were findings, producing false-positive
    # gate blocks on legitimate completion summaries.
    if grep -Eiq '\b(findings?|concerns?|issues?|risks?|problems?|bugs?|defects?|gaps?|vulnerabilit|recommendations?|severity|blocker|critical|should[[:space:]]+(fix|address|consider))\b' <<<"${cleaned}"; then
      local fallback_count
      fallback_count="$(printf '%s\n' "${cleaned}" \
        | grep -cE '^[[:space:]]*[0-9]+[.):][[:space:]]' 2>/dev/null \
        || true)"
      fallback_count="${fallback_count:-0}"
      if [[ "${fallback_count}" -ge 3 ]]; then
        bullets="$(printf '%s\n' "${cleaned}" | awk '
          /^#+[[:space:]]/ { next }
          /^[[:space:]]*[0-9]+[.):]/ {
            sub(/^[[:space:]]*[0-9]+[.):]+[[:space:]]*/, "")
            print
          }
        ' || true)"
      fi
    fi
  fi

  [[ -z "${bullets}" ]] && return 0

  local capped
  capped="$(printf '%s\n' "${bullets}" | head -n 10)"

  local line summary severity id
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    summary="$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
    summary="${summary:0:240}"
    [[ -z "${summary}" ]] && continue

    severity="$(_severity_from_bullet "${summary}")"
    id="$(_finding_id "${agent_name}" "${summary}")"
    [[ -z "${id}" ]] && continue

    jq -nc \
      --arg id "${id}" \
      --arg src "${agent_name}" \
      --arg sum "${summary}" \
      --arg sev "${severity}" \
      --arg ts "${now_ts}" \
      '{id:$id, source:$src, summary:$sum, severity:$sev, status:"pending", reason:"", ts:$ts}' \
      2>/dev/null || continue
  done <<<"${capped}"
}

# with_scope_lock: serialize writes to discovered_scope.jsonl per session.
# Same mkdir + stale-recovery pattern as with_metrics_lock / with_state_lock.
with_scope_lock() {
  if [[ -z "${SESSION_ID:-}" ]]; then
    return 1
  fi
  local lockdir
  lockdir="$(session_file ".scope.lock")"
  local attempts=0

  while true; do
    if mkdir "${lockdir}" 2>/dev/null; then
      break
    fi
    attempts=$((attempts + 1))
    if [[ -d "${lockdir}" ]]; then
      local now held_since
      now="$(date +%s)"
      held_since="$(_lock_mtime "${lockdir}")"
      if [[ "${held_since}" -gt 0 ]] \
          && [[ $(( now - held_since )) -gt "${OMC_STATE_LOCK_STALE_SECS}" ]]; then
        rmdir "${lockdir}" 2>/dev/null || true
        continue
      fi
    fi
    if [[ "${attempts}" -ge "${OMC_STATE_LOCK_MAX_ATTEMPTS}" ]]; then
      log_anomaly "with_scope_lock" "lock not acquired after ${OMC_STATE_LOCK_MAX_ATTEMPTS} attempts"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done

  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null || true
  return "${rc}"
}

# append_discovered_scope <agent_name> <jsonl_rows>
# Dedupes by id against existing rows, appends new ones, caps total at 200.
append_discovered_scope() {
  local agent_name="$1"
  local rows="$2"
  [[ -z "${rows}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  _do_append_scope() {
    local file existing_ids
    file="$(session_file "discovered_scope.jsonl")"

    # Invariant: existing_ids is always "|id1|id2|..." with both leading
    # and trailing pipes, so the substring check `*"|${id}|"*` matches.
    # An empty initial set must be "|", not "" — otherwise the first add
    # leaves the string as "id|" with no leading pipe and within-batch
    # duplicates slip through dedup.
    existing_ids="|"
    if [[ -f "${file}" ]]; then
      existing_ids="|$(jq -r '.id // empty' "${file}" 2>/dev/null | tr '\n' '|' || true)"
    fi

    local row row_id
    while IFS= read -r row; do
      [[ -z "${row}" ]] && continue
      row_id="$(jq -r '.id // empty' <<<"${row}" 2>/dev/null || true)"
      [[ -z "${row_id}" ]] && continue
      if [[ "${existing_ids}" != *"|${row_id}|"* ]]; then
        printf '%s\n' "${row}" >> "${file}"
        existing_ids="${existing_ids}${row_id}|"
      fi
    done <<<"${rows}"

    if [[ -f "${file}" ]]; then
      local total
      total="$(wc -l < "${file}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
      total="${total:-0}"
      if [[ "${total}" -gt 200 ]]; then
        local trimmed
        trimmed="$(mktemp "${file}.XXXXXX")"
        tail -n 200 "${file}" > "${trimmed}" 2>/dev/null \
          && mv "${trimmed}" "${file}" 2>/dev/null \
          || rm -f "${trimmed}"
      fi
    fi
  }

  with_scope_lock _do_append_scope || true
}

# read_scope_count_by_status <status>
# Per-line counter that tolerates malformed JSONL rows. A single bad line
# would cause `jq -s` slurp to fail entirely, silently disabling the gate.
# Per-line parsing skips bad rows individually.
read_scope_count_by_status() {
  local target_status="$1"
  [[ -z "${target_status}" ]] && { printf '0'; return; }
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return; }
  local file count line
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || { printf '0'; return; }
  count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if jq -e --arg s "${target_status}" '.status == $s' <<<"${line}" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done < "${file}"
  printf '%s' "${count}"
}

read_pending_scope_count() {
  read_scope_count_by_status "pending"
}

read_total_scope_count() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return; }
  local file count
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || { printf '0'; return; }
  count="$(wc -l < "${file}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  printf '%s' "${count:-0}"
}

# build_discovered_scope_scorecard [max_lines]
# Returns up to max_lines (default 8) pending findings, severity-ordered
# (high > medium > low). Empty stdout if none.
# Filters parseable pending lines first, then slurps for sorting — keeps
# the gate functional even when a single row is corrupted.
build_discovered_scope_scorecard() {
  [[ -z "${SESSION_ID:-}" ]] && return 0
  local file max_lines line filtered
  file="$(session_file "discovered_scope.jsonl")"
  [[ -f "${file}" ]] || return 0
  max_lines="${1:-8}"

  filtered=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if jq -e '.status == "pending"' <<<"${line}" >/dev/null 2>&1; then
      filtered="${filtered}${line}
"
    fi
  done < "${file}"

  [[ -z "${filtered}" ]] && return 0

  printf '%s' "${filtered}" | jq -s -r --argjson max "${max_lines}" '
    sort_by(if .severity == "high" then 0 elif .severity == "medium" then 1 else 2 end) |
    .[0:$max] |
    map("- [\(.id[0:8])] \(.severity) · \(.source) · \(.summary[0:80])") |
    .[]
  ' 2>/dev/null || true
}

# update_scope_status <id_prefix> <status> [reason]
# Updates the row whose id starts with id_prefix. Refuses to update if the
# prefix is shorter than 6 chars or matches multiple rows (logs an anomaly
# instead) — silent wrong-row updates are worse than no update.
update_scope_status() {
  local id_prefix="$1"
  local new_status="$2"
  local new_reason="${3:-}"
  [[ -z "${id_prefix}" || -z "${new_status}" ]] && return 0
  [[ -z "${SESSION_ID:-}" ]] && return 0

  if [[ "${#id_prefix}" -lt 6 ]]; then
    log_anomaly "update_scope_status" "rejected id_prefix too short: ${id_prefix} (min 6 chars)"
    return 1
  fi

  _do_update_scope() {
    local file
    file="$(session_file "discovered_scope.jsonl")"
    [[ -f "${file}" ]] || return 0

    # Pre-scan: refuse on ambiguity. Per-line parse so a malformed row
    # doesn't corrupt the count.
    local match_count=0 line row_id
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      row_id="$(jq -r '.id // empty' <<<"${line}" 2>/dev/null || true)"
      if [[ -n "${row_id}" && "${row_id}" == "${id_prefix}"* ]]; then
        match_count=$((match_count + 1))
      fi
    done < "${file}"

    if [[ "${match_count}" -gt 1 ]]; then
      log_anomaly "update_scope_status" "ambiguous prefix ${id_prefix} matched ${match_count} rows; no update applied"
      return 0
    fi
    if [[ "${match_count}" -eq 0 ]]; then
      return 0
    fi

    local tmp matched=0 obj
    tmp="$(mktemp "${file}.XXXXXX")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      obj="${line}"
      if [[ "${matched}" -eq 0 ]]; then
        row_id="$(jq -r '.id // empty' <<<"${line}" 2>/dev/null || true)"
        if [[ -n "${row_id}" && "${row_id}" == "${id_prefix}"* ]]; then
          obj="$(jq -c \
            --arg s "${new_status}" \
            --arg r "${new_reason}" \
            '.status = $s | .reason = $r' <<<"${line}" 2>/dev/null || printf '%s' "${line}")"
          matched=1
        fi
      fi
      printf '%s\n' "${obj}" >> "${tmp}"
    done < "${file}"

    mv "${tmp}" "${file}" 2>/dev/null || rm -f "${tmp}"
  }

  with_scope_lock _do_update_scope || true
}

# --- end discovered-scope tracking ---

# --- Wave plan tracking ---
#
# Reads the master finding list (`<session>/findings.json`) created by
# `record-finding-list.sh` during council Phase 8. The discovered-scope
# gate uses these helpers to raise its block cap when the model is
# legitimately working through a multi-wave implementation — without
# this, the gate releases after 2 blocks even if 30 findings remain
# pending across 5 planned waves.
#
# Failure mode: missing findings.json or malformed JSON returns 0,
# which preserves legacy 2-block behavior. Never throws.

read_active_wave_total() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r '(.waves // []) | length' "${file}" 2>/dev/null || printf '0'
}

read_active_waves_completed() {
  [[ -z "${SESSION_ID:-}" ]] && { printf '0'; return 0; }
  local file
  file="$(session_file "findings.json")"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  jq -r '[(.waves // [])[] | select(.status == "completed")] | length' "${file}" 2>/dev/null || printf '0'
}

# --- end wave plan tracking ---

# --- Session discovery for manually-invoked scripts ---
#
# Manually-invoked autowork scripts (record-finding-list.sh, show-status.sh)
# do not have a hook JSON to read SESSION_ID from. They must discover the
# active session by inspecting STATE_ROOT directly.
#
# Critical: filter for directories. STATE_ROOT also contains flat files
# (hooks.log, installed-manifest.txt) which would otherwise be picked by
# a naive `ls -t | head -1` and cause downstream bugs (mkdir -p collisions
# in record-finding-list.sh, "no state file" warnings in show-status.sh).
#
# Returns the session ID (basename of newest dir) or empty string if no
# session directory exists. Never throws; STATE_ROOT-missing is silent.

discover_latest_session() {
  local d newest=""
  [[ -d "${STATE_ROOT}" ]] || { printf ''; return 0; }
  shopt -s nullglob
  local dirs=("${STATE_ROOT}"/*/)
  shopt -u nullglob
  for d in "${dirs[@]}"; do
    [[ -z "${newest}" || "${d}" -nt "${newest}" ]] && newest="${d}"
  done
  [[ -n "${newest}" ]] && basename "${newest}" || printf ''
}

# --- end session discovery ---

# Final cleanup: unset bootstrap helpers now that all libs have been sourced.
unset _omc_self _omc_self_dir
