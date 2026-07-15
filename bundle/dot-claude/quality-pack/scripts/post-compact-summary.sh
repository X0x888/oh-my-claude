#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
TRIGGER="$(json_get '.trigger')"
COMPACT_SUMMARY="$(json_get '.compact_summary')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

# Gap 6 — harden compact_summary handling. The PostCompact hook schema
# documents .compact_summary as a string field (verified against
# code.claude.com/docs/en/hooks), but schemas can change and we have no
# runtime guarantee the field is populated. On absence, emit a visible
# fallback marker and surface a warning in hooks.log so the gap is
# diagnosable instead of silently empty in the handoff file.
compact_summary_missing=0
if [[ -z "${COMPACT_SUMMARY}" ]]; then
  compact_summary_missing=1
  COMPACT_SUMMARY="(compact summary not provided by runtime — see compact_debug.log if HOOK_DEBUG is enabled)"
  log_hook "post-compact-summary" "warn: .compact_summary field empty or missing"
fi

# The runtime supplies its native summary to the resumed model directly. Keep
# only a bounded diagnostic copy in state; duplicating the full body inside our
# SessionStart handoff spends context without adding continuity information.
COMPACT_SUMMARY_STATE="$(truncate_chars 1800 "$(printf '%s' "${COMPACT_SUMMARY}" | tr -d '\000-\010\013-\014\016-\037\177' | omc_redact_secrets)")"

# Optional raw-hook-JSON debug log — enabled via HOOK_DEBUG=1 env var or
# hook_debug=true in oh-my-claude.conf. Useful when diagnosing schema
# drift in a future Claude Code release.
if is_hook_debug; then
  debug_file="$(session_file "compact_debug.log")"
  {
    printf '=== PostCompact @ %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "${HOOK_JSON}"
  } >>"${debug_file}" 2>/dev/null || true
fi

# Gap 2 — set just_compacted flag so the next UserPromptSubmit in
# prompt-intent-router can bias classification toward continuation.
write_state_batch \
  "last_compact_trigger" "${TRIGGER:-unknown}" \
  "last_compact_summary" "${COMPACT_SUMMARY_STATE}" \
  "last_compact_summary_ts" "$(now_epoch)" \
  "just_compacted" "1" \
  "just_compacted_ts" "$(now_epoch)"

combined_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"

{
  printf '# Compact Handoff\n\n'
  printf 'The runtime native compact summary is already present and is not duplicated here.\n'
  if [[ "${compact_summary_missing}" -eq 1 ]]; then
    printf '\n## Runtime Summary Diagnostic\n%s\n' "${COMPACT_SUMMARY_STATE}"
  fi

  if [[ -f "${snapshot_file}" ]]; then
    printf '\n## Preserved Priority State\n'
    cat "${snapshot_file}"
    printf '\n'
  fi
} >"${combined_file}"
