#!/usr/bin/env bash
#
# tools/bootstrap-gate-events-rollup.sh — one-shot aggregator that
# walks every per-session `gate_events.jsonl` under
# `${STATE_ROOT}/<sid>/` and appends the rows (tagged with session_id
# + project_key) into the user-scope cross-session ledger
# `${HOME}/.claude/quality-pack/gate_events.jsonl`.
#
# Why this exists (v1.32.4): the natural sweep aggregates per-session
# telemetry into the user-scope rollup at session-stop / sweep time,
# but TTL gating (default 7 days) means recent telemetry doesn't reach
# the rollup for a week. v1.14.0 added the `gate_events.jsonl`
# per-event ledger; users who want to run `/ulw-report` analysis on
# the recent data without waiting for the natural TTL can run this
# bootstrap once. Idempotent — safe to re-run; rows are not
# deduplicated (the natural sweep doesn't dedupe either; the cap at
# rotation time is the bound).
#
# Developer-only — NOT installed by install.sh; lives under tools/.
#
# Usage:
#   bash tools/bootstrap-gate-events-rollup.sh           # run
#   bash tools/bootstrap-gate-events-rollup.sh --dry-run # preview

set -euo pipefail

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
DST_FILE="${HOME}/.claude/quality-pack/gate_events.jsonl"

if [[ ! -d "${STATE_ROOT}" ]]; then
  printf 'error: STATE_ROOT not found: %s\n' "${STATE_ROOT}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

# Walk every <sid>/gate_events.jsonl. Same project_key derivation as
# the natural sweep: read from the per-session session_state.json's
# .project_key field; empty string when missing.
total_rows=0
total_files=0

while IFS= read -r src_file; do
  [[ -z "${src_file}" ]] && continue
  [[ ! -s "${src_file}" ]] && continue

  sid_dir="$(dirname "${src_file}")"
  sid="$(basename "${sid_dir}")"

  # Skip the synthetic _watchdog session dir — it aggregates locally
  # via the v1.31.0 Wave 4 cap, NOT via the cross-session rollup.
  [[ "${sid}" == "_watchdog" ]] && continue

  # Derive project_key from session_state.json (same logic as
  # _sweep_append_gate_events in common.sh:1192-1198).
  pkey=""
  state_file="${sid_dir}/session_state.json"
  if [[ -f "${state_file}" ]]; then
    pkey="$(jq -r '.project_key // ""' "${state_file}" 2>/dev/null || echo "")"
  fi

  rows="$(wc -l < "${src_file}" 2>/dev/null | tr -d ' ' || echo 0)"
  total_files=$((total_files + 1))
  total_rows=$((total_rows + rows))

  if [[ "${dry_run}" -eq 1 ]]; then
    printf '  would-append  %s rows from %s (project_key=%s)\n' \
      "${rows}" "${sid}" "${pkey:-<empty>}"
    continue
  fi

  # Mirror _sweep_append_gate_events: tag each row with session_id +
  # (optionally) project_key, then append to the dst file.
  if [[ -n "${pkey}" ]]; then
    jq -c --arg sid "${sid}" --arg pkey "${pkey}" \
      '. + {session_id: $sid, project_key: $pkey}' \
      "${src_file}" 2>/dev/null \
      >> "${DST_FILE}" \
      || true
  else
    jq -c --arg sid "${sid}" \
      '. + {session_id: $sid}' \
      "${src_file}" 2>/dev/null \
      >> "${DST_FILE}" \
      || true
  fi
done < <(find "${STATE_ROOT}" -name 'gate_events.jsonl' -size +0 2>/dev/null)

if [[ "${dry_run}" -eq 1 ]]; then
  printf '\n[dry-run] %d sessions, %d total rows would be aggregated.\n' \
    "${total_files}" "${total_rows}"
  printf '[dry-run] Destination: %s\n' "${DST_FILE}"
  exit 0
fi

dst_rows="$(wc -l < "${DST_FILE}" 2>/dev/null | tr -d ' ' || echo 0)"
printf '\nAggregated %d sessions / %d source rows.\n' "${total_files}" "${total_rows}"
printf 'Destination: %s\n' "${DST_FILE}"
printf 'Total rows in destination: %d\n' "${dst_rows}"
