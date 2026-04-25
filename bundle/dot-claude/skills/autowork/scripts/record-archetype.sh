#!/usr/bin/env bash
# record-archetype.sh — log an archetype application for cross-session memory.
#
# When a UI specialist (frontend-developer, ios-ui-developer) emits its
# 9-section Design Contract, the contract names a closest archetype as
# its anchor (Stripe, Linear, Things 3, lazygit, etc.). This script
# captures each application keyed by project so the prompt router can
# warn the agent against repeating the same archetype on later sessions
# in the same project — closing the v1.15.0 metis-F7 deferred
# "cross-session archetype memory" gap.
#
# Project keying uses `_omc_project_key` (git-remote-first, cwd
# fallback) so the memory survives worktree paths and bare clones at
# different locations.
#
# Usage (JSON via stdin):
#   echo '{"archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}' \
#     | ~/.claude/skills/autowork/scripts/record-archetype.sh
#
# Multi-row form (one row per matched archetype, newline-separated):
#   echo -e '{"archetype":"Stripe", ...}\n{"archetype":"Linear", ...}' | record-archetype.sh
#
# Writes to:
#   ~/.claude/quality-pack/used-archetypes.jsonl  — cross-session aggregate
# Each row: {ts, session, project_key, archetype, platform, domain, agent}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# Hook-style guard: never block the parent flow on missing session.
if [[ -z "${SESSION_ID:-}" ]]; then
  exit 0
fi

if [[ -t 0 ]]; then
  cat <<'USAGE' >&2
record-archetype: expected JSON on stdin (one object per line)
usage:
  echo '{"archetype":"Stripe","platform":"web","domain":"fintech","agent":"frontend-developer"}' \
    | record-archetype.sh
fields:
  archetype  (required) — short name (e.g. Stripe, Linear, Things 3, lazygit)
  platform   (optional) — web | ios | macos | cli | unknown
  domain     (optional) — fintech | wellness | creative | devtool | editorial | …
  agent      (optional) — emitting agent (frontend-developer | ios-ui-developer)
USAGE
  exit 2
fi

cross_log="${HOME}/.claude/quality-pack/used-archetypes.jsonl"
mkdir -p "$(dirname "${cross_log}")" 2>/dev/null || true

ts="$(date +%s)"
project_key="$(_omc_project_key 2>/dev/null || echo "unknown")"

# Read every JSON object from stdin. One row per archetype emission so
# the same contract can record multiple priors when the agent named
# more than one anchor (e.g. "closest is Stripe, also drawing from
# Linear's restraint").
written=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
    continue
  fi
  archetype="$(jq -r '.archetype // empty' <<<"${line}")"
  if [[ -z "${archetype}" ]]; then
    continue
  fi
  platform="$(jq -r '.platform // empty' <<<"${line}")"
  domain="$(jq -r '.domain // empty' <<<"${line}")"
  agent="$(jq -r '.agent // empty' <<<"${line}")"

  record="$(jq -nc \
    --arg ts "${ts}" \
    --arg session "${SESSION_ID}" \
    --arg pkey "${project_key}" \
    --arg arch "${archetype}" \
    --arg plat "${platform}" \
    --arg dom "${domain}" \
    --arg ag "${agent}" \
    '{ts:$ts, session:$session, project_key:$pkey, archetype:$arch, platform:$plat, domain:$dom, agent:$ag}')"

  # Cross-session aggregate. Tolerate write failure (read-only HOME,
  # disk full, etc.) — the archetype record is advisory, not load-
  # bearing. Aborting would cause the SubagentStop hook to fail and
  # break unrelated downstream consumers.
  { printf '%s\n' "${record}" >> "${cross_log}"; } 2>/dev/null || \
    log_anomaly "record-archetype" "cross-session log write failed: ${cross_log}"
  written=$((written + 1))
done

if [[ "${written}" -eq 0 ]]; then
  printf 'record-archetype: no valid rows on stdin\n' >&2
  exit 2
fi

exit 0
