#!/usr/bin/env bash
# record-self-audit.sh — stamp completion of a `/council --self-audit`
# pass so session-start-self-audit-nudge.sh's 90-day staleness check
# has a fresh baseline. `/council --self-audit` is a markdown-driven
# agentic protocol with no backing script, so there is no natural
# "on completion" hook to wire this automatically — run this by hand
# (or have the agent run it) right after a self-audit finishes:
#
#   bash ~/.claude/quality-pack/scripts/record-self-audit.sh
#
# Preserves last_self_audit_nudge_ts if present; only overwrites `ts`.

set -euo pipefail

FILE="${HOME}/.claude/quality-pack/last-self-audit.json"
mkdir -p "$(dirname "${FILE}")"
ts="$(date +%s)"
tmp="$(mktemp "${FILE}.XXXXXX")"
if [[ -f "${FILE}" ]] && jq --argjson ts "${ts}" '.ts = $ts' "${FILE}" > "${tmp}" 2>/dev/null; then
  :
else
  jq -nc --argjson ts "${ts}" '{ts: $ts}' > "${tmp}"
fi
mv "${tmp}" "${FILE}"
printf 'Recorded self-audit completion at %s (%s)\n' "${ts}" "${FILE}"
