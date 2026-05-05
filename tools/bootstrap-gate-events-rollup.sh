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
# bootstrap once.
#
# v1.32.5 fixes (release-reviewer dogfood pass):
# - **NOT idempotent.** The natural sweep is idempotent because it
#   `rm -rf`s the source dir after appending; this bootstrap leaves
#   sources in place, so re-running double-counts. Per-source
#   `.bootstrap-aggregated` stamp file added to skip already-
#   aggregated sessions on subsequent runs. To force re-aggregation
#   of one session, delete its stamp; to start fresh, truncate the
#   destination and remove all stamps.
# - **Cross-session log lock** acquired via `with_cross_session_log_lock`
#   to prevent row-tearing under PIPE_BUF if a watchdog tick or
#   active hook writes to the dst concurrently.
# - **Fixture-dir filter.** Skip session dirs whose names don't match
#   the UUID shape (`[0-9a-f]{8}-...`). Closes a contamination
#   surface where prometheus-suggest perf benchmarks / classifier
#   replays leaked fixture rows into the rollup.
# - **`project_key` honest-empty.** `session_state.json` doesn't yet
#   persist `.project_key` (v1.31.0 Wave 4 wired the read path but
#   never the write path); all rows correctly tag `project_key: null`
#   until that wiring debt is closed.
#
# Developer-only — NOT installed by install.sh; lives under tools/.
#
# Usage:
#   bash tools/bootstrap-gate-events-rollup.sh           # run, skip stamped
#   bash tools/bootstrap-gate-events-rollup.sh --dry-run # preview
#   bash tools/bootstrap-gate-events-rollup.sh --force   # ignore stamps

set -euo pipefail

dry_run=0
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --force)   force=1; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"
DST_FILE="${HOME}/.claude/quality-pack/gate_events.jsonl"
STAMP_NAME=".bootstrap-aggregated"

if [[ ! -d "${STATE_ROOT}" ]]; then
  printf 'error: STATE_ROOT not found: %s\n' "${STATE_ROOT}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

# Source common.sh for with_cross_session_log_lock (v1.32.5 lock-fix).
# Falls back to bare append if not available (e.g., user invoked from
# a checkout where common.sh is somewhere else); the warning makes the
# degraded mode auditable rather than silent.
COMMON_SH="${COMMON_SH:-${HOME}/.claude/skills/autowork/scripts/common.sh}"
if [[ -f "${COMMON_SH}" ]]; then
  # shellcheck source=/dev/null
  . "${COMMON_SH}"
else
  printf 'warn: %s not found — appending without cross-session log lock; row tearing possible under concurrent watchdog tick\n' \
    "${COMMON_SH}" >&2
fi

# _do_append_one — bare-append helper invoked under
# with_cross_session_log_lock when available, or directly otherwise.
# Args: src_file sid pkey
_do_append_one() {
  local src="$1" sid="$2" pkey="$3"
  if [[ -n "${pkey}" ]]; then
    jq -c --arg sid "${sid}" --arg pkey "${pkey}" \
      '. + {session_id: $sid, project_key: $pkey}' \
      "${src}" 2>/dev/null \
      >> "${DST_FILE}" \
      || true
  else
    jq -c --arg sid "${sid}" \
      '. + {session_id: $sid}' \
      "${src}" 2>/dev/null \
      >> "${DST_FILE}" \
      || true
  fi
}

# Walk every <sid>/gate_events.jsonl.
total_rows=0
total_files=0
skipped_stamped=0
skipped_fixture=0
skipped_watchdog=0

while IFS= read -r src_file; do
  [[ -z "${src_file}" ]] && continue
  [[ ! -s "${src_file}" ]] && continue

  sid_dir="$(dirname "${src_file}")"
  sid="$(basename "${sid_dir}")"

  # Skip the synthetic _watchdog session dir — it aggregates locally
  # via the v1.31.0 Wave 4 cap, NOT via the cross-session rollup.
  if [[ "${sid}" == "_watchdog" ]]; then
    skipped_watchdog=$((skipped_watchdog + 1))
    continue
  fi

  # v1.32.5 fixture-dir filter: skip session dirs whose names don't
  # match the UUID shape (8-4-4-4-12 hex). Closes the contamination
  # surface where prometheus-suggest perf benchmarks / classifier
  # replays (with names like `p4-2398`, `ip-2`, `p1-foo`) leaked
  # fixture rows into the rollup.
  if [[ ! "${sid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    skipped_fixture=$((skipped_fixture + 1))
    if [[ "${dry_run}" -eq 1 ]]; then
      printf '  skip-fixture  %s (non-UUID shape)\n' "${sid}"
    fi
    continue
  fi

  # v1.32.5 idempotency stamp: if this session has already been
  # bootstrap-aggregated, skip it. The stamp lives at the source
  # session's own .bootstrap-aggregated marker — separate from any
  # other state on the system. --force ignores stamps.
  stamp="${sid_dir}/${STAMP_NAME}"
  if [[ "${force}" -ne 1 ]] && [[ -f "${stamp}" ]]; then
    skipped_stamped=$((skipped_stamped + 1))
    if [[ "${dry_run}" -eq 1 ]]; then
      printf '  skip-stamped  %s (already aggregated; --force to override)\n' "${sid}"
    fi
    continue
  fi

  # Derive project_key from session_state.json (same logic as
  # _sweep_append_gate_events in common.sh:1192-1198). Currently
  # always empty because no code writes project_key into session_state
  # — see v1.32.5 docstring header for the v1.31.0 wiring debt.
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

  # Append under cross-session log lock when available, bare otherwise.
  if declare -f with_cross_session_log_lock >/dev/null 2>&1; then
    with_cross_session_log_lock "${DST_FILE}" \
      _do_append_one "${src_file}" "${sid}" "${pkey}" \
      || _do_append_one "${src_file}" "${sid}" "${pkey}"
  else
    _do_append_one "${src_file}" "${sid}" "${pkey}"
  fi

  # Mark the source as aggregated so subsequent runs skip it.
  : > "${stamp}"
done < <(find "${STATE_ROOT}" -name 'gate_events.jsonl' -size +0 2>/dev/null)

if [[ "${dry_run}" -eq 1 ]]; then
  printf '\n[dry-run] %d sessions, %d total rows would be aggregated.\n' \
    "${total_files}" "${total_rows}"
  printf '[dry-run] Skipped: %d stamped, %d fixture, %d _watchdog\n' \
    "${skipped_stamped}" "${skipped_fixture}" "${skipped_watchdog}"
  printf '[dry-run] Destination: %s\n' "${DST_FILE}"
  exit 0
fi

dst_rows="$(wc -l < "${DST_FILE}" 2>/dev/null | tr -d ' ' || echo 0)"
printf '\nAggregated %d sessions / %d source rows.\n' "${total_files}" "${total_rows}"
printf 'Skipped: %d stamped, %d fixture, %d _watchdog\n' \
  "${skipped_stamped}" "${skipped_fixture}" "${skipped_watchdog}"
printf 'Destination: %s\n' "${DST_FILE}"
printf 'Total rows in destination: %d\n' "${dst_rows}"
