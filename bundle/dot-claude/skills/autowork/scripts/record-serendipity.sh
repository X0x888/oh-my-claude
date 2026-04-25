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
if [[ -z "${SESSION_ID:-}" ]]; then
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
  conditions      (optional) — pipe/comma-separated: verified|same-path|bounded
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
  --arg ts "${ts}" \
  --arg session "${SESSION_ID}" \
  --arg fix "${fix}" \
  --arg orig "${original}" \
  --arg cond "${conditions}" \
  --arg sha "${commit_sha}" \
  '{ts:$ts, session:$session, fix:$fix, original_task:$orig, conditions:$cond, commit:$sha}')"

# Per-session log (JSONL append; line-sized writes are POSIX-atomic).
session_log="$(session_file "serendipity_log.jsonl")"
printf '%s\n' "${record}" >> "${session_log}"

# Cross-session aggregate.
cross_log="${HOME}/.claude/quality-pack/serendipity-log.jsonl"
mkdir -p "$(dirname "${cross_log}")"
printf '%s\n' "${record}" >> "${cross_log}"

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
