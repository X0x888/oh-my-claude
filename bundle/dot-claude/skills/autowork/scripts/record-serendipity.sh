#!/usr/bin/env bash
# record-serendipity.sh — log a Serendipity Rule application.
#
# The Serendipity Rule (core.md) governs in-session triage of verified
# adjacent defects: when a bug is discovered during unrelated work and
# meets the verified / same-code-path / bounded-fix conditions, it gets
# fixed in-session. This script captures each such application so the
# rule's effectiveness can be audited across sessions.
#
# Usage (JSON via stdin):
#   echo '{"fix":"<short>","original_task":"<short>","conditions":"verified|same-path|bounded","commit":"<optional sha>"}' \
#     | ~/.claude/skills/autowork/scripts/record-serendipity.sh
#
# Writes to:
#   <session>/serendipity_log.jsonl                    — per-session log
#   ~/.claude/quality-pack/serendipity-log.jsonl       — cross-session aggregate
# Updates session_state.json:
#   serendipity_count          — running count for the session
#   last_serendipity_ts        — last fire (epoch)
#   last_serendipity_fix       — short description of the most recent fix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# Hook-style guard: exit 0 on missing SESSION_ID so test/non-session
# invocations don't fail loudly.
#
# v1.40.x harness-improvement wave follow-up: when stdin has actual
# content (a Serendipity JSON payload waiting to be logged), emit a
# stderr warning before the silent exit. The hook-safety contract
# (exit 0 in non-session contexts) is preserved, but the warning
# saves the next user from the silent-failure trap the rule's author
# just hit when invoking from a shell where SESSION_ID wasn't
# exported — the call returned rc=0, the counter stayed at 0, and
# the catch was invisible until cross-checked against the per-session
# state. The `-t 0` test below would already catch interactive
# invocations; this branch catches piped-input cases.
if [[ -z "${SESSION_ID:-}" ]]; then
  if [[ ! -t 0 ]]; then
    cat <<'WARN' >&2
record-serendipity: SESSION_ID unset — payload discarded silently for hook-safety.
To log a Serendipity catch from a shell, run inside the active session
(SESSION_ID is set by the harness) or pass it explicitly:
  SESSION_ID="<session-uuid>" bash record-serendipity.sh < payload.json
WARN
  fi
  exit 0
fi

ensure_session_dir

if [[ -t 0 ]]; then
  cat <<'USAGE' >&2
record-serendipity: expected JSON on stdin
usage:
  echo '{"fix":"<short>","original_task":"<short>","conditions":"...","commit":"<sha>"}' \
    | record-serendipity.sh
fields:
  fix             (required) — one-line description of what was fixed
  original_task   (optional) — the task that was being worked on
  conditions      (optional) — pipe/comma-separated subset of:
                      verified   — reproduced or analogous to a defect just
                                   fixed with the same root-cause family
                      same-path  — lives in a file/function already loaded
                                   for the main task; same mental model
                      bounded    — does not expand the diff substantially or
                                   require separate investigation/planning/tests
                  All three must hold for the Serendipity Rule to fire (see
                  ~/.claude/quality-pack/memory/core.md → "The Serendipity Rule").
  commit          (optional) — short commit SHA if the fix shipped in a commit
USAGE
  exit 2
fi

input="$(cat)"
if [[ -z "${input//[[:space:]]/}" ]]; then
  printf 'record-serendipity: empty stdin\n' >&2
  exit 2
fi
if ! jq -e 'type == "object"' <<<"${input}" >/dev/null 2>&1; then
  printf 'record-serendipity: input must be a JSON object\n' >&2
  exit 2
fi

fix="$(jq -r '.fix // empty' <<<"${input}")"
if [[ -z "${fix}" ]]; then
  printf 'record-serendipity: input must include a non-empty "fix" field\n' >&2
  exit 2
fi

ts="$(date +%s)"
original="$(jq -r '.original_task // empty' <<<"${input}")"
conditions="$(jq -r '.conditions // empty' <<<"${input}")"
commit_sha="$(jq -r '.commit // empty' <<<"${input}")"

record="$(jq -nc \
  --argjson ts "${ts}" \
  --arg session_id "${SESSION_ID}" \
  --arg fix "${fix}" \
  --arg orig "${original}" \
  --arg cond "${conditions}" \
  --arg sha "${commit_sha}" \
  '{_v:1, ts:$ts, session_id:$session_id, fix:$fix, original_task:$orig, conditions:$cond, commit:$sha}')"
# v1.31.0 Wave 4 (data-lens F-2 + F-3 + F-5):
#   - --arg ts → --argjson ts: ts is now an integer everywhere, not
#     "1777133312" (string). show-report.sh's tonumber wrappers no
#     longer silently drop corrupt-typed rows.
#   - session → session_id: align the field name with every other
#     cross-session ledger so jq joins (gate_events × serendipity ×
#     session_summary) work without column-rename.
#   - _v:1 schema_version: future shape changes can be migrated with
#     a known boundary instead of post-hoc archaeology.

# Per-session log (JSONL append; line-sized writes are POSIX-atomic).
session_log="$(session_file "serendipity_log.jsonl")"
printf '%s\n' "${record}" >> "${session_log}"

# Cross-session aggregate. Tolerate write failure (e.g. read-only HOME)
# rather than aborting — the per-session log already captured the event,
# and aborting here would leave the state counter unincremented and
# diverged from the per-session log. The append is wrapped in
# with_cross_session_log_lock so concurrent SubagentStop hooks across
# sessions cannot interleave bytes mid-row in the shared cross-session
# aggregate.
cross_log="${HOME}/.claude/quality-pack/serendipity-log.jsonl"
mkdir -p "$(dirname "${cross_log}")" 2>/dev/null || true
_do_serendipity_append() {
  { printf '%s\n' "${record}" >> "${cross_log}"; } 2>/dev/null || \
    log_anomaly "record-serendipity" "cross-session log write failed: ${cross_log}"
}
with_cross_session_log_lock "${cross_log}" _do_serendipity_append || true

# Update session counters under lock so concurrent SubagentStops
# don't race on the read-modify-write.
_update_serendipity_state() {
  local current
  current="$(read_state "serendipity_count")"
  current="${current:-0}"
  write_state_batch \
    "serendipity_count" "$((current + 1))" \
    "last_serendipity_ts" "${ts}" \
    "last_serendipity_fix" "${fix}"
}
with_state_lock _update_serendipity_state

printf 'Logged Serendipity event: %s\n' "${fix}" >&2
exit 0
