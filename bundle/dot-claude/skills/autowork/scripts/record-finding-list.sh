#!/usr/bin/env bash
# record-finding-list.sh — Master finding list for council Phase 8 execution.
#
# Persists the per-session findings.json that bridges council assessment
# to wave-based implementation. Provides atomic status updates so the
# model can track shipped/deferred/rejected without re-writing the whole
# document and risking corruption.
#
# Usage:
#   record-finding-list.sh init [--force]  # read JSON from stdin and create file.
#                                          # Refuses to clobber an active wave plan
#                                          # (waves[] non-empty) unless --force.
#   record-finding-list.sh add-finding     # read a single finding JSON object from
#                                          # stdin and append to .findings (use this
#                                          # when a wave reveals a new finding mid-
#                                          # execution that wasn't in the master list)
#   record-finding-list.sh path            # print absolute path to findings.json
#   record-finding-list.sh status <id> <status> [<commit_sha>] [<notes>]
#                                          # status: shipped | deferred | rejected | in_progress | pending
#   record-finding-list.sh assign-wave <wave_idx> <wave_total> <surface> <id> [<id>...]
#   record-finding-list.sh wave-status <wave_idx> <status> [<commit_sha>]
#                                          # status: pending | in_progress | completed
#   record-finding-list.sh show            # print current findings.json (pretty)
#   record-finding-list.sh summary         # markdown summary table for final report
#   record-finding-list.sh counts          # one-line counts (total/shipped/deferred/etc.)
#
# Resuming a session: if findings.json already exists with a non-empty
# waves[] array, run `counts` first to see where execution stands; do NOT
# call `init` again (that would clobber the wave plan and lose progress).
# Re-enter Phase 8 at the in-progress wave instead.
#
# Schema (findings.json):
#   {
#     "version": 1,
#     "created_ts": <epoch>,
#     "updated_ts": <epoch>,
#     "findings": [
#       { "id": "F-001", "summary": "...", "severity": "critical|high|medium|low",
#         "surface": "auth/login", "effort": "S|M|L", "lens": "security-lens",
#         "wave": <int|null>, "status": "pending|in_progress|shipped|deferred|rejected",
#         "commit_sha": "...", "notes": "...", "ts": <epoch> }
#     ],
#     "waves": [
#       { "index": 1, "total": 5, "surface": "auth", "finding_ids": ["F-001","F-002"],
#         "status": "pending|in_progress|completed", "commit_sha": "...", "ts": <epoch> }
#     ]
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Discover the active session via the shared helper in common.sh.
# Invoked manually mid-session — no hook JSON to read SESSION_ID from.
SESSION_ID="$(discover_latest_session)"
if [[ -z "${SESSION_ID}" ]]; then
  printf 'record-finding-list: no active session found under %s\n' "${STATE_ROOT}" >&2
  exit 1
fi

ensure_session_dir
FINDINGS_FILE="$(session_file "findings.json")"
LOCKDIR="${FINDINGS_FILE}.lock"

_now() { date +%s; }

# Lock retry: 50 attempts × 0.1s sleep = ~5s effective timeout.
LOCK_RETRIES=50
LOCK_SLEEP_S=0.1

_acquire_lock() {
  # Install the trap BEFORE the mkdir loop so a SIGINT delivered between
  # mkdir success and the trap install can't orphan the lock directory.
  # The trap's rmdir is a safe no-op when LOCKDIR doesn't yet exist.
  trap '_release_lock' EXIT INT TERM
  local i=0
  while ! mkdir "${LOCKDIR}" 2>/dev/null; do
    i=$((i + 1))
    if [[ "${i}" -gt "${LOCK_RETRIES}" ]]; then
      printf 'record-finding-list: lock timeout on %s (waited ~%ss)\n' \
        "${LOCKDIR}" "$(awk "BEGIN { print ${LOCK_RETRIES} * ${LOCK_SLEEP_S} }")" >&2
      trap - EXIT INT TERM
      return 1
    fi
    sleep "${LOCK_SLEEP_S}"
  done
}

_release_lock() {
  rmdir "${LOCKDIR}" 2>/dev/null || true
}

_atomic_write() {
  local content="$1"
  local tmp="${FINDINGS_FILE}.tmp.$$"
  printf '%s\n' "${content}" >"${tmp}"
  mv -f "${tmp}" "${FINDINGS_FILE}"
}

_init_empty() {
  jq -n --argjson ts "$(_now)" \
    '{version:1, created_ts:$ts, updated_ts:$ts, findings:[], waves:[]}'
}

_ensure_file() {
  if [[ ! -f "${FINDINGS_FILE}" ]]; then
    _init_empty >"${FINDINGS_FILE}"
  fi
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  init)
    force=0
    if [[ "${1:-}" == "--force" ]]; then
      force=1
      shift || true
    fi
    # Refuse to clobber an active wave plan unless --force. This protects a
    # resumed session: if the model crashes after wave 2/5 and a new turn
    # blindly re-runs `init`, we'd otherwise overwrite waves[] and lose all
    # commit/status progress on shipped findings.
    if [[ "${force}" -eq 0 && -f "${FINDINGS_FILE}" ]]; then
      existing_waves="$(jq -r '(.waves // []) | length' "${FINDINGS_FILE}" 2>/dev/null || printf '0')"
      if [[ "${existing_waves}" -gt 0 ]]; then
        printf 'record-finding-list init: refusing to overwrite an active wave plan.\n' >&2
        printf '  %s already has %s wave(s).\n' "${FINDINGS_FILE}" "${existing_waves}" >&2
        # shellcheck disable=SC2016  # backticks are literal in the error text.
        printf '  Run `record-finding-list counts` to inspect progress and resume the\n' >&2
        printf '  in-progress wave. To start over from scratch, re-run with --force.\n' >&2
        exit 1
      fi
    fi
    input="$(cat)"
    if [[ -z "${input}" ]]; then
      printf 'record-finding-list init: empty stdin\n' >&2
      exit 1
    fi
    # Accept either { "findings": [...] } or a bare [...] array.
    if printf '%s' "${input}" | jq -e 'type=="array"' >/dev/null 2>&1; then
      findings_json="${input}"
    else
      findings_json="$(printf '%s' "${input}" | jq '.findings // []')"
    fi
    # Stamp ts/status defaults so downstream queries never see undefined fields.
    normalized="$(printf '%s' "${findings_json}" | jq --argjson ts "$(_now)" \
      '[.[] | . + {
        ts: (.ts // $ts),
        status: (.status // "pending"),
        wave: (.wave // null),
        commit_sha: (.commit_sha // ""),
        notes: (.notes // "")
      }]')"
    _acquire_lock
    new_doc="$(jq -n \
      --argjson ts "$(_now)" \
      --argjson findings "${normalized}" \
      '{version:1, created_ts:$ts, updated_ts:$ts, findings:$findings, waves:[]}')"
    _atomic_write "${new_doc}"
    count="$(jq 'length' <<<"${normalized}")"
    printf 'Initialized %s with %s findings.\n' "${FINDINGS_FILE}" "${count}"
    ;;

  add-finding)
    input="$(cat)"
    if [[ -z "${input}" ]]; then
      printf 'record-finding-list add-finding: empty stdin\n' >&2
      exit 1
    fi
    if ! printf '%s' "${input}" | jq -e 'type=="object" and has("id")' >/dev/null 2>&1; then
      printf 'record-finding-list add-finding: stdin must be a JSON object with an "id" field\n' >&2
      exit 1
    fi
    new_id="$(printf '%s' "${input}" | jq -r '.id')"
    _ensure_file
    _acquire_lock
    current="$(cat "${FINDINGS_FILE}")"
    if printf '%s' "${current}" | jq -e --arg id "${new_id}" \
        '[.findings[] | select(.id == $id)] | length > 0' >/dev/null 2>&1; then
      # shellcheck disable=SC2016  # backticks are literal in the error text.
      printf 'record-finding-list add-finding: id %s already exists; use `status` to update\n' \
        "${new_id}" >&2
      exit 1
    fi
    normalized="$(printf '%s' "${input}" | jq --argjson ts "$(_now)" \
      '. + {
        ts: (.ts // $ts),
        status: (.status // "pending"),
        wave: (.wave // null),
        commit_sha: (.commit_sha // ""),
        notes: (.notes // "")
      }')"
    updated="$(printf '%s' "${current}" | jq \
      --argjson finding "${normalized}" \
      --argjson ts "$(_now)" '
      .updated_ts = $ts |
      .findings += [$finding]')"
    _atomic_write "${updated}"
    printf 'F=%s added (status=pending)\n' "${new_id}"
    ;;

  path)
    printf '%s\n' "${FINDINGS_FILE}"
    ;;

  status)
    id="${1:-}"; status="${2:-}"; commit_sha="${3:-}"; notes="${4:-}"
    if [[ -z "${id}" || -z "${status}" ]]; then
      printf 'usage: record-finding-list status <id> <status> [<commit_sha>] [<notes>]\n' >&2
      exit 1
    fi
    case "${status}" in
      pending|in_progress|shipped|deferred|rejected) ;;
      *) printf 'invalid status: %s (expected pending|in_progress|shipped|deferred|rejected)\n' "${status}" >&2; exit 1 ;;
    esac
    _ensure_file
    _acquire_lock
    current="$(cat "${FINDINGS_FILE}")"
    updated="$(printf '%s' "${current}" | jq \
      --arg id "${id}" \
      --arg status "${status}" \
      --arg commit_sha "${commit_sha}" \
      --arg notes "${notes}" \
      --argjson ts "$(_now)" '
      .updated_ts = $ts |
      .findings = (.findings | map(
        if .id == $id then
          . + {
            status: $status,
            commit_sha: (if $commit_sha == "" then .commit_sha else $commit_sha end),
            notes: (if $notes == "" then .notes else $notes end),
            ts: $ts
          }
        else . end
      ))')"
    _atomic_write "${updated}"
    printf 'F=%s status=%s\n' "${id}" "${status}"
    ;;

  assign-wave)
    wave_idx="${1:-}"; wave_total="${2:-}"; surface="${3:-}"
    if [[ -z "${wave_idx}" || -z "${wave_total}" || -z "${surface}" ]] || ! shift 3 || [[ $# -eq 0 ]]; then
      printf 'usage: record-finding-list assign-wave <idx> <total> <surface> <id> [<id>...]\n' >&2
      exit 1
    fi
    ids_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    _ensure_file
    _acquire_lock
    current="$(cat "${FINDINGS_FILE}")"
    updated="$(printf '%s' "${current}" | jq \
      --argjson idx "${wave_idx}" \
      --argjson total "${wave_total}" \
      --arg surface "${surface}" \
      --argjson ids "${ids_json}" \
      --argjson ts "$(_now)" '
      .updated_ts = $ts |
      .findings = (.findings | map(
        if (.id as $fid | $ids | index($fid)) then . + {wave:$idx} else . end
      )) |
      .waves = (
        ((.waves // []) | map(select(.index != $idx))) +
        [{index:$idx, total:$total, surface:$surface, finding_ids:$ids, status:"pending", commit_sha:"", ts:$ts}]
      ) |
      .waves |= sort_by(.index)')"
    _atomic_write "${updated}"
    printf 'wave=%s/%s surface=%s ids=%s\n' "${wave_idx}" "${wave_total}" "${surface}" "$*"
    ;;

  wave-status)
    wave_idx="${1:-}"; wstatus="${2:-}"; commit_sha="${3:-}"
    if [[ -z "${wave_idx}" || -z "${wstatus}" ]]; then
      printf 'usage: record-finding-list wave-status <idx> <status> [<commit_sha>]\n' >&2
      exit 1
    fi
    case "${wstatus}" in
      pending|in_progress|completed) ;;
      *) printf 'invalid wave status: %s (expected pending|in_progress|completed)\n' "${wstatus}" >&2; exit 1 ;;
    esac
    _ensure_file
    _acquire_lock
    current="$(cat "${FINDINGS_FILE}")"
    updated="$(printf '%s' "${current}" | jq \
      --argjson idx "${wave_idx}" \
      --arg wstatus "${wstatus}" \
      --arg commit_sha "${commit_sha}" \
      --argjson ts "$(_now)" '
      .updated_ts = $ts |
      .waves = (.waves | map(
        if .index == $idx then
          . + {
            status: $wstatus,
            commit_sha: (if $commit_sha == "" then .commit_sha else $commit_sha end),
            ts: $ts
          }
        else . end
      ))')"
    _atomic_write "${updated}"
    printf 'wave=%s status=%s\n' "${wave_idx}" "${wstatus}"
    ;;

  show)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      # shellcheck disable=SC2016
      printf '(no findings.json yet — run `record-finding-list init` to create it)\n'
      exit 0
    fi
    jq . "${FINDINGS_FILE}"
    ;;

  counts)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      printf 'total=0 shipped=0 deferred=0 rejected=0 in_progress=0 pending=0\n'
      exit 0
    fi
    total="$(jq '.findings|length' "${FINDINGS_FILE}")"
    shipped="$(jq '[.findings[]|select(.status=="shipped")]|length' "${FINDINGS_FILE}")"
    deferred="$(jq '[.findings[]|select(.status=="deferred")]|length' "${FINDINGS_FILE}")"
    rejected="$(jq '[.findings[]|select(.status=="rejected")]|length' "${FINDINGS_FILE}")"
    in_progress="$(jq '[.findings[]|select(.status=="in_progress")]|length' "${FINDINGS_FILE}")"
    pending="$(jq '[.findings[]|select(.status=="pending")]|length' "${FINDINGS_FILE}")"
    printf 'total=%s shipped=%s deferred=%s rejected=%s in_progress=%s pending=%s\n' \
      "${total}" "${shipped}" "${deferred}" "${rejected}" "${in_progress}" "${pending}"
    ;;

  summary)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      printf '_(no findings recorded)_\n'
      exit 0
    fi
    {
      printf '| ID | Severity | Surface | Status | Commit | Notes |\n'
      printf '|----|----------|---------|--------|--------|-------|\n'
      jq -r '
        .findings | sort_by(.id)[] |
        "| \(.id) | \(.severity // "—") | \(.surface // "—") | \(
          if .status == "shipped" then "✓ shipped"
          elif .status == "deferred" then "⚠ deferred"
          elif .status == "rejected" then "✗ rejected"
          elif .status == "in_progress" then "◐ in-progress"
          else "○ pending"
          end
        ) | \(if (.commit_sha // "") == "" then "—" else (.commit_sha[0:7]) end) | \((.notes // "") | gsub("\\|"; "\\|")) |"
      ' "${FINDINGS_FILE}"
      printf '\n'
      total="$(jq '.findings|length' "${FINDINGS_FILE}")"
      shipped="$(jq '[.findings[]|select(.status=="shipped")]|length' "${FINDINGS_FILE}")"
      deferred="$(jq '[.findings[]|select(.status=="deferred")]|length' "${FINDINGS_FILE}")"
      rejected="$(jq '[.findings[]|select(.status=="rejected")]|length' "${FINDINGS_FILE}")"
      in_progress="$(jq '[.findings[]|select(.status=="in_progress")]|length' "${FINDINGS_FILE}")"
      pending="$(jq '[.findings[]|select(.status=="pending")]|length' "${FINDINGS_FILE}")"
      printf '**Counts:** total=%s · shipped=%s · deferred=%s · rejected=%s · in-progress=%s · pending=%s\n' \
        "${total}" "${shipped}" "${deferred}" "${rejected}" "${in_progress}" "${pending}"
      printf '\n'
    }
    ;;

  ""|--help|-h|help)
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    printf 'unknown command: %s (try --help)\n' "${cmd}" >&2
    exit 1
    ;;
esac
