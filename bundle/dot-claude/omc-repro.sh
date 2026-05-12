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
#   - gate_events.jsonl (per-event outcome attribution rows; if present, added v1.14.0)
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

# v1.40.x security-lens F-007: defense-in-depth secret redaction.
# Prior versions of this script applied truncation only — a prompt
# beginning with `--api-key sk-ant-...` kept the credential intact
# in the first 80 chars. State written by pre-v1.40 sessions still
# carries raw secrets on disk; this fallback scrub catches them at
# bundle time. Sources omc_redact_secrets from common.sh.
#
# v1.40.0 hardening (F-008): the fallback used to silently cat-
# passthrough so the pipeline "never breaks" — but a user running
# omc-repro.sh against a corrupted install would then ship secrets
# verbatim in the support tarball, defeating the F-007 contract.
# The new behavior is FAIL-CLOSED: if common.sh can't be sourced or
# omc_redact_secrets isn't defined, the script aborts with a stderr
# warning naming the failure mode. Power users who genuinely want
# the legacy unredacted-bundle path (rare — only legitimate when
# the user has no secrets in session state and accepts the risk)
# can set OMC_REPRO_ALLOW_UNREDACTED=1 to re-enable the cat-
# passthrough. Default is abort.
_omc_self_dir="$(cd "$(dirname "$0")" && pwd)"
_common_sh="${_omc_self_dir}/skills/autowork/scripts/common.sh"
if [[ -f "${_common_sh}" ]]; then
  # shellcheck source=skills/autowork/scripts/common.sh
  OMC_LAZY_CLASSIFIER=1 OMC_LAZY_TIMING=1 SESSION_ID="omc-repro-$$" \
    source "${_common_sh}" </dev/null 2>/dev/null || true
fi
if ! declare -f omc_redact_secrets >/dev/null 2>&1; then
  if [[ "${OMC_REPRO_ALLOW_UNREDACTED:-0}" == "1" ]]; then
    printf 'omc-repro: WARNING — OMC_REPRO_ALLOW_UNREDACTED=1 set; bundling without secret redaction.\n' >&2
    printf 'omc-repro:          The tarball MAY contain credentials, tokens, or other secrets from\n' >&2
    printf 'omc-repro:          your session state. Review the bundle before sharing.\n' >&2
    omc_redact_secrets() { cat; }
  else
    printf 'omc-repro: ERROR — common.sh failed to source; omc_redact_secrets is unavailable.\n' >&2
    printf 'omc-repro:        Aborting to prevent secrets from leaking into the bundle (F-007 contract).\n' >&2
    printf 'omc-repro:        Likely cause: corrupted or partial install. Try re-running install.sh.\n' >&2
    printf 'omc-repro:        Override (NOT recommended): OMC_REPRO_ALLOW_UNREDACTED=1 bash omc-repro.sh ...\n' >&2
    exit 2
  fi
fi

# Redact user-prompt and assistant-message fields to the configured char
# cap. The comma-generator (not array literal) form of `reduce` iterates
# one field name per pass with `$k` bound to the string; `has($k)` guards
# against creating missing keys (naive `.[$k] |= ...` would set them to
# null). Non-string values are left untouched.
redact_session_state() {
  local src="$1"
  local dst="$2"
  local _tmp_truncated _tmp_safe k v
  _tmp_truncated="$(mktemp "${dst}.trunc.XXXXXX")" || { printf '{}\n' > "${dst}"; return 1; }
  jq --argjson n "${REDACT_CHARS}" '
    reduce ("last_user_prompt","last_assistant_message","current_objective","last_meta_request") as $k (.;
      if has($k) and (.[$k] | type == "string")
        then .[$k] = (.[$k] | .[0:$n])
        else .
      end
    )
  ' "${src}" > "${_tmp_truncated}" 2>/dev/null \
    || {
      # jq failed (corrupt JSON, etc.). Emit an empty object — an
      # unredacted leak is worse than a missing file in a bug-report.
      rm -f "${_tmp_truncated}"
      printf '{}\n' > "${dst}"
      return 1
    }
  # v1.40.x F-007: post-process the four redacted fields through
  # omc_redact_secrets so a secret in the first REDACT_CHARS chars
  # (e.g. "/ulw fix bug, key=sk-ant-XYZ...") is scrubbed before the
  # tarball ships. Each pass extracts the raw field value, pipes it
  # through omc_redact_secrets, and writes it back via jq --arg.
  cp "${_tmp_truncated}" "${dst}"
  rm -f "${_tmp_truncated}"
  for k in last_user_prompt last_assistant_message current_objective last_meta_request; do
    v="$(jq -r --arg k "${k}" 'if has($k) then .[$k] else "" end' "${dst}" 2>/dev/null)"
    [[ -z "${v}" || "${v}" == "null" ]] && continue
    v_safe="$(printf '%s' "${v}" | omc_redact_secrets)"
    _tmp_safe="$(mktemp "${dst}.safe.XXXXXX")" || continue
    if jq --arg k "${k}" --arg v "${v_safe}" 'if has($k) then .[$k] = $v else . end' "${dst}" > "${_tmp_safe}" 2>/dev/null; then
      mv "${_tmp_safe}" "${dst}"
    else
      rm -f "${_tmp_safe}"
    fi
  done
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
  local _tmp_trunc
  _tmp_trunc="$(mktemp "${dst}.trunc.XXXXXX")" || return 1
  jq -cR --arg field "${field}" --argjson n "${REDACT_CHARS}" '
    . as $line
    | try (
        fromjson
        | if type == "object" and has($field) and (.[$field] | type == "string")
            then .[$field] = (.[$field] | .[0:$n])
            else .
          end
      ) catch empty
  ' "${src}" > "${_tmp_trunc}" 2>/dev/null
  # v1.40.x F-007: scrub the truncated field through omc_redact_secrets
  # so secrets in chars 0..REDACT_CHARS-1 don't survive in the bundle.
  : > "${dst}"
  local row v v_safe
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    v="$(printf '%s' "${row}" | jq -r --arg f "${field}" 'if has($f) then .[$f] else "" end' 2>/dev/null)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      v_safe="$(printf '%s' "${v}" | omc_redact_secrets)"
      row="$(printf '%s' "${row}" | jq -c --arg f "${field}" --arg v "${v_safe}" 'if has($f) then .[$f] = $v else . end' 2>/dev/null)"
    fi
    printf '%s\n' "${row}" >> "${dst}"
  done < "${_tmp_trunc}"
  rm -f "${_tmp_trunc}"
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
# project state, not from user prompts. serendipity_log.jsonl carries
# fix descriptions and commit SHAs from record-serendipity.sh.
# gate_events.jsonl carries per-event outcome rows (gate-name, event-type,
# block counts, finding-status changes) — derived from gate emissions and
# state writes, no prompt content. They are included so that bug reports
# about Phase 8 / discovered-scope / Serendipity analytics / gate-fire
# attribution arrive with the wave plan, findings list, rule-application
# log, and per-event ledger the maintainer needs to reproduce the issue.
for name in \
    edited_files.log \
    stall_paths.log \
    pending_agents.jsonl \
    subagent_summaries.jsonl \
    discovered_scope.jsonl \
    findings.json \
    gate_events.jsonl \
    serendipity_log.jsonl; do
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
