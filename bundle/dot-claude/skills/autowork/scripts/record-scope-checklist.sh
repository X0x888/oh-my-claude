#!/usr/bin/env bash
# record-scope-checklist.sh - Exemplifying-scope checklist ledger.
#
# When a /ulw execution prompt uses example markers ("for instance",
# "e.g.", "such as", "as needed", etc.), the prompt-intent-router marks
# exemplifying_scope_required=1. This script records the sibling items in
# the class the user exemplified, then tracks whether each item shipped or
# was consciously declined with a concrete reason. stop-guard reads the
# same file and blocks until no checklist items remain pending.
#
# Usage:
#   record-scope-checklist.sh init [--force]  # read JSON array from stdin
#   record-scope-checklist.sh status <id-prefix> <pending|shipped|declined> [reason]
#   record-scope-checklist.sh counts
#   record-scope-checklist.sh show
#   record-scope-checklist.sh summary
#   record-scope-checklist.sh path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(discover_latest_session)"
if [[ -z "${SESSION_ID}" ]]; then
  printf 'record-scope-checklist: no active session found under %s\n' "${STATE_ROOT}" >&2
  exit 1
fi

ensure_session_dir
SCOPE_CHECKLIST_FILE="$(session_file "exemplifying_scope.json")"
LOCKDIR="${SCOPE_CHECKLIST_FILE}.lock"

_now() { date +%s; }

_acquire_lock() {
  trap '_release_lock' EXIT INT TERM
  local i=0
  while ! mkdir "${LOCKDIR}" 2>/dev/null; do
    i=$((i + 1))
    if [[ "${i}" -gt 50 ]]; then
      printf 'record-scope-checklist: lock timeout on %s\n' "${LOCKDIR}" >&2
      trap - EXIT INT TERM
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

_release_lock() {
  rmdir "${LOCKDIR}" 2>/dev/null || true
}

_atomic_write() {
  local content="$1"
  local tmp="${SCOPE_CHECKLIST_FILE}.tmp.$$"
  printf '%s\n' "${content}" > "${tmp}"
  mv -f "${tmp}" "${SCOPE_CHECKLIST_FILE}"
}

_prompt_ts() {
  local ts
  ts="$(read_state "exemplifying_scope_prompt_ts")"
  [[ "${ts}" =~ ^[0-9]+$ ]] || ts=0
  printf '%s' "${ts}"
}

_prompt_preview() {
  read_state "exemplifying_scope_prompt_preview"
}

_normalize_input() {
  local raw="$1"
  local ts="$2"
  local prompt_ts="$3"
  local preview="$4"

  jq -c \
    --argjson ts "${ts}" \
    --argjson prompt_ts "${prompt_ts}" \
    --arg preview "${preview}" '
    def sid($n):
      if $n < 10 then "S-00\($n)"
      elif $n < 100 then "S-0\($n)"
      else "S-\($n)"
      end;
    def clean:
      tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");

    (if type == "array" then .
     elif type == "object" and (.items | type == "array") then .items
     else error("expected a JSON array, or an object with items[]")
     end)
    | [
        .[]
        | if type == "string" then
            {summary: (. | clean), surface: "", notes: ""}
          elif type == "object" then
            {
              summary: ((.summary // .item // .title // "") | clean),
              surface: ((.surface // "") | clean),
              notes: ((.notes // "") | clean)
            }
          else
            empty
          end
        | select(.summary != "")
      ]
    | if length == 0 then error("expected at least one non-empty item")
      elif length > 25 then error("expected at most 25 checklist items")
      else .
      end
    | {
        version: 1,
        created_ts: $ts,
        updated_ts: $ts,
        source: "exemplifying_scope",
        source_prompt_ts: $prompt_ts,
        prompt_preview: $preview,
        items: (
          to_entries
          | map({
              id: sid(.key + 1),
              summary: .value.summary,
              surface: .value.surface,
              notes: .value.notes,
              status: "pending",
              reason: "",
              ts: $ts
            })
        )
      }' <<< "${raw}"
}

_counts_line() {
  if [[ ! -f "${SCOPE_CHECKLIST_FILE}" ]]; then
    printf 'total=0 pending=0 shipped=0 declined=0\n'
    return
  fi

  jq -r '
    .items // [] |
    "total=\(length) pending=\([.[] | select(.status=="pending")] | length) shipped=\([.[] | select(.status=="shipped")] | length) declined=\([.[] | select(.status=="declined")] | length)"
  ' "${SCOPE_CHECKLIST_FILE}" 2>/dev/null || printf 'total=0 pending=0 shipped=0 declined=0\n'
}

_require_file() {
  if [[ ! -f "${SCOPE_CHECKLIST_FILE}" ]]; then
    printf 'record-scope-checklist: no exemplifying_scope.json yet; run init first\n' >&2
    exit 2
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

    raw="$(cat)"
    if [[ -z "${raw//[[:space:]]/}" ]]; then
      printf 'record-scope-checklist: init requires a JSON array on stdin\n' >&2
      exit 2
    fi

    ts="$(_now)"
    prompt_ts="$(_prompt_ts)"
    preview="$(_prompt_preview)"

    if [[ -f "${SCOPE_CHECKLIST_FILE}" && "${force}" -eq 0 ]]; then
      existing_prompt_ts="$(jq -r '.source_prompt_ts // 0' "${SCOPE_CHECKLIST_FILE}" 2>/dev/null || printf '0')"
      existing_items="$(jq -r '(.items // []) | length' "${SCOPE_CHECKLIST_FILE}" 2>/dev/null || printf '0')"
      if [[ "${existing_prompt_ts}" == "${prompt_ts}" && "${existing_items}" -gt 0 ]]; then
        printf 'record-scope-checklist: checklist already exists for this prompt; use init --force to replace it\n' >&2
        exit 2
      fi
    fi

    if ! checklist="$(_normalize_input "${raw}" "${ts}" "${prompt_ts}" "${preview}")"; then
      printf 'record-scope-checklist: invalid checklist JSON\n' >&2
      exit 2
    fi

    _acquire_lock
    _atomic_write "${checklist}"
    _release_lock
    trap - EXIT INT TERM

    write_state_batch \
      "exemplifying_scope_checklist_ts" "${ts}" \
      "exemplifying_scope_pending_count" "$(jq -r '[.items[] | select(.status=="pending")] | length' <<< "${checklist}")" \
      "exemplifying_scope_satisfied_ts" ""

    printf 'Recorded exemplifying-scope checklist. %s\n' "$(_counts_line)"
    ;;

  status)
    _require_file
    id_prefix="${1:-}"
    status="${2:-}"
    reason="${3:-}"

    if [[ -z "${id_prefix}" || -z "${status}" ]]; then
      printf 'usage: record-scope-checklist.sh status <id-prefix> <pending|shipped|declined> [reason]\n' >&2
      exit 2
    fi
    case "${status}" in
      pending|shipped|declined) ;;
      *)
        printf 'record-scope-checklist: invalid status: %s (expected pending|shipped|declined)\n' "${status}" >&2
        exit 2
        ;;
    esac

    if [[ "${status}" == "declined" ]]; then
      if [[ -z "${reason//[[:space:]]/}" ]]; then
        printf 'record-scope-checklist: declined requires a concrete reason\n' >&2
        exit 2
      fi
      if ! omc_reason_has_concrete_why "${reason}"; then
        cat >&2 <<EOF
record-scope-checklist: decline reason rejected — must name a concrete WHY (external blocker, not effort excuse).

Provided: ${reason}

Acceptable shapes:
  - requires <named context>           e.g. 'requires database migration'
  - blocked by <named blocker>         e.g. 'blocked by F-042'
  - superseded by <successor>          e.g. 'superseded by S-005'
  - awaiting <named event>             e.g. 'awaiting telemetry from canary'
  - pending #<issue> | wave N
  - duplicate | obsolete | wontfix | not reproducible | false positive | by design

Rejected — silent-skip patterns and effort excuses:
  - 'out of scope' / 'follow-up' / 'later' / 'low priority' (no WHY)
  - 'requires significant effort' / 'needs more time' / 'blocked by complexity'
  - 'tracks to a future session' / 'superseded by future work'

A legitimate WHY names what you are WAITING ON, not what the WORK COSTS.
EOF
        exit 2
      fi
    fi

    match_count="$(jq --arg id "${id_prefix}" '[.items[] | select(.id | startswith($id))] | length' "${SCOPE_CHECKLIST_FILE}")"
    if [[ "${match_count}" -eq 0 ]]; then
      printf 'record-scope-checklist: no item matches id prefix %s\n' "${id_prefix}" >&2
      exit 2
    fi
    if [[ "${match_count}" -gt 1 ]]; then
      printf 'record-scope-checklist: id prefix %s is ambiguous (%s matches)\n' "${id_prefix}" "${match_count}" >&2
      exit 2
    fi

    ts="$(_now)"
    _acquire_lock
    updated="$(jq -c \
      --arg id "${id_prefix}" \
      --arg status "${status}" \
      --arg reason "${reason}" \
      --argjson ts "${ts}" '
        .updated_ts = $ts
        | .items |= map(
            if (.id | startswith($id)) then
              .status = $status
              | .reason = $reason
              | .ts = $ts
            else
              .
            end
          )
      ' "${SCOPE_CHECKLIST_FILE}")"
    _atomic_write "${updated}"
    _release_lock
    trap - EXIT INT TERM

    pending="$(jq -r '[.items[] | select(.status=="pending")] | length' <<< "${updated}")"
    write_state "exemplifying_scope_pending_count" "${pending}"
    if [[ "${pending}" -eq 0 ]]; then
      write_state "exemplifying_scope_satisfied_ts" "${ts}"
    else
      write_state "exemplifying_scope_satisfied_ts" ""
    fi

    printf 'Updated %s to %s. %s\n' "${id_prefix}" "${status}" "$(_counts_line)"
    ;;

  counts)
    _counts_line
    ;;

  show)
    _require_file
    jq . "${SCOPE_CHECKLIST_FILE}"
    ;;

  summary)
    _require_file
    jq -r '
      "**Exemplifying Scope Checklist**",
      "",
      (.items // [] | map(
        "- [" + .status + "] " + .id + ": " + .summary
        + (if (.surface // "") != "" then " (" + .surface + ")" else "" end)
        + (if (.reason // "") != "" then " -- " + .reason else "" end)
      )[])
    ' "${SCOPE_CHECKLIST_FILE}"
    ;;

  path)
    printf '%s\n' "${SCOPE_CHECKLIST_FILE}"
    ;;

  *)
    cat >&2 <<'EOF'
Usage:
  record-scope-checklist.sh init [--force] < items.json
  record-scope-checklist.sh status <id-prefix> <pending|shipped|declined> [reason]
  record-scope-checklist.sh counts
  record-scope-checklist.sh show
  record-scope-checklist.sh summary
  record-scope-checklist.sh path
EOF
    exit 2
    ;;
esac
