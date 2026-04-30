#!/usr/bin/env bash
# mark-deferred.sh — bulk-update all pending discovered_scope rows to
# status="deferred" with a one-line reason.
#
# Backs the /mark-deferred skill. Closes the gap where the
# discovered-scope gate (stop-guard.sh) requires explicit deferrals but
# the user has no structured verb — they had to either address each
# finding inline in the summary or hit the gate's block cap. This
# script gives them a one-call defer-all-pending verb that keeps the
# rows in the log (not deletes them) so /ulw-report can audit deferral
# patterns later.
#
# Usage:
#   mark-deferred.sh "<reason>"
#
# Exit codes:
#   0 — at least one row updated, OR no pending rows to update (no-op)
#   2 — bad invocation (missing reason / not in a session / no scope file)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

reason="${1:-}"
if [[ -z "${reason//[[:space:]]/}" ]]; then
  printf 'mark-deferred: a non-empty reason is required.\n' >&2
  printf 'usage: mark-deferred.sh "<reason>"\n' >&2
  exit 2
fi

# Reject reasons that have historically been used as silent-skip
# escape hatches. The error message lists acceptable shapes so the
# user (or model invoking the skill) can immediately rewrite.
if [[ "${OMC_MARK_DEFERRED_STRICT:-on}" == "on" ]] \
    && ! omc_reason_has_concrete_why "${reason}"; then
  cat >&2 <<EOF
mark-deferred: reason rejected — must name a concrete WHY.

Provided: ${reason}

Acceptable reason shapes (from mark-deferred/SKILL.md):
  - requires <named context>     e.g. 'requires database migration'
  - blocked by <named blocker>   e.g. 'blocked by F-042 shipping first'
  - superseded by <successor>    e.g. 'superseded by F-051'
  - awaiting <named event>       e.g. 'awaiting stakeholder pricing decision'
  - pending #<issue> | wave N    e.g. 'pending #847' or 'pending wave 3'
  - duplicate | obsolete | superseded (self-explanatory single token)

Rejected (silent-skip patterns):
  - out of scope               (what makes it out of scope?)
  - not in scope               (same)
  - follow-up                  (waiting on what?)
  - separate task              (which task, when?)
  - later / not now            (no WHY)
  - low priority               (rank, not reason)

Reach for wave-append before deferral when the finding is same-surface to
your active work — see /mark-deferred SKILL.md "When NOT to use".

Override (last resort, audited): set OMC_MARK_DEFERRED_STRICT=off in the
environment or oh-my-claude.conf. Prefer rewriting the reason instead.
EOF
  exit 2
fi

if [[ -z "${SESSION_ID:-}" ]]; then
  printf 'mark-deferred: no active session (SESSION_ID unset)\n' >&2
  exit 2
fi

# Audit the strict-mode bypass. When OMC_MARK_DEFERRED_STRICT=off AND the
# reason would have been rejected by the require-WHY validator, emit a
# gate-event row so /ulw-report can surface the user's bypass count
# across sessions. The error message at line 62 promises "audited" — this
# call is what makes that promise concrete. Without it, a user could
# silently bypass the validator indefinitely with no visibility into how
# often they're sidestepping the silent-skip defense.
if [[ "${OMC_MARK_DEFERRED_STRICT:-on}" != "on" ]] \
    && ! omc_reason_has_concrete_why "${reason}"; then
  # Pure-bash slice instead of `head -c 200`: same root-cause family as
  # the Wave 1 resume-watchdog.sh:117 fix (head -c is non-POSIX and
  # behaves inconsistently on minimal coreutils variants the harness may
  # encounter under restricted PATH or BusyBox/Alpine setups).
  record_gate_event "mark-deferred" "strict-bypass" \
    reason="${reason:0:200}"
fi

scope_file="$(session_file "discovered_scope.jsonl")"
if [[ ! -f "${scope_file}" ]]; then
  printf 'mark-deferred: no discovered_scope.jsonl in this session yet (nothing to defer)\n' >&2
  exit 2
fi

ts="$(date +%s)"

# shellcheck disable=SC2329 # invoked indirectly via with_scope_lock
_do_mark_deferred() {
  local file pending_before deferred_before total_before
  file="$(session_file "discovered_scope.jsonl")"

  # Per-line count so a single malformed row doesn't false-pass the gate
  # via slurp tolerance (same defensive pattern read_pending_scope_count
  # uses in common.sh).
  pending_before=0
  deferred_before=0
  total_before=0
  local line status
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    total_before=$((total_before + 1))
    status="$(jq -r '.status // empty' <<<"${line}" 2>/dev/null || true)"
    case "${status}" in
      pending)  pending_before=$((pending_before + 1)) ;;
      deferred) deferred_before=$((deferred_before + 1)) ;;
    esac
  done < "${file}"

  if [[ "${pending_before}" -eq 0 ]]; then
    printf 'No pending findings to defer (%d total in scope, %d already deferred).\n' \
      "${total_before}" "${deferred_before}"
    return 0
  fi

  # Atomic update: build a new file with every pending row flipped to
  # deferred (carrying the reason and an updated ts), then mv-replace.
  # Per-line transform tolerates malformed rows (they pass through
  # unchanged) — corrupting an already-corrupt log is not the win here.
  #
  # Counter discipline: `updated` = pending → deferred transforms that
  # succeeded; `xform_failed` = pending rows whose jq transform failed
  # (corrupt JSONL); `non_pending_preserved` = rows that were not
  # pending. Conflating the last two would let a transform-failure
  # masquerade as a successful preservation and trip the post-message
  # claim that the gate will pass — which would be a UX-breaking lie
  # (the still-pending row would re-block the gate on the next stop).
  local tmp updated=0 xform_failed=0 non_pending_preserved=0
  tmp="$(mktemp "${file}.XXXXXX")"
  # Trap the tmp file across SIGINT / SIGTERM so an interrupt between
  # mktemp and mv does not leak <session>/discovered_scope.jsonl.XXXXXX.
  # Cleared on the success path (line cleanup just before return 0) so
  # the mv can hand off ownership of the inode without a competing rm.
  # shellcheck disable=SC2064 # intentionally expand $tmp at trap-set time
  trap "rm -f '${tmp}'" INT TERM EXIT
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    # Validate JSON first so corrupt rows are routed to xform_failed
    # rather than silently falling through the non-pending branch.
    # Without this, a malformed row's status-detection jq fails, status
    # becomes empty, and the row counts as "preserved" — which masks a
    # real corruption signal from the user and the gate.
    if ! jq -e 'type == "object"' <<<"${line}" >/dev/null 2>&1; then
      printf '%s\n' "${line}" >> "${tmp}"
      xform_failed=$((xform_failed + 1))
      continue
    fi
    status="$(jq -r '.status // empty' <<<"${line}" 2>/dev/null || true)"
    if [[ "${status}" == "pending" ]]; then
      local transformed
      if transformed="$(jq -c \
            --arg reason "${reason}" \
            --arg ts "${ts}" \
            '. + {status:"deferred", reason:$reason, ts_updated:$ts}' \
            <<<"${line}" 2>/dev/null)"; then
        printf '%s\n' "${transformed}" >> "${tmp}"
        updated=$((updated + 1))
      else
        # Object validates but the transform failed (jq filter error,
        # disk write hiccup) — preserve the original. Still pending in
        # the output; surface honestly to the user.
        printf '%s\n' "${line}" >> "${tmp}"
        xform_failed=$((xform_failed + 1))
      fi
    else
      printf '%s\n' "${line}" >> "${tmp}"
      non_pending_preserved=$((non_pending_preserved + 1))
    fi
  done < "${file}"

  if ! mv "${tmp}" "${file}" 2>/dev/null; then
    rm -f "${tmp}"
    trap - INT TERM EXIT
    printf 'mark-deferred: atomic rename failed; no changes applied\n' >&2
    return 1
  fi
  # mv consumed the tmp inode — clear the trap so the EXIT handler does
  # not rm a file that no longer exists by that name.
  trap - INT TERM EXIT

  printf 'Deferred %d pending finding(s) with reason: %s\n' "${updated}" "${reason}"
  printf '  Scope status: %d deferred (now), %d other rows preserved.\n' \
    "$((deferred_before + updated))" "${non_pending_preserved}"
  if [[ "${xform_failed}" -eq 0 ]]; then
    printf '  Discovered-scope gate will pass on the next stop attempt (0 pending remain).\n'
  else
    # Two modes are possible here: (a) row was pending, the deferral
    # filter failed, row stays pending → gate WILL re-block; (b) row was
    # not parseable as JSON at all → gate's status check ignores it, so
    # the gate may still pass, but the file is corrupt and the user
    # should know. Both warrant the same action: inspect the file.
    printf '  WARNING: %d row(s) failed the deferral transform (corrupt JSONL or filter error) and were preserved unchanged.\n' \
      "${xform_failed}"
    printf '           Inspect %s and repair the malformed rows; if any were pending, the discovered-scope gate will continue to block.\n' \
      "${file}"
  fi
  return 0
}

with_scope_lock _do_mark_deferred
exit 0
