#!/usr/bin/env bash

set -euo pipefail

# Register a gate skip for the current ULW session.
# Usage: bash ulw-skip-register.sh "reason text"
#
# Writes gate_skip_reason, gate_skip_ts, and gate_skip_edit_ts (the edit
# clock at registration time) into session state under the state lock.
# The stop-guard checks that the edit clock has not advanced since the
# skip was registered — if new edits happened, the skip is stale.

SKIP_REASON="${1:-user override}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Find the most recent session directory
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # Pick the newest session DIRECTORY. The `*/` glob (not bare ls) is
  # load-bearing: the state root also holds files (hooks.log,
  # gate_events.jsonl) whose mtimes routinely out-sort session dirs —
  # bare `ls -t | head -1` picked hooks.log and ensure_session_dir
  # crashed on the file/dir collision (observed live 2026-07-05).
  # shellcheck disable=SC2012
  latest_session="$(cd "${STATE_ROOT}" 2>/dev/null && ls -td -- */ 2>/dev/null | head -1 || true)"
  latest_session="${latest_session%/}"
fi

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found.\n'
  exit 0
fi

SESSION_ID="${latest_session}"
ensure_session_dir

if ! is_ultrawork_mode; then
  printf 'ULW mode is not active. No skip registered.\n'
  exit 0
fi

# Capture the current edit clock so stop-guard can detect stale skips.
current_edit_ts="$(read_state "last_edit_ts")"
current_edit_ts="${current_edit_ts:-0}"

# v1.42.x stop-guard bypass closure (Bypass-Surface F-011 / forensic-
# observed #2): refuse /ulw-skip on the quality gate when reviewer
# findings remain unaddressed AND edits happened after the review.
#
# Live-session telemetry showed session 012e7a23 used the skip twice in
# a row to clear `review_unremediated=1` blocks with "release shipped"
# / "CI is the real gate" rationalizations. The skip was the
# post-release closeout shortcut for the post-edit reviewer-completeness
# gate. The pattern: reviewer flagged findings → agent edited code (or
# claimed to disposition in prose) → review-clock never re-advanced →
# stop-guard fired review_unremediated → /ulw-skip cleared it without
# requiring the reviewer to assent.
#
# Defense: when the imminent block IS the post-edit reviewer-completeness
# class (`review_had_findings=true` AND `last_edit_ts > last_review_ts`),
# refuse the skip and route to the legit recovery — re-run the reviewer.
# The reviewer agent is the only thing that can machine-verify the
# disposition. /ulw-skip is for false positives the reviewer cannot run,
# not for "the reviewer would assent if it could run".
#
# Bypass: `OMC_ULW_SKIP_FORCE=1` (audited via gate_events) for tests and
# for the user's explicit "yes I really mean it" recovery on the rare
# case where re-running the reviewer is genuinely impossible.
_review_had_findings="$(read_state "review_had_findings" 2>/dev/null || true)"
_last_review_ts="$(read_state "last_review_ts" 2>/dev/null || true)"
_last_review_ts="${_last_review_ts:-0}"
[[ "${current_edit_ts}" =~ ^[0-9]+$ ]] || current_edit_ts=0
[[ "${_last_review_ts}" =~ ^[0-9]+$ ]] || _last_review_ts=0

if [[ "${_review_had_findings}" == "true" ]] \
  && [[ "${current_edit_ts}" -gt "${_last_review_ts}" ]] \
  && [[ "${_last_review_ts}" -gt 0 ]] \
  && [[ "${OMC_ULW_SKIP_FORCE:-}" != "1" ]]; then
  record_gate_event "ulw-skip" "unremediated-refused" \
    "skipped_gate=quality" \
    "review_had_findings=true" \
    "last_edit_ts=${current_edit_ts}" \
    "last_review_ts=${_last_review_ts}" \
    "reason_preview=${SKIP_REASON:0:200}" 2>/dev/null || true
  cat >&2 <<EOF
ulw-skip: refused on unremediated post-edit reviewer-completeness gate.

Reviewer flagged findings (review_had_findings=true), and edits have
landed since the review (last_edit_ts=${current_edit_ts} > last_review_ts=${_last_review_ts}).

Skipping this gate with the supplied reason would close the loop on the
agent's word alone — the reviewer hasn't been re-run on the post-edit
state. This is the failure mode observed in v1.42.x telemetry (session
012e7a23 cleared two consecutive blocks via /ulw-skip with "release
shipped / CI watch is the real gate" rationalization).

Reason supplied: ${SKIP_REASON}

Recovery (preferred order):
  1. Re-run the reviewer on the post-edit diff. The reviewer can
     machine-verify the disposition. If it returns clean, the gate
     clears without needing /ulw-skip.
  2. If you genuinely dispositioned findings in prose this turn, name
     each finding + the disposition in your final summary. The reviewer
     pass on the NEXT stop attempt picks up the post-edit state.
  3. Last-resort override (audited): \`OMC_ULW_SKIP_FORCE=1 bash <script>\`.
     Use only when re-running the reviewer is genuinely impossible
     (network down, dependent service dead). The override is logged to
     gate_events.jsonl as 'ulw-skip force-bypass'.
EOF
  exit 4
fi

with_state_lock_batch \
  "gate_skip_reason" "${SKIP_REASON}" \
  "gate_skip_ts" "$(now_epoch)" \
  "gate_skip_edit_ts" "${current_edit_ts}" \
  "discovered_scope_blocks" "0"

# v1.42.x: audit the force-bypass when it fires so the override is
# observable in /ulw-report aggregations. The force path lets the user
# escape genuinely-stuck cases; we want telemetry on whether it's being
# used as a routine workaround.
if [[ "${_review_had_findings}" == "true" ]] \
  && [[ "${current_edit_ts}" -gt "${_last_review_ts}" ]] \
  && [[ "${_last_review_ts}" -gt 0 ]] \
  && [[ "${OMC_ULW_SKIP_FORCE:-}" == "1" ]]; then
  record_gate_event "ulw-skip" "force-bypass" \
    "skipped_gate=quality" \
    "review_had_findings=true" \
    "reason_preview=${SKIP_REASON:0:200}" 2>/dev/null || true
  # v1.42.x audit symmetry: per-session counter so /ulw-status can show
  # routine-vs-genuine-stuck usage at a glance. Mirrors the analogous
  # ulw_pause_force_count and ulw_correct_force_count increments.
  _skip_force_count="$(read_state "ulw_skip_force_count" 2>/dev/null || true)"
  _skip_force_count="${_skip_force_count:-0}"
  [[ "${_skip_force_count}" =~ ^[0-9]+$ ]] || _skip_force_count=0
  write_state "ulw_skip_force_count" "$((_skip_force_count + 1))" 2>/dev/null || true
fi

# v1.37.x W4 (Item 6): catch-quality logging for share-card weighting
# revisit. Pre-fix the skip count was global — wave-shape and discovered-
# scope blocks were weighted identically (360s) in the share-card with
# no signal as to whether wave-shape was actually catching real defects
# (under-decomposed plans) vs firing on every large plan submission.
# The /ulw-skip bypass is the user's "you got this wrong" feedback
# signal; joining skip → gate name lets future analysis re-weight the
# share card based on actual catch quality (skip-rate as false-positive
# proxy). The data path: tail the in-session gate_events.jsonl, find
# the most recent block event, record an `ulw-skip:registered` event
# referencing that gate. /ulw-report can then aggregate per-gate skip
# rates over a 2-week window.
events_file="$(session_file "gate_events.jsonl")"
recent_block_gate=""
if [[ -f "${events_file}" ]] && [[ -s "${events_file}" ]]; then
  # Tail-scan the latest 50 events for the most recent block. jq's
  # `select(.event == "block") | .gate` picks the gate name from the
  # last matching row. Fail-soft: a missing or malformed events file
  # leaves recent_block_gate empty and the catch-quality field reads
  # `unknown` — never blocks the skip.
  recent_block_gate="$(tail -50 "${events_file}" 2>/dev/null \
    | jq -rs 'map(select(.event == "block")) | last | .gate // empty' 2>/dev/null \
    || true)"
fi

if [[ -n "${recent_block_gate}" ]]; then
  record_gate_event "ulw-skip" "registered" \
    "skipped_gate=${recent_block_gate}" \
    "reason=${SKIP_REASON}"
else
  record_gate_event "ulw-skip" "registered" \
    "skipped_gate=unknown" \
    "reason=${SKIP_REASON}"
fi

printf 'Gate skip registered. The next stop attempt will pass.\n'
printf 'Reason: %s\n' "${SKIP_REASON}"
if [[ -n "${recent_block_gate}" ]]; then
  printf 'Skipped gate: %s (catch-quality logging — see /ulw-report when data accumulates).\n' "${recent_block_gate}"
fi
printf 'Note: If you make further edits, the skip will be invalidated.\n'
