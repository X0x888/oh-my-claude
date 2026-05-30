#!/usr/bin/env bash
# record-discovered-scope.sh - Resolve discovered-scope findings (v1.46).
#
# discovered_scope.jsonl rows (captured from advisory specialists / council
# lenses / reviewers) carry a `status` field. The discovered-scope stop-gate
# counts `pending` rows and, under no_defer_mode=on (the /ulw default), keeps
# blocking until pending==0. Before v1.46 the ONLY writer that could mutate
# that status was mark-deferred.sh — which is REFUSED under ULW — so a model
# that genuinely SHIPPED a fix for a captured finding (or determined it was
# NOT a defect) had no sanctioned CLI to clear the row: it had to eat the
# 2-block cap or abuse /ulw-skip. The gate's own #1-preferred recovery ("ship
# inline") was un-recordable, and stop-guard.sh even referenced this script
# before it existed. This is that missing verb — the anti-defer counterpart
# to mark-deferred (so `shipped` is NEVER gated by is_no_defer_active).
#
# Statuses:
#   shipped  — the finding was fixed inline; requires a commit SHA or evidence
#              string (proof-of-work; symmetric to the F-010 reject-without-
#              rationale defense — no silent clear).
#   rejected — not a defect (false positive / duplicate / obsolete / by design
#              — X); requires a concrete WHY (validated like a finding reject,
#              NOT a defer, so allowed under ULW).
#   pending  — un-resolve (restore to the gate's count).
#
# Usage:
#   record-discovered-scope.sh status <id-prefix> <shipped|rejected|pending> [evidence|why]
#   record-discovered-scope.sh counts
#   record-discovered-scope.sh path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(discover_latest_session)"
if [[ -z "${SESSION_ID}" ]]; then
  printf 'record-discovered-scope: no active session found under %s\n' "${STATE_ROOT}" >&2
  exit 1
fi

ensure_session_dir
SCOPE_FILE="$(session_file "discovered_scope.jsonl")"

_now() { date +%s; }

_require_file() {
  if [[ ! -f "${SCOPE_FILE}" ]]; then
    printf 'record-discovered-scope: no discovered_scope.jsonl for this session (nothing to resolve)\n' >&2
    exit 2
  fi
}

_counts_line() {
  printf 'pending=%s shipped=%s rejected=%s total=%s' \
    "$(read_pending_scope_count)" \
    "$(read_scope_count_by_status "shipped")" \
    "$(read_scope_count_by_status "rejected")" \
    "$(read_total_scope_count)"
}

# Count rows whose id starts with the given prefix (per-line; JSONL tolerates
# a single malformed row without nuking the whole file, mirroring
# read_scope_count_by_status).
_match_count() {
  local prefix="$1" line count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    if jq -e --arg id "${prefix}" '(.id // "") | startswith($id)' <<<"${line}" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done < "${SCOPE_FILE}"
  printf '%s' "${count}"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  status)
    _require_file
    id_prefix="${1:-}"
    new_status="${2:-}"
    evidence="${3:-}"

    if [[ -z "${id_prefix}" || -z "${new_status}" ]]; then
      printf 'usage: record-discovered-scope.sh status <id-prefix> <shipped|rejected|pending> [evidence|why]\n' >&2
      exit 2
    fi
    case "${new_status}" in
      shipped|rejected|pending) ;;
      *)
        printf 'record-discovered-scope: invalid status: %s (expected shipped|rejected|pending)\n' "${new_status}" >&2
        exit 2
        ;;
    esac

    # shipped: proof-of-work required so a finding cannot be silently cleared
    # without evidence it was actually fixed (symmetric to F-010).
    if [[ "${new_status}" == "shipped" && -z "${evidence//[[:space:]]/}" ]]; then
      printf 'record-discovered-scope: shipped requires a commit SHA or evidence string (no silent clear)\n' >&2
      exit 2
    fi

    # rejected: not-a-defect requires a concrete WHY. This is a REJECT, not a
    # DEFER, so it is allowed under no_defer_mode — but the same WHY-validator
    # that gates finding rejects applies (no bare "out of scope").
    if [[ "${new_status}" == "rejected" ]]; then
      if [[ -z "${evidence//[[:space:]]/}" ]]; then
        printf 'record-discovered-scope: rejected requires a concrete WHY (false positive / duplicate / obsolete / not a bug / by design — <reason>)\n' >&2
        exit 2
      fi
      if ! omc_reason_has_concrete_why "${evidence}"; then
        printf 'record-discovered-scope: reject reason rejected — name a concrete WHY (false positive, duplicate, obsolete, not reproducible, n/a, or "by design — <reason>"), not a silent skip.\n' >&2
        exit 2
      fi
    fi

    match_count="$(_match_count "${id_prefix}")"
    if [[ "${match_count}" -eq 0 ]]; then
      printf 'record-discovered-scope: no finding matches id prefix %s\n' "${id_prefix}" >&2
      exit 2
    fi
    if [[ "${match_count}" -gt 1 ]]; then
      printf 'record-discovered-scope: id prefix %s is ambiguous (%s matches) — use a longer prefix\n' "${id_prefix}" "${match_count}" >&2
      exit 2
    fi

    ts="$(_now)"
    _do_status_update() {
      local tmp line
      tmp="$(mktemp "${SCOPE_FILE}.XXXXXX")" || return 1
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        if jq -e --arg id "${id_prefix}" '(.id // "") | startswith($id)' <<<"${line}" >/dev/null 2>&1; then
          jq -c \
            --arg st "${new_status}" \
            --arg ev "${evidence}" \
            --argjson ts "${ts}" \
            '.status = $st | .reason = $ev | .resolved_ts = $ts' <<<"${line}" >> "${tmp}" 2>/dev/null \
            || printf '%s\n' "${line}" >> "${tmp}"
        else
          printf '%s\n' "${line}" >> "${tmp}"
        fi
      done < "${SCOPE_FILE}"
      mv -f "${tmp}" "${SCOPE_FILE}"
    }
    if ! with_scope_lock _do_status_update; then
      printf 'record-discovered-scope: status update failed for %s (lock contention or temp-file error)\n' "${id_prefix}" >&2
      exit 2
    fi

    printf 'Updated %s to %s. %s\n' "${id_prefix}" "${new_status}" "$(_counts_line)"
    ;;

  counts)
    # Works even with no file (read_* helpers return 0 for a missing file).
    printf '%s\n' "$(_counts_line)"
    ;;

  path)
    printf '%s\n' "${SCOPE_FILE}"
    ;;

  *)
    printf 'usage: record-discovered-scope.sh <status|counts|path>\n' >&2
    printf '  status <id-prefix> <shipped|rejected|pending> [evidence|why]\n' >&2
    printf '  counts\n' >&2
    printf '  path\n' >&2
    exit 2
    ;;
esac
