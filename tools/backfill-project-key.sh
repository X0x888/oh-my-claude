#!/usr/bin/env bash
#
# tools/backfill-project-key.sh — one-shot backfill that walks every
# `${STATE_ROOT}/<sid>/session_state.json` with `cwd` set but
# `project_key` unset, computes `_omc_project_key` from the recorded
# cwd, and writes it back. Closes the historical-data gap left by
# the v1.31.0 → v1.32.5 wiring debt.
#
# Why this exists (v1.32.9): v1.32.6 wired `project_key` writes for
# new sessions; v1.32.8 extended that to non-ULW session-start. But
# session_state.json files written before v1.32.6 still carry no
# `project_key`. When those pre-1.32.6 sessions age past TTL and
# get swept, the natural sweep at common.sh:1193 reads `project_key:
# ""` from state, tags rows with empty project_key, and the multi-
# project /ulw-report slicing surface stays broken for that backlog.
# v1.32.6 CHANGELOG claimed "backfill not feasible because
# session_state.json doesn't carry the value" — but `cwd` IS
# populated for ~half the historical sessions, and `_omc_project_key`
# only needs cwd to compute. The v1.32.8 reviewer pointed this out
# as the deferred follow-up that should ship before the backlog
# starts to age out.
#
# Idempotent — safe to re-run; sessions with `project_key` already
# set are skipped silently. `--dry-run` previews counts without
# writing.
#
# Skips:
#   - _watchdog session (synthetic; no project)
#   - non-UUID-shape session dirs (fixture contamination — same
#     filter shape as v1.32.5 bootstrap-gate-events-rollup.sh)
#   - sessions where cwd is empty (can't compute project_key)
#   - sessions where project_key is already set (idempotent skip)
#
# Developer-only — NOT installed by install.sh; lives under tools/.
#
# Usage:
#   bash tools/backfill-project-key.sh           # backfill missing keys
#   bash tools/backfill-project-key.sh --dry-run # preview counts

set -euo pipefail

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

STATE_ROOT="${STATE_ROOT:-${HOME}/.claude/quality-pack/state}"

if [[ ! -d "${STATE_ROOT}" ]]; then
  printf 'error: STATE_ROOT not found: %s\n' "${STATE_ROOT}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required\n' >&2
  exit 1
fi

# Source common.sh for _omc_project_key. Falls back to a degraded
# direct-shasum mode if common.sh isn't reachable; the warning
# makes the fallback auditable.
COMMON_SH="${COMMON_SH:-${HOME}/.claude/skills/autowork/scripts/common.sh}"
if [[ -f "${COMMON_SH}" ]]; then
  # shellcheck source=/dev/null
  . "${COMMON_SH}"
else
  printf 'warn: %s not found — _omc_project_key unavailable; cannot proceed\n' \
    "${COMMON_SH}" >&2
  exit 1
fi

backfilled=0
skipped_already_set=0
skipped_no_cwd=0
skipped_fixture=0
skipped_watchdog=0
errors=0

while IFS= read -r state_file; do
  [[ -z "${state_file}" ]] && continue
  [[ ! -f "${state_file}" ]] && continue

  sid_dir="$(dirname "${state_file}")"
  sid="$(basename "${sid_dir}")"

  if [[ "${sid}" == "_watchdog" ]]; then
    skipped_watchdog=$((skipped_watchdog + 1))
    continue
  fi

  if [[ ! "${sid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    skipped_fixture=$((skipped_fixture + 1))
    continue
  fi

  # Read cwd + existing project_key.
  cwd="$(jq -r '.cwd // ""' "${state_file}" 2>/dev/null || echo "")"
  existing="$(jq -r '.project_key // ""' "${state_file}" 2>/dev/null || echo "")"

  if [[ -n "${existing}" ]]; then
    skipped_already_set=$((skipped_already_set + 1))
    continue
  fi

  if [[ -z "${cwd}" ]]; then
    skipped_no_cwd=$((skipped_no_cwd + 1))
    continue
  fi

  # Compute project_key from cwd. _omc_project_key relies on the
  # current PWD via `git config --get remote.origin.url`. Run inside
  # a subshell that cd's to the recorded cwd so the lookup matches
  # what the LIVE session would have computed at write time.
  if [[ ! -d "${cwd}" ]]; then
    # cwd dir no longer exists (project moved/deleted) — compute via
    # _omc_project_id fallback shape (cwd hash). Same fallback the
    # live function uses when there's no remote.
    key="$(printf '%s' "${cwd}" | shasum -a 256 2>/dev/null | cut -c1-12)"
  else
    key="$(cd "${cwd}" 2>/dev/null && _omc_project_key 2>/dev/null || true)"
  fi

  if [[ -z "${key}" ]]; then
    errors=$((errors + 1))
    if [[ "${dry_run}" -eq 1 ]]; then
      printf '  ERROR: %s — could not compute project_key from cwd=%s\n' "${sid}" "${cwd}" >&2
    fi
    continue
  fi

  if [[ "${dry_run}" -eq 1 ]]; then
    printf '  would-write  %s ← project_key=%s (cwd=%s)\n' "${sid}" "${key}" "${cwd}"
    backfilled=$((backfilled + 1))
    continue
  fi

  # Write back atomically — jq filter + temp file + mv.
  tmp_file="$(mktemp "${state_file}.XXXXXX")"
  if jq --arg k "${key}" '.project_key = $k' "${state_file}" > "${tmp_file}" 2>/dev/null; then
    mv "${tmp_file}" "${state_file}"
    backfilled=$((backfilled + 1))
  else
    rm -f "${tmp_file}" 2>/dev/null || true
    errors=$((errors + 1))
  fi
done < <(find "${STATE_ROOT}" -name 'session_state.json' 2>/dev/null)

if [[ "${dry_run}" -eq 1 ]]; then
  printf '\n[dry-run] %d backfilled, %d already-set, %d no-cwd, %d fixture, %d _watchdog, %d errors\n' \
    "${backfilled}" "${skipped_already_set}" "${skipped_no_cwd}" "${skipped_fixture}" "${skipped_watchdog}" "${errors}"
  exit 0
fi

printf '\nBackfilled %d session_state.json files.\n' "${backfilled}"
printf 'Skipped: %d already-set, %d no-cwd, %d fixture, %d _watchdog\n' \
  "${skipped_already_set}" "${skipped_no_cwd}" "${skipped_fixture}" "${skipped_watchdog}"
if [[ "${errors}" -gt 0 ]]; then
  printf 'Errors: %d (see stderr)\n' "${errors}"
  exit 1
fi
exit 0
