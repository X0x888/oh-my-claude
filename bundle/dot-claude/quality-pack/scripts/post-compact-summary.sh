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
if [[ -z "${COMPACT_SUMMARY}" ]]; then
  COMPACT_SUMMARY="(compact summary not provided by runtime — see compact_debug.log if HOOK_DEBUG is enabled)"
  log_hook "post-compact-summary" "warn: .compact_summary field empty or missing"
fi

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
  "last_compact_summary" "${COMPACT_SUMMARY}" \
  "last_compact_summary_ts" "$(now_epoch)" \
  "just_compacted" "1" \
  "just_compacted_ts" "$(now_epoch)"

combined_file="$(session_file "compact_handoff.md")"
snapshot_file="$(session_file "precompact_snapshot.md")"

{
  printf '# Compact Handoff\n\n'
  printf '## Native Compact Summary\n%s\n' "${COMPACT_SUMMARY}"

  if [[ -f "${snapshot_file}" ]]; then
    printf '\n## Preserved Live State\n'
    cat "${snapshot_file}"
    printf '\n'
  fi
} >"${combined_file}"
