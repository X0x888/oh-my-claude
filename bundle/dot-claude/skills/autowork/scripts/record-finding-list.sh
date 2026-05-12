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
#   record-finding-list.sh mark-user-decision <id> <reason>
#                                          # Flag a finding as requiring user judgment
#                                          # (v1.40.0: operational-only — credentials/login, external account,
#                                          # destructive shared-state action awaiting confirmation. NOT for
#                                          # taste/policy/credible-approach under no_defer_mode=on.)
#                                          # so Phase 8 wave executor pauses on it
#                                          # rather than choosing autonomously.
#   record-finding-list.sh show            # print current findings.json (pretty)
#   record-finding-list.sh summary         # markdown summary table for final report
#   record-finding-list.sh counts          # one-line counts (total/shipped/deferred/etc.)
#   record-finding-list.sh status-line     # human-readable progress line (in-session use)
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
#         "commit_sha": "...", "notes": "...", "ts": <epoch>,
#         "requires_user_decision": <bool>, "decision_reason": "..." }
#     ],
#     "waves": [
#       { "index": 1, "total": 5, "surface": "auth", "finding_ids": ["F-001","F-002"],
#         "status": "pending|in_progress|completed", "commit_sha": "...", "ts": <epoch> }
#     ]
#   }
#
# requires_user_decision (v1.18.0):
#   Findings that involve taste, policy, brand voice, or a credible-approach
#   split (two reasonable paths where choosing wrong costs significant
#   rework) should be marked with requires_user_decision=true and a
#   non-empty decision_reason. Phase 8 wave executor pauses on these
#   instead of choosing autonomously — the rule mirrors core.md's pause
#   cases. Backwards compatible: defaults to false; existing finding
#   schemas without the field continue to work.

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

_now() { date +%s; }

# v1.36.x W1 F-001: Lock acquisition routes through with_findings_lock
# (in common.sh), which delegates to _with_lockdir for PID-based stale
# recovery. Prior versions had a bare-mkdir lockdir with no PID reclaim,
# so a crashed mid-write process orphaned the lock for the full retry
# budget (~5s) before the next caller could proceed. The new helper
# uses kill -0 to reclaim immediately on holder-process death and
# emits a long-wait anomaly for /ulw-report visibility.

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
    # requires_user_decision defaults to false (most findings are model-
    # executable); decision_reason defaults to empty string. Both are
    # backwards compatible — existing init payloads without these fields
    # continue to work.
    normalized="$(printf '%s' "${findings_json}" | jq --argjson ts "$(_now)" \
      '[.[] | . + {
        ts: (.ts // $ts),
        status: (.status // "pending"),
        wave: (.wave // null),
        commit_sha: (.commit_sha // ""),
        notes: (.notes // ""),
        requires_user_decision: (.requires_user_decision // false),
        decision_reason: (.decision_reason // "")
      }]')"
    _do_init_write() {
      local new_doc
      new_doc="$(jq -n \
        --argjson ts "$(_now)" \
        --argjson findings "${normalized}" \
        '{version:1, created_ts:$ts, updated_ts:$ts, findings:$findings, waves:[]}')"
      _atomic_write "${new_doc}"
    }
    if ! with_findings_lock _do_init_write; then
      printf 'record-finding-list init: lock acquisition or body failed for %s\n' "${FINDINGS_FILE}" >&2
      exit 1
    fi
    count="$(jq 'length' <<<"${normalized}")"
    # Fresh plan = fresh gate budget. The wave-shape gate's cap=1 design
    # is "once per wave plan", not "once per session" — without this
    # reset, a session that pivots to a new findings list (e.g., after
    # a long pause and a new objective) would carry the prior plan's
    # exhausted block forward, silently disabling the gate on the new
    # plan. write_state is sourced from common.sh and is a no-op when
    # SESSION_ID is unset (e.g., test harness).
    if [[ -n "${SESSION_ID:-}" ]]; then
      write_state "wave_shape_blocks" "" 2>/dev/null || true
    fi
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
    # Pre-validate dedup outside the lock — a duplicate-id rejection is
    # cheaper to surface without acquiring the mutex, and a concurrent
    # add-finding for the same id is rare in the wave-plan workflow
    # (the finding-id space is model-generated and globally unique per
    # wave plan). The dedup check inside _do_add_finding still fires
    # under the lock to close the race; this is a fast-path bail-out.
    _add_finding_dedup_outside_lock="$(jq -e --arg id "${new_id}" \
      '[.findings[] | select(.id == $id)] | length > 0' "${FINDINGS_FILE}" 2>/dev/null && printf '1' || printf '0')"
    if [[ "${_add_finding_dedup_outside_lock}" == "1" ]]; then
      # shellcheck disable=SC2016  # backticks are literal in the error text.
      printf 'record-finding-list add-finding: id %s already exists; use `status` to update\n' \
        "${new_id}" >&2
      exit 1
    fi
    _do_add_finding() {
      local current normalized updated
      current="$(cat "${FINDINGS_FILE}")"
      # Re-check inside the lock — a peer may have added the same id
      # between the outside-lock fast-path bail-out and this acquire.
      if printf '%s' "${current}" | jq -e --arg id "${new_id}" \
          '[.findings[] | select(.id == $id)] | length > 0' >/dev/null 2>&1; then
        printf 'record-finding-list add-finding: id %s already exists (race-detected under lock)\n' \
          "${new_id}" >&2
        return 1
      fi
      normalized="$(printf '%s' "${input}" | jq --argjson ts "$(_now)" \
        '. + {
          ts: (.ts // $ts),
          status: (.status // "pending"),
          wave: (.wave // null),
          commit_sha: (.commit_sha // ""),
          notes: (.notes // ""),
          requires_user_decision: (.requires_user_decision // false),
          decision_reason: (.decision_reason // "")
        }')"
      updated="$(printf '%s' "${current}" | jq \
        --argjson finding "${normalized}" \
        --argjson ts "$(_now)" '
        .updated_ts = $ts |
        .findings += [$finding]')"
      _atomic_write "${updated}"
    }
    if ! with_findings_lock _do_add_finding; then
      printf 'record-finding-list add-finding: lock acquisition or write failed for F=%s\n' "${new_id}" >&2
      exit 1
    fi
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

    # v1.40.0 no_defer_mode guard — the second of three deferral call
    # sites. Under ULW execution intent, marking a finding deferred via
    # the wave-plan ledger is the same escape pattern /mark-deferred
    # closed: a model can hide cherry-picked work behind a status flip.
    # The guard refuses the transition; the model must use status=shipped
    # (with a real commit_sha), keep status=pending until shipped, or
    # mark status=rejected when the finding is genuinely not-a-defect
    # (the validator on rejected still requires a concrete WHY, and the
    # bar for "not a defect" is high — it should be uncommon). Status
    # transitions other than deferred (pending/in_progress/shipped/
    # rejected) pass through unchanged.
    if [[ "${status}" == "deferred" ]] && is_no_defer_active; then
      cat >&2 <<EOF
record-finding-list: status=deferred refused for F=${id} under ULW execution (no_defer_mode=on).

The /ulw workflow does not defer findings. Recovery options:
  1. Ship the finding inline, then: record-finding-list.sh status ${id} shipped <commit_sha>
  2. Keep status=pending and address it in the active or next wave.
  3. status=rejected with a concrete WHY — ONLY when the finding is
     genuinely not a defect (false positive, working as intended, by
     design, duplicate, obsolete, wontfix with a real reason).
  4. /ulw-pause for a real external blocker (credentials, rate limit,
     dead infra) — NOT for credible-approach splits or taste calls.

Override (last resort, audited): no_defer_mode=off in oh-my-claude.conf.
EOF
      record_gate_event "no-defer-mode" "finding-deferred-refused" \
        "finding_id=${id}" \
        "notes_preview=${notes:0:200}" 2>/dev/null || true
      exit 2
    fi

    # v1.35.0 — require-WHY validation on terminal-status non-success transitions.
    # Until v1.34.x this path was unvalidated, leaving a parallel silent-skip
    # loophole to /mark-deferred: a model could mark a finding deferred or
    # rejected with a vague notes string ("out of scope", "requires significant
    # effort") and the wave-plan dashboard would accept it. The same validator
    # that gates /mark-deferred and record-scope-checklist declined-paths now
    # gates this transition. Gated by OMC_MARK_DEFERRED_STRICT (single source
    # of truth flag for all three call sites).
    #
    # Scope:
    #   - status=deferred — notes is the deferral reason, validated when present
    #   - status=rejected — notes is the rejection reason, validated when present
    #   - status=shipped|in_progress|pending — notes is descriptive metadata
    #     (commit summary, comparison hint, transition note), NOT validated
    #   - empty notes still permitted on this path (preserves prior notes
    #     via the jq ternary in the status-update block below); validation
    #     only fires when a non-empty notes string is provided AND status
    #     is deferred|rejected
    #
    # The bypass path mirrors /mark-deferred: setting OMC_MARK_DEFERRED_STRICT=off
    # disables the check. Bypass-with-failed-validator audits to gate_events.jsonl
    # so /ulw-report aggregates the pattern.
    if [[ "${status}" == "deferred" || "${status}" == "rejected" ]] \
        && [[ -n "${notes//[[:space:]]/}" ]] \
        && [[ "${OMC_MARK_DEFERRED_STRICT:-on}" == "on" ]] \
        && ! omc_reason_has_concrete_why "${notes}"; then
      cat >&2 <<EOF
record-finding-list status: ${status}-reason rejected — must name a concrete WHY (external blocker, not effort excuse).

Provided notes for F=${id}: ${notes}

Acceptable shapes:
  - requires <named context>           e.g. 'requires database migration'
  - blocked by <named blocker>         e.g. 'blocked by F-042 shipping first'
  - superseded by <successor>          e.g. 'superseded by F-051'
  - awaiting <named event>             e.g. 'awaiting stakeholder pricing decision'
  - pending #<issue> | wave N          e.g. 'pending #847' or 'pending wave 3'
  - duplicate | obsolete | wontfix | not reproducible | false positive | by design

Rejected — silent-skip patterns and effort excuses:
  - 'out of scope' / 'follow-up' / 'later' / 'low priority' (no WHY at all)
  - 'requires significant effort' / 'needs more time' / 'blocked by complexity'
  - 'tracks to a future session' / 'superseded by future work'

A legitimate WHY names what you are WAITING ON, not what the WORK COSTS.
For same-surface findings, prefer wave-append (record-finding-list.sh
add-finding + assign-wave) over marking deferred.

Override (last resort, audited): set OMC_MARK_DEFERRED_STRICT=off.
EOF
      exit 2
    fi
    # Audit the strict-mode bypass when the reason would have been rejected
    # under strict=on. Mirrors the audit shape used by mark-deferred.sh:84-91
    # so /ulw-report can aggregate bypass counts across both call sites
    # without separate plumbing.
    if [[ "${status}" == "deferred" || "${status}" == "rejected" ]] \
        && [[ -n "${notes//[[:space:]]/}" ]] \
        && [[ "${OMC_MARK_DEFERRED_STRICT:-on}" != "on" ]] \
        && ! omc_reason_has_concrete_why "${notes}"; then
      record_gate_event "finding-status" "strict-bypass" \
        "finding_id=${id}" \
        "finding_status=${status}" \
        reason="${notes:0:200}" 2>/dev/null || true
    fi

    _ensure_file
    _do_status_update() {
      local current updated
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
    }
    if ! with_findings_lock _do_status_update; then
      printf 'record-finding-list status: lock acquisition or body failed for F=%s\n' "${id}" >&2
      exit 1
    fi
    record_gate_event "finding-status" "finding-status-change" \
      "finding_id=${id}" \
      "finding_status=${status}" \
      "commit_sha=${commit_sha}"
    printf 'F=%s status=%s\n' "${id}" "${status}"
    ;;

  assign-wave)
    wave_idx="${1:-}"; wave_total="${2:-}"; surface="${3:-}"
    if [[ -z "${wave_idx}" || -z "${wave_total}" || -z "${surface}" ]] || ! shift 3 || [[ $# -eq 0 ]]; then
      printf 'usage: record-finding-list assign-wave <idx> <total> <surface> <id> [<id>...]\n' >&2
      exit 1
    fi
    ids_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    finding_count="$#"
    _ensure_file
    _do_assign_wave() {
      local current updated
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
    }
    if ! with_findings_lock _do_assign_wave; then
      printf 'record-finding-list assign-wave: lock acquisition or body failed for wave=%s\n' "${wave_idx}" >&2
      exit 1
    fi
    # F-011 — emit gate event for cross-session telemetry. /ulw-report
    # aggregates these into a wave-shape distribution panel.
    record_gate_event "wave-plan" "wave-assigned" \
      "wave_idx=${wave_idx}" \
      "wave_total=${wave_total}" \
      "surface=${surface}" \
      "finding_count=${finding_count}"
    # F-012 — narrow-wave advisory. Fires when a freshly-assigned wave
    # has <3 findings AND the master list has ≥5 findings AND there are
    # ≥2 waves planned. Single-finding waves on small lists are
    # legitimate; the warning targets the over-segmentation pattern that
    # produced the v1.21.0 5×1-wave UX regression.
    if [[ "${finding_count}" -lt 3 ]]; then
      total_findings="$(jq -r '(.findings // []) | length' "${FINDINGS_FILE}" 2>/dev/null || printf '0')"
      if [[ "${total_findings}" =~ ^[0-9]+$ ]] && [[ "${total_findings}" -ge 5 ]] && [[ "${wave_total}" -gt 1 ]]; then
        avg=$((total_findings / wave_total))
        printf 'record-finding-list assign-wave: WARNING — wave %s/%s has %s finding(s) (< 3)\n' \
          "${wave_idx}" "${wave_total}" "${finding_count}" >&2
        printf '  master list has %s findings across %s waves (avg %s/wave; canonical bar is 5-10/wave per council/SKILL.md Step 8)\n' \
          "${total_findings}" "${wave_total}" "${avg}" >&2
        printf '  if this is intentional (one critical finding owns its own wave), name the reason in the wave commit body\n' >&2
        record_gate_event "wave-plan" "narrow-wave-warning" \
          "wave_idx=${wave_idx}" \
          "wave_total=${wave_total}" \
          "finding_count=${finding_count}" \
          "total_findings=${total_findings}" \
          "avg_per_wave=${avg}"
      fi
    fi
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
    _do_wave_status() {
      local current updated
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
    }
    if ! with_findings_lock _do_wave_status; then
      printf 'record-finding-list wave-status: lock acquisition or body failed for wave=%s\n' "${wave_idx}" >&2
      exit 1
    fi
    record_gate_event "wave-status" "wave-status-change" \
      "wave_idx=${wave_idx}" \
      "wave_status=${wstatus}" \
      "commit_sha=${commit_sha}"
    printf 'wave=%s status=%s\n' "${wave_idx}" "${wstatus}"
    ;;

  mark-user-decision)
    id="${1:-}"; reason="${2:-}"
    if [[ -z "${id}" || -z "${reason}" ]]; then
      printf 'usage: record-finding-list mark-user-decision <id> <reason>\n' >&2
      printf '  Reason must name a real OPERATIONAL block (credentials, login, external account, destructive shared-state action).\n' >&2
      printf '  Under v1.40.0 no_defer_mode=on, taste/policy/credible-approach are NOT user-decision findings — the agent picks those.\n' >&2
      exit 1
    fi
    # Reject newlines in reason — they break the markdown bullet rendering
    # in `summary`'s "Awaiting user decision" section. Single-line reasons
    # only; if the user needs more detail they should put it in `notes`.
    if [[ "${reason}" == *$'\n'* ]]; then
      printf 'record-finding-list mark-user-decision: reason cannot contain newlines\n' >&2
      printf '  Use single-line reason; put detail in `notes` if needed.\n' >&2
      exit 1
    fi
    _ensure_file
    # Pre-check id existence and current status outside the lock — both
    # are read-only and a positive ID-not-found / terminal-status response
    # surfaces faster without serializing through the mutex. The actual
    # update inside _do_mark_user_decision re-reads under the lock so a
    # racing terminal-status transition cannot slip through.
    if ! jq -e --arg id "${id}" \
        '[.findings[] | select(.id == $id)] | length > 0' "${FINDINGS_FILE}" >/dev/null 2>&1; then
      printf 'record-finding-list mark-user-decision: id %s not found\n' "${id}" >&2
      exit 1
    fi
    _muc_current_status_outside_lock="$(jq -r --arg id "${id}" \
      '.findings[] | select(.id == $id) | .status' "${FINDINGS_FILE}" 2>/dev/null || true)"
    case "${_muc_current_status_outside_lock}" in
      shipped|deferred|rejected)
        printf 'record-finding-list mark-user-decision: F=%s already %s; mark-user-decision is for actionable findings only\n' \
          "${id}" "${_muc_current_status_outside_lock}" >&2
        printf '  Use `status` to update notes if you need to record retrospective context.\n' >&2
        exit 1
        ;;
    esac
    _do_mark_user_decision() {
      local current updated current_status
      current="$(cat "${FINDINGS_FILE}")"
      # Re-check terminal status under the lock — a peer may have shipped/
      # deferred/rejected this finding between the outside-lock pre-check
      # and this acquire. mark-user-decision is for actionable findings
      # only; flagging shipped / deferred / rejected findings creates
      # confusing UX where past-tense rows look identical to actionable
      # ones in the summary table.
      current_status="$(printf '%s' "${current}" | jq -r --arg id "${id}" \
        '.findings[] | select(.id == $id) | .status')"
      case "${current_status}" in
        shipped|deferred|rejected)
          printf 'record-finding-list mark-user-decision: F=%s already %s (race-detected under lock)\n' \
            "${id}" "${current_status}" >&2
          printf '  Use `status` to update notes if you need to record retrospective context.\n' >&2
          return 1
          ;;
      esac
      updated="$(printf '%s' "${current}" | jq \
        --arg id "${id}" \
        --arg reason "${reason}" \
        --argjson ts "$(_now)" '
        .updated_ts = $ts |
        .findings = (.findings | map(
          if .id == $id then
            . + {
              requires_user_decision: true,
              decision_reason: $reason,
              ts: $ts
            }
          else . end
        ))')"
      _atomic_write "${updated}"
    }
    if ! with_findings_lock _do_mark_user_decision; then
      printf 'record-finding-list mark-user-decision: lock acquisition or write failed for F=%s\n' "${id}" >&2
      exit 1
    fi
    record_gate_event "finding-status" "user-decision-marked" \
      "finding_id=${id}" \
      "decision_reason=${reason}"
    # v1.34.1+ (security-lens Z-009): pipe display through
    # _omc_strip_render_unsafe to drop C0/C1 control bytes the model
    # may have placed in the reason field. printf %q quotes shell
    # metacharacters but does NOT strip terminal-control or display-
    # mangling bytes (ANSI escapes, etc.). Defense-in-depth on the
    # display path; the strip is a no-op when the reason is clean.
    printf 'F=%s requires_user_decision=true reason=%q\n' "${id}" "${reason}" \
      | _omc_strip_render_unsafe
    ;;

  show)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      # shellcheck disable=SC2016
      printf '(no findings.json yet — run `record-finding-list init` to create it)\n'
      exit 0
    fi
    jq . "${FINDINGS_FILE}"
    ;;

  status-line)
    # Single human-readable status line for in-session progress visibility.
    # Format: "Findings: <shipped>/<total> shipped · <waves_completed>/<wave_total> waves · <pending> pending [· avg <N>/wave]"
    # The avg/wave suffix appears only when a wave plan is active. Trailing
    # warnings ("⚠ under-segmented") are appended when the predicate matches.
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      printf 'Findings: no plan yet (run record-finding-list.sh init to start)\n'
      exit 0
    fi
    total="$(jq '.findings|length' "${FINDINGS_FILE}")"
    shipped="$(jq '[.findings[]|select(.status=="shipped")]|length' "${FINDINGS_FILE}")"
    pending="$(jq '[.findings[]|select(.status=="pending")]|length' "${FINDINGS_FILE}")"
    in_progress="$(jq '[.findings[]|select(.status=="in_progress")]|length' "${FINDINGS_FILE}")"
    deferred="$(jq '[.findings[]|select(.status=="deferred")]|length' "${FINDINGS_FILE}")"
    wave_total="$(jq '(.waves // []) | length' "${FINDINGS_FILE}")"
    waves_completed="$(jq '[(.waves // [])[] | select(.status == "completed")] | length' "${FINDINGS_FILE}")"
    line="Findings: ${shipped}/${total} shipped"
    if [[ "${in_progress}" -gt 0 ]]; then
      line+=" · ${in_progress} in-progress"
    fi
    if [[ "${pending}" -gt 0 ]]; then
      line+=" · ${pending} pending"
    fi
    if [[ "${deferred}" -gt 0 ]]; then
      line+=" · ${deferred} deferred"
    fi
    if [[ "${wave_total}" -gt 0 ]]; then
      line+=" · ${waves_completed}/${wave_total} waves"
      if [[ "${total}" -ge 5 ]] && [[ "${wave_total}" -gt 1 ]]; then
        avg=$((total / wave_total))
        line+=" (avg ${avg}/wave"
        if (( total < 3 * wave_total )); then
          line+=" ⚠ under-segmented"
        fi
        line+=")"
      fi
    fi
    printf '%s\n' "${line}"
    ;;

  counts)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      printf 'total=0 shipped=0 deferred=0 rejected=0 in_progress=0 pending=0 user_decision=0\n'
      exit 0
    fi
    total="$(jq '.findings|length' "${FINDINGS_FILE}")"
    shipped="$(jq '[.findings[]|select(.status=="shipped")]|length' "${FINDINGS_FILE}")"
    deferred="$(jq '[.findings[]|select(.status=="deferred")]|length' "${FINDINGS_FILE}")"
    rejected="$(jq '[.findings[]|select(.status=="rejected")]|length' "${FINDINGS_FILE}")"
    in_progress="$(jq '[.findings[]|select(.status=="in_progress")]|length' "${FINDINGS_FILE}")"
    pending="$(jq '[.findings[]|select(.status=="pending")]|length' "${FINDINGS_FILE}")"
    # user_decision counts findings still awaiting user input (pending or
    # in_progress). Once a finding is shipped/deferred/rejected, the
    # user-decision flag is informational history, not actionable status.
    user_decision="$(jq '[.findings[]|select((.requires_user_decision // false) == true and (.status=="pending" or .status=="in_progress"))]|length' "${FINDINGS_FILE}")"
    printf 'total=%s shipped=%s deferred=%s rejected=%s in_progress=%s pending=%s user_decision=%s\n' \
      "${total}" "${shipped}" "${deferred}" "${rejected}" "${in_progress}" "${pending}" "${user_decision}"
    ;;

  summary)
    if [[ ! -f "${FINDINGS_FILE}" ]]; then
      printf '_(no findings recorded)_\n'
      exit 0
    fi
    {
      printf '| ID | Severity | Surface | Decision | Status | Commit | Notes |\n'
      printf '|----|----------|---------|----------|--------|--------|-------|\n'
      # A3-MED-4 (4-attacker security review): strip C0/C1 control
      # bytes from the rendered markdown table. The .notes / .id /
      # .severity / .surface fields originate in model-emitted
      # FINDINGS_JSON (the contract permits any printable string), so
      # JSON-decoded `` escape sequences would otherwise reach
      # the user's tty when this summary is run interactively. The
      # escape stripping happens post-jq-decode so any escape encoded
      # at the JSON layer is bytes-already by the time tr filters it.
      jq -r '
        .findings | sort_by(.id)[] |
        "| \(.id) | \(.severity // "—") | \(.surface // "—") | \(
          if (.requires_user_decision // false) == true then "USER-DECISION"
          else "—"
          end
        ) | \(
          if .status == "shipped" then "✓ shipped"
          elif .status == "deferred" then "⚠ deferred"
          elif .status == "rejected" then "✗ rejected"
          elif .status == "in_progress" then "◐ in-progress"
          else "○ pending"
          end
        ) | \(if (.commit_sha // "") == "" then "—" else (.commit_sha[0:7]) end) | \((.notes // "") | gsub("\\|"; "\\|")) |"
      ' "${FINDINGS_FILE}" | _omc_strip_render_unsafe
      printf '\n'
      total="$(jq '.findings|length' "${FINDINGS_FILE}")"
      shipped="$(jq '[.findings[]|select(.status=="shipped")]|length' "${FINDINGS_FILE}")"
      deferred="$(jq '[.findings[]|select(.status=="deferred")]|length' "${FINDINGS_FILE}")"
      rejected="$(jq '[.findings[]|select(.status=="rejected")]|length' "${FINDINGS_FILE}")"
      in_progress="$(jq '[.findings[]|select(.status=="in_progress")]|length' "${FINDINGS_FILE}")"
      pending="$(jq '[.findings[]|select(.status=="pending")]|length' "${FINDINGS_FILE}")"
      user_decision="$(jq '[.findings[]|select((.requires_user_decision // false) == true and (.status=="pending" or .status=="in_progress"))]|length' "${FINDINGS_FILE}")"
      printf '**Counts:** total=%s · shipped=%s · deferred=%s · rejected=%s · in-progress=%s · pending=%s · awaiting-user-decision=%s\n' \
        "${total}" "${shipped}" "${deferred}" "${rejected}" "${in_progress}" "${pending}" "${user_decision}"
      printf '\n'
      # When findings need user input, surface them inline so the final
      # summary makes the user-decision queue obvious without forcing
      # the reader to scan the table for USER-DECISION cells. Reason
      # and summary are flattened to a single line via gsub on newlines
      # (defense-in-depth — mark-user-decision rejects newlines in input,
      # but bare init payloads can still emit multi-line strings) and
      # pipes are escaped in case the field is later promoted to a
      # table column.
      if [[ "${user_decision}" -gt 0 ]]; then
        printf '**Awaiting user decision:**\n\n'
        jq -r '
          def safe: (. // "—") | gsub("\n"; " ") | gsub("\\|"; "\\|");
          .findings[] | select((.requires_user_decision // false) == true and (.status=="pending" or .status=="in_progress")) |
          "- **\(.id)** (\(.surface | safe)): \(.summary | safe)\n  Reason: \(.decision_reason | safe)"
        ' "${FINDINGS_FILE}"
        printf '\n'
      fi
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
