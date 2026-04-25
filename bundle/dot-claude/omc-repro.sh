#!/usr/bin/env bash
#
# omc-repro — package an oh-my-claude session's state for a bug report.
#
# Usage:
#   bash ~/.claude/omc-repro.sh                  # bundle the most recently touched session
#   bash ~/.claude/omc-repro.sh <session-id>     # bundle a specific session
#   bash ~/.claude/omc-repro.sh --list           # list recent sessions, newest first
#
# Output: a .tar.gz at $HOME/omc-repro-<session>-<stamp>.tar.gz containing:
#   - session_state.json (user-prompt fields redacted — see below)
#   - classifier_telemetry.jsonl (prompt_preview redacted, if present)
#   - recent_prompts.jsonl (text field redacted, if present)
#   - edited_files.log (if present)
#   - subagent_summaries.jsonl (if present)
#   - pending_agents.jsonl (if present)
#   - discovered_scope.jsonl (council Phase 8 advisory-specialist findings; if present)
#   - findings.json (council Phase 8 master finding list and wave plan; if present)
#   - hooks.log (last 200 lines only, to keep the bundle small)
#   - manifest.txt (oh-my-claude version, OS, shell, jq version, file list)
#
# Redaction contract: every field that holds user-originated prompt or
# assistant-message text is truncated to REDACT_CHARS (default 80) chars
# before bundling. Covered fields:
#   session_state.json   — last_user_prompt, last_assistant_message,
#                          current_objective, last_meta_request
#   classifier_telemetry — prompt_preview (was 200, becomes 80)
#   recent_prompts       — text
# Redaction is applied per-row with jq's try/catch so a malformed row
# falls through to `empty` (dropped) rather than leaking the unredacted
# original. The fallback-to-copy-on-jq-failure path was removed: a jq
# failure now emits `{}` for session state and skips JSONL lines, never
# copies through the unredacted source under any path.

set -euo pipefail

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
BUNDLE_DIR="${HOME}/.claude"
REDACT_CHARS="${OMC_REPRO_REDACT_CHARS:-80}"

# Redact user-prompt and assistant-message fields to the configured char
# cap. The comma-generator (not array literal) form of `reduce` iterates
# one field name per pass with `$k` bound to the string; `has($k)` guards
# against creating missing keys (naive `.[$k] |= ...` would set them to
# null). Non-string values are left untouched.
redact_session_state() {
  local src="$1"
  local dst="$2"
  jq --argjson n "${REDACT_CHARS}" '
    reduce ("last_user_prompt","last_assistant_message","current_objective","last_meta_request") as $k (.;
      if has($k) and (.[$k] | type == "string")
        then .[$k] = (.[$k] | .[0:$n])
        else .
      end
    )
  ' "${src}" > "${dst}" 2>/dev/null \
    || {
      # jq failed (corrupt JSON, jq missing, etc.). Rather than fall back
      # to the unredacted copy, emit an empty object — an unredacted leak
      # is worse than a missing file in a bug-report bundle. The repro
      # recipient will see `{}` and know to ask the reporter to share
      # state.json separately if they need it.
      printf '{}\n' > "${dst}"
      return 1
    }
  return 0
}

# Redact a JSONL file field-by-field with per-row try/catch. Each row is
# parsed independently; malformed rows are dropped (never copied through
# as plaintext). Returns non-zero only if the output file could not be
# written at all — per-row failures are swallowed silently.
redact_jsonl_field() {
  local src="$1"
  local dst="$2"
  local field="$3"
  jq -cR --arg field "${field}" --argjson n "${REDACT_CHARS}" '
    . as $line
    | try (
        fromjson
        | if type == "object" and has($field) and (.[$field] | type == "string")
            then .[$field] = (.[$field] | .[0:$n])
            else .
          end
      ) catch empty
  ' "${src}" > "${dst}" 2>/dev/null
}

usage() {
  cat <<'EOF'
omc-repro — package an oh-my-claude session for a bug report.

Usage:
  bash ~/.claude/omc-repro.sh                  bundle the most recently touched session
  bash ~/.claude/omc-repro.sh <session-id>     bundle a specific session
  bash ~/.claude/omc-repro.sh --list           list recent sessions, newest first
  bash ~/.claude/omc-repro.sh --help           show this help

The output tarball lives at $HOME/omc-repro-<session>-<stamp>.tar.gz.
Prompt previews are truncated to 80 chars before bundling.
EOF
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'omc-repro: jq is required but not found in PATH.\n' >&2
  exit 1
fi

if [[ ! -d "${STATE_ROOT}" ]]; then
  printf 'omc-repro: state root does not exist: %s\n' "${STATE_ROOT}" >&2
  printf '           (no oh-my-claude sessions have run on this machine)\n' >&2
  exit 1
fi

# --- session discovery ---

# Emit session IDs sorted by state-file mtime, newest first. Works on BSD and
# GNU stat. Falls back to name sort if stat is unavailable.
list_sessions() {
  local sid mtime state_file
  for sid_dir in "${STATE_ROOT}"/*/; do
    [[ -d "${sid_dir}" ]] || continue
    sid="$(basename "${sid_dir}")"
    case "${sid}" in .*|*.lock) continue ;; esac
    state_file="${sid_dir}session_state.json"
    [[ -f "${state_file}" ]] || continue
    mtime="$(stat -f %m "${state_file}" 2>/dev/null)" \
      || mtime="$(stat -c %Y "${state_file}" 2>/dev/null)" \
      || mtime=0
    printf '%s\t%s\n' "${mtime}" "${sid}"
  done | sort -rn | awk -F'\t' '{print $2}'
}

latest_session() {
  list_sessions | head -n 1
}

# --- arg parsing ---

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --list)
    sessions="$(list_sessions)"
    if [[ -z "${sessions}" ]]; then
      printf 'No sessions found under %s\n' "${STATE_ROOT}"
      exit 0
    fi
    printf 'Sessions (newest first):\n'
    printf '%s\n' "${sessions}" | head -n 20 | while IFS= read -r sid; do
      printf '  %s\n' "${sid}"
    done
    exit 0
    ;;
  "")
    SESSION_ID="$(latest_session)"
    if [[ -z "${SESSION_ID}" ]]; then
      printf 'omc-repro: no sessions found under %s\n' "${STATE_ROOT}" >&2
      exit 1
    fi
    ;;
  *)
    SESSION_ID="$1"
    ;;
esac

SESSION_DIR="${STATE_ROOT}/${SESSION_ID}"
if [[ ! -d "${SESSION_DIR}" ]]; then
  printf 'omc-repro: session directory not found: %s\n' "${SESSION_DIR}" >&2
  printf '           run with --list to see available sessions.\n' >&2
  exit 1
fi

# --- stage ---

STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGING="$(mktemp -d -t omc-repro.XXXXXX)"
trap 'rm -rf "${STAGING}"' EXIT

REPRO_NAME="omc-repro-${SESSION_ID}-${STAMP}"
REPRO_DIR="${STAGING}/${REPRO_NAME}"
mkdir -p "${REPRO_DIR}"

# Copy non-sensitive session files directly (no prompt text in these).
# findings.json and discovered_scope.jsonl carry council/advisory-specialist
# output (severity, surface area, summaries) — derived from model output and
# project state, not from user prompts. They are included so that bug
# reports about Phase 8 / discovered-scope behavior arrive with the wave
# plan and findings list the maintainer needs to reproduce the issue.
for name in \
    edited_files.log \
    stall_paths.log \
    pending_agents.jsonl \
    subagent_summaries.jsonl \
    discovered_scope.jsonl \
    findings.json; do
  if [[ -f "${SESSION_DIR}/${name}" ]]; then
    cp "${SESSION_DIR}/${name}" "${REPRO_DIR}/${name}"
  fi
done

# session_state.json: redact the four user-prompt / assistant-message fields
# before copying. If jq fails for any reason, we emit an empty object rather
# than fall back to the raw original — an unredacted leak is worse than a
# missing file in a bug-report bundle.
if [[ -f "${SESSION_DIR}/session_state.json" ]]; then
  redact_session_state "${SESSION_DIR}/session_state.json" "${REPRO_DIR}/session_state.json" || true
fi

# classifier_telemetry.jsonl: redact prompt_preview per-row via try/catch.
if [[ -f "${SESSION_DIR}/classifier_telemetry.jsonl" ]]; then
  redact_jsonl_field \
    "${SESSION_DIR}/classifier_telemetry.jsonl" \
    "${REPRO_DIR}/classifier_telemetry.jsonl" \
    "prompt_preview" || true
fi

# recent_prompts.jsonl: rows carry verbatim user prompts in `.text`.
# Redact per-row; a malformed row is dropped rather than copied through.
if [[ -f "${SESSION_DIR}/recent_prompts.jsonl" ]]; then
  redact_jsonl_field \
    "${SESSION_DIR}/recent_prompts.jsonl" \
    "${REPRO_DIR}/recent_prompts.jsonl" \
    "text" || true
fi

# hooks.log is shared across sessions, so only include the tail.
if [[ -f "${STATE_ROOT}/hooks.log" ]]; then
  tail -n 200 "${STATE_ROOT}/hooks.log" > "${REPRO_DIR}/hooks.log.tail" 2>/dev/null || true
fi

# --- manifest ---

MANIFEST="${REPRO_DIR}/manifest.txt"
{
  printf 'oh-my-claude repro bundle\n'
  printf '=========================\n'
  printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf 'Session:   %s\n' "${SESSION_ID}"

  omc_version="$(tr -d '[:space:]' < "${BUNDLE_DIR}/VERSION" 2>/dev/null || echo unknown)"
  printf 'oh-my-claude: %s\n' "${omc_version}"

  printf 'OS:        %s %s\n' "$(uname -s 2>/dev/null || echo unknown)" "$(uname -r 2>/dev/null || echo unknown)"
  printf 'Shell:     %s\n' "${SHELL:-unknown}"
  printf 'Bash:      %s\n' "${BASH_VERSION:-unknown}"
  printf 'jq:        %s\n' "$(jq --version 2>/dev/null || echo unknown)"
  printf '\n'

  printf 'Files in bundle:\n'
  (cd "${REPRO_DIR}" && find . -maxdepth 1 -type f -not -name manifest.txt | sort | while IFS= read -r f; do
    size="$(wc -c < "${f}" 2>/dev/null | tr -d ' ')"
    printf '  %8s bytes  %s\n' "${size:-0}" "${f#./}"
  done)

  # Hook-log summary — triage hint at the top of a bug-report bundle so
  # the recipient sees "30 anomalies in the last 200 lines" before digging
  # into the file. Counts only the tail we bundled; full history may exceed.
  log_tail="${REPRO_DIR}/hooks.log.tail"
  if [[ -f "${log_tail}" ]]; then
    anomaly_count="$({ grep -c '\[anomaly\]' "${log_tail}" 2>/dev/null || true; } | tail -n1)"
    debug_count="$({ grep -c '\[debug\]' "${log_tail}" 2>/dev/null || true; } | tail -n1)"
    printf '\n'
    printf 'Hook-log tail summary (last 200 lines):\n'
    printf '  anomalies: %s\n' "${anomaly_count:-0}"
    printf '  debug:     %s\n' "${debug_count:-0}"
  fi
} > "${MANIFEST}"

# --- package ---

OUT="${HOME}/${REPRO_NAME}.tar.gz"
(cd "${STAGING}" && tar -czf "${OUT}" "${REPRO_NAME}")

printf '\n'
printf 'Repro bundle created:\n'
printf '  %s\n\n' "${OUT}"
printf 'Contents: see manifest.txt inside the tarball, or run:\n'
printf '  tar -tzf %s\n\n' "${OUT}"
printf 'Share this file with the oh-my-claude maintainer when reporting a bug.\n'
printf 'User prompt and assistant-message fields are truncated to %s chars across\n' "${REDACT_CHARS}"
printf 'session_state.json, classifier_telemetry.jsonl, and recent_prompts.jsonl.\n'
printf 'Raise OMC_REPRO_REDACT_CHARS to keep more context, or review the tarball\n'
# shellcheck disable=SC2016  # backticks are literal inside the message.
printf 'with `tar -xzf %s -C /tmp` before sharing if you have additional\n' "${OUT}"
printf 'privacy concerns.\n'
